-- The turn-on decisions of one Hue Light device (single lamp, zone light or
-- room light): Control4's brightness On Mode (#429), the colour on modes with
-- the On and Dim colours (#427), and what the proxy tells the driver about
-- both (docs/turn-on-design.md §7.4). The driver asks; this module answers
-- and keeps what it learned. It never sends anything and never moves a light
-- (D26): every decision is a value the driver puts into its own HUE_SET.
--
-- Pure Lua except for C4:ColorXYtoCCT / C4:ColorCCTtoXY (as light.state) and
-- the persistence functions the driver hands to turnon.new().
--
-- A colour is a table { x =, y =, mode = 0|1, id = n|nil, origin = n|nil }:
-- CIE 1931 xy, the light_v2 colour mode (0 full colour, 1 colour temperature),
-- and the preset id and origin when the colour is a preset as it stands (so
-- the notifies can name it, D16). Callers get copies; changing one changes
-- nothing here.
--
-- Parameter names: the light_v2 pages print the UPDATE_* names with spaces;
-- on the house SET_COLOR_TARGET's spaced names arrived with underscores
-- [verified: docs/c4-lighting-guidelines.md §6]. Every name is read with
-- underscores first, then with spaces (§7.3).

local log = require("common.log")

local turnon = {}

-- The colour and brightness modes as this module names them.
turnon.MODE_PRESET, turnon.MODE_PREVIOUS, turnon.MODE_FADE = "preset", "previous", "fade"
local PRESET, PREVIOUS, FADE = turnon.MODE_PRESET, turnon.MODE_PREVIOUS, turnon.MODE_FADE

-- §7.7. Two colours closer than MATCH_XY in x and y (same mode) are the same
-- preset (D16, and "Dim equals On", D13). FOREIGN_XY and FOREIGN_MIREK are
-- the driver's thresholds for a colour change made outside Control4
-- (turnon.foreign_color); they live here so the numbers are in one place.
turnon.MATCH_XY = 0.002
turnon.FOREIGN_XY = 0.01
turnon.FOREIGN_MIREK = 5

-- The "On" brightness preset has id 1 [verified: LV2 notif _16-PRESETLEVEL.md]
-- until the proxy names another (F6).
turnon.ON_PRESET_ID = 1

-- The persisted keys (§7.6); flat tables only, as the saved level.
turnon.KEYS = { brightness = "turnon_brightness", color = "turnon_color", presets = "turnon_presets" }
local KEYS = turnon.KEYS

-- light_v2 colour modes (LIGHT_COLOR_*_COLOR_MODE), as light.state.
local MODE_XY, MODE_CCT = 0, 1

-- The proxy's own preset names, matched without case (§7.4). A brightness
-- preset of these names maps onto the field of turnon_presets holding its
-- id; a colour preset onto the fields of its id and colour.
local LEVEL_ROLES = { on = "on_id", off = "off_id", previous = "previous_id" }
local COLOR_ROLES = {
	on = { id = "color_on_id", x = "on_x", y = "on_y", mode = "on_mode" },
	dim = { id = "color_dim_id", x = "dim_x", y = "dim_y", mode = "dim_mode" },
	-- The Previous colour changes with every off (F11): its id is kept, its
	-- colour only in memory.
	previous = { id = "color_previous_id" },
}

-- Parsing -------------------------------------------------------------------

-- A number, or nil for anything else (nil, junk, NaN, infinities).
local function num(v)
	if v == nil then
		return nil
	end
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- A parameter under its underscore name, else under the same name with
-- spaces; nil when absent or empty.
local function param(params, name)
	local v = params[name]
	if v == nil or v == "" then
		v = params[(name:gsub("_", " "))]
	end
	if v == "" then
		return nil
	end
	return v
end

-- The first of several names (UPDATE_BRIGHTNESS_PRESET prints its id as ID
-- on one page and PRESET ID on another, F5).
local function param_of(params, names)
	for _, name in ipairs(names) do
		local v = param(params, name)
		if v ~= nil then
			return v
		end
	end
	return nil
end

local function trim_lower(s)
	if s == nil then
		return nil
	end
	return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

local function valid_level(n)
	return n ~= nil and n >= 0 and n <= 100
end

-- A chromaticity inside the unit square. The GET_SETUP sample carries 0, 0
-- for presets defined by name only [verified: LV2 cmds _16.5-GETSETUP.md],
-- which is no colour.
local function valid_xy(x, y)
	return x ~= nil and y ~= nil and x > 0 and x < 1 and y > 0 and y < 1
end

local function valid_mode(m)
	return m == MODE_XY or m == MODE_CCT
end

-- The colour mode a message gave; a colour without one is full colour
-- [assumed], as light.state reads SET_COLOR_TARGET.
local function mode_or_xy(m)
	m = num(m)
	return valid_mode(m) and m or MODE_XY
end

local function round(n)
	return math.floor(n + 0.5)
end

local function clamp(n, lo, hi)
	return math.max(lo, math.min(hi, n))
end

-- Tables ---------------------------------------------------------------------

local function copy(t)
	if t == nil then
		return nil
	end
	local c = {}
	for k, v in pairs(t) do
		c[k] = v
	end
	return c
end

local function same_flat(a, b)
	if a == nil or b == nil then
		return a == b
	end
	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end
	for k, v in pairs(b) do
		if a[k] ~= v then
			return false
		end
	end
	return true
end

local function color(x, y, mode, id, origin)
	return { x = x, y = y, mode = mode, id = id, origin = origin }
end

-- Two colours that show the same: same mode, xy within MATCH_XY.
local function same_color(a, b)
	return a.mode == b.mode and math.abs(a.x - b.x) <= turnon.MATCH_XY and math.abs(a.y - b.y) <= turnon.MATCH_XY
end

-- Preset origins (1 device, 2 Color Agent, F13): equal, or one of them
-- unknown. UPDATE_COLOR_PRESET carries no origin, and neither do the
-- persisted On and Dim copies, so an unknown origin matches any [assumed].
local function origin_exact(a, b)
	return a == b
end

local function origin_lenient(a, b)
	return a == nil or b == nil or a == b
end

-- Persistence ----------------------------------------------------------------

-- The database keeps what was written, not a live reference: always a copy.
local function save(t, key, value)
	if value == nil then
		t.store.delete(key)
	else
		t.store.set(key, copy(value))
	end
end

local function save_presets(t)
	if next(t.presets) == nil then
		save(t, KEYS.presets, nil)
	else
		save(t, KEYS.presets, t.presets)
	end
end

-- Validators for the persisted copies: a normalised table, or nil and why.

local function check_brightness(v)
	if type(v) ~= "table" then
		return nil, "not a table"
	end
	local id, level = num(v.id), num(v.level)
	if not id then
		return nil, "no preset id"
	end
	if v.level ~= nil and not valid_level(level) then
		return nil, "level out of range"
	end
	return { id = id, level = level }
end

local function check_xy(v, x_key, y_key, mode_key, out)
	local x, y, mode = num(v[x_key]), num(v[y_key]), num(v[mode_key])
	if v[x_key] == nil and v[y_key] == nil then
		return true
	end
	if not valid_xy(x, y) or (v[mode_key] ~= nil and not valid_mode(mode)) then
		return false
	end
	out[x_key], out[y_key], out[mode_key] = x, y, mode or MODE_XY
	return true
end

local function check_color(v)
	if type(v) ~= "table" then
		return nil, "not a table"
	end
	if v.kind ~= PRESET and v.kind ~= PREVIOUS and v.kind ~= FADE then
		return nil, "unknown kind"
	end
	local out = { kind = v.kind }
	for _, k in ipairs({ "id", "origin", "fade_id", "fade_origin" }) do
		out[k] = num(v[k])
		if v[k] ~= nil and out[k] == nil then
			return nil, k .. " is not a number"
		end
	end
	if not check_xy(v, "x", "y", "mode", out) or not check_xy(v, "fade_x", "fade_y", "fade_mode", out) then
		return nil, "colour out of range"
	end
	if out.kind == FADE and not (out.fade_id and out.fade_x) then
		return nil, "fade without its Dim colour"
	end
	if out.kind == PREVIOUS and not out.id then
		return nil, "previous without a preset id"
	end
	if out.kind == PRESET and not (out.id or out.x) then
		return nil, "preset without an id or a colour"
	end
	if out.kind ~= FADE then
		out.fade_id, out.fade_origin, out.fade_x, out.fade_y, out.fade_mode = nil, nil, nil, nil, nil
	end
	if out.kind == PREVIOUS then
		out.x, out.y, out.mode = nil, nil, nil
	end
	return out
end

local function check_presets(v)
	if type(v) ~= "table" then
		return nil, "not a table"
	end
	local out = {}
	for _, k in ipairs({ "on_id", "off_id", "previous_id", "color_on_id", "color_dim_id", "color_previous_id" }) do
		out[k] = num(v[k])
		if v[k] ~= nil and out[k] == nil then
			return nil, k .. " is not a number"
		end
	end
	if not check_xy(v, "on_x", "on_y", "on_mode", out) or not check_xy(v, "dim_x", "dim_y", "dim_mode", out) then
		return nil, "colour out of range"
	end
	return out
end

-- One persisted copy, or nil; a bad one is deleted with one warning, so it
-- is not warned about at every start (L83).
local function load_key(t, key, check)
	-- The extra parentheses keep one value: Director's PersistGetValue returns
	-- none at all for a key never written (#298).
	local value = (t.store.get(key))
	if value == nil then
		return nil
	end
	local good, why = check(value)
	if not good then
		log.warn("stored %s is not usable (%s); dropped", key, why)
		t.store.delete(key)
	end
	return good
end

-- Construction ----------------------------------------------------------------

local function noop() end

-- store = { get = fn(key), set = fn(key, value), delete = fn(key) }, the
-- device's persistence (C4:PersistGetValue and friends); missing functions
-- do nothing, so a spec can leave it out.
function turnon.new(store)
	store = store or {}
	return {
		store = { get = store.get or noop, set = store.set or noop, delete = store.delete or noop },
		-- The brightness on mode (UPDATE_BRIGHTNESS_ON_MODE): { id, level }; nil is
		-- the default, Preset On at the Default On Brightness (D3).
		brightness = nil,
		-- The colour on mode (UPDATE_COLOR_ON_MODE): { kind, id, origin, x, y, mode,
		-- fade_id, fade_origin, fade_x, fade_y, fade_mode }; nil is the default,
		-- Preset with the proxy's On colour preset (D10).
		color = nil,
		-- The proxy's named presets (§7.6 turnon_presets), flat.
		presets = {},
		-- Memory only (refreshed by UPDATE_* and GET_SETUP): brightness preset
		-- levels by id, and every colour preset heard, { id, origin, name, x, y, mode }.
		levels = {},
		colors = {},
		-- D14: a Preset blend runs from a Control4 turn-on that carried the on
		-- colour until an explicit or foreign colour or the light going off.
		blending = false,
	}
end

-- At late init: the persisted copies (§7.6). Bad ones are dropped with a
-- warning and the defaults apply (D3, D10).
function turnon.load(t)
	t.brightness = load_key(t, KEYS.brightness, check_brightness)
	t.color = load_key(t, KEYS.color, check_color)
	t.presets = load_key(t, KEYS.presets, check_presets) or {}
end

-- Learned presets -------------------------------------------------------------

local function on_id(t)
	return t.presets.on_id or turnon.ON_PRESET_ID
end

-- The colour of a named preset (On or Dim) as last learned, or nil.
local function named(t, role)
	local f = COLOR_ROLES[role]
	local p = t.presets
	if not (f.x and p[f.x]) then
		return nil
	end
	return color(p[f.x], p[f.y], p[f.mode] or MODE_XY, p[f.id], nil)
end

-- Every colour this module knows with an id, for lookups by preset: the on
-- mode's own copies first (an UPDATE_COLOR_ON_MODE is at least as recent as
-- any preset heard before it, and a preset heard after it updates them,
-- sync_on_mode), then the presets heard, then the named ones.
local function candidates(t)
	local list = {}
	local m = t.color
	if m then
		list[#list + 1] = { id = m.id, origin = m.origin, x = m.x, y = m.y, mode = m.mode }
		if m.kind == FADE then
			list[#list + 1] = { id = m.fade_id, origin = m.fade_origin, x = m.fade_x, y = m.fade_y, mode = m.fade_mode }
		end
	end
	for _, c in ipairs(t.colors) do
		list[#list + 1] = c
	end
	for _, role in ipairs({ "on", "dim" }) do
		local c = named(t, role)
		if c then
			list[#list + 1] = c
		end
	end
	return list
end

-- The learned colour of a preset by id and origin: an exact origin match
-- first, then one where either origin is unknown. nil when none is known.
function turnon.color_for_preset(t, id, origin)
	id, origin = num(id), num(origin)
	if not id then
		return nil
	end
	local list = candidates(t)
	for _, match in ipairs({ origin_exact, origin_lenient }) do
		for _, c in ipairs(list) do
			if c.id == id and c.x and match(c.origin, origin) then
				return color(c.x, c.y, c.mode or MODE_XY, id, origin or c.origin)
			end
		end
	end
	return nil
end

-- Whether a brightness preset id is the learned "Previous" preset (D6).
function turnon.is_previous_preset(t, id)
	id = num(id)
	return id ~= nil and id == t.presets.previous_id
end

-- The learned "Off" brightness preset id, for an off's CHANGING (D7); nil
-- until the proxy named it: only learned ids and On = 1 are ever sent.
function turnon.off_preset_id(t)
	return t.presets.off_id
end

-- §7.6: a Previous brightness level is never persisted (it changes with every
-- off, and Previous mode never reads it, D6). Called once the Previous id is
-- known, which may be after the on mode named it.
local function strip_previous_level(t)
	local m = t.brightness
	if m and m.level ~= nil and turnon.is_previous_preset(t, m.id) then
		m.level = nil
		save(t, KEYS.brightness, m)
		return true
	end
	return false
end

-- A preset heard (UPDATE_COLOR_PRESET or GET_SETUP) changes the on mode's
-- copies that name it, so the latest word from the proxy wins. Returns true
-- when a copy changed.
local function sync_on_mode(t, id, origin, c)
	local m = t.color
	if not (m and id and c) then
		return false
	end
	local changed = false
	if m.kind ~= PREVIOUS and m.id == id and origin_lenient(m.origin, origin)
		and not (m.x == c.x and m.y == c.y and m.mode == c.mode) then
		m.x, m.y, m.mode = c.x, c.y, c.mode
		changed = true
	end
	if m.kind == FADE and m.fade_id == id and origin_lenient(m.fade_origin, origin)
		and not (m.fade_x == c.x and m.fade_y == c.y and m.fade_mode == c.mode) then
		m.fade_x, m.fade_y, m.fade_mode = c.x, c.y, c.mode
		changed = true
	end
	if changed then
		save(t, KEYS.color, m)
	end
	return changed
end

-- Add or replace a colour preset in the memory list: by id (and origin)
-- when it has one, else by name. Returns true when it changed.
local function remember_color(t, entry)
	for i, c in ipairs(t.colors) do
		local same_key
		if entry.id ~= nil then
			same_key = c.id == entry.id and c.origin == entry.origin
		else
			same_key = c.id == nil and c.name == entry.name and c.origin == entry.origin
		end
		if same_key then
			if same_flat(c, entry) then
				return false
			end
			t.colors[i] = entry
			return true
		end
	end
	t.colors[#t.colors + 1] = entry
	return true
end

-- Set a named colour preset's id and colour (either may be nil: kept).
-- Returns true when turnon_presets changed.
local function learn_role(t, role, id, c)
	local f, p = COLOR_ROLES[role], t.presets
	local changed = false
	if id ~= nil and p[f.id] ~= id then
		p[f.id] = id
		changed = true
	end
	if c and f.x and not (p[f.x] == c.x and p[f.y] == c.y and p[f.mode] == c.mode) then
		p[f.x], p[f.y], p[f.mode] = c.x, c.y, c.mode
		changed = true
	end
	return changed
end

-- From the proxy: brightness ------------------------------------------------

-- UPDATE_BRIGHTNESS_ON_MODE {BRIGHTNESS_PRESET_ID, BRIGHTNESS_PRESET_LEVEL}
-- [verified: LV2 cmds _20.1-UPDATEBRIGHTNESSONMODE.md]: the preset a turn-on
-- goes to (D4). The level is a convenience and may be absent. Returns true
-- when the mode changed.
function turnon.update_brightness_on_mode(t, params)
	params = params or {}
	local raw = param(params, "BRIGHTNESS_PRESET_ID")
	local id = num(raw)
	if not id then
		log.warn("UPDATE_BRIGHTNESS_ON_MODE without a usable BRIGHTNESS_PRESET_ID (%s); mode kept", tostring(raw))
		return false
	end
	local level = num(param(params, "BRIGHTNESS_PRESET_LEVEL"))
	if not valid_level(level) or turnon.is_previous_preset(t, id) then
		level = nil
	end
	local mode = { id = id, level = level }
	if same_flat(mode, t.brightness) then
		return false
	end
	t.brightness = mode
	save(t, KEYS.brightness, mode)
	return true
end

-- UPDATE_BRIGHTNESS_PRESET {COMMAND, ID or PRESET_ID, NAME, LEVEL} [verified:
-- LV2 cmds _20.3-UPDATEBRIGHTNESSPREST.md, _20.6-UPDATEBRIGHTNESSPRESET.md]:
-- keeps the On, Off and Previous ids and the on mode preset's level (D4).
-- Returns changed, on_level: on_level is the level when the preset is the
-- On preset (the driver stores it as Default On Brightness without echoing
-- PRESET_LEVEL, §7.5 dev.take_setting). A preset is On by its name, or by
-- the On id when it has no name of the three (a localised name, say).
-- REMOVED of the on mode's preset falls back to the On preset (§5).
function turnon.update_brightness_preset(t, params)
	params = params or {}
	local command = trim_lower(param(params, "COMMAND")) or "modified"
	local id = num(param_of(params, { "ID", "PRESET_ID" }))
	local name = trim_lower(param(params, "NAME"))
	local role = name and LEVEL_ROLES[name] and name or nil
	local level = num(param(params, "LEVEL"))
	level = valid_level(level) and level or nil
	local changed = false

	if command == "removed" then
		if id == nil then
			log.warn("UPDATE_BRIGHTNESS_PRESET REMOVED without a preset id; ignored")
			return false
		end
		if t.levels[id] ~= nil then
			t.levels[id] = nil
			changed = true
		end
		local presets_changed = false
		for _, field in pairs(LEVEL_ROLES) do
			if t.presets[field] == id then
				t.presets[field] = nil
				presets_changed = true
			end
		end
		if presets_changed then
			save_presets(t)
		end
		if t.brightness and t.brightness.id == id then
			t.brightness = nil
			save(t, KEYS.brightness, nil)
			log.info("the On Mode's brightness preset %s was removed; turning on to the On preset", tostring(id))
			changed = true
		end
		return changed or presets_changed, nil
	end
	if command ~= "added" and command ~= "modified" then
		log.warn("UPDATE_BRIGHTNESS_PRESET with an unknown COMMAND %q; ignored", tostring(command))
		return false
	end
	if id == nil and role == nil then
		log.warn("UPDATE_BRIGHTNESS_PRESET without a preset id or a known name; ignored")
		return false
	end

	if id ~= nil and role ~= nil and t.presets[LEVEL_ROLES[role]] ~= id then
		t.presets[LEVEL_ROLES[role]] = id
		save_presets(t)
		strip_previous_level(t)
		changed = true
	end
	if turnon.is_previous_preset(t, id) then
		-- The proxy moves the Previous preset at every off [verified: LV2 caps
		-- _7-brightnessonmodeprevious.md]; its level is not ours to keep (D6).
		level = nil
	end
	if id ~= nil and level ~= nil and t.levels[id] ~= level then
		t.levels[id] = level
		changed = true
	end
	local mode = t.brightness
	if mode and id ~= nil and mode.id == id and level ~= nil and mode.level ~= level then
		mode.level = level
		save(t, KEYS.brightness, mode)
		changed = true
	end
	local is_on = role == "on" or (role == nil and id ~= nil and id == on_id(t))
	return changed, is_on and level or nil
end

-- From the proxy: colour ----------------------------------------------------

-- The "Previous" colour preset, by its learned id.
local function is_color_previous(t, id)
	return id ~= nil and id == t.presets.color_previous_id
end

-- UPDATE_COLOR_ON_MODE [verified: LV2 cmds _20.4-UPDATECOLORONMODE.md] (D9,
-- D11). Which kind it is, [assumed until check T10] as §7.3 decides: fade
-- when the fade preset has an id and an x and y; else previous when the
-- preset is the learned "Previous" colour preset; else preset, with the on
-- colour from the x, y and mode given or, without them, looked up by id at
-- each turn-on. The page's origin texts contradict each other (F13); origins
-- are kept as numbers and only compared. Returns true when the mode changed.
function turnon.update_color_on_mode(t, params)
	params = params or {}
	local id, origin = num(param(params, "COLOR_PRESET_ID")), num(param(params, "COLOR_PRESET_ORIGIN"))
	local x, y = num(param(params, "COLOR_PRESET_COLOR_X")), num(param(params, "COLOR_PRESET_COLOR_Y"))
	local fade_id = num(param(params, "COLOR_FADE_PRESET_ID"))
	local fade_x, fade_y = num(param(params, "COLOR_FADE_PRESET_COLOR_X")), num(param(params, "COLOR_FADE_PRESET_COLOR_Y"))

	local mode = { id = id, origin = origin }
	if valid_xy(x, y) then
		mode.x, mode.y, mode.mode = x, y, mode_or_xy(param(params, "COLOR_PRESET_COLOR_MODE"))
	end
	if fade_id ~= nil and valid_xy(fade_x, fade_y) then
		mode.kind = FADE
		mode.fade_id, mode.fade_origin = fade_id, num(param(params, "COLOR_FADE_PRESET_ORIGIN"))
		mode.fade_x, mode.fade_y = fade_x, fade_y
		mode.fade_mode = mode_or_xy(param(params, "COLOR_FADE_PRESET_COLOR_MODE"))
	elseif is_color_previous(t, id) then
		-- The Previous colour moves with every off (F11) and Previous mode
		-- sends none (D11): its colour is not kept.
		mode.kind = PREVIOUS
		mode.x, mode.y, mode.mode = nil, nil, nil
	else
		mode.kind = PRESET
		if id == nil and mode.x == nil then
			log.warn("UPDATE_COLOR_ON_MODE without a preset id or a colour; mode kept")
			return false
		end
	end
	if same_flat(mode, t.color) then
		return false
	end
	t.color = mode
	save(t, KEYS.color, mode)
	return true
end

-- UPDATE_COLOR_PRESET {COMMAND, ID, NAME, COLOR_X, COLOR_Y, COLOR_MODE}
-- [verified: LV2 cmds _21-UPDATECOLORPRESET.md]: the On, Dim and Previous
-- colours and every other preset by id (D10, D16). It carries no origin. A
-- change to the preset the colour on mode names changes the mode's copy;
-- REMOVED of it falls back to the default, Preset On (as for brightness).
-- Returns true when something changed.
function turnon.update_color_preset(t, params)
	params = params or {}
	local command = trim_lower(param(params, "COMMAND")) or "modified"
	local id = num(param_of(params, { "ID", "PRESET_ID" }))
	local name = trim_lower(param(params, "NAME"))
	local role = name and COLOR_ROLES[name] and name or nil

	if command == "removed" then
		if id == nil and role == nil then
			log.warn("UPDATE_COLOR_PRESET REMOVED without a preset id or a known name; ignored")
			return false
		end
		local changed = false
		for i = #t.colors, 1, -1 do
			local c = t.colors[i]
			if (id ~= nil and c.id == id) or (id == nil and c.name == name) then
				table.remove(t.colors, i)
				changed = true
			end
		end
		local presets_changed = false
		for r, f in pairs(COLOR_ROLES) do
			if (id ~= nil and t.presets[f.id] == id) or (id == nil and r == role) then
				for _, k in pairs(f) do
					if t.presets[k] ~= nil then
						t.presets[k] = nil
						presets_changed = true
					end
				end
			end
		end
		if presets_changed then
			save_presets(t)
		end
		local m = t.color
		if m and id ~= nil and (m.id == id or (m.kind == FADE and m.fade_id == id)) then
			t.color = nil
			save(t, KEYS.color, nil)
			log.info("the colour on mode's preset %s was removed; turning on in the On colour", tostring(id))
			changed = true
		end
		return changed or presets_changed
	end
	if command ~= "added" and command ~= "modified" then
		log.warn("UPDATE_COLOR_PRESET with an unknown COMMAND %q; ignored", tostring(command))
		return false
	end
	if id == nil and role == nil then
		log.warn("UPDATE_COLOR_PRESET without a preset id or a known name; ignored")
		return false
	end

	local x, y = num(param(params, "COLOR_X")), num(param(params, "COLOR_Y"))
	local c = valid_xy(x, y) and color(x, y, mode_or_xy(param(params, "COLOR_MODE"))) or nil
	local changed = false
	if c then
		changed = remember_color(t, { id = id, name = name, x = c.x, y = c.y, mode = c.mode })
	end
	if role and learn_role(t, role, id, c) then
		save_presets(t)
		changed = true
	end
	if sync_on_mode(t, id, nil, c) then
		changed = true
	end
	return changed
end

-- GET_SETUP and variable 1300 (D19) ----------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function entity(name)
	if name:sub(1, 1) == "#" then
		local n = name:sub(2, 2) == "x" and tonumber(name:sub(3), 16) or tonumber(name:sub(2))
		if n and n >= 0 and n < 256 then
			return string.char(n)
		end
		return nil
	end
	return ENTITIES[name]
end

local function unescape(s)
	return (s:gsub("&(#?%w+);", entity))
end

-- The attributes of one start tag, names in lower case, values unescaped;
-- either quote.
local function attributes(s)
	local a = {}
	for key, _, value in s:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
		a[key:lower()] = unescape(value)
	end
	return a
end

-- The colour of a <color …> element: color_x / color_y, or from the colour
-- temperature when a CCT preset carries only that.
local function element_color(a)
	local x, y, mode = num(a.color_x), num(a.color_y), num(a.color_mode)
	if not valid_mode(mode) then
		mode = MODE_XY
	end
	if not valid_xy(x, y) and mode == MODE_CCT then
		local k = num(a.color_correlated_temperature)
		if k and k > 0 then
			x, y = C4:ColorCCTtoXY(k)
		end
	end
	if valid_xy(x, y) then
		return color(x, y, mode)
	end
	return nil
end

-- What GET_SETUP answered (F18) or variable 1300 holds (F20; its format is
-- not documented [assumed]: read with the same parser). Every element with a
-- name and color_x / color_y (or a colour temperature) is a colour preset
-- (category is read as its origin [assumed: the sample shows On and Off as
-- category 1, the named colours as 2]); every element with a name and a
-- level is a brightness preset. id is read when present (the sample has
-- none). Names On, Off, Previous (brightness) and On, Dim, Previous (colour)
-- are matched without case; what is learned refreshes the named presets and
-- the maps and never changes a mode or moves a light (D19, D26). Returns
-- colours, levels: how many colour presets with a usable colour, and how
-- many brightness presets, were found; malformed text gives 0, 0 and changes
-- nothing.
function turnon.take_setup(t, xml)
	if type(xml) ~= "string" then
		return 0, 0
	end
	if not xml:find("<", 1, true) and xml:find("&lt;", 1, true) then
		xml = unescape(xml) -- a variable holding escaped XML
	end
	local colors, levels = 0, 0
	local presets_changed = false
	local role_rank = {} -- a role learned in this text: 2 from category 1 or none, 1 from another
	for tag, body in xml:gmatch("<([%a_][%w_:%-]*)(%s[^<>]*)>") do
		local a = attributes(body)
		local name = trim_lower(a.name)
		local id = num(a.id) or num(a.preset_id)
		local has_color_attrs = a.color_x ~= nil or a.color_y ~= nil or a.color_correlated_temperature ~= nil
		if name and has_color_attrs then
			local origin = num(a.origin) or num(a.category)
			local c = element_color(a)
			if c then
				colors = colors + 1
				remember_color(t, { id = id, origin = origin, name = name, x = c.x, y = c.y, mode = c.mode })
			end
			local role = COLOR_ROLES[name] and name or nil
			local rank = (origin == nil or origin == 1) and 2 or 1
			if role and rank > (role_rank[role] or 0) then
				role_rank[role] = rank
				if learn_role(t, role, id, c) then
					presets_changed = true
				end
				sync_on_mode(t, id or t.presets[COLOR_ROLES[role].id], origin, c)
			elseif c and id then
				sync_on_mode(t, id, origin, c)
			end
		elseif name and a.level ~= nil and (tag:lower() == "level" or num(a.level)) then
			local level = num(a.level)
			if valid_level(level) then
				levels = levels + 1
				if id ~= nil and name ~= "previous" then
					t.levels[id] = level
				end
			end
			local field = LEVEL_ROLES[name]
			if field and id ~= nil and t.presets[field] ~= id then
				t.presets[field] = id
				presets_changed = true
			end
		end
	end
	if presets_changed then
		save_presets(t)
		strip_previous_level(t)
	end
	return colors, levels
end

-- Decisions: brightness -----------------------------------------------------

local function brightness_kind(t)
	local m = t.brightness
	if m and turnon.is_previous_preset(t, m.id) then
		return PREVIOUS
	end
	return PRESET
end

local function color_kind(t)
	return t.color and t.color.kind or PRESET
end

-- The modes in force, for logs and properties: brightness, colour.
function turnon.modes(t)
	return brightness_kind(t), color_kind(t)
end

-- The Default On Brightness (the On preset's level), 100 when unknown.
local function preset_level(ctx)
	local p = num(ctx.preset)
	if p and p >= 1 and p <= 100 then
		return p
	end
	return 100
end

local function mode_id(t)
	return t.brightness and t.brightness.id or on_id(t)
end

-- The level of the on mode's preset in Preset mode: the Default On
-- Brightness for the On preset (D3), else the level the proxy gave for the
-- preset; one unknown or below 1 reads as the Default On Brightness.
local function mode_level(t, ctx)
	local m = t.brightness
	if not m or m.id == on_id(t) then
		return preset_level(ctx)
	end
	local level = m.level or t.levels[m.id]
	if level and level >= 1 then
		return math.min(level, 100)
	end
	return preset_level(ctx)
end

-- Previous on a single lamp (D6): the last non-zero level reported to the
-- proxy, else Hue's remembered level, else the Default On Brightness.
local function previous_level(ctx)
	local last = num(ctx.last_on)
	if last and last > 0 then
		return math.min(last, 100)
	end
	local cached = num(ctx.cached)
	if cached and cached > 0 then
		-- Hue reports its Zigbee level as a decimal (20.16 for 20): a whole percent.
		return clamp(round(cached), 1, 100)
	end
	return preset_level(ctx)
end

-- A Control4 turn-on from off (D5, D6). ctx = { preset = Default On
-- Brightness, group = zone or room light, last_on = last_on_level or nil,
-- cached = st.brightness or nil }. Returns { level, preset_id, native }:
-- native means HUE_SET {on = "true"} without a brightness, so Hue brings
-- every lamp of the zone or room back at its own level; level is then what
-- CHANGING names as target.
function turnon.turn_on(t, ctx)
	ctx = ctx or {}
	if brightness_kind(t) == PREVIOUS then
		return { level = previous_level(ctx), preset_id = t.brightness.id, native = ctx.group and true or false }
	end
	return { level = mode_level(t, ctx), preset_id = mode_id(t), native = false }
end

-- A top tap or ON while the light is on (D5): the on mode preset in Preset
-- mode, the On preset (Default On Brightness) in Previous mode, which has
-- nothing to restore while on.
function turnon.while_on(t, ctx)
	ctx = ctx or {}
	if brightness_kind(t) == PREVIOUS then
		return { level = preset_level(ctx), preset_id = on_id(t) }
	end
	return { level = mode_level(t, ctx), preset_id = mode_id(t) }
end

-- Decisions: colour -----------------------------------------------------------

-- D13. The colour between dim (at 1 %) and on (at top and above) for a
-- level: f = (level - 1) / (top - 1), clamped to 0..1 (1 when top <= 1).
-- Two colour temperatures blend linearly in Kelvin, as the UPDATE_COLOR_PRESET
-- page's example (On 4000 K, Dim 2000 K, Default On 80 %: 3000 K at 40 %)
-- and the best practice's warm dim do, and give a colour temperature;
-- anything else blends linearly in x and y as the fade page writes it, and
-- gives full colour. Dim equal to On (Composer's Dim checkbox off, which
-- copies On into Dim) gives On at every level. At either end the result is
-- that preset itself, id and origin included.
function turnon.blend(dim, on, level, top)
	if not on then
		return nil
	end
	if not dim or same_color(dim, on) then
		return copy(on)
	end
	level, top = num(level) or 100, num(top) or 100
	local f = 1
	if top > 1 then
		f = clamp((level - 1) / (top - 1), 0, 1)
	end
	if f >= 1 then
		return copy(on)
	elseif f <= 0 then
		return copy(dim)
	end
	if on.mode == MODE_CCT and dim.mode == MODE_CCT then
		local k_on, k_dim = num(C4:ColorXYtoCCT(on.x, on.y)), num(C4:ColorXYtoCCT(dim.x, dim.y))
		if k_on and k_dim and k_on > 0 and k_dim > 0 then
			local x, y = C4:ColorCCTtoXY(k_dim + (k_on - k_dim) * f)
			x, y = num(x), num(y)
			if valid_xy(x, y) then
				return color(x, y, MODE_CCT)
			end
		end
	end
	return color(dim.x + (on.x - dim.x) * f, dim.y + (on.y - dim.y) * f, MODE_XY)
end

-- The on colour of the colour on mode, or nil: the colour the mode carries,
-- else its preset looked up by id, else the proxy's On colour preset (D10:
-- the default mode, and the mandatory On preset the proxy always has, F14).
-- nil in Previous mode and while no On colour is known at all (D10: unknown
-- means unchanged).
local function resolve_on(t)
	local m = t.color
	if not m then
		return named(t, "on")
	end
	if m.kind == PREVIOUS then
		return nil
	end
	if m.x then
		return color(m.x, m.y, m.mode, m.id, m.origin)
	end
	return (m.id and turnon.color_for_preset(t, m.id, m.origin)) or named(t, "on")
end

-- The Dim colour: the fade preset in Fade mode, else the proxy's Dim colour
-- preset; nil while unknown.
local function resolve_dim(t)
	local m = t.color
	if m and m.kind == FADE then
		return color(m.fade_x, m.fade_y, m.fade_mode, m.fade_id, m.fade_origin)
	end
	return named(t, "dim")
end

-- No colour at all: ctx says the bulb has neither colour nor colour
-- temperature (light.state's has_color / has_cct). Absent fields read as
-- able: light.state's mapping drops colour for a white-only bulb anyway (D18).
local function no_abilities(ctx)
	return ctx.has_color == false and ctx.has_cct == false
end

-- The top of a Preset blend (D13): the level of the on mode's preset, where
-- the light turns on in the On colour (L32), which is the Default On
-- Brightness for the On preset and in Previous mode (F14, L33).
local function top_level(t, ctx)
	return turnon.while_on(t, ctx).level
end

-- The colour a Control4 turn-on to `level` carries (D10, D11, D13): Preset
-- blends On toward Dim for the level (the On colour at the on mode's level),
-- Fade gives the fade formula, Previous none (Hue keeps its last colour, and
-- a zone each lamp's own). nil without an On colour or without abilities.
-- A colour stored while off wins over this one in the driver (D11).
function turnon.on_color(t, level, ctx)
	ctx = ctx or {}
	level = num(level)
	if no_abilities(ctx) or not level or level <= 0 then
		return nil
	end
	local kind = color_kind(t)
	if kind == PREVIOUS then
		return nil
	end
	local on = resolve_on(t)
	if not on then
		return nil
	end
	if kind == FADE then
		return turnon.blend(resolve_dim(t), on, level, 100)
	end
	return turnon.blend(resolve_dim(t), on, level, top_level(t, ctx))
end

-- The colour a Control4 turn-off with `rate` ms carries (D12): the Dim
-- colour in Preset and Fade modes when the rate is above 0. nil for an
-- instant off (guidelines departure D16), in Previous mode (the Dim colour
-- would become the remembered colour, F11) and while no Dim colour is known.
-- The driver never asks during or after a hold.
function turnon.off_color(t, rate)
	rate = num(rate)
	if not rate or rate <= 0 or color_kind(t) == PREVIOUS then
		return nil
	end
	return resolve_dim(t)
end

-- The colour a Control4 brightness target above 0 carries while the light is
-- on (D14, D15): in Fade mode always the formula; in Preset mode the blend
-- while one runs; else nil.
function turnon.level_color(t, level, ctx)
	ctx = ctx or {}
	level = num(level)
	if no_abilities(ctx) or not level or level <= 0 then
		return nil
	end
	local kind = color_kind(t)
	if kind == FADE then
		return turnon.blend(resolve_dim(t), resolve_on(t), level, 100)
	elseif kind == PRESET and t.blending then
		return turnon.blend(resolve_dim(t), resolve_on(t), level, top_level(t, ctx))
	end
	return nil
end

-- Whether a SET_COLOR_TARGET is the on colour (D16): its preset id (and
-- origin, when both are known) is the colour on mode's preset, or its xy is
-- within MATCH_XY, in the same mode, of the on colour. The proxy may send
-- the on colour itself around a turn-on; that must not end a blend.
function turnon.is_on_color(t, x, y, mode, id, origin)
	id, origin = num(id), num(origin)
	local m = t.color
	local on_preset, on_origin
	if m then
		on_preset, on_origin = m.id, m.origin
	else
		on_preset = t.presets.color_on_id
	end
	if id ~= nil and on_preset ~= nil and id == on_preset and origin_lenient(origin, on_origin) then
		return true
	end
	local on = resolve_on(t)
	x, y = num(x), num(y)
	if not (on and x and y) then
		return false
	end
	return same_color(color(x, y, mode_or_xy(mode)), on)
end

-- Blend state (D14) ---------------------------------------------------------

-- A Control4 turn-on went out; carried_on_color says whether it carried the
-- on colour (true) or a colour stored while off won (false, D11).
function turnon.started(t, carried_on_color)
	t.blending = carried_on_color and true or false
end

-- An explicit colour went out (not the on colour, D16): a Preset blend ends.
-- Fade needs nothing: the next brightness target applies the formula again.
function turnon.explicit_color(t)
	t.blending = false
end

-- A colour change made outside Control4 (the Hue app, a Hue scene, §5).
function turnon.foreign_color(t)
	t.blending = false
end

-- The light is off.
function turnon.ended(t)
	t.blending = false
end

-- Whether a Preset blend runs (D14).
function turnon.is_blending(t)
	return t.blending
end

return turnon
