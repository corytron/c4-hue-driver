-- The Hue entertainment areas the bridge knows, and the lamps' return to
-- their state from before a sync (2.0 beta stage 1, #514). The contract is
-- docs/hdmi-sync-stage1-design.md §4.2 to §4.4 (design
-- docs/hdmi-sync-design.md §6.2 and §6.3; contracts C6 and C7 of
-- docs/hdmi-sync-contracts.md). bridge/hue_model.lua parses the CLIP v2
-- items (entertainment_area, entertainment_owners, area_update; field names
-- from docs/entertainment-areas-research.md §2). Nothing here writes an area
-- or Hue's own "light state after streaming" setting.
--
-- What the checks T0 to T9 settle, and what this module assumes until then
-- (contract §2):
--   [assumed, T1] a lamp reports `mode: "streaming"` while it streams and
--                 "normal" after, through an `update` event; the lights module
--                 reads it into the model's `streaming` and calls lamp_mode().
--   [assumed, T2] while a lamp streams, Hue keeps reporting its state from
--                 before the stream, so its current model is its pre-sync state
--                 whenever no earlier one was kept (a reload mid-sync included).
--   [assumed, T7] when a stream stops, the area turns inactive, the lamps'
--                 mode turns normal, and Hue applies its own end state; the
--                 restore waits RESTORE_AFTER_S after the last lamp stops.
--   [assumed, T3] a PUT to a streaming lamp answers 200 without changing it:
--                 never relied on, since no PUT goes to a lamp that streams.
--
-- Interface (contract §4.2):
--   e = entertainment.new(ctx)
--   e:fetch_all(done)          GET entertainment_configuration, then entertainment;
--                              replaces the areas; done(ok). The first fetch after load
--                              fires no on_stream; a later one fires it for each area
--                              whose status changed since the last.
--   e:on_container(container)  entertainment_configuration add, update and delete items
--                              (and entertainment items, which keep the lamp map current);
--                              a stream that starts or stops calls on_stream, a stop starts
--                              the restore.
--   e:lamp_mode(rid, streaming, before)   a lamp's `streaming` changed; keeps the pre-sync
--                              state when it turns true.
--   e:settle()                 end of a lights container or fetch: on_lamps_changed(rids)
--                              once with the lamps lamp_mode named since the last settle.
--   e:is_streaming(rid), e:stream_label(rid), e:areas(), e:row(), e:pre_sync(rid)
--   e:stop()                   every restore timer cancelled (OnDriverDestroyed)
--   entertainment.started_text(area), stopped_text(area), restored_text(area, count)
--                              the bridge's Last Action texts (contract §4.4)
--
-- ctx fields (http required; the rest optional):
--   http(req, cb)              req = { path, method = "GET" }; the driver adds ip and key;
--                              cb(result) with result.ok, result.json, result.err
--   log, now                   common.log / os.time look-alikes
--   set_timer(delay_ms, fn)    C4:SetTimer(delay_ms, fn), an object with Cancel()
--                              [verified: API 34/_1], as bridge/scenes.lua takes it
--   lights                     the bridge.lights instance, or a function returning it:
--                              its `models` (rid -> normalised light, with `streaming`)
--                              and `devices` (for a service without renderer_reference)
--   on_stream(area, started)   an area started (true) or stopped (false) streaming
--   on_lamps_changed(rids)     some lamps' `streaming` changed; once per settle
--   after_sync()               "Put the lights back" (default) or "As Hue decides"
--   put_back(rid, body, done)  one lamp's restore PUT body, through the lights queue;
--                              false when it was not queued; done(result) optional
--   on_restored(area, count)   the restore of an area sent `count` lamps (count > 0)
-- An area handed to on_stream, on_restored and returned by areas() is a copy:
-- { id, id_v1, name, kind, status, streamer, lamps = { rid... }, streaming }.
--
-- The restore (contract §4.3, O11): when an area stops and After A Sync Ends
-- is "Put the lights back", it waits until none of the area's lamps streams
-- (a lamp streaming in another active area does not hold it up), then
-- RESTORE_AFTER_S more; then every lamp of the area with a kept pre-sync
-- state that its current model differs from gets one PUT back to that state
-- (per lamp: coalescing per room or zone is allowed, not needed in stage 1).
-- A lamp still streaming in another area keeps its state for that area's
-- restore. The pre-sync states are dropped then, and with "As Hue decides"
-- without a PUT. Commands that came in during the stream are never applied:
-- only the pre-sync states are sent (design §6.3). Everything is kept in
-- memory only (T2 covers a reload).
--
-- Control4's lighting guidelines (docs/c4-lighting-guidelines.md; the light_v2
-- best practices): one PUT carries a lamp's on, level and colour together, as
-- the best practice on consecutive brightness and colour commands asks; an off
-- state is put back as a bare off, so no colour is set on a lamp that stays
-- off; the restore is a Control4 change that Hue reports back as any other, so
-- the devices' events and programming see it (L6, L68). While a stream runs
-- Hue reports no state for a streamed lamp: departure D21.
--
-- Callback rules as in bridge/lights.lua: the GETs run serially, chained from
-- the http callbacks (OnDone callbacks); on_container runs inside OnBodyChunk
-- and starts no transfer (a restore is only ever sent from its timer); every
-- callback the module makes, and every timer body, is pcall-wrapped.

