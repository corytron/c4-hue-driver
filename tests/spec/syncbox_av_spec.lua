-- syncbox/av.lua (#557, docs/hdmi-sync-stage3-design.md §3, contracts C4,
-- design docs/hdmi-sync-design.md §5.2, §5.3 and §5.8): the AV switch
-- proxy's commands as writes for syncbox/queue.lua, in each wiring, and the
-- notifies (ON, OFF, INPUT_OUTPUT_CHANGED) only for what a read shows done.
-- The first parts drive av with a recording queue (each write ended by the
-- spec, as the queue would end it), and stand-ins for agent B's
-- syncbox/sources.lua and syncbox/room.lua; the last part runs av, the real
-- queue, client and poller against the Lua fake box
-- (tests/helpers/fake_syncbox.lua). Director's parameters are text, as the
-- proxy sends them (docs/syncbox-control4-research.md §1.3). Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

-- SET_INPUT as Director sends it: binding ids and booleans as text.
local function set_input(input, video, audio, extra)
	local p = { INPUT = tostring(input), OUTPUT = video and "2000" or "4000", VIDEO = video and "True" or "False",
		AUDIO = audio and "True" or "False", PREV_DEV_LIST = "1234" }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

describe("syncbox/av.lua (#557)", function()
	local av, queue, state, c4, a, sq, notified, actions, props, sources, room, current, lines

	-- The recording queue: every set kept; finish(i, ok, why, detail) ends
	-- set i as the real queue would.
	local function stub_queue()
		local s = { sets = {} }
		function s:set(fields, tag, cb)
			self.sets[#self.sets + 1] = { fields = fields, tag = tag, cb = cb }
			return true
		end
		function s:observe(m) self.observed = m end
		function s:finish(i, ok, why, detail)
			local entry = assert(self.sets[i], "no set " .. tostring(i))
			entry.cb(entry.tag, ok, nil, why, detail)
		end
		function s:kinds()
			local out = {}
			for _, e in ipairs(self.sets) do out[#out + 1] = e.tag.kind end
			return out
		end
		return s
	end

	local function model_of(name, edit)
		local raw = F.copy(F.state[name])
		if edit then edit(raw) end
		return (state.from_api(raw))
	end

	local function new_av(extra)
		local deps = {
			queue = sq,
			state_now = function() return current end,
			notify = function(command, params) notified[#notified + 1] = { command, params } end,
			last_action = function(text) actions[#actions + 1] = text end,
			properties = function(name) return props[name] end,
			sources = sources,
			room = function() return room end,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
			log = log,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return av.new(deps)
	end

	local function commands()
		local out = {}
		for _, n in ipairs(notified) do out[#out + 1] = n[1] end
		return out
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		for _, m in ipairs({ "syncbox.queue", "syncbox.av", "syncbox.state" }) do package.loaded[m] = nil end
		queue, av, state = require("syncbox.queue"), require("syncbox.av"), require("syncbox.state")
		sq = stub_queue()
		notified, actions, props = {}, {}, {}
		-- Agent B's sources:mode_for as its header documents it: the selection
		-- the room's state ({ selected, kind }) or an id; the source's own
		-- setting, then Listen -> Music, then what its driver calls for
		-- (`calls_for`, Video by default).
		sources = { calls = {}, modes = {}, calls_for = {} }
		function sources:mode_for(selection, wiring, input)
			self.calls[#self.calls + 1] = { selection = selection, wiring = wiring, input = input }
			local id, kind = selection, nil
			if type(selection) == "table" then
				id, kind = selection.selected or selection.id, selection.kind
			end
			if not id or kind == "off" then
				return nil, "nothing selected"
			end
			if self.modes[id] then
				return self.modes[id], "set"
			end
			if kind == "listen" then
				return "music", "listen"
			end
			return self.calls_for[id] or "video", "default"
		end
		room = { power = "on", selected = 101, kind = "watch" }
		current = model_of("HSB2")
		a = new_av()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("SET_INPUT in line (C4)", function()
		it("takes input n from the video ids 1000 to 1003 and the audio ids 3000 to 3003", function()
			for n = 1, 4 do
				sq.sets = {}
				assert.is_true(a:received("SET_INPUT", set_input(999 + n, true, false)))
				assert.same({ hdmiActive = true, hdmiSource = "input" .. n }, sq.sets[1].fields)
				sq.sets = {}
				a:reset()
				assert.is_true(a:received("SET_INPUT", set_input(2999 + n, false, true)))
				assert.same({ hdmiActive = true, hdmiSource = "input" .. n }, sq.sets[1].fields)
				a:reset()
			end
		end)

		it("queues the wake and the input, then the input's mode with syncActive; Automatic by the input's type",
			function()
				a:received("SET_INPUT", set_input(1001, true, false))
				assert.same({ "input", "sync" }, sq:kinds())
				assert.same({ mode = "game", syncActive = true }, sq.sets[2].fields, "HDMI 2 is a PlayStation")
				sq.sets = {}
				a:received("SET_INPUT", set_input(1000, true, true))
				assert.same({ mode = "video", syncActive = true }, sq.sets[2].fields, "HDMI 1 is an Apple TV")
				sq.sets = {}
				a:received("SET_INPUT", set_input(1002, true, false))
				assert.same({ mode = "video", syncActive = true }, sq.sets[2].fields, "generic: Video")
				current = model_of("HSB2", function(raw) raw.hdmi.input4.type = "soundbar" end)
				sq.sets = {}
				a:received("SET_INPUT", set_input(1003, true, false))
				assert.same({ mode = "music", syncActive = true }, sq.sets[2].fields, "a soundbar: Music")
			end)

		it("lets HDMI n Sync Mode override the type", function()
			props["HDMI 1 Sync Mode"] = "Game"
			props["HDMI 2 Sync Mode"] = "Music"
			props["HDMI 3 Sync Mode"] = "Automatic"
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("game", sq.sets[2].fields.mode)
			a:received("SET_INPUT", set_input(1001, true, false))
			assert.equal("music", sq.sets[4].fields.mode)
			a:received("SET_INPUT", set_input(1002, true, false))
			assert.equal("video", sq.sets[6].fields.mode)
		end)

		it("syncs music for an audio-only route, and keeps the input's mode when its video route is there", function()
			a:received("SET_INPUT", set_input(3001, false, true))
			assert.same({ mode = "music", syncActive = true }, sq.sets[2].fields, "Listen on HDMI 2")
			a:reset()
			sq.sets = {}
			a:received("SET_INPUT", set_input(1001, true, false))
			a:received("SET_INPUT", set_input(3001, false, true))
			assert.equal("game", sq.sets[2].fields.mode)
			assert.equal("game", sq.sets[4].fields.mode, "the audio half of a Watch source")
			assert.same({ video = 2, audio = 2 }, a:routes())
			sq.sets = {}
			a:received("SET_INPUT", set_input(3002, false, true))
			assert.equal("music", sq.sets[2].fields.mode, "a Listen source on another input")
			props["HDMI 4 Sync Mode"] = "Video"
			sq.sets = {}
			a:received("SET_INPUT", set_input(3003, false, true))
			assert.equal("video", sq.sets[2].fields.mode, "the dealer's setting comes first")
		end)

		it("sends only the input for Do not sync, with syncActive false so a sync from the last input stops (SB39)",
			function()
				props["HDMI 3 Sync Mode"] = "Do not sync"
				a:received("SET_INPUT", set_input(1002, true, true))
				assert.same({ "input", "no_sync" }, sq:kinds())
				assert.same({ hdmiActive = true, hdmiSource = "input3" }, sq.sets[1].fields)
				assert.same({ syncActive = false }, sq.sets[2].fields)
				for _, e in ipairs(sq.sets) do
					assert.is_nil(e.fields.mode, "never a sync start")
				end
			end)

		it("refuses an input the box lacks with the contract's text, and sends nothing", function()
			current = model_of("HSB3")
			for _, id in ipairs({ 1001, 1003, 3002 }) do
				actions, sq.sets = {}, {}
				assert.is_true(a:received("SET_INPUT", set_input(id, id < 2000, id > 2000)))
				assert.same({ "Not switched: this box has 1 HDMI input" }, actions)
				assert.equal(0, #sq.sets)
			end
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal(2, #sq.sets, "its one input works")
			assert.same({ mode = "game", syncActive = true }, sq.sets[2].fields, "a Nintendo Switch")
		end)

		it("refuses an id that is no input of the switch, and sends the input before the first read", function()
			for _, id in ipairs({ "1004", "999", "2000", "3099", "x", "" }) do
				actions = {}
				a:received("SET_INPUT", { INPUT = id, OUTPUT = "2000" })
				assert.equal(1, #actions)
				assert.truthy(actions[1]:find("^Not switched: Control4 asked for input"))
			end
			assert.equal(0, #sq.sets)
			current = nil
			a:received("SET_INPUT", set_input(1003, true, false))
			assert.same({ hdmiActive = true, hdmiSource = "input4" }, sq.sets[1].fields)
			assert.equal("video", sq.sets[2].fields.mode)
		end)

		it("answers INPUT_OUTPUT_CHANGED with INPUT, OUTPUT, AUDIO and VIDEO only once the queue says a read shows it",
			function()
				a:received("SET_INPUT", set_input(1001, true, false))
				assert.same({}, notified)
				sq:finish(2, true)
				assert.same({}, notified, "the sync is no AV notify")
				sq:finish(1, true)
				assert.same({ { "INPUT_OUTPUT_CHANGED", { INPUT = 1001, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } } },
					notified)
				assert.same({}, actions)
			end)

		it("fills OUTPUT, AUDIO and VIDEO from the binding range when Director leaves them out", function()
			a:received("SET_INPUT", { INPUT = "3002" })
			sq:finish(1, true)
			assert.same({ INPUT = 3002, OUTPUT = 4000, AUDIO = "true", VIDEO = "false" }, notified[1][2])
			assert.equal("music", sq.sets[2].fields.mode, "an audio id alone is an audio-only route")
			a:received("SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "1", AUDIO = "0" })
			sq:finish(3, true)
			assert.same({ INPUT = 1000, OUTPUT = 2000, AUDIO = "0", VIDEO = "1" }, notified[2][2])
		end)

		it("routes SET_OUTPUT_INPUT as SET_INPUT", function()
			assert.is_true(a:received("SET_OUTPUT_INPUT", { INPUT = "1001", OUTPUT = "2000" }))
			assert.same({ hdmiActive = true, hdmiSource = "input2" }, sq.sets[1].fields)
			sq:finish(1, true)
			assert.equal("INPUT_OUTPUT_CHANGED", notified[1][1])
		end)

		it("says 'Not switched: the box did not change input' after the queue's 4 tries, and notifies nothing", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(1, false, queue.NOT_LANDED)
			assert.same({ "Not switched: the box did not change input" }, actions)
			assert.same({}, notified)
		end)

		it("says nothing for a write overtaken or cancelled", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(1, false, queue.SUPERSEDED)
			sq:finish(2, false, queue.CANCELLED)
			assert.same({}, actions)
			assert.same({}, notified)
		end)

		it("says the bridge is busy for code 16, and still confirms the input", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(2, false, queue.BUSY, "HTTP 400, box error 16: Invalid State")
			assert.same({ "Not syncing: " .. av.TEXT.BUSY }, actions)
			sq:finish(1, true)
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
		end)

		it("says a refusal or a request not sent once, through the input", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(1, false, queue.REFUSED, "HTTP 400, box error 15: Invalid Value")
			sq:finish(2, false, queue.REFUSED, "HTTP 400, box error 15: Invalid Value")
			assert.same({ "Not switched: the box refused it (HTTP 400, box error 15: Invalid Value)" }, actions)
			actions = {}
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(3, false, queue.NOT_SENT, "not paired")
			sq:finish(4, false, queue.NOT_SENT, "not paired")
			assert.same({ "Not switched: the box is not paired; run Pair Sync Box" }, actions)
			actions = {}
			a:received("SET_INPUT", set_input(1001, true, false))
			sq:finish(6, false, queue.NOT_LANDED)
			assert.same({ "Not syncing: the box did not start syncing" }, actions)
		end)

		it("hands the period's intensity and brightness to the sync start when there is one (stage 4)", function()
			a = new_av({ period = function(n, mode)
				assert.equal(2, n)
				assert.equal("game", mode)
				return { intensity = "moderate", brightness = 70 }
			end })
			a:received("SET_INPUT", set_input(1001, true, false))
			assert.same({ mode = "game", syncActive = true, intensity = "moderate", brightness = 70 }, sq.sets[2].fields)
		end)
	end)

	describe("ON, OFF and DISCONNECT_OUTPUT (C4)", function()
		it("wakes the box on ON and answers ON once a read shows it on", function()
			assert.is_true(a:received("ON", {}))
			assert.same({ hdmiActive = true }, sq.sets[1].fields)
			assert.same({}, notified)
			sq:finish(1, true)
			assert.same({ { "ON", {} } }, notified)
			a:received("ON")
			sq:finish(2, false, queue.NOT_LANDED)
			assert.same({ "Not turned on: the box did not wake from power save" }, actions)
		end)

		it("puts the box in power save on OFF (At Room Off's default), then answers OFF", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			a:received("OFF", {})
			assert.same({ mode = "powersave" }, sq.sets[3].fields)
			assert.same({}, a:routes())
			sq:finish(3, true)
			assert.same({ { "OFF", {} } }, notified)
			a:received("OFF", {})
			sq:finish(4, false, queue.NOT_LANDED)
			assert.same({ "Not turned off: the box did not go to power save" }, actions)
		end)

		it("only stops syncing on OFF when At Room Off keeps the picture", function()
			props["At Room Off"] = "Stop syncing and keep the picture"
			a:received("OFF", {})
			assert.same({ syncActive = false }, sq.sets[1].fields)
			sq:finish(1, true)
			assert.same({ "OFF" }, commands())
		end)

		it("applies When The Source Leaves The Box 1.5 s after a DISCONNECT_OUTPUT that ends the last route", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			a:received("SET_INPUT", set_input(3001, false, true))
			sq.sets = {}
			assert.is_true(a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True", AUDIO = "False" }))
			c4.advance(5000)
			assert.equal(0, #sq.sets, "the sound still passes the box")
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "4000" })
			c4.advance(av.OFF_WINDOW_MS - 1)
			assert.equal(0, #sq.sets)
			c4.advance(1)
			assert.same({ syncActive = false }, sq.sets[1].fields, "the default: stop syncing, keep the picture")
			assert.same({}, notified, "DISCONNECT_OUTPUT has no notify")
			props["When The Source Leaves The Box"] = "Power save"
			a:received("DISCONNECT_OUTPUT", {})
			c4.advance(av.OFF_WINDOW_MS)
			assert.same({ mode = "powersave" }, sq.sets[2].fields)
		end)

		it("lets At Room Off alone decide when OFF comes with DISCONNECT_OUTPUT, in either order (probe P4)", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			sq.sets = {}
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000" })
			c4.advance(500)
			a:received("OFF", {})
			c4.advance(5000)
			assert.same({ "off" }, sq:kinds())
			c4.advance(60000)
			a:received("SET_INPUT", set_input(1001, true, false))
			sq.sets = {}
			a:received("OFF", {})
			c4.advance(300)
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000" })
			c4.advance(5000)
			assert.same({ "off" }, sq:kinds())
		end)

		it("leaves nothing pending when a SET_INPUT routes the box again within the window", function()
			a:received("SET_INPUT", set_input(1001, true, false))
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000" })
			c4.advance(200)
			a:received("SET_INPUT", set_input(1002, true, false))
			sq.sets = {}
			c4.advance(5000)
			assert.equal(0, #sq.sets)
		end)

		it("notes CONNECT_OUTPUT and the commands C4 ignores, and leaves volume to others", function()
			for _, command in ipairs({ "CONNECT_OUTPUT", "GET_AUDIO_INPUTS", "SET_ROOM_BINDING_NAME",
				"IS_AV_OUTPUT_TO_INPUT_VALID", "PULSE_INPUT" }) do
				assert.is_true(a:received(command, { OUTPUT = "2000" }))
			end
			assert.is_false(a:received("SET_VOLUME_LEVEL", { LEVEL = "20" }))
			assert.is_false(a:received("MUTE_TOGGLE"))
			assert.equal(0, #sq.sets)
			assert.same({}, notified)
		end)

		it("notes which inputs Composer binds (BINDING_CHANGE_ACTION)", function()
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "1001", IS_BOUND = "True" })
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "3003", IS_BOUND = "true" })
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "1002", IS_BOUND = "False" })
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "nope", IS_BOUND = "True" })
			assert.same({ 2, 4 }, a:bound_inputs())
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "1001", IS_BOUND = "False" })
			assert.same({ 4 }, a:bound_inputs())
			assert.equal(0, #sq.sets)
		end)

		it("hands every read to the queue", function()
			local m = model_of("HSB2")
			a:confirm(m)
			assert.equal(m, sq.observed)
			a:confirm(nil)
			assert.equal(m, sq.observed)
		end)
	end)

	describe("behind a receiver (design 5.8)", function()
		before_each(function()
			current = model_of("HSB2_behind_receiver")
		end)

		it("takes the mode from the followed room's source, never from HDMI 1's type or setting", function()
			props["HDMI 1 Sync Mode"] = "Music"
			sources.modes[101] = "Game"
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.same({ mode = "game", syncActive = true }, sq.sets[2].fields)
			assert.same({ selection = room, wiring = "behind_receiver", input = 1 }, sources.calls[1],
				"the room's state is the selection, so its Listen kind travels with the id")
			sources.modes[101] = { mode = "music" }
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("music", sq.sets[4].fields.mode, "a table with .mode reads too")
		end)

		it("falls back to Music for a Listen selection, else Video, when the source has no mode", function()
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("video", sq.sets[2].fields.mode)
			sources.modes[101] = "Automatic"
			room.kind = "listen"
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("music", sq.sets[4].fields.mode)
			a = new_av({ sources = false, room = false })
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("video", sq.sets[6].fields.mode, "no sources and no room: Video")
		end)

		it("syncs music when the room listens to a video source (an Apple TV under Listen, #536)", function()
			sources.calls_for[101] = "video"   -- an Apple TV: its driver calls for Video
			local watch = { power = "on", selected = 101, kind = "watch" }
			local listen = { power = "on", selected = 101, kind = "listen" }
			room = watch
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("video", sq.sets[2].fields.mode, "watched, it is Video")
			room = listen
			sq.sets = {}
			a:room_changed(listen, watch)
			assert.same({ "listen_input", "sync" }, sq:kinds())
			assert.equal("music", sq.sets[2].fields.mode)
			sq.sets = {}
			a:received("OFF", {})
			assert.equal("music", sq.sets[2].fields.mode, "OFF while it listens")
			c4.advance(60000)
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("music", sq.sets[4].fields.mode, "SET_INPUT while it listens")
			sq.sets = {}
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000" })
			c4.advance(av.OFF_WINDOW_MS)
			assert.same({ "listen_input", "sync" }, sq:kinds())
			assert.equal("music", sq.sets[2].fields.mode, "the source leaves the box while it listens")
		end)

		it("syncs music for an Apple TV under Listen with agent B's own syncbox/sources.lua", function()
			package.loaded["syncbox.sources"] = nil
			local real = require("syncbox.sources").new({
				get_devices = function() return {} end,
				bound_provider = function() return 0 end,
				display_name = function() return "Apple TV" end,
				persist_get = function() return nil end,
				persist_set = function() end,
				log = log,
			})
			room = { power = "on", selected = 101, kind = "watch" }
			a = new_av({ sources = real })
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.equal("video", sq.sets[2].fields.mode)
			local listen = { power = "on", selected = 101, kind = "listen" }
			room = listen
			a:room_changed(listen, { power = "on", selected = 101, kind = "watch" })
			assert.equal("music", sq.sets[4].fields.mode)
		end)

		it("sends only the input for a source set to Do not sync", function()
			sources.modes[101] = "Do not sync"
			a:received("SET_INPUT", set_input(1000, true, false))
			assert.same({ "input", "no_sync" }, sq:kinds())
		end)

		it("follows a source change that sends the box nothing, only while routed, and never on the baseline",
			function()
				local before = { power = "on", selected = 101, kind = "watch" }
				local after = { power = "on", selected = 102, kind = "watch" }
				sources.modes[102] = "Game"
				a:room_changed(after, nil)
				a:room_changed(after, before)
				assert.equal(0, #sq.sets, "the box is not on the path")
				a:received("SET_INPUT", set_input(1000, true, false))
				sq.sets = {}
				a:room_changed(before, before)
				assert.equal(0, #sq.sets, "nothing changed")
				room = after
				a:room_changed(after, before)
				assert.same({ mode = "game", syncActive = true }, sq.sets[1].fields)
				assert.same({ "sync" }, sq:kinds(), "the input stays: every source is on HDMI 1")
				a:room_changed({ power = "off", kind = "off" }, after)
				assert.equal(1, #sq.sets, "Room Off is OFF's")
			end)

		it("starts music sync anyway when the room listens (#536), on its change, on OFF and on DISCONNECT_OUTPUT",
			function()
				local listen = { power = "on", selected = 201, kind = "listen" }
				a:room_changed(listen, room)
				assert.same({ "listen_input", "sync" }, sq:kinds())
				assert.same({ hdmiActive = true, hdmiSource = "input1" }, sq.sets[1].fields)
				assert.same({ mode = "music", syncActive = true }, sq.sets[2].fields)
				room = listen
				sq.sets = {}
				a:received("OFF", {})
				assert.same({ "listen_input", "sync" }, sq:kinds())
				sq:finish(2, true)
				assert.same({ "OFF" }, commands(), "OFF answered once the music sync shows")
				sq.sets = {}
				a:received("SET_INPUT", set_input(1000, true, false))
				sq.sets = {}
				a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000" })
				c4.advance(av.OFF_WINDOW_MS)
				assert.same({ "listen_input", "sync" }, sq:kinds())
			end)

		it("treats Listen as a source that leaves the box when the owner's answer is 'leave', or its mode is Do not sync",
			function()
				local saved = av.LISTEN_BEHIND_RECEIVER
				av.LISTEN_BEHIND_RECEIVER = "leave"
				room = { power = "on", selected = 201, kind = "listen" }
				a:room_changed(room, { power = "on", selected = 101, kind = "watch" })
				a:received("OFF", {})
				av.LISTEN_BEHIND_RECEIVER = saved
				assert.same({ "off" }, sq:kinds())
				sources.modes[201] = "Do not sync"
				sq.sets = {}
				a:room_changed(room, { power = "on", selected = 101, kind = "watch" })
				a:received("OFF", {})
				assert.same({ "off" }, sq:kinds())
			end)
	end)

	describe("on a receiver's second output (design 5.8)", function()
		it("only logs Director's commands: Follow Room drives the box", function()
			current = model_of("HSB2_second_output")
			for _, c in ipairs({ { "ON", {} }, { "SET_INPUT", set_input(1000, true, false) }, { "OFF", {} },
				{ "DISCONNECT_OUTPUT", { OUTPUT = "2000" } } }) do
				assert.is_true(a:received(c[1], c[2]))
			end
			c4.advance(5000)
			a:room_changed({ kind = "listen", selected = 3 }, room)
			assert.equal(0, #sq.sets)
			assert.same({}, notified)
			assert.same({}, actions)
			a:received("BINDING_CHANGE_ACTION", { BINDING_ID = "1000", IS_BOUND = "True" })
			assert.same({ 1 }, a:bound_inputs())
		end)

		it("takes the wiring from wiring_now before the model's", function()
			a = new_av({ wiring_now = function() return "second_output" end })
			a:received("ON", {})
			assert.equal(0, #sq.sets)
			a = new_av({ wiring_now = function() return "nonsense" end })
			a:received("ON", {})
			assert.equal(1, #sq.sets, "an unknown wiring reads in line")
		end)
	end)

	describe("end to end against the Lua fake box (queue, client and poller)", function()
		local clientmod, pollermod, h, c, p, q

		local function rig(fixture)
			for _, m in ipairs({ "common.https", "syncbox.client", "syncbox.poller" }) do package.loaded[m] = nil end
			clientmod, pollermod = require("syncbox.client"), require("syncbox.poller")
			h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = fixture and F.state[fixture] })
			local timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end
			local now = function() return c4:GetTime() end
			c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log, timer = timer, now = now })
			c:set_trusted(true)
			p = pollermod.new({ client = c, timer = timer, now = now, log = log,
				on_state = function(m) a:confirm(m) end })
			q = queue.new({ client = c, poller = p, timer = timer, now = now, log = log })
			a = new_av({ queue = q, state_now = function() return p:last_model() end })
			p:start()
		end

		local function box_put(body)
			assert.equal(200, (h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN }, body)))
		end

		local function puts()
			return h:requests_of("PUT", "/api/v1/execution")
		end

		it("Watch on HDMI 2 from power save: one PUT, then ON and both INPUT_OUTPUT_CHANGED after the read",
			function()
				rig()
				box_put({ mode = "powersave" })
				c4.advance(5000)
				local before = #puts()
				a:received("ON", {})
				a:received("SET_INPUT", set_input(1001, true, false))
				a:received("SET_INPUT", set_input(3001, false, true))
				c4.advance(queue.COALESCE_MS)
				assert.equal(before + 1, #puts())
				assert.same({ hdmiActive = true, hdmiSource = "input2", mode = "game", syncActive = true },
					puts()[#puts()].json)
				assert.equal("game", h:value("execution.mode"))
				assert.same({}, notified, "nothing before a read shows it")
				c4.advance(1000)
				assert.same({ "ON", "INPUT_OUTPUT_CHANGED", "INPUT_OUTPUT_CHANGED" }, commands())
				assert.same({ INPUT = 1001, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" }, notified[2][2])
				assert.same({ INPUT = 3001, OUTPUT = 4000, AUDIO = "True", VIDEO = "False" }, notified[3][2])
				assert.same({}, actions)
			end)

		it("Room Off with DISCONNECT_OUTPUT then OFF: power save, and OFF answered after the read", function()
			rig()
			a:received("SET_INPUT", set_input(1000, true, false))
			c4.advance(queue.COALESCE_MS + 1000)
			notified = {}
			a:received("DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True", AUDIO = "False" })
			a:received("OFF", {})
			c4.advance(queue.COALESCE_MS)
			assert.equal("powersave", h:value("execution.mode"))
			assert.same({}, notified)
			c4.advance(1000)
			assert.same({ "OFF" }, commands())
			c4.advance(10000)
			assert.equal("powersave", h:value("execution.mode"), "the disconnect did nothing of its own")
		end)

		it("tries 4 times 2 s apart when the box does not take the input, then says Not switched", function()
			rig()
			h:fault("5xx", { method = "PUT" })
			local before = #puts()
			a:received("SET_INPUT", set_input(1002, true, false))
			c4.advance(queue.COALESCE_MS)
			c4.advance(4 * queue.RETRY_MS)
			local tries = {}
			for i = before + 1, #puts() do tries[#tries + 1] = puts()[i] end
			assert.equal(4, #tries)
			assert.same({ "Not switched: the box did not change input" }, { actions[1] })
			assert.same({}, notified)
			assert.equal("input1", h:value("execution.hdmiSource"))
		end)

		it("switches the input while another app streams, and says the bridge is busy (code 16)", function()
			rig()
			h:event("bridge", { state = "busy" })
			c4.advance(5000)
			a:received("SET_INPUT", set_input(1001, true, false))
			c4.advance(queue.COALESCE_MS)
			assert.same({ "Not syncing: " .. av.TEXT.BUSY }, actions)
			c4.advance(queue.COALESCE_MS + 1000)
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
			assert.equal("input2", h:value("execution.hdmiSource"))
			assert.equal("passthrough", h:value("execution.mode"))
		end)

		it("never notifies a change the box makes by itself (CEC, the Hue Sync app)", function()
			rig()
			a:received("SET_INPUT", set_input(1001, true, false))
			c4.advance(queue.COALESCE_MS + 1000)
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
			assert.is_true(h:event("cec_active_source", { input = "input1" }))
			box_put({ mode = "powersave" })
			box_put({ hdmiActive = true, hdmiSource = "input3" })
			c4.advance(30000)
			assert.equal(3, p:last_model().input)
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
			assert.same({}, actions)
		end)

		it("stops the last input's sync and starts none on a Do not sync input", function()
			rig()
			props["HDMI 3 Sync Mode"] = "Do not sync"
			assert.equal("video", h:value("execution.mode"))
			a:received("SET_INPUT", set_input(1002, true, false))
			c4.advance(queue.COALESCE_MS + 1000)
			assert.equal("input3", h:value("execution.hdmiSource"))
			assert.equal("passthrough", h:value("execution.mode"))
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
		end)

		it("syncs music on an audio-only route", function()
			rig()
			a:received("SET_INPUT", set_input(3003, false, true))
			c4.advance(queue.COALESCE_MS + 1000)
			assert.equal("music", h:value("execution.mode"))
			assert.equal("input4", h:value("execution.hdmiSource"))
			assert.same({ "INPUT_OUTPUT_CHANGED" }, commands())
		end)

		it("refuses HDMI 2 on a one-input box and sends nothing", function()
			rig("HSB3")
			local before = #puts()
			a:received("SET_INPUT", set_input(1001, true, false))
			c4.advance(10000)
			assert.same({ "Not switched: this box has 1 HDMI input" }, actions)
			assert.equal(before, #puts())
		end)

		it("syncs behind a receiver in the mode of the room's source", function()
			rig("HSB2_behind_receiver")
			sources.modes[101] = "Game"
			a:received("ON", {})
			a:received("SET_INPUT", set_input(1000, true, false))
			c4.advance(queue.COALESCE_MS + 1000)
			assert.equal("game", h:value("execution.mode"))
			assert.same({ "ON", "INPUT_OUTPUT_CHANGED" }, commands())
		end)

		it("sends nothing to the box on a receiver's second output", function()
			rig("HSB2_second_output")
			local before = #puts()
			a:received("ON", {})
			a:received("SET_INPUT", set_input(1000, true, false))
			a:received("OFF", {})
			c4.advance(10000)
			assert.equal(before, #puts())
			assert.same({}, notified)
		end)
	end)
end)
