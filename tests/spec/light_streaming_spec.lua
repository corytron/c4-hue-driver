-- Hue Light and zone light devices while their lamps follow a TV sync (an
-- entertainment stream): docs/hdmi-sync-stage1-design.md §5.1, contracts C7
-- in docs/hdmi-sync-contracts.md, the owner's decision O9 in
-- docs/hdmi-sync-design.md §10. Against the fake runtime, with a bridge
-- standing behind binding 1 as device 15. The bridge's HUE_STATE carries
-- `streaming` ("true" / "false"), `stream_label` while it is true, and for a
-- zone or room light `lamps` and `streaming_lamps`.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local LIGHT_ID = 2001
local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"

local CONFIGURE = { rid = "l1", name = "Desk", model = "Hue color lamp", has_color = "true", has_cct = "true",
	mirek_min = "153", mirek_max = "500", min_dim = "0.2" }
local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
	model = "Hue zone", hue_room = "Bedside Lights (zone)", id_v1 = "/groups/2", has_color = "true",
	has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

-- The texts of §5.1, with the stage 1 bridge's label.
local SYNCING = "Syncing with the TV (another app)"
local NOT_CHANGED = "Not changed: the lamp follows the TV while it syncs (another app)"
local NOT_CHANGED_ZONE = "Not changed: the lamps follow the TV while they sync (another app)"
local IDENTITY = "Desk (Hue color lamp)"
local ZONE_IDENTITY = "Hue zone Bedside Lights (2 lights)"