local hue_model = require("bridge.hue_model")
local util = require("bridge.util")
local rows = require("bridge.rows")
local num = require("common.num")
local log = require("common.log")

local entertainment = {}
entertainment.__index = entertainment

-- The two serial GETs of a resync (design §6.2).
entertainment.RESOURCES = {
	{ kind = "configuration", path = "/clip/v2/resource/entertainment_configuration" },
	{ kind = "entertainment", path = "/clip/v2/resource/entertainment" },
}

-- Seconds after the last of an area's lamps stops streaming before the
-- restore goes out: a constant until check T7 measures when Hue's own end
-- state lands [assumed, T7; research §4.4: one user's lamp read "on" about
-- three seconds after the box powered off].
entertainment.RESTORE_AFTER_S = 3

-- The values of the bridge's property After A Sync Ends (contract §4.4).
entertainment.PUT_BACK = "Put the lights back"
entertainment.AS_HUE = "As Hue decides"
entertainment.AFTER_SYNC = { entertainment.PUT_BACK, entertainment.AS_HUE }

-- Who streams, as the devices and the row say it. Stage 2 names the bound
-- sync box instead (contract §1).
entertainment.OTHER_APP = "another app"

-- The row (contract §4.4) and what it reads without areas.
entertainment.ROW = "Entertainment Areas"
entertainment.NONE = "None"

-- The "differs" rule of the restore (contract §4.3): a brightness more than
-- 1 apart, xy more than 0.002 apart, mirek more than 2 apart.
entertainment.BRIGHTNESS_MARGIN = 1
entertainment.XY_MARGIN = 0.002
entertainment.MIREK_MARGIN = 2

-- A pre-sync state: the model's fields a restore needs.
local PRE_FIELDS = { "on", "brightness", "x", "y", "mirek", "color_mode" }

-- Hue's mirek range when the lamp's own is unknown (bridge/commands.lua's DEFAULT_LIMITS).
local MIREK_MIN, MIREK_MAX = 153, 500

local ROW_SEP = " | "

local function copy_list(list)
	local out = {}
	for i, v in ipairs(type(list) == "table" and list or {}) do
		out[i] = v
	end
	return out
end

local function contains(list, value)
	for _, v in ipairs(type(list) == "table" and list or {}) do
		if v == value then
			return true
		end
	end
	return false
end

local function snapshot(model)
	local out = {}
	for _, name in ipairs(PRE_FIELDS) do
		out[name] = model[name]
	end
	return out
end

-- The area as the callbacks and areas() see it: a copy, with `streaming`.
local function view(area)
	return {
		id = area.id,
		id_v1 = area.id_v1,
		name = area.name,
		kind = area.kind,
		status = area.status,
		streamer = area.streamer,
		lamps = copy_list(area.lamps),
		streaming = area.status == "active",
	}
end

local function sorted_keys(map)
	local out = {}
	for key in pairs(map) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

function entertainment.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "entertainment.new: ctx.http is required")
	ctx.log = ctx.log or log
	ctx.now = ctx.now or os.time
	ctx.set_timer = ctx.set_timer or function(delay_ms, fn)
		return C4:SetTimer(delay_ms, fn)
	end
	ctx.on_stream = ctx.on_stream or function() end
	ctx.on_lamps_changed = ctx.on_lamps_changed or function() end
	ctx.on_restored = ctx.on_restored or function() end
	ctx.after_sync = ctx.after_sync or function()
		return entertainment.PUT_BACK
	end
	ctx.put_back = ctx.put_back or function(rid)
		ctx.log.warn("entertainment: no put_back in ctx; %s not put back", tostring(rid))
		return false
	end
	return setmetatable({
		ctx = ctx,
		by_id = {},       -- area id -> hue_model.entertainment_area() record
		owners = {},      -- entertainment service rid -> light rid
		pre = {},         -- light rid -> its pre-sync state (PRE_FIELDS), until the restore
		changed = {},     -- light rid -> true: lamp_mode named it since the last settle()
		restores = {},    -- area id -> { area (a view), lamps, timer } waiting to go out
		fetched = false,  -- a fetch_all has succeeded since load
	}, entertainment)
