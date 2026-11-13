-- The cached Hue state of one light, and the mapping both ways between it
-- and what the light_v2 proxy speaks. Pure Lua except for the colour
-- conversions, which go through C4:ColorCCTtoXY / C4:ColorXYtoCCT (3.3.0+).
--
-- The same device can stand for a Hue zone or room driven through its
-- grouped_light (kind "group", docs/zone-light-design.md §2); the bridge
-- reports a group's on/off, average brightness and a member's colour in the
-- same HUE_STATE fields, so only the identity part knows the difference.
--
-- Every value in an inter-driver message is a string (docs/lights-design.md,
-- "Messages"), so the parsers accept strings and numbers alike and the
-- HUE_SET builders hand back strings.
--
-- The cache holds what the proxy has been told the light is doing. Normally
-- that is what the bridge last reported; after a fallback (a target the
-- bridge never confirmed) the driver applies the sent HUE_SET to it, so the
-- next real report differs from it and corrects the proxy.

local device = require("common.device")
local num = require("common.num")

local state = {}

-- light_v2 colour modes (LIGHT_COLOR_*_COLOR_MODE).
state.MODE_XY = 0
state.MODE_CCT = 1

-- Hue's widest CCT range, used until HUE_CONFIGURE says what this bulb does.
local DEFAULT_MIREK_MIN, DEFAULT_MIREK_MAX = 153, 500

-- #486 (C-3, D-4): the mirek values taken from the bridge, the bulb's limits
-- included, are finite and clamped to 50 to 2000, the 500 to 20 000 K the
-- proxy's CCT bounds can say (light.caps); a pair of limits the wrong way
-- round reads as the default range, so a colour sent is always within the
-- light's own limits, else 153 to 500.
local MIREK_LO, MIREK_HI = 50, 2000

-- What the device stands for: a Hue light, or a Hue zone or room (its
-- grouped_light). A configure names the kind; a device never told one is a
-- light, as every light imported before zone lights existed.
state.KIND_LIGHT = "light"
state.KIND_GROUP = "group"
state.KINDS = { [state.KIND_LIGHT] = true, [state.KIND_GROUP] = true }

function state.new()
	return {
		rid = nil,            -- Hue light (or zone/room) resource id; the key in every message
		kind = nil,           -- state.KIND_LIGHT / KIND_GROUP; nil until told (reads as a light)
		group_type = nil,     -- group: "zone" / "room", nil while unknown
		light_count = nil,    -- group: lights in the zone or room, nil while unknown
		no_lights = false,    -- group: no lights, so no grouped_light to drive (Decision 11)
		name = nil,
		model = nil,          -- "Hue color lamp"; for a group "Hue zone" / "Hue room"
		hue_room = nil,       -- Hue room name (for a group: its own label), nil while unknown or in no room
		id_v1 = nil,          -- Hue's v1 id ("/lights/12", "12", "/groups/2"), nil while unknown
		gone = false,         -- the bridge reports the rid is no longer on it
		gone_since = nil,     -- unix time the bridge entered that state, when it said
		forgotten = nil,      -- { name } after HUE_FORGOTTEN, until the next HUE_CONFIGURE
		has_color = false,
		has_cct = false,
		mirek_min = DEFAULT_MIREK_MIN,
		mirek_max = DEFAULT_MIREK_MAX,
		min_dim = nil,        -- Hue's lowest brightness percent, informational here
		on = nil,             -- nil until the bridge has reported
		brightness = nil,     -- Hue percent; Hue keeps it while the light is off
		x = nil,
		y = nil,
		mirek = nil,
		color_mode = nil,     -- "xy" or "ct"
		online = nil,
		pending_color = nil,  -- HUE_SET colour fields kept while off, sent with the next turn-on
	}
end

-- Parsing and formatting ---------------------------------------------------

-- A string param or nil when absent or empty (SendToDevice drops empty
-- values, so "" never arrives; an absent key is the same thing), and a
-- boolean from "true"/"1" and "false"/"0": the parsers both device drivers
-- use (common/device.lua).
local text, to_bool = device.text, device.to_bool

-- A finite number, else nil: NaN and the infinities, which tonumber takes
-- from "nan" and "inf", never reach the cache or a HUE_SET (#486,
-- common/num.lua).
local to_num = num.finite

local function round(n)
	return math.floor(n + 0.5)
end

local function clamp(n, lo, hi)
	return math.max(lo, math.min(hi, n))
end

-- Compact decimal text: "50", "50.5", "0.3127". Four decimals keep xy exact
-- to what the bridge stores.
local function str(n)
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	return (string.format("%.4f", n):gsub("0+$", ""))
end

-- Bridge -> cache ----------------------------------------------------------

