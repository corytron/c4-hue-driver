-- bridge/automations.lua (docs/hue-automation-audit-design.md §6.1-6.6, the
-- test list of §8): the owner of the Hue automation audit. A fake bridge
-- answers the requests from the fixtures of tests/fixtures/hue_automations.lua
-- (part A's), a fake control4() says which lights Control4 controls, and the
-- clock and the timers are the spec's own. Test names carry the contract's
-- decision (D) and lifecycle (H, C, R) ids they pin.

local json = require("dkjson")
local log = require("common.log")
local A = require("fixtures.hue_automations")
local automations = require("bridge.automations")

local T0 = 1793000000
local BRIDGE = "001788fffe123abc"
local OTHER_BRIDGE = "001788fffe999999"
local I, L, T = A.ids.instances, A.ids.lights, A.topology
local INSTANCE_PATH = "/clip/v2/resource/behavior_instance"
local SCRIPT_PATH = "/clip/v2/resource/behavior_script"

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return out
end

local function find(list, pattern)
	for _, line in ipairs(list) do
		if line:find(pattern, 1, true) then
			return line
		end
	end
	return nil
end

local function day(ts)
	return os.date("%m-%d", ts)
end

describe("bridge.automations", function()
	local a, ctx, bridge, requests, held, store, saves, last, changed, logged, timers, now
	local c4, firmware, paired, busy

	-- The fake bridge --------------------------------------------------------------------------

	local function reset_bridge(keys)
		bridge = { instances = {}, scripts = A.scripts(), put = {}, down = false }
		for _, item in ipairs(A.instances(keys)) do
			bridge.instances[item.id] = item
		end
	end

	local function ok(data)
		return { ok = true, code = 200, json = json.decode(json.encode({ errors = {}, data = data })) }
	end

	local function respond(req, cb)
		if bridge.down then
			return cb({ ok = false, err = "transfer failed (28): timeout" })
		end
		local path = req.path
		if req.method == "PUT" then
			local rid = path:match("behavior_instance/(.+)$")
			local item = bridge.instances[rid]
			local mode = bridge.put[rid] or "apply"
			if not item then
				return cb({ ok = false, code = 404, err = "HTTP 404" })
			elseif mode == "refuse" then
				return cb({ ok = false, code = 400, err = "HTTP 400",
					json = { errors = { { description = "invalid value for enabled" } }, data = {} } })
			elseif mode == "silent" then
				return cb({ ok = false, err = "transfer failed (28): timeout" })
			elseif mode == "silent_applied" then
				item.enabled = req.body.enabled
				return cb({ ok = false, err = "transfer failed (28): timeout" })
			elseif mode == "ignore" then
				return cb(ok({ { rid = rid, rtype = "behavior_instance" } }))
			end
			item.enabled = req.body.enabled
			item.status = req.body.enabled and "running" or "disabled"
			return cb(ok({ { rid = rid, rtype = "behavior_instance" } }))
		end
		if path == SCRIPT_PATH then
			return cb(ok(bridge.scripts))
		end
		if path == INSTANCE_PATH then
			local list = {}
			for _, item in pairs(bridge.instances) do
				list[#list + 1] = item
			end
			table.sort(list, function(x, y) return x.id < y.id end)
			return cb(ok(list))
		end
		local rid = path:match("behavior_instance/(.+)$")
		if rid then
			local item = bridge.instances[rid]
			if not item then
				return cb({ ok = false, code = 404, err = "HTTP 404" })
			end
			return cb(ok({ item }))
		end
		cb({ ok = false, code = 404, err = "HTTP 404" })
	end

	local function http(req, cb)
		requests[#requests + 1] = { method = req.method, path = req.path, body = copy(req.body),
			saved = copy(store) }
		if bridge.hold then
			held[#held + 1] = { req = req, cb = cb }
			return
		end
		respond(req, cb)
	end

	local function release()
		local job = table.remove(held, 1)
		respond(job.req, job.cb)
	end

	local function count(method, path_pattern)
		local n = 0
		for _, r in ipairs(requests) do
			if r.method == method and (not path_pattern or r.path:find(path_pattern, 1, true)) then
				n = n + 1
			end
		end
		return n
	end

	local function puts()
		local list = {}
		for _, r in ipairs(requests) do
			if r.method == "PUT" then
				list[#list + 1] = r
			end
		end
		return list
	end

	-- The context ------------------------------------------------------------------------------

	local function expand(rid, rtype)
		if rtype == "room" or rtype == "zone" or rtype == "bridge_home" then
			return copy(T.members[rid] or {})
		elseif rtype == "device" then
			return copy(T.device_lights[rid] or {})
		elseif rtype == "scene" then
			local g = T.scene_group[rid]
			return g and copy(T.members[g.rid] or {}) or {}
		end
		return {}
	end

	local function new_module()
		a = automations.new(ctx)
		a:load()
		return a
	end

	before_each(function()
		logged, requests, held, saves, timers = {}, {}, {}, {}, {}
		log.sink = function(line) logged[#logged + 1] = line end
		now, store, last, changed, busy = T0, nil, nil, 0, nil
		firmware, paired = "1.70.1970000000", true
		-- Control4 controls the Bedroom Lamp and the Hall Lamp (light devices).
		c4 = { lights = { [L.bedroom_lamp] = "Bed Lamp", [L.hall_lamp] = "Hall Light" }, via = {} }
		reset_bridge()
		ctx = {
			http = http,
			log = log,
			now = function() return now end,
			persist_get = function(key)
				assert.are.equal("hue_automations", key)
				return copy(store)
			end,
			persist_set = function(key, value)
				assert.are.equal("hue_automations", key)
				store = copy(value)
				saves[#saves + 1] = copy(value)
			end,
			bridge_id = function() return BRIDGE end,
			firmware = function() return firmware end,
			paired = function() return paired end,
			control4 = function() return c4 end,
			expand = expand,
			light_name = function(rid) return T.light_names[rid] end,
			motion_device = function(rid) return rid == A.ids.area and "Kitchen Motion" or nil end,
			last_action = function(text) last = text end,
			changed = function() changed = changed + 1 end,
			busy = function() return busy end,
			wrote = function() end,
			set_timer = function(ms, fn)
				local t = { ms = ms, fn = fn, active = true }
				function t.Cancel() t.active = false end
				timers[#timers + 1] = t
				return t
			end,
		}
		new_module()
	end)

	after_each(function()
		log.sink = print
	end)

	local function fire_timers()
		local list = timers
		timers = {}
		for _, t in ipairs(list) do
			if t.active then
				t.active = false
				t.fn()
			end
		end
	end

	local function resync(tier)
		local result
		a:resync(function(ok_, err, sent) result = { ok = ok_, err = err, sent = sent } end, tier)
		return result
	end

	local function run(value)
		last = nil
		a:run({ Automation = value })
		return last
	end

	local function group_of(rid)
		local v = a:evaluate().by_rid[rid]
		return v and v.group
	end

	local function stream(kind, items)
		return a:on_container(A.container(kind, items))
	end

	-- Resync (D18) ------------------------------------------------------------------------------

	describe("resync", function()
		it("a full resync reads the instances, then the scripts, once each; done(true, nil, 0)", function()
			local r = resync()
			assert.are.same({ ok = true, sent = 0 }, { ok = r.ok, err = r.err, sent = r.sent })
			assert.are.same({ "GET " .. INSTANCE_PATH, "GET " .. SCRIPT_PATH },
				{ requests[1].method .. " " .. requests[1].path, requests[2].method .. " " .. requests[2].path })
			assert.are.equal(2, #requests)
		end)

		it("the next full resync reads the instances alone; an unknown script id is not asked again (H20)", function()
			resync()
			requests = {}
			resync()
			assert.are.equal(1, #requests)
			assert.are.equal(INSTANCE_PATH, requests[1].path)
			-- The unknown script's instance is classified as an unknown script, not "not classified".
			assert.are_not.equal("unclassified", group_of(I.unknown))
		end)

		it("the quick tier reads nothing and answers at once", function()
			local r = resync("quick")
			assert.is_true(r.ok)
			assert.are.equal(0, #requests)
			assert.are.equal("Not read yet", a:summary())
		end)

		it("re-reads the scripts when an instance names a script id not read yet", function()
			resync()
			requests = {}
			local item = A.instance("wake_up")
			item.id = "b1000000-0000-4000-8000-0000000000a1"
			item.script_id = "5c000000-0000-4000-8000-0000000000f2"
			bridge.instances[item.id] = item
			resync()
			assert.are.equal(1, count("GET", SCRIPT_PATH))
		end)

		it("re-reads the scripts when Bridge Firmware changes (H21)", function()
			resync()
			requests = {}
			firmware = "1.71.1971000000"
			resync()
			assert.are.equal(1, count("GET", SCRIPT_PATH))
		end)

		it("a stream item naming a new script asks for it from a timer, never inside the callback", function()
			resync()
			requests = {}
			local item = A.instance("schedule")
			item.id = "b1000000-0000-4000-8000-0000000000a2"
			item.script_id = "5c000000-0000-4000-8000-0000000000f3"
			assert.is_true(stream("add", { item }))
			assert.are.equal(0, #requests)
			assert.are.equal("unclassified", group_of(item.id))
			fire_timers()
			assert.are.equal(1, count("GET", SCRIPT_PATH))
			assert.are_not.equal("unclassified", group_of(item.id))
			assert.is_true(changed > 0)
		end)

		it("a failed GET marks nothing and the row says as of the last good read (D23, H26)", function()
			store = { v = 1, bridge_id = BRIDGE, entries = { [I.wake_up] = { state = "disabled", name = "Wake Weekdays",
				kind = "wake up", lights = { "Bed Lamp" }, at = T0 - 86400 } }, kept = {}, refused = {}, other = {} }
			new_module()
			bridge.instances[I.wake_up].enabled = false
			resync()
			now = T0 + 3600
			bridge.down = true
			local r = resync()
			assert.is_false(r.ok)
			assert.truthy(r.err:find("GET behavior_instance: ", 1, true), r.err)
			assert.are.equal("disabled", store.entries[I.wake_up].state)
			assert.truthy(a:summary():find("(as of " .. os.date("%H:%M", T0) .. ")", 1, true), a:summary())
			assert.are.equal("disabled", group_of(I.wake_up))
		end)
	end)

	-- Evaluate (D3-D8) ---------------------------------------------------------------------------

	describe("evaluate", function()
		before_each(function()
			resync()
		end)

		it("sorts each instance into conflict, shared, elsewhere, does nothing, safety, outside (D8)", function()
			local expected = {
				wake_up = "conflict",         -- a time, Bedroom (Bed Lamp)
				motion_sensor = "conflict",   -- a sensor, Hallway (Hall Light)
				dimmer = "shared",            -- a switch on Downstairs (Hall Light)
				tap_dial = "shared",
				timer = "shared",             -- Timers: a person starts it
				go_to_sleep = "shared",       -- no `when`
				mimic = "shared",             -- stopped
				schedule = "elsewhere",       -- Living Room only
				coming_home = "elsewhere",
				motionaware = "inert",        -- Do nothing (H14)
				smoke_alarm = "safety",       -- D22
				vacation = "outside",         -- disabled in Hue (H7)
			}
			for key, group in pairs(expected) do
				assert.are.equal(group, group_of(I[key]), key)
			end
			assert.are.equal(1, a:evaluate().entertainment) -- H19
		end)

		it("can't tell which lights: an enabled instance with no target reference (D8)", function()
			local item = A.instance("wake_up")
			item.id = "b1000000-0000-4000-8000-0000000000c1"
			item.metadata.name = "Mystery"
			item.configuration.where = nil
			item.dependees = {}
			stream("add", { item })
			assert.are.equal("unknown_lights", group_of(item.id))
			assert.truthy(find(a:list_items(), "Can't tell which lights: Mystery"))
		end)

		it("D3: lights of a zone light or scene device count (ctx.control4().via)", function()
			c4 = { lights = {}, via = { [L.kitchen1] = "Kitchen Zone" } }
			stream("update", { A.updates.configuration("motionaware_before") })
			assert.are.equal("conflict", group_of(I.motionaware))
			local line = find(a:list_items(), "On Control4 lights: Kitchen motion area")
			assert.truthy(line:find("(MotionAware) on Kitchen 1", 1, true), line)
			assert.truthy(line:find("(Hue app only)", 1, true))
			assert.truthy(line:find("(Control4 device: Kitchen Motion)", 1, true))
		end)

		it("follows Control4 at once: a light device added or forgotten re-evaluates without a GET (D19, C1, C2)",
			function()
				requests = {}
				assert.are.equal("elsewhere", group_of(I.schedule))
				c4.lights[L.living_lamp] = "Living Lamp C4"
				assert.are.equal("conflict", group_of(I.schedule))
				c4.lights[L.living_lamp] = nil
				assert.are.equal("elsewhere", group_of(I.schedule))
				assert.are.equal(0, #requests)
			end)

		it("partial overlap (H12): the picker says how many lights are outside Control4", function()
			local list = a:picker("f:off")
			local wake
			for _, e in ipairs(list) do
				if e.value == "off:" .. I.wake_up then
					wake = e.text
				end
			end
			assert.are.equal("Wake Weekdays (wake up) on Bed Lamp; also 2 lights outside Control4", wake)
		end)
	end)

	-- Keep (D10, D15) --------------------------------------------------------------------------------

	describe("keep", function()
		before_each(function()
			resync()
		end)

		it("keeps a conflict off Attention; it lapses only for new Control4 lights", function()
			assert.are.equal("Kept Wake Weekdays on the Hue side: Attention no longer lists it unless it starts acting on "
				.. "other Control4 lights.", run("keep:" .. I.wake_up))
			assert.are.equal("kept", group_of(I.wake_up))
			assert.is_nil(find(a:attention_items(), "Wake Weekdays"))
			assert.is_true(store.kept[I.wake_up].lights[L.bedroom_lamp])
			-- A light leaves Control4: still kept.
			c4.lights[L.bedroom_lamp] = nil
			c4.lights[L.bedside] = nil
			assert.are.equal("elsewhere", group_of(I.wake_up))
			c4.lights[L.bedroom_lamp] = "Bed Lamp"
			assert.are.equal("kept", group_of(I.wake_up))
			-- A new Control4 light: listed again, naming only the new light.
			c4.lights[L.bedroom_ceiling] = "Ceiling"
			assert.are.equal("conflict", group_of(I.wake_up))
			assert.truthy(find(a:list_items(), "On Control4 lights: Wake Weekdays (wake up) (kept; now also Ceiling)"))
			assert.truthy(find(a:attention_items(), "Wake Weekdays"))
			-- Keep again covers the new light.
			run("keep:" .. I.wake_up)
			assert.are.equal("kept", group_of(I.wake_up))
		end)

		it("Stop keeping lists it again", function()
			run("keep:" .. I.wake_up)
			local list = a:picker("f:unkeep")
			assert.are.equal("Wake Weekdays (kept " .. day(T0) .. ")", list[2].text)
			assert.are.equal("Stopped keeping Wake Weekdays: it is listed again while it acts on Control4 lights.",
				run("unkeep:" .. I.wake_up))
			assert.are.equal("conflict", group_of(I.wake_up))
			assert.is_nil(store.kept[I.wake_up])
		end)

		it("keep:shared keeps every shared line at once", function()
			local text = run("keep:shared")
			assert.truthy(text:find("^Kept 5 Hue automations on the Hue side"), text)
			assert.are.equal("kept", group_of(I.dimmer))
			assert.are.equal("kept", group_of(I.timer))
			assert.are.equal(0, #puts())
		end)

		it("Restore keeps what still acts on Control4 lights (D15)", function()
			run("off:" .. I.wake_up)
			now = T0 + 60
			local text = run("on:" .. I.wake_up)
			assert.are.equal("Turned on again in Hue: Wake Weekdays (disabled by Control4 since " .. day(T0) .. "). It acts "
				.. "on Bed Lamp, a Control4 light, so it is now kept (Hue Automations ▸ Stop keeping lists it again).", text)
			assert.are.equal("kept", group_of(I.wake_up))
			assert.is_nil(store.entries[I.wake_up])
		end)
	end)

	-- Disable (R1-R5) ---------------------------------------------------------------------------------

	describe("disable", function()
		before_each(function()
			resync()
			requests = {}
		end)

		it("R1: a fresh GET, the entry persisted pending before the PUT, a read-back, then disabled (D13)", function()
			local text = run("off:" .. I.wake_up)
			assert.are.same({ "GET", "PUT", "GET" }, { requests[1].method, requests[2].method, requests[3].method })
			assert.are.equal(INSTANCE_PATH .. "/" .. I.wake_up, requests[2].path)
			assert.are.same({ enabled = false }, requests[2].body)
			local before = requests[2].saved.entries[I.wake_up]
			assert.are.equal("pending", before.state)
			assert.are.equal("Wake Weekdays", before.name)
			assert.are.equal("wake up", before.kind)
			assert.are.same({ "Bed Lamp" }, before.lights)
			assert.are.equal(A.ids.scripts.wake_up, before.script_rid)
			assert.is_string(before.sig)
			assert.are.equal(T0, before.at)
			assert.are.equal("disabled", store.entries[I.wake_up].state)
			assert.are.equal("Disabled in Hue: Wake Weekdays. It stays on the bridge and shows as off in the Hue app; Hue "
				.. "Automations ▸ Restore turns it on again. It also controlled Bedroom Ceiling and Bedside, which Control4 "
				.. "does not control: they no longer follow it either.", text)
			assert.are.equal("disabled", group_of(I.wake_up))
			assert.truthy(find(a:list_items(), "Disabled by Control4 " .. day(T0) .. ": Wake Weekdays (wake up)"))
			assert.are.same({ "1 Hue automation acts on Control4 lights: Hallway sensor (Hue Automations)" },
				a:attention_items())
			assert.is_true(changed > 0)
		end)

		it("R2: 2xx while the read-back still shows enabled: refused mark, Hue app steps, nothing kept (D12)", function()
			bridge.put[I.wake_up] = "ignore"
			local text = run("off:" .. I.wake_up)
			assert.are.equal("Not disabled: Wake Weekdays: the bridge accepted the change but did not apply it; nothing "
				.. "was changed. In the Hue app: Automations, Wake Weekdays, switch it off.", text)
			assert.is_nil(store.entries[I.wake_up])
			assert.are.equal(firmware, store.refused[I.wake_up])
			-- The next click writes nothing: Hue app only on this firmware.
			requests = {}
			text = run("off:" .. I.wake_up)
			assert.are.equal(0, #requests)
			assert.truthy(text:find("Hue app only", 1, true), text)
			assert.truthy(find(a:list_items(), "Wake Weekdays (wake up) on Bed Lamp, Bedroom Ceiling, Bedside (Hue app only)"))
		end)

		it("R3: a 4xx is quoted and marked Hue app only", function()
			bridge.put[I.wake_up] = "refuse"
			assert.are.equal("Not disabled: Wake Weekdays: the bridge refused (HTTP 400: invalid value for enabled); "
				.. "nothing was changed. In the Hue app: Automations, Wake Weekdays, switch it off.", run("off:" .. I.wake_up))
			assert.is_nil(store.entries[I.wake_up])
			assert.are.equal(firmware, store.refused[I.wake_up])
		end)

		it("R4: no answer leaves the entry pending, resolved by the next read without a second PUT", function()
			bridge.put[I.wake_up] = "silent_applied"
			assert.are.equal("Disable of Wake Weekdays not confirmed; Control4 checks again when the bridge answers.",
				run("off:" .. I.wake_up))
			assert.are.equal("pending", store.entries[I.wake_up].state)
			assert.truthy(a:summary():find(", 1 not confirmed", 1, true))
			assert.truthy(find(a:list_items(), "Not confirmed: Wake Weekdays"))
			assert.is_nil(find(a:attention_items(), "not confirmed"))
			now = T0 + 599
			assert.is_nil(find(a:attention_items(), "not confirmed"))
			now = T0 + 600
			assert.are.equal("1 Hue automation change not confirmed: Wake Weekdays (Hue Automations)",
				find(a:attention_items(), "not confirmed"))
			resync()
			assert.are.equal(1, #puts())
			assert.are.equal("disabled", store.entries[I.wake_up].state)
		end)

		it("R4: a pending disable the next read shows not applied is forgotten, never sent again", function()
			bridge.put[I.wake_up] = "silent"
			run("off:" .. I.wake_up)
			assert.are.equal("pending", store.entries[I.wake_up].state)
			resync()
			assert.is_nil(store.entries[I.wake_up])
			assert.are.equal(1, #puts())
			assert.are.equal("conflict", group_of(I.wake_up))
		end)

		it("R5: every one listed, one at a time, mixed results, no rollback", function()
			c4.lights[L.living_lamp] = "Living Lamp C4"
			bridge.put[I.schedule] = "refuse"
			local text = run("off:all")
			-- coming home, evening lights, wake up (class Disable), then the Hue app only conflicts.
			assert.are.equal(3, #puts())
			assert.truthy(text:find("^Disabled 2 of %d+ Hue automations: Coming home, Wake Weekdays%. Not disabled: "), text)
			assert.truthy(text:find("Evening lights (refused (HTTP 400: invalid value for enabled))", 1, true), text)
			assert.truthy(text:find("Hallway sensor (Hue app only; open it again for the steps)", 1, true), text)
			assert.are.equal("disabled", store.entries[I.coming_home].state)
			assert.are.equal("disabled", store.entries[I.wake_up].state)
			assert.is_nil(store.entries[I.schedule])
		end)

		it("R5: a bridge that stops answering ends the run; the rest are not tried", function()
			c4.lights[L.living_lamp] = "Living Lamp C4"
			bridge.put[I.coming_home] = "silent"
			local text = run("off:all")
			assert.are.equal(1, #puts())
			assert.truthy(text:find("Coming home (not confirmed)", 1, true), text)
			assert.truthy(text:find("Wake Weekdays (not tried)", 1, true), text)
		end)

		it("Hue app steps for an automation the API cannot switch off: nothing written (D6, H13, H15, H16)", function()
			c4.lights[L.kitchen1] = "Kitchen One"
			stream("update", { A.updates.configuration("motionaware_before") })
			requests = {}
			local text = run("off:" .. I.motionaware)
			assert.truthy(text:find("^Kitchen motion area is a MotionAware set%-up the bridge does not let other apps "
				.. "switch off%."), text)
			assert.truthy(text:find("Do not switch the area off", 1, true))
			text = run("off:" .. I.motion_sensor)
			assert.truthy(text:find("^Hallway sensor's behaviour is a sensor set%-up%."), text)
			text = run("off:" .. I.dimmer)
			assert.truthy(text:find("^Bedroom dimmer is a Hue switch%."), text)
			assert.are.equal(0, #requests)
		end)

		it("refuses with nothing written: already disabled, not a conflict, the bridge not answering", function()
			assert.truthy(run("off:" .. I.schedule):find("no longer acts by itself on Control4 lights", 1, true))
			bridge.instances[I.wake_up].enabled = false
			assert.are.equal("Not disabled: Wake Weekdays is already disabled in Hue; nothing was changed.",
				run("off:" .. I.wake_up))
			bridge.instances[I.wake_up].enabled = true
			resync()
			bridge.down = true
			assert.are.equal("Not disabled: the Hue bridge is not answering; nothing was changed.", run("off:" .. I.wake_up))
			assert.are.equal(0, #puts())
			assert.is_nil(store and store.entries[I.wake_up])
		end)

		it("R9: refused while busy, and while another click runs", function()
			busy = "Busy: reading the bridge; try again in a moment"
			assert.are.equal(busy, run("off:" .. I.wake_up))
			busy = nil
			bridge.hold = true
			run("off:" .. I.wake_up)
			assert.are.equal("Busy: changing a Hue automation; try again in a moment", run("off:" .. I.motion_sensor))
			bridge.hold = false
			while #held > 0 do
				release()
			end
			assert.are.equal("disabled", store.entries[I.wake_up].state)
			assert.are.equal(1, #puts())
		end)

		it("not paired: nothing is sent", function()
			paired = false
			assert.are.equal("Not paired; nothing was changed.", run("off:" .. I.wake_up))
			assert.are.equal(0, #requests)
		end)
	end)

	-- Restore (R6, R7, D16, D24) ---------------------------------------------------------------------

	describe("restore", function()
		before_each(function()
			resync()
		end)

		it("R6: the entry persisted restoring before the PUT; cleared after the read-back", function()
			c4.lights[L.living_lamp] = "Living Lamp C4"
			run("off:" .. I.schedule)
			c4.lights[L.living_lamp] = nil -- R6 without the keep: no longer on Control4 lights
			assert.truthy(find(a:list_items(), "Evening lights (schedule) on Desk Lamp, Living Lamp; no longer on Control4 "
				.. "lights"))
			requests = {}
			local text = run("on:" .. I.schedule)
			assert.are.same({ "GET", "PUT", "GET" }, { requests[1].method, requests[2].method, requests[3].method })
			assert.are.same({ enabled = true }, requests[2].body)
			assert.are.equal("restoring", requests[2].saved.entries[I.schedule].state)
			assert.are.equal("Turned on again in Hue: Evening lights (disabled by Control4 since " .. day(T0) .. "). It "
				.. "changed in Hue while it was off (its lights); it is on as it is now.", text)
			assert.is_nil(store.entries[I.schedule])
			assert.is_nil(store.kept[I.schedule])
		end)

		it("R7: restored as it is now; Last Action names a new name and new settings", function()
			run("off:" .. I.wake_up)
			stream("update", { A.updates.name("wake_up", "Wake Early") })
			local item = A.updates.configuration("wake_up")
			item.configuration.fade_in_duration = { seconds = 900 }
			stream("update", { item })
			bridge.instances[I.wake_up].metadata.name = "Wake Early"
			bridge.instances[I.wake_up].configuration.fade_in_duration = { seconds = 900 }
			assert.truthy(find(a:list_items(), "Disabled by Control4 " .. day(T0) .. ": Wake Early (wake up) on Bed Lamp, "
				.. "Bedroom Ceiling, Bedside; changed in Hue since"))
			local picker = a:picker("f:on")
			assert.are.equal("Wake Early (disabled " .. day(T0) .. "; changed in Hue since)", picker[2].text)
			local text = run("on:" .. I.wake_up)
			assert.truthy(text:find("^Turned on again in Hue: Wake Early %(was Wake Weekdays%) %(disabled by Control4 since "),
				text)
			assert.truthy(text:find("It changed in Hue while it was off (its name); it is on as it is now.", 1, true), text)
		end)

		it("R6: deleted in Hue meanwhile: the entry is cleared, nothing written", function()
			run("off:" .. I.wake_up)
			bridge.instances[I.wake_up] = nil
			requests = {}
			assert.are.equal("Nothing to restore: Wake Weekdays is no longer on the bridge; Control4 forgot its record.",
				run("on:" .. I.wake_up))
			assert.is_nil(store.entries[I.wake_up])
			assert.are.equal(0, #puts())
		end)

		it("R6: on again outside Control4: forgets the record, nothing written", function()
			run("off:" .. I.wake_up)
			bridge.instances[I.wake_up].enabled = true
			stream("update", { A.updates.enabled("wake_up", true) })
			local picker = a:picker("f:on")
			assert.are.equal("Wake Weekdays (on again outside Control4: forgets the record)", picker[2].text)
			requests = {}
			local text = run("on:" .. I.wake_up)
			assert.truthy(text:find("^Wake Weekdays is already on in Hue; Control4 forgot its record%."), text)
			assert.are.equal(0, #puts())
			assert.is_nil(store.entries[I.wake_up])
		end)

		it("on:all restores every entry", function()
			c4.lights[L.living_lamp] = "Living Lamp C4"
			run("off:all")
			local text = run("on:all")
			assert.truthy(text:find("^Turned on again 3 of 3 Hue automations: "), text)
			assert.truthy(text:find("Kept on the Hue side because they act on Control4 lights:", 1, true), text)
			assert.are.same({}, store.entries)
		end)

		it("D16: a schedule disabled outside Control4 is offered and turned on with no entry", function()
			local top = a:picker("f:on")
			assert.are.same({ text = "Disabled outside Control4 (1)", value = "f:on:other", folder = true }, top[2])
			local list, back = a:picker("f:on:other")
			assert.are.equal("f:on", back)
			assert.are.equal("Back to Restore", list[1].text)
			assert.are.same({ text = "Vacation lights (schedule; not disabled by Control4)", value = "other:" .. I.vacation },
				list[2])
			requests = {}
			assert.are.equal("Turned on again in Hue: Vacation lights (it was not disabled by Control4).",
				run("other:" .. I.vacation))
			assert.are.same({ enabled = true }, puts()[1].body)
			assert.is_nil(store and store.entries[I.vacation])
			assert.are.equal("elsewhere", group_of(I.vacation))
		end)

		it("D24: another bridge's record is shown, offered for Forget, and never acted on", function()
			store = { v = 1, bridge_id = OTHER_BRIDGE, entries = { [I.wake_up] = { state = "disabled", name = "Old wake",
				kind = "wake up", lights = {}, at = T0 } }, kept = {}, refused = {}, other = {} }
			new_module()
			assert.are.equal(BRIDGE, store.bridge_id)
			assert.are.same({}, store.entries)
			resync()
			assert.truthy(find(a:list_items(), "Bridge …9999: 1 automation Control4 disabled there"))
			local list = a:picker("f:on")
			assert.are.same({ text = "Forget the record of bridge …9999 (1 automation)", value = "forget:" .. OTHER_BRIDGE },
				list[#list])
			requests = {}
			assert.are.equal("Forgot the record of bridge …9999 (1 automation); nothing was changed in Hue.",
				run("forget:" .. OTHER_BRIDGE))
			assert.are.equal(0, #requests)
			assert.is_nil(store.other[OTHER_BRIDGE])
			assert.is_nil(find(a:list_items(), "Bridge …9999"))
		end)
	end)

	-- Lifecycle ----------------------------------------------------------------------------------------

	describe("lifecycle", function()
		before_each(function()
			resync()
			run("off:" .. I.wake_up)
			requests = {}
		end)

		it("H6: turned on again outside Control4: on again, Attention, an offer, and no write (D14)", function()
			bridge.instances[I.wake_up].enabled = true
			assert.is_true(stream("update", { A.updates.enabled("wake_up", true) }))
			assert.are.equal("on_again", store.entries[I.wake_up].state)
			assert.are.equal(T0, store.entries[I.wake_up].on_again_at)
			assert.are.same({ "1 Hue automation acts on Control4 lights: Hallway sensor (Hue Automations)",
				"1 Hue automation Control4 disabled is on again: Wake Weekdays (turned on outside Control4; "
				.. "Hue Automations)" }, a:attention_items())
			assert.truthy(find(a:list_items(), "On again outside Control4: Wake Weekdays"))
			assert.truthy(a:summary():find(", 1 on again", 1, true))
			local off = a:picker("f:off")
			local line
			for _, e in ipairs(off) do
				if e.value == "off:" .. I.wake_up then
					line = e.text
				end
			end
			assert.are.equal("Wake Weekdays (wake up) on Bed Lamp; also 2 lights outside Control4 (on again outside "
				.. "Control4)", line)
			resync()
			assert.are.equal(0, #puts())
			-- Keep drops the entry.
			run("keep:" .. I.wake_up)
			assert.is_nil(store.entries[I.wake_up])
			assert.are.equal("kept", group_of(I.wake_up))
		end)

		it("H6: Disable again is a click away", function()
			bridge.instances[I.wake_up].enabled = true
			stream("update", { A.updates.enabled("wake_up", true) })
			run("off:" .. I.wake_up)
			assert.are.equal(1, #puts())
			assert.are.equal("disabled", store.entries[I.wake_up].state)
		end)

		it("H10, D23: a successful read without the instance drops the entry with one log.always line", function()
			bridge.instances[I.wake_up] = nil
			bridge.down = true
			resync()
			assert.is_not_nil(store.entries[I.wake_up])
			bridge.down = false
			logged = {}
			resync()
			assert.is_nil(store.entries[I.wake_up])
			local lines = 0
			for _, line in ipairs(logged) do
				if line:find("Wake Weekdays, which Control4 disabled, was deleted in Hue", 1, true) then
					lines = lines + 1
				end
			end
			assert.are.equal(1, lines)
			assert.truthy(find(a:list_items(), "Deleted in Hue since Control4 disabled it: Wake Weekdays"))
		end)

		it("H4: an edit in Hue while disabled is shown as changed since", function()
			stream("update", { A.updates.name("wake_up", "Wake Late") })
			assert.truthy(find(a:list_items(), "Wake Late (wake up)"))
			assert.truthy(find(a:list_items(), "; changed in Hue since"))
		end)

		it("C8, C9: Forget Pairing and removal name what stays disabled", function()
			assert.are.equal("Control4 still has 1 Hue automation disabled on this bridge: Wake Weekdays; pair again to "
				.. "restore it, or turn it on in the Hue app", a:forget_pairing_text())
			assert.are.equal("The Hue Bridge driver was removed while Control4 had 1 Hue automation disabled on the bridge: "
				.. "Wake Weekdays. It stays off; turn it on in the Hue app", a:removal_text())
			run("on:" .. I.wake_up)
			assert.is_nil(a:forget_pairing_text())
			assert.is_nil(a:removal_text())
		end)

		it("C6: the record survives a restart; a pending entry is resolved by the first read", function()
			store.entries[I.wake_up].state = "pending"
			new_module()
			resync()
			assert.are.equal("disabled", store.entries[I.wake_up].state)
			assert.are.equal(0, #puts())
		end)
	end)

	-- D12 -----------------------------------------------------------------------------------------------

	it("D12: a refusal mark is cleared by a firmware change, and the next click tries again", function()
		resync()
		bridge.put[I.wake_up] = "refuse"
		run("off:" .. I.wake_up)
		assert.are.equal(firmware, store.refused[I.wake_up])
		firmware = "1.71.1971000000"
		bridge.put[I.wake_up] = nil
		resync()
		assert.is_nil(store.refused[I.wake_up])
		requests = {}
		run("off:" .. I.wake_up)
		assert.are.equal(1, #puts())
		assert.are.equal("disabled", store.entries[I.wake_up].state)
	end)

	-- The picker (§6.2) --------------------------------------------------------------------------------

	describe("picker", function()
		it("one explanatory row while not paired, not read, or with nothing to act on", function()
			paired = false
			assert.are.same({ { text = "(not paired)", value = "" } }, (a:picker("")))
			paired = true
			assert.are.same({ { text = automations.NOT_READ, value = "" } }, (a:picker("")))
			reset_bridge({ "motionaware_after", "vacation" })
			bridge.scripts = A.scripts()
			bridge.instances[I.vacation] = nil
			resync()
			assert.are.same({ { text = "(no Hue automations to act on)", value = "" } }, (a:picker("")))
			assert.are.equal("(no Hue automations to act on)", run(""))
		end)

		it("folder labels; empty folders left out", function()
			resync()
			local list, back = a:picker("")
			assert.is_nil(back)
			assert.are.same({
				{ text = "Disable in Hue (6 on Control4 lights)", value = "f:off", folder = true },
				{ text = "Restore (0 disabled by Control4)", value = "f:on", folder = true },
				{ text = "Keep on the Hue side (7)", value = "f:keep", folder = true },
			}, list)
			run("off:" .. I.wake_up)
			run("keep:" .. I.dimmer)
			list = a:picker("")
			assert.are.equal("Disable in Hue (4 on Control4 lights)", list[1].text)
			assert.are.equal("Restore (1 disabled by Control4)", list[2].text)
			assert.are.equal("Keep on the Hue side (5)", list[3].text)
			assert.are.same({ text = "Stop keeping (1)", value = "f:unkeep", folder = true }, list[4])
		end)

		it("a folder list starts with its Back row; class Disable first, Hue app only last", function()
			resync()
			local list, back = a:picker("f:off")
			assert.are.equal("", back)
			assert.are.same({ text = "Back to all folders", value = automations.TOP, folder = true }, list[1])
			assert.are.equal("off:" .. I.wake_up, list[2].value)
			assert.truthy(list[#list].text:find("(Hue app only)", 1, true))
			-- The top itself, from the Back row.
			assert.are.equal("f:off", (a:picker(automations.TOP))[1].value)
		end)

		it("a folder picked directly writes nothing", function()
			resync()
			requests = {}
			assert.are.equal("Not changed: Disable in Hue is a folder; open it and pick one inside", run("f:off"))
			assert.are.equal("Not changed: Restore is a folder; open it and pick one inside", run("f:on"))
			assert.are.equal("Not changed: Keep on the Hue side is a folder; open it and pick one inside", run("f:keep"))
			assert.are.equal(0, #requests)
		end)

		it("bulk rows appear for two or more", function()
			resync()
			assert.is_nil(find((function()
				local texts = {}
				for _, e in ipairs(a:picker("f:off")) do texts[#texts + 1] = e.text end
				return texts
			end)(), "Every one Control4 can disable"))
			c4.lights[L.living_lamp] = "Living Lamp C4"
			local list = a:picker("f:off")
			assert.are.same({ text = "Every one Control4 can disable (3)", value = "off:all" }, list[2])
		end)
	end)

	-- The row and Attention (§6.3, §6.4) -----------------------------------------------------------------

	describe("row", function()
		it("summary: before the first read, unpaired, and after it", function()
			assert.are.equal("Not read yet", a:summary())
			paired = false
			assert.are.equal("Not paired", a:summary())
			paired = true
			resync()
			assert.are.equal("15 on bridge, 7 on Control4 lights, 0 disabled by Control4", a:summary())
		end)

		it("summary stays within 75 characters with every count and a failed read", function()
			resync()
			c4.lights[L.living_lamp] = "Living Lamp C4"
			run("off:" .. I.wake_up)
			run("off:" .. I.coming_home)
			bridge.put[I.schedule] = "silent"
			run("off:" .. I.schedule)
			bridge.instances[I.wake_up].enabled = true
			stream("update", { A.updates.enabled("wake_up", true) })
			run("keep:" .. I.dimmer)
			bridge.down = true
			now = T0 + 60
			resync()
			local s = a:summary()
			assert.truthy(#s <= 75, s)
			assert.truthy(s:find("on again", 1, true), s)
			assert.truthy(s:find("1 kept", 1, true), s)
			assert.truthy(s:find("unconfirmed", 1, true), s)
			assert.truthy(s:find(os.date("%H:%M", T0), 1, true), s)
		end)

		it("the drop-down follows the order of §6.3; the coverage line is always last", function()
			resync()
			run("off:" .. I.wake_up)
			run("keep:" .. I.timer)
			local items = a:list_items()
			local order = { "On Control4 lights: ", "Disabled by Control4 ", "Kept: ", "Shared (a person starts it): ",
				"Does nothing: Kitchen motion area (MotionAware), Control4 decides (Control4 device: Kitchen Motion)",
				"Safety lighting (kept): Smoke alarm lights", "Disabled outside Control4: Vacation lights",
				"Elsewhere: ", "Not audited: 1 entertainment setting" }
			local pos = 0
			for _, prefix in ipairs(order) do
				local found
				for i = pos + 1, #items do
					if items[i]:sub(1, #prefix) == prefix then
						found = i
						break
					end
				end
				assert.is_not_nil(found, prefix)
				pos = found
			end
			assert.are.equal(automations.COVERAGE, items[#items])
		end)

		it("Attention: singular and plural; never shared, kept, inert, safety, outside or elsewhere (§6.4)", function()
			resync()
			assert.are.same({ "2 Hue automations act on Control4 lights: Hallway sensor, Wake Weekdays (Hue Automations)" },
				a:attention_items())
			run("keep:" .. I.motion_sensor)
			assert.are.same({ "1 Hue automation acts on Control4 lights: Wake Weekdays (Hue Automations)" },
				a:attention_items())
			run("keep:" .. I.wake_up)
			assert.are.same({}, a:attention_items())
		end)
	end)

	-- Load (L83, D24) -----------------------------------------------------------------------------------

	describe("load", function()
		it("drops malformed parts with a log line", function()
			store = { v = 1, bridge_id = BRIDGE,
				entries = { [I.wake_up] = { state = "disabled", name = "Wake Weekdays", at = T0 }, bad = { state = "odd" },
					[I.schedule] = "not a table" },
				kept = { [I.dimmer] = { name = "Bedroom dimmer", lights = { [L.hall_lamp] = true } }, x = 5 },
				refused = { [I.timer] = "1.70", y = {} }, other = 7 }
			logged = {}
			new_module()
			assert.are.same({ I.wake_up }, (function()
				local keys = {}
				for k in pairs(a.rec.entries) do keys[#keys + 1] = k end
				return keys
			end)())
			assert.is_not_nil(a.rec.kept[I.dimmer])
			assert.are.equal("1.70", a.rec.refused[I.timer])
			assert.truthy(find(logged, "malformed parts of the stored record dropped"))
		end)

		it("drops a record of the wrong version or type", function()
			store = { v = 2 }
			logged = {}
			new_module()
			assert.are.same({}, a.rec.entries)
			assert.truthy(find(logged, "malformed; dropped"))
			store = "garbage"
			new_module()
			assert.are.same({}, a.rec.entries)
		end)

		it("another bridge's record is set aside as `other` (D24); pairing back takes it back", function()
			store = { v = 1, bridge_id = OTHER_BRIDGE, entries = { [I.wake_up] = { state = "disabled", name = "W",
				at = T0 } } }
			new_module()
			assert.is_not_nil(store.other[OTHER_BRIDGE].entries[I.wake_up])
			ctx.bridge_id = function() return OTHER_BRIDGE end
			a:evaluate()
			assert.are.equal(OTHER_BRIDGE, store.bridge_id)
			assert.is_not_nil(store.entries[I.wake_up])
		end)
	end)

	-- No write without a click (D1, D2) -----------------------------------------------------------------

	it("never sends a PUT from load, resync, on_container, evaluate or the rows (D1)", function()
		store = { v = 1, bridge_id = BRIDGE, entries = {
			[I.wake_up] = { state = "disabled", name = "Wake Weekdays", at = T0 },
			[I.schedule] = { state = "pending", name = "Evening lights", at = T0 },
			[I.coming_home] = { state = "restoring", name = "Coming home", at = T0 },
			[I.timer] = { state = "on_again", name = "Hall timer", at = T0 },
		}, kept = { [I.dimmer] = { name = "Bedroom dimmer", lights = {} } }, refused = {}, other = {} }
		new_module()
		c4.lights[L.living_lamp] = "Living Lamp C4"
		resync()
		local function touch()
			a:evaluate()
			a:summary()
			a:list_items()
			a:attention_items()
			a:picker("")
			a:picker("f:off")
			a:picker("f:on")
			a:picker("f:keep")
		end
		touch()
		for _, key in ipairs({ "wake_up", "dimmer", "schedule", "timer", "coming_home", "mimic_started", "mimic_stopped",
			"tap_dial", "motionaware_before", "motionaware_after", "motion_sensor", "streaming", "unknown", "smoke_alarm",
			"go_to_sleep", "vacation", "natural_light" }) do
			stream("add", { A.instance(key) })
			stream("update", { A.updates.enabled(key, false) })
			stream("update", { A.updates.enabled(key, true) })
			stream("update", { A.updates.name(key, "Renamed " .. key) })
			stream("update", { A.updates.configuration(key) })
			touch()
		end
		stream("update", { A.updates.pm_state("started") })
		stream("add", A.scripts())
		fire_timers()
		for _, key in ipairs({ "wake_up", "dimmer", "schedule", "timer" }) do
			stream("delete", { A.updates.delete(key) })
		end
		touch()
		resync()
		touch()
		assert.are.equal(0, count("PUT"))
		assert.are.equal(0, count("POST"))
		assert.are.equal(0, count("DELETE"))
		assert.is_false(stream("update", "not a list"))
		assert.is_false(a:on_container(nil))
	end)
end)