end

-- pcall wrapper for callbacks and timer bodies; failures are logged, not raised.
function entertainment:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.ctx.log.error("entertainment: %s failed: %s", what, tostring(err))
	end
	return ok, err
end

-- The lights module, read at each use (it may be created after this one).
function entertainment:lights_module()
	local lights = self.ctx.lights
	if type(lights) == "function" then
		local ok, value = pcall(lights)
		lights = ok and value or nil
	end
	return type(lights) == "table" and lights or nil
end

-- A lamp's normalised light (hue_model.light), or nil.
function entertainment:model(rid)
	local lights = self:lights_module()
	local models = lights and lights.models
	local model = type(models) == "table" and rid ~= nil and models[rid] or nil
	return type(model) == "table" and model or nil
end

function entertainment:is_streaming(rid)
	local model = self:model(rid)
	return model ~= nil and model.streaming == true
end

-- Who a streaming lamp follows: "another app" in stage 1; nil while it does not stream.
function entertainment:stream_label(rid)
	if self:is_streaming(rid) then
		return entertainment.OTHER_APP
	end
	return nil
end

-- Who an active area's stream comes from (the row's "syncing: ..." text).
function entertainment.area_label(_self, _area)
	return entertainment.OTHER_APP
end

-- After A Sync Ends: "As Hue decides" when the property says so, else the default.
function entertainment:after_sync()
	local ok, value = pcall(self.ctx.after_sync)
	if ok and value == entertainment.AS_HUE then
		return entertainment.AS_HUE
	end
	return entertainment.PUT_BACK
end

-- Coverage ------------------------------------------------------------------------

-- True when an active area other than `except_id` holds the lamp.
function entertainment:held_active(rid, except_id)
	for id, area in pairs(self.by_id) do
		if id ~= except_id and area.status == "active" and contains(area.lamps, rid) then
			return true
		end
	end
	return false
end

-- True when an active area or a waiting restore (other than `except_id`)
-- still needs the lamp's pre-sync state.
function entertainment:covered(rid, except_id)
	if self:held_active(rid, except_id) then
		return true
	end
	for id, restore in pairs(self.restores) do
		if id ~= except_id and contains(restore.lamps, rid) then
			return true
		end
	end
	return false
end

-- Keep the current model as the pre-sync state of every lamp of `area` that
-- has none yet: Hue keeps reporting the state from before the stream (T2), so
-- this holds whether the area's status or the lamps' mode arrives first, and
-- even if Hue sends no lamp mode at all [assumed, T1].
function entertainment:keep_lamps(area)
	for _, rid in ipairs(area.lamps) do
		if self.pre[rid] == nil then
			local model = self:model(rid)
			if model then
				self.pre[rid] = snapshot(model)
			end
		end
	end
end

-- Drop the pre-sync states of `lamps` that nothing else needs.
function entertainment:drop(lamps, area_id)
	for _, rid in ipairs(lamps) do
		if not self:covered(rid, area_id) then
			self.pre[rid] = nil
		end
	end
end

