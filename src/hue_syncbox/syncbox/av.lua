-- The box's AV switch proxy (5001) and what its commands do to the box
-- (#557, docs/hdmi-sync-stage3-design.md §1 and §3, contracts C4 in
-- docs/hdmi-sync-contracts.md, design docs/hdmi-sync-design.md §5.2, §5.3
-- and §5.8): Director routes, this module turns each command into writes
-- for syncbox/queue.lua and answers the proxy only once a read of the box
-- shows the write done.
--
--   local a = av.new{ queue, state_now, wiring_now, sources, room, notify,
--                     last_action, properties, period, timer, now, log }
--   a:received(command, params)  a command from the proxy (ReceivedFromProxy
--                    on 5001): true when it is the AV switch's (acted on,
--                    noted or ignored as C4 says), false for anything else
--   a:confirm(model) every good read: the queue checks its writes against
--                    it (q:observe), and the proxy hears ON, OFF and
--                    INPUT_OUTPUT_CHANGED for the commands it shows done
--   a:room_changed(state, prev)  the followed room changed (syncbox/room.lua's
--                    on_change; not its baseline): behind a receiver the
--                    sync mode follows the room's source
--   a:reset()        forget the routes and a pending source-leaves
--                    (a wiring change, a restart of the routing)
--   a:bound_inputs() the box inputs Composer binds (BINDING_CHANGE_ACTION)
--   a:routes()       { video = n, audio = n }: the inputs Director routes
--
-- deps:
--   queue        syncbox/queue.lua's
--   state_now()  the last good read's model (syncbox/poller.lua
--                p:last_model()); nil before the first
--   wiring_now() "in_line" | "behind_receiver" | "second_output" (the
--                model's wiring, design 5.8); nil reads the model's, else
--                in line
--   sources      syncbox/sources.lua's: s:mode_for(selection, wiring, input)
--                with the room's state as the selection ({ selected, kind },
--                so Listen reads as Listen) -> "video" | "game" | "music" |
--                "none" (also the property's words, any case, or a table
--                with .mode); nil or "automatic" falls back to Listen ->
--                Music, else Video
--   room         syncbox/room.lua's (its :state() or .state), or a function
--                returning the room state { power, selected, kind = "watch"
--                | "listen" | "off", ... }
--   notify(command, params)  to the proxy: C4:SendToProxy(5001, ...), which
--                sends a NOTIFY for a binding of 1000 or more [verified: SDK
--                docs-driverworks-api 25_proxy/_6-SendToProxy.md]
--   last_action(text)        Last Action
--   properties   a function(name) or the Properties table: HDMI n Sync Mode,
--                At Room Off, When The Source Leaves The Box (contracts C1.4)
--   period(n, mode)  optional (stage 4): { intensity, brightness } for a sync
--                start; stage 3 leaves both as the box has them (§1)
--
-- What Director sends (docs/syncbox-control4-research.md §1.3 to §1.5;
-- docs-driverworks-proxyprotocol 8_audio_video_switch_proxy_commands
-- _28-ON.md, _27-OFF.md, _46-SETINPUT.md, _48-SETOUTPUTINPUT.md,
-- _5-DISCONNECTOUTPUT.md, _3-CONNECTOUTPUT.md, _8-GETAUDIOINPUTS.md, and
-- what goes back, 7_audio_video_switch_protocol_notifications _4, _7, _8):
--   ON                 -> hdmiActive true; ON once the box reads on
--   SET_INPUT {INPUT, OUTPUT, AUDIO, VIDEO[, PREV_DEV_LIST]}, and
--   SET_OUTPUT_INPUT {INPUT, OUTPUT}
--                      -> input n = INPUT - 999 (video 1000-1003) or - 2999
--                         (audio 3000-3003); an n the box lacks: Last Action
--                         "Not switched: this box has 1 HDMI input" and
--                         nothing sent. Else one write with the wake and
--                         hdmiSource "input<n>", and one with the input's
--                         mode and syncActive true (Do not sync:
--                         syncActive false instead, see below);
--                         INPUT_OUTPUT_CHANGED {INPUT, OUTPUT, AUDIO, VIDEO}
--                         once a read shows input n; after 4 tries Last
--                         Action "Not switched: the box did not change input"
--   OFF                -> At Room Off: Power save (mode powersave) or Stop
--                         syncing and keep the picture (syncActive false);
--                         OFF once done
--   DISCONNECT_OUTPUT  -> without OFF: When The Source Leaves The Box,
--                         Stop syncing and keep the picture (syncActive
--                         false) or Power save
--   CONNECT_OUTPUT, GET_AUDIO_INPUTS, SET_ROOM_BINDING_NAME,
--   IS_AV_OUTPUT_TO_INPUT_VALID, PULSE_INPUT  -> noted only
--   BINDING_CHANGE_ACTION {BINDING_ID, IS_BOUND}  -> which inputs are bound
-- The parameters arrive as text; every one is read through common/num.lua
-- or compared as text, never trusted as a type. AUDIO and VIDEO are booleans
-- as text [verified: syncbox-control4-research.md §1.3, Snap One's avswitch
-- template]; which spelling Director uses is [assumed] ("true", "True",
-- "1" all read true), and the notify echoes the text it got.
--
-- "Without OFF" (C4): Director's Room Off may send DISCONNECT_OUTPUT before
-- or after OFF (the order is probe P4's question). A DISCONNECT_OUTPUT that
-- leaves no route through the box waits OFF_WINDOW_MS; an OFF within that
-- time, before or after it, or a SET_INPUT that routes the box again, means
-- At Room Off (or the new route) decides instead.
--
-- The sync mode (design 5.3, O5; research docs/syncbox-wirings-research.md
-- §7.2):
--   in line          HDMI n Sync Mode; Automatic is Music for an audio-only
--                    route (AUDIO without VIDEO, and no video route on that
--                    input), else the input's type in the Hue Sync app
--                    (GAME_TYPES Game, MUSIC_TYPES Music), else Video
--   behind a receiver  every source arrives on HDMI 1, so the mode is the
--                    followed room's source's (sources:mode_for); a source
--                    change that sends the box nothing comes through
--                    a:room_changed. A Listen selection starts music sync
--                    anyway (owner's provisional answer, #536, stage 3 §2:
--                    LISTEN_BEHIND_RECEIVER)
--   second output    Director never routes through the box (research §4.2):
--                    a command is only logged; syncbox/follow.lua drives
-- Do not sync sends the input and no sync start; it also sends syncActive
-- false, so a sync that ran on the previous input stops (the box keeps the
-- mode across an input change, behaviour SB39) rather than lighting the
-- room from an input the dealer marked Do not sync. syncActive false
-- changes nothing on a box that does not sync (SB33).
--
-- A change the box makes by itself (its CEC or hot-plug switching, the Hue
-- Sync app) never reaches the proxy: only a write this module queued, and
-- that a read then shows, is answered (C4; Control4 ignores unsolicited AV
-- notifications and does not run its pathing backwards [verified: SDK
-- docs-driverworks-proxyprotocol 116_proxy_and_protocol_best_practices/
-- _1-AVPATHINGUNSOLICITEDNOTIFICATIONSANDCONTROL4UI.md]).

local num = require("common.num")
local queue = require("syncbox.queue")

local av = {}

av.MODE_PROPERTY = "HDMI %d Sync Mode"
av.ROOM_OFF_PROPERTY = "At Room Off"
av.LEAVES_PROPERTY = "When The Source Leaves The Box"
av.POWER_SAVE = "Power save"
av.KEEP_PICTURE = "Stop syncing and keep the picture"
av.OFF_WINDOW_MS = 1500
-- #536, stage 3 §2: behind a receiver, a Listen selection in the followed
-- room starts music sync anyway ("sync"), or is a source that leaves the
-- box ("leave").
av.LISTEN_BEHIND_RECEIVER = "sync"
av.INPUTS = 4
av.VIDEO_IN, av.AUDIO_IN = 1000, 3000      -- input n is 999 + n and 2999 + n (C1.2)
av.VIDEO_OUT, av.AUDIO_OUT = 2000, 4000
av.PARAM_MAX = 40                          -- bytes of a parameter in a text
-- Design 5.3: the input types that call for Game and for Music.
av.GAME_TYPES = { xbox = true, playstation = true, nintendoswitch = true, game = true }
av.MUSIC_TYPES = { avreceiver = true, soundbar = true, music = true }
av.WIRINGS = { in_line = true, behind_receiver = true, second_output = true }

av.TEXT = {
	NO_INPUT = "Not switched: this box has %d HDMI input%s",
	UNKNOWN_INPUT = "Not switched: Control4 asked for input %s, which this switch does not have",
	-- per kind of write: what failed, and the words for "not landed".
	input = { no = "Not switched", landed = "the box did not change input" },
	sync = { no = "Not syncing", landed = "the box did not start syncing" },
	no_sync = { no = "Not stopped", landed = "the box did not stop syncing" },
	on = { no = "Not turned on", landed = "the box did not wake from power save" },
	off = { no = "Not turned off", landed = "the box did not go to power save" },
	off_keep = { no = "Not turned off", landed = "the box did not stop syncing" },
	leave = { no = "Not stopped", landed = "the box did not go to power save" },
	leave_keep = { no = "Not stopped", landed = "the box did not stop syncing" },
	BUSY = "another app streams to the Hue Bridge's entertainment area, so the box is busy",
	REFUSED = "the box refused it (%s)",
	NOT_PAIRED = "the box is not paired; run Pair Sync Box",
}

-- Commands noted without acting (C4), and the ones that act.
local NOTED = { CONNECT_OUTPUT = true, GET_AUDIO_INPUTS = true, SET_ROOM_BINDING_NAME = true,
	IS_AV_OUTPUT_TO_INPUT_VALID = true, PULSE_INPUT = true }
local ACTING = { ON = true, OFF = true, SET_INPUT = true, SET_OUTPUT_INPUT = true, DISCONNECT_OUTPUT = true }

-- A property's or a source's mode, in the queue's words ("none" for Do not
-- sync), or nil.
local MODE_WORDS = { automatic = "automatic", video = "video", game = "game", music = "music",
	["do not sync"] = "none", ["do_not_sync"] = "none", none = "none", off = "none" }

