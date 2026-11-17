-- syncbox/link.lua (2.0 beta stage 2, #534): the sync box's side of the
-- HUE_SYNCBOX binding (docs/hdmi-sync-stage2-design.md §3.8, contracts C5).
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
			assert.equal(64, link.AREAS_MAX)
		end)

		it("needs send", function()
			assert.has_error(function() link.new({}) end)
			assert.has_error(function() link.new() end)
		end)

		it("handles the two messages from the bridge, nothing else", function()
			assert.is_true(link.handles("HUE_SYNCBOX_CONFIGURE"))
			assert.is_true(link.handles("HUE_SYNCBOX_AREA"))
			assert.is_false(link.handles("HUE_SYNCBOX_HELLO"))
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

	describe("received() of anything else", function()
		it("is nil, without a log line", function()
			assert.is_nil(l:received("HUE_SYNCBOX_HELLO", { box_id = BOX }))
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
	end)
end)