-- Drop every pre-sync state whose lamp does not stream and that no active
-- area or waiting restore needs (a stream on an area the bridge did not
-- know, say), so that it cannot stand in for a later stream's.
function entertainment:prune()
	for _, rid in ipairs(sorted_keys(self.pre)) do
		if not self:is_streaming(rid) and not self:covered(rid) then
			self.pre[rid] = nil
		end
	end
end

-- Lamps ---------------------------------------------------------------------------

-- The lights module reports a change of a lamp's `streaming`. `before` is a
-- copy of its model from before the change, nil at first sight. A lamp that
-- starts streaming keeps its pre-sync state (`before`, else its current
-- model, T2) unless one is kept already: a lamp that streams again before
-- its restore went out goes back to its state from before the first stream.
-- A lamp that stops streaming while no active area or waiting restore holds
-- it loses its state (its stream was on an area the bridge does not know).
function entertainment:lamp_mode(rid, streaming, before)
	rid = hue_model.resource_id(rid)
	if rid == nil then
		return
	end
	if streaming == true then
		if self.pre[rid] == nil then
			local source = type(before) == "table" and before or self:model(rid)
			if type(source) == "table" then
				self.pre[rid] = snapshot(source)
			end
		end
	elseif not self:covered(rid) then
		self.pre[rid] = nil
	end
	self.changed[rid] = true
end

-- The end of a lights container or fetch: on_lamps_changed once with the
-- lamps lamp_mode named (sorted), then the waiting restores are checked.
function entertainment:settle()
	local rids = sorted_keys(self.changed)
	self.changed = {}
	if #rids > 0 then
		self:protect("on_lamps_changed", self.ctx.on_lamps_changed, rids)
	end
	self:check_restores()
end

-- Streams starting and stopping -------------------------------------------------

function entertainment:transition(area, started)
	if started then
		self.ctx.log.info("entertainment: %s started syncing (%s)", area.name, self:area_label(area))
		self:cancel_restore(area.id)  -- it streams again: its lamps keep their states
		self:keep_lamps(area)
	else
		self.ctx.log.info("entertainment: %s stopped syncing", area.name)
	end
	self:protect("on_stream", self.ctx.on_stream, view(area), started)
	if not started then
		self:start_restore(area)
	end
end

function entertainment:cancel_restore(id)
	local restore = self.restores[id]
	if restore then
		if restore.timer then
			restore.timer:Cancel()
		end
		self.restores[id] = nil
	end
end

function entertainment:start_restore(area)
	self:cancel_restore(area.id)
	local lamps = copy_list(area.lamps)
	if self:after_sync() ~= entertainment.PUT_BACK then
		self:drop(lamps, area.id)
		self.ctx.log.info("entertainment: After A Sync Ends is %s: the lamps of %s stay as Hue leaves them",
			entertainment.AS_HUE, area.name)
		return
	end
	self.restores[area.id] = { area = view(area), lamps = lamps, timer = nil }
	self:check_restores()
end

-- Arm the timer of every waiting restore none of whose lamps streams (a
-- lamp streaming in another active area aside); disarm it while one does.
function entertainment:check_restores()
	for _, id in ipairs(sorted_keys(self.restores)) do
		local restore = self.restores[id]
		local waiting = false
		for _, rid in ipairs(restore.lamps) do
			if self:is_streaming(rid) and not self:held_active(rid, id) then
				waiting = true
				break
			end
		end
		if waiting and restore.timer then
			restore.timer:Cancel()
			restore.timer = nil
		elseif not waiting and not restore.timer then
			restore.timer = self.ctx.set_timer(entertainment.RESTORE_AFTER_S * 1000, function()
				self:protect("restore", self.run_restore, self, id, restore)
			end)
		end
	end
end

-- The restore ------------------------------------------------------------------------

