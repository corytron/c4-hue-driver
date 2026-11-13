-- The Hue Bridge's link as the device drivers read it (#428,
-- docs/offline-design.md §6.1, §6.3 and §6.6): the parameters of
-- HUE_BRIDGE_LINK, which the bridge sends to every Hue device at the change
-- to offline (after 300 s of trouble, D1), at the change back online, at a
-- reason change while offline (D3), at the first evaluation of a run and
-- first in every hello answer (D4); and the Status text a device shows while
-- the bridge is offline (D5, D14). Pure: no state, no C4 call. What a device
-- was told is the device's to keep (common/device.lua for the Hue Light and
-- the Hue Scene; hue_motion keeps and persists its own).
--
--   local link = require("common.link")
--   local l = link.parse(params) -- { offline = false }, or
--                                -- { offline = true, reason = "not_answering", since = 1762696920 },
--                                -- or nil for a message to ignore (an unknown state)
--   link.text(l, os.time())      -- "Hue Bridge not answering since 14:02"; nil while online
--   link.clock(since_s, now_s)   -- "14:02" on the day of now_s, "10-26 14:02" on another day

local num = require("common.num")

local link = {}

-- §6.1's reasons, each with the words of its §6.3 Status text: "Hue Bridge
-- <phrase> since <clock><tail>". At most 60 characters with the longer clock
-- of another day (tests/spec/common_link_spec.lua checks every one).
local TEXTS = {
	not_answering = { phrase = "not answering", tail = "" },
	other_bridge = { phrase = "not at its address", tail = "" },
	key_rejected = { phrase = "refuses the pairing", tail = "" },
	blocked = { phrase = "not usable", tail = " (see its Status)" },
	not_paired = { phrase = "not paired", tail = "" },
}

-- An offline link whose reason this build does not know (a later bridge's,
-- or none) is still offline: it reads as the plainest one, "not answering".
local FALLBACK_REASON = "not_answering"

-- `since` is epoch seconds as a decimal string (§6.1). Anything that is not a
-- positive, finite time os.date takes on every controller (common/num.lua's
-- num.timestamp: before 2100; until #487 the bound was 2^32, 2106) is
-- dropped: the text then names no time.
local function seconds(value)
	local n = num.timestamp(value)
	if not n or n <= 0 then
		return nil
	end
	return math.floor(n)
end

-- HUE_BRIDGE_LINK's params -> { offline = false } for "online";
-- { offline = true, reason, since } for "offline", the reason one of §6.1's
-- (an unknown or missing one taken as not_answering) and since in whole
-- epoch seconds or nil; nil for anything else, which the device ignores and
-- logs once (§6.1).
function link.parse(params)
	if type(params) ~= "table" then
		return nil
	end
	local state = params.state
	if state == "online" then
		return { offline = false }
	elseif state ~= "offline" then
		return nil
	end
	local reason = params.reason
	if type(reason) ~= "string" or not TEXTS[reason] then
		reason = FALLBACK_REASON
	end
	return { offline = true, reason = reason, since = seconds(params.since) }
end

-- "14:02" when since_s falls on the controller's day of now_s (os.time() when
-- nil), "10-26 14:02" otherwise: the rule of the bridge's away:clock
-- (src/hue_bridge/bridge/away.lua), in seconds (§6.3). Both go through
-- common/num.lua's num.date (#487): a time os.date cannot take reads "?",
-- never an error.
function link.clock(since_s, now_s)
	local now = num.timestamp(now_s) or os.time()
	if num.date("%Y-%m-%d", since_s) == num.date("%Y-%m-%d", now) then
		return num.date("%H:%M", since_s)
	end
	return num.date("%m-%d %H:%M", since_s)
end

-- §6.3's Status text for an offline link, computed from since at every call,
-- so a refresh after midnight names the day; nil for an online or no link.
-- Without a since it names no time ("Hue Bridge not answering").
function link.text(l, now_s)
	if type(l) ~= "table" or not l.offline then
		return nil
	end
	local words = TEXTS[l.reason] or TEXTS[FALLBACK_REASON]
	local s = "Hue Bridge " .. words.phrase
	local since = seconds(l.since)
	if since then
		s = s .. " since " .. link.clock(since, now_s)
	end
	return s .. words.tail
end

return link
