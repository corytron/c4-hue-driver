-- The DYNAMIC_CAPABILITIES_CHANGED notify for one light. The proxy docs
-- require supports_color and supports_color_correlated_temperature in a
-- single notify (otherwise colour presets get their mode rewritten), and
-- the CCT bounds in Kelvin as multiples of 10 within 500..20000.

local caps = {}

local KELVIN_MIN, KELVIN_MAX = 500, 20000

local function kelvin(mirek)
	return 1000000 / mirek
end

-- Round inward to a multiple of 10 so the proxy never offers a temperature
-- the bulb cannot reach; the few Kelvin lost are invisible.
local function tens(k, up)
	k = up and math.ceil(k / 10) * 10 or math.floor(k / 10) * 10
	return math.max(KELVIN_MIN, math.min(KELVIN_MAX, k))
end

-- Params for one DYNAMIC_CAPABILITIES_CHANGED, from a light.state table.
-- Booleans are the "true"/"false" strings the notify expects; the CCT
-- bounds are numbers and present only when the bulb supports CCT.
function caps.params(st)
	local p = {
		supports_color = st.has_color and "true" or "false",
		supports_color_correlated_temperature = st.has_cct and "true" or "false",
	}
	if st.has_cct and (st.mirek_min or 0) > 0 and (st.mirek_max or 0) > 0 then
		-- Hue counts in mirek (warm = large), the proxy in Kelvin (warm = small).
		local lo, hi = tens(kelvin(st.mirek_max), true), tens(kelvin(st.mirek_min), false)
		if lo > hi then
			-- A fixed white point: both bounds the same, as the docs ask.
			lo = math.floor(kelvin(st.mirek_min) / 10 + 0.5) * 10
			hi = lo
		end
		p.color_correlated_temperature_min = lo
		p.color_correlated_temperature_max = hi
	end
	return p
end

return caps
