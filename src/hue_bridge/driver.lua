-- Hue Bridge driver: owns the connection to one Hue bridge and serves the
-- Hue Light drivers bound to it: pairing, the event stream (on its own
-- address spelling, see choose_stream_address), the light registry and
-- import, state fan-out to the light drivers, and the coalesced command
-- queue. docs/lights-design.md is the contract with the light driver.

local log = require("common.log")
local dispatch = require("common.dispatch")
local config = require("bridge.config")
local altaddr = require("bridge.altaddr")
local http = require("bridge.http")
local credentials = require("bridge.credentials")
local pairing = require("bridge.pairing")
local stream = require("bridge.stream")
local netstream = require("bridge.netstream")
local lights_mod = require("bridge.lights")
local scenes_mod = require("bridge.scenes")
local zone_lights_mod = require("bridge.zone_lights")
local motion_mod = require("bridge.motion")
local motion_diag_mod = require("bridge.motion_diag")
local commands = require("bridge.commands")
local netcheck = require("bridge.netcheck")
local project_mod = require("bridge.project")
local util = require("bridge.util")
local housekeeping = require("bridge.housekeeping")
local discovery_mod = require("bridge.discovery")
local actions_mod = require("bridge.actions")
local names_mod = require("bridge.names")
local group_hold_mod = require("bridge.group_hold")
local rows_mod = require("bridge.rows")
local bridges_found_mod = require("bridge.bridges_found")
local away_mod = require("bridge.away")
local link_mod = require("bridge.link")
local identity_mod = require("bridge.identity")
local tasks_mod = require("bridge.tasks")
local netgate_mod = require("bridge.netgate")
local pair_window_mod = require("bridge.pair_window")

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the
-- driver fetches its code from a server on the LAN and reloads itself.
-- See docs/dev-loop.md. Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	-- A missing module reads "not found" under busted and "An unknown error
	-- occurred" on the controller [hardware 2026-10-24].
	local reason = tostring(devloop):lower()
	if not (reason:find("not found", 1, true) or reason:find("unknown error", 1, true)) then
		print("[ERROR] Hue Bridge: dev loop failed to load: " .. tostring(devloop))
	end
	devloop = nil
end

-- The development handlers (the dev loop's property, the request and project
-- probes, the connection experiment, the CA pinning check, ...) live in
-- bridge/devtools.lua, which tools/build.sh ships in dev builds only; a
-- release build carries none of that code [code analysis 2026-10-22, M4].
local devtools = devloop and require("bridge.devtools") or nil