-- True when a lamp's current model `now` differs from its pre-sync state
-- `pre` (contract §4.3): `on` differs; or both are on and the brightness is
-- more than BRIGHTNESS_MARGIN apart, or the colour differs (color_mode, xy
-- more than XY_MARGIN apart, mirek more than MIREK_MARGIN apart). Two off
-- states never differ: the off body carries nothing more. A state without
-- `on` has nothing to put back.
function entertainment.differs(pre, now)
	if type(pre) ~= "table" or type(now) ~= "table" or pre.on == nil then
		return false
	end
	if (pre.on == true) ~= (now.on == true) then
		return true
	end
	if pre.on ~= true then
		return false
	end
	local b0, b1 = num.finite(pre.brightness), num.finite(now.brightness)
	if b0 and b1 and math.abs(b0 - b1) > entertainment.BRIGHTNESS_MARGIN then
		return true
	end
	if pre.color_mode == nil then
		return false
	end
	if pre.color_mode ~= now.color_mode then
		return true
	end
	local function apart(a, b, margin)
		a, b = num.finite(a), num.finite(b)
		return a ~= nil and b ~= nil and math.abs(a - b) > margin
	end
	if pre.color_mode == "xy" then
		return apart(pre.x, now.x, entertainment.XY_MARGIN) or apart(pre.y, now.y, entertainment.XY_MARGIN)
	end
	return pre.color_mode == "ct" and apart(pre.mirek, now.mirek, entertainment.MIREK_MARGIN)
end

-- The CLIP v2 light PUT body that puts a lamp back to `pre` (contract §4.3):
-- { on = { on = false } } for an off state; else on, dimming.brightness and
-- color.xy or color_temperature.mirek as its color_mode says. Every number
-- passes common/num.lua: brightness within 0..100, x and y within 0..1, mirek
-- a whole number within the lamp's range (`model`'s, else 153..500). nil for
-- a state without `on`.
function entertainment.body(pre, model)
	if type(pre) ~= "table" then
		return nil
	end
	if pre.on == false then
		return { on = { on = false } }
	end
	if pre.on ~= true then
		return nil
	end
	local body = { on = { on = true } }
	local brightness = num.clamp(pre.brightness, 0, 100)
	if brightness then
		body.dimming = { brightness = brightness }
	end
	if pre.color_mode == "xy" then
		local x, y = num.clamp(pre.x, 0, 1), num.clamp(pre.y, 0, 1)
		if x and y then
			body.color = { xy = { x = x, y = y } }
		end
	elseif pre.color_mode == "ct" then
		model = type(model) == "table" and model or {}
		local lo = num.finite(model.mirek_min) or MIREK_MIN
		local hi = num.finite(model.mirek_max) or MIREK_MAX
		local mirek = num.int(num.clamp(pre.mirek, lo, math.max(lo, hi)))
		if mirek then
			body.color_temperature = { mirek = mirek }
		end
	end
	return body
end

-- One lamp's PUT through ctx.put_back; true when it was queued.
function entertainment:send_back(rid, body)
	local ctx = self.ctx
	local ok, queued = pcall(ctx.put_back, rid, body, function(result)
		if result == false or (type(result) == "table" and result.ok == false) then
			ctx.log.warn("entertainment: putting %s back after the sync failed: %s", rid,
				util.echo(type(result) == "table" and result.err or "not sent", util.LOG_MAX))
		end
	end)
	if not ok then
		ctx.log.error("entertainment: put_back failed for %s: %s", rid, tostring(queued))
		return false
	end
	return queued ~= false
end

function entertainment:run_restore(id, restore)
	if self.restores[id] ~= restore then
		return  -- cancelled, or replaced by a later stop
	end
	self.restores[id] = nil
	restore.timer = nil
	local area = self.by_id[id] and view(self.by_id[id]) or restore.area
	if self:after_sync() ~= entertainment.PUT_BACK then
		self:drop(restore.lamps, id)
		self.ctx.log.info("entertainment: After A Sync Ends is %s: the lamps of %s stay as Hue leaves them",
			entertainment.AS_HUE, area.name)
		return
	end
	local count = 0
	for _, rid in ipairs(restore.lamps) do
		-- A lamp that streams again (in another area) keeps its state for later.
		if not (self:held_active(rid, id) or self:is_streaming(rid)) then
			local pre, model = self.pre[rid], self:model(rid)
			if pre and model and entertainment.differs(pre, model) then
				local body = entertainment.body(pre, model)
				if body and self:send_back(rid, body) then
					count = count + 1
					self.ctx.log.debug("entertainment: %s put back after the sync of %s", rid:sub(1, 8), area.name)
				end
			end
			self.pre[rid] = nil
		end
	end
	if count > 0 then
		self.ctx.log.info("entertainment: %s", entertainment.restored_text(area, count))
		self:protect("on_restored", self.ctx.on_restored, area, count)
	end