function av.mode_word(v)
	if type(v) == "table" then
		v = v.mode
	end
	if v == false then
		return "none"
	end
	if type(v) ~= "string" then
		return nil
	end
	return MODE_WORDS[v:lower()]
end

-- In line (design 5.3): the HDMI n Sync Mode setting, then the route, then
-- the input's type, then Video.
function av.inline_mode(setting, input_type, audio_only)
	local word = av.mode_word(setting) or "automatic"
	if word ~= "automatic" then
		return word
	end
	if audio_only then
		return "music"
	end
	if av.GAME_TYPES[input_type] then
		return "game"
	end
	if av.MUSIC_TYPES[input_type] then
		return "music"
	end
	return "video"
end

-- A boolean sent as text ("true", "True", "1"; "false", "0"), else nil.
local function flag(v)
	if type(v) == "boolean" then
		return v
	end
	if type(v) == "number" then
		return v == 1 or (v ~= 0 and nil)
	end
	if type(v) ~= "string" then
		return nil
	end
	local s = v:lower()
	if s == "true" or s == "1" then
		return true
	elseif s == "false" or s == "0" then
		return false
	end
	return nil
end

-- A parameter in a text: printable, capped.
local function shown(v)
	local s = tostring(v)
	s = s:gsub("[^ -~]", "?")
	return #s > av.PARAM_MAX and (s:sub(1, av.PARAM_MAX) .. "...") or s
