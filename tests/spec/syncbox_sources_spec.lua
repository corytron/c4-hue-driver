-- syncbox/sources.lua (#557, docs/hdmi-sync-stage3-design.md §4; research
-- docs/syncbox-wirings-research.md §2, §3.2, §5 W21 and §7.2): a source's
-- name and kind through C4:GetDevices, the sources upstream of the box
-- through its bindings, the sync mode each calls for with research §7.2's
-- precedence, and the per-source settings stored by device id with the name
-- they had. The project is the fake runtime's (tests/helpers/fake_c4.lua:
-- fake.add_device makes a source and its proxy; C4:Bind connects them).
-- Device ids, names and driver files are made up; no LAN address appears.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BOX = 300                    -- the box's avswitch proxy
local RECEIVER, RECEIVER_DEV = 210, 200
local APPLE, APPLE_DEV = 120, 110
local PS5, PS5_DEV = 130, 125
local RADIO, RADIO_DEV = 140, 135
local XBOX = 150                   -- a combo driver: no proxy

describe("syncbox/sources.lua (#557)", function()
	local sources, c4, s, lines

	before_each(function()
		lines = {}
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		package.loaded["syncbox.sources"] = nil
		sources = require("syncbox.sources")
		fake.add_device(RECEIVER_DEV, { name = "AV Receiver", driver = "denon_avr.c4z", proxy = "receiver",
			proxy_id = RECEIVER })
		fake.add_device(APPLE_DEV, { name = "Apple TV", driver = "apple_tv_ip.c4z", proxy = "media_player",
			proxy_id = APPLE })
		fake.add_device(PS5_DEV, { name = "PS5", driver = "sony_playstation5.c4z", proxy = "dvd", proxy_id = PS5 })
		fake.add_device(RADIO_DEV, { name = "Radio", driver = "generic_tuner.c4z", proxy = "tuner", proxy_id = RADIO })
		fake.add_device(XBOX, { name = "Xbox", driver = "xbox_series.c4z", proxy = false })
		-- The receiver's HDMI out into the box's HDMI 1; two sources on the receiver.
		c4:Bind(RECEIVER, 2000, BOX, 1000, "HDMI")
		c4:Bind(APPLE, 2000, RECEIVER, 1000, "HDMI")
		c4:Bind(PS5, 2000, RECEIVER, 1003, "HDMI")
		s = sources.new()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("describe", function()
		it("names a source and its kind from its proxy id", function()
			local d = s:describe(APPLE)
			assert.equal(APPLE, d.id)
			assert.equal("Apple TV", d.name)
			assert.equal("media_player", d.proxy_kind)
			assert.equal("apple_tv_ip.c4z", d.driver_file)
			assert.equal(APPLE_DEV, d.protocol_id)
			assert.same({ [APPLE] = true, [APPLE_DEV] = true }, d.ids)
			assert.equal(7, d.room_id)
			assert.same({ { { DeviceIds = tostring(APPLE) } } }, (function()
				local out = {}
				for _, args in ipairs(c4.calls_to("GetDevices")) do out[#out + 1] = { args[1] } end
				return out
			end)(), "the filter value is a string")
		end)

		it("from the protocol id too, and a combo driver without a proxy kind", function()
			local d = s:describe(PS5_DEV)
			assert.equal("dvd", d.proxy_kind)
			assert.equal("sony_playstation5.c4z", d.driver_file)
			assert.is_true(d.ids[PS5])
			local x = s:describe(XBOX)
			assert.is_nil(x.proxy_kind)
			assert.equal("xbox_series.c4z", x.driver_file)
		end)

		it("tells a device gone from a lookup that failed", function()
			assert.same({ nil, "gone" }, { s:describe(999) })
			s = sources.new({ get_devices = function() error("busy") end })
			assert.same({ nil, "error" }, { s:describe(APPLE) })
			assert.same({ nil, "error" }, { s:describe("abc") })
		end)

		it("checks every value: names capped and without control characters, odd file names dropped", function()
			s = sources.new({ get_devices = function()
				return { [APPLE] = { deviceName = string.rep("A", 300) .. "\n[ERROR] forged",
					driverFileName = "tv.c4i", protocol = { [APPLE_DEV] = { driverFileName = "evil file;rm.c4z" } } } }
			end })
			local d = s:describe(APPLE)
			assert.is_true(#d.name <= sources.NAME_MAX)
			assert.is_nil(d.name:find("\n", 1, true))
			assert.is_nil(d.driver_file)
			assert.equal("tv", d.proxy_kind)
		end)
	end)

	describe("upstream", function()
		it("finds the receiver on HDMI 1 and the sources behind it", function()
			local up = s:upstream(BOX)
			assert.equal(RECEIVER, up.inputs[1].id)
			assert.equal("receiver", up.inputs[1].proxy_kind)
			assert.equal(1, up.first_input)
			assert.is_true(up.ids[RECEIVER])
			assert.is_true(up.ids[RECEIVER_DEV])
			local names = {}
			for _, d in ipairs(up.sources) do names[#names + 1] = d.name .. "@" .. d.via end
			table.sort(names)
			assert.same({ "Apple TV@1", "PS5@1" }, names)
		end)

		it("reads 0 or nothing as no binding, and a table answer by its lowest id", function()
			s = sources.new({ bound_provider = function(device, binding)
				if device == BOX and binding == 1001 then return { [APPLE] = "Apple TV", [PS5] = "PS5" } end
				return 0
			end })
			local up = s:upstream(BOX)
			assert.is_nil(up.inputs[1])
			assert.equal(APPLE, up.inputs[2].id)
			assert.equal(2, up.first_input)
			assert.same({ inputs = {}, sources = {}, ids = {} }, sources.new():upstream(nil))
		end)
	end)

	describe("mode_for (research §7.2)", function()
		local function second(id, kind) return s:mode_for({ selected = id, kind = kind or "watch" }, "second_output") end

		it("second output: Video by default, Game guessed from the driver's file name, Music for a tuner", function()
			assert.same({ "video", "default" }, { second(APPLE) })
			assert.same({ "game", "guess" }, { second(PS5) })
			assert.same({ "game", "guess" }, { second(XBOX) })
			assert.same({ "music", "kind" }, { second(RADIO) })
		end)

		it("a CD player is Music by its kind (probe P11 listed a CD player as Video, #557)", function()
			local CD_DEV, CD = 3901, 3902
			fake.add_device(CD_DEV, { name = "CD", driver = "cd_generic_ir.c4i", proxy = "cd", proxy_id = CD })
			assert.same({ "music", "kind" }, { second(CD) })
		end)

		it("Listen is Music, whatever the device", function()
			assert.same({ "music", "listen" }, { second(APPLE, "listen") })
			assert.same({ "music", "listen" }, { second(PS5, "listen") })
		end)

		it("the dealer's setting comes first, before Listen and the guess", function()
			s:set_mode(PS5, "Video")
			s:set_mode(APPLE, "Do not sync")
			assert.same({ "video", "set" }, { second(PS5) })
			assert.same({ "none", "set" }, { second(APPLE, "listen") })
		end)

		it("nothing selected, or Room Off, has no mode", function()
			assert.is_nil((second(0)))
			assert.is_nil((s:mode_for({ selected = APPLE, kind = "off" }, "second_output")))
			assert.is_nil((s:mode_for(nil, "behind_receiver")))
		end)

		it("behind a receiver follows the same precedence; a bare id is a Watch", function()
			assert.same({ "game", "guess" }, { s:mode_for(PS5, "behind_receiver") })
			assert.same({ "music", "listen" }, { s:mode_for({ id = APPLE, kind = "listen" }, "behind_receiver") })
		end)

		it("in line: HDMI n Sync Mode, then an audio-only route, then the box's input type, then Video", function()
			assert.same({ "game", "set" }, { s:mode_for(nil, "in_line", { n = 1, setting = "Game", audio_only = true }) })
			assert.same({ "none", "set" }, { s:mode_for(nil, "in_line", { setting = "Do not sync" }) })
			assert.same({ "music", "route" }, { s:mode_for(nil, "in_line", { setting = "Automatic", audio_only = true,
				type = "xbox" }) })
			assert.same({ "game", "type" }, { s:mode_for(nil, "in_line", { setting = "Automatic", type = "playstation" }) })
			assert.same({ "music", "type" }, { s:mode_for(nil, "in_line", { type = "soundbar" }) })
			assert.same({ "video", "default" }, { s:mode_for(nil, "in_line", { type = "appletv" }) })
			assert.same({ "video", "default" }, { s:mode_for(nil, "in_line") })
		end)

		it("the game guess is one constant: \"offer\" shows it without applying it", function()
			assert.equal("apply", sources.GAME_GUESS, "provisional owner answer 3 (#536)")
			sources.GAME_GUESS = "offer"
			local mode = second(PS5)
			local summary = s:summary(BOX)
			sources.GAME_GUESS = "apply"
			assert.equal("video", mode)
			assert.equal("Apple TV: Video; PS5: Video (Game guessed from its driver)", summary)
		end)
	end)

	describe("the per-source settings", function()
		it("stores a mode by device id with the name it had, as a table, with no encrypted flag", function()
			assert.same({ true, "Source Sync Mode of PS5: Game" }, { s:set_mode(PS5, "Game") })
			assert.same({ [tostring(PS5)] = { mode = "game", name = "PS5" } }, c4.persist[sources.STORE_KEY])
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do assert.is_false(args[3]) end
			assert.equal("game", s:setting(PS5))
		end)

		it("Automatic removes the setting; anything else is refused", function()
			s:set_mode(PS5, "Music")
			assert.same({ true, "Source Sync Mode of PS5: Automatic" }, { s:set_mode(PS5, "automatic") })
			assert.is_nil(s:setting(PS5))
			assert.same({}, c4.persist[sources.STORE_KEY])
			assert.same({ false, "not a sync mode" }, { s:set_mode(PS5, "Loud") })
			assert.same({ false, "no source" }, { s:set_mode("x", "Game") })
		end)

		it("keeps what it stored in memory, whatever the storage answers right after", function()
			local stored
			s = sources.new({ persist_get = function() return nil end, persist_set = function(_, v) stored = v end })
			s:set_mode(APPLE, "Music")
			assert.equal("music", s:setting(APPLE))
			assert.same({ mode = "music", name = "Apple TV" }, stored[tostring(APPLE)])
		end)

		it("checks what it loads: unknown modes, odd ids and long names", function()
			c4.persist[sources.STORE_KEY] = {
				[tostring(APPLE)] = { mode = "music", name = string.rep("n", 500) },
				[tostring(PS5)] = { mode = "disco" },
				["-3"] = { mode = "video" },
				["abc"] = { mode = "video" },
			}
			assert.equal("music", s:setting(APPLE))
			assert.is_nil(s:setting(PS5))
			assert.is_true(#s:modes()[APPLE].name <= sources.NAME_MAX)
			local n = 0
			for _ in pairs(s:modes()) do n = n + 1 end
			assert.equal(1, n)
		end)

		it("holds at most STORE_MAX sources with a setting of their own", function()
			local m = s:modes()
			for i = 1, sources.STORE_MAX do m[5000 + i] = { mode = "video", name = "S" .. i } end
			assert.same({ false, "too many sources with a sync mode of their own" }, { s:set_mode(APPLE, "Game") })
			assert.is_true((s:set_mode(5001, "Game")), "an existing entry may change")
		end)
	end)

	describe("Source Sync Modes and the action's list", function()
		it("lists the sources upstream, the ones seen in the room and the stored ones, by name", function()
			s:saw(RADIO)
			assert.equal("Apple TV: Video; PS5: Game (guessed from its driver); Radio: Music", s:summary(BOX))
			local ids = {}
			for _, item in ipairs(s:candidates(BOX)) do ids[#ids + 1] = item.id end
			assert.same({ APPLE, PS5, RADIO }, ids)
		end)

		it("shows a setting the dealer made", function()
			s:set_mode(APPLE, "Music")
			assert.equal("Apple TV: Music; PS5: Game (guessed from its driver)", s:summary(BOX))
		end)

		it("says so when nothing is known, and cuts a long list", function()
			assert.equal("No sources found yet", sources.new():summary(nil))
			for i = 1, sources.SUMMARY_MAX + 3 do
				fake.add_device(6000 + 2 * i, { name = string.format("Source %02d", i), proxy_id = 6001 + 2 * i })
				s:saw(6001 + 2 * i)
			end
			local text = s:summary(nil)
			assert.truthy(text:find("; and 3 more$"))
		end)

		it("keeps the latest name of a renamed source it stores", function()
			s:set_mode(APPLE, "Music")
			c4:RenameDevice(APPLE, "Den Apple TV")
			s:candidates(BOX)
			assert.same({ mode = "music", name = "Den Apple TV" }, c4.persist[sources.STORE_KEY][tostring(APPLE)])
		end)
	end)

	describe("W21: a source device deleted or replaced in Composer", function()
		it("keeps its mode, shown as (device gone); the new device starts at Automatic; the old mode is offered",
			function()
				s:set_mode(APPLE, "Music")
				fake.delete_device(APPLE)
				assert.equal("Apple TV: Music (device gone); PS5: Game (guessed from its driver)", s:summary(BOX))
				assert.equal("music", s:setting(APPLE), "kept")
				-- The replacement: same name, a new device, connected where the old one was.
				fake.add_device(160, { name = "Apple TV", driver = "apple_tv_ip.c4z", proxy = "media_player",
					proxy_id = 170 })
				c4:Bind(170, 2000, RECEIVER, 1000, "HDMI")
				assert.same({ "video", "default" },
					{ s:mode_for({ selected = 170, kind = "watch" }, "second_output") }, "not applied by itself")
				local offers = s:offers(BOX)
				assert.equal(1, #offers)
				assert.same({ from_id = APPLE, to_id = 170, name = "Apple TV", mode = "music" },
					{ from_id = offers[1].from_id, to_id = offers[1].to_id, name = offers[1].name, mode = offers[1].mode })
				assert.equal("Apple TV (device 170) replaces a source set to Music: give it Music with Set Source Sync "
					.. "Mode", offers[1].text)
				-- One click.
				assert.is_true(s:accept(APPLE, 170))
				assert.equal("music", s:setting(170))
				assert.is_nil(s:setting(APPLE))
				assert.same({}, s:offers(BOX))
			end)

		it("offers nothing when two present sources share the old name, or the new one has its own setting", function()
			s:set_mode(APPLE, "Music")
			fake.delete_device(APPLE)
			fake.add_device(160, { name = "Apple TV", proxy_id = 170 })
			fake.add_device(180, { name = "Apple TV", proxy_id = 190 })
			s:saw(170)
			s:saw(190)
			assert.same({}, s:offers(nil))
			s:set_mode(190, "Video")
			assert.equal(1, #s:offers(nil), "the one without a setting")
			s:set_mode(170, "Game")
			assert.same({}, s:offers(nil))
			assert.is_false(s:accept(APPLE, 170), "never over a setting of its own")
		end)

		it("a lookup that fails is not a device gone", function()
			s:set_mode(APPLE, "Music")
			local list = sources.new({ get_devices = function() error("busy") end }):candidates(nil)
			assert.is_false(list[1].gone)
		end)
	end)
end)
