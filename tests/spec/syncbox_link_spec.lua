-- syncbox/link.lua (2.0 beta stage 2, #534): the sync box's side of the
-- HUE_SYNCBOX binding (docs/hdmi-sync-stage2-design.md §3.8, contracts C5);
-- stage 4 (#568, docs/hdmi-sync-stage4-design.md §6): the sync state, STATE,
-- STOP_AREA and STOPPED (O12, research W10).
-- Placeholders only: bridge 001788fffe123abc, box 0A1B2C3D4E5F.
package.path = "src/hue_syncbox/?.lua;" .. package.path

local json = require("dkjson")
local log = require("common.log")

local BRIDGE = "001788fffe123abc"
local BOX = "0A1B2C3D4E5F"
local TV = "6a7b8c9d-0000-4000-8000-0000000ea001"
local OFFICE = "6a7b8c9d-0000-4000-8000-0000000ea002"
local DEVICE = 2001

-- What the Hue Bridge's decoder does: dkjson, null → nil, an error as nil and a text.
local function decode(text)
	local value, _, err = json.decode(text)
	if err then
		return nil, err
	end
	return value
end

describe("syncbox.link", function()
	local link, l, sent, lines, answer

	local function new_l(extra)
		local deps = {
			send = function(binding, command, params)
				sent[#sent + 1] = { binding = binding, command = command, params = params }
				return answer
			end,
			log = log,
			device_id = function() return DEVICE end,
			decode = decode,
		}
		for k, v in pairs(extra or {}) do
			deps[k] = v
		end
		return link.new(deps)
	end

	local function saw(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	-- A CONFIGURE's params with `areas` the JSON of `list`.
	local function configure(list, extra)
		local params = { bridge_id = BRIDGE, match = "true", areas = json.encode(list) }
		for k, v in pairs(extra or {}) do
			params[k] = v
		end
		return params
	end

	local function area(id, name, extra)
		local out = { id = id, name = name, type = "screen", status = "inactive", lamps = 5, rooms = { "Living Room" } }
		for k, v in pairs(extra or {}) do
			out[k] = v
		end
		return out
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		package.loaded["syncbox.link"] = nil
		link = require("syncbox.link")
		sent, answer = {}, nil
		l = new_l()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("module", function()
		it("has the contract's binding and message names", function()
			assert.equal(1, link.BINDING)
			assert.equal("HUE_SYNCBOX", link.CLASS)
			assert.equal("HUE_SYNCBOX_HELLO", link.HELLO)
			assert.equal("HUE_SYNCBOX_GOODBYE", link.GOODBYE)
			assert.equal("HUE_SYNCBOX_CONFIGURE", link.CONFIGURE)
			assert.equal("HUE_SYNCBOX_AREA", link.AREA)
			assert.equal("HUE_SYNCBOX_STATE", link.STATE)
			assert.equal("HUE_SYNCBOX_STOP_AREA", link.STOP_AREA)
			assert.equal("HUE_SYNCBOX_STOPPED", link.STOPPED)
			assert.equal(64, link.AREAS_MAX)
		end)

		it("needs send", function()
			assert.has_error(function() link.new({}) end)
			assert.has_error(function() link.new() end)
		end)

		it("handles the three messages from the bridge, nothing else", function()
			assert.is_true(link.handles("HUE_SYNCBOX_CONFIGURE"))
			assert.is_true(link.handles("HUE_SYNCBOX_AREA"))
			assert.is_true(link.handles("HUE_SYNCBOX_STOPPED"))
			assert.is_false(link.handles("HUE_SYNCBOX_HELLO"))
			assert.is_false(link.handles("HUE_SYNCBOX_STATE"))
			assert.is_false(link.handles("HUE_SYNCBOX_STOP_AREA"))
			assert.is_false(link.handles("HUE_BRIDGE_LINK"))
			assert.is_false(link.handles(nil))
		end)

		it("checks ids: the box's 12 hex digits upper case, a bridge's and an area's lower case", function()
			assert.equal(BOX, link.box_id(BOX:lower()))
			assert.is_nil(link.box_id("0A1B2C3D4E5"))
			assert.is_nil(link.box_id("0A1B2C3D4E5G"))
			assert.is_nil(link.box_id(12))
			assert.equal(BRIDGE, link.bridge_id(BRIDGE:upper()))
			assert.is_nil(link.bridge_id("001788fffe12-abc"))
			assert.is_nil(link.bridge_id(("a"):rep(65)))
			assert.equal(TV, link.area_id(TV:upper()))
			assert.is_nil(link.area_id("groups/3"))
			assert.is_nil(link.area_id("../light"))
			assert.is_nil(link.area_id(("a"):rep(65)))
			assert.is_nil(link.area_id(""))
		end)
	end)

	describe("hello()", function()
		it("sends HUE_SYNCBOX_HELLO on binding 1 with this device, the box, its bridge and its area, as strings", function()
			assert.is_true(l:hello(BOX:lower(), BRIDGE:upper(), TV))
			assert.same({ { binding = 1, command = "HUE_SYNCBOX_HELLO",
				params = { device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = TV } } }, sent)
		end)

		it("leaves out what the box does not know yet, and what is no id (one debug line each)", function()
			assert.is_true(l:hello(nil, "", nil))
			assert.same({ device_id = "2001" }, sent[1].params)
			assert.is_true(l:hello("nonsense", "001788fffe12/abc", "groups/3"))
			assert.same({ device_id = "2001" }, sent[2].params)
			assert.is_true(saw("the box id nonsense is left out"))
			assert.is_true(saw("the bridge id 001788fffe12/abc is left out"))
			assert.is_true(saw("the area id groups/3 is left out"))
		end)

		it("leaves out a device id that is none, and reads C4:GetDeviceID by default", function()
			l = new_l({ device_id = function() return nil end })
			l:hello(BOX, BRIDGE, TV)
			assert.is_nil(sent[1].params.device_id)
			l = new_l({ device_id = function() error("no runtime") end })
			l:hello(BOX, BRIDGE, TV)
			assert.is_nil(sent[2].params.device_id)
			local saved = _G.C4
			_G.C4 = { GetDeviceID = function() return 1999 end }
			local ok, err = pcall(function()
				l = link.new({ send = function(binding, command, params)
					sent[#sent + 1] = { binding = binding, command = command, params = params }
				end })
				l:hello(BOX, BRIDGE, TV)
			end)
			_G.C4 = saved
			assert(ok, err)
			assert.equal("1999", sent[3].params.device_id)
		end)

		it("carries the sync state as true or false, and leaves it out while unknown (stage 4)", function()
			l:hello(BOX, BRIDGE, TV, true)
			assert.same({ device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = TV, syncing = "true" },
				sent[1].params)
			l:hello(BOX, BRIDGE, TV, false)
			assert.equal("false", sent[2].params.syncing)
			l:hello(BOX, BRIDGE, TV, "true")
			assert.equal("true", sent[3].params.syncing, "the message's own text is taken too")
			for i, value in ipairs({ nil, "yes", 1, {} }) do
				l:hello(BOX, BRIDGE, TV, value)
				assert.is_nil(sent[3 + i].params.syncing, tostring(value))
			end
		end)

		it("is false when nothing went out: no bridge bound, or the send raised (with a warning)", function()
			answer = false
			assert.is_false(l:hello(BOX, BRIDGE, TV))
			assert.is_true(saw("not sent (no Hue Bridge bound)"))
			l = new_l({ send = function() error("no such device") end })
			assert.is_false(l:hello(BOX, BRIDGE, TV))
			assert.is_true(saw("HUE_SYNCBOX_HELLO failed"))
		end)
	end)

	describe("update()", function()
		it("sends the hello again only when the box, its bridge or its area changed", function()
			assert.is_true(l:update(BOX, BRIDGE, TV))
			assert.is_false(l:update(BOX, BRIDGE, TV))
			assert.is_false(l:update(BOX:lower(), BRIDGE:upper(), TV:upper()), "the same ids in another case")
			assert.is_true(l:update(BOX, BRIDGE, OFFICE))
			assert.is_true(l:update(BOX, nil, OFFICE))
			assert.is_true(l:update(nil, nil, OFFICE))
			assert.equal(4, #sent)
		end)

		it("tries again after a hello that did not go out", function()
			answer = false
			assert.is_false(l:update(BOX, BRIDGE, TV))
			answer = nil
			assert.is_true(l:update(BOX, BRIDGE, TV))
		end)

		it("sends again after reset() and after a goodbye", function()
			l:update(BOX, BRIDGE, TV)
			l:reset()
			assert.is_true(l:update(BOX, BRIDGE, TV))
			l:goodbye(BOX)
			assert.is_true(l:update(BOX, BRIDGE, TV))
		end)

		it("sends STATE, not the hello, when only the sync state changed (stage 4)", function()
			assert.is_true(l:update(BOX, BRIDGE, TV, false))
			assert.equal("HUE_SYNCBOX_HELLO", sent[1].command)
			assert.is_false(l:update(BOX, BRIDGE, TV, false))
			assert.is_true(l:update(BOX, BRIDGE, TV, true))
			assert.same({ binding = 1, command = "HUE_SYNCBOX_STATE", params = { device_id = "2001", box_id = BOX,
				bridge_id = BRIDGE, area_id = TV, syncing = "true" } }, sent[2])
			assert.is_false(l:update(BOX, BRIDGE, TV, true))
			assert.is_true(l:update(BOX, BRIDGE, OFFICE, false), "the area changed too: the hello says both")
			assert.same({ "HUE_SYNCBOX_HELLO", "false" }, { sent[3].command, sent[3].params.syncing })
			assert.equal(3, #sent)
		end)

		it("sends STATE once the sync state is known after a hello without it, and never for an unknown one", function()
			l:update(BOX, BRIDGE, TV, nil)
			assert.is_nil(sent[1].params.syncing)
			assert.is_false(l:update(BOX, BRIDGE, TV, nil))
			assert.is_false(l:update(BOX, BRIDGE, TV, "maybe"))
			assert.is_true(l:update(BOX, BRIDGE, TV, false))
			assert.same({ "HUE_SYNCBOX_STATE", "false" }, { sent[2].command, sent[2].params.syncing })
		end)

		it("sends STATE once after an AREA from the bridge, even when nothing changed", function()
			l:update(BOX, BRIDGE, TV, false)
			assert.is_truthy(l:received("HUE_SYNCBOX_AREA", { id = TV, status = "active", streamer = "this_box" }))
			assert.is_true(l:update(BOX, BRIDGE, TV, false))
			assert.same({ "HUE_SYNCBOX_STATE", "false" }, { sent[2].command, sent[2].params.syncing })
			assert.is_false(l:update(BOX, BRIDGE, TV, false), "once")
			l:received("HUE_SYNCBOX_AREA", { id = "../x", status = "active", streamer = "this_box" })
			assert.is_false(l:update(BOX, BRIDGE, TV, false), "a dropped AREA asks for nothing")
			l:received("HUE_SYNCBOX_AREA", { id = OFFICE, status = "inactive", streamer = "none" })
			assert.is_false(l:update(BOX, BRIDGE, TV, nil), "not while the sync state is unknown")
			assert.is_true(l:update(BOX, BRIDGE, TV, false), "but at the first read that knows it")
			assert.equal(3, #sent)
		end)

		it("tries STATE again after one that did not go out", function()
			l:update(BOX, BRIDGE, TV, false)
			answer = false
			assert.is_false(l:update(BOX, BRIDGE, TV, true))
			answer = nil
			assert.is_true(l:update(BOX, BRIDGE, TV, true))
			assert.equal("HUE_SYNCBOX_STATE", sent[3].command)
		end)

		it("leaves out of STATE what is no id, with one debug line", function()
			l:update("nonsense", BRIDGE, TV, false)
			l:update("nonsense", BRIDGE, TV, true)
			assert.same({ device_id = "2001", bridge_id = BRIDGE, area_id = TV, syncing = "true" }, sent[2].params)
			assert.is_true(saw("the box id nonsense is left out of HUE_SYNCBOX_STATE"))
		end)
	end)

	describe("stop_area()", function()
		it("sends HUE_SYNCBOX_STOP_AREA on binding 1 with this device, the box, its bridge and the area", function()
			assert.is_true(l:stop_area(TV:upper(), BOX:lower(), BRIDGE:upper()))
			assert.same({ { binding = 1, command = "HUE_SYNCBOX_STOP_AREA",
				params = { device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = TV } } }, sent)
			for k, v in pairs(sent[1].params) do
				assert.equal("string", type(v), k)
			end
		end)

		it("sends nothing for an area id that is none, with one debug line", function()
			assert.is_false(l:stop_area(nil, BOX, BRIDGE))
			for _, bad in ipairs({ "", "../light", "groups/3", ("a"):rep(65), 7 }) do
				assert.is_false(l:stop_area(bad, BOX, BRIDGE))
			end
			assert.same({}, sent)
			assert.is_true(saw("HUE_SYNCBOX_STOP_AREA not sent: the area id ../light is not one"))
		end)

		it("leaves out the box or the bridge it does not know", function()
			assert.is_true(l:stop_area(TV, nil, "not/an/id"))
			assert.same({ device_id = "2001", area_id = TV }, sent[1].params)
		end)

		it("is false when nothing went out, and then reads no answer for that area", function()
			answer = false
			assert.is_false(l:stop_area(TV, BOX, BRIDGE))
			answer = nil
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true", reason = "stopped" }))
			assert.is_true(saw("did not ask to stop that area"))
		end)
	end)

	describe("goodbye()", function()
		it("sends HUE_SYNCBOX_GOODBYE on binding 1 with this device and the box", function()
			assert.is_true(l:goodbye(BOX:lower()))
			assert.same({ { binding = 1, command = "HUE_SYNCBOX_GOODBYE", params = { device_id = "2001", box_id = BOX } } },
				sent)
			assert.is_true(l:goodbye(nil))
			assert.same({ device_id = "2001" }, sent[2].params)
		end)
	end)

	describe("received() CONFIGURE", function()
		it("reads the bridge's id, match and areas", function()
			local got = l:received("HUE_SYNCBOX_CONFIGURE", configure({
				area(TV, "Living Room TV", { status = "active", rooms = { "Living Room", "Kitchen" } }),
				area(OFFICE, "Office", { type = "music", lamps = 3, rooms = {} }),
			}))
			assert.same({ kind = "configure", bridge_id = BRIDGE, match = true, areas = {
				{ id = TV, name = "Living Room TV", type = "screen", status = "active", lamps = 5,
					rooms = { "Living Room", "Kitchen" } },
				{ id = OFFICE, name = "Office", type = "music", status = "inactive", lamps = 3, rooms = {} },
			} }, got)
		end)

		it("reads match false, with or without a bridge id, and no areas as none", function()
			assert.same({ kind = "configure", bridge_id = nil, match = false, areas = {} },
				l:received("HUE_SYNCBOX_CONFIGURE", { match = "false" }))
			assert.same({ kind = "configure", bridge_id = BRIDGE, match = false, areas = {} },
				l:received("HUE_SYNCBOX_CONFIGURE", { match = "false", bridge_id = BRIDGE:upper(), areas = "[]" }))
		end)

		it("reads a list C4:JsonEncode wrote as an object with keys 1, 2, ... in their order", function()
			local text = '{"2":' .. json.encode(area(OFFICE, "Office")) .. ',"1":' .. json.encode(area(TV, "Living Room TV"))
				.. '}'
			local got = l:received("HUE_SYNCBOX_CONFIGURE", { bridge_id = BRIDGE, match = "true", areas = text })
			assert.same({ TV, OFFICE }, { got.areas[1].id, got.areas[2].id })
			text = json.encode(area(TV, "Living Room TV", { rooms = { ["1"] = "Den", ["2"] = "Hall" } }))
			got = l:received("HUE_SYNCBOX_CONFIGURE", { bridge_id = BRIDGE, match = "true", areas = "[" .. text .. "]" })
			assert.same({ "Den", "Hall" }, got.areas[1].rooms)
		end)

		it("drops a malformed message with one debug line", function()
			local cases = {
				{ match = "yes", bridge_id = BRIDGE, areas = "[]" },
				{ bridge_id = BRIDGE, areas = "[]" },
				{ match = "true", areas = "[]" },
				{ match = "true", bridge_id = "001788fffe12/abc", areas = "[]" },
				{ match = "false", bridge_id = { BRIDGE }, areas = "[]" },
				{ match = "true", bridge_id = BRIDGE, areas = { area(TV, "TV") } },
				{ match = "true", bridge_id = BRIDGE, areas = "[" .. ("1,"):rep(40000) .. "1]" },
				{ match = "true", bridge_id = BRIDGE, areas = "[{" },
				{ match = "true", bridge_id = BRIDGE, areas = "null" },
				{ match = "true", bridge_id = BRIDGE, areas = '"text"' },
				{ match = "true", bridge_id = BRIDGE, areas = '{"name":"not a list"}' },
				{ match = "true", bridge_id = BRIDGE, areas = '{"0":{}}' },
			}
			for i, params in ipairs(cases) do
				local before = #lines
				assert.is_nil(l:received("HUE_SYNCBOX_CONFIGURE", params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("HUE_SYNCBOX_CONFIGURE dropped", 1, true), lines[#lines])
			end
			assert.is_nil(l:received("HUE_SYNCBOX_CONFIGURE", nil))
			assert.is_true(saw("no parameters"))
		end)

		it("survives a decoder that raises", function()
			l = new_l({ decode = function() error("bad json") end })
			assert.is_nil(l:received("HUE_SYNCBOX_CONFIGURE", configure({})))
			assert.is_true(saw("its areas are not JSON"))
		end)

		it("leaves out an area without an id or a name, or one seen before, with one debug line", function()
			local got = l:received("HUE_SYNCBOX_CONFIGURE", configure({
				area(TV, "Living Room TV"),
				area("../light", "Bad"),
				area(nil, "No id"),
				area(OFFICE, nil),
				area(OFFICE, ""),
				area(OFFICE, 42),
				area(TV, "Again"),
				"junk",
				area(OFFICE, "Office"),
			}))
			assert.same({ TV, OFFICE }, { got.areas[1].id, got.areas[2].id })
			assert.equal(2, #got.areas)
			assert.is_true(saw("7 area(s) without an id or a name left out"))
		end)

		it("checks every field: an unknown type is other, status inactive, lamps a whole number or 0", function()
			local got = l:received("HUE_SYNCBOX_CONFIGURE", configure({
				area(TV, "A", { type = "hologram", status = "streaming", lamps = "7" }),
				area("ea-b", "B", { type = { "screen" }, status = { "active" }, lamps = 1e999 }),
				area("ea-c", "C", { lamps = -1 }),
				area("ea-d", "D", { lamps = 256 }),
				area("ea-e", "E", { lamps = 2.6 }),
			}))
			assert.same({ "other", "inactive", 7 }, { got.areas[1].type, got.areas[1].status, got.areas[1].lamps })
			assert.same({ "other", "inactive", 0 }, { got.areas[2].type, got.areas[2].status, got.areas[2].lamps })
			assert.same({ 0, 0, 3 }, { got.areas[3].lamps, got.areas[4].lamps, got.areas[5].lamps })
		end)

		it("takes names and rooms through peer_text: no control characters, at most 256 bytes", function()
			local long = ("x"):rep(300)
			local got = l:received("HUE_SYNCBOX_CONFIGURE", configure({
				area(TV, "Living\nRoom\27 TV", { rooms = { "Den\r", 7, "", long, { "table" } } }),
				area(OFFICE, long),
			}))
			assert.equal("LivingRoom TV", got.areas[1].name)
			assert.same({ "Den", ("x"):rep(253) .. "..." }, got.areas[1].rooms)
			assert.equal(256, #got.areas[2].name)
		end)

		it("keeps at most 64 areas and 32 rooms an area", function()
			local list, many = {}, {}
			for i = 1, 32 + 5 do
				many[i] = string.format("Room %02d", i)
			end
			for i = 1, 70 do
				list[i] = area(string.format("ea-%02d", i), string.format("Area %02d", i), { rooms = many })
			end
			local got = l:received("HUE_SYNCBOX_CONFIGURE", configure(list))
			assert.equal(64, #got.areas)
			assert.equal("ea-64", got.areas[64].id)
			assert.equal(32, #got.areas[1].rooms)
			assert.equal("Room 32", got.areas[1].rooms[32])
		end)

		it("decodes with common.https by default (C4:JsonDecode under pcall)", function()
			local saved = _G.C4
			_G.C4 = { JsonDecode = function(_, text) return decode(text) end }
			local ok, got = pcall(function()
				return new_l({ decode = false }):received("HUE_SYNCBOX_CONFIGURE", configure({ area(TV, "TV") }))
			end)
			_G.C4 = saved
			assert(ok, got)
			assert.equal(TV, got.areas[1].id)
		end)
	end)

	describe("received() AREA", function()
		it("reads the area, its status and who streams", function()
			for _, status in ipairs({ "active", "inactive" }) do
				for _, streamer in ipairs({ "this_box", "other", "none" }) do
					assert.same({ kind = "area", id = TV, status = status, streamer = streamer },
						l:received("HUE_SYNCBOX_AREA", { id = TV:upper(), status = status, streamer = streamer }))
				end
			end
		end)

		it("drops a malformed message with one debug line", function()
			local cases = {
				{ status = "active", streamer = "other" },
				{ id = "../light", status = "active", streamer = "other" },
				{ id = TV, status = "on", streamer = "other" },
				{ id = TV, streamer = "other" },
				{ id = TV, status = "active", streamer = "me" },
				{ id = TV, status = "active" },
			}
			for i, params in ipairs(cases) do
				local before = #lines
				assert.is_nil(l:received("HUE_SYNCBOX_AREA", params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("HUE_SYNCBOX_AREA dropped", 1, true), lines[#lines])
			end
		end)
	end)

	describe("received() STOPPED", function()
		it("reads the answer to a stop this box asked for, once", function()
			l:stop_area(TV, BOX, BRIDGE)
			assert.same({ kind = "stopped", area_id = TV, ok = true, reason = "stopped" },
				l:received("HUE_SYNCBOX_STOPPED", { area_id = TV:upper(), ok = "true", reason = "stopped" }))
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true", reason = "stopped" }),
				"a second answer for the same stop")
			assert.is_true(saw("HUE_SYNCBOX_STOPPED dropped: this box did not ask to stop that area"))
		end)

		it("reads every refusal, with another box's name and the bridge's detail", function()
			for _, reason in ipairs({ "another_box", "no_area", "not_linked", "failed", "busy" }) do
				l:stop_area(TV, BOX, BRIDGE)
				assert.same({ kind = "stopped", area_id = TV, ok = false, reason = reason },
					l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false", reason = reason }), reason)
			end
			l:stop_area(TV, BOX, BRIDGE)
			assert.same({ kind = "stopped", area_id = TV, ok = false, reason = "another_box", by = "DenSync Box" },
				l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false", reason = "another_box",
					by = "Den\nSync Box" }))
			l:stop_area(TV, BOX, BRIDGE)
			assert.same({ kind = "stopped", area_id = TV, ok = false, reason = "failed", detail = "HTTP 503" },
				l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false", reason = "failed", detail = "HTTP 503",
					by = "" }))
		end)

		it("reads an unknown refusal as failed, and ok as stopped whatever its reason", function()
			l:stop_area(TV, BOX, BRIDGE)
			assert.equal("failed", l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false", reason = "odd" }).reason)
			l:stop_area(TV, BOX, BRIDGE)
			assert.equal("failed", l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false" }).reason)
			l:stop_area(TV, BOX, BRIDGE)
			assert.equal("failed", l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false",
				reason = "stopped" }).reason, "a refusal is never stopped")
			l:stop_area(TV, BOX, BRIDGE)
			assert.equal("stopped", l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true",
				reason = "no_area" }).reason)
		end)

		it("takes by and detail through peer_text, at most 120 bytes", function()
			l:stop_area(TV, BOX, BRIDGE)
			local long = ("x"):rep(300)
			local got = l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "false", reason = "failed",
				detail = long .. "\27", by = { "table" } })
			assert.equal(("x"):rep(117) .. "...", got.detail)
			assert.is_nil(got.by)
		end)

		it("drops a malformed answer with one debug line, and keeps the stop asked for", function()
			l:stop_area(TV, BOX, BRIDGE)
			local cases = {
				{ ok = "true", reason = "stopped" },
				{ area_id = "../light", ok = "true", reason = "stopped" },
				{ area_id = TV, ok = "yes", reason = "stopped" },
				{ area_id = TV, reason = "stopped" },
				{ area_id = OFFICE, ok = "true", reason = "stopped" },
			}
			for i, params in ipairs(cases) do
				local before = #lines
				assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("HUE_SYNCBOX_STOPPED dropped", 1, true), lines[#lines])
			end
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", nil))
			assert.is_truthy(l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true" }), "still asked for")
		end)

		it("forgets the stops asked for at reset() and a goodbye, and keeps at most four, the newest", function()
			l:stop_area(TV, BOX, BRIDGE)
			l:reset()
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true" }))
			l:stop_area(TV, BOX, BRIDGE)
			l:goodbye(BOX)
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", { area_id = TV, ok = "true" }))
			local ids = {}
			for i = 1, link.ASKED_MAX + 1 do
				ids[i] = string.format("ea-%02d", i)
				l:stop_area(ids[i], BOX, BRIDGE)
			end
			l:stop_area(ids[2], BOX, BRIDGE)
			assert.is_nil(l:received("HUE_SYNCBOX_STOPPED", { area_id = ids[1], ok = "true" }), "the oldest went")
			for i = 2, link.ASKED_MAX + 1 do
				assert.is_truthy(l:received("HUE_SYNCBOX_STOPPED", { area_id = ids[i], ok = "true" }), ids[i])
			end
		end)
	end)

	describe("received() of anything else", function()
		it("is nil, without a log line", function()
			assert.is_nil(l:received("HUE_SYNCBOX_HELLO", { box_id = BOX }))
			assert.is_nil(l:received("HUE_SYNCBOX_STOP_AREA", { area_id = TV }))
			assert.is_nil(l:received("HUE_BRIDGE_LINK", { state = "online" }))
			assert.is_nil(l:received(nil, nil))
			assert.same({}, lines)
		end)
	end)

	-- The two sides together: what bridge/syncboxes.lua sends reads back whole here.
	describe("with the bridge's side", function()
		it("reads the CONFIGURE and the AREA bridge/syncboxes.lua builds", function()
			local syncboxes = require("bridge.syncboxes")
			local to_box = {}
			local s = syncboxes.new({
				send = function(_, command, params) to_box[#to_box + 1] = { command = command, params = params } end,
				bridge_id = function() return BRIDGE end,
				areas = function()
					return {
						{ id = TV, name = 'Tom\'s "Cinema" \\ Ü→', kind = "screen", status = "active",
							lamps = { "l1", "l2" } },
						{ id = OFFICE, name = "Office", kind = "music", status = "inactive", lamps = { "l3" } },
					}
				end,
				rooms_for = function(lamps) return #lamps == 2 and { "Living Room", "Den" } or {} end,
				log = log,
			})
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			l:hello(BOX, BRIDGE, TV)
			assert.is_true(s:hello(sent[1].params))
			assert.same({ kind = "configure", bridge_id = BRIDGE, match = true, areas = {
				{ id = TV, name = 'Tom\'s "Cinema" \\ Ü→', type = "screen", status = "active", lamps = 2,
					rooms = { "Den", "Living Room" } },
				{ id = OFFICE, name = "Office", type = "music", status = "inactive", lamps = 1, rooms = {} },
			} }, l:received(to_box[1].command, to_box[1].params))
			s:on_stream({ id = TV }, true)
			assert.same({ kind = "area", id = TV, status = "active", streamer = "this_box" },
				l:received(to_box[2].command, to_box[2].params))
			l:goodbye(BOX)
			assert.is_true(s:goodbye(sent[2].params))
			assert.equal(0, s:count())
		end)

		it("takes the sync state and a take-over to the bridge, and reads its STOPPED back (stage 4)", function()
			local syncboxes = require("bridge.syncboxes")
			local to_box, puts = {}, {}
			local s = syncboxes.new({
				send = function(_, command, params) to_box[#to_box + 1] = { command = command, params = params } end,
				bridge_id = function() return BRIDGE end,
				areas = function()
					return { { id = TV, name = "Living Room TV", kind = "screen", status = "active", lamps = {} } }
				end,
				display_name = function() return "Living Room Sync Box" end,
				http = function(req, cb)
					puts[#puts + 1] = req
					cb({ ok = true, code = 200 })
				end,
				log = log,
			})
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			l:update(BOX, BRIDGE, TV, false)
			assert.is_true(s:hello(sent[1].params))
			assert.is_false(s:boxes()[1].syncing)
			l:update(BOX, BRIDGE, TV, true)
			assert.is_true(s:state(sent[2].params))
			assert.is_true(s:boxes()[1].syncing)
			assert.equal("Living Room Sync Box", s:label_for(TV))
			l:update(BOX, BRIDGE, TV, false)
			assert.is_true(s:state(sent[3].params))
			assert.is_nil(s:label_for(TV), "a box that says it does not sync names no stream")
			assert.is_true(l:stop_area(TV, BOX, BRIDGE))
			assert.is_true(s:stop_area(sent[4].params))
			assert.same({ { method = "PUT", path = "/clip/v2/resource/entertainment_configuration/" .. TV,
				body = { action = "stop" } } }, puts)
			local reply = to_box[#to_box]
			assert.equal("HUE_SYNCBOX_STOPPED", reply.command)
			assert.same({ kind = "stopped", area_id = TV, ok = true, reason = "stopped" },
				l:received(reply.command, reply.params))
		end)
	end)
end)