end

local A = {}
A.__index = A

function av.new(deps)
	deps = deps or {}
	if type(deps.queue) ~= "table" or type(deps.queue.set) ~= "function" then
		error("av.new: a queue required", 2)
	end
	local a = setmetatable({}, A)
	a.queue = deps.queue
	a.state_now = deps.state_now
	a.wiring_now = deps.wiring_now
	a.sources = deps.sources
	a.room = deps.room
	a.notify = deps.notify
	a.last_action = deps.last_action
	a.properties = deps.properties
	a.period = deps.period
	a.log = deps.log or require("common.log")
	a.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	a.now = deps.now or function()
		return C4:GetTime()
	end
	a.route = {}      -- { video = n, audio = n }: what Director routes through the box
	a.bound = {}      -- binding id -> bound (BINDING_CHANGE_ACTION)
	a.model = nil     -- the last read a:confirm saw
	a.off_at = nil    -- when the last OFF came (ms)
	a.leave_timer = nil
	return a
end

-- Reading the driver -----------------------------------------------------------------------

function A:_model()
	if type(self.state_now) == "function" then
		local ok, m = pcall(self.state_now)
		if ok and type(m) == "table" then
			return m
		end
	end
	return self.model
end

function A:_wiring()
	local w
	if type(self.wiring_now) == "function" then
		local ok, v = pcall(self.wiring_now)
		w = ok and v or nil
	end
	if w == nil then
		local m = self:_model()
		w = m and m.wiring
	end
	return av.WIRINGS[w] and w or "in_line"
