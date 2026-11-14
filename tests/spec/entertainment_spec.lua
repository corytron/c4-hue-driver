local json = require("dkjson")
local log = require("common.log")
local hue_model = require("bridge.hue_model")
local rows = require("bridge.rows")
local E = require("fixtures.hue_entertainment")

-- Decode a fixture the way http.request does (dkjson, null → nil).
local function decode(text)
	local value, _, err = json.decode(text)
	assert(value, err)
	return value
end

local function items(text)
	return decode(text).data
end

-- The fixture's entertainment item of the service `rid`.
local function by_rid_service(rid)
	for _, item in ipairs(items(E.entertainment)) do
		if item.id == rid then
			return item
		end
	end
end

local CONFIG_PATH = "/clip/v2/resource/entertainment_configuration"
local SERVICE_PATH = "/clip/v2/resource/entertainment"

-- 2.0 beta stage 1 (#514): docs/hdmi-sync-stage1-design.md §4.2 to §4.4, the
-- bridge's entertainment areas and the restore after a sync.
describe("bridge.entertainment", function()
	local entertainment, e, lights, answers, requests, timers, streams, changes, puts, restored, after, lines

	-- A one-shot timer fired by hand (fire() runs every timer still armed once).
	local function set_timer(ms, fn)
		local t = { ms = ms, fn = fn, active = true }
		function t.Cancel()
			t.active = false
		end
		timers[#timers + 1] = t
		return t
	end

	local function armed()
		local out = {}
		for _, t in ipairs(timers) do
			if t.active then
				out[#out + 1] = t.ms
			end
		end
		return out
	end

	local function fire()
		local due = {}
		for _, t in ipairs(timers) do
			if t.active then
				due[#due + 1] = t
			end
		end
		for _, t in ipairs(due) do
			t.active = false
			t.fn()
		end
	end

	-- The driver's request: a fixture text answers 200 with its JSON, a table is
	-- the result itself, nothing is a timeout.
	local function http(req, cb)
		requests[#requests + 1] = req.method .. " " .. req.path
		local answer = answers[req.path]
		if type(answer) == "string" then
			cb({ ok = true, code = 200, json = decode(answer) })
		elseif type(answer) == "table" then
			cb(answer)
		else
			cb({ ok = false, err = "timeout" })
		end
	end

	-- The GET /entertainment_configuration answer with the areas `statuses`
	-- names ({ tv = "active" }) in that status.
	local function configuration(statuses)
		local body = decode(E.configuration)
		for _, item in ipairs(body.data) do
			for key, id in pairs(E.area_rids) do
				if item.id == id and statuses[key] then
					item.status = statuses[key]
					item.active_streamer = statuses[key] == "active" and { rid = E.streamer, rtype = "auth_v1" } or nil
				end
			end
		end
		return { ok = true, code = 200, json = body }
	end

	local function new_lights()
		local models = {}
		for _, item in ipairs(items(E.light)) do
			local model = hue_model.light(item)
			models[model.rid] = model
		end
		return { models = models, devices = hue_model.devices(items(E.device)) }
	end

	local function new_e(extra)
		local ctx = {
			http = http,
			log = log,
			set_timer = set_timer,
			lights = function() return lights end,
			on_stream = function(area, started)
				streams[#streams + 1] = { name = area.name, started = started, area = area }
			end,
			on_lamps_changed = function(rids) changes[#changes + 1] = rids end,
			after_sync = function() return after end,
			put_back = function(rid, body, done)
				puts[#puts + 1] = { rid = rid, body = body, done = done }
				return true
			end,
			on_restored = function(area, count) restored[#restored + 1] = { name = area.name, count = count } end,
		}
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return entertainment.new(ctx)
	end

	local function copy(t)
		local out = {}
		for k, v in pairs(t) do
			out[k] = v
		end
		return out
	end

	-- What the lights module does with a container (contract §4.5): each light
	-- item merged, lamp_mode when its `streaming` changed, settle at the end.
	local function lights_take(container)
		for _, item in ipairs(container.data) do
			local model = item.type == "light" and lights.models[item.id] or nil
			if model then
				local before = copy(model)
				hue_model.update(model, item)
				if model.streaming ~= before.streaming then
					e:lamp_mode(item.id, model.streaming, before)
				end
			end
		end
		e:settle()
	end

	-- An event: the lights module first, then this one (the driver's order).
	local function event(text)
		for _, container in ipairs(decode(text)) do
			lights_take(container)
			e:on_container(container)
		end
	end

	-- A fetch that must succeed.
	local function fetch()
		local ok
		e:fetch_all(function(result) ok = result end)
		assert.is_true(ok)
	end

	local function rids_of(keys)
		local out = {}
		for i, key in ipairs(keys) do
			out[i] = E.rids[key]
		end
		return out
	end

	local function put_for(key)
		for _, put in ipairs(puts) do
			if put.rid == E.rids[key] then
				return put
			end
		end
	end

	local function saw(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	-- The Living Room TV stream starts: its status, then its lamps' mode.
	local function start_tv()
		event(E.events.area_status("tv", "active"))
		event(E.events.lamp_mode(E.tv_lamps, "streaming"))
	end

	-- It stops: its status, its lamps' mode, then Hue's own end state.
	local function stop_tv(end_state)
		event(E.events.area_status("tv", "inactive"))
		event(E.events.lamp_mode(E.tv_lamps, "normal"))
		if end_state then
			event(E.events.lamp_state(end_state))
		end
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		package.loaded["bridge.entertainment"] = nil
		entertainment = require("bridge.entertainment")
		timers, requests, streams, changes, puts, restored = {}, {}, {}, {}, {}, {}
		answers = { [CONFIG_PATH] = E.configuration, [SERVICE_PATH] = E.entertainment }
		after = "Put the lights back"
		lights = new_lights()
		e = new_e()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("module", function()
		it("has the contract's constants", function()
			assert.equal(3, entertainment.RESTORE_AFTER_S)
			assert.equal("Put the lights back", entertainment.PUT_BACK)
			assert.equal("As Hue decides", entertainment.AS_HUE)
			assert.same({ "Put the lights back", "As Hue decides" }, entertainment.AFTER_SYNC)
			assert.equal("another app", entertainment.OTHER_APP)
			assert.equal("Entertainment Areas", entertainment.ROW)
			assert.equal("None", entertainment.NONE)
			assert.equal(1, entertainment.BRIGHTNESS_MARGIN)
			assert.equal(0.002, entertainment.XY_MARGIN)
			assert.equal(2, entertainment.MIREK_MARGIN)
			assert.same({ CONFIG_PATH, SERVICE_PATH },
				{ entertainment.RESOURCES[1].path, entertainment.RESOURCES[2].path })
		end)

		it("needs http, and takes the rest from defaults", function()
			assert.has_error(function() entertainment.new({}) end)
			local bare = entertainment.new({ http = http })
			assert.equal("Put the lights back", bare:after_sync())
			assert.is_false(bare:is_streaming(E.rids.tv_left), "no lights module: nothing streams")
			assert.equal("None", bare:row())
		end)
	end)

	describe("fetch_all()", function()
		it("GETs the areas, then the lamp services, one after the other, and replaces the areas", function()
			fetch()
			assert.same({ "GET " .. CONFIG_PATH, "GET " .. SERVICE_PATH }, requests)
			local areas = e:areas()
			assert.equal(2, #areas)
			assert.equal("Living Room TV", areas[1].name)
			assert.same(rids_of(E.tv_lamps), areas[1].lamps)
			assert.equal("Office", areas[2].name)
			assert.same(rids_of(E.office_lamps), areas[2].lamps, "through the channels and the lamp services")
			answers[CONFIG_PATH] = E.no_areas
			fetch()
			assert.same({}, e:areas())
		end)

		it("reads only the areas on a quick read once the lamp services are known, and keeps their lamps", function()
			e:fetch_all(function() end, "quick")
			assert.same({ "GET " .. CONFIG_PATH, "GET " .. SERVICE_PATH }, requests,
				"the first fetch reads both, whatever the tier")
			requests = {}
			local result = "unset"
			e:fetch_all(function(ok) result = ok end, "quick")
			assert.is_true(result)
			assert.same({ "GET " .. CONFIG_PATH }, requests, "the lamp services are not read again")
			assert.same(rids_of(E.office_lamps), e:areas()[2].lamps, "the channels still reach the lamps")
			requests = {}
			e:fetch_all(function() end, "full")
			assert.same({ "GET " .. CONFIG_PATH, "GET " .. SERVICE_PATH }, requests, "a full read reads both")
		end)

		it("keeps the areas as they were when a GET fails or its answer is malformed", function()
			fetch()
			local result = "unset"
			answers[SERVICE_PATH] = { ok = false, err = "timeout" }
			e:fetch_all(function(ok) result = ok end)
			assert.is_false(result)
			assert.equal(2, #e:areas())
			assert.truthy(saw("GET " .. SERVICE_PATH .. ": timeout; the areas stay as they were"))
			requests, result = {}, "unset"
			answers[CONFIG_PATH] = '{"errors":[]}'
			e:fetch_all(function(ok) result = ok end)
			assert.is_false(result)
			assert.same({ "GET " .. CONFIG_PATH }, requests, "the second GET is not sent")
			assert.truthy(saw("malformed response"))
			assert.equal(2, #e:areas())
		end)

		it("fires no on_stream on the first fetch after load, and keeps an active area's lamps as they are (T2)", function()
			answers[CONFIG_PATH] = configuration({ tv = "active" })
			fetch()
			assert.same({}, streams)
			assert.is_true(e:areas()[1].streaming)
			local model = lights.models[E.rids.tv_left]
			assert.same({ on = true, brightness = 60, mirek = 370, color_mode = "ct", x = 0.4, y = 0.4 },
				e:pre_sync(E.rids.tv_left))
			assert.equal(model.brightness, e:pre_sync(E.rids.tv_left).brightness)
			assert.is_nil(e:pre_sync(E.rids.desk), "not in the active area")
		end)

		it("fires on_stream on a later fetch for each area whose status changed", function()
			fetch()
			answers[CONFIG_PATH] = configuration({ tv = "active" })
			fetch()
			assert.equal(1, #streams)
			assert.same({ "Living Room TV", true }, { streams[1].name, streams[1].started })
			answers[CONFIG_PATH] = configuration({ office = "active" })
			fetch()
			assert.same({ "Living Room TV", false, "Office", true },
				{ streams[2].name, streams[2].started, streams[3].name, streams[3].started })
			fetch()
			assert.equal(3, #streams, "the same status again fires nothing")
		end)

		it("treats an active area a later fetch no longer lists as stopped, and starts its restore", function()
			answers[CONFIG_PATH] = configuration({ tv = "active" })
			fetch()
			answers[CONFIG_PATH] = E.no_areas
			fetch()
			assert.same({ "Living Room TV", false }, { streams[1].name, streams[1].started })
			assert.same({ 3000 }, armed(), "its lamps do not stream: the restore waits RESTORE_AFTER_S")
		end)

		it("starts the restore of a stop a resync finds", function()
			fetch()
			start_tv()
			lights.models[E.rids.tv_left].brightness = 100
			for _, key in ipairs(E.tv_lamps) do
				lights.models[E.rids[key]].streaming = false
				e:lamp_mode(E.rids[key], false, nil)
			end
			e:settle()
			assert.same({}, armed(), "the area still streams")
			fetch()
			assert.same({ "Living Room TV", false }, { streams[2].name, streams[2].started })
			fire()
			assert.equal(1, #puts)
			assert.same({ on = { on = true }, dimming = { brightness = 60 }, color_temperature = { mirek = 370 } },
				put_for("tv_left").body)
		end)
	end)

	describe("events", function()
		before_each(function()
			fetch()
		end)

		it("fire on_stream when an area turns active, then inactive, with the area's copy", function()
			event(E.events.area_status("tv", "active"))
			assert.equal(1, #streams)
			local area = streams[1].area
			assert.is_true(streams[1].started)
			assert.same({ E.area_rids.tv, "Living Room TV", "screen", "active", E.streamer, true },
				{ area.id, area.name, area.kind, area.status, area.streamer, area.streaming })
			assert.same(rids_of(E.tv_lamps), area.lamps)
			area.lamps[1] = "changed"
			assert.same(rids_of(E.tv_lamps), e:areas()[1].lamps, "a copy")
			event(E.events.area_status("tv", "active"))
			assert.equal(1, #streams, "the same status again fires nothing")
			event(E.events.area_status("tv", "inactive"))
			assert.same({ "Living Room TV", false }, { streams[2].name, streams[2].started })
			assert.is_nil(streams[2].area.streamer)
		end)

		it("list an added area, firing on_stream only when it arrives active", function()
			event(E.events.desk_add)
			assert.equal("Desk", e:areas()[1].name)
			assert.same({}, streams)
			local item = items('{"data":[' .. E.desk_area .. ']}')[1]
			item.id, item.status, item.metadata.name = "6a7b8c9d-0000-4000-8000-0000000ea009", "active", "Game"
			e:on_container({ type = "add", data = { item } })
			assert.same({ "Game", true }, { streams[1].name, streams[1].started })
		end)

		it("drop a deleted area; deleting an active one stops its stream", function()
			event(E.events.office_delete)
			assert.equal(1, #e:areas())
			assert.same({}, streams)
			fetch()
			event(E.events.area_status("office", "active"))
			event(E.events.office_delete)
			assert.same({ "Office", true, "Office", false },
				{ streams[1].name, streams[1].started, streams[2].name, streams[2].started })
		end)

		it("rename an area", function()
			event(E.events.office_rename)
			assert.equal("Living Room TV (5 lamps) | Study (3 lamps)", e:row())
		end)

		it("ignore an update for an area the bridge has not listed yet, until the next resync", function()
			local fresh = new_e()
			e = fresh
			event(E.events.area_status("tv", "active"))
			assert.same({}, streams)
			assert.truthy(saw("update for unknown area 6a7b8c9d ignored until the next resync"))
		end)

		it("follow a lamp service added later, for an area without light_services", function()
			answers[SERVICE_PATH] = E.no_areas
			fetch()
			assert.same({}, e:areas()[2].lamps, "Office has no lamps without the lamp services")
			local service = by_rid_service(E.service_rids.desk)
			e:on_container({ type = "add", data = { service } })
			assert.same({ E.rids.desk }, e:areas()[2].lamps)
			e:on_container({ type = "delete", data = { { id = E.service_rids.desk, type = "entertainment" } } })
			assert.same({}, e:areas()[2].lamps)
		end)

		it("ignore other items, junk and containers that are not tables", function()
			e:on_container(nil)
			e:on_container({})
			e:on_container({ type = "update", data = "x" })
			e:on_container({ type = "update", data = { "junk", { id = "a/b", type = "entertainment_configuration",
				status = "active" }, { id = E.rids.desk, type = "light", mode = "streaming" } } })
			assert.same({}, streams)
			assert.equal(2, #e:areas())
			assert.is_false(saw("failed"))
		end)
	end)

	describe("lamp_mode() and settle()", function()
		before_each(function()
			fetch()
		end)

		it("keep the model from before the change as a lamp's pre-sync state", function()
			local rid = E.rids.tv_left
			local before = copy(lights.models[rid])
			lights.models[rid].brightness = 99
			e:lamp_mode(rid, true, before)
			assert.equal(60, e:pre_sync(rid).brightness)
		end)

		it("keep the current model at first sight, when there is no before (T2)", function()
			e:lamp_mode(E.rids.tv_bar, true, nil)
			assert.same({ on = true, brightness = 30, x = 0.6, y = 0.35, color_mode = "xy" }, e:pre_sync(E.rids.tv_bar))
			local kept = e:pre_sync(E.rids.tv_bar)
			kept.on = false
			assert.is_true(e:pre_sync(E.rids.tv_bar).on, "pre_sync gives a copy")
		end)

		it("keep the first pre-sync state when a lamp streams again before its restore", function()
			start_tv()
			event(E.events.area_status("tv", "inactive"))
			event(E.events.lamp_mode(E.tv_lamps, "normal"))
			event(E.events.lamp_state({ tv_left = { brightness = "100" } }))
			event(E.events.area_status("tv", "active"))
			assert.same({}, armed(), "the restore waits no longer")
			event(E.events.lamp_mode(E.tv_lamps, "streaming"))
			assert.equal(60, e:pre_sync(E.rids.tv_left).brightness, "from before the first stream")
		end)

		it("drop the state of a lamp that stops streaming in an area the bridge does not know", function()
			e:lamp_mode(E.rids.desk, true, nil)
			assert.truthy(e:pre_sync(E.rids.desk))
			e:lamp_mode(E.rids.desk, false, nil)
			assert.is_nil(e:pre_sync(E.rids.desk))
		end)

		it("settle calls on_lamps_changed once with the lamps, sorted, and then forgets them", function()
			e:lamp_mode(E.rids.shelf, true, nil)
			e:lamp_mode(E.rids.desk, true, nil)
			e:lamp_mode(E.rids.shelf, false, nil)
			e:lamp_mode("a/b", true, nil)
			assert.same({}, changes, "nothing before the settle")
			e:settle()
			assert.same({ { E.rids.desk, E.rids.shelf } }, changes)
			e:settle()
			assert.equal(1, #changes, "nothing changed since")
		end)

		it("settle once per lights container, with every lamp of it", function()
			start_tv()
			assert.same({ rids_of(E.tv_lamps) }, changes)
		end)

		it("is_streaming and stream_label follow the lamp's model", function()
			assert.is_false(e:is_streaming(E.rids.tv_left))
			assert.is_nil(e:stream_label(E.rids.tv_left))
			start_tv()
			assert.is_true(e:is_streaming(E.rids.tv_left))
			assert.equal("another app", e:stream_label(E.rids.tv_left))
			assert.is_false(e:is_streaming(E.rids.desk))
			assert.is_false(e:is_streaming("unknown-rid"))
			assert.is_nil(e:stream_label(nil))
			local plain = new_e({ lights = lights })
			assert.is_true(plain:is_streaming(E.rids.tv_left), "lights given as the instance itself")
		end)
	end)

	describe("the restore", function()
		before_each(function()
			fetch()
		end)

		it("waits until no lamp of the area streams, then RESTORE_AFTER_S, then puts back what differs", function()
			start_tv()
			event(E.events.area_status("tv", "inactive"))
			assert.same({}, armed(), "its lamps still stream")
			event(E.events.lamp_mode({ "tv_strip", "tv_left", "tv_right", "tv_bar" }, "normal"))
			assert.same({}, armed(), "the floor lamp still streams")
			event(E.events.lamp_mode({ "floor" }, "normal"))
			assert.same({ 3000 }, armed())
			-- Hue's own end state (T7): within the margins, or off and off, nothing goes.
			event(E.events.lamp_state({
				tv_left = { brightness = "61.0" },           -- 1 apart: the same
				tv_right = { x = 0.5, y = 0.5 },             -- off before and after
				tv_bar = { x = 0.6015, y = 0.3515 },        -- 0.0015 apart: the same
				floor = { mirek = 303 },                     -- 3 apart: differs
			}))
			assert.same({}, puts, "nothing before the timer")
			fire()
			assert.equal(1, #puts)
			assert.same({ on = { on = true }, dimming = { brightness = 45.5 }, color_temperature = { mirek = 300 } },
				put_for("floor").body)
			assert.same({ { name = "Living Room TV", count = 1 } }, restored)
			for _, key in ipairs(E.tv_lamps) do
				assert.is_nil(e:pre_sync(E.rids[key]), "dropped: " .. key)
			end
		end)

		it("arms the timer at the stop when the lamps reported normal first", function()
			start_tv()
			event(E.events.lamp_mode(E.tv_lamps, "normal"))
			assert.same({}, armed(), "the area still streams")
			event(E.events.area_status("tv", "inactive"))
			assert.same({ 3000 }, armed())
		end)

		it("disarms the timer when a lamp of the area streams again, and arms it afresh after", function()
			start_tv()
			stop_tv()
			assert.same({ 3000 }, armed())
			event(E.events.lamp_mode({ "tv_left" }, "streaming"))
			assert.same({}, armed())
			event(E.events.lamp_mode({ "tv_left" }, "normal"))
			assert.same({ 3000 }, armed())
		end)

		it("puts back an off lamp with a bare off, a colour with its xy, a white with its mirek", function()
			start_tv()
			stop_tv({
				tv_strip = { on = true, brightness = "100", x = 0.5, y = 0.4 },
				tv_left = { on = true, brightness = "100", x = 0.5, y = 0.4 },
				tv_right = { on = true, brightness = "100", x = 0.5, y = 0.4 },
				tv_bar = { on = true, brightness = "100", x = 0.5, y = 0.4 },
				floor = { on = true, brightness = "100", x = 0.5, y = 0.4 },
			})
			fire()
			assert.equal(5, #puts)
			assert.same({ on = { on = true }, dimming = { brightness = 80 }, color = { xy = { x = 0.3127, y = 0.329 } } },
				put_for("tv_strip").body)
			assert.same({ on = { on = true }, dimming = { brightness = 60 }, color_temperature = { mirek = 370 } },
				put_for("tv_left").body)
			assert.same({ on = { on = false } }, put_for("tv_right").body)
			assert.same({ on = { on = true }, dimming = { brightness = 30 }, color = { xy = { x = 0.6, y = 0.35 } } },
				put_for("tv_bar").body)
			assert.same(rids_of(E.tv_lamps), { puts[1].rid, puts[2].rid, puts[3].rid, puts[4].rid, puts[5].rid })
			assert.same({ { name = "Living Room TV", count = 5 } }, restored)
		end)

		it("never applies what changed during the stream: the lamps go back to their state from before it", function()
			start_tv()
			-- A command the bridge stored during the stream [assumed, T3] shows in the model.
			event(E.events.lamp_state({ tv_left = { brightness = "10" } }))
			stop_tv({ tv_left = { brightness = "100" } })
			fire()
			assert.same({ brightness = 60 }, put_for("tv_left").body.dimming)
		end)

		it("sends nothing, and calls no on_restored, when every lamp is as it was", function()
			start_tv()
			stop_tv()
			fire()
			assert.same({}, puts)
			assert.same({}, restored)
			assert.is_nil(e:pre_sync(E.rids.tv_left), "dropped all the same")
		end)

		it("keeps a lamp shared with another area that still streams until that area stops too", function()
			start_tv()
			event(E.events.area_status("office", "active"))
			event(E.events.lamp_mode({ "desk", "shelf" }, "streaming"))
			event(E.events.area_status("tv", "inactive"))
			event(E.events.lamp_mode({ "tv_strip", "tv_left", "tv_right", "tv_bar" }, "normal"))
			assert.same({ 3000 }, armed(), "the floor lamp streams for the Office: it does not hold the TV's restore")
			event(E.events.lamp_state({ tv_left = { brightness = "100" }, floor = { brightness = "100" } }))
			fire()
			assert.same({ E.rids.tv_left }, { puts[1].rid })
			assert.equal(1, #puts, "not the floor lamp")
			assert.equal(45.5, e:pre_sync(E.rids.floor).brightness, "kept for the Office's restore")
			event(E.events.area_status("office", "inactive"))
			event(E.events.lamp_mode(E.office_lamps, "normal"))
			event(E.events.lamp_state({ floor = { brightness = "100" }, desk = { on = true } }))
			fire()
			assert.same({ dimming = { brightness = 45.5 }, color_temperature = { mirek = 300 }, on = { on = true } },
				put_for("floor").body)
			assert.same({ on = { on = false } }, put_for("desk").body)
			assert.same({ { name = "Living Room TV", count = 1 }, { name = "Office", count = 2 } }, restored)
			assert.is_nil(e:pre_sync(E.rids.floor))
		end)

		it("drops the pre-sync states without a PUT when After A Sync Ends is As Hue decides", function()
			after = "As Hue decides"
			start_tv()
			assert.truthy(e:pre_sync(E.rids.tv_left), "kept while the stream runs")
			stop_tv({ tv_left = { brightness = "100" } })
			assert.same({}, armed(), "no restore waits")
			fire()
			assert.same({}, puts)
			assert.same({}, restored)
			assert.is_nil(e:pre_sync(E.rids.tv_left))
			assert.truthy(saw("After A Sync Ends is As Hue decides"))
		end)

		it("reads After A Sync Ends again when the timer fires", function()
			start_tv()
			stop_tv({ tv_left = { brightness = "100" } })
			after = "As Hue decides"
			fire()
			assert.same({}, puts)
			assert.is_nil(e:pre_sync(E.rids.tv_left))
		end)

		it("counts only the lamps put_back queued, and logs one whose PUT failed", function()
			e = new_e({ put_back = function(rid, body, done)
				puts[#puts + 1] = { rid = rid, body = body, done = done }
				return rid ~= E.rids.tv_left
			end })
			fetch()
			start_tv()
			stop_tv({ tv_left = { brightness = "100" }, tv_bar = { brightness = "100" } })
			fire()
			assert.equal(2, #puts)
			assert.same({ { name = "Living Room TV", count = 1 } }, restored)
			put_for("tv_bar").done({ ok = false, err = "HTTP 503" })
			assert.truthy(saw("putting " .. E.rids.tv_bar .. " back after the sync failed: HTTP 503"))
		end)

		it("survives a put_back or an on_stream that raises", function()
			e = new_e({ put_back = function() error("boom") end, on_stream = function() error("bang") end })
			fetch()
			start_tv()
			stop_tv({ tv_left = { brightness = "100" } })
			fire()
			assert.same({}, restored)
			assert.truthy(saw("on_stream failed"))
			assert.truthy(saw("put_back failed for " .. E.rids.tv_left))
		end)

		it("stop() cancels the waiting restores", function()
			start_tv()
			stop_tv({ tv_left = { brightness = "100" } })
			assert.same({ 3000 }, armed())
			e:stop()
			assert.same({}, armed())
		end)
	end)

	describe("differs()", function()
		local differs

		before_each(function()
			differs = entertainment.differs
		end)

		it("is true when on differs, and never for two off states", function()
			assert.is_true(differs({ on = true }, { on = false }))
			assert.is_true(differs({ on = false }, { on = true }))
			assert.is_false(differs({ on = false, brightness = 10, color_mode = "xy", x = 0.1, y = 0.1 },
				{ on = false, brightness = 90, color_mode = "ct", mirek = 400 }))
		end)

		it("is true for a brightness more than 1 apart while both are on", function()
			assert.is_false(differs({ on = true, brightness = 50 }, { on = true, brightness = 51 }))
			assert.is_false(differs({ on = true, brightness = 50 }, { on = true, brightness = 49 }))
			assert.is_true(differs({ on = true, brightness = 50 }, { on = true, brightness = 51.5 }))
			assert.is_false(differs({ on = true, brightness = 50 }, { on = true }), "an unknown level is no difference")
		end)

		it("is true for another colour mode, xy more than 0.002 apart, mirek more than 2 apart", function()
			local xy = { on = true, brightness = 50, color_mode = "xy", x = 0.3, y = 0.3 }
			local ct = { on = true, brightness = 50, color_mode = "ct", mirek = 300 }
			assert.is_true(differs(xy, ct))
			assert.is_true(differs(ct, xy))
			assert.is_false(differs(xy, { on = true, brightness = 50, color_mode = "xy", x = 0.3019, y = 0.2981 }))
			assert.is_true(differs(xy, { on = true, brightness = 50, color_mode = "xy", x = 0.3021, y = 0.3 }))
			assert.is_true(differs(xy, { on = true, brightness = 50, color_mode = "xy", x = 0.3, y = 0.297 }))
			assert.is_false(differs(ct, { on = true, brightness = 50, color_mode = "ct", mirek = 302 }))
			assert.is_true(differs(ct, { on = true, brightness = 50, color_mode = "ct", mirek = 297 }))
		end)

		it("has nothing to compare without a known on state, or a colour mode, or a table", function()
			assert.is_false(differs({ brightness = 10 }, { on = true, brightness = 90 }))
			assert.is_false(differs({ on = true, brightness = 50 }, { on = true, brightness = 50, color_mode = "ct",
				mirek = 400 }), "a white-only lamp's colour is not compared")
			assert.is_false(differs(nil, { on = true }))
			assert.is_false(differs({ on = true }, nil))
		end)
	end)

	describe("body()", function()
		local body

		before_each(function()
			body = entertainment.body
		end)

		it("is a bare off for an off state", function()
			assert.same({ on = { on = false } }, body({ on = false, brightness = 40, color_mode = "xy", x = 0.2, y = 0.2 }))
		end)

		it("carries on, the brightness and the colour of its mode", function()
			assert.same({ on = { on = true }, dimming = { brightness = 40 }, color = { xy = { x = 0.2, y = 0.25 } } },
				body({ on = true, brightness = 40, color_mode = "xy", x = 0.2, y = 0.25, mirek = 300 }))
			assert.same({ on = { on = true }, dimming = { brightness = 40 }, color_temperature = { mirek = 300 } },
				body({ on = true, brightness = 40, color_mode = "ct", x = 0.2, y = 0.25, mirek = 300 }))
			assert.same({ on = { on = true } }, body({ on = true }), "an on/off lamp")
		end)

		it("passes every number through common/num: clamped, whole mirek within the lamp's range, no infinity", function()
			assert.same({ on = { on = true }, dimming = { brightness = 100 }, color = { xy = { x = 1, y = 0 } } },
				body({ on = true, brightness = 150, color_mode = "xy", x = 1.5, y = -0.2 }))
			assert.same({ on = { on = true }, color_temperature = { mirek = 454 } },
				body({ on = true, brightness = math.huge, color_mode = "ct", mirek = 480.4 }, { mirek_min = 153,
					mirek_max = 454 }))
			assert.same({ mirek = 301 }, body({ on = true, color_mode = "ct", mirek = 300.6 }).color_temperature)
			assert.same({ on = { on = true } }, body({ on = true, brightness = 0 / 0, color_mode = "xy", x = 0 / 0, y = 0.3 }))
		end)

		it("is nil without a known on state", function()
			assert.is_nil(body({ brightness = 40 }))
			assert.is_nil(body(nil))
		end)
	end)

	describe("the row and areas()", function()
		it("reads None without areas", function()
			assert.equal("None", e:row())
			answers[CONFIG_PATH] = E.no_areas
			fetch()
			assert.equal("None", e:row())
		end)

		it("reads as the contract's example while the TV area syncs", function()
			fetch()
			assert.equal("Living Room TV (5 lamps) | Office (3 lamps)", e:row())
			event(E.events.area_status("tv", "active"))
			assert.equal("Living Room TV (5 lamps, syncing: another app) | Office (3 lamps)", e:row())
		end)

		it("sorts the areas by name, whatever their case, and says 1 lamp", function()
			fetch()
			event(E.events.desk_add)
			local item = items('{"data":[' .. E.desk_area .. ']}')[1]
			item.id, item.metadata.name = "6a7b8c9d-0000-4000-8000-0000000ea008", "attic"
			e:on_container({ type = "add", data = { item } })
			assert.equal("attic (1 lamp) | Desk (1 lamp) | Living Room TV (5 lamps) | Office (3 lamps)", e:row())
			local areas = e:areas()
			assert.same({ "attic", "Desk", "Living Room TV", "Office" },
				{ areas[1].name, areas[2].name, areas[3].name, areas[4].name })
			assert.is_false(areas[3].streaming)
		end)

		it("is capped by rows.ROW_MAX: the areas that fit, then how many more", function()
			local data = {}
			for i = 1, 40 do
				data[i] = { id = string.format("ea-%02d", i), type = "entertainment_configuration",
					metadata = { name = string.format("Area %02d", i) }, status = "inactive" }
			end
			e:on_container({ type = "add", data = data })
			local row = e:row()
			assert.is_true(#row <= rows.ROW_MAX, #row .. " bytes")
			local shown = select(2, row:gsub("%(0 lamps%)", ""))
			local more = tonumber(row:match(" | %+(%d+) more$"))
			assert.truthy(more, row)
			assert.equal(40, shown + more)
			assert.equal("Area 01 (0 lamps) | Area 02", row:sub(1, 27))
		end)

		it("cuts a first area too long for the row on its own, before a character", function()
			e:on_container({ type = "add", data = { { id = "ea-1", type = "entertainment_configuration",
				metadata = { name = ("€"):rep(100) } } } })
			local row = e:row()
			assert.is_true(#row <= rows.ROW_MAX)
			assert.equal("...", row:sub(-3))
			assert.truthy(row:sub(1, -4):match("^[\226\130\172]+$") and (#row - 3) % 3 == 0, "whole characters only")
			e:on_container({ type = "add", data = { { id = "ea-2", type = "entertainment_configuration",
				metadata = { name = "Office" } } } })
			assert.equal("Office (0 lamps) | +1 more", e:row(), "a later area too long is counted")
		end)
	end)

	describe("Last Action texts", function()
		it("are the contract's", function()
			local area = { name = "Living Room TV" }
			assert.equal("Sync started: Living Room TV", entertainment.started_text(area))
			assert.equal("Sync stopped: Living Room TV", entertainment.stopped_text(area))
			assert.equal("Lights put back after the sync: Living Room TV (5 lamps)", entertainment.restored_text(area, 5))
			assert.equal("Lights put back after the sync: Living Room TV (1 lamp)", entertainment.restored_text(area, 1))
		end)
	end)
end)
