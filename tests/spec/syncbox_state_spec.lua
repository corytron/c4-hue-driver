-- syncbox/state.lua (#534, docs/hdmi-sync-stage2-design.md §3.5, contracts
-- C2): the model of one GET /api/v1, its changes, and the row texts. The
-- states below are written by hand here from the field names of
-- docs/syncbox-api-research.md §2 (never copied from Signify's or a
-- library's examples), so this spec needs no fixture file. Placeholders
-- only: box 0A1B2C3D4E5F at 10.0.2.150, bridge 001788fffe123abc at
-- 10.0.2.143.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local state = require("syncbox.state")

local DASH = "\226\128\148"
local ARROW = "\226\134\146"
local AREA = "5b0e1c2d-0000-4000-8000-0000000000a1"
local AREA2 = "5b0e1c2d-0000-4000-8000-0000000000a2"

-- An 8K box wired in line, syncing video on HDMI 1 to the Living Room TV area.
local function hsb2()
	return {
		device = {
			name = "Living Room Box", deviceType = "HSB2", uniqueId = "0A1B2C3D4E5F", ipAddress = "10.0.2.150",
			apiLevel = 14, firmwareVersion = "2.5.4", buildNumber = 2054000, overheating = false, undervolt = false,
		},
		execution = {
			mode = "video", syncActive = true, hdmiActive = true, hdmiSource = "input1", hueTarget = AREA,
			brightness = 100, lastSyncMode = "video",
			video = { intensity = "high", backgroundLighting = true },
			game = { intensity = "intense", backgroundLighting = false },
			music = { intensity = "moderate", palette = "neutral" },
		},
		hdmi = {
			input1 = { name = "Apple TV", type = "appletv", status = "linked", lastSyncMode = "video" },
			input2 = { name = "PlayStation", type = "playstation", status = "plugged", lastSyncMode = "game" },
			input3 = { name = "", type = "generic", status = "unplugged" },
			input4 = { name = "", type = "generic", status = "unplugged" },
			output = { name = "Receiver", type = "avreceiver", status = "linked" },
		},
		behavior = {
			inactivePowersave = 20, cecPowersave = 1, usbPowersave = 0, hpdInputSwitch = 0, arcBypassMode = 0,
			soloMode = 0,
			input1 = { cecInputSwitch = 1, linkAutoSync = 1, hpdInputPortSwitch = 1 },
			input2 = { cecInputSwitch = 1, linkAutoSync = 1, hpdInputPortSwitch = 0 },
			input3 = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 },
			input4 = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 },
		},
		hue = {
			bridgeUniqueId = "001788FFFE123ABC", bridgeIpAddress = "10.0.2.143", connectionState = "streaming",
			groupId = AREA, operatingMode = "bridge",
			groups = {
				[AREA] = { name = "Living Room TV", numLights = 4, active = true },
				[AREA2] = { name = "Desk", numLights = 2, active = false },
			},
		},
	}
end

-- The original box at API level 7: no soloMode, no operatingMode, no groupId.
local function hsb1()
	local raw = hsb2()
	raw.device.deviceType, raw.device.apiLevel, raw.device.firmwareVersion = "HSB1", 7, "1.8.3"
	raw.device.undervolt = nil
	raw.behavior.soloMode = nil
	raw.hue.operatingMode, raw.hue.groupId = nil, nil
	return raw
end

-- The 2026 4K box: one input, no box-wide hot-plug switch.
local function hsb3()
	local raw = hsb2()
	raw.device.deviceType, raw.device.firmwareVersion = "HSB3", "3.5.2"
	raw.hdmi.input2, raw.hdmi.input3, raw.hdmi.input4 = nil, nil, nil
	raw.behavior.input2, raw.behavior.input3, raw.behavior.input4 = nil, nil, nil
	raw.behavior.usbPowersave, raw.behavior.hpdInputSwitch = nil, nil
	return raw
end

local function hsb3_standalone()
	local raw = hsb3()
	raw.execution.hueTarget = nil
	raw.hue = { connectionState = "uninitialized", operatingMode = "standalone", groups = {} }
	return raw
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end