end

function A:_prop(name)
	local p = self.properties
	local ok, v
	if type(p) == "function" then
		ok, v = pcall(p, name)
	elseif type(p) == "table" then
		ok, v = true, p[name]
	end
	return ok and type(v) == "string" and v or nil
end

function A:_room()
	local r, ok, st = self.room, false, nil
	if type(r) == "function" then
		ok, st = pcall(r)
	elseif type(r) == "table" then
		if type(r.state) == "function" then
			ok, st = pcall(r.state, r)
		elseif type(r.state) == "table" then
			ok, st = true, r.state
		else
			ok, st = true, r
		end
	end
	return ok and type(st) == "table" and st or nil
end

-- Behind a receiver: whether the followed room listens, and Listen is to
-- start music sync (#536).
function A:_listening()
	local st = self:_room()
	return av.LISTEN_BEHIND_RECEIVER == "sync" and st ~= nil and st.kind == "listen"
end

function A:_say(text)
	self.log.info("%s", text)
	if type(self.last_action) == "function" then
		local ok, err = pcall(self.last_action, text)
		if not ok then
			self.log.warn("av: Last Action failed: %s", tostring(err))
		end
	end
end

function A:_notify(command, params)
	self.log.debug("av: %s to the proxy", command)
	if type(self.notify) == "function" then
		local ok, err = pcall(self.notify, command, params or {})
		if not ok then
			self.log.warn("av: the %s notify failed: %s", command, tostring(err))
		end
	end
end

-- A write that ended without ok: Last Action for what the owner should
-- read, the log for the rest.
function A:_failed(kind, why, detail)
	if why == nil or why == queue.SUPERSEDED or why == queue.CANCELLED then
		self.log.debug("av: a %s write ended: %s", kind, tostring(why))
		return
	end
	local t = av.TEXT[kind]
	local words
	if why == queue.NOT_LANDED then
		words = t.landed
	elseif why == queue.BUSY then
		words = av.TEXT.BUSY
	elseif why == queue.REFUSED then
		words = string.format(av.TEXT.REFUSED, tostring(detail or "no reason given"))
	elseif why == queue.NOT_SENT then
		words = (detail == "not paired" or detail == "no box address") and av.TEXT.NOT_PAIRED or tostring(detail)
	else
		words = tostring(why)
	end
	-- A PUT the box refused, or never sent, ends the input's and the sync's
	-- writes together: the input's text says it once.
	if kind == "sync" and why ~= queue.BUSY and why ~= queue.NOT_LANDED then
		self.log.info("av: %s: %s", t.no, words)
		return
	end
	self:_say(t.no .. ": " .. words)
end

-- The writes -------------------------------------------------------------------------------

function A:_cancel_leave()
	if self.leave_timer then
		pcall(function() self.leave_timer:Cancel() end)
		self.leave_timer = nil
	end
end

-- The sync for input n in `mode` ("none": Do not sync).
function A:_queue_mode(n, mode, on_ok)
	if mode == "none" then
		return self.queue:set({ syncActive = false }, { kind = "no_sync", input = n }, function(_, ok, _, why, detail)
			if ok then
				return on_ok and on_ok()
			end
			self:_failed("no_sync", why, detail)
		end)
	end
	local fields = { mode = mode, syncActive = true }
	if type(self.period) == "function" then
		local ok, p = pcall(self.period, n, mode)
		if ok and type(p) == "table" then
			fields.intensity, fields.brightness = p.intensity, p.brightness
		end
	end
	local function done(_, ok, _, why, detail)
		if ok then
			self.log.info("av: syncing %s on HDMI %d", mode, n)
			return on_ok and on_ok()
		end
		self:_failed("sync", why, detail)
	end
	local tag = { kind = "sync", input = n, mode = mode }
	if not self.queue:set(fields, tag, done) and (fields.intensity ~= nil or fields.brightness ~= nil) then
		self.log.warn("av: the period's settings were refused; syncing with the box's own")
		fields.intensity, fields.brightness = nil, nil
		self.queue:set(fields, tag, done)
	end
end

function A:_queue_input(n, reply)
	local tag = { kind = "input", input = n, reply = reply }
	self.queue:set({ hdmiActive = true, hdmiSource = "input" .. n }, tag, function(_, ok, _, why, detail)
		if ok then
			self.log.info("av: HDMI %d confirmed (input %s, output %s)", n, tostring(reply.INPUT), tostring(reply.OUTPUT))
			return self:_notify("INPUT_OUTPUT_CHANGED", reply)
		end
		self:_failed("input", why, detail)
	end)
end

-- Behind a receiver: the sync mode of the room's source (`st` the room's
-- state when the caller has it, a:room_changed's; else the room's now).
function A:_source_mode(n, audio_only, st)
	st = st or self:_room()
	local word
	local s = self.sources
	if type(s) == "table" and type(s.mode_for) == "function" then
		-- The room's state as the selection, not its bare id: sources.lua
		-- reads the Listen kind from it ({ selected, kind }), so an Apple TV
		-- under Listen is Music (#536), not the Video its driver calls for.
		local ok, v = pcall(s.mode_for, s, st, "behind_receiver", n)
		if ok then
			word = av.mode_word(v)
		else
			self.log.warn("av: the source's sync mode could not be read: %s", tostring(v))
		end
	end
	if word == nil or word == "automatic" then
		word = ((st and st.kind == "listen") or audio_only) and "music" or "video"
	end
	return word
end

function A:_mode_for(n, audio_only, model, wiring)
	if wiring == "behind_receiver" then
		return self:_source_mode(n, audio_only)
	end
	local input_type
	for _, i in ipairs(type(model) == "table" and type(model.inputs) == "table" and model.inputs or {}) do
		if i.n == n then
			input_type = i.type
		end
	end
	return av.inline_mode(self:_prop(string.format(av.MODE_PROPERTY, n)), input_type, audio_only)
end

-- The inputs the box has: a count, and whether it has input n; nil when no
-- read said yet.
local function inputs_of(model)
	if type(model) ~= "table" then
		return nil
	end
	if type(model.inputs) == "table" and #model.inputs > 0 then
		local has = {}
		for _, i in ipairs(model.inputs) do
			has[i.n] = true
		end
		return #model.inputs, has
	end
	if model.model == "HSB3" then
		return 1, { true }
	end
	return nil
end

-- Behind a receiver, Listen: the box wakes on HDMI 1 and syncs music (or
-- the source's own mode); `on_ok` once a read shows it.
function A:_listen_sync(mode, on_ok)
	self.queue:set({ hdmiActive = true, hdmiSource = "input1" }, { kind = "listen_input", input = 1 },
		function(_, ok, _, why, detail)
			if not ok then
				self:_failed("input", why, detail)
			end
		end)
	self:_queue_mode(1, mode or "music", on_ok)
end

-- Proxy commands ---------------------------------------------------------------------------

function A:_on()
	self.queue:set({ hdmiActive = true }, { kind = "on" }, function(_, ok, _, why, detail)
		if ok then
			return self:_notify("ON", {})
		end
		self:_failed("on", why, detail)
	end)
end

function A:_off()
	self:_cancel_leave()
	self.off_at = self.now()
	self.route = {}
	local function notify_off()
		self:_notify("OFF", {})
	end
	if self:_wiring() == "behind_receiver" and self:_listening() then
		local mode = self:_source_mode(1, true)
		if mode ~= "none" then
			self.log.info("av: OFF while the room listens: music sync goes on behind the receiver (#536)")
			return self:_listen_sync(mode, notify_off)
		end
	end
	local keep = self:_prop(av.ROOM_OFF_PROPERTY) == av.KEEP_PICTURE
	local fields = keep and { syncActive = false } or { mode = "powersave" }
	local kind = keep and "off_keep" or "off"
	self.queue:set(fields, { kind = "off" }, function(_, ok, _, why, detail)
		if ok then
			return notify_off()
		end
		self:_failed(kind, why, detail)
	end)
end

-- When The Source Leaves The Box, once the window passed without an OFF.
function A:_leave()
	local wiring = self:_wiring()
	if wiring == "second_output" or self.route.video or self.route.audio then
		return
	end
	if wiring == "behind_receiver" and self:_listening() then
		local mode = self:_source_mode(1, true)
		if mode ~= "none" then
			self.log.info("av: the box left the path for a Listen source: music sync behind the receiver (#536)")
			return self:_listen_sync(mode)
		end
	end
	local power_save = self:_prop(av.LEAVES_PROPERTY) == av.POWER_SAVE
	local fields = power_save and { mode = "powersave" } or { syncActive = false }
	local kind = power_save and "leave" or "leave_keep"
	self.log.info("av: the source left the box: %s", power_save and "power save" or "stop syncing")
	self.queue:set(fields, { kind = "leave" }, function(_, ok, _, why, detail)
		if not ok then
			self:_failed(kind, why, detail)
		end
	end)
end

function A:_disconnect(params)
	local video, audio = flag(params.VIDEO), flag(params.AUDIO)
	if not video and not audio then
		local out = num.int(params.OUTPUT)
		if out and out >= 2000 and out <= 2999 then
			video = true
		elseif out and out >= 4000 and out <= 4999 then
			audio = true
		else
			video, audio = true, true
		end
	end
	if video then
		self.route.video = nil
	end
	if audio then
		self.route.audio = nil
	end
	if self.route.video or self.route.audio then
		self.log.debug("av: DISCONNECT_OUTPUT: the box still carries the %s", self.route.video and "picture" or "sound")
		return
	end
	if self.off_at and self.now() - self.off_at < av.OFF_WINDOW_MS then
		self.log.debug("av: DISCONNECT_OUTPUT with OFF: At Room Off decides")
		return
	end
	self:_cancel_leave()
	local timer
	timer = self.timer(av.OFF_WINDOW_MS, function()
		if self.leave_timer ~= timer then
			return
		end
		self.leave_timer = nil
		self:_leave()
	end)
	self.leave_timer = timer
end

function A:_set_input(params)
	local id = num.int(params.INPUT)
	local n, range
	if id and id >= av.VIDEO_IN and id < av.VIDEO_IN + av.INPUTS then
		n, range = id - (av.VIDEO_IN - 1), "video"
	elseif id and id >= av.AUDIO_IN and id < av.AUDIO_IN + av.INPUTS then
		n, range = id - (av.AUDIO_IN - 1), "audio"
	else
		return self:_say(string.format(av.TEXT.UNKNOWN_INPUT, shown(params.INPUT)))
	end
	local video, audio = flag(params.VIDEO), flag(params.AUDIO)
	if not video and not audio then
		video, audio = range == "video", range == "audio"
	end
	local model = self:_model()
	local count, has = inputs_of(model)
	if count and not has[n] then
		return self:_say(string.format(av.TEXT.NO_INPUT, count, count == 1 and "" or "s"))
	end
	self:_cancel_leave()
	self.off_at = nil -- routed again: a later DISCONNECT_OUTPUT is no part of that Room Off
	local audio_only = audio and not video and self.route.video ~= n
	if video then
		self.route.video = n
	end
	if audio then
		self.route.audio = n
	end
	local output = num.int(params.OUTPUT, av.VIDEO_OUT, 4999) or (video and av.VIDEO_OUT or av.AUDIO_OUT)
	local reply = {
		INPUT = id,
		OUTPUT = output,
		AUDIO = flag(params.AUDIO) ~= nil and shown(params.AUDIO) or tostring(audio == true),
		VIDEO = flag(params.VIDEO) ~= nil and shown(params.VIDEO) or tostring(video == true),
	}
	local wiring = self:_wiring()
	local mode = self:_mode_for(n, audio_only, model, wiring)
	self.log.info("av: %s route to HDMI %d (%s), sync %s", audio_only and "an audio-only" or "a", n,
		wiring, mode == "none" and "off (Do not sync)" or mode)
	self:_queue_input(n, reply)
	self:_queue_mode(n, mode)
end

function A:_binding(params)
	local id = num.int(params.BINDING_ID, 1000, 4999)
	if not id then
		self.log.debug("av: BINDING_CHANGE_ACTION without a binding id in range")
		return
	end
	local bound = flag(params.IS_BOUND)
	self.bound[id] = bound == true
end

function A:received(command, params)
	params = type(params) == "table" and params or {}
	if command == "BINDING_CHANGE_ACTION" then
		self:_binding(params)
		return true
	end
	if NOTED[command] then
		self.log.debug("av: %s noted", command)
		return true
	end
	if not ACTING[command] then
		return false
	end
	if self:_wiring() == "second_output" then
		-- Research §4.2: none expected; Follow Room drives the box.
		self.log.info("av: %s only logged: the box is on a receiver's second output, Follow Room drives it", command)
		return true
	end
	if command == "ON" then
		self:_on()
	elseif command == "OFF" then
		self:_off()
	elseif command == "DISCONNECT_OUTPUT" then
		self:_disconnect(params)
	else
		self:_set_input(params)
	end
	return true
end

function A:confirm(model)
	if type(model) ~= "table" then
		return
	end
	self.model = model
	if type(self.queue.observe) == "function" then
		self.queue:observe(model)
	end
end

function A:room_changed(state, prev)
	if type(state) ~= "table" or type(prev) ~= "table" or self:_wiring() ~= "behind_receiver" then
		return -- no prev: the baseline, which changes nothing on the box
	end
	if prev.selected == state.selected and prev.kind == state.kind then
		return
	end
	if state.kind == "listen" then
		if av.LISTEN_BEHIND_RECEIVER == "sync" then
			local mode = self:_source_mode(1, true, state)
			if mode ~= "none" then
				self:_cancel_leave()
				self.log.info("av: the room listens: music sync behind the receiver (#536)")
				self:_listen_sync(mode)
			end
		end
		return
	end
	local n = self.route.video or self.route.audio
	if state.kind ~= "watch" or not n then
		return -- the box is not on the path; Director's commands decide
	end
	local mode = self:_source_mode(n, self.route.video == nil, state)
	self.log.info("av: the room's source changed behind the receiver: sync %s", mode == "none" and "off" or mode)
	self:_queue_mode(n, mode)
end

function A:reset()
	self:_cancel_leave()
	self.route = {}
	self.off_at = nil
end

function A:routes()
	return { video = self.route.video, audio = self.route.audio }
end

function A:bound_inputs()
	local out = {}
	for n = 1, av.INPUTS do
		if self.bound[av.VIDEO_IN - 1 + n] or self.bound[av.AUDIO_IN - 1 + n] then
			out[#out + 1] = n
		end
	end
	return out
end

return av