local state = {
	ip = nil,            -- validated Bridge IP Address property
	creds = nil,         -- what pairing produced; loaded from the store at startup
	stream = nil,        -- bridge.stream instance, created in OnDriverLateInit
	stream_ip = nil,     -- spelling of the bridge address the stream uses, see choose_stream_address
	stream_family = nil, -- spellings the stream rotates over (altaddr.stream_family); nil in single-queue mode
	last_stream_ip = nil, -- spelling of the previous stream transfer, so the next one differs
	lights = nil,        -- bridge.lights registry, created in OnDriverLateInit
	scenes = nil,        -- bridge.scenes (docs/scenes-design.md), created in OnDriverLateInit
	zone_lights = nil,   -- bridge.zone_lights (docs/zone-light-design.md), created in OnDriverLateInit
	motion = nil,        -- bridge.motion (docs/motion-design.md), created in OnDriverLateInit
	motion_diag = nil,   -- bridge.motion_diag, Log Motion Diagnostics
	queue = nil,         -- bridge.commands coalescer, created in OnDriverLateInit
	group_queue = nil,   -- the same for grouped_light (scene OFF)
	group_hold = nil,    -- bridge.group_hold (docs/group-hold-design.md, #249), created in OnDriverLateInit
	late_init_done = false,
	destroyed = false,   -- OnDriverDestroyed ran: what this code still has in flight starts nothing
	address_gen = 0,     -- bumped at every Bridge IP Address change; late results of an older one are ignored
	key_rejected = nil,  -- HTTP code (401/403) once the bridge refused the key; cleared by Pair Bridge or a new address
	tls_verdict = nil,   -- the TLS self-check's answer for this start and address (bridge/tlscheck.lua)
	net_check = nil,     -- the network connection's TLS check for this run (net_gate): pinned, accepted, not_pinned
	identity_ok = nil,  -- true once the identity check (with the TLS check) passed for this address; false when it failed
	identity_text = nil, -- the Status text of the identity check's failure, kept for refresh_status (#236)
	attention_sent = nil, -- the Attention text last written, so an unchanged one is not written again
	limits_sent = {},    -- light rid -> the limits last given to the command queue
	stream_started_at = nil, -- "MM-DD HH:MM" of the stream's first connect since the driver started
	stream_abandoned = {}, -- abandoned stream transfers that may still be open, across stream rebuilds (stream.lua)
	-- The outage and "away" measures (bridge/away.lua; ms since the epoch, nil when the condition does not hold):
	stream_down_ms = nil, -- since when the event stream is not connected
	unreachable_ms = nil, -- since when the identity check finds nothing answering at this address
	away_ms = nil,        -- since when the identity check fails at this address (nothing, or another bridge)
	away_other = nil,     -- the id another bridge answered with at this address, when that was the last answer
	find_missed_ms = nil, -- when the follow-up search (D5, D12) last ended without the paired bridge
	moved = nil,          -- { from, to, text, at }: the last address change the follow-up made (away.MOVED_KEY)
	-- Created as the chunk loads (below), so they exist whatever runs first:
	bridges_found = nil,  -- bridge/bridges_found.lua, the Bridges Found row
	away = nil,           -- bridge/away.lua, the measures above and what they lead to
	identity = nil,       -- bridge/identity.lua, the identity check (with the TLS self-check)
}

-- Milliseconds since the epoch [verified: SDK 34_timer/_2-GetTime, OS 3.2.3 on]: the clock of
-- the outage and "away" measures (bridge/away.lua, bridge/tasks.lua), so the specs' fake clock
-- (c4.advance) moves them too.
local function now_ms()
	return C4:GetTime()
end

-- Stream timeout in single-queue mode: commands wait for the stream to
-- end, so it must end often.
local SINGLE_QUEUE_TIMEOUT = 60

-- Persisted spelling of the last stream transfer, so a reloaded driver does
-- not reuse the one its predecessor's abandoned transfer still holds.
local STREAM_SPELLING_KEY = "hue_stream_spelling"

-- The owner-facing rows (bridge/rows.lua): plain rows, the rows the stream
-- rewrites per event, list rows, and texts word-wrapped onto continuation
-- rows (Attention, Last Action).
local rows = rows_mod.new()

local function prop(name, value)
	rows:prop(name, value)
end

-- The rows the stream rewrites per event (`Events Received`, `Last Event`,
-- `Event Stream`) are written at most once a second each (bridge/rows.lua).
-- A direct prop() of the same row ("Stopped", Forget Pairing's 0) wins over
-- a value still waiting.
local function prop_soon(name, value)
	rows:prop_soon(name, value)
end

local function paired()
	return credentials.paired(state.creds)
end

-- The Status row from the driver's state. "Paired" is the normal state, and
-- it means that keyed requests go out: never while the identity check (with
-- the TLS check it waits for) has failed or has not passed yet for this
-- address (#236). A failure keeps the check's own text (state.identity_text,
-- bridge/identity.lua); a check still running reads "Checking the bridge at
-- <ip> before anything is sent".
local function refresh_status()
	if not state.ip then
		prop("Status", "Enter the bridge IP address")
	elseif not paired() then
		prop("Status", "Not paired: press the link button, then run Pair Bridge")
	elseif state.key_rejected then
		prop("Status", string.format("Key rejected by the bridge (HTTP %d): checked again by itself; re-pair with "
			.. "Pair Bridge if it stays", state.key_rejected))
	elseif state.tls_verdict == "not_pinned" then
		prop("Status", "TLS check failed: nothing is sent (see Attention)")
	elseif state.identity_ok ~= true then
		prop("Status", state.identity_text
			or string.format("Checking the bridge at %s before anything is sent", state.ip))
	else
		prop("Status", "Paired")
	end
	prop("Bridge ID", paired() and state.creds.bridge_id or "")
	-- Every change of what the background tasks' guards read passes here.
	if state.hk then
		state.hk:wake()
	end
	-- The bridge cannot be used (unpaired, key rejected, TLS, identity): the
	-- link counts it as trouble (#428 D2 d).
	if state.link then
		state.link:evaluate()
	end
end

-- What the stream needs to connect, or nil when it can't.
local function connection()
	if state.ip and paired() then
		return { ip = state.ip, key = state.creds.key }
	end
	return nil
end

-- Why nothing that carries the key may go out now, or nil
-- (docs/security-fixes-design.md §3): not paired; the TLS self-check found
-- the controller accepting a decoy CA (until the next start or address
-- change); the bridge refused the key (until Pair Bridge, an address change,
-- or a Test Connection that shows the key works). Test Connection asks with
-- `for_test`: a rejected key is the one thing it may disprove, so that
-- refusal does not apply to it. The identity check is the callers' own step.
local function keyed_refusal(for_test)
	if not connection() then
		return "not paired"
	end
	if state.tls_verdict == "not_pinned" then
		return "TLS check failed"
	end
	if state.key_rejected and not for_test then
		return "key rejected"
	end
	return nil
end

local function number_property(name, default)
	return tonumber(Properties[name]) or default
end

-- True when the stream has its own C4:url queues (padded address spellings
-- that the startup self-check confirmed), so commands never wait for it.
local function dual_queue()
	return state.stream_family ~= nil
end

-- The position of a spelling in the stream family, 0 when it is not there.
local function family_index(spelling)
	for i, s in ipairs(state.stream_family or {}) do
		if s == spelling then
			return i
		end
	end
	return 0
end

-- The spelling the next stream transfer uses: the family entry after the one
-- the previous transfer used (in memory, or persisted by the driver instance
-- a reload replaced), wrapping around, so a new transfer never queues behind
-- the abandoned one (docs/design.md, "Stream address rotation"). With
-- `commit` the pick is recorded and persisted as used.
local function next_stream_address(commit)
	local family = state.stream_family
	if not family then
		return state.ip
	end
	local index = family_index(state.last_stream_ip or C4:PersistGetValue(STREAM_SPELLING_KEY)) % #family + 1
	local pick = family[index]
	if commit then
		state.last_stream_ip = pick
		C4:PersistSetValue(STREAM_SPELLING_KEY, pick)
		log.debug("stream spelling %s (%d of %d)", pick, index, #family)
	end
	return pick
end

-- The `Stream Address` text in dual-queue mode. Composer's value column
-- shows about 75 characters and does not wrap, so this stays short; the
-- commands' address is the `Bridge IP Address` row.
local function stream_address_text(spelling)
	local family = state.stream_family or {}
	if #family > 1 then
		return string.format("%s (own queue, spelling %d of %d)", spelling, family_index(spelling), #family)
	end
	return string.format("%s (own queue, the only spelling)", spelling)
end

-- Why the event stream may not connect now, or nil: keyed_refusal's reasons,
-- then an identity check (with the TLS check) that has not passed.
local function stream_refusal()
	local refusal = keyed_refusal()
	if refusal == nil and state.identity_ok ~= true then
		refusal = "bridge identity not verified yet"
	end
	return refusal
end

-- The Event Stream row while the feed waits for something other than the
-- stream itself: no pairing, no address, a refusal, or the identity check.
-- Late init and an address change write it, so the row never keeps a text
-- from before a restart or from the old address while the check is pending
-- or failing (#236); the stream's own texts replace it once it starts.
local function show_stream_waiting()
	if not connection() then
		return prop("Event Stream", paired() and "Waiting for IP address" or "Not paired")
	end
	local refusal = stream_refusal()
	if refusal then
		prop("Event Stream", "Not connected: " .. refusal)
	end
end

-- What the stream connects with. The stream calls this for every attempt,
-- so each connection gets the next spelling. Every path that starts the
-- stream checks first; this is the last guard for a path added later (diff
-- review 2026-10-25 row 6): nothing keyed to an unverified bridge, after a
-- failed TLS check, with a rejected key, or on a network connection whose
-- own TLS check has not passed (net_gate). The second value is the stream's
-- status text.
-- The stream's transport (docs/raw-stream-design.md §0, #317): a network
-- connection unless the owner chose Web transfer, the C4:url stream of 1.0,
-- or the network connection's TLS check failed in this run (net_gate; the
-- property is left as the owner set it).
local NETSTREAM_TEXT = "%s (network connection, binding " .. tostring(netstream.BINDING or 6001) .. ")"

local function use_netstream()
	return state.net_check ~= "not_pinned"
		and not (Properties and Properties["Event Stream Transport"] == "Web transfer")
end

-- True once the network connection's TLS check lets the key go out on it in this run (net_gate).
local function net_cleared()
	return state.net_check == "pinned" or state.net_check == "accepted"
end

local function stream_connection()
	local refusal = stream_refusal()
	if refusal == nil and use_netstream() and not net_cleared() then
		refusal = "network connection TLS check pending"
	end
	if refusal and refusal ~= "not paired" then
		log.warn("event stream not connected: %s", refusal)
		return nil, "Not connected: " .. refusal
	end
	local conn = connection()
	if conn and use_netstream() then
		-- Off C4:url the address spelling buys nothing: the dotted one.
		state.stream_ip = conn.ip
		conn.stream_ip = conn.ip
		prop("Stream Address", string.format(NETSTREAM_TEXT, conn.ip))
	elseif conn then
		state.stream_ip = next_stream_address(true)
		conn.stream_ip = state.stream_ip
		if dual_queue() then
			prop("Stream Address", stream_address_text(state.stream_ip))
		end
	end
	return conn
end

-- Bounds [code analysis 2026-10-22, M3]: 0 would make the transfer wait for
-- ever (and block every command in single-queue mode); a watchdog shorter
-- than the keepalive interval would reconnect and resync without end.
local TIMEOUT_MIN, TIMEOUT_MAX, WATCHDOG_MIN = 30, 86400, 60

local function stream_timeout()
	local configured = number_property("Stream Timeout (s)", stream.DEFAULT_TIMEOUT)
	configured = math.max(TIMEOUT_MIN, math.min(configured, TIMEOUT_MAX))
	if dual_queue() then
		return configured
	end
	return math.min(configured, SINGLE_QUEUE_TIMEOUT)
end

-- Authenticated request on the dotted address. The registry and the command
-- queue go through this, so they never learn about addresses or keys.
-- Every request that carries the application key goes through here: only
-- to the paired bridge, only once its identity is verified (below), and
-- never with a caller-supplied TLS table (the pinned bundle always applies).
-- The bridge refused the key (HTTP 401/403 on the stream or on a keyed
-- request; the house Bridge Pro answers an unknown key with 403, verified
-- 2026-10-25): stop the stream, say so, and answer every keyed request at
-- once until Pair Bridge succeeds or the address changes (issue #44).
local function key_rejected(code)
	code = tonumber(code) or 403
	if state.key_rejected == code then
		return
	end
	state.key_rejected = code
	log.warn("the bridge rejected the application key (HTTP %d): stream stopped; re-pair with Pair Bridge", code)
	if state.stream then
		state.stream:stop()
	end
	C4:UpdateProperty("Event Stream", string.format("Stopped: key rejected (HTTP %d)", code))
	refresh_status()
	-- The background re-check (owner's answer D8): 5 min, 15 min, 1 h, then
	-- hourly, until the bridge accepts the key again or the driver re-pairs.
	if state.hk then
		state.hk:poke("key_recheck", "error")
	end
end

-- A 401/403 to a keyed module request is not proof that the key is gone:
-- which other refusals CLIP v2 answers with 403 is not known [assumed:
-- Signify's error list is behind a login]. One keyed GET of the bridge
-- resource, which any valid key may read, decides; only its own 401/403
-- locks (security review 2026-10-25 finding 4). One at a time, however many
-- refusals arrive; a result for an earlier address or pairing is ignored.
local key_confirm_running = false

local function confirm_key_rejected(code)
	if key_confirm_running or state.key_rejected or keyed_refusal() or state.identity_ok ~= true then
		return
	end
	key_confirm_running = true
	local gen, creds = state.address_gen, state.creds
	log.info("HTTP %d to a keyed request: asking the bridge resource whether the key itself is refused", code)
	http.request({ ip = state.ip, key = creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
		key_confirm_running = false
		if gen ~= state.address_gen or creds ~= state.creds then
			return log.debug("key check for an earlier address or pairing ignored")
		end
		if r.code == 401 or r.code == 403 then
			key_rejected(r.code)
		elseif r.ok then
			log.warn("the bridge refused one request (HTTP %d) but accepts the key: not locked", code)
		end
	end)
end

local function bridge_request(req, callback)
	local refusal = keyed_refusal()
	if refusal then
		return callback({ ok = false, err = refusal, code = refusal == "key rejected" and state.key_rejected or nil })
	end
	if state.identity_ok ~= true then
		return callback({ ok = false, err = "bridge identity not verified yet" })
	end
	-- The GETs sent while a background read runs (an optional task's resync
	-- chain) count against the hourly budget of optional requests
	-- (bridge/housekeeping.lua job.charge; §4 finding 7); nothing is refused.
	if state.charge and (req.method == nil or req.method == "GET") then
		state.charge()
	end
	req.ip = state.ip
	req.key = state.creds.key
	req.tls = nil
	-- Every write here is a person's (commands, recalls, renames): the
	-- background tasks keep 1.5 s clear of the last one (§1.3).
	if req.method ~= nil and req.method ~= "GET" then
		state.last_write_ms = C4:GetTime()
	end
	return http.request(req, function(r)
		if type(r) == "table" and (r.code == 401 or r.code == 403) then
			confirm_key_rejected(r.code)
		end
		-- The link to the bridge (#428 D2 c, f): a 2xx is contact; a transfer
		-- that failed without an HTTP status is trouble, except the local
		-- invalid request path. 429, 5xx and other 4xx are neither.
		if type(r) == "table" and state.link then
			if r.ok then
				state.link:contact()
			elseif r.code == nil and r.err ~= http.INVALID_PATH then
				state.link:trouble()
			end
		end
		callback(r)
	end)
end


-- The project calls (docs/import-design.md §13), wrapped so the modules stay
-- free of C4. Shapes verified on hardware (design.md "Project APIs"):
-- GetDevices wants comma-separated strings; GetBoundConsumerDevices values
-- are driver names, not Composer names.
local project_calls = {
	rooms = function() return C4:GetDevicesByC4iName("roomdevice.c4i") end,
	hierarchy = function() return C4:GetProjectHierarchy() end,
	devices = function(filter) return C4:GetDevices(filter) end,
	bound = function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1) end,
	unbind = function(device_id) C4:Unbind(device_id, 1) end,
	rename = function(proxy_id, name) C4:RenameDevice(proxy_id, name) end,
	display_name = function(id) return C4:GetDeviceDisplayName(id) end,
}

-- "k=v k=v" of a message's params, rid left out, for debug lines.
local function params_text(params)
	local parts = {}
	for k, v in pairs(params or {}) do
		if k ~= "rid" then parts[#parts + 1] = k .. "=" .. tostring(v) end
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

-- Every message to a light, scene or zone-light device. The debug text is
-- built only when it is printed: Lua evaluates the arguments before the
-- call, so it used to cost a table, a sort and a concat per message with
-- Debug Mode off.
local function device_send(id, command, params)
	if log.enabled("debug") then
		log.debug("%s %s -> %d: %s", command, tostring(params and params.rid):sub(1, 8), id, params_text(params))
	end
	-- logCommand (the fifth argument) defaults to true; false keeps Director
	-- from logging every message with its whole parameter table [verified:
	-- API 32_serial_network_device/_19-SendToDevice]. Debug Mode brings it back.
	C4:SendToDevice(id, command, params, false, log.enabled("debug"))
end

local function new_lights()
	return lights_mod.new({
		http = bridge_request,
		send = device_send,
		bridge_id = C4:GetDeviceID(),
		room_id = C4:RoomGetId(),
		log = log,
		now = os.time,
		project = project_calls,
		-- Zone-light devices run the light driver too (docs/zone-light-design.md):
		-- the lights module never adopts, links or messages them. Read live,
		-- since the zone module is created after the lights.
		skip_devices = function()
			return state.zone_lights and state.zone_lights:device_ids() or {}
		end,
	})
end

-- The grouped_light hooks the scenes and the zone lights share: every
-- grouped_light PUT goes through the group queue (one coalescing entry per
-- group, so a "room off" reaching several devices sends one PUT).
local group_hooks = {
	-- Scene OFF / zone light OFF. A scene's keypad tap fades the group out
	-- over `opts.rate` ms, past the request bucket (#421 S-D2, S-D6).
	group_off = function(grouped_light_rid, opts)
		if state.group_queue then
			local fields = { on = false }
			if type(opts) == "table" then
				fields.rate, fields.urgent = opts.rate, opts.urgent
			end
			state.group_queue:set(grouped_light_rid, fields)
			return true
		end
		return false
	end,
	-- Hold-to-dim on a keypad and a scene slider's relative move: bridge/group_hold.lua
	-- decides how each reaches Hue (docs/group-hold-design.md, #249).
	group_dim = function(grouped_light_rid, body, level)
		return state.group_hold ~= nil and state.group_hold:dim(grouped_light_rid, body, level) == true
	end,
	-- Absolute fields on the grouped_light: a scene slider while the group's
	-- level is unknown (docs/scene-dimmer-design.md), every zone light
	-- command (docs/zone-light-design.md Decision 5).
	group_set = function(grouped_light_rid, fields)
		if state.group_queue and type(fields) == "table" then
			-- A zone light's PUTs are clamped to its members' common colour
			-- temperature range (docs/zone-light-design.md Decision 7), not
			-- only on the device side.
			local limits = state.zone_lights and state.zone_lights:limits(grouped_light_rid)
			if limits then
				local sent = state.limits_sent[grouped_light_rid]
				if not (sent and sent.min_dim == limits.min_dim and sent.mirek_min == limits.mirek_min
					and sent.mirek_max == limits.mirek_max) then
					state.limits_sent[grouped_light_rid] = limits
					state.group_queue:limits(grouped_light_rid, limits)
				end
			end
			state.group_queue:set(grouped_light_rid, fields)
			return true
		end
		return false
	end,
}

-- The context the scenes (docs/scenes-design.md §4) and the zone lights
-- (docs/zone-light-design.md) are created with; `extra` adds to it.
local function module_ctx(extra)
	local ctx = {
		http = bridge_request,
		send = device_send,
		bridge_id = C4:GetDeviceID(),
		log = log,
		now = os.time,
		project = project_calls,
		lights = state.lights,
		group_off = group_hooks.group_off,
		group_dim = group_hooks.group_dim,
		group_set = group_hooks.group_set,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) C4:PersistSetValue(name, value) end,
	}
	for k, v in pairs(extra or {}) do
		ctx[k] = v
	end
	return ctx
end

-- True when a stream container may change what the Motion Sensors row or
-- Attention shows: battery, reachability, an area's configuration, or a
-- sensor or area switched on or off in the Hue app. Plain motion, light level
-- and temperature updates do not, and they are the frequent ones.
local MOTION_ROW_TYPES = { device_power = true, zigbee_connectivity = true, motion_area_configuration = true }
local MOTION_ENABLED_TYPES = { motion = true, convenience_area_motion = true, security_area_motion = true }

local function motion_rows_changed(container)
	for _, item in ipairs(type(container.data) == "table" and container.data or {}) do
		if type(item) == "table" and (MOTION_ROW_TYPES[item.type]
				or (MOTION_ENABLED_TYPES[item.type] and item.enabled ~= nil)) then
			return true
		end
	end
	return false
end

local function zone_light_device(device_id)
	local id = tonumber(device_id)
	return id ~= nil and state.zone_lights:device_ids()[id] == true
end

-- The light devices' ids as a set, for the zone lights' Link Devices.
local function light_device_ids()
	local set = {}
	for _, entry in pairs(state.lights.registry) do
		if entry.device_id then
			set[entry.device_id] = true
		end
	end
	return set
end

local function is_zone_light_rid(rid)
	return rid ~= nil and rid ~= "" and state.zone_lights:is_group(rid) == true
end

-- The owner-facing counts and lists (docs/import-design.md §6).
-- The TLS checks' items, the bridge's own, then the lights' Attention text followed by the
-- scenes', the zone lights', the motion devices' and the names' items.
local function attention_text()
	local items = {}
	if state.tls_verdict == "not_pinned" then
		items[1] = identity_mod.TLS_ATTENTION
	end
	if state.net_check == "not_pinned" then
		items[#items + 1] = netgate_mod.ATTENTION
	end
	for _, item in ipairs(state.away:attention_items()) do
		items[#items + 1] = item
	end
	for _, item in ipairs(state.link and state.link:attention_items() or {}) do
		items[#items + 1] = item
	end
	local text = state.lights:attention()
	if text and text ~= "" and text ~= "None" then
		items[#items + 1] = text
	end
	for _, item in ipairs(state.scenes:attention_items() or {}) do
		items[#items + 1] = item
	end
	for _, item in ipairs(state.zone_lights:attention_items() or {}) do
		items[#items + 1] = item
	end
	if state.motion then
		for _, item in ipairs(state.motion:attention_items() or {}) do
			items[#items + 1] = item
		end
	end
	-- Names that wait for the bridge, that Hue refused, or that changed in
	-- bulk (bridge/names.lua; each ends in "(Resolve Names)").
	if state.names then
		for _, item in ipairs(state.names:attention() or {}) do
			items[#items + 1] = item
		end
	end
	return #items > 0 and table.concat(items, "; ") or "None"
end

-- List rows (`Room Mappings`, `Lights`, `Scenes`, `Zone Lights`, `Motion
-- Sensors`; bridge/rows.lua): the summary on the row, every item on a line
-- of the drop-down, and a pick in Composer snaps back to the summary.
local function refresh_room_mappings()
	local items, unmapped = state.lights:room_mapping_items()
	if #items == 0 then
		return rows:list("Room Mappings", "None yet (Set Room Mapping makes one)")
	end
	rows:list("Room Mappings", string.format("%d Hue rooms and zones; %d unmapped (open the list to read)",
		#items, unmapped), items)
end

-- A module's summary as the row and its list_items() as the drop-down.
local function show_module_list(name, module)
	rows:list(name, module:summary(), module:list_items())
end

-- Attention, word-wrapped onto its continuation rows like Last Action
-- (#68, contract §1.3: the action hint at the end is never cut; bridge/rows.lua).
local attention_rows = rows:wrapped("Attention", {
	empty = "None",
	on_overflow = function(text)
		-- In full in the Lua output whatever Debug Mode says, as Last Action's overflow (§4 finding 1).
		log.always("Attention: %s", text)
	end,
})

local function refresh_lights_props()
	if not state.zone_lights then
		return -- before late init created the modules
	end
	show_module_list("Lights", state.lights)
	local attention = attention_text()
	if attention ~= state.attention_sent then
		state.attention_sent = attention
		attention_rows:show(attention)
	end
	refresh_room_mappings()
	show_module_list("Scenes", state.scenes)
	show_module_list("Zone Lights", state.zone_lights)
	if state.motion then
		show_module_list("Motion Sensors", state.motion)
	end
end

local function new_queue()
	return commands.new({
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/light/" .. rid, body = body }, done)
		end,
		-- A PUT that failed answers the device with the bridge's last word (#428 D8).
		on_undelivered = function(rid)
			if state.lights then
				state.lights:undelivered(rid)
			end
		end,
	})
end

-- Grouped-light PUTs (scene OFF, dims, levels, zone lights) have their own
-- queue and bucket, separate from the lights': Hue's guidance for groups is
-- about one request a second [verified: Core Concepts], so one a second
-- sustained with a burst of three (a hold's start and stop, a tap after a
-- hold) (docs/zone-light-design.md Decision 9).
local function new_group_queue()
	return commands.new({
		label = "grouped_light",
		rate_per_sec = 1,
		burst = 3,
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/grouped_light/" .. rid, body = body }, done)
		end,
		-- Where a refused dim stop's fallback estimate starts.
		level_of = function(rid)
			return state.scenes and state.scenes.group_level and state.scenes.group_level[rid] or nil
		end,
		-- A grouped_light PUT that failed answers the zone lights and the
		-- scenes on that group with the bridge's last word (#428 D8, D9).
		on_undelivered = function(rid)
			if state.zone_lights then
				state.zone_lights:undelivered(rid)
			end
			if state.scenes then
				state.scenes:undelivered_group(rid)
			end
		end,
	})
end

-- Every module's resync, one GET at a time: at every stream connect, and
-- from Refresh All (#324), which needs no stream. Runs from a timer or an
-- action, never inside a transfer's callbacks. The scenes follow the lights
-- (their catalogue GET is the large one, 351 KB on the house bridge, and
-- their groups and room mappings come from the lights' resync), the zone
-- lights the scenes (their grouped_light GET is small, and the scenes hand
-- theirs on), the motion devices last (their sensors come from the lights'
-- device cache, docs/motion-design.md §4.2); the owner-facing rows are
-- refreshed after the lights and once more after the chain. done(failures)
-- gets the list of "<part>: <error>" texts, empty when every part worked.
local function resync_all(done, tier)
	local failures = {}
	local function note(part, ok, err, sent)
		if ok then
			log.info("%s resync done: %d state messages", part, tonumber(sent) or 0)
		else
			log.warn("%s resync failed: %s", part, tostring(err))
			failures[#failures + 1] = part .. ": " .. tostring(err)
		end
	end
	-- A quick resync (after a silence reconnect, contract §3.1) leaves out the
	-- scene catalogue; the zone lights then read /grouped_light themselves.
	local function scenes_step(cb)
		if tier == "quick" then
			log.info("scene resync skipped (quick resync)")
			return cb(true, nil, 0, nil)
		end
		state.scenes:resync(cb)
	end
	state.lights:resync(function(ok, err, sent)
		note("light", ok, err, sent)
		refresh_lights_props()
		scenes_step(function(sok, serr, ssent, grouped)
			if tier ~= "quick" then
				note("scene", sok, serr, ssent)
			end
			state.zone_lights:resync(function(zok, zerr, zsent)
				note("zone light", zok, zerr, zsent)
				state.motion:resync(function(mok, merr, msent)
					note("motion", mok, merr, msent)
					refresh_lights_props()
					if done then
						done(failures)
					end
				end)
			end, grouped)
		end)
	end)
end

-- Background tasks (docs/simplify-actions-design.md §1.3, §3.1; the engine
-- is bridge/housekeeping.lua, the tasks are bridge/tasks.lua's, started in
-- start_housekeeping below). The resync chain's GETs go through
-- bridge_request as before, not through the engine's job.http; an optional
-- task's chain charges each GET to its job (state.charge, job.charge), so
-- the hourly budget of optional requests counts it (§4 finding 7).

-- True while a command queue holds work or a person's write went out in the
-- last quiet_ms (the engine's gate, research §3.4).
local function user_active(quiet_ms)
	if (state.queue and state.queue:busy()) or (state.group_queue and state.group_queue:busy()) then
		return true
	end
	return state.last_write_ms ~= nil
		and C4:GetTime() - state.last_write_ms < (quiet_ms or housekeeping.USER_QUIET_MS)
end

-- Ask for a resync; a full one wins over a quick one still waiting.
-- done(ok, text) once, by the run that serves it.
local function want_resync(tier, why, done)
	if state.resync_tier ~= "full" then
		state.resync_tier = tier
	end
	if not state.hk then
		-- Not started yet (cannot happen after late init): as beta 8 did.
		return resync_all(function(failures)
			if done then done(#failures == 0, table.concat(failures, "; ")) end
		end, tier)
	end
	state.hk:poke("resync", why, done)
end

-- The paired bridge away and the event stream down (bridge/away.lua): the
-- measures, the identity check after an outage, the follow-up search for the
-- bridge at a new address (owner's answers D5, D12) and Attention's items.
state.away = away_mod.new({
	state = state,
	paired = paired,
	keyed_refusal = keyed_refusal,
	use_netstream = use_netstream,
	heard_elsewhere = function() return state.bridges_found:heard_elsewhere() end,
	offer = function() state.bridges_found:offer() end,
	refresh = refresh_lights_props,
	refresh_status = refresh_status,
	verify_identity = function(purpose, callback) state.identity:verify(purpose, callback) end,
	log = log,
	now_ms = now_ms,
})

-- The link to the bridge (#428, docs/offline-design.md §3): every Hue device
-- goes offline after OFFLINE_AFTER_S of trouble and back at the first contact.
-- The devices of all four modules, as one set of device ids.
local function link_device_ids()
	local ids = {}
	local function add(registry)
		for _, entry in pairs(registry or {}) do
			if entry.device_id then
				ids[tonumber(entry.device_id) or entry.device_id] = true
			end
		end
	end
	add(state.lights and state.lights.registry)
	add(state.scenes and state.scenes.registry)
	add(state.zone_lights and state.zone_lights.registry)
	add(state.motion and state.motion.registry)
	return ids
end
state.link = link_mod.new({
	state = state,
	paired = paired,
	keyed_refusal = keyed_refusal,
	now_ms = now_ms,
	device_ids = link_device_ids,
	send = device_send,
	refresh = refresh_lights_props,
	log = log,
	clock = function(ms) return state.away:clock(ms) end,
})
state.away.ctx.link = state.link

local function new_stream()
	return (use_netstream() and netstream or stream).new({
		connection = stream_connection,
		tls_checked = net_cleared, -- netstream's own guard (#317); stream.lua ignores it
		abandoned = state.stream_abandoned,
		timeout = stream_timeout(),
		watchdog = math.max(WATCHDOG_MIN, number_property("Stream Watchdog (s)", stream.DEFAULT_WATCHDOG)),
		-- The per-event rewrite of the row ("Connected since …, N containers,
		-- last …") is coalesced; a state change lands at once.
		on_status = function(text, per_event)
			-- Reconnects since the driver started (any stream instance), so
			-- the owner can read the real reconnect rate off the row (#65).
			-- The motion devices say "bridge not answering" while the stream
			-- is down (docs/edge-cases-motion.md §6).
			if not per_event and state.motion and not tostring(text):find("^Connected since") then
				state.motion:on_stream_state(false)
			end
			-- The outage measures (when it began, the reason it began with) and
			-- the identity check after an outage (bridge/away.lua).
			if not per_event then
				state.away:stream_status(text)
			end
			if not per_event and tostring(text):find("^Connected since") then
				state.stream_connects = (state.stream_connects or 0) + 1
				state.stream_started_at = state.stream_started_at or os.date("%m-%d %H:%M")
			end
			local reconnects = math.max(0, (state.stream_connects or 0) - 1)
			if reconnects > 0 and tostring(text):find("^Connected since") then
				text = per_event and string.format("%s; %d reconnect%s", text, reconnects, reconnects == 1 and "" or "s")
					or string.format("%s (%d reconnect%s since %s)", text, reconnects, reconnects == 1 and "" or "s",
						state.stream_started_at)
			end
			if per_event then
				prop_soon("Event Stream", text)
			else
				prop("Event Stream", text)
			end
		end,
		on_key_rejected = function(code)
			key_rejected(code)
		end,
		on_connected = function()
			-- Runs from a timer, never inside the stream's callbacks (see
			-- stream.lua); events may have been missed while reconnecting.
			-- The scenes follow the lights (their catalogue GET is the large
			-- one, 351 KB on the house bridge, and their groups and room
			-- mappings come from the lights' resync), the zone lights the
			-- scenes (their grouped_light GET is small); the owner-facing
			-- rows are refreshed once, after the last of the three.
			log.info("event stream connected; resyncing %d lights", state.lights:count())
			state.motion:on_stream_state(true)
			want_resync(state.away:connect_tier(), "connect")
		end,
		on_container = function(container)
			-- Fan-out only sends SendToDevice, which is safe inside a C4:url
			-- callback; nothing here starts a transfer. A container that is not
			-- a table is the bridge's or a peer's malformed data (security
			-- review 2026-10-25 finding 6).
			if type(container) ~= "table" then
				return
			end
			state.lights:on_container(container)
			state.scenes:on_container(container)
			state.zone_lights:on_container(container)
			state.motion:on_container(container)
			state.motion_diag:on_container(container)
			-- A resource appearing or disappearing changes the counts and the
			-- Attention list; plain updates (state, names) do not, except the
			-- motion devices' battery, reachability and switched-off state,
			-- which Attention lists at once (docs/motion-design.md D5, D6).
			if container.type == "add" or container.type == "delete" or motion_rows_changed(container) then
				refresh_lights_props()
			end
			prop_soon("Events Received", state.stream.stats.containers)
			prop_soon("Last Event", state.stream.stats.last_event)
		end,
	})
end

-- Rebuild the stream with the current properties. It is started again if it
-- was running, or if `force` is set and the driver is paired with an IP.
local function restart_stream(force)
	if not state.stream or state.destroyed then
		return
	end
	local was_running = state.stream:running()
	-- A rejected key keeps key_rejected's text, not a bare "Stopped": the address
	-- self-check's 401/403 rebuilds the stream right after writing it (#246).
	state.stream:stop(state.key_rejected and string.format("Stopped: key rejected (HTTP %d)", state.key_rejected))
	state.stream = new_stream()
	if (was_running or force) and keyed_refusal() == nil and state.identity_ok == true then
		state.stream:start()
	end
end

-- The bridge's model, name and firmware rows (docs/bridge-compat-design.md
-- Decision 3), from a /api/0/config answer or a pairing probe. The model is
-- kept for Bridges Found too: a pairing made before 1.1 stored none, so the
-- stored credentials alone left its summary "Paired with  at ..." (dev 467).
local function show_bridge_info(info)
	state.bridge_model = info.model
	prop("Bridge Model", config.model_label(info.model))
	state.bridges_found:show() -- its summary names the model
	prop("Bridge Name", util.display_name(info.name))
	prop("Bridge Firmware", config.firmware_label(info.sw_version, info.api_version))
	if config.firmware_check(info.sw_version) == "old" then
		log.warn("bridge firmware %s is older than %d: the CLIP v2 API may be missing", tostring(info.sw_version),
			config.MIN_FIRMWARE)
	end
end

-- The bridge's identity, checked without the key before any request carries
-- it, with the TLS self-check inside (bridge/identity.lua): until it passes
-- for this address nothing keyed is sent.
state.identity = identity_mod.new({
	state = state,
	paired = paired,
	prop = prop,
	show_bridge_info = show_bridge_info,
	refresh_status = refresh_status,
	show_stream_waiting = show_stream_waiting,
	show_attention = function(text) attention_rows:show(text) end,
	away = state.away,
	log = log,
})

-- The TLS check of the network connection (#317, bridge/netgate.lua over
-- bridge/netcheck.lua): before the event stream's first keyed connect on a
-- network connection in a run; its answer holds for the run
-- (state.net_check), and not_pinned moves the stream to Web transfer.
local net_gate = netgate_mod.new({
	state = state,
	prop = prop,
	refresh = refresh_lights_props,
	log = log,
})

-- Decide which spellings of the bridge address the stream uses (docs/design.md,
-- "Two ways to keep commands flowing" and "Stream address rotation"). Director
-- queues C4:url transfers per host text, so zero-padded spellings give the
-- stream its own queues, one per connection, rotating so a reconnect never
-- waits for the transfer it replaced. The self-check uses a spelling no
-- stream ever takes, so it can never queue behind a stream or an abandoned
-- one. Calls back when done; until then the stream must not be started.
local function choose_stream_address(callback)
	if state.destroyed then
		return -- a callback of unloaded code (see OnDriverDestroyed)
	end
	local gen = state.address_gen
	local check_ip = altaddr.for_check(state.ip)
	local family = altaddr.stream_family(state.ip)
	local function single(reason, detail)
		state.stream_family = nil
		state.stream_ip = state.ip
		prop("Stream Address", string.format("%s (shared queue with commands: %s)", state.ip, reason))
		log.warn("stream shares the command queue: %s%s; stream timeout capped at %d s", reason,
			detail and (" (" .. detail .. ")") or "", SINGLE_QUEUE_TIMEOUT)
		callback()
	end
	if not paired() then
		return single("not paired")
	end
	local refusal = keyed_refusal()
	if refusal then
		return log.info("stream address not chosen: %s", refusal) -- Status says why
	end
	if state.identity_ok ~= true then
		return state.identity:verify("stream", function(ok)
			if ok then
				choose_stream_address(callback)
			elseif state.link then
				-- An unsupported model fails without a Status refresh: count it (#428 E11).
				state.link:evaluate()
			end
		end)
	end
	if use_netstream() then
		if not net_cleared() then
			-- The network connection's own TLS check first (#317, bridge/netgate.lua).
			return net_gate:run(function() choose_stream_address(callback) end)
		end
		-- No queue to share off C4:url (#317): no spelling, no self-check.
		state.stream_family = nil
		state.stream_ip = state.ip
		prop("Stream Address", string.format(NETSTREAM_TEXT, state.ip))
		return callback()
	end
	if not family or not check_ip then
		return single("no octet below 8 to pad")
	end
	http.request({ ip = check_ip, key = state.creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
		if gen ~= state.address_gen then
			return log.debug("stream address check for an earlier address ignored")
		end
		if r.code == 401 or r.code == 403 then
			key_rejected(r.code)
			return callback()
		end
		if r.ok then
			state.stream_family = family
			state.stream_ip = next_stream_address(false)
			prop("Stream Address", stream_address_text(state.stream_ip))
			log.info("stream will use %s, rotating over %d spelling(s); self-check via %s OK",
				state.stream_ip, #family, check_ip)
			callback()
		else
			single("self-check failed", "via " .. check_ip .. ": " .. tostring(r.err))
		end
	end)
end

-- Properties ---------------------------------------------------------------

-- Director answers the version lookup with nothing at the first init of a
-- device created by AddDevice [hardware 2026-10-24, device 1166], so the
-- build's own stamp (common/build_version.lua, tools/build.sh) is the fallback.
local build_version_ok, build_version = pcall(require, "common.build_version")
local function driver_version()
	local v = C4:GetDriverConfigInfo("version")
	if v == nil or tostring(v) == "" then
		v = build_version_ok and tostring(build_version) or ""
	end
	return v
end

-- Director fills a new device's property table late: at the first init of
-- a device created by AddDevice the replay of the properties reaches no
-- handler [hardware 2026-10-24, devices 1166 and 1168], so late init writes
-- the read-only row itself (it has no property handler) and looks again
-- twice while it is empty.
local version_timer = nil

local function show_driver_version(attempt)
	if version_timer then
		version_timer:Cancel()
		version_timer = nil
	end
	local v = driver_version()
	prop("Driver Version", v)
	if v == "" and attempt < 3 then
		version_timer = C4:SetTimer(5000 * attempt, function()
			version_timer = nil
			show_driver_version(attempt + 1)
		end)
	end
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

dispatch.properties["Bridge_IP_Address"] = function(value)
	local ip, err = config.parse_ipv4(value)
	if not ip and value ~= "" then
		log.warn("ignoring bridge IP %q: %s", value, err)
	end
	local changed = ip ~= state.ip
	-- Whether the feed is wanted at a new address, from what it did at the
	-- old one (read before the old address's state is dropped below):
	-- running, stopped only while the address was invalid, never started
	-- because the identity check had not passed, about to start (its address
	-- check had not answered), or stopped by a rejected key, a stop the new
	-- address ends (#236). A feed the owner stopped with Disconnect Event
	-- Stream stays stopped.
	local wanted = (state.stream and state.stream:running()) or state.stream_paused_by_address
		or state.identity_ok ~= true or state.stream_ip == nil or state.key_rejected ~= nil
	state.ip = ip
	if changed then
		-- Everything learnt about the old address goes; the checks run afresh,
		-- and until they pass Status does not read "Paired" (#236).
		state.address_gen = state.address_gen + 1
		if state.hk then
			state.hk:reset(state.address_gen)
		end
		state.away:reset() -- the new address gets its own identity check below
		state.key_rejected = nil
		state.tls_verdict = nil
		state.identity_ok = nil
		state.identity_text = nil
	end
	refresh_status()
	if changed and state.late_init_done then
		state.stream_ip = nil
		state.stream_family = nil
		state.identity:reset()
		net_gate:reset() -- a probe of the old address; the run's verdict stays
		if ip and paired() then
			credentials.save_ip(ip)
			state.creds.ip = ip
			state.stream_paused_by_address = nil
			if state.stream then state.stream:stop() end
			-- The feed comes back by itself once the bridge at the new address
			-- passes the identity check; until then the row says so.
			if wanted then
				show_stream_waiting()
			end
			choose_stream_address(function() restart_stream(wanted) end)
		else
			state.stream_paused_by_address = (state.stream and state.stream:running()) or nil
			restart_stream()
		end
		-- A driver that was never paired opens the pairing window as soon as
		-- an address is entered (contract §1.2, action 1).
		if ip and not paired() and not (state.creds and state.creds.bridge_id) and not state.pair_until then
			dispatch.commands["Pair_Bridge"]()
		end
		-- Bridges Found names the address: the paired summary, and the
		-- networks of the offered search (§4 finding 12).
		state.bridges_found:show()
	end
end

dispatch.properties["Stream_Timeout_(s)"] = function()
	if state.late_init_done then restart_stream() end
end

dispatch.properties["Event_Stream_Transport"] = function()
	if state.late_init_done then
		net_gate:reset() -- a probe in flight served the previous choice; its answer would restart the stream twice
		choose_stream_address(function() restart_stream(true) end)
	end
end

dispatch.properties["Stream_Watchdog_(s)"] = function()
	if state.late_init_done then restart_stream() end
end


-- Actions ------------------------------------------------------------------

-- Pair Bridge waits up to two minutes for the link button (contract §1.2,
-- action 1; bridge/pair_window.lua), asking for the key again every 3 s
-- while Status counts down.
local pair_window = pair_window_mod.new({
	state = state,
	prop = prop,
	show_bridge_info = show_bridge_info,
	log = log,
	on_paired = function(creds)
		local previous_id = state.creds and state.creds.bridge_id
		-- Use the in-memory result: the store writes on its own thread
		-- and may not return the value yet.
		state.creds = creds
		state.key_rejected = nil
		-- The identity check runs afresh (choose_stream_address below) unless it
		-- passed for this very bridge: a failure text (an unreachable bridge,
		-- say) is stale now that the bridge answered, and a check of the bridge
		-- paired before (a late answer after Forget Pairing) proves nothing for
		-- this one. Status reads "Checking the bridge ..." meanwhile.
		if state.identity_ok ~= true or previous_id ~= creds.bridge_id then
			state.identity_ok = nil
			state.identity_text = nil
		end
		prop("Bridge Model", config.model_label(creds.model))
		refresh_status()
		-- Bridges Found reads "Paired with ..." at once, and the first-load
		-- searches end (§4 finding 2).
		state.bridges_found:paired()
		show_stream_waiting() -- not "Not paired" while the new pairing's checks run
		choose_stream_address(function() restart_stream(true) end)
	end,
})

dispatch.commands["Pair_Bridge"] = function()
	pair_window:open()
end

-- GET /clip/v2/resource/bridge with the key via `host` (the dotted address;
-- dev builds may pass another spelling, see bridge/devtools.lua), then the
-- application-layer identity check described in docs/design.md.
-- Gated like every keyed request (security review 2026-10-25 finding 1):
-- refused after a failed TLS check, and sent only once the unkeyed identity
-- check has passed, so a different bridge at the address is reported from
-- /api/0/config without the key. A rejected key does not stop it: a 200 with
-- the paired bridge id is how the key is shown to work again, which clears
-- the lock and starts the stream (finding 4).
-- The bridge accepts the key again (Test Connection, or the background
-- re-check of D8): the lock goes and the stream starts again.
local function key_accepted_again()
	state.key_rejected = nil
	refresh_status()
	if state.stream_ip then
		restart_stream(true)
	else
		choose_stream_address(function() restart_stream(true) end)
	end
end

-- The background key re-check (owner's answer D8): one keyed GET of the
-- bridge resource, which any valid key may read, sent although the key is
-- locked (the lock is what it tests), only after the identity check passed
-- (the task's guards). done(ok, text, cleared): cleared when this check
-- lifted the lock.
local function recheck_key(done)
	if not state.key_rejected then
		return done(true, "the key is not rejected")
	end
	local gen, creds = state.address_gen, state.creds
	http.request({ ip = state.ip, key = creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
		if gen ~= state.address_gen or creds ~= state.creds then
			return done(false, "cancelled: the address or the pairing changed")
		end
		if r.code == 401 or r.code == 403 then
			return done(false, string.format("the bridge still refuses the key (HTTP %d)", r.code))
		elseif not r.ok then
			return done(false, "no answer: " .. tostring(r.err))
		end
		local item = r.json and r.json.data and r.json.data[1] or {}
		local reported = config.normalise_bridge_id(item.bridge_id)
		if reported and reported ~= creds.bridge_id then
			return done(false, string.format("the bridge reports ID %s, expected %s", reported, creds.bridge_id))
		end
		if state.key_rejected then
			log.warn("key re-check: the bridge accepts the key again; key-rejected lock cleared, stream restarting")
			key_accepted_again()
			return done(true, "the bridge accepts the key again", true)
		end
		done(true, "the bridge accepts the key")
	end)
end

local function test_connection(host)
	local refusal = keyed_refusal(true)
	if refusal == "not paired" then
		prop("Status", "Not paired")
		return
	end
	if refusal then
		prop("Status", "Test refused: " .. refusal .. "; nothing is sent (see Attention)")
		return
	end
	if state.identity_ok ~= true then
		prop("Status", "Testing: checking the bridge identity first")
		return state.identity:verify("test", function(ok)
			if ok then
				test_connection(host)
			end
		end)
	end
	prop("Status", "Testing: GET /clip/v2/resource/bridge via " .. host)
	local started = os.time()
	http.request({ ip = host, key = state.creds.key, path = "/clip/v2/resource/bridge" }, function(r)
		local secs = os.time() - started
		log.always("Test Connection via %s: %s after %d s", host, r.ok and "OK" or tostring(r.err), secs)
		if not r.ok then
			if r.code == 401 or r.code == 403 then
				key_rejected(r.code)
				prop("Status", "Test failed: key rejected (HTTP " .. r.code .. "). Re-pair with Pair Bridge")
			else
				prop("Status", "Test failed: " .. tostring(r.err))
			end
			return
		end
		-- [assumed] the bridge resource carries bridge_id; used as the
		-- application-layer identity check described in docs/design.md.
		local item = r.json and r.json.data and r.json.data[1] or {}
		local reported = config.normalise_bridge_id(item.bridge_id)
		if reported and reported ~= state.creds.bridge_id then
			prop("Status", string.format("Test failed: bridge reports ID %s, expected %s",
				reported, state.creds.bridge_id))
			return
		end
		if state.key_rejected then
			log.warn("Test Connection: the bridge accepts the key again; key-rejected lock cleared, stream restarting")
			key_accepted_again()
		end
		prop("Status", string.format("Test OK: HTTP 200 via %s in %d s, bridge %s", host, secs,
			tostring(reported or state.creds.bridge_id)))
	end)
end

dispatch.commands["Test_Connection"] = function()
	test_connection(state.ip)
end

-- Owner actions (docs/import-design.md §6): every click writes its result to
-- Last Action and refreshes the counts. The pickers are CUSTOM_SELECT lists
-- built on demand by the global functions below [verified: FUND 12.3].

-- A long result is word-wrapped onto `Last Action` and the rows `Last
-- Action (2)` … `(6)` (bridge/rows.lua); rows not in use are hidden.
-- Nothing to click, nothing editable (issue #68).
local last_action_rows = rows:wrapped("Last Action")

local function last_action(text)
	text = tostring(text == nil and "" or text)
	log.always("%s", text)
	last_action_rows:show(text)
	refresh_lights_props()
end

-- The lists are read-only in Composer; should a pick still arrive, the row
-- goes back to its summary (only when it left it, so this cannot loop).
local function list_pick(name)
	return function(value)
		if state.late_init_done and rows:list_moved(name, value) then
			refresh_lights_props()
		end
	end
end
dispatch.properties["Room_Mappings"] = list_pick("Room Mappings")
dispatch.properties["Lights"] = list_pick("Lights")
dispatch.properties["Scenes"] = list_pick("Scenes")
dispatch.properties["Zone_Lights"] = list_pick("Zone Lights")
dispatch.properties["Motion_Sensors"] = list_pick("Motion Sensors")

-- False, with the reason in Last Action, when an action cannot run.
local function can()
	if not connection() then
		last_action("Not paired")
		return false
	end
	return true
end

-- A picker value, or nil for the empty-list entry and a missing param.
local function selection(params, name)
	local value = params and params[name]
	if value == nil or value == "" then
		return nil
	end
	return tostring(value)
end

-- A module's picker list, or the one explanatory entry when the list raised
-- or the module does not exist yet (Composer may open a list before late init).
local function picker(module, method, ...)
	if module then
		local ok, list = pcall(module[method], module, ...)
		if ok and type(list) == "table" then
			return list
		end
		log.warn("%s: %s", method, tostring(list))
		return { { text = "(error building the list; see Lua output)", value = "" } }
	end
	return { { text = "(not ready yet; open the list again)", value = "" } }
end

function HueLightList() return picker(state.lights, "picker_lights") end
-- RoomList (Add From Hue's Room) is defined with the 1.2 actions below.
function RelinkDeviceList() return picker(state.lights, "picker_relink_devices") end
-- ForgetDeviceList is defined with the zone lights' pickers below: it joins
-- the lights' and the zone lights' devices.
function HueRoomList() return picker(state.lights, "picker_hue_rooms") end
function MappingTargetList() return picker(state.lights, "picker_rooms", "mapping") end

-- Scenes (docs/scenes-design.md §5): the same shapes against state.scenes.
function SceneList() return picker(state.scenes, "picker_scenes") end
function SceneGroupList() return picker(state.scenes, "picker_groups") end
function RelinkSceneList() return picker(state.scenes, "picker_relink_devices") end
function ForgetSceneList() return picker(state.scenes, "picker_forget_devices") end

local function join_texts(lights_text, scenes_text, zone_lights_text, motion_text)
	local text = tostring(lights_text)
	if scenes_text ~= nil and scenes_text ~= "" then
		text = text .. " | Scenes: " .. tostring(scenes_text)
	end
	if zone_lights_text ~= nil and zone_lights_text ~= "" then
		text = text .. " | Zone lights: " .. tostring(zone_lights_text)
	end
	if motion_text ~= nil and motion_text ~= "" then
		text = text .. " | Motion: " .. tostring(motion_text)
	end
	return text
end

-- Zone lights (docs/zone-light-design.md §8): the same shapes against
-- state.zone_lights. Two pickers as one: real entries of both, or whichever
-- has them, or the first's placeholder.
local function join_pickers(first, second)
	local function real(list)
		return type(list) == "table" and #list > 0 and list[1].value ~= ""
	end
	if not real(second) then
		return first
	elseif not real(first) then
		return second
	end
	local out = {}
	for _, entry in ipairs(first) do out[#out + 1] = entry end
	for _, entry in ipairs(second) do out[#out + 1] = entry end
	return out
end

function ZoneGroupList() return picker(state.zone_lights, "picker_groups") end
function RelinkZoneLightList()
	local list = picker(state.zone_lights, "picker_relink_devices")
	if #list == 0 then
		return { { text = "(no zone light device is gone or unbound)", value = "" } }
	end
	return list
end
-- ForgetDeviceList (Forget Device's Device) is defined with the 1.2 actions below.

dispatch.commands["Add_Light"] = function(params)
	if not can() then return end
	local rid = selection(params, "Light")
	if not rid then
		return last_action("Not added: pick a light first")
	end
	state.lights:add_light(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Import_All_New_Lights"] = function()
	if can() then
		state.lights:import_new(function(_, text) last_action(text) end)
	end
end

dispatch.commands["Re-link_Device_To_Light"] = function(params)
	if not can() then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Light")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a light")
	end
	local _, text = state.lights:relink(device, rid)
	last_action(text)
end

dispatch.commands["Link_Devices"] = function()
	if can() then
		-- Zone-light devices run the light driver too: each module skips the
		-- other's devices.
		last_action(join_texts(state.lights:link_devices(state.zone_lights:device_ids()), state.scenes:link_devices(),
			state.zone_lights:link_devices(light_device_ids()), state.motion:link_devices()))
	end
end

dispatch.commands["Forget_Light"] = function(params)
	if not can() then return end
	local device = tonumber(selection(params, "Device"))
	if not device then
		return last_action("Not forgotten: pick a device first")
	end
	if zone_light_device(device) then
		local _, text = state.zone_lights:forget(device)
		-- A stale light entry for the same device (an older bridge adopted
		-- the zone light's hello as a light) is dropped too; the lights
		-- module neither unbinds nor messages a device it knows is foreign.
		if light_device_ids()[device] then
			local _, stale = state.lights:forget(device)
			text = tostring(text) .. " | " .. tostring(stale)
		end
		return last_action(text)
	end
	local _, text = state.lights:forget(device)
	last_action(text)
end

-- Entries created before proxy ids were recorded get theirs from the proxy's
-- binding: the light_v2 proxy is the bound consumer of the protocol driver's
-- binding 5001 [verified: hardware]. Renames need it (Composer shows the proxy).
local function fill_proxy_ids()
	local filled = 0
	for rid, entry in pairs(state.lights.registry) do
		if not entry.proxy_id and entry.device_id then
			local consumers = C4:GetBoundConsumerDevices(entry.device_id, 5001)
			local proxy = type(consumers) == "table" and next(consumers) or nil
			if proxy then
				entry.proxy_id = proxy
				filled = filled + 1
				log.debug("proxy id %s recorded for %s", tostring(proxy), rid:sub(1, 8))
			end
		end
	end
	if filled > 0 then
		state.lights:save()
	end
	-- The motion devices too: the contact proxy is the consumer of 5001 the
	-- same way (docs/motion-design.md §2.1); one adopted through a hello or
	-- Link Devices has no proxy id yet.
	local motion_filled = 0
	for _, entry in pairs(state.motion and state.motion.registry or {}) do
		if type(entry) == "table" and not entry.proxy_id and entry.device_id then
			local consumers = C4:GetBoundConsumerDevices(entry.device_id, 5001)
			local proxy = type(consumers) == "table" and next(consumers) or nil
			if proxy then
				entry.proxy_id = proxy
				motion_filled = motion_filled + 1
			end
		end
	end
	if motion_filled > 0 then
		state.motion:save()
	end
	return filled + motion_filled
end

dispatch.commands["Adopt_Hue_Names"] = function()
	if can() then
		fill_proxy_ids()
		last_action(join_texts(state.lights:adopt_hue_names(), state.scenes:adopt_hue_names(),
			state.zone_lights:adopt_hue_names(), state.motion:adopt_hue_names()))
	end
end

dispatch.commands["Accept_Names_As_They_Are"] = function()
	if can() then
		last_action(join_texts(state.lights:accept_names(), state.scenes:accept_names(),
			state.zone_lights:accept_names(), state.motion:accept_names()))
	end
end

dispatch.commands["Set_Room_Mapping"] = function(params)
	if not can() then return end
	local group, target = selection(params, "Hue Room"), selection(params, "Room")
	if not group then
		return last_action("Not mapped: pick a Hue room first")
	end
	local room_id = nil
	if target ~= "none" then
		room_id = tonumber(target)
		if not room_id then
			return last_action("Not mapped: pick a Control4 room or (no mapping)")
		end
	end
	local _, text = state.lights:set_room_mapping(group, room_id)
	last_action(text)
end

dispatch.commands["Map_Rooms_By_Name"] = function()
	if can() then last_action(state.lights:map_rooms_by_name()) end
end

-- The zone-light devices for the Room Audit: each with the zone/room it
-- stands for, audited against that group's mapping like a light.
local function zone_audit_entries()
	local entries = {}
	for _, rid in ipairs(state.zone_lights:registered_rids() or {}) do
		local entry = state.zone_lights:entry(rid)
		if type(entry) == "table" and entry.device_id then
			entries[#entries + 1] = { device_id = entry.device_id, name = entry.name, group_rid = rid }
		end
	end
	return entries
end

dispatch.commands["Room_Audit"] = function()
	if can() then last_action(state.lights:room_audit(zone_audit_entries())) end
end

-- From a light (or zone light) being deleted in Composer (docs/import-design.md §4).
dispatch.commands["HUE_GOODBYE"] = function(params)
	params = params or {}
	if zone_light_device(params.device_id) then
		state.zone_lights:goodbye(params)
	else
		state.lights:goodbye(params)
	end
	refresh_lights_props()
end

-- From a light's (or zone light's) Forget This Light action.
dispatch.commands["HUE_FORGET"] = function(params)
	params = params or {}
	if zone_light_device(params.device_id) then
		local _, text = state.zone_lights:forget_request(params)
		return last_action(text)
	end
	if can() then
		local _, text = state.lights:forget_request(params)
		last_action(text)
	end
end

-- Zone light actions (docs/zone-light-design.md §8) --------------------------

dispatch.commands["Add_Zone_Light"] = function(params)
	if not can() then return end
	local rid = selection(params, "Group")
	if not rid then
		return last_action("Not added: pick a zone or room first")
	end
	state.zone_lights:add(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Re-link_Zone_Light"] = function(params)
	if not can() then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Group")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a zone or room")
	end
	local _, text = state.zone_lights:relink(device, rid)
	last_action(text)
end

-- Motion actions (docs/motion-design.md §4.4) --------------------------------

function MotionSensorList() return picker(state.motion, "picker_sensors") end
function MotionAreaList() return picker(state.motion, "picker_areas") end
-- Re-link takes a sensor or an area; the module refuses a change of kind (D4).
function MotionTargetList()
	return join_pickers(picker(state.motion, "picker_sensors"), picker(state.motion, "picker_areas"))
end
function RelinkMotionDeviceList()
	local list = picker(state.motion, "picker_relink_devices")
	if #list == 0 then
		return { { text = "(no motion device is gone or unbound)", value = "" } }
	end
	return list
end
function ForgetMotionDeviceList() return picker(state.motion, "picker_forget_devices") end

dispatch.commands["Add_Motion_Sensor"] = function(params)
	if not can() then return end
	local rid = selection(params, "Sensor")
	if not rid then
		return last_action("Not added: pick a motion sensor first")
	end
	state.motion:add(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

-- Every new sensor into the room its Hue room maps to; the rest listed (#319;
-- Add All New Motion Sensors until #325).
dispatch.commands["Import_All_New_Motion_Sensors"] = function()
	if can() then
		state.motion:import_new(function(_, text) last_action(text) end)
	end
end

dispatch.commands["Add_Motion_Area"] = function(params)
	if not can() then return end
	local rid = selection(params, "Area")
	if not rid then
		return last_action("Not added: pick a MotionAware area first")
	end
	state.motion:add(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Re-link_Motion_Device"] = function(params)
	if not can() then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Target")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a sensor or area")
	end
	local _, text = state.motion:relink(device, rid)
	last_action(text)
end

dispatch.commands["Forget_Motion_Device"] = function(params)
	if not can() then return end
	local device = tonumber(selection(params, "Device"))
	if not device then
		return last_action("Not forgotten: pick a device first")
	end
	local _, text = state.motion:forget(device)
	last_action(text)
	refresh_lights_props()
end

dispatch.commands["Log_Motion_Diagnostics"] = function()
	if not can() then return end
	state.motion_diag:run(function(_, text) last_action(text) end)
end

dispatch.commands["HUE_MOTION_HELLO"] = function(params)
	params = params or {}
	-- The link first, so the device knows before its state (#428 D4).
	state.link:tell(tonumber(params.device_id))
	if not state.motion:hello(params) then
		log.debug("HUE_MOTION_HELLO from unregistered motion device %q (device %s)", tostring(params.rid),
			tostring(params.device_id))
	end
end

dispatch.commands["HUE_MOTION_GOODBYE"] = function(params)
	state.motion:goodbye(params or {})
	refresh_lights_props()
end

dispatch.commands["HUE_MOTION_FORGET"] = function(params)
	local _, text = state.motion:forget_request(params or {})
	last_action(text)
	refresh_lights_props()
end

-- Scene actions (docs/scenes-design.md §5) ----------------------------------

dispatch.commands["Add_Scene"] = function(params)
	if not can() then return end
	local rid = selection(params, "Scene")
	if not rid then
		return last_action("Not added: pick a scene first")
	end
	state.scenes:add_scene(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Add_All_Scenes_Of_Room"] = function(params)
	if not can() then return end
	local group = selection(params, "Hue Room")
	if not group then
		return last_action("Not added: pick a Hue room first")
	end
	state.scenes:add_all_of_group(group, function(_, text) last_action(text) end)
end

dispatch.commands["Re-link_Scene"] = function(params)
	if not can() then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Scene")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a scene")
	end
	local _, text = state.scenes:relink(device, rid)
	last_action(text)
end

dispatch.commands["Forget_Scene"] = function(params)
	if not can() then return end
	local device = tonumber(selection(params, "Device"))
	if not device then
		return last_action("Not forgotten: pick a device first")
	end
	local _, text = state.scenes:forget(device)
	last_action(text)
end

-- Refresh All (#324): every list read from the bridge now, stream or not.
dispatch.commands["Refresh_All"] = function()
	if not can() then return end
	want_resync("full", "click", function(ok, text)
		if ok then
			last_action(string.format("Refreshed from the bridge: Lights: %s | Scenes: %s | Zone lights: %s | Motion: %s",
				tostring(state.lights:summary()), tostring(state.scenes:summary()),
				tostring(state.zone_lights:summary()), tostring(state.motion:summary())))
		else
			last_action("Read everything from the bridge: " .. tostring(text))
		end
	end)
end

dispatch.commands["Refresh_Scenes"] = function()
	if not can() then return end
	state.scenes:resync(function(ok, err)
		if ok then
			last_action("Scenes refreshed: " .. tostring(state.scenes:summary()))
		else
			last_action("Scene refresh failed: " .. tostring(err))
		end
	end)
end

-- Messages from scene devices (docs/scenes-design.md §2).
dispatch.commands["HUE_SCENE_HELLO"] = function(params)
	params = params or {}
	-- The link first, so the device knows before its state (#428 D4).
	state.link:tell(tonumber(params.device_id))
	-- hello(rid, params): the rid is a separate argument, as for lights.
	if not state.scenes:hello(params.rid or "", params) then
		log.debug("HUE_SCENE_HELLO not answered for %q (device %s)", tostring(params.rid), tostring(params.device_id))
	end
end

dispatch.commands["HUE_SCENE_RECALL"] = function(params)
	state.scenes:recall(params or {})
end

dispatch.commands["HUE_SCENE_OFF"] = function(params)
	state.scenes:off(params or {})
end

dispatch.commands["HUE_SCENE_DIM"] = function(params)
	state.scenes:dim(params or {})
end

dispatch.commands["HUE_SCENE_LEVEL"] = function(params)
	state.scenes:level(params or {})
end

dispatch.commands["HUE_SCENE_GOODBYE"] = function(params)
	state.scenes:goodbye(params or {})
	refresh_lights_props()
end

dispatch.commands["HUE_SCENE_FORGET"] = function(params)
	if can() then
		local _, text = state.scenes:forget_request(params or {})
		last_action(text)
	end
end

-- The light's limits go to the command queue only when they changed: a
-- slider tick used to build three tables per light for nothing
-- (docs/reviews/efficiency-2026-10-24.md R4).
local function set_light_limits(rid)
	local limits = state.lights:limits(rid) or {}
	local sent = state.limits_sent[rid]
	if sent and sent.min_dim == limits.min_dim and sent.mirek_min == limits.mirek_min
		and sent.mirek_max == limits.mirek_max then
		return
	end
	state.limits_sent[rid] = { min_dim = limits.min_dim, mirek_min = limits.mirek_min, mirek_max = limits.mirek_max }
	state.queue:limits(rid, limits)
end

-- From a light driver: a proxy command mapped to Hue fields (strings).
dispatch.commands["HUE_SET"] = function(params)
	params = params or {}
	local rid = params.rid
	if is_zone_light_rid(rid) then
		return state.zone_lights:set(params)
	end
	if not rid or rid == "" or not state.lights:device_for(rid) then
		log.warn("HUE_SET for unknown light %s", tostring(rid))
		return
	end
	local fields = {
		brightness = tonumber(params.brightness),
		x = tonumber(params.x),
		y = tonumber(params.y),
		mirek = tonumber(params.mirek),
		rate = tonumber(params.rate),
		-- A keypad tap's start, or a tap stop sent as a level, goes out at once,
		-- past the request bucket (#421 D12, commands.urgent).
		urgent = (params.urgent == "true" or params.urgent == true) or nil,
	}
	if params.on == "true" then fields.on = true elseif params.on == "false" then fields.on = false end
	if log.enabled("info") then
		log.info("HUE_SET %s: on=%s brightness=%s x=%s y=%s mirek=%s rate=%s%s", rid:sub(1, 8), tostring(fields.on),
			tostring(fields.brightness), tostring(fields.x), tostring(fields.y), tostring(fields.mirek),
			tostring(fields.rate), fields.urgent and " urgent" or "")
	end
	set_light_limits(rid)
	state.queue:set(rid, fields)
end

-- HUE_DIM { rid, direction up | down | stop, duration ms, level }: a keypad
-- hold on a Hue Light, as Hue's relative dim (docs/keypad-design.md). The
-- level goes with a stop and is written only if the bridge refuses the stop.
dispatch.commands["HUE_DIM"] = function(params)
	params = params or {}
	local rid = params.rid
	if is_zone_light_rid(rid) then
		return state.zone_lights:dim(params)
	end
	if not rid or rid == "" or not state.lights:device_for(rid) then
		log.warn("HUE_DIM for unknown light %s", tostring(rid))
		return
	end
	local dir = params.direction
	if dir ~= "up" and dir ~= "down" and dir ~= "stop" then
		log.warn("HUE_DIM %s: unknown direction %s", rid:sub(1, 8), tostring(dir))
		return
	end
	if log.enabled("info") then
		log.info("HUE_DIM %s: %s duration=%s level=%s", rid:sub(1, 8), dir, tostring(params.duration),
			tostring(params.level))
	end
	set_light_limits(rid)
	state.queue:set(rid, { dim = dir, rate = tonumber(params.duration), level = tonumber(params.level) })
end

-- From a light driver at its startup or binding: resend its configuration
-- and state.
dispatch.commands["HUE_HELLO"] = function(params)
	params = params or {}
	-- The link first, so the device knows before its state (#428 D4).
	state.link:tell(tonumber(params.device_id))
	local rid = params.rid or ""
	if params.kind == "group" then
		if not state.zone_lights:hello(params) then
			log.debug("HUE_HELLO from unregistered zone light %q (device %s)", tostring(rid), tostring(params.device_id))
		end
		return
	end
	if not state.lights:hello(rid, params) then
		log.debug("HUE_HELLO from unregistered light %q (device %s)", tostring(rid), tostring(params.device_id))
	end
end

dispatch.commands["Connect_Event_Stream"] = function()
	if not connection() then
		prop("Event Stream", "Not paired")
		return
	end
	local refusal = keyed_refusal()
	if refusal then
		prop("Event Stream", "Not connected: " .. refusal)
		return
	end
	if not state.stream_ip then
		return choose_stream_address(function() restart_stream(true) end)
	end
	state.stream:start()
end

dispatch.commands["Disconnect_Event_Stream"] = function()
	state.outage_restart = nil -- an outage check in flight does not start it again
	state.stream:stop()
end

dispatch.commands["Forget_Pairing"] = function()
	pair_window:close()
	if state.hk then
		state.hk:reset(state.address_gen, true)
	end
	state.identity_ok = nil
	state.identity_text = nil
	state.identity:reset()
	net_gate:reset()
	state.stream:stop()
	-- No stale bridge address left on the stream's network binding (#317).
	netstream.clear_address()
	credentials.clear()
	state.creds = nil
	state.bridge_model = nil
	state.stream_ip = nil
	state.stream_family = nil
	prop("Stream Address", "")
	prop("Bridge Model", "")
	prop("Bridge Name", "")
	prop("Bridge Firmware", "")
	prop("Events Received", 0)
	prop("Last Event", "")
	-- Nothing is paired: no outage, nothing away or moved (bridge/away.lua).
	state.away:forget()
	refresh_status()
	-- Bridges Found reads the unpaired summary at once, and the first-load
	-- searches start again (§4 finding 2).
	state.bridges_found:show()
	state.bridges_found:restart()
end

-- Bindings and system events --------------------------------------------------

-- Director answers nil, not an empty table, when nothing is bound to the
-- bridge [verified: hardware 2026-10-25]; the modules read one nil as
-- unknown and a second one, NIL_CONFIRM_S later, as "nothing bound"
-- (bridge/project.lua). When the lookup answers nil, the three modules
-- reconcile once more after that, so removing the last binding is noticed.
local function confirm_unbound_later()
	local ok, bound = pcall(project_calls.bound)
	if not ok or type(bound) == "table" then
		return
	end
	if state.unbound_confirm_timer then
		state.unbound_confirm_timer:Cancel()
	end
	state.unbound_confirm_timer = C4:SetTimer((project_mod.NIL_CONFIRM_S + 1) * 1000, function()
		state.unbound_confirm_timer = nil
		state.lights:reconcile()
		state.scenes:reconcile()
		state.zone_lights:reconcile()
		state.motion:reconcile()
		refresh_lights_props()
	end)
end

-- Director reports changes to the HUE_BRIDGE control binding here [verified:
-- API 9/_12]; the three registries settle against it. Before late init the
-- modules do not exist yet; the startup reconcile covers the bindings then.
function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
	if log.enabled("debug") then
		log.debug("OnBindingChanged(%s, %s, %s, %s, %s)", tostring(idBinding), tostring(strClass), tostring(bIsBound),
			tostring(otherDeviceID), tostring(otherBindingID))
	end
	if state.scenes then
		state.scenes:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
	end
	if state.zone_lights then
		state.zone_lights:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
	end
	if state.motion then
		state.motion:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
	end
	if state.lights then
		state.lights:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
		refresh_lights_props()
		-- Director settles the binding tables after the callback; the SDK's
		-- own sample re-enumerates a second later [verified: sample idc_controller].
		-- One reconcile for a burst: a project load with N bindings used to
		-- run N (docs/reviews/efficiency-2026-10-24.md R5, security finding 11).
		if state.binding_reconcile_timer then
			state.binding_reconcile_timer:Cancel()
		end
		state.binding_reconcile_timer = C4:SetTimer(1000, function()
			state.binding_reconcile_timer = nil
			state.lights:reconcile()
			refresh_lights_props()
			confirm_unbound_later()
		end)
	end
end

-- Called before Director adds a binding [verified: API 32/_26]; only the
-- HUE_BRIDGE class belongs here [assumed: returning false rejects].
function OnBindingValidate(idBinding, strClass)
	local ok = strClass == "HUE_BRIDGE"
	log.debug("OnBindingValidate(%s, %s) -> %s", tostring(idBinding), tostring(strClass), tostring(ok))
	return ok
end

-- The project events a driver can register for [verified: API 7/_1, 7/_5.5];
-- the names come from Control4's own handlers.lua. OnItemNameChanged is the
-- one acted on (a rename in Composer); the others are logged in Debug Mode,
-- as the probe of docs/import-design.md §11 did, since their payloads are
-- not documented.
local PROBE_EVENTS = { "OnItemAdded", "OnItemRemoved", "OnItemNameChanged", "OnItemMoved",
	"OnDeviceUserInitiatedRemove", "OnPIP" }

local function register_probe_events()
	if type(C4SystemEvents) ~= "table" or type(C4.RegisterSystemEvent) ~= "function" then
		return log.debug("system events unavailable in this runtime")
	end
	for _, name in ipairs(PROBE_EVENTS) do
		local id = C4SystemEvents[name]
		if id then
			local ok, err = pcall(C4.RegisterSystemEvent, C4, id, 0)
			if not ok then
				log.warn("RegisterSystemEvent %s: %s", name, tostring(err))
			end
		else
			log.debug("no system event named %s", name)
		end
	end
end

function OnSystemEvent(data)
	if log.enabled("debug") then
		log.debug("OnSystemEvent: %s", tostring(data):sub(1, 600))
	end
	-- A rename in Composer changes what Attention compares; without this it
	-- stayed stale until the next action or resync [hardware 2026-10-22].
	if state.late_init_done and type(data) == "string" and data:find("OnItemNameChanged", 1, true) then
		-- Two-way names (owner's answer D6): a light, scene or motion device
		-- renamed in Composer is renamed on the bridge (bridge/names.lua reads
		-- the new name itself; other items' ids are ignored there).
		local id = tonumber(data:match('name="iditem"[^>]*>%s*(%d+)') or data:match('iditem="?(%d+)')
			or data:match("<iditem>%s*(%d+)%s*</iditem>"))
		if state.names and id then
			state.names:on_composer_rename(id)
		end
		refresh_lights_props()
	end
end

-- Lifecycle ----------------------------------------------------------------

-- Messages from light and scene drivers can arrive before this driver's
-- late init (Director's inter-driver order is not guaranteed) and the
-- handlers index state that does not exist yet [code analysis 2026-10-22,
-- H1]: hellos are queued and replayed after late init, anything else dropped.
local EARLY_QUEUED = { HUE_HELLO = true, HUE_SCENE_HELLO = true, HUE_MOTION_HELLO = true }
local EARLY_MAX = 200
local early_commands = {}
local execute_command = dispatch.execute_command
dispatch.execute_command = function(command, params)
	if not state.late_init_done then
		local name = command
		if command == "LUA_ACTION" and type(params) == "table" and params.ACTION then
			name = params.ACTION
		end
		if EARLY_QUEUED[name] and #early_commands < EARLY_MAX then
			early_commands[#early_commands + 1] = { command, params }
			log.debug("%s before late init: queued", tostring(name))
		else
			log.warn("%s before late init: dropped", tostring(name))
		end
		return
	end
	return execute_command(command, params)
end

local function replay_early_commands()
	local queued = early_commands
	early_commands = {}
	for _, c in ipairs(queued) do
		execute_command(c[1], c[2])
	end
end

log.set_prefix("Hue Bridge")
dispatch.install(_G)

-- Dev builds: the development handlers, with what they need handed over
-- explicitly (bridge/devtools.lua). Composer's DEV-ONLY actions and
-- HUE_LOG join the dispatch table; the rest, Test Connection's Host
-- variant included, answer signed dev loop commands only.
if devtools then
	devtools.install({
		state = state,
		prop = prop,
		connection = connection,
		paired = paired,
		bridge_request = bridge_request,
		restart_stream = restart_stream,
		test_connection = test_connection,
		last_action = last_action,
	})
end

-- The merged actions of 1.2 (bridge/actions.lua, docs/simplify-actions-design.md §3.3, §3.4) ----------

-- The beta 8 handlers the new actions run (Diagnostics' entries, Import All
-- New), taken before the aliases below take their keys over.
local beta8 = {}
for _, key in ipairs({ "Test_Connection", "Refresh_All", "Connect_Event_Stream", "Disconnect_Event_Stream",
	"Log_Motion_Diagnostics" }) do
	beta8[key] = dispatch.commands[key]
end

local D = actions_mod.DIAGNOSTICS
-- Diagnostics' entries; the dev ones run bridge/devtools.lua's handlers,
-- which exist in dev builds only (looked up when run).
local function dev_command(key, params)
	return function()
		local fn = dispatch.commands[key]
		if fn then fn(params or {}) end
	end
end
local diagnostics = {
	[D.TEST] = { order = 1, text = "Check the connection now", shows = "Status",
		run = function() beta8.Test_Connection() end },
	[D.REFRESH] = { order = 2, text = "Read everything from the bridge now", run = function() beta8.Refresh_All() end },
	[D.CONNECT] = { order = 3, text = "Reconnect the event stream", shows = "Event Stream",
		run = function() beta8.Connect_Event_Stream() end },
	[D.DISCONNECT] = { order = 4, text = "Stop the event stream until the next start", shows = "Event Stream",
		run = function() beta8.Disconnect_Event_Stream() end },
	[D.MOTION_LOG] = { order = 5, text = "Log motion diagnostics (10 minutes)",
		run = function() beta8.Log_Motion_Diagnostics() end },
	[D.CONNECTION_TEST_BRIDGE] = { order = 6, dev = true, text = "(dev) Connection experiment: the bridge",
		run = dev_command("Connection_Test", { Target = "Bridge" }) },
	[D.CONNECTION_TEST_SERVER] = { order = 7, dev = true, text = "(dev) Connection experiment: the diagnostic server",
		run = dev_command("Connection_Test", { Target = "Diagnostic Server" }) },
	[D.RELOAD_CREDENTIALS] = { order = 8, dev = true, text = "(dev) Reload credentials",
		run = dev_command("Reload_Credentials") },
	[D.CHECK_PINNING] = { order = 9, dev = true, text = "(dev) Check CA pinning", run = dev_command("Check_CA_Pinning") },
}

local function new_actions()
	return actions_mod.new({
		lights = state.lights, scenes = state.scenes, zone_lights = state.zone_lights, motion = state.motion,
		names = state.names, last_action = last_action, can = can, diagnostics = diagnostics, dev = devtools ~= nil,
		log = log, before_names = fill_proxy_ids,
	})
end

local function actions_list(method, folder)
	if not state.actions then
		return { { text = "(not ready yet; open the list again)", value = "" } }
	end
	return state.actions[method](state.actions, folder)
end

function AddFromHueList(folder) return actions_list("add_list", folder) end
function RoomList() return actions_list("room_list") end
function LinkDeviceList(folder) return actions_list("link_list", folder) end
function LinkTargetList(folder) return actions_list("link_target_list", folder) end
function ForgetDeviceList(folder) return actions_list("forget_list", folder) end
function ResolveNamesList() return actions_list("names_list") end
function DiagnosticsList() return actions_list("diagnostics_list") end

dispatch.commands["Add_From_Hue"] = function(params) state.actions:run_add(params) end
dispatch.commands["Link_Device"] = function(params) state.actions:run_link(params) end
dispatch.commands["Forget_Device"] = function(params) state.actions:run_forget(params) end
dispatch.commands["Resolve_Names"] = function(params) state.actions:run_names(params) end
dispatch.commands["Diagnostics"] = function(params) state.actions:run_diagnostics(params) end

-- Import All New: the lights, then the motion sensors, each into the room
-- its Hue room maps to (§1.2 action 2).
dispatch.commands["Import_All_New"] = function()
	if not can() then return end
	state.lights:import_new(function(_, lights_text)
		state.motion:import_new(function(_, motion_text)
			last_action(tostring(lights_text) .. " | Motion: " .. tostring(motion_text))
		end)
	end)
end

-- Forget Pairing asks for confirmation (§3.3).
local forget_pairing = dispatch.commands["Forget_Pairing"]
dispatch.commands["Forget_Pairing"] = function(params)
	if (params or {}).Confirm ~= actions_mod.CONFIRM_YES then
		return last_action(actions_mod.NOT_CONFIRMED)
	end
	forget_pairing(params)
	last_action("Pairing forgotten: the key is gone and the event stream stopped; devices and the address are kept")
end

-- Set Room Mapping's second picker is "Control4 Room" in 1.2; "Room" still
-- arrives from the dev loop and older briefs.
local set_room_mapping = dispatch.commands["Set_Room_Mapping"]
dispatch.commands["Set_Room_Mapping"] = function(params)
	params = params or {}
	if params["Control4 Room"] ~= nil and params.Room == nil then
		params.Room = params["Control4 Room"]
	end
	return set_room_mapping(params)
end

-- Every beta 8 command merged into bridge/actions.lua answers until 2.0.
for old in pairs(actions_mod.ALIASES) do
	dispatch.commands[(old:gsub("%s+", "_"))] = function(params) state.actions:run_alias(old, params) end
end

-- Bridges Found (owner's answer D5; discovery research §2.4): the bridges
-- that answered on the local network, never the internet, as a list row
-- (bridge/bridges_found.lua). A pick sets Bridge IP Address and runs Pair
-- Bridge, which then pairs the picked bridge only.

-- The driver's own UpdateProperty fires no OnPropertyChanged, so the
-- property's handler runs here (discovery research finding 7).
local function set_bridge_address(ip)
	C4:UpdateProperty("Bridge IP Address", ip)
	dispatch.properties["Bridge_IP_Address"](ip)
end

state.bridges_found = bridges_found_mod.new({
	state = state,
	paired = paired,
	rows = rows,
	last_action = last_action,
	refresh = refresh_lights_props,
	set_address = set_bridge_address,
	pair = function() dispatch.commands["Pair_Bridge"]() end,
	log = log,
})

dispatch.properties["Bridges_Found"] = function(value)
	state.bridges_found:on_pick(value)
end

-- The background tasks (contract §1.3, §3.1; scheduler research §5): defined
-- in bridge/tasks.lua on the engine of bridge/housekeeping.lua.
local function start_housekeeping(dit)
	local hk = tasks_mod.new({
		state = state,
		http = bridge_request,
		log = log,
		user_active = user_active,
		connection = connection,
		keyed_refusal = keyed_refusal,
		resync_all = resync_all,
		recheck_key = recheck_key,
		last_action = last_action,
		set_address = set_bridge_address,
		now_ms = now_ms,
	})
	state.hk = hk
	hk:start(dit)
	if state.key_rejected then
		hk:poke("key_recheck", "error")
	end
end

function OnDriverInit()
end

function OnDriverLateInit(dit)
	state.creds = credentials.load()
	log.info("credentials at startup: %s", credentials.summary(state.creds))
	state.away:load() -- the last good address and the last move, from the store
	state.link:load() -- an outage that outlived the last run (#428 D12)
	state.lights = new_lights()
	state.lights:load()
	-- Configure every known light from the persisted registry before any
	-- GET: a light that restarted with us gets its capabilities at once.
	state.lights:configure_all()
	state.queue = new_queue()
	state.group_queue = new_group_queue()
	-- Keypad holds on scenes, zone lights and room lights (#249): per-light
	-- dims through the light queue for up to 10 lamps, stepped group dims above
	-- that or while a scene runs, the group queue as before otherwise. Read
	-- live: the zone lights and scenes are created below, and the lights'
	-- models change at resyncs.
	state.group_hold = group_hold_mod.new({
		members = function(grouped_light_rid)
			return state.zone_lights and state.zone_lights:lights_of_grouped_light(grouped_light_rid) or {}
		end,
		is_on = function(light_rid)
			local model = state.lights and state.lights:record_of(light_rid)
			return model ~= nil and model.on == true
		end,
		light_set = function(light_rid, fields)
			if not state.queue then
				return false
			end
			state.queue:set(light_rid, fields)
			return true
		end,
		group_set = function(grouped_light_rid, fields)
			if not state.group_queue then
				return false
			end
			state.group_queue:set(grouped_light_rid, fields)
			return true
		end,
		set_timer = function(ms, fn) return C4:SetTimer(ms, fn) end, -- [verified: API 34/_1]
		keep_group = function(grouped_light_rid)
			return state.scenes ~= nil and state.scenes:scene_running_on(grouped_light_rid) == true
		end,
		log = log,
	})
	state.scenes = scenes_mod.new(module_ctx())
	state.scenes:load()
	state.scenes:configure_all()
	state.scenes:reconcile()
	state.zone_lights = zone_lights_mod.new(module_ctx({ groups = state.lights.groups }))
	state.zone_lights:load()
	state.zone_lights:configure_all()
	state.zone_lights:reconcile()
	state.motion = motion_mod.new(module_ctx({ groups = state.lights.groups }))
	state.motion:load()
	state.motion:configure_all()
	state.motion:reconcile()
	-- The diagnostics' output goes into public issues: everything that
	-- identifies this bridge is scrubbed from every line (docs/motion-design.md §4.3).
	-- Attention items that wait an hour (a sensor unreachable, an area
	-- degraded, no motion reading: docs/motion-design.md D5) come due without
	-- any event to refresh the rows: look again every five minutes. The rows
	-- are sent only when they changed.
	state.rows_timer = C4:SetTimer(300000, function() refresh_lights_props() end, true)
	state.motion_diag = motion_diag_mod.new(module_ctx({
		secrets = function()
			return { key = state.creds and state.creds.key, ip = state.ip,
				bridge_id = state.creds and state.creds.bridge_id }
		end,
		on_done = function(text) last_action(text) end,
	}))
	-- Two-way names (D6, D11; bridge/names.lua). Its writes go through
	-- bridge_request like a person's, so the background tasks give way.
	local registries = { light = state.lights, scene = state.scenes, motion = state.motion,
		zone_light = state.zone_lights }
	state.names = names_mod.new({
		persist_get = function(key) return C4:PersistGetValue(key) end,
		persist_set = function(key, value) C4:PersistSetValue(key, value) end,
		registries = registries,
		put_name = names_mod.put_via(registries, bridge_request, log),
		rename_device = function(id, name) C4:RenameDevice(id, name) end,
		display_name = function(id) return C4:GetDeviceDisplayName(id) end,
		proxy_of = function(device_id)
			local consumers = C4:GetBoundConsumerDevices(device_id, 5001)
			return type(consumers) == "table" and next(consumers) or nil
		end,
		user_active = user_active,
		bridge_ready = function()
			return connection() ~= nil and state.identity_ok == true and keyed_refusal() == nil
		end,
		last_action = function(text) last_action(text) end,
		attention_changed = function() refresh_lights_props() end,
		set_timer = function(ms, fn) return C4:SetTimer(ms, fn) end,
		now_ms = function() return C4:GetTime() end,
		wall = os.time,
		log = log,
	})
	for _, m in ipairs({ state.lights, state.scenes, state.zone_lights, state.motion }) do
		m:set_names(state.names)
		-- The re-link by radio (D7) says what it did in Last Action.
		m.ctx.last_action = last_action
	end
	state.names:migrate(driver_version())
	state.actions = new_actions()
	-- Bindings are complete at late init [verified: FUND 28/_3]: settle which
	-- registered devices are still bound and present (docs/import-design.md §5).
	local r = state.lights:reconcile()
	log.info("startup reconcile: %d unbound, %d relinked, %d deleted in Composer",
		#(r.unbound or {}), #(r.relinked or {}), #(r.tombstoned or {}))
	fill_proxy_ids()
	confirm_unbound_later()
	refresh_lights_props()
	dispatch.replay_properties(Properties)
	show_driver_version(1)
	-- Last Action's continuation rows that still hold text from before the
	-- restart stay shown, the empty ones are hidden.
	last_action_rows:settle(Properties)
	if state.stream then
		state.stream:stop() -- never two objects on the binding (netstream.lua)
	end
	state.stream = new_stream()
	state.late_init_done = true
	state.discovery = discovery_mod.new({ identify = pairing.probe, log = log })
	start_housekeeping(dit)
	state.bridges_found:show()
	state.bridges_found:schedule()
	replay_early_commands()
	register_probe_events()
	refresh_status()
	-- A true Event Stream text until the stream starts (#236): the row may
	-- still hold its text from before the restart while the identity or TLS
	-- check is pending or failing.
	show_stream_waiting()
	if connection() then
		choose_stream_address(function() restart_stream(true) end)
	end
	-- Dev builds: the dev loop starts last, so a reload pushed through it
	-- sees a fully initialised driver.
	if devtools then
		devtools.late_init()
	end
end

-- Director ends the old code with its Lua state and kills its timers
-- (API 22_miscellaneous/_24-OnDriverDestroyed.md); a dev loop reload keeps
-- both (src/common/devloop.lua). So everything in flight here, an identity
-- or TLS check above all, must start nothing once it answers: a stream
-- started by unloaded code holds binding 6001 beside the new code's, never
-- sees a report, and ends the new code's connection with its own connect
-- timeout and retries (the flapping of 2026-11-05).
function OnDriverDestroyed()
	state.destroyed = true
	pair_window:close()
	state.away:cancel_outage_check()
	state.link:cancel()
	attention_rows:cancel()
	last_action_rows:cancel()
	if state.hk then
		state.hk:stop()
	end
	if state.discovery then
		state.discovery:stop()
	end
	state.bridges_found:stop()
	rows:stop()
	if state.binding_reconcile_timer then
		state.binding_reconcile_timer:Cancel()
		state.binding_reconcile_timer = nil
	end
	if state.unbound_confirm_timer then
		state.unbound_confirm_timer:Cancel()
		state.unbound_confirm_timer = nil
	end
	state.identity:cancel_retry()
	net_gate:reset() -- closes, clears and removes the probe binding of a check in flight (#329)
	if version_timer then
		version_timer:Cancel()
		version_timer = nil
	end
	if state.stream then
		state.stream:stop()
	end
	netstream.retire() -- and no object of this code's netstream connects again
	if state.group_hold then
		state.group_hold:stop_all() -- before the queues: no step lands in a stopped queue
	end
	if state.queue then
		state.queue:stop()
	end
	if state.group_queue then
		state.group_queue:stop()
	end
end

-- The network-connection stream's callbacks (docs/raw-stream-design.md §0,
-- #317): Director calls these globals for binding 6001; a Web transfer
-- stream has no such entry points and ignores them. Bindings 6100 to 6999
-- are the network connection's TLS check (bridge/netcheck.lua), never the stream.
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if netcheck.on_status_changed(idBinding, nPort, strStatus) then
		return
	end
	-- Binding 6008: the mDNS search of bridge/discovery.lua.
	if state.discovery and state.discovery:status_changed(idBinding, nPort, strStatus) then
		return
	end
	local s = state.stream
	if s and s.on_status_changed then
		s:on_status_changed(idBinding, nPort, strStatus)
	end
end

-- `from` (the sender) is passed from OS 4.0.0 on only [verified: SDK
-- 32_serial_network_device/_15-ReceivedFromNetwork].
function ReceivedFromNetwork(idBinding, nPort, strData, from)
	if netcheck.on_data(idBinding, strData) then
		return
	end
	if state.discovery and state.discovery:received(idBinding, nPort, strData, from) then
		return
	end
	local s = state.stream
	if s and s.on_data then
		s:on_data(idBinding, strData)
	end
end