-- Merge a HUE_CONFIGURE message: identity, lifecycle and capabilities. The
-- bridge builds every configure from its whole registry entry, so the
-- lifecycle fields (hue_room, id_v1, state, gone_since, and a group's
-- group_type, light_count, no_lights) are taken as sent and reset when
-- absent: a light that left its room, or a bridge build that does not send
-- them yet, both read as "none". A configure also ends a forgotten state:
-- the bridge knows the light again.
--
-- The kind sticks: a configure that names none leaves what the device is
-- (the bridge's lights module names none, and so does an older bridge that
-- answers a zone light's hello as if it were a light, docs/zone-light-design.md
-- §7 Q11); an unknown kind is ignored. Re-linking across kinds is refused on
-- the bridge, so a kind only ever changes when a configure says so.
function state.configure(st, params)
	params = params or {}
	if params.rid and params.rid ~= "" then
		st.rid = params.rid
	end
	local kind = text(params.kind)
	if kind and state.KINDS[kind] then
		st.kind = kind
	end
	st.group_type = text(params.group_type)
	st.light_count = num.within(params.light_count, 0, nil)
	st.no_lights = to_bool(params.no_lights) == true
	if st.no_lights then
		-- Nothing in the group can be lit and there is no grouped_light to
		-- say otherwise: the proxy and the keypad LEDs see off until the
		-- group is refilled and the bridge reports again.
		st.on = false
	end
	st.name = params.name or st.name
	st.model = params.model or st.model
	st.hue_room = text(params.hue_room)
	st.id_v1 = text(params.id_v1)
	st.gone = params.state == "gone"
	-- #487 D-6: a time os.date takes on every controller, else none.
	st.gone_since = st.gone and num.timestamp(params.gone_since) or nil
	st.forgotten = nil
	local b = to_bool(params.has_color)
	if b ~= nil then st.has_color = b end
	b = to_bool(params.has_cct)
	if b ~= nil then st.has_cct = b end
	st.mirek_min = num.clamp(params.mirek_min, MIREK_LO, MIREK_HI) or st.mirek_min
	st.mirek_max = num.clamp(params.mirek_max, MIREK_LO, MIREK_HI) or st.mirek_max
	if st.mirek_min > st.mirek_max then
		st.mirek_min, st.mirek_max = DEFAULT_MIREK_MIN, DEFAULT_MIREK_MAX
	end
	st.min_dim = num.within(params.min_dim, 0, 100) or st.min_dim
end

-- A zone or room device (docs/zone-light-design.md §2); false for a light
-- and for a device never told its kind.
function state.is_group(st)
	return st.kind == state.KIND_GROUP
end

-- What the proxy would be told right now; compared before and after a merge.
local function proxy_view(st)
	local x, y, mode = state.to_proxy_color(st)
	return { brightness = state.to_proxy_brightness(st), x = x, y = y, mode = mode, online = st.online }
end

-- Merge a HUE_STATE message (or a HUE_SET the driver assumes went through).
-- Returns { brightness = bool, color = bool, online = bool }: which of the
-- proxy-facing values differ from before.
function state.apply_hue(st, params)
	params = params or {}
	local before = proxy_view(st)
	local color_forced = false

	local on = to_bool(params.on)
	if on ~= nil then
		-- Turned on by something other than this driver (our own turn-on
		-- clears the pending colour first): the colour kept for it is void,
		-- and the proxy must hear the light's real colour again.
		if on and st.on ~= true and st.pending_color then
			st.pending_color = nil
			color_forced = true
		end
		st.on = on
	end
	-- #486: a finite level, clamped to 0..100, and mirek (MIREK_LO..MIREK_HI);
	-- xy within 0..1. Anything else leaves the field as it was.
	st.brightness = num.clamp(params.brightness, 0, 100) or st.brightness

	local x, y = num.within(params.x, 0, 1), num.within(params.y, 0, 1)
	local mirek = num.clamp(params.mirek, MIREK_LO, MIREK_HI)
	if x and y then
		st.x, st.y = x, y
	end
	if mirek then
		st.mirek = mirek
	end
	if params.color_mode == "xy" or params.color_mode == "ct" then
		st.color_mode = params.color_mode
	elseif mirek and not (x and y) then
		st.color_mode = "ct"
	elseif x and y and not mirek then
		st.color_mode = "xy"
	end

	local online = to_bool(params.online)
	if online ~= nil then
		st.online = online
	end

	local after = proxy_view(st)
	return {
		brightness = before.brightness ~= after.brightness,
		color = color_forced or before.x ~= after.x or before.y ~= after.y or before.mode ~= after.mode,
		online = before.online ~= after.online,
	}
end

-- Cache -> proxy -----------------------------------------------------------

-- LIGHT_BRIGHTNESS_CURRENT, or nil while the bridge has not reported yet.
-- Off is 0; on without a dimming value (a plug, an undimmable bulb) is 100.
-- Always a whole percent: Hue reports its Zigbee level as a decimal (a
-- requested 20 comes back as 20.16), and the proxy showed such a value as
-- 0 %/off while the lamp was on. Never 0 while on, so Hue's lowest level
-- (min_dim_level, below 0.5 on some bulbs) does not read as off either.
function state.to_proxy_brightness(st)
	if st.on == nil then
		return nil
	end
	if not st.on then
		return 0
	end
	return clamp(round(st.brightness or 100), 1, 100)
