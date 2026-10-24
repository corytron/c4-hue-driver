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
local lights_mod = require("bridge.lights")
local scenes_mod = require("bridge.scenes")
local zone_lights_mod = require("bridge.zone_lights")
local commands = require("bridge.commands")

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
	queue = nil,         -- bridge.commands coalescer, created in OnDriverLateInit
	group_queue = nil,   -- the same for grouped_light (scene OFF)
	late_init_done = false,
}

-- Stream timeout in single-queue mode: commands wait for the stream to
-- end, so it must end often.
local SINGLE_QUEUE_TIMEOUT = 60

-- Persisted spelling of the last stream transfer, so a reloaded driver does
-- not reuse the one its predecessor's abandoned transfer still holds.
local STREAM_SPELLING_KEY = "hue_stream_spelling"

-- The rows the stream rewrites per event (`Events Received`, `Last Event`,
-- `Event Stream`) are written at most once a second each: a row's first
-- value of a burst at once, its latest when the one-shot timer fires a
-- second later (so the final value always lands), and the timer stays armed
-- while values keep coming. A direct prop() of the same row ("Stopped",
-- Forget Pairing's 0) wins over a value still waiting.
local PROP_SOON_MS = 1000
local prop_soon_pending = {}   -- name -> the latest value, waiting for the timer
local prop_soon_written = {}   -- name -> true once written in the current second
local prop_soon_timer = nil

local function prop(name, value)
	prop_soon_pending[name] = nil
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

local function flush_prop_soon()
	prop_soon_timer = nil
	local pending = prop_soon_pending
	prop_soon_pending, prop_soon_written = {}, {}
	if next(pending) == nil then
		return
	end
	for name, value in pairs(pending) do
		prop_soon_written[name] = true
		prop(name, value)
	end
	prop_soon_timer = C4:SetTimer(PROP_SOON_MS, flush_prop_soon)
end

local function prop_soon(name, value)
	if prop_soon_written[name] then
		prop_soon_pending[name] = value
	else
		prop_soon_written[name] = true
		prop(name, value)
	end
	if not prop_soon_timer then
		prop_soon_timer = C4:SetTimer(PROP_SOON_MS, flush_prop_soon)
	end
end

-- A list property (driver.xml DYNAMIC_LIST): the drop-down holds `items`,
-- `value` (default the first item) is what the row shows. Comma-delimited
-- (SDK 24_properties/_6-UpdatePropertyList); the list's default alone did
-- not move the row after a pick in Composer (build 184), so the value is
-- set as well.
local function prop_list(name, items, value)
	value = value or items[1]
	C4:UpdatePropertyList(name, table.concat(items, ","), value)
	C4:UpdateProperty(name, value)
end

local function paired()
	return credentials.paired(state.creds)
end

local function refresh_status()
	if not state.ip then
		prop("Status", "Enter the bridge IP address")
	elseif not paired() then
		prop("Status", "Not paired: press the link button, then run Pair Bridge")
	else
		prop("Status", "Paired")
	end
	prop("Bridge ID", paired() and state.creds.bridge_id or "")
end

-- What the stream needs to connect, or nil when it can't.
local function connection()
	if state.ip and paired() then
		return { ip = state.ip, key = state.creds.key }
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

-- What the stream connects with. The stream calls this for every attempt,
-- so each connection gets the next spelling.
local function stream_connection()
	local conn = connection()
	if conn then
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
local function bridge_request(req, callback)
	if not connection() then
		return callback({ ok = false, err = "not paired" })
	end
	if state.identity_ok ~= true then
		return callback({ ok = false, err = "bridge identity not verified yet" })
	end
	req.ip = state.ip
	req.key = state.creds.key
	req.tls = nil
	return http.request(req, callback)
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
	C4:SendToDevice(id, command, params)
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
	-- Scene OFF / zone light OFF.
	group_off = function(grouped_light_rid)
		if state.group_queue then
			state.group_queue:set(grouped_light_rid, { on = false })
			return true
		end
		return false
	end,
	-- Hold-to-dim on a keypad: dimming_delta start/stop on the grouped_light
	-- (docs/keypad-design.md). The queue builds the PUT from a "dim" field.
	group_dim = function(grouped_light_rid, body, level)
		local delta = type(body) == "table" and body.dimming_delta or nil
		if not state.group_queue or type(delta) ~= "table" then
			return false
		end
		state.group_queue:set(grouped_light_rid, {
			dim = delta.action,
			delta = delta.brightness_delta,
			rate = type(body.dynamics) == "table" and body.dynamics.duration or nil,
			-- A zone light's stop carries the level it ended at, written
			-- only if the bridge refuses the stop (as the light queue does).
			level = tonumber(level),
		})
		return true
	end,
	-- Absolute fields on the grouped_light: a scene slider while the group's
	-- level is unknown (docs/scene-dimmer-design.md), every zone light
	-- command (docs/zone-light-design.md Decision 5).
	group_set = function(grouped_light_rid, fields)
		if state.group_queue and type(fields) == "table" then
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
-- The lights' Attention text followed by the scenes' and the zone lights' items.
local function attention_text()
	local items = {}
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
	return #items > 0 and table.concat(items, "; ") or "None"
end

-- List rows (`Room Mappings`, `Lights`, `Scenes`, `Zone Lights`, `Last
-- Action`): Composer clips a value at about 75 characters, so the row shows
-- a summary and the drop-down every item on a line of its own. The list is
-- comma-delimited, so a comma in any text becomes "‚". A pick in Composer
-- changes nothing: the row snaps back to the summary (list_rows remembers
-- it, and only a value that left it is reset, so this cannot loop).
local list_rows = {}

local function commaless(text)
	return (tostring(text == nil and "" or text):gsub(",", "‚"))
end

local list_rows_sent = {}

local function show_list(name, summary, items)
	summary = commaless(summary)
	local list = { summary }
	for _, item in ipairs(items or {}) do
		list[#list + 1] = commaless(item)
	end
	list_rows[name] = summary
	-- Director and Composer are told only when the list changed (the lists
	-- are rebuilt at every refresh); a pick clears the memory first.
	local joined = table.concat(list, ",")
	if list_rows_sent[name] ~= joined then
		list_rows_sent[name] = joined
		prop_list(name, list, summary)
	end
end

local function refresh_room_mappings()
	local items, unmapped = state.lights:room_mapping_items()
	if #items == 0 then
		return show_list("Room Mappings", "None; use Map Rooms By Name")
	end
	show_list("Room Mappings", string.format("%d Hue rooms and zones; %d unmapped (open the list to read)",
		#items, unmapped), items)
end

-- A module's summary as the row and its list_items() as the drop-down.
local function show_module_list(name, module)
	show_list(name, module:summary(), module:list_items())
end

local function refresh_lights_props()
	if not state.zone_lights then
		return -- before late init created the modules
	end
	show_module_list("Lights", state.lights)
	prop("Attention", attention_text())
	refresh_room_mappings()
	show_module_list("Scenes", state.scenes)
	show_module_list("Zone Lights", state.zone_lights)
end

local function new_queue()
	return commands.new({
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/light/" .. rid, body = body }, done)
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
		rate_per_sec = 1,
		burst = 3,
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/grouped_light/" .. rid, body = body }, done)
		end,
		-- Where a refused dim stop's fallback estimate starts.
		level_of = function(rid)
			return state.scenes and state.scenes.group_level and state.scenes.group_level[rid] or nil
		end,
	})
end

local function new_stream()
	return stream.new({
		connection = stream_connection,
		timeout = stream_timeout(),
		watchdog = math.max(WATCHDOG_MIN, number_property("Stream Watchdog (s)", stream.DEFAULT_WATCHDOG)),
		-- The per-event rewrite of the row ("Connected since …, N containers,
		-- last …") is coalesced; a state change lands at once.
		on_status = function(text, per_event)
			if per_event then
				prop_soon("Event Stream", text)
			else
				prop("Event Stream", text)
			end
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
			state.lights:resync(function(ok, err, sent)
				if ok then
					log.info("resync done: %d state messages", tonumber(sent) or 0)
				else
					log.warn("resync failed: %s", tostring(err))
				end
				-- The lights' rows at once (the scene catalogue GET that
				-- follows is the slow one), then once more after the chain.
				refresh_lights_props()
				-- The scenes hand their grouped_light items on, so the zone
				-- lights skip their own GET of the same resource.
				state.scenes:resync(function(sok, serr, ssent, grouped)
					if sok then
						log.info("scene resync done: %d state messages", tonumber(ssent) or 0)
					else
						log.warn("scene resync failed: %s", tostring(serr))
					end
					state.zone_lights:resync(function(zok, zerr, zsent)
						if zok then
							log.info("zone light resync done: %d state messages", tonumber(zsent) or 0)
						else
							log.warn("zone light resync failed: %s", tostring(zerr))
						end
						refresh_lights_props()
					end, grouped)
				end)
			end)
		end,
		on_container = function(container)
			-- Fan-out only sends SendToDevice, which is safe inside a C4:url
			-- callback; nothing here starts a transfer.
			state.lights:on_container(container)
			state.scenes:on_container(container)
			state.zone_lights:on_container(container)
			-- A resource appearing or disappearing changes the counts and the
			-- Attention list; plain updates (state, names) do not.
			if container.type == "add" or container.type == "delete" then
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
	if not state.stream then
		return
	end
	local was_running = state.stream:running()
	state.stream:stop()
	state.stream = new_stream()
	if (was_running or force) and connection() then
		state.stream:start()
	end
end

-- Decide which spellings of the bridge address the stream uses (docs/design.md,
-- "Two ways to keep commands flowing" and "Stream address rotation"). Director
-- queues C4:url transfers per host text, so zero-padded spellings give the
-- stream its own queues, one per connection, rotating so a reconnect never
-- waits for the transfer it replaced. The self-check uses a spelling no
-- stream ever takes, so it can never queue behind a stream or an abandoned
-- one. Calls back when done; until then the stream must not be started.
-- The bridge's identity, checked without the key before any request
-- carries it (docs/reviews/security-2026-10-24.md): GET /api/0/config is
-- public and answers the bridge id. Until it matches the paired id nothing
-- is sent; an unreachable bridge is asked again every 30 s, a different
-- bridge never (it does not become ours by waiting).
local IDENTITY_RETRY_MS = 30000
local identity_timer = nil

local function cancel_identity_retry()
	if identity_timer then
		identity_timer:Cancel()
		identity_timer = nil
	end
end

local function verify_identity(callback)
	cancel_identity_retry()
	local ip = state.ip
	http.request({ ip = ip, path = "/api/0/config", timeout = 10 }, function(r)
		if ip ~= state.ip then
			return -- the address changed meanwhile; its own check runs
		end
		local reported = r.ok and type(r.json) == "table" and config.normalise_bridge_id(r.json.bridgeid) or nil
		if reported and reported == state.creds.bridge_id then
			state.identity_ok = true
			refresh_status()
			return callback(true)
		end
		state.identity_ok = false
		if reported then
			prop("Status", string.format("Bridge at %s reports ID %s, expected %s; nothing is sent until the address "
				.. "is corrected", ip, reported, state.creds.bridge_id))
			log.warn("bridge at %s reports id %s, expected %s: no request is sent", ip, reported, state.creds.bridge_id)
			return callback(false)
		end
		prop("Status", string.format("Bridge at %s not reachable (%s); checking again in %d s", ip,
			tostring(r.ok and "no bridge id in the answer" or r.err), IDENTITY_RETRY_MS / 1000))
		log.warn("bridge identity check via %s failed: %s; again in %d s", ip, tostring(r.err), IDENTITY_RETRY_MS / 1000)
		identity_timer = C4:SetTimer(IDENTITY_RETRY_MS, function()
			identity_timer = nil
			verify_identity(callback)
		end)
	end)
end

local function choose_stream_address(callback)
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
	if state.identity_ok ~= true then
		return verify_identity(function(ok)
			if ok then
				choose_stream_address(callback)
			end
		end)
	end
	if not family or not check_ip then
		return single("no octet below 8 to pad")
	end
	http.request({ ip = check_ip, key = state.creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
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
local function show_driver_version(attempt)
	local v = driver_version()
	prop("Driver Version", v)
	if v == "" and attempt < 3 then
		C4:SetTimer(5000 * attempt, function() show_driver_version(attempt + 1) end)
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
	state.ip = ip
	refresh_status()
	if changed and state.late_init_done then
		state.stream_ip = nil
		state.stream_family = nil
		cancel_identity_retry()
		if ip and paired() then
			credentials.save_ip(ip)
			state.creds.ip = ip
			-- Running now, stopped only while the address was invalid, or
			-- never started because the identity check failed: a corrected
			-- address brings the feed back by itself.
			local was_running = (state.stream and state.stream:running()) or state.stream_paused_by_address
				or state.identity_ok ~= true
			state.stream_paused_by_address = nil
			state.identity_ok = nil
			if state.stream then state.stream:stop() end
			choose_stream_address(function() restart_stream(was_running) end)
		else
			state.stream_paused_by_address = (state.stream and state.stream:running()) or nil
			state.identity_ok = nil
			restart_stream()
		end
	end
end

dispatch.properties["Stream_Timeout_(s)"] = function()
	if state.late_init_done then restart_stream() end
end

dispatch.properties["Stream_Watchdog_(s)"] = function()
	if state.late_init_done then restart_stream() end
end


-- Actions ------------------------------------------------------------------

dispatch.commands["Pair_Bridge"] = function()
	if not state.ip then
		prop("Status", "Enter the bridge IP address first")
		return
	end
	prop("Status", "Pairing: contacting bridge")
	pairing.pair(state.ip, {
		on_probed = function(info)
			prop("Bridge Model", info.model or "")
			prop("Status", string.format("Pairing: found %s %s, requesting key", tostring(info.model), info.bridge_id))
		end,
		on_link_button = function()
			prop("Status", "Press the link button on the bridge, then run Pair Bridge again")
		end,
		on_paired = function(creds)
			-- Use the in-memory result: the store writes on its own thread
			-- and may not return the value yet.
			state.creds = creds
			prop("Bridge Model", creds.model or "")
			refresh_status()
			choose_stream_address(function() restart_stream(true) end)
		end,
		on_error = function(message)
			prop("Status", "Pairing failed: " .. message)
		end,
	})
end

-- GET /clip/v2/resource/bridge with the key via `host` (the dotted address;
-- dev builds may pass another spelling, see bridge/devtools.lua), then the
-- application-layer identity check described in docs/design.md.
local function test_connection(host)
	if not connection() then
		prop("Status", "Not paired")
		return
	end
	prop("Status", "Testing: GET /clip/v2/resource/bridge via " .. host)
	local started = os.time()
	http.request({ ip = host, key = state.creds.key, path = "/clip/v2/resource/bridge" }, function(r)
		local secs = os.time() - started
		log.always("Test Connection via %s: %s after %d s", host, r.ok and "OK" or tostring(r.err), secs)
		if not r.ok then
			if r.code == 401 or r.code == 403 then
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

-- The text as the row; a long text also as its "; "-separated parts in the
-- drop-down, each readable where the row clips.
local function last_action(text)
	text = tostring(text == nil and "" or text)
	log.always("%s", text)
	-- The parts of a long result: the "; "-separated items of an audit or
	-- an import, and the " | "-separated halves of an action the lights,
	-- scenes and zone lights share (Link Devices, the name actions).
	local parts = {}
	if #text > 70 and (text:find("; ", 1, true) or text:find(" | ", 1, true)) then
		for part in (text:gsub(" | ", "; ") .. "; "):gmatch("(.-); ") do
			if part ~= "" then
				parts[#parts + 1] = part
			end
		end
	end
	show_list("Last Action", text, parts)
	refresh_lights_props()
end

-- The lists are for reading: a pick in Composer changes nothing and the row
-- goes back to its summary (only when it left it, so this cannot loop).
local function list_pick(name)
	return function(value)
		if state.late_init_done and list_rows[name] ~= nil and value ~= list_rows[name] then
			list_rows_sent[name] = nil
			if name == "Last Action" then
				last_action(name .. " is for reading; the row shows the text again")
			else
				refresh_lights_props()
				last_action(name .. " is for reading; the row shows the summary again")
			end
		end
	end
end
dispatch.properties["Room_Mappings"] = list_pick("Room Mappings")
dispatch.properties["Lights"] = list_pick("Lights")
dispatch.properties["Scenes"] = list_pick("Scenes")
dispatch.properties["Zone_Lights"] = list_pick("Zone Lights")
dispatch.properties["Last_Action"] = list_pick("Last Action")

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
	return { { text = "(not available in this build)", value = "" } }
end

function HueLightList() return picker(state.lights, "picker_lights") end
function RoomList() return picker(state.lights, "picker_rooms", "add") end
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

local function join_texts(lights_text, scenes_text, zone_lights_text)
	local text = tostring(lights_text)
	if scenes_text ~= nil and scenes_text ~= "" then
		text = text .. " | Scenes: " .. tostring(scenes_text)
	end
	if zone_lights_text ~= nil and zone_lights_text ~= "" then
		text = text .. " | Zone lights: " .. tostring(zone_lights_text)
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
function ForgetDeviceList()
	return join_pickers(picker(state.lights, "picker_forget_devices"),
		picker(state.zone_lights, "picker_forget_devices"))
end

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
			state.zone_lights:link_devices(light_device_ids())))
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
	return filled
end

dispatch.commands["Adopt_Hue_Names"] = function()
	if can() then
		fill_proxy_ids()
		last_action(join_texts(state.lights:adopt_hue_names(), state.scenes:adopt_hue_names(),
			state.zone_lights:adopt_hue_names()))
	end
end

dispatch.commands["Accept_Names_As_They_Are"] = function()
	if can() then
		last_action(join_texts(state.lights:accept_names(), state.scenes:accept_names(),
			state.zone_lights:accept_names()))
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
	}
	if params.on == "true" then fields.on = true elseif params.on == "false" then fields.on = false end
	if log.enabled("info") then
		log.info("HUE_SET %s: on=%s brightness=%s x=%s y=%s mirek=%s rate=%s", rid:sub(1, 8), tostring(fields.on),
			tostring(fields.brightness), tostring(fields.x), tostring(fields.y), tostring(fields.mirek),
			tostring(fields.rate))
	end
	state.queue:limits(rid, state.lights:limits(rid))
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
	state.queue:limits(rid, state.lights:limits(rid))
	state.queue:set(rid, { dim = dir, rate = tonumber(params.duration), level = tonumber(params.level) })
end

-- From a light driver at its startup or binding: resend its configuration
-- and state.
dispatch.commands["HUE_HELLO"] = function(params)
	params = params or {}
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
	if not state.stream_ip then
		return choose_stream_address(function() restart_stream(true) end)
	end
	state.stream:start()
end

dispatch.commands["Disconnect_Event_Stream"] = function()
	state.stream:stop()
end

dispatch.commands["Forget_Pairing"] = function()
	state.identity_ok = nil
	cancel_identity_retry()
	state.stream:stop()
	credentials.clear()
	state.creds = nil
	state.stream_ip = nil
	state.stream_family = nil
	prop("Stream Address", "")
	prop("Bridge Model", "")
	prop("Events Received", 0)
	prop("Last Event", "")
	refresh_status()
end

-- Bindings and system events --------------------------------------------------

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
	if state.lights then
		state.lights:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
		refresh_lights_props()
		-- Director settles the binding tables after the callback; the SDK's
		-- own sample re-enumerates a second later [verified: sample idc_controller].
		C4:SetTimer(1000, function()
			state.lights:reconcile()
			refresh_lights_props()
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
		refresh_lights_props()
	end
end

-- Lifecycle ----------------------------------------------------------------

-- Messages from light and scene drivers can arrive before this driver's
-- late init (Director's inter-driver order is not guaranteed) and the
-- handlers index state that does not exist yet [code analysis 2026-10-22,
-- H1]: hellos are queued and replayed after late init, anything else dropped.
local EARLY_QUEUED = { HUE_HELLO = true, HUE_SCENE_HELLO = true }
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
-- explicitly (bridge/devtools.lua). Registered last, so Test Connection's
-- dev variant (the Host param) replaces the handler above.
if devtools then
	devtools.install({
		state = state,
		prop = prop,
		connection = connection,
		paired = paired,
		bridge_request = bridge_request,
		restart_stream = restart_stream,
		test_connection = test_connection,
	})
end

function OnDriverInit()
end

function OnDriverLateInit()
	state.creds = credentials.load()
	log.info("credentials at startup: %s", credentials.summary(state.creds))
	state.lights = new_lights()
	state.lights:load()
	-- Configure every known light from the persisted registry before any
	-- GET: a light that restarted with us gets its capabilities at once.
	state.lights:configure_all()
	state.queue = new_queue()
	state.group_queue = new_group_queue()
	state.scenes = scenes_mod.new(module_ctx())
	state.scenes:load()
	state.scenes:configure_all()
	state.scenes:reconcile()
	state.zone_lights = zone_lights_mod.new(module_ctx({ groups = state.lights.groups }))
	state.zone_lights:load()
	state.zone_lights:configure_all()
	state.zone_lights:reconcile()
	-- Bindings are complete at late init [verified: FUND 28/_3]: settle which
	-- registered devices are still bound and present (docs/import-design.md §5).
	local r = state.lights:reconcile()
	log.info("startup reconcile: %d unbound, %d relinked, %d deleted in Composer",
		#(r.unbound or {}), #(r.relinked or {}), #(r.tombstoned or {}))
	fill_proxy_ids()
	refresh_lights_props()
	dispatch.replay_properties(Properties)
	show_driver_version(1)
	state.stream = new_stream()
	state.late_init_done = true
	replay_early_commands()
	register_probe_events()
	refresh_status()
	if connection() then
		choose_stream_address(function() restart_stream(true) end)
	else
		prop("Event Stream", paired() and "Waiting for IP address" or "Not paired")
	end
	-- Dev builds: the dev loop starts last, so a reload pushed through it
	-- sees a fully initialised driver.
	if devtools then
		devtools.late_init()
	end
end

function OnDriverDestroyed()
	if prop_soon_timer then
		prop_soon_timer:Cancel()
		prop_soon_timer = nil
	end
	if state.stream then
		state.stream:stop()
	end
	if state.queue then
		state.queue:stop()
	end
	if state.group_queue then
		state.group_queue:stop()
	end
end