-- The read of the proxy's presets after late init, and the window of the
-- Hue-side level reports (#433 D12).
local SETUP_READ_MS = 3000
local LEVEL_REPORT_MS = 1000

local function quiet()
	log.sink = function() end
end

local function load_light(rid, opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
	end
	c4.persist.hue_rid = rid
	env.OnDriverLateInit("DIT_STARTUP")
	assert(c4.fire_timers_of(SETUP_READ_MS) == 1, "late init arms the read of the proxy's presets")
	return env, c4
end

-- A configured light (or, with `base` ZONE, a zone device), on at 40 % in a
-- warm white, idle, with the recorded calls and messages cleared.
local function lit(base)
	base = base or CONFIGURE
	local env, c4 = load_light(base.rid)
	env.ExecuteCommand("HUE_CONFIGURE", base)
	env.ExecuteCommand("HUE_STATE", { rid = base.rid, on = "true", brightness = "40", mirek = "370",
		color_mode = "ct", online = "true", reason = "hello" })
	assert(c4.fire_timers_of(LEVEL_REPORT_MS) == 1, "the hello's report opens the level window")
	c4.calls, c4.sent = {}, {}
	return env, c4
end

-- The bridge says the lamp streams (an event, as when `mode` turns
-- "streaming"); `extra` adds or overrides fields.
local function sync(env, rid, extra)
	local params = { rid = rid or "l1", streaming = "true", stream_label = "another app", reason = "event" }
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_STATE", params)
end

local function unsync(env, rid)
	env.ExecuteCommand("HUE_STATE", { rid = rid or "l1", streaming = "false", reason = "event" })
end

-- Params of every SendToProxy to the proxy binding with that command.
local function notifies(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 5001 and args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

-- Every light command sent to the bridge (HUE_SET, HUE_DIM), in order.
local function commands(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == "HUE_SET" or m.command == "HUE_DIM" then out[#out + 1] = m end
	end
	return out
end

local function changing(c4)
	return notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")
end

local function changed(c4)
	return notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")
end

describe("Hue Light while its lamp syncs with the TV (#514, §5.1)", function()
	before_each(function()
		fake.reset_project()
		quiet()
	end)

	describe("Status, Online and the stream fields", function()
		it("Status reads Syncing with the TV (<stream_label>) and the device stays online", function()
			local env, c4 = lit()
			sync(env)
			assert.equal(SYNCING, env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			for _, n in ipairs(notifies(c4, "ONLINE_CHANGED")) do
				assert.is_true(n.STATE, "never offline because of the stream")
			end
			assert.equal(0, #changed(c4), "the state Hue reports stays: nothing to report")
		end)

		it("names whoever the bridge says streams, and another app when it names no one", function()
			local env = lit()
			sync(env, "l1", { stream_label = "Living Room sync box" })
			assert.equal("Syncing with the TV (Living Room sync box)", env.Properties["Status"])
			env = lit()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", streaming = "true", reason = "event" })
			assert.equal(SYNCING, env.Properties["Status"])
		end)

		it("keeps the stream through an event that does not mention it, and its label with it", function()
			local env, c4 = lit()
			sync(env, "l1", { stream_label = "Living Room sync box" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "55", reason = "event" })
			assert.equal("Syncing with the TV (Living Room sync box)", env.Properties["Status"])
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 55 } }, changed(c4), "Hue's reports still reach the proxy")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", stream_label = "another app", reason = "event" })
			assert.equal(SYNCING, env.Properties["Status"], "a new label while it runs")
		end)

		it("returns Status to what it showed when streaming turns false, and commands go out again", function()
			local env, c4 = lit()
			sync(env)
			assert.equal(SYNCING, env.Properties["Status"])
			unsync(env)
			assert.equal(IDENTITY, env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = "l1", on = "true", brightness = "75", rate = "0" } } }, commands(c4))
		end)

		it("a full state that does not mention the stream ends it; an undelivered answer does not", function()
			local env = lit()
			sync(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", reason = "undelivered" })
			assert.equal(SYNCING, env.Properties["Status"], "a bare undelivered answer says nothing of the stream")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", online = "true",
				reason = "resync" })
			assert.equal(IDENTITY, env.Properties["Status"], "a resync without it: no stream (an older bridge too)")
		end)

		it("a streaming value that is not a boolean changes nothing", function()
			local env = lit()
			sync(env, "l1", { streaming = "maybe" })
			assert.equal(IDENTITY, env.Properties["Status"])
			sync(env)
			sync(env, "l1", { streaming = "maybe" })
			assert.equal(SYNCING, env.Properties["Status"])
		end)

		it("every reason the device cannot be reached comes first in Status: the link, a forget", function()
			local env, c4 = lit()
			sync(env)
			env.ExecuteCommand("HUE_BRIDGE_LINK", { state = "offline", reason = "not_answering", since = "1762696920" })
			assert.truthy(env.Properties["Status"]:find("^Hue Bridge"), env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"], "offline for the link, not for the stream")
			env.ExecuteCommand("HUE_BRIDGE_LINK", { state = "online" })
			assert.equal(SYNCING, env.Properties["Status"])
			assert.same({ STATE = true }, notifies(c4, "ONLINE_CHANGED")[2])
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1" })
			assert.truthy(env.Properties["Status"]:find("^Forgotten by the bridge"))
		end)

		it("forgets the stream with the bridge binding: the next bridge says its own", function()
			local env, c4 = lit()
			sync(env)
			assert.equal(SYNCING, env.Properties["Status"])
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.equal(IDENTITY, env.Properties["Status"])
			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(1, #commands(c4))
		end)
	end)

	describe("commands are not sent; the proxy hears the known state (O9)", function()
		it("a brightness target: CHANGING to it, then CHANGED at the level the light shows, and Last Action", function()
			local env, c4 = lit() -- on at 40 %
			sync(env)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })
			assert.same({}, commands(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 75, RATE = 500 } }, changing(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
			assert.equal(NOT_CHANGED, fake.last_action(env))
			assert.equal(0, #c4.active_timers(), "no ramp, no fallback")
			assert.equal(SYNCING, env.Properties["Status"])
			-- The stops, with nothing running, only report, as before.
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			env.ReceivedFromProxy(5001, "SET_COLOR_STOP", {})
			assert.same({}, commands(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 }, { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
		end)

		it("on, off, toggle, level, ramp and the dynamic commands each close their CHANGING at 40 %", function()
			local cases = {
				{ "ON", {} }, { "OFF", {} }, { "TOGGLE", {} }, { "SET_LEVEL", { LEVEL = "70" } },
				{ "RAMP_TO_LEVEL", { LEVEL = "70", TIME = "2000" } }, { "DYNAMIC_OFF", {} },
				{ "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "1000" } },
			}
			for _, case in ipairs(cases) do
				local env, c4 = lit()
				sync(env)
				env.ReceivedFromProxy(5001, case[1], case[2])
				assert.same({}, commands(c4), case[1])
				assert.equal(1, #changing(c4), case[1])
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4), case[1])
				assert.equal(NOT_CHANGED, fake.last_action(env), case[1])
				assert.equal(0, #c4.active_timers(), case[1])
			end
		end)

		it("a turn-on from off closes at 0, and the light stays off", function()
			local env, c4 = lit()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", reason = "event" })
			sync(env)
			c4.calls = {}
			for _, command in ipairs({ "ON", "TOGGLE", "DYNAMIC_ON" }) do
				env.ReceivedFromProxy(5001, command, {})
			end
			assert.same({}, commands(c4))
			assert.equal(3, #changing(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 }, { LIGHT_BRIGHTNESS_CURRENT = 0 },
				{ LIGHT_BRIGHTNESS_CURRENT = 0 } }, changed(c4))
		end)

		it("a colour or a colour temperature: CHANGING to it, then CHANGED with the colour the light shows", function()
			for _, mode in ipairs({ "0", "1" }) do
				local env, c4 = lit() -- warm white, 370 mirek
				sync(env)
				env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.2", LIGHT_COLOR_TARGET_Y = "0.3",
					LIGHT_COLOR_TARGET_COLOR_MODE = mode, LIGHT_COLOR_TARGET_RATE = "500" })
				assert.same({}, commands(c4), "mode " .. mode)
				local target = notifies(c4, "LIGHT_COLOR_CHANGING")
				assert.equal(1, #target, "mode " .. mode)
				assert.equal(0.2, target[1].LIGHT_COLOR_TARGET_X)
				local now = notifies(c4, "LIGHT_COLOR_CHANGED")
				assert.equal(1, #now, "mode " .. mode)
				assert.equal(1, now[1].LIGHT_COLOR_CURRENT_COLOR_MODE, "still the warm white it showed")
				assert.equal(NOT_CHANGED, fake.last_action(env))
				assert.equal(0, #c4.active_timers())
			end
		end)

		it("a colour sent while the light is off is not kept for the next turn-on either", function()
			local env, c4 = lit()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", reason = "event" })
			sync(env)
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.2", LIGHT_COLOR_TARGET_Y = "0.3",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.equal(1, notifies(c4, "LIGHT_COLOR_CHANGED")[1].LIGHT_COLOR_CURRENT_COLOR_MODE)
			unsync(env)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
			assert.same({ rid = "l1", on = "true", brightness = "60", rate = "0" }, commands(c4)[1].params,
				"no colour from the sync goes with the turn-on")
		end)

		it("a keypad tap sends nothing and closes its CHANGING; the button's own events still fire", function()
			local env, c4 = lit()
			sync(env)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.same({}, commands(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 1800,
				LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } }, changing(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
			assert.equal(NOT_CHANGED, fake.last_action(env))
			assert.same({ { BUTTON_ID = 0, ACTION = 1 }, { BUTTON_ID = 0, ACTION = 2 } }, notifies(c4, "BUTTON_ACTION"))
			c4.advance(600)
			assert.same({ { BUTTON_ID = 0, COUNT = 1 } }, notifies(c4, "CLICK_COUNT"))
		end)

		it("a keypad hold sends no dim and closes its CHANGING; the release sends no stop", function()
			local env, c4 = lit()
			sync(env)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.advance(400) -- the hold timer
			assert.same({}, commands(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 } }, changing(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
			assert.equal(NOT_CHANGED, fake.last_action(env))
			c4.advance(1000)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			assert.same({}, commands(c4))
			c4.advance(5000)
			assert.equal(1, #changed(c4), "no estimate assumed afterwards")
		end)

		it("a hold from off sends no turn-on and no dim", function()
			local env, c4 = lit()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", reason = "event" })
			sync(env)
			c4.calls = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.advance(2000)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			assert.same({}, commands(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, changed(c4))
		end)

		it("a load group's level, ramp and hold send nothing to the lamp", function()
			local env, c4 = lit()
			sync(env)
			env.ReceivedFromProxy(5001, "GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "70" })
			env.ReceivedFromProxy(5001, "GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1234", LEVEL = "70", TIME = "2000" })
			env.ReceivedFromProxy(5001, "GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "4000" })
			env.ReceivedFromProxy(5001, "GROUP_STOP_RAMP", { GROUP_ID = "1234" })
			assert.same({}, commands(c4))
			assert.equal(3, #changing(c4))
			for _, n in ipairs(changed(c4)) do
				assert.same({ LIGHT_BRIGHTNESS_CURRENT = 40 }, n)
			end
			assert.equal(NOT_CHANGED, fake.last_action(env))
		end)

		it("Raise Level By and Restore Saved Level change nothing and keep what was saved", function()
			local env, c4 = lit()
			env.ExecuteCommand("Raise Level By", { Points = "20", ["Ramp (ms)"] = "0" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "60", reason = "event" })
			assert.same({ level = 40, target = 60, at = c4.persist.saved_level.at }, c4.persist.saved_level)
			sync(env)
			c4.calls, c4.sent = {}, {}
			env.ExecuteCommand("Raise Level By", { Points = "20", ["Ramp (ms)"] = "0" })
			assert.equal(NOT_CHANGED, fake.last_action(env))
			env.ExecuteCommand("Restore Saved Level", { ["Ramp (ms)"] = "0" })
			assert.equal(NOT_CHANGED, fake.last_action(env))
			assert.same({}, commands(c4))
			assert.same({}, changing(c4), "programming sent these, not the proxy: nothing to close")
			assert.equal(40, c4.persist.saved_level.level, "the saved level stays for after the sync")
			assert.equal(60, c4.persist.saved_level.target)
			unsync(env)
			env.ExecuteCommand("Restore Saved Level", { ["Ramp (ms)"] = "0" })
			assert.equal("Restored to 40 %", fake.last_action(env))
		end)

	end)

	describe("a stream that begins while a command is in flight", function()
		it("ends a running ramp with the level Hue last reported; a stop then sends nothing", function()
			local env, c4 = lit() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "5000" })
			assert.equal(1, #commands(c4))
			c4.advance(1000)
			sync(env)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4), "the CHANGING is closed at once")
			assert.equal(0, #c4.active_timers(), "no ramp and no fallback left to assume the target")
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.equal(1, #commands(c4), "only the target sent before the stream")
		end)

		it("a hold that began before it: the release sends no stop and the proxy hears Hue's level", function()
			local env, c4 = lit()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.advance(400)
			assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, { commands(c4)[1].params })
			c4.advance(1000)
			sync(env)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			assert.equal(1, #commands(c4), "no HUE_DIM stop")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
			assert.equal(NOT_CHANGED, fake.last_action(env))
			c4.advance(5000)
			assert.equal(1, #changed(c4), "nothing assumed afterwards")
		end)
	end)
end)

describe("Hue zone light while its lamps sync with the TV (#514, §5.1)", function()
	before_each(function()
		fake.reset_project()
		quiet()
	end)

	it("some lamps syncing: Status counts them, and commands go out as before", function()
		local env, c4 = lit(ZONE)
		env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, streaming = "false", lamps = "6", streaming_lamps = "2",
			reason = "event" })
		assert.equal("2 of 6 lamps syncing with the TV", env.Properties["Status"])
		assert.equal("Online", env.Properties["Online"])
		env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
		assert.same({ { id = BRIDGE_ID, command = "HUE_SET",
			params = { rid = ZONE_RID, on = "true", brightness = "75", rate = "0" } } }, commands(c4))
		assert.equal("", fake.last_action(env))

		-- Only a zone or room light counts its lamps.
		env = lit()
		env.ExecuteCommand("HUE_STATE", { rid = "l1", streaming = "false", lamps = "6", streaming_lamps = "2",
			reason = "event" })
		assert.equal(IDENTITY, env.Properties["Status"])
	end)

	it("every lamp syncing: as a light, with the zone's own Last Action", function()
		local env, c4 = lit(ZONE)
		sync(env, ZONE_RID, { lamps = "6", streaming_lamps = "6" })
		assert.equal(SYNCING, env.Properties["Status"])
		env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
		assert.same({}, commands(c4))
		assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, changed(c4))
		assert.equal(NOT_CHANGED_ZONE, fake.last_action(env))
		env.ReceivedFromProxy(200, "DO_PUSH", {})
		env.ReceivedFromProxy(200, "DO_RELEASE", {})
		env.ReceivedFromProxy(200, "DO_CLICK", {})
		assert.same({}, commands(c4))
	end)

	it("from all to some to none: Status follows, back to what it showed", function()
		local env = lit(ZONE)
		sync(env, ZONE_RID, { lamps = "6", streaming_lamps = "6" })
		assert.equal(SYNCING, env.Properties["Status"])
		env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, streaming = "false", streaming_lamps = "1", reason = "event" })
		assert.equal("1 of 6 lamps syncing with the TV", env.Properties["Status"])
		env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, streaming_lamps = "0", reason = "event" })
		assert.equal(ZONE_IDENTITY, env.Properties["Status"])
	end)

	it("takes the counts as whole numbers from 0; anything else leaves them as they were", function()
		local env = lit(ZONE)
		env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, streaming = "false", lamps = "6", streaming_lamps = "2",
			reason = "event" })
		for _, bad in ipairs({ "nan", "inf", "-1", "two" }) do
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, lamps = bad, streaming_lamps = bad, reason = "event" })
			assert.equal("2 of 6 lamps syncing with the TV", env.Properties["Status"], bad)
		end
		env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, streaming_lamps = "6", reason = "event" })
		assert.equal(ZONE_IDENTITY, env.Properties["Status"], "all six while the bridge says it does not stream")
	end)
end)
