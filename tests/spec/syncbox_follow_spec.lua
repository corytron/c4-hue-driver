-- syncbox/follow.lua (#557, docs/hdmi-sync-stage3-design.md §2 and §4;
-- design hdmi-sync-design.md §5.8; research docs/syncbox-wirings-research.md
-- §4.2, §5 and §7.2): the followed room's power and source as intents for
-- the box's queue. The room (syncbox/room.lua) and the sources
-- (syncbox/sources.lua) are the real modules on the fake runtime
-- (tests/helpers/fake_c4.lua); the queue is a stand-in that records
-- q:set(fields, tag) (agent A's syncbox/queue.lua takes the same call); the
-- box's model is a table the spec sets, with syncbox/state.lua's field
-- names. Each lifecycle case of research §5 carries its number (W11 ...);
-- the ones about the room and the sources alone are in syncbox_room_spec.lua
-- and syncbox_sources_spec.lua. Ids and names are made up.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local LIVING, BEDROOM, DEN = 7, 38, 41
local OWN_DEVICE = 15
local BOX = 300                     -- the box's avswitch proxy
local RECEIVER, RECEIVER_DEV = 210, 200
local TV, TV_DEV = 220, 215
local APPLE, PS5, RADIO, ROKU = 120, 130, 140, 160

local function path(...)
	local parts = {}
	for i, id in ipairs({ ... }) do parts[i] = string.format("<id>%d</id>", id) end
	return table.concat(parts)
end

describe("syncbox/follow.lua (#557)", function()
	local room, sources, follow, c4, env
	local q, f, r, s, model, wiring, online, settings, peer, notes

	local function watch(room_id, id, via_receiver)
		fake.room_variable(room_id, 1002, id)
		fake.room_variable(room_id, 1001, id)
		fake.room_variable(room_id, 1008, via_receiver == false and path(id, TV) or path(id, RECEIVER, TV))
		fake.room_variable(room_id, 1007, "")
		fake.room_variable(room_id, 1000, id)
	end

	local function listen(room_id, id)
		fake.room_variable(room_id, 1001, id)
		fake.room_variable(room_id, 1007, path(id, RECEIVER))
		fake.room_variable(room_id, 1008, "")
		fake.room_variable(room_id, 1000, id)
	end

	local function room_off(room_id)
		fake.room_variable(room_id, 1000, 0)
	end

	local function settle()
		c4.advance(room.SETTLE_MS)
	end

	local function last_action()
		for i = #notes, 1, -1 do
			if notes[i][1] == "last_action" then return notes[i][2] end
		end
		return nil
	end

	local function attention()
		for i = #notes, 1, -1 do
			if notes[i][1] == "attention" then return notes[i][2] end
		end
		return nil
	end

	-- The box in power save, as at night.
	local function asleep()
		return { power = "powersave", mode = "powersave", syncing = false, input = 1 }
	end

	local function syncing(mode, input)
		return { power = "on", mode = mode, syncing = true, input = input or 1 }
	end

	-- The driver's wiring of the three modules (agent C does the same in driver.lua).
	local function start(room_id, name)
		q = { sets = {} }
		function q.set(self, fields, tag) self.sets[#self.sets + 1] = { fields = fields, tag = tag } end
		s = sources.new()
		f = follow.new({
			queue = q, sources = s,
			box_id = function() return BOX end,
			wiring = function() return wiring end,
			model = function() return model end,
			online = function() return online end,
			settings = function() return settings end,
			peer_syncing = function() return peer end,
			own_name = function() return "Bedroom Sync Box" end,
			notify = function(kind, text) notes[#notes + 1] = { kind, text } end,
		})
		r = room.new({
			on_baseline = function(st) f:baseline(st) end,
			on_change = function(st, prev) f:changed(st, prev) end,
		})
		env.OnWatchedVariableChanged = function(device, variable, value) r:on_variable(device, variable, value) end
		if room_id then
			f:set_room(room_id, name)
			r:follow(room_id, name)
			c4.advance(room.BASELINE_MS)
		end
	end

	before_each(function()
		log.sink = function() end
		c4, env = fake.install_c4()
		for _, name in ipairs({ "syncbox.room", "syncbox.sources", "syncbox.follow" }) do package.loaded[name] = nil end
		room = require("syncbox.room")
		sources = require("syncbox.sources")
		follow = require("syncbox.follow")
		fake.add_room(BEDROOM, "Bedroom")
		fake.add_room(DEN, "Den")
		fake.move_device(OWN_DEVICE, BEDROOM)
		fake.add_device(RECEIVER_DEV, { name = "AV Receiver", driver = "denon_avr.c4z", proxy = "receiver",
			proxy_id = RECEIVER, room_id = BEDROOM })
		fake.add_device(TV_DEV, { name = "TV", driver = "lg_tv.c4z", proxy = "tv", proxy_id = TV, room_id = BEDROOM })
		fake.add_device(110, { name = "Apple TV", driver = "apple_tv_ip.c4z", proxy = "media_player", proxy_id = APPLE })
		fake.add_device(125, { name = "PS5", driver = "sony_playstation5.c4z", proxy = "dvd", proxy_id = PS5 })
		fake.add_device(135, { name = "Radio", driver = "generic_tuner.c4z", proxy = "tuner", proxy_id = RADIO })
		fake.add_device(155, { name = "Roku", driver = "roku_ip.c4z", proxy = "media_player", proxy_id = ROKU })
		-- Choice B of research §4.1: the receiver's second output into the box's HDMI 1.
		c4:Bind(RECEIVER, 2001, BOX, 1000, "HDMI")
		c4:Bind(APPLE, 2000, RECEIVER, 1000, "HDMI")
		c4:Bind(PS5, 2000, RECEIVER, 1001, "HDMI")
		c4:Bind(ROKU, 2000, TV, 1002, "HDMI")   -- straight into the TV: it bypasses the receiver
		model = asleep()
		wiring, online, settings, peer, notes = "second_output", true, {}, nil, {}
		start(BEDROOM, "Bedroom")
	end)

	after_each(function()
		log.sink = print
	end)

	describe("on a receiver's second output", function()
		it("W15: a start with the room already on changes nothing on the box", function()
			watch(BEDROOM, APPLE)
			start(BEDROOM, "Bedroom")   -- the driver restarted mid-film
			c4.advance(10000)
			assert.same({}, q.sets)
			assert.same({}, notes)
			assert.equal("Follows Bedroom (watching Apple TV)", f:status())
		end)

		it("W11: a Watch source picked on a Navigator wakes the box and syncs in its mode, after the settle", function()
			watch(BEDROOM, APPLE)
			assert.same({}, q.sets, "nothing before the settle")
			settle()
			assert.same({ { fields = { hdmiActive = true, mode = "video", syncActive = true }, tag = "follow:sync:video" } },
				q.sets)
			assert.equal("Bedroom on Apple TV: syncing video", last_action())
		end)

		it("W12: the same selection from programming acts the same way", function()
			fake.room_variable(BEDROOM, 1002, PS5)
			fake.room_variable(BEDROOM, 1008, path(PS5, RECEIVER, TV))
			fake.room_variable(BEDROOM, 1000, PS5)
			settle()
			assert.equal(1, #q.sets)
			assert.equal("game", q.sets[1].fields.mode, "Game guessed from its driver's file name")
		end)

		it("W19: zapping through sources sends one intent, for the last", function()
			watch(BEDROOM, APPLE)
			c4.advance(200)
			watch(BEDROOM, PS5)
			c4.advance(200)
			watch(BEDROOM, APPLE)
			c4.advance(200)
			watch(BEDROOM, PS5)
			settle()
			assert.equal(1, #q.sets)
			assert.equal("game", q.sets[1].fields.mode)
		end)

		it("a source change while syncing changes the mode", function()
			model = syncing("video")
			watch(BEDROOM, PS5)
			settle()
			assert.same({ mode = "game", syncActive = true }, q.sets[1].fields)
		end)

		it("sends nothing the box already shows", function()
			model = syncing("video")
			watch(BEDROOM, APPLE)
			settle()
			assert.same({}, q.sets)
		end)

		it("names the box's input when the receiver is bound to it and the box is on another", function()
			model = { power = "on", mode = "passthrough", syncing = false, input = 3 }
			watch(BEDROOM, APPLE)
			settle()
			assert.same({ hdmiSource = "input1", mode = "video", syncActive = true }, q.sets[1].fields)
		end)

		it("W18: Listen syncs music; no sound on the second output is said once", function()
			listen(BEDROOM, RADIO)
			settle()
			assert.same({ hdmiActive = true, mode = "music", syncActive = true }, q.sets[1].fields)
			assert.equal("follow:sync:music", q.sets[1].tag)
			model = { power = "on", mode = "passthrough", syncing = false, input = 1 }
			assert.is_true(f:done("follow:sync:music", false, model))
			assert.equal("No sound on the second output: music sync did not start", last_action())
			local n = #notes
			f:done("follow:sync:music", false, model)
			assert.equal(n, #notes, "said once")
			f:done("follow:sync:music", true, syncing("music"))
			f:done("follow:sync:music", false, model)
			assert.equal(n + 1, #notes, "said again after music synced once")
		end)

		it("Room Off: At Room Off, Power save by default", function()
			model = syncing("video")
			watch(BEDROOM, APPLE)
			settle()
			room_off(BEDROOM)
			settle()
			assert.same({ { fields = { mode = "powersave" }, tag = "follow:off" } }, q.sets)
			assert.equal("Bedroom off: power save", last_action())
			assert.equal("Follows Bedroom (off)", f:status())
		end)

		it("Room Off: Stop syncing and keep the picture when At Room Off says so", function()
			model = syncing("video")
			watch(BEDROOM, APPLE)
			settle()
			settings = { at_room_off = "Stop syncing and keep the picture" }
			room_off(BEDROOM)
			settle()
			assert.same({ syncActive = false }, q.sets[1].fields)
		end)

		it("Room Off with the box already in power save sends nothing", function()
			watch(BEDROOM, APPLE)   -- unsent: the spec's box never woke
			model = asleep()
			q.sets = {}
			room_off(BEDROOM)
			settle()
			assert.same({}, q.sets)
		end)

		it("W17 (choice B): a source that does not pass the receiver: When The Source Leaves The Box", function()
			model = syncing("video")
			watch(BEDROOM, ROKU, false)
			settle()
			assert.same({ { fields = { syncActive = false }, tag = "follow:leave" } }, q.sets)
			assert.equal("Bedroom on Roku, which does not pass the box: sync stopped", last_action())
			model = syncing("video")
			settings = { source_leaves = "Power save" }
			watch(BEDROOM, APPLE)
			settle()
			watch(BEDROOM, ROKU, false)
			settle()
			assert.same({ mode = "powersave" }, q.sets[#q.sets].fields)
		end)

		it("W17 (choice A): with nothing bound upstream only a source set to Do not sync leaves", function()
			c4:Unbind(BOX, 1000)
			f:refresh()
			watch(BEDROOM, ROKU, false)
			settle()
			assert.same({ hdmiActive = true, mode = "video", syncActive = true }, q.sets[1].fields,
				"cannot tell: the box reports no picture itself (edge case I16)")
			model = syncing("video")
			s:set_mode(ROKU, "Do not sync")
			watch(BEDROOM, APPLE)
			settle()
			watch(BEDROOM, ROKU, false)
			settle()
			assert.same({ syncActive = false }, q.sets[#q.sets].fields)
			assert.equal("Bedroom on Roku (Do not sync): sync stopped", last_action())
		end)

		it("W13: a source changed outside Control4 (the receiver's remote, CEC): nothing seen, nothing done", function()
			model = syncing("video")
			watch(BEDROOM, APPLE)
			settle()
			-- The receiver switches by its own remote: the box reads another signal, the room nothing.
			model = syncing("video", 1)
			model.mode = "game"
			c4.advance(60000)
			assert.same({}, q.sets)
			assert.equal("Follows Bedroom (watching Apple TV)", f:status())
		end)

		it("W14: programming that switches the receiver directly, not through the room: nothing", function()
			c4.device_variables[RECEIVER] = { [1000] = "2" }
			c4.advance(60000)
			assert.same({}, q.sets)
			assert.is_false(c4.listens(RECEIVER, 1000))
		end)

		it("W2: None: no room followed, the box runs on its own settings", function()
			r:stop()
			f:set_room(nil)
			assert.equal(0, fake.room_variable(BEDROOM, 1000, APPLE))
			assert.is_false(f:changed({ room_id = BEDROOM, selected = APPLE, kind = "watch", video_path = {},
				audio_path = {} }))
			c4.advance(10000)
			assert.same({}, q.sets)
			assert.equal("Follows no room: the box runs on its own settings", f:status())
			wiring = "in_line"
			assert.is_nil(f:status())
		end)

		it("W4: the followed room deleted: following stops and the box is left as it is", function()
			model = syncing("video")
			local choice = room.choice()
			choice:choose("Den")
			f:set_room(DEN, "Den")
			r:follow(DEN, "Den")
			c4.advance(room.BASELINE_MS)
			fake.delete_room(DEN)
			local res = choice:resolve()
			assert.equal("gone", res.how)
			f:set_room(res.room_id)
			r:stop()
			c4.advance(60000)
			assert.same({}, q.sets)
		end)

		it("W5 and W6: the device moved: the new room is followed from a baseline", function()
			local choice = room.choice()
			assert.equal(BEDROOM, choice:resolve().room_id)
			watch(DEN, APPLE)
			fake.move_device(OWN_DEVICE, DEN)
			local res = choice:resolve()
			assert.equal(DEN, res.room_id)
			assert.equal("Follows Den now: this device moved there from Bedroom", res.last_action)
			f:set_room(res.room_id, res.name)
			r:follow(res.room_id, res.name)
			c4.advance(room.BASELINE_MS)
			assert.same({}, q.sets, "a baseline")
			watch(BEDROOM, PS5)
			settle()
			assert.same({}, q.sets, "the old room is not followed")
			listen(DEN, RADIO)
			settle()
			assert.equal("music", q.sets[1].fields.mode)
		end)

		it("W7: a room other than the device's is followed as chosen", function()
			local choice = room.choice()
			choice:choose("Den")
			local res = choice:resolve()
			f:set_room(res.room_id, res.name)
			r:follow(res.room_id, res.name)
			c4.advance(room.BASELINE_MS)
			watch(DEN, APPLE)
			settle()
			assert.equal(1, #q.sets)
			assert.equal("Den on Apple TV: syncing video", last_action())
		end)

		it("a click that changes Follow Room may catch up at once (opts.catch_up)", function()
			watch(DEN, APPLE)
			f:set_room(DEN, "Den", { catch_up = true })
			r:follow(DEN, "Den")
			c4.advance(room.BASELINE_MS)
			assert.equal(1, #q.sets)
			assert.equal("Follow Room changed: Den on Apple TV: syncing video", last_action())
		end)

		it("W8: a selection linked from another room acts through the followed room's own variables", function()
			watch(BEDROOM, APPLE)   -- what Den's linked selection makes Bedroom show (assumed, P8)
			settle()
			assert.equal(1, #q.sets)
			assert.is_false(c4.listens(DEN, 1000), "the linked room is not followed too")
		end)

		it("W9: two rooms on one receiver: only the followed room's selections act", function()
			watch(DEN, APPLE)
			settle()
			assert.same({}, q.sets)
			watch(BEDROOM, PS5)
			settle()
			assert.equal(1, #q.sets)
		end)

		it("W10: another box of this project syncs the area: no sync start, Attention names both", function()
			peer = "Living Room Sync Box"
			watch(BEDROOM, APPLE)
			settle()
			assert.same({}, q.sets)
			assert.equal("Bedroom Sync Box and Living Room Sync Box sync the same entertainment area: Bedroom Sync "
				.. "Box did not start syncing, so neither takes the other's stream", attention())
			room_off(BEDROOM)
			model = syncing("video")
			settle()
			assert.same({ mode = "powersave" }, q.sets[1].fields, "Room Off takes nothing from anyone")
		end)

		it("W10: a box busy with another stream (code 16) is reported, never retried, never taken over", function()
			watch(BEDROOM, APPLE)
			settle()
			assert.equal(1, #q.sets)
			assert.is_true(f:done("follow:sync:video", "busy", model))
			assert.equal("Bedroom Sync Box did not start syncing: another app streams to its entertainment area",
				attention())
			f:done("follow:sync:video", false, model, "busy")
			assert.is_false(f:contact(), "nothing pending to re-send")
			c4.advance(60000)
			assert.equal(1, #q.sets)
		end)

		it("W23: the box offline while the room changes: at contact the room's current state, once", function()
			online = false
			watch(BEDROOM, APPLE)
			settle()
			watch(BEDROOM, PS5)
			settle()
			room_off(BEDROOM)
			settle()
			watch(BEDROOM, APPLE)
			settle()
			assert.same({}, q.sets, "nothing queued for a box that does not answer")
			assert.equal("Bedroom on Apple TV: syncing video, once the box answers again", last_action())
			online = true
			assert.is_true(f:contact())
			assert.same({ { fields = { hdmiActive = true, mode = "video", syncActive = true }, tag = "follow:sync:video" } },
				q.sets, "the current state only, never the missed sequence")
			assert.equal("When the box answered again: Bedroom on Apple TV: syncing video", last_action())
			assert.is_false(f:contact(), "once")
		end)

		it("W23: an undelivered intent is applied at contact only if the box still differs", function()
			watch(BEDROOM, APPLE)
			settle()
			f:done("follow:sync:video", false, nil)
			model = syncing("video")   -- the box got there anyway
			assert.is_false(f:contact())
			assert.equal(1, #q.sets)
			watch(BEDROOM, PS5)
			settle()
			f:done("follow:sync:game", false, nil)
			assert.is_true(f:contact())
			assert.equal("game", q.sets[#q.sets].fields.mode)
		end)

		it("W23: a write replaced, cleared or refused leaves nothing for contact; one not landed does", function()
			watch(BEDROOM, APPLE)
			settle()
			for _, why in ipairs({ "superseded", "cancelled", "refused" }) do
				f:done("follow:sync:video", false, model, why)
				assert.is_false(f:contact(), why)
			end
			f:done("follow:sync:video", false, model, "not landed")
			assert.is_true(f:contact())
			assert.equal(2, #q.sets)
		end)

		it("a source set to Do not sync leaves the box out", function()
			model = syncing("video")
			s:set_mode(PS5, "Do not sync")
			watch(BEDROOM, PS5)
			settle()
			assert.same({ syncActive = false }, q.sets[1].fields)
		end)

		it("a selection the room cannot read is not acted on", function()
			fake.room_variable(BEDROOM, 1000, "garbage")
			settle()
			assert.same({}, q.sets)
		end)

		it("survives a queue that raises", function()
			q.set = function() error("full") end
			watch(BEDROOM, APPLE)
			assert.has_no.errors(settle)
		end)
	end)

	describe("W22: the wiring changes on the box", function()
		it("a change to the second output catches up once with the room, said in Last Action", function()
			wiring = "in_line"
			assert.is_false(f:wiring_changed("in_line"), "the first wiring of a run is a baseline")
			watch(BEDROOM, APPLE)
			settle()
			assert.same({}, q.sets, "in line, Director's commands drive")
			wiring = "second_output"
			assert.is_true(f:wiring_changed("second_output"))
			assert.equal(1, #q.sets)
			assert.equal("The box is now on a receiver's second output; Bedroom on Apple TV: syncing video",
				last_action())
			assert.is_false(f:wiring_changed("second_output"))
			wiring = "in_line"
			assert.is_false(f:wiring_changed("in_line"))
			assert.equal(1, #q.sets)
		end)

		it("the first wiring read of a run never acts, even on the second output", function()
			watch(BEDROOM, APPLE)
			start(BEDROOM, "Bedroom")
			assert.is_false(f:wiring_changed("second_output"))
			assert.same({}, q.sets)
		end)
	end)

	describe("behind a receiver", function()
		it("sends nothing: Director's commands and av.lua drive, Listen included (provisional answer 2 is av's)",
			function()
				wiring = "behind_receiver"
				model = syncing("video")
				listen(BEDROOM, RADIO)
				settle()
				watch(BEDROOM, PS5)
				settle()
				room_off(BEDROOM)
				settle()
				assert.same({}, q.sets)
				assert.is_nil(follow.LISTEN_BEHIND_RECEIVER, "one constant for the answer, in av.lua")
			end)
	end)

	describe("in line", function()
		it("leaves everything to Director's commands and the input", function()
			wiring = "in_line"
			watch(BEDROOM, APPLE)
			settle()
			listen(BEDROOM, RADIO)
			settle()
			room_off(BEDROOM)
			settle()
			assert.same({}, q.sets)
		end)
	end)

	describe("the interface", function()
		it("needs a queue", function()
			assert.has_error(function() follow.new({}) end)
		end)

		it("owns only its own tags", function()
			assert.is_true(follow.owns("follow:sync:video"))
			assert.is_false(follow.owns("av:set_input"))
			assert.is_false(follow.owns("followers"))
			assert.is_false(f:done("av:set_input", false, nil))
		end)

		it("works without sources: Watch is Video and Listen Music", function()
			local q2 = { sets = {} }
			function q2.set(self, fields, tag) self.sets[#self.sets + 1] = { fields = fields, tag = tag } end
			local bare = follow.new({ queue = q2, wiring = function() return "second_output" end })
			bare:set_room(LIVING, "Living Room")
			local st = { room_id = LIVING, selected = APPLE, kind = "watch", video_path = {}, audio_path = {} }
			bare:baseline(st)
			st = { room_id = LIVING, selected = RADIO, kind = "listen", video_path = {}, audio_path = {} }
			assert.is_true(bare:changed(st))
			assert.equal("music", q2.sets[1].fields.mode)
			assert.equal("Follows Living Room (listening to device 140)", bare:status())
		end)
	end)
end)
