-- bridge/automation_model.lua (docs/hue-automation-audit-design.md §6.1,
-- the test list of §8): parsing and classifying Hue behaviour scripts and
-- instances. The fixtures are tests/fixtures/hue_automations.lua, in the
-- shapes of docs/hue-automations-research.md §1.4 and §1.8 and the house's
-- MotionAware instance (contract H3, H4).

local json = require("dkjson")
local log = require("common.log")
local A = require("fixtures.hue_automations")

describe("bridge.automation_model", function()
	local model

	before_each(function()
		log.sink = function() end
		package.loaded["bridge.automation_model"] = nil
		model = require("bridge.automation_model")
	end)

	local function script(key)
		return model.script(A.script(key))
	end

	local function inst(key)
		return model.instance(A.instance(key))
	end

	-- The script record an instance fixture runs (nil for the unknown one,
	-- whose script no GET listed).
	local SCRIPT_OF = {
		wake_up = "wake_up", go_to_sleep = "go_to_sleep", schedule = "schedule", vacation = "schedule",
		timer = "timers", coming_home = "coming_home", mimic_started = "mimic", mimic_stopped = "mimic",
		dimmer = "hue_accessories", tap_dial = "tap_switch", motionaware_before = "hue_accessories",
		motionaware_after = "hue_accessories", motion_sensor = "motion_sensor", streaming = "streaming",
		natural_light = "natural_light", smoke_alarm = "smoke_alarm",
	}

	local function pair(key)
		return inst(key), SCRIPT_OF[key] and script(SCRIPT_OF[key]) or nil
	end

	local function ref_set(refs, where)
		local out = {}
		for _, r in ipairs(refs) do
			if where == nil or r.where == where then
				out[r.rid .. "|" .. r.rtype] = true
			end
		end
		return out
	end

	local function count(t)
		local n = 0
		for _ in pairs(t) do
			n = n + 1
		end
		return n
	end

	describe("script", function()
		it("reads id, name, category and version", function()
			local s = script("wake_up")
			assert.equal(A.ids.scripts.wake_up, s.rid)
			assert.equal("Basic wake up routine", s.name)
			assert.equal("automation", s.category)
			assert.equal("0.0.1", s.version)
			assert.is_nil(s.max_instances)
			assert.equal(1, script("mimic").max_instances)
			assert.equal("accessory", script("tap_switch").category)
			assert.equal("entertainment", script("streaming").category)
			assert.equal("other", script("custom").category)
		end)

		it("reads an empty category as empty, a missing one as empty, an unknown one as other", function()
			assert.equal("", script("natural_light").category)
			local item = A.script("schedule")
			item.metadata.category = nil
			assert.equal("", model.script(item).category)
			item.metadata.category = "lighting_magic"
			assert.equal("other", model.script(item).category)
			item.metadata.category = 7
			assert.equal("", model.script(item).category)
			item.metadata = nil
			local s = model.script(item)
			assert.equal("", s.category)
			assert.equal("", s.name)
		end)

		it("drops an item without a resource id", function()
			assert.is_nil(model.script({ metadata = { name = "x" } }))
			assert.is_nil(model.script({ id = "../x", metadata = { name = "x" } }))
			assert.is_nil(model.script({ id = {} }))
			assert.is_nil(model.script("nope"))
			assert.is_nil(model.script(nil))
		end)
	end)

	describe("instance", function()
		it("reads the plain fields", function()
			local i = inst("wake_up")
			assert.equal(A.ids.instances.wake_up, i.rid)
			assert.equal(A.ids.scripts.wake_up, i.script_rid)
			assert.equal("Wake Weekdays", i.name)
			assert.is_true(i.enabled)
			assert.equal("running", i.status)
			assert.equal("", i.last_error)
			assert.is_nil(i.pm_state)
			assert.is_true(i.migrated)
			assert.is_false(inst("schedule").migrated)
			assert.is_false(inst("vacation").enabled)
			assert.equal("disabled", inst("vacation").status)
			assert.equal("started", inst("mimic_started").pm_state)
			assert.equal("stopped", inst("mimic_stopped").pm_state)
			assert.equal("stopped", inst("timer").timer_state)
			assert.equal("string", type(i.sig))
		end)

		it("reads an errored instance's last error, cleaned for a row", function()
			local item = A.instance("schedule")
			item.status = "errored"
			item.last_error = "scene\nnot found"
			local i = model.instance(item)
			assert.equal("errored", i.status)
			assert.equal("scenenot found", i.last_error)
		end)

		it("drops an item without a resource id and survives missing blocks", function()
			assert.is_nil(model.instance({ script_id = A.ids.scripts.schedule }))
			assert.is_nil(model.instance({ id = "a b" }))
			assert.is_nil(model.instance(false))
			local i = model.instance({ id = A.ids.instances.schedule })
			assert.same({}, i.refs)
			assert.same({}, i.actions)
			assert.is_false(i.enabled)
			assert.is_nil(i.script_rid)
			assert.equal("", i.name)
			local j = model.instance({ id = A.ids.instances.schedule, configuration = "junk", dependees = 5,
				state = "x", status = "bad status", metadata = "y" })
			assert.same({}, j.refs)
			assert.is_nil(j.status)
			assert.is_nil(j.pm_state)
		end)
	end)

	describe("refs", function()
		it("lists every {rid, rtype} in the configuration and in the dependees", function()
			local i = inst("wake_up")
			local R, L = A.ids.rooms, A.ids.lights
			assert.same({
				[R.bedroom .. "|room"] = true, [L.bedroom_lamp .. "|light"] = true, [L.bedside .. "|light"] = true,
			}, ref_set(i.refs, "configuration"))
			assert.same(ref_set(i.refs, "configuration"), ref_set(i.refs, "dependee"))
			assert.equal(6, #i.refs)
			for _, r in ipairs(i.refs) do
				if r.where == "dependee" then
					assert.equal("critical", r.level)
				else
					assert.is_nil(r.level)
				end
			end
		end)

		it("finds references nested anywhere: what/recall, button slots, a switch's device", function()
			local s = ref_set(inst("schedule").refs, "configuration")
			assert.is_true(s[A.ids.scenes.living_evening .. "|scene"])
			assert.is_true(s[A.ids.rooms.living .. "|room"])
			local d = ref_set(inst("dimmer").refs, "configuration")
			assert.is_true(d[A.ids.scenes.downstairs_bright .. "|scene"])
			assert.is_true(d[A.ids.switch_devices.dimmer .. "|device"])
			assert.is_true(d[A.ids.zones.downstairs .. "|zone"])
			local t = ref_set(inst("tap_dial").refs, "configuration")
			assert.is_true(t[A.ids.scenes.kitchen_night .. "|scene"], "scene_cycle_extended slots of lists")
			assert.is_true(t[A.ids.rooms.hallway .. "|room"], "button 3's own where")
			local m = ref_set(inst("motionaware_before").refs, "configuration")
			assert.is_true(m[A.ids.area .. "|motion_area_configuration"])
			assert.is_true(m[A.ids.convenience .. "|convenience_area_motion"])
			assert.is_true(m[A.ids.rooms.kitchen .. "|room"])
			assert.is_true(m[A.ids.scenes.kitchen_relax .. "|scene"])
		end)

		it("does not take a dimmer's button-id keys for references", function()
			local d = inst("dimmer")
			local conf = ref_set(d.refs, "configuration")
			for _, rid in pairs(A.ids.buttons) do
				assert.is_nil(conf[rid .. "|button"])
				for key in pairs(conf) do
					assert.is_nil(key:find(rid, 1, true), "button id taken from a key: " .. rid)
				end
			end
			-- The buttons come in only as dependees.
			local deps = ref_set(d.refs, "dependee")
			assert.is_true(deps[A.ids.buttons.dimmer1 .. "|button"])
			assert.equal(7, count(deps))
		end)

		it("skips malformed references and dependees", function()
			local item = A.instance("schedule")
			item.configuration.where[2] = { group = { rid = "../../etc", rtype = "room" } }
			item.configuration.where[3] = { group = { rid = A.ids.rooms.kitchen, rtype = "room type" } }
			item.configuration.where[4] = { group = { rid = A.ids.rooms.kitchen } }
			item.configuration.where[5] = { group = { rid = 12, rtype = "room" } }
			item.dependees[3] = "junk"
			item.dependees[4] = { type = "ResourceDependee", level = "critical" }
			item.dependees[5] = { type = "ResourceDependee", target = { rid = A.ids.rooms.kitchen, rtype = {} } }
			local i = model.instance(item)
			assert.same(ref_set(inst("schedule").refs), ref_set(i.refs))
			assert.equal(#inst("schedule").refs, #i.refs)
		end)

		it("takes a bare-identifier dependee (openhue's model)", function()
			local item = A.instance("go_to_sleep")
			item.dependees = { { rid = A.ids.rooms.kitchen, rtype = "room" } }
			local deps = ref_set(model.instance(item).refs, "dependee")
			assert.same({ [A.ids.rooms.kitchen .. "|room"] = true }, deps)
		end)

		it("lists each reference once per side, in a stable order", function()
			local a, b = inst("tap_dial"), inst("tap_dial")
			assert.same(a.refs, b.refs)
			local seen = {}
			for _, r in ipairs(a.refs) do
				local key = r.rid .. r.rtype .. r.where
				assert.is_nil(seen[key])
				seen[key] = true
			end
		end)

		it("stops at a runaway nesting depth", function()
			local item = A.instance("schedule")
			local node = item.configuration
			for _ = 1, 200 do
				node.deeper = {}
				node = node.deeper
			end
			node.group = { rid = A.ids.rooms.kitchen, rtype = "room" }
			local i = model.instance(item)
			assert.is_nil(ref_set(i.refs, "configuration")[A.ids.rooms.kitchen .. "|room"])
			assert.is_true(ref_set(i.refs, "configuration")[A.ids.rooms.living .. "|room"])
		end)
	end)

	describe("D4 rtypes", function()
		it("never counts a trigger rtype as a target", function()
			for rtype in pairs(model.trigger_rtypes) do
				assert.is_nil(model.target_rtypes[rtype], rtype)
				assert.is_nil(model.ignored_rtypes[rtype], rtype)
			end
			for _, rtype in ipairs({ "button", "relative_rotary", "motion", "convenience_area_motion",
				"security_area_motion", "motion_area_configuration", "contact", "camera_motion", "light_level",
				"geofence_client", "behavior_instance" }) do
				assert.is_true(model.trigger_rtypes[rtype], rtype)
			end
			for _, rtype in ipairs({ "light", "device", "room", "zone", "grouped_light", "scene", "smart_scene",
				"bridge_home" }) do
				assert.is_true(model.target_rtypes[rtype], rtype)
			end
		end)

		it("ignores entertainment_configuration and recipe: neither trigger nor target", function()
			for _, rtype in ipairs({ "entertainment_configuration", "recipe" }) do
				assert.is_true(model.ignored_rtypes[rtype])
				assert.is_nil(model.trigger_rtypes[rtype])
				assert.is_nil(model.target_rtypes[rtype])
			end
			-- They are still listed as references; the rtype tells the caller.
			local s = ref_set(inst("streaming").refs)
			assert.is_true(s[A.ids.entertainment .. "|entertainment_configuration"])
			assert.is_true(ref_set(inst("timer").refs)[A.ids.recipes.energize .. "|recipe"])
		end)

		it("leaves the MotionAware instance's room as its only target besides its scenes", function()
			local targets = {}
			for _, r in ipairs(inst("motionaware_after").refs) do
				if model.target_rtypes[r.rtype] then
					targets[r.rid .. "|" .. r.rtype] = true
				end
			end
			assert.same({ [A.ids.rooms.kitchen .. "|room"] = true }, targets)
		end)
	end)

	describe("is_ref", function()
		it("answers rid and rtype of a well-formed reference only", function()
			local rid, rtype = model.is_ref({ rid = A.ids.rooms.kitchen, rtype = "room" })
			assert.equal(A.ids.rooms.kitchen, rid)
			assert.equal("room", rtype)
			assert.is_nil(model.is_ref({ rid = A.ids.rooms.kitchen }))
			assert.is_nil(model.is_ref({ rid = "a/b", rtype = "room" }))
			assert.is_nil(model.is_ref("x"))
		end)
	end)

	describe("actions and D5 (does nothing)", function()
		it("collects the action words in order of appearance, each once", function()
			assert.same({ "recall", "all_off" }, inst("motionaware_before").actions)
			assert.same({ "do_nothing" }, inst("motionaware_after").actions)
			assert.same({ "recall", "do_nothing" }, inst("dimmer").actions)
			assert.same({ "recall", "all_off", "do_nothing", "dim_down", "dim_up" }, inst("tap_dial").actions)
			assert.same({}, inst("wake_up").actions)
			assert.same({}, inst("streaming").actions, "end_state is not an action")
		end)

		it("reads an action object by its first key, junk as unknown", function()
			local item = A.instance("dimmer")
			local buttons = item.configuration.buttons
			buttons[A.ids.buttons.dimmer2] = { on_repeat = { action = { scene_cycle = {} } } }
			buttons[A.ids.buttons.dimmer3] = { on_repeat = { action = "dim up!" } }
			buttons[A.ids.buttons.dimmer4] = { on_repeat = { action = 5 } }
			assert.same({ "recall", "scene_cycle", "unknown" }, model.instance(item).actions)
		end)

		it("calls the MotionAware set-up after Do nothing inert, and before it not", function()
			assert.is_true(model.inert(inst("motionaware_after")))
			assert.is_false(model.inert(inst("motionaware_before")))
		end)

		it("does not call a dimmer with one recall and three do_nothing inert", function()
			assert.is_false(model.inert(inst("dimmer")))
		end)

		it("never calls an automation without an action key inert", function()
			for _, key in ipairs({ "wake_up", "schedule", "timer", "coming_home", "go_to_sleep", "streaming",
				"natural_light", "smoke_alarm", "unknown" }) do
				assert.is_false(model.inert(inst(key)), key)
			end
			assert.is_false(model.inert({}))
			assert.is_false(model.inert(nil))
		end)

		it("calls a switch whose every button does nothing inert", function()
			local item = A.instance("dimmer")
			item.configuration.buttons[A.ids.buttons.dimmer1] = { on_short_release = { action = "do_nothing" } }
			assert.is_true(model.inert(model.instance(item)))
		end)
	end)

	describe("fires (D7)", function()
		local EXPECTED = {
			wake_up = "own", schedule = "own", vacation = "own", coming_home = "own",
			mimic_started = "own", motionaware_before = "own", motionaware_after = "own",
			motion_sensor = "own", natural_light = "own",
			go_to_sleep = "person", timer = "person", mimic_stopped = "person", dimmer = "person",
			tap_dial = "person",
			smoke_alarm = "safety",
			streaming = "none",
		}

		for key, want in pairs(EXPECTED) do
			it(key .. " fires " .. want, function()
				local i, s = pair(key)
				assert.equal(want, model.fires(i, s))
			end)
		end

		it("treats an instance of a script not read yet as firing on its own", function()
			assert.equal("own", model.fires(inst("unknown"), nil))
			assert.equal("own", model.fires(inst("unknown"), script("custom")))
		end)

		it("tells mimic presence started from stopped, even before its script is read", function()
			assert.equal("own", model.fires(inst("mimic_started"), nil))
			assert.equal("person", model.fires(inst("mimic_stopped"), nil))
		end)

		it("makes Go to sleep fire on its own once it has a time", function()
			local item = A.instance("go_to_sleep")
			item.configuration.when = { recurrence_days = { "sunday" },
				time_point = { type = "time", time = { hour = 22, minute = 0 } } }
			assert.equal("own", model.fires(model.instance(item), script("go_to_sleep")))
		end)

		it("reads a geofence or contact reference as firing on its own", function()
			local item = A.instance("go_to_sleep")
			item.dependees[2] = { type = "ResourceDependee", level = "non_critical",
				target = { rid = A.ids.rooms.kitchen, rtype = "geofence_client" } }
			assert.equal("own", model.fires(model.instance(item), script("go_to_sleep")))
			local contact = A.instance("go_to_sleep")
			contact.configuration.contact = { contact_service = { rid = A.ids.motion, rtype = "contact" } }
			assert.equal("own", model.fires(model.instance(contact), script("contact_sensor")))
		end)

		it("works on classification by shape when the category is missing (older firmware)", function()
			local s = A.script("streaming")
			s.metadata.category = nil
			assert.equal("none", model.fires(inst("streaming"), model.script(s)))
			assert.equal("none", model.fires(inst("streaming"), nil), "by the public id")
		end)
	end)

	describe("remedy (D6)", function()
		it("is disable only for automation-category, non-play/stop, non-safety scripts", function()
			local EXPECTED = {
				wake_up = "disable", schedule = "disable", vacation = "disable", coming_home = "disable",
				go_to_sleep = "disable",
				timer = "steps", mimic_started = "steps", mimic_stopped = "steps", smoke_alarm = "steps",
				dimmer = "steps", tap_dial = "steps", motionaware_before = "steps", motionaware_after = "steps",
				motion_sensor = "steps", streaming = "steps", natural_light = "steps",
			}
			for key, want in pairs(EXPECTED) do
				local i, s = pair(key)
				assert.equal(want, model.remedy(i, s), key)
			end
		end)

		it("gives steps while the script is not read, or is of another category", function()
			assert.equal("steps", model.remedy(inst("unknown"), nil))
			assert.equal("steps", model.remedy(inst("unknown"), script("custom")))
			assert.equal("steps", model.remedy(inst("schedule"), nil))
			local s = A.script("schedule")
			s.metadata.category = nil
			assert.equal("steps", model.remedy(inst("schedule"), model.script(s)), "no category: never written")
		end)

		it("gives steps for a play/stop instance whatever its script says", function()
			local item = A.instance("schedule")
			item.state = { pm_state = "stopped" }
			assert.equal("steps", model.remedy(model.instance(item), script("schedule")))
		end)
	end)

	describe("kind", function()
		local EXPECTED = {
			wake_up = "wake up", go_to_sleep = "go to sleep", schedule = "schedule", vacation = "schedule",
			timer = "timer", coming_home = "coming home", mimic_started = "mimic presence",
			mimic_stopped = "mimic presence", natural_light = "natural light",
			motionaware_before = "MotionAware", motionaware_after = "MotionAware",
			motion_sensor = "motion sensor", dimmer = "Hue switch", tap_dial = "Hue switch",
			smoke_alarm = "safety lighting", streaming = "Light state after streaming",
		}

		for key, want in pairs(EXPECTED) do
			it(key .. " is a " .. want, function()
				local i, s = pair(key)
				assert.equal(want, model.kind(i, s))
			end)
		end

		it("names a script not read yet 'automation', and by its name once read", function()
			assert.equal("automation", model.kind(inst("unknown"), nil))
			assert.equal("Custom behavior", model.kind(inst("unknown"), script("custom")))
		end)

		it("goes by shape before the script id: the dimmer and MotionAware share Hue Accessories", function()
			assert.equal(A.ids.scripts.hue_accessories, inst("dimmer").script_rid)
			assert.equal(A.ids.scripts.hue_accessories, inst("motionaware_after").script_rid)
			assert.equal("Hue switch", model.kind(inst("dimmer"), script("hue_accessories")))
			assert.equal("MotionAware", model.kind(inst("motionaware_after"), script("hue_accessories")))
			-- A wake-up script carrying a switch's shape is a switch.
			local item = A.instance("dimmer")
			item.script_id = A.ids.scripts.wake_up
			assert.equal("Hue switch", model.kind(model.instance(item), script("wake_up")))
		end)

		it("knows a public id under a new name, and a known name under a new id", function()
			local s = A.script("wake_up")
			s.metadata.name = "Sunrise routine 2"
			assert.equal("wake up", model.kind(inst("wake_up"), model.script(s)))
			assert.equal("wake up", model.kind(inst("wake_up"), nil), "the instance's script id alone")
			local renamed = A.script("custom")
			renamed.metadata.name = "Leaving home"
			assert.equal("leaving home", model.kind(inst("unknown"), model.script(renamed)))
		end)

		it("reads a contact sensor's set-up by shape", function()
			local item = A.instance("go_to_sleep")
			item.configuration.contact = { contact_service = { rid = A.ids.motion, rtype = "contact" } }
			assert.equal("contact sensor", model.kind(model.instance(item), script("contact_sensor")))
		end)

		it("falls back to 'automation' without a name", function()
			local s = A.script("custom")
			s.metadata.name = ""
			assert.equal("automation", model.kind(inst("unknown"), model.script(s)))
			assert.equal("automation", model.kind(nil, nil))
		end)
	end)

	describe("signature", function()
		it("is stable and ignores key order", function()
			local a = model.signature(A.instance("dimmer"))
			assert.equal(a, model.signature(A.instance("dimmer")))
			-- The same content decoded from text whose keys come in another order.
			local reordered = json.decode(json.encode(A.instance("dimmer"), { keyorder = { "where", "model_id" } }))
			assert.equal(a, model.signature(reordered))
			assert.equal(a, inst("dimmer").sig)
		end)

		it("follows configuration and name, not enabled, status or dependees", function()
			local base = model.signature(A.instance("schedule"))
			local item = A.instance("schedule")
			item.enabled = false
			item.status = "disabled"
			item.dependees = {}
			assert.equal(base, model.signature(item))
			item.metadata.name = "Evening lights 2"
			assert.not_equal(base, model.signature(item))
			local edited = A.instance("schedule")
			edited.configuration.when_extended.start_at.time_point.time.hour = 20
			assert.not_equal(base, model.signature(edited))
			assert.not_equal(model.signature(A.instance("motionaware_before")),
				model.signature(A.instance("motionaware_after")))
		end)

		it("tells types apart and survives junk", function()
			local a = { metadata = { name = "x" }, configuration = { n = 1 } }
			local b = { metadata = { name = "x" }, configuration = { n = "1" } }
			assert.not_equal(model.signature(a), model.signature(b))
			assert.equal("string", type(model.signature(nil)))
			assert.equal("string", type(model.signature({ configuration = "junk" })))
		end)
	end)

	describe("update", function()
		it("takes an enabled-only update", function()
			local i = inst("wake_up")
			local refs, sig = i.refs, i.sig
			local changed, fields = model.update(i, A.updates.enabled("wake_up", false))
			assert.is_true(changed)
			assert.is_true(fields.enabled)
			assert.is_true(fields.status)
			assert.is_false(i.enabled)
			assert.equal("disabled", i.status)
			assert.equal(refs, i.refs)
			assert.equal(sig, i.sig)
			assert.equal("Wake Weekdays", i.name)
			-- The same again changes nothing.
			changed, fields = model.update(i, A.updates.enabled("wake_up", false))
			assert.is_false(changed)
			assert.same({}, fields)
		end)

		it("works refs, actions and the signature out again from a configuration update", function()
			local i = inst("motionaware_before")
			local sig = i.sig
			local changed, fields = model.update(i, A.updates.configuration("motionaware_after"))
			assert.is_true(changed)
			assert.is_true(fields.refs)
			assert.is_true(fields.actions)
			assert.is_true(fields.sig)
			assert.is_nil(fields.enabled)
			assert.not_equal(sig, i.sig)
			assert.equal(inst("motionaware_after").sig, i.sig)
			assert.same(inst("motionaware_after").refs, i.refs)
			assert.is_true(model.inert(i))
			assert.equal("Kitchen motion area", i.name)
		end)

		it("changes only the signature and the name on a metadata.name update", function()
			local i = inst("wake_up")
			local refs = i.refs
			local changed, fields = model.update(i, A.updates.name("wake_up", "Wake Workdays"))
			assert.is_false(changed)
			assert.same({ name = true, sig = true }, fields)
			assert.equal("Wake Workdays", i.name)
			assert.equal(refs, i.refs)
			local renamed = A.instance("wake_up")
			renamed.metadata.name = "Wake Workdays"
			assert.equal(model.signature(renamed), i.sig)
		end)

		it("keeps the raw name for the signature across a configuration update", function()
			local item = A.instance("schedule")
			item.metadata.name = "Evening\tlights"
			local i = model.instance(item)
			assert.equal("Eveninglights", i.name)
			model.update(i, { id = item.id, configuration = item.configuration })
			assert.equal(model.signature(item), i.sig)
		end)

		it("reports mimic presence starting as a change", function()
			local i = inst("mimic_stopped")
			local changed, fields = model.update(i, A.updates.pm_state("started"))
			assert.is_true(changed)
			assert.is_true(fields.pm_state)
			assert.equal("own", model.fires(i, script("mimic")))
		end)

		it("reports a new dependee list and a new script", function()
			local i = inst("schedule")
			local changed, fields = model.update(i, { id = i.rid, dependees = { { type = "ResourceDependee",
				level = "critical", target = { rid = A.ids.rooms.living, rtype = "room" } } } })
			assert.is_true(changed)
			assert.is_true(fields.refs)
			assert.is_nil(ref_set(i.refs, "dependee")[A.ids.scenes.living_evening .. "|scene"])
			assert.is_true(ref_set(i.refs, "configuration")[A.ids.scenes.living_evening .. "|scene"])
			changed, fields = model.update(i, { id = i.rid, script_id = A.ids.scripts.wake_up })
			assert.is_true(changed)
			assert.is_true(fields.script)
			assert.equal(A.ids.scripts.wake_up, i.script_rid)
		end)

		it("ignores junk fields and junk arguments", function()
			local i = inst("schedule")
			local before = i.sig
			local changed, fields = model.update(i, { id = i.rid, enabled = "yes", configuration = "x",
				dependees = 3, metadata = { name = 5 }, state = "started", script_id = "a/b" })
			assert.is_false(changed)
			assert.same({}, fields)
			assert.equal(before, i.sig)
			assert.is_true(i.enabled)
			assert.is_false((model.update(nil, {})))
			assert.is_false((model.update(i, nil)))
		end)
	end)
end)