end

-- The last mirek converted and its xy: a ct-mode HUE_STATE asks for the same
-- conversion up to three times (the view before and after the merge, then
-- the report), each a call into the controller; this keeps it to one
-- (docs/reviews/efficiency-2026-10-24.md R10). The xy is a function of the
-- mirek alone, so the entry never goes stale; a new mirek replaces it.
local memo_mirek, memo_x, memo_y = nil, nil, nil

-- x, y, mode for LIGHT_COLOR_*; nil while no colour is known. In "ct" mode
-- the xy is derived from the mirek, so the proxy sees the white point the
-- controller's own conversion gives for that temperature.
function state.to_proxy_color(st)
	if st.color_mode == "ct" and st.mirek and st.mirek > 0 then
		if st.mirek ~= memo_mirek then
			memo_x, memo_y = C4:ColorCCTtoXY(1000000 / st.mirek)
			memo_mirek = st.mirek
		end
		return memo_x, memo_y, state.MODE_CCT
	end
	if st.x and st.y then
		return st.x, st.y, state.MODE_XY
	end
	return nil
end

-- Proxy -> HUE_SET ---------------------------------------------------------

local function copy_into(params, fields)
	for k, v in pairs(fields) do
		params[k] = v
	end
end

-- The HUE_SET colour fields for a proxy colour (x, y, light_v2 mode): a
-- mirek clamped to the bulb's range for a CCT colour on a bulb with CCT, and
-- for any colour on a bulb with CCT alone; xy passed through on a colour
-- bulb (the bridge clamps it to the gamut). nil plus why instead: "no xy",
-- or "unsupported" (a white-only bulb, which never gets colour: #427 D18).
-- Every colour the driver sends goes through here: a SET_COLOR_TARGET, the
-- On and Dim colours of a turn-on or turn-off, a blend (#427 D11-D15).
function state.color_fields(st, x, y, mode)
	x, y = to_num(x), to_num(y)
	mode = to_num(mode) or state.MODE_XY
	if not (x and y) then
		return nil, "no xy"
	end
	if st.has_cct and (mode == state.MODE_CCT or not st.has_color) then
		local kelvin = C4:ColorXYtoCCT(x, y)
		if not kelvin or kelvin <= 0 then
			kelvin = 1 -- off the locus entirely; clamps to the warmest the bulb has
		end
		return { mirek = str(clamp(round(1000000 / kelvin), st.mirek_min, st.mirek_max)) }
	elseif st.has_color then
		return { x = str(x), y = str(y) }
	end
	return nil, "unsupported"
end

-- SET_BRIGHTNESS_TARGET -> HUE_SET params. Target 0 is off; anything else is
-- on at that brightness (the bridge clamps to the bulb's minimum).
-- `opts` (#429, #427):
--   color   HUE_SET colour fields (state.color_fields) to send along: the
--           On colour of a turn-on, the Dim colour of a timed turn-off, a
--           blend (D11-D15). A colour stored while the light was off wins
--           over it on a turn-on (D11) and is forgotten here; a turn-off
--           never spends a stored colour.
--   native  on only, no brightness: a zone or room light's Previous
--           turn-on, where Hue brings every lamp back at its own level (D6).
-- Returns the params and which colour went out: "stored", "given" or nil.
function state.from_brightness_target(st, target, rate, opts)
	opts = opts or {}
	target = to_num(target) or 0
	local params = { rid = st.rid, rate = str(to_num(rate) or 0) }
	if target <= 0 then
		params.on = "false"
		if opts.color then
			copy_into(params, opts.color)
			return params, "given"
		end
		return params, nil
	end
	params.on = "true"
	if not opts.native then
		params.brightness = str(target)
	end
	if st.pending_color then
		copy_into(params, st.pending_color)
		st.pending_color = nil
		return params, "stored"
	elseif opts.color then
		copy_into(params, opts.color)
		return params, "given"
	end
	return params, nil
end

-- SET_COLOR_TARGET -> HUE_SET params, mapped by state.color_fields. Returns
-- nil plus a reason instead when nothing is to be sent: "stored" (light
-- off: kept for the next turn-on, the light_v2 best practice), or
-- color_fields' "unsupported" or "no xy". `opts.on_soon` (#427 D17): a
-- Control4 turn-on of this light is under way whose report has not come
-- yet, so the cache still says off; the colour goes out instead of being
-- stored, and the bridge usually folds it into the turn-on's request.
-- Until 1.5 it was stored, and the report of the turn-on then voided it
-- (apply_hue): brightness then colour lost the colour.
function state.from_color_target(st, x, y, mode, rate, opts)
	local fields, why = state.color_fields(st, x, y, mode)
	if not fields then
		return nil, why
	end
	if st.on == false and not (opts and opts.on_soon) then
		st.pending_color = fields
		return nil, "stored"
	end
	-- Sent now: a colour stored before is superseded by this one.
	st.pending_color = nil
	local params = { rid = st.rid, rate = str(to_num(rate) or 0) }
	copy_into(params, fields)
	return params
end

return state
