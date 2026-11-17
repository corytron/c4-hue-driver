-- Follow Room: what the followed room's power and source make the Hue Sync
-- Box do where Director's commands cannot say it (2.0 beta stage 3, #557):
-- docs/hdmi-sync-stage3-design.md §2 and §4, design hdmi-sync-design.md
-- §5.8, research docs/syncbox-wirings-research.md §4.2, §5 (W1 to W24) and
-- §7.2 to §7.4.
--
-- It turns the room's states (syncbox/room.lua) into intents for the box's
-- queue (syncbox/queue.lua: q:set(fields, tag), fields named as the box's
-- PUT /execution names them). It never sends anything itself, never moves
-- a Control4 room, never touches the receiver, and acts on nothing the box
-- does by itself (W13, W14).
--
--   local f = follow.new{ queue, sources, box_id, wiring, model, online,
--                         settings, peer_syncing, own_name, notify, log }
--   f:set_room(room_id, name, opts)  the room followed (nil: none, W2; a
--                     deleted one, W4). Its next baseline is a baseline;
--                     opts.catch_up = true (a dealer's click) applies that
--                     baseline once instead.
--   f:baseline(state)  room.lua's on_baseline: remembered, nothing sent
--                     (W15: a driver restart changes nothing on the box)
--   f:changed(state, prev)  room.lua's on_change → at most one intent
--   f:wiring_changed(wiring)  after each read of the box (model.wiring);
--                     the first call of a run is a baseline. A change to the
--                     second output catches up once with the room's current
--                     state, said in Last Action (W22).
--   f:contact()       the box answers again after an outage (the poller's
--                     on_online): the room's current state applied once if
--                     it differs from the box's, never the missed sequence
--                     (W23; edge case I15's rule)
--   f:done(tag, ok, model, reason)  the queue's on_done(tag, ok, model, why)
--                     for follow's tags (follow.owns(tag)); why "busy" (or
--                     ok == "busy") is code 16, never retried (W10);
--                     "superseded", "cancelled" and "refused" leave nothing
--                     pending; any other failure is applied at contact (W23)
--   f:refresh()       forget the cached bindings upstream of the box (after a
--                     BINDING_CHANGE_ACTION, at OnPIP)
--   f:status()        the Status part about the followed room, or nil
--
-- What each wiring gets from here (research §7.2):
--   second output: everything (research §4.2): a Watch or Listen selection
--     that passes the receiver → wake and sync in the source's mode
--     (sources:mode_for); Room Off → At Room Off; a selection that does not
--     pass the box, or a source set to Do not sync → When The Source Leaves
--     The Box (W17). Whether a selection passes is known only when Composer
--     connects the receiver's second output to the box (research §4.1 choice
--     B): the room's path must then name a device bound upstream.
--   behind a receiver and in line: nothing from here. Director's commands
--     drive and syncbox/av.lua takes the room's changes behind a receiver
--     (contract §3), provisional owner answer 2 (a Listen selection starts
--     music sync) included: its constant is av.LISTEN_BEHIND_RECEIVER, so
--     the answer stays a one-line change in one place.
--
-- The fields (contracts C4, stage 3 §1: execution only): a sync start is
-- { mode, syncActive = true }, with hdmiActive = true unless the box reads
-- on, and hdmiSource = "input<n>" when the receiver is bound to HDMI n and
-- the box is on another input; "Power save" is { mode = "powersave" };
-- "Stop syncing and keep the picture" is { syncActive = false }.
-- Intensity and brightness stay the box's until stage 4's periods. An intent
-- the box already shows is not sent.
--
-- W10's guard: two boxes of this project on one area would take each
-- other's stream over. No take-over is ever asked from here; a box busy
-- with another app's stream (code 16) is reported, not retried; and when
-- peer_syncing() names another box of this project syncing the same area
-- (stage 4's bridge messages, C5), no sync start is sent and Attention names
-- both boxes.
--
-- Deps: queue (required); sources (syncbox/sources.lua; without it Watch is
-- Video and Listen Music); box_id() the box's avswitch proxy id; wiring()
-- "in_line" | "behind_receiver" | "second_output" (default: the last
-- wiring_changed); model() the box's state model (syncbox/state.lua) or nil;
-- online() (default true); settings() → { at_room_off, source_leaves }, the
-- two properties' texts (contracts C1.4); peer_syncing() → nil or the other
-- box's name; own_name();
-- notify(kind, text) with kind "last_action" or "attention"; log.

local follow = {}

follow.POWER_SAVE = "Power save"
follow.KEEP_PICTURE = "Stop syncing and keep the picture"
follow.DEFAULT_AT_ROOM_OFF = follow.POWER_SAVE         -- contracts C1.4
follow.DEFAULT_SOURCE_LEAVES = follow.KEEP_PICTURE     -- contracts C1.4
follow.TAG = "follow"
-- syncbox/queue.lua's `why` for a write that needs nothing at contact (W23):
-- a later q:set replaced it, q:clear dropped it (a wiring change), or the
-- box refused it (the same PUT gets the same answer). "not landed" and
-- "not sent" leave it pending.
follow.SETTLED_REASONS = { superseded = true, cancelled = true, refused = true }

local F = {}
F.__index = F

function follow.owns(tag)
	return type(tag) == "string" and tag:sub(1, #follow.TAG + 1) == follow.TAG .. ":"
end

function follow.new(deps)
	deps = deps or {}
	if type(deps.queue) ~= "table" or type(deps.queue.set) ~= "function" then
		error("follow.new: a queue with a set function is required", 2)
	end
	local f = setmetatable({}, F)
	f.queue = deps.queue
	f.sources = deps.sources
	f.log = deps.log or require("common.log")
	f.box_id = deps.box_id or function() return nil end
	f.wiring = deps.wiring or function() return f.wiring_seen end
	f.model = deps.model or function() return nil end
	f.online = deps.online or function() return true end
	f.settings = deps.settings or function() return {} end
	f.peer_syncing = deps.peer_syncing or function() return nil end
	f.own_name = deps.own_name or function() return "this sync box" end
	f.notify_fn = deps.notify or function() end
	f.room_id, f.room_name = nil, nil
	f.room_state = nil      -- the latest state of the followed room
	f.based = false         -- its baseline came
	f.catch_up_next = false
	f.wiring_seen = nil
	f.pending = false       -- W23: something was not delivered
	f.said_no_sound = false -- W18: said once
	f.up = nil              -- cached sources:upstream(box_id())
	return f
end

local function safe(self, fn, ...)
	local ok, a, b = pcall(fn, ...)
	if not ok then
		self.log.warn("Sync box: Follow Room: %s", tostring(a))
		return nil
	end
	return a, b
end

function F:notify(kind, text)
	if text then
		safe(self, self.notify_fn, kind, text)
	end
end

function F:room_label()
	return self.room_name or string.format("room %d", self.room_id or 0)
end

function F:source_name(id)
	if self.sources and id then
		local d = safe(self, self.sources.describe, self.sources, id)
		if d and d.name then
			return d.name
		end
	end
	return string.format("device %s", tostring(id))
end

-- Cached until refresh(); not cached while the box's id is not known yet.
function F:upstream()
	if self.up == nil and self.sources then
		local box = safe(self, self.box_id)
		if box then
			self.up = safe(self, self.sources.upstream, self.sources, box) or false
		end
	end
	return self.up or nil
end

function F:refresh()
	self.up = nil
end

-- true when the room's path names a device bound upstream of the box; nil
-- when that cannot be told (nothing bound upstream: research §4.1 choice A,
-- or an empty path).
function F:passes(st)
	local up = self:upstream()
	if not up or next(up.ids) == nil then
		return nil
	end
	local path = st.kind == "listen" and st.audio_path or st.video_path
	if not path or #path == 0 then
		return nil
	end
	for _, id in ipairs(path) do
		if up.ids[id] then
			return true
		end
	end
	return false
end

local function is_power_save(text)
	return type(text) == "string" and text:lower():find("power save", 1, true) ~= nil
end

local function leave(setting)
	if is_power_save(setting) then
		return { mode = "powersave" }, "power save"
	end
	return { syncActive = false }, "sync stopped"
end

function F:mode_of(st, wiring)
	if self.sources then
		local mode = safe(self, self.sources.mode_for, self.sources, st, wiring)
		if mode then
			return mode
		end
	end
	return st.kind == "listen" and "music" or "video"
end

function F:sync_fields(mode)
	local fields = { mode = mode, syncActive = true }
	local m = safe(self, self.model)
	if not m or m.power ~= "on" then
		fields.hdmiActive = true
	end
	local up = self:upstream()
	local n = up and up.first_input
	if n and (not m or m.input ~= n) then
		fields.hdmiSource = "input" .. n
	end
	return fields
end

-- Second output: the whole plan (research §4.2). → fields, text, what, mode
function F:plan_second_output(st)
	local s = safe(self, self.settings) or {}
	local room = self:room_label()
	if st.kind == "off" then
		local fields, did = leave(s.at_room_off or follow.DEFAULT_AT_ROOM_OFF)
		return fields, string.format("%s off: %s", room, did), "off"
	end
	local name = self:source_name(st.selected)
	local mode = self:mode_of(st, "second_output")
	if mode == "none" then
		local fields, did = leave(s.source_leaves or follow.DEFAULT_SOURCE_LEAVES)
		return fields, string.format("%s on %s (Do not sync): %s", room, name, did), "leave"
	end
	if self:passes(st) == false then
		local fields, did = leave(s.source_leaves or follow.DEFAULT_SOURCE_LEAVES)
		return fields, string.format("%s on %s, which does not pass the box: %s", room, name, did), "leave"
	end
	return self:sync_fields(mode), string.format("%s on %s: syncing %s", room, name, mode), "sync", mode
end

-- Whether the box's model already shows `fields`.
local function differs(fields, m)
	if not m then
		return true
	end
	if fields.mode == "powersave" then
		return m.power ~= "powersave"
	end
	if fields.syncActive == false then
		return m.syncing == true
	end
	if m.syncing ~= true or m.mode ~= fields.mode or m.power ~= "on" then
		return true
	end
	return fields.hdmiSource ~= nil
end
follow.differs = differs

function F:plan(st)
	if not st or st.kind == "unknown" then
		return nil
	end
	if safe(self, self.wiring) == "second_output" then
		return self:plan_second_output(st)
	end
	return nil   -- in line and behind a receiver: Director's commands and av.lua (contracts C4, stage 3 §3)
end

-- The plan for `st`, sent unless the box already shows it. `prefix` opens the
-- Last Action text. → true when an intent went to the queue.
function F:act(st, prefix)
	local fields, text, what, mode = self:plan(st)
	if not fields then
		return false
	end
	if what == "sync" then
		local peer = safe(self, self.peer_syncing)
		if peer then
			local own = safe(self, self.own_name) or "this sync box"
			self:notify("attention", string.format("%s and %s sync the same entertainment area: %s did not start "
				.. "syncing, so neither takes the other's stream", own, tostring(peer), own))
			return false
		end
	end
	if not differs(fields, safe(self, self.model)) then
		return false
	end
	if not safe(self, self.online) then
		self.pending = true
		self:notify("last_action", string.format("%s%s, once the box answers again", prefix or "", text))
		return false
	end
	local tag = string.format("%s:%s%s", follow.TAG, what, mode and (":" .. mode) or "")
	local ok, err = pcall(self.queue.set, self.queue, fields, tag)
	if not ok then
		self.log.warn("Sync box: Follow Room could not queue %s: %s", tag, tostring(err))
		return false
	end
	self:notify("last_action", (prefix or "") .. text)
	return true
end

function F:set_room(room_id, name, opts)
	if room_id ~= self.room_id then
		self.room_state, self.based = nil, false
	end
	self.room_id, self.room_name = room_id, name
	self.catch_up_next = room_id ~= nil and opts ~= nil and opts.catch_up == true
end

function F:baseline(st)
	if not self.room_id or not st or st.room_id ~= self.room_id then
		return false
	end
	self.room_state, self.based = st, true
	if self.sources and st.selected and st.selected ~= 0 then
		safe(self, self.sources.saw, self.sources, st.selected)
	end
	if self.catch_up_next then
		self.catch_up_next = false
		return self:act(st, "Follow Room changed: ")
	end
	return false
end

function F:changed(st, _prev)
	if not self.room_id or not st or st.room_id ~= self.room_id then
		return false
	end
	self.room_state = st
	if self.sources and st.selected and st.selected ~= 0 then
		safe(self, self.sources.saw, self.sources, st.selected)
	end
	if not self.based then
		self.based = true   -- no baseline came first: this one is the baseline
		return false
	end
	return self:act(st)
end

function F:wiring_changed(wiring)
	local prev = self.wiring_seen
	self.wiring_seen = wiring
	if prev == nil or prev == wiring then
		return false
	end
	if wiring == "second_output" and self.room_id and self.based and self.room_state then
		return self:act(self.room_state, "The box is now on a receiver's second output; ")
	end
	return false
end

function F:contact()
	if not self.pending then
		return false
	end
	self.pending = false
	if not self.room_id or not self.based or not self.room_state then
		return false
	end
	return self:act(self.room_state, "When the box answered again: ")
end

function F:done(tag, ok, model, reason)
	if not follow.owns(tag) then
		return false
	end
	if ok == true then
		self.pending = false
		if tag:find(":music", 1, true) then
			self.said_no_sound = false
		end
		return true
	end
	if ok == "busy" or reason == "busy" then
		-- Code 16: another app streams to the area. Never retried, never taken over (W10).
		self:notify("attention", string.format("%s did not start syncing: another app streams to its "
			.. "entertainment area", safe(self, self.own_name) or "this sync box"))
		return true
	end
	if follow.SETTLED_REASONS[reason] then
		return true   -- a later intent replaced it, the wiring changed, or the box would refuse it again
	end
	self.pending = true
	local online = safe(self, self.online)
	if online and tag:find(":music", 1, true) and type(model) == "table" and model.syncing ~= true
		and not self.said_no_sound then
		self.said_no_sound = true
		self:notify("last_action", "No sound on the second output: music sync did not start")
	end
	return true
end

local KIND_TEXT = { watch = "watching", listen = "listening to" }

function F:status()
	local wiring = safe(self, self.wiring)
	if not self.room_id then
		if wiring == "second_output" then
			return "Follows no room: the box runs on its own settings"
		end
		return nil
	end
	local st = self.room_state
	if not st or st.kind == "unknown" then
		return string.format("Follows %s", self:room_label())
	end
	if st.kind == "off" then
		return string.format("Follows %s (off)", self:room_label())
	end
	return string.format("Follows %s (%s %s)", self:room_label(), KIND_TEXT[st.kind], self:source_name(st.selected))
end

return follow