describe("syncbox/state.lua (#534)", function()
	describe("from_api", function()
		it("reads an 8K box in line, syncing video", function()
			local m, changes = state.from_api(hsb2(), nil)
			assert.equal("0A1B2C3D4E5F", m.id)
			assert.equal("Living Room Box", m.name)
			assert.equal("HSB2", m.model)
			assert.equal("HSB2", m.device_type)
			assert.equal("2.5.4", m.firmware)
			assert.equal(14, m.api_level)
			assert.equal(2054000, m.build)
			assert.is_false(m.overheating)
			assert.equal("on", m.power)
			assert.equal("video", m.mode)
			assert.is_nil(m.mode_raw)
			assert.is_true(m.syncing)
			assert.equal(1, m.input)
			assert.equal("high", m.intensity)
			assert.equal(100, m.brightness)
			assert.equal(AREA, m.area)
			assert.equal("Living Room TV", m.area_name)
			assert.same({ id = "001788fffe123abc", state = "streaming" }, m.bridge)
			assert.is_false(m.standalone)
			assert.equal("in_line", m.wiring)
			assert.same({
				{ n = 1, name = "Apple TV", type = "appletv", status = "linked" },
				{ n = 2, name = "PlayStation", type = "playstation", status = "plugged" },
				{ n = 3, type = "generic", status = "unplugged" },
				{ n = 4, type = "generic", status = "unplugged" },
			}, m.inputs)
			assert.same({
				{ id = AREA2, name = "Desk", lights = 2, active = false },
				{ id = AREA, name = "Living Room TV", lights = 4, active = true },
			}, m.areas)
			assert.same({ n = 1, cec_input_switch = true, link_auto_sync = true, hpd_input_port_switch = true },
				m.behavior.inputs[1])
			assert.equal(20, m.behavior.inactive_powersave)
			assert.is_true(m.behavior.cec_powersave)
			assert.is_false(m.behavior.arc_bypass)
			assert.is_false(m.behavior.solo)
			-- The first read: every field the model has, in the documented order.
			local expected = {}
			for _, name in ipairs(state.FIELDS) do
				if m[name] ~= nil then expected[#expected + 1] = name end
			end
			assert.same(expected, changes)
		end)

		it("names the wiring from soloMode, then arcBypassMode, else in line (O17)", function()
			local raw = hsb2()
			raw.behavior.arcBypassMode = 1
			assert.equal("behind_receiver", state.from_api(raw).wiring)
			raw.behavior.soloMode = 1
			assert.equal("second_output", state.from_api(raw).wiring)
			raw.behavior.arcBypassMode = 0
			assert.equal("second_output", state.from_api(raw).wiring)
			raw.behavior = nil
			assert.equal("in_line", state.from_api(raw).wiring)
		end)

		it("leaves out what an older box lacks (HSB1 at API level 7)", function()
			local m = state.from_api(hsb1())
			assert.equal("HSB1", m.model)
			assert.is_nil(m.standalone)
			assert.is_nil(m.behavior.solo)
			assert.is_nil(m.undervolt)
			assert.equal("in_line", m.wiring)
			assert.equal(AREA, m.area) -- from execution.hueTarget
		end)

		it("reads the one-input 4K box (HSB3)", function()
			local m = state.from_api(hsb3())
			assert.equal("HSB3", m.model)
			assert.equal(1, #m.inputs)
			assert.equal(1, #m.behavior.inputs)
			assert.is_nil(m.behavior.hpd_input_switch)
		end)

		it("reads a standalone HSB3 and keeps going", function()
			local m = state.from_api(hsb3_standalone())
			assert.is_true(m.standalone)
			assert.is_nil(m.area)
			assert.same({}, m.areas)
			assert.same({ state = "uninitialized" }, m.bridge)
		end)

		it("takes the area from hue.groupId when execution has no hueTarget", function()
			local raw = hsb2()
			raw.execution.hueTarget = nil
			raw.hue.groupId = AREA2
			local m = state.from_api(raw)
			assert.equal(AREA2, m.area)
			assert.equal("Desk", m.area_name)
		end)

		it("knows an area id that is not in hue.groups only by its id", function()
			local raw = hsb2()
			raw.execution.hueTarget = "5b0e1c2d-0000-4000-8000-0000000000ff"
			local m = state.from_api(raw)
			assert.equal("5b0e1c2d-0000-4000-8000-0000000000ff", m.area)
			assert.is_nil(m.area_name)
		end)

		it("reads power save and passthrough, and the last sync mode's intensity", function()
			local raw = hsb2()
			raw.execution.mode, raw.execution.syncActive, raw.execution.hdmiActive = "powersave", false, false
			raw.execution.lastSyncMode = "game"
			local m = state.from_api(raw)
			assert.equal("powersave", m.power)
			assert.equal("powersave", m.mode)
			assert.is_false(m.syncing)
			assert.equal("game", m.last_sync_mode)
			assert.equal("intense", m.intensity)
			raw.execution.mode, raw.execution.hdmiActive = "passthrough", true
			m = state.from_api(raw)
			assert.equal("on", m.power)
			assert.equal("passthrough", m.mode)
		end)

		it("reads the camera as HSC001 whatever the library calls it, with no inputs", function()
			for _, kind in ipairs({ "HSC001", "HSC1", "hsc2" }) do
				local raw = hsb2()
				raw.device.deviceType = kind
				raw.hdmi = nil
				raw.execution.hdmiActive, raw.execution.hdmiSource = nil, nil
				local m = state.from_api(raw)
				assert.equal("HSC001", m.model)
				assert.is_nil(m.inputs)
				assert.is_nil(m.power)
				assert.is_nil(m.input)
			end
		end)

		it("reads values it does not know as unknown, keeping the box's text aside (B15)", function()
			local raw = hsb2()
			raw.device.deviceType = "HSB9"
			raw.execution.mode = "ambient"
			raw.execution.lastSyncMode = "ambient"
			raw.execution.ambient = { intensity = "high" }
			raw.hdmi.input1.type = "hologram"
			raw.hdmi.input1.status = "dreaming"
			raw.hue.connectionState = "migrating"
			local m = state.from_api(raw)
			assert.equal("unknown", m.model)
			assert.equal("HSB9", m.device_type)
			assert.equal("unknown", m.mode)
			assert.equal("ambient", m.mode_raw)
			assert.is_nil(m.last_sync_mode)
			assert.is_nil(m.intensity)
			assert.equal("unknown", m.inputs[1].type)
			assert.equal("unknown", m.inputs[1].status)
			assert.same({ id = "001788fffe123abc", state = "unknown", state_raw = "migrating" }, m.bridge)
			raw.execution.mode = "video"
			raw.execution.video.intensity = "blinding"
			assert.equal("unknown", state.from_api(raw).intensity)
		end)

		it("checks every number and text the box sends, and never raises (#486, #487, #489)", function()
			local raw = hsb2()
			local long = string.rep("x", 300)
			raw.device.name = "Living\nRoom\0 Box"
			raw.device.uniqueId = "0A1B2C3D4E5"     -- 11 digits
			raw.device.apiLevel = 0 / 0
			raw.device.firmwareVersion = long
			raw.device.buildNumber = math.huge
			raw.device.overheating = 2
			raw.device.undervolt = 0.5
			raw.execution.brightness = 250
			raw.execution.hdmiSource = "input9"
			raw.execution.hueTarget = "../../registrations"
			raw.hue.groupId = "groups/../1"
			raw.execution.syncActive = "yes"
			raw.hdmi.input1.name = long
			raw.hdmi.input2 = "not an object"
			raw.behavior.soloMode = "1x"
			raw.hue.bridgeUniqueId = "001788fffe123abc; rm"
			raw.hue.groups[long] = { name = "Too long an id" }
			raw.hue.groups["a/b"] = { name = "A slash" }
			raw.hue.groups[AREA2] = "not an object"
			local m = state.from_api(raw)
			assert.equal("LivingRoom Box", m.name)
			assert.is_nil(m.id)
			assert.is_nil(m.api_level)
			assert.is_true(#m.firmware <= state.SHORT_MAX)
			assert.is_nil(m.build)
			assert.is_nil(m.overheating)
			assert.is_nil(m.undervolt)
			assert.is_nil(m.brightness)
			assert.is_nil(m.input)
			assert.is_nil(m.area)
			assert.is_nil(m.syncing)
			assert.is_true(#m.inputs[1].name <= state.NAME_MAX)
			assert.equal(3, #m.inputs) -- input2 dropped
			assert.equal(3, m.inputs[2].n)
			assert.is_nil(m.behavior.solo)
			assert.equal("in_line", m.wiring)
			assert.is_nil(m.bridge.id)
			assert.same({ { id = AREA, name = "Living Room TV", lights = 4, active = true } }, m.areas)
		end)

		it("rounds numbers into their range and refuses the rest", function()
			local raw = hsb2()
			for value, expected in pairs({ [99.6] = 100, [200] = 200, [0] = 0, [-1] = false, [201] = false }) do
				raw.execution.brightness = value
				local got = state.from_api(raw).brightness
				if expected == false then
					assert.is_nil(got)
				else
					assert.equal(expected, got)
				end
			end
			raw.execution.brightness = -math.huge
			assert.is_nil(state.from_api(raw).brightness)
		end)

		it("takes the old bridge's area form groups/<n> (R1 §2.6)", function()
			local raw = hsb2()
			raw.execution.hueTarget = "groups/7"
			raw.hue.groups = { ["groups/7"] = { name = "TV area", numLights = 3, active = false } }
			local m = state.from_api(raw)
			assert.equal("groups/7", m.area)
			assert.equal("TV area", m.area_name)
		end)

		it("keeps at most 64 areas, sorted by name", function()
			local raw = hsb2()
			raw.hue.groups = {}
			for i = 1, 300 do
				raw.hue.groups[string.format("area-%03d", i)] = { name = string.format("Area %03d", i), numLights = 1 }
			end
			local m = state.from_api(raw)
			assert.equal(state.AREAS_MAX, #m.areas)
			for i = 2, #m.areas do
				assert.is_true(m.areas[i - 1].name < m.areas[i].name)
			end
		end)

		it("refuses what is not the box's state", function()
			for _, raw in ipairs({ "text", 42, true, {}, { device = {} }, { execution = {} },
				{ device = "x", execution = {} } }) do
				local m, reason = state.from_api(raw)
				assert.is_nil(m)
				assert.is_string(reason)
				assert.truthy(reason:find("not the box's state", 1, true))
			end
			assert.is_nil(state.from_api(nil))
		end)

		it("needs nothing but the device and execution objects", function()
			local m = state.from_api({ device = {}, execution = {} })
			assert.equal("unknown", m.model)
			assert.equal("in_line", m.wiring)
			assert.is_nil(m.inputs)
			assert.is_nil(m.bridge)
			assert.is_nil(m.behavior)
		end)

		it("lists the fields that changed since the last read", function()
			local first = state.from_api(hsb2())
			local again, none = state.from_api(hsb2(), first)
			assert.same({}, none)
			local raw = hsb2()
			raw.execution.brightness = 120
			local _, changes = state.from_api(raw, again)
			assert.same({ "brightness" }, changes)
			raw = hsb2()
			raw.execution.hdmiSource = "input2"
			raw.hdmi.input2.status = "linked"
			_, changes = state.from_api(raw, again)
			assert.same({ "inputs", "input" }, changes)
			raw = hsb2()
			raw.execution.hueTarget, raw.hue.groupId = nil, nil
			_, changes = state.from_api(raw, again)
			assert.same({ "area", "area_name" }, changes)
			raw = hsb2()
			raw.behavior.arcBypassMode = 1
			_, changes = state.from_api(raw, again)
			assert.same({ "behavior", "wiring" }, changes)
			raw = hsb2()
			raw.execution.mode, raw.execution.syncActive = "passthrough", false
			_, changes = state.from_api(raw, again)
			assert.same({ "mode", "syncing" }, changes)
		end)

		-- R1 §2.9: the Bluetooth light fields of hue carry a key Home Assistant
		-- hides as a secret, and the answer also lists the registrations. The
		-- secret is put together at run time (no literal for the secrets check).
		it("never copies a secret of the answer into the model or a row (R1 §2.9)", function()
			local secret = string.rep("5E", 16)
			local raw = hsb2()
			raw.hue.bleEntertainmentLights = { { id = "light-1", name = "Bar", key = secret, clientKey = secret } }
			raw.hue.bleConnectionState = "connected"
			raw.hue.clientKey, raw.hue.username, raw.hue.bleSecretKey = secret, secret, secret
			raw.hue.groups[AREA].key, raw.hue.groups[AREA].owner = secret, secret
			raw.device.key, raw.device.bluetooth = secret, { key = secret }
			raw.execution.key, raw.execution.video.key = secret, secret
			raw.hdmi.input1.key, raw.behavior.input1.key = secret, secret
			raw.registrations = { ["7"] = { appName = "c4-hue", accessToken = secret } }
			raw.ir = { codes = { [secret] = { name = secret } } }
			raw.presets = { ["1"] = { name = secret } }
			local m = state.from_api(raw)
			-- Every top-level field is one the model documents.
			local known = {}
			for _, name in ipairs(state.FIELDS) do known[name] = true end
			for k in pairs(m) do
				assert.is_true(known[k] == true, "unexpected model field " .. tostring(k))
			end
			-- Nowhere in the model, as a key or a value, nor any key named like one.
			local function walk(v, path)
				if type(v) == "string" then
					assert.is_nil(v:find(secret, 1, true), "the secret in " .. path)
				elseif type(v) == "table" then
					for k, x in pairs(v) do
						local name = tostring(k)
						assert.is_nil(name:find(secret, 1, true), "the secret as a key in " .. path)
						assert.is_nil(name:lower():find("key", 1, true), "a key field " .. path .. "." .. name)
						assert.is_nil(name:lower():find("ble", 1, true), "a Bluetooth field " .. path .. "." .. name)
						walk(x, path .. "." .. name)
					end
				end
			end
			walk(m, "model")
			for key, text in pairs(state.describe(m)) do
				assert.is_nil(text:find(secret, 1, true), "the secret in the " .. key .. " row")
			end
			-- The rest of the state reads as without it.
			assert.same(state.from_api(hsb2()), m)
		end)

		it("treats a prev that is not a table as none", function()
			local m, changes = state.from_api(hsb2(), "junk")
			assert.truthy(contains(changes, "id"))
			assert.equal(m.id, "0A1B2C3D4E5F")
		end)
	end)

	describe("describe", function()
		it("gives the rows of an 8K box syncing in line", function()
			local t = state.describe(state.from_api(hsb2()))
			assert.equal("Video, high, brightness 100 % on Living Room TV", t.sync)
			assert.equal("1 Apple TV (on), 2 PlayStation, 3 " .. DASH .. ", 4 " .. DASH, t.inputs)
			assert.equal("Hue Play HDMI Sync Box 8K (HSB2)", t.model)
			assert.equal("2.5.4 (API level 14)", t.firmware)
			assert.equal("Hue Bridge 001788fffe123abc, streaming", t.bridge_link)
			assert.equal("By the box: HDMI CEC and hot-plug; auto-sync on HDMI 1, 2", t.input_switching)
			assert.equal("In line (sources " .. ARROW .. " box " .. ARROW .. " TV or receiver)", t.wiring)
			assert.is_nil(t.refusal)
		end)

		it("names each wiring", function()
			local raw = hsb2()
			raw.behavior.arcBypassMode = 1
			assert.equal("Behind a receiver (ARC bypass on)", state.describe(state.from_api(raw)).wiring)
			raw.behavior.soloMode = 1
			assert.equal("From a receiver's second output (solo mode)", state.describe(state.from_api(raw)).wiring)
		end)

		it("names each model, else the box's own type", function()
			assert.equal("Hue Play HDMI Sync Box (HSB1)", state.describe(state.from_api(hsb1())).model)
			assert.equal("Hue Play HDMI Sync Box 4K (HSB3)", state.describe(state.from_api(hsb3())).model)
			local raw = hsb2()
			raw.device.deviceType = "HSB9"
			assert.equal("HSB9", state.describe(state.from_api(raw)).model)
		end)

		it("shows one input on the 4K box", function()
			assert.equal("1 Apple TV (on)", state.describe(state.from_api(hsb3())).inputs)
		end)

		it("says power save and passthrough without the area or an input marked on", function()
			local raw = hsb2()
			raw.execution.mode, raw.execution.syncActive, raw.execution.hdmiActive = "powersave", false, false
			local t = state.describe(state.from_api(raw))
			assert.equal("Power save", t.sync)
			assert.equal("1 Apple TV, 2 PlayStation, 3 " .. DASH .. ", 4 " .. DASH, t.inputs)
			raw.execution.mode, raw.execution.hdmiActive = "passthrough", true
			raw.execution.hdmiSource = "input2"
			t = state.describe(state.from_api(raw))
			assert.equal("Off (passthrough)", t.sync)
			assert.equal("1 Apple TV, 2 PlayStation (on), 3 " .. DASH .. ", 4 " .. DASH, t.inputs)
		end)

		it("writes music and game, and leaves out what is not known", function()
			local raw = hsb2()
			raw.execution.mode = "music"
			assert.equal("Music, moderate, brightness 100 % on Living Room TV", state.describe(state.from_api(raw)).sync)
			raw.execution.mode, raw.execution.brightness, raw.execution.hueTarget, raw.hue.groupId = "game", nil, nil, nil
			assert.equal("Game, intense", state.describe(state.from_api(raw)).sync)
			raw.execution.mode = "ambient"
			assert.equal("Unknown mode (ambient)", state.describe(state.from_api(raw)).sync)
			raw.execution.mode = nil
			assert.equal(DASH, state.describe(state.from_api(raw)).sync)
		end)

		it("names the bridge link's state", function()
			local raw = hsb2()
			local expect = {
				connected = "Hue Bridge 001788fffe123abc, connected",
				busy = "Hue Bridge 001788fffe123abc, busy",
				invalidgroup = "Hue Bridge 001788fffe123abc, invalid area",
				uninitialized = "Hue Bridge 001788fffe123abc, not linked",
				disconnected = "Hue Bridge 001788fffe123abc, disconnected",
				unauthorized = "Hue Bridge 001788fffe123abc, not authorized",
				migrating = "Hue Bridge 001788fffe123abc, unknown (migrating)",
			}
			for st, text in pairs(expect) do
				raw.hue.connectionState = st
				assert.equal(text, state.describe(state.from_api(raw)).bridge_link)
			end
			raw.hue = { connectionState = "uninitialized" }
			assert.equal("Not linked", state.describe(state.from_api(raw)).bridge_link)
			raw.hue = nil
			assert.equal("Not linked", state.describe(state.from_api(raw)).bridge_link)
		end)

		it("refuses a standalone box (O2) and the camera", function()
			local t = state.describe(state.from_api(hsb3_standalone()))
			assert.equal("Not supported: this box runs without a Hue Bridge (standalone mode)", t.refusal)
			assert.equal("Not linked (standalone mode)", t.bridge_link)
			assert.equal("Hue Play HDMI Sync Box 4K (HSB3)", t.model)
			local raw = hsb2()
			raw.device.deviceType, raw.hdmi = "HSC001", nil
			t = state.describe(state.from_api(raw))
			assert.equal(state.REFUSAL_CAMERA, t.refusal)
			assert.equal(DASH, t.inputs)
		end)

		it("says what the box switches by itself", function()
			local raw = hsb2()
			for n = 1, 4 do
				raw.behavior["input" .. n] = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 }
			end
			local function switching() return state.describe(state.from_api(raw)).input_switching end
			assert.equal("None: the box neither switches inputs nor starts syncing by itself", switching())
			raw.behavior.hpdInputSwitch = 1
			assert.equal("By the box: hot-plug", switching())
			raw.behavior.hpdInputSwitch = 0
			raw.behavior.input3.cecInputSwitch = 1
			assert.equal("By the box: HDMI CEC", switching())
			raw.behavior.input3.cecInputSwitch = 0
			raw.behavior.input4.linkAutoSync = 1
			assert.equal("By the box: auto-sync on HDMI 4", switching())
			raw.behavior = nil
			assert.equal(DASH, switching())
		end)

		it("writes the firmware with whatever is known", function()
			local raw = hsb2()
			raw.device.apiLevel = nil
			assert.equal("2.5.4", state.describe(state.from_api(raw)).firmware)
			raw.device.firmwareVersion, raw.device.apiLevel = nil, 14
			assert.equal("API level 14", state.describe(state.from_api(raw)).firmware)
			raw.device.apiLevel = nil
			assert.equal(DASH, state.describe(state.from_api(raw)).firmware)
		end)

		it("keeps every row within the row cap", function()
			local raw = hsb2()
			for n = 1, 4 do
				raw.hdmi["input" .. n].name = string.rep("n", 200)
			end
			raw.hue.groups[AREA].name = string.rep("a", 200)
			local t = state.describe(state.from_api(raw))
			for key, text in pairs(t) do
				assert.is_true(#text <= state.ROW_MAX, key)
			end
		end)

		it("describes nothing without raising", function()
			local t = state.describe(nil)
			assert.equal(DASH, t.sync)
			assert.equal(DASH, t.inputs)
			assert.equal(DASH, t.model)
			assert.equal(DASH, t.firmware)
			assert.equal("Not linked", t.bridge_link)
			assert.equal(DASH, t.input_switching)
			assert.equal(state.WIRING_TEXTS.in_line, t.wiring)
			assert.is_nil(t.refusal)
		end)
	end)
end)