end

function entertainment:stop()
	for _, id in ipairs(sorted_keys(self.restores)) do
		self:cancel_restore(id)
	end
end

-- Fetching and events ---------------------------------------------------------------

-- Replace the areas and the lamp map with a fetch's items, then fire the
-- transitions since the last fetch (none after load).
function entertainment:absorb(got)
	local lights = self:lights_module()
	local owners = got.entertainment and hue_model.entertainment_owners(got.entertainment, lights and lights.devices)
		or self.owners
	local areas = {}
	for _, item in ipairs(got.configuration) do
		local area = hue_model.entertainment_area(item, owners)
		if area then
			areas[area.id] = area
		end
	end
	local events = {}
	if self.fetched then
		local ids = {}
		for id in pairs(self.by_id) do
			ids[id] = true
		end
		for id in pairs(areas) do
			ids[id] = true
		end
		for _, id in ipairs(sorted_keys(ids)) do
			local old, new = self.by_id[id], areas[id]
			local was = old and old.status or "inactive"
			local is = new and new.status or "inactive"
			if was ~= is then
				events[#events + 1] = { area = new or old, started = is == "active" }
			end
		end
	end
	self.owners, self.by_id, self.fetched = owners, areas, true
	for _, event in ipairs(events) do
		self:transition(event.area, event.started)
	end
	for _, id in ipairs(sorted_keys(areas)) do
		if areas[id].status == "active" then
			self:keep_lamps(areas[id])
		end
	end
	self:prune()
	self:check_restores()
	self.ctx.log.debug("entertainment: %d areas, %d lamp services cached", #sorted_keys(areas), #sorted_keys(owners))
end

-- `tier` "quick" (the resync after a silence) reads only the areas once a
-- fetch has read the lamp map: the services rarely change, the events keep
-- the map current, and the 10-minute quick read stays within the hourly
-- request budget (bridge/housekeeping.lua HOUR_BUDGET, 16 GETs a read on a
-- Bridge Pro). The full tier reads both.
function entertainment:fetch_all(done, tier)
	done = type(done) == "function" and done or function() end
	local got = {}
	local function step(i)
		local res = entertainment.RESOURCES[i]
		if res and res.kind == "entertainment" and tier == "quick" and self.fetched then
			res = nil
		end
		if not res then
			return done(self:protect("absorb", self.absorb, self, got) == true)
		end
		self.ctx.http({ path = res.path, method = "GET" }, function(r)
			self:protect("fetch " .. res.kind, function()
				local items = type(r) == "table" and r.ok and type(r.json) == "table" and r.json.data or nil
				if type(items) ~= "table" then
					local why = type(r) == "table" and not r.ok and util.echo(r.err, util.LOG_MAX) or "malformed response"
					self.ctx.log.warn("entertainment: GET %s: %s; the areas stay as they were", res.path, why)
					return done(false)
				end
				got[res.kind] = items
				step(i + 1)
			end)
		end)
	end
	step(1)
end

-- An entertainment item: the lamp map. True when it changed.
function entertainment:on_service_item(item, kind)
	local id = hue_model.resource_id(item.id)
	if id == nil then
		return false
	end
	if kind == "delete" then
		local had = self.owners[id] ~= nil
		self.owners[id] = nil
		return had
	end
	local lights = self:lights_module()
	local light = hue_model.entertainment_light(item, lights and lights.devices)
	if light and self.owners[id] ~= light then
		self.owners[id] = light
		return true
	end
	return false
end

-- An entertainment_configuration item; a status change joins `events`.
function entertainment:on_area_item(item, kind, events)
	local id = hue_model.resource_id(item.id)
	if id == nil then
		return
	end
	if kind == "add" then
		local area = hue_model.entertainment_area(item, self.owners)
		if area then
			local old = self.by_id[id]
			self.by_id[id] = area
			if (old and old.status or "inactive") ~= area.status then
				events[#events + 1] = { area = area, started = area.status == "active" }
			end
		end
	elseif kind == "delete" then
		local old = self.by_id[id]
		self.by_id[id] = nil
		if old and old.status == "active" then
			events[#events + 1] = { area = old, started = false }  -- [assumed]: deleting an area ends its stream
		end
	elseif kind == "update" then
		local area = self.by_id[id]
		if not area then
			self.ctx.log.debug("entertainment: update for unknown area %s ignored until the next resync", id:sub(1, 8))
			return
		end
		if util.has_field(hue_model.area_update(area, item, self.owners), "status") then
			events[#events + 1] = { area = area, started = area.status == "active" }
		end
	end
end

-- One event-stream container. Runs inside OnBodyChunk: no transfer starts
-- here (a restore only arms its timer). The status changes fire after the
-- whole container is in, so an area and its lamp services arriving together
-- are resolved first.
local function on_container_body(self, container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return
	end
	local kind = container.type
	local events, owners_changed = {}, false
	for _, item in ipairs(container.data) do
		if type(item) == "table" then
			if item.type == "entertainment" then
				owners_changed = self:on_service_item(item, kind) or owners_changed
			elseif item.type == "entertainment_configuration" then
				self:on_area_item(item, kind, events)
			end
		end
	end
	if owners_changed then
		for _, area in pairs(self.by_id) do
			area.lamps = hue_model.area_lamps(area, self.owners)
		end
	end
	for _, event in ipairs(events) do
		self:transition(event.area, event.started)
	end
	self:check_restores()
end

function entertainment:on_container(container)
	self:protect("event container", on_container_body, self, container)
end

-- What Composer shows ----------------------------------------------------------------

-- The areas, sorted by name (then id), as copies with `lamps` and `streaming`.
function entertainment:areas()
	local list = {}
	for _, area in pairs(self.by_id) do
		list[#list + 1] = area
	end
	table.sort(list, function(a, b)
		local ka, kb = util.norm(a.name), util.norm(b.name)
		if ka ~= kb then
			return ka < kb
		end
		return a.id < b.id
	end)
	for i, area in ipairs(list) do
		list[i] = view(area)
	end
	return list
end

-- The Entertainment Areas row (contract §4.4): "Living Room TV (5 lamps,
-- syncing: another app) | Office (3 lamps)", "None" without areas. At most
-- rows.ROW_MAX bytes (the rows rule, #489 C-4): the areas that fit, then
-- "+N more"; a first area too long on its own is cut (util.echo).
function entertainment:row()
	local list = self:areas()
	if #list == 0 then
		return entertainment.NONE
	end
	local parts = {}
	for i, area in ipairs(list) do
		local text = area.name .. " (" .. util.plural(#area.lamps, "lamp")
		if area.streaming then
			text = text .. ", syncing: " .. self:area_label(area)
		end
		parts[i] = text .. ")"
	end
	local used, fit = 0, 0
	for i, part in ipairs(parts) do
		local add = #part + (i > 1 and #ROW_SEP or 0)
		local rest = #parts - i
		local more = rest > 0 and (#ROW_SEP + #string.format("+%d more", rest)) or 0
		if used + add + more > rows.ROW_MAX then
			break
		end
		used, fit = used + add, i
	end
	if fit == #parts then
		return table.concat(parts, ROW_SEP)
	elseif fit == 0 then
		return util.echo(parts[1], rows.ROW_MAX)
	end
	return table.concat(parts, ROW_SEP, 1, fit) .. ROW_SEP .. string.format("+%d more", #parts - fit)
end

-- The kept pre-sync state of a lamp (a copy), or nil; for the specs.
function entertainment:pre_sync(rid)
	local pre = rid ~= nil and self.pre[rid] or nil
	return pre and snapshot(pre) or nil
end

-- Last Action texts (contract §4.4).
function entertainment.started_text(area)
	return "Sync started: " .. tostring(area and area.name or "?")
end

function entertainment.stopped_text(area)
	return "Sync stopped: " .. tostring(area and area.name or "?")
end

function entertainment.restored_text(area, count)
	return string.format("Lights put back after the sync: %s (%s)", tostring(area and area.name or "?"),
		util.plural(num.int(count, 0) or 0, "lamp"))
end

return entertainment
