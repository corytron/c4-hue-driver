-- mDNS for Hue bridges (#334, docs/simplify-actions-design.md §3.4, D5):
-- the shared query and parser (common/mdns.lua, which documents the format,
-- the bounds and what the house's Bridge Pro sent) configured for
-- _hue._tcp.local (#514, docs/hdmi-sync-stage1-design.md §3). This module
-- is that instance itself. bridge/discovery.lua sends the query and hands
-- every datagram it receives to mdns.read.
--
-- A Hue bridge answers with TXT bridgeid (16 hex digits, upper case on the
-- Bridge Pro; config.normalise_bridge_id lower-cases it) and modelid
-- [verified: hardware, 2026-11-05, #334]. The addresses a candidate may
-- have are those of the controller's own kind of network: what the sweep
-- may search (bridge/sweep.lua searchable: private and documentation
-- networks) and link-local (security review 2026-11-13, N-3, #490).
--
-- The fields and functions, as before the move: GROUP, PORT, SERVICE,
-- MAX_PACKET, MAX_RECORDS, MAX_JUMPS, MAX_NAME; query(id), parse(data),
-- candidates(msg), read(data), usable_address(ip); and, new with the move,
-- MAX_ANSWERS and window(query_id, opts).

local config = require("bridge.config")
local sweep = require("bridge.sweep")

return require("common.mdns").new({
	service = "_hue._tcp.local",
	config = config,
	sweep = sweep,
	txt = { id = "bridgeid", model = "modelid" },
	normalise_id = function(raw)
		return config.normalise_bridge_id(raw)
	end,
})
