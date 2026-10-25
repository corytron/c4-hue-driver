"""Unit tests for tools/smart_scene_probe.py: no network and no dev loop. FakeLoop stands in for
tools/devctl.py and the controller: it answers each queued Hue Request from FakeBridge and writes
the answer to a driver.log the way bridge/devtools.lua logs it (summary line, then the body in
800-character pieces; PUT, POST and DELETE answers end with a newline, as the bridge's do).

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import datetime
import io
import json
import math
import os
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import smart_scene_probe as probe  # noqa: E402

BRIDGE = "10.0.2.143"  # the documented placeholder address
ROOM = "aaaaaaaa-0000-4000-8000-00000000r001"
GROUPED = "aaaaaaaa-0000-4000-8000-00000000g001"
ZONE = "aaaaaaaa-0000-4000-8000-00000000z001"
DEVICES = ["aaaaaaaa-0000-4000-8000-00000000d00%d" % n for n in range(1, 5)]
LAMP = "aaaaaaaa-0000-4000-8000-00000000l001"  # colour lamp, mirek 153-500
FLOOR = "aaaaaaaa-0000-4000-8000-00000000l002"  # white ambiance, mirek 153-454
PLUG = "aaaaaaaa-0000-4000-8000-00000000l003"  # on/off only
HALL = "aaaaaaaa-0000-4000-8000-00000000l009"  # another room's light
SCENE_A = "aaaaaaaa-0000-4000-8000-00000000s00a"
SCENE_B = "aaaaaaaa-0000-4000-8000-00000000s00b"
SMART = "aaaaaaaa-0000-4000-8000-0000000ss001"
SUNDAY = datetime.datetime(2026, 10, 25, 14, 3, 20)
NOT_FOUND = '{"errors":[{"description":"Not Found"}]}'
EFFECTS = ["no_effect", "candle", "fire", "prism", "sparkle", "opal", "glisten", "underwater", "cosmos", "sunbeam"]


def compact(value):
    return json.dumps(value, separators=(",", ":"))


def ident(rid, rtype):
    return compact({"data": [{"rid": rid, "rtype": rtype}], "errors": []}) + "\n"


def answer_lines(method, path, code, body, stamp="12:00:00.000"):
    """What bridge/devtools.lua logs for one Hue Request with Raw=true (prefix "Hue Bridge: ")."""
    status = "HTTP %d" % code if code else "transfer failed (28): Timeout was reached"
    lines = [
        "%s Hue Bridge: Hue Request %s %s via %s: %s in 0 s, %d bytes: %s"
        % (stamp, method, path, BRIDGE, status, len(body), body[:300])
    ]
    pieces = math.ceil(len(body) / 800)
    for i in range(pieces):
        lines.append(
            "%s Hue Bridge: Hue Request body %d/%d: %s" % (stamp, i + 1, pieces, body[i * 800 : i * 800 + 800])
        )
    return "".join(line + "\n" for line in lines)


def light_item(rid, device, name, mirek_range=(153, 500), on=False, brightness=50.0):
    return {
        "id": rid,
        "type": "light",
        "owner": {"rid": device, "rtype": "device"},
        "metadata": {"name": name},
        "on": {"on": on},
        "dimming": {"brightness": brightness, "min_dim_level": 0.2},
        "color_temperature": {
            "mirek": 366,
            "mirek_valid": True,
            "mirek_schema": {"mirek_minimum": mirek_range[0], "mirek_maximum": mirek_range[1]},
        },
        "effects": {"status_values": EFFECTS, "status": "no_effect"},
    }


def info(rid, low=153, high=500, ct=True):
    return {"rid": rid, "name": rid[-4:], "on": False, "dims": True, "ct": ct, "mirek_min": low, "mirek_max": high}


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


class FakeBridge:
    """CLIP v2 resources in memory, answering the way the house bridge did (research §7)."""

    def __init__(self):
        self.items = {}
        self.calls = []
        self.serial = 0
        self.fail_post = set()
        self.locked = set()  # rids whose DELETE is refused
        self.advance_after = None  # slot B starts on the smart scene GET after this many
        self.smart_gets = 0
        self.add(
            {
                "id": ROOM,
                "type": "room",
                "metadata": {"name": "Office"},
                "children": [{"rid": device, "rtype": "device"} for device in DEVICES[:3]],
                "services": [{"rid": GROUPED, "rtype": "grouped_light"}],
            }
        )
        self.add(light_item(LAMP, DEVICES[0], "Desk Lamp"))
        self.add(light_item(FLOOR, DEVICES[1], "Floor Lamp", (153, 454)))
        self.add(
            {
                "id": PLUG,
                "type": "light",
                "owner": {"rid": DEVICES[2], "rtype": "device"},
                "metadata": {"name": "Plug"},
                "on": {"on": False},
            }
        )
        self.add(light_item(HALL, DEVICES[3], "Hall Lamp"))
        self.add(
            {"id": "aaaaaaaa-0000-4000-8000-00000000b001", "type": "bridge", "time_zone": {"time_zone": "EST5EDT"}}
        )

    def add(self, item):
        self.items[(item["type"], item["id"])] = item

    def light(self, rid):
        return self.items[("light", rid)]

    def apply(self, scene_rid):
        """Recall a scene: its actions on the lights, its status static, the group's others inactive."""
        scene = self.items[("scene", scene_rid)]
        for action in scene["actions"]:
            light = self.light(action["target"]["rid"])
            light["on"] = {"on": True}
            light["dimming"]["brightness"] = action["action"]["dimming"]["brightness"]
            if "color_temperature" in action["action"]:
                light["color_temperature"].update(
                    mirek=action["action"]["color_temperature"]["mirek"], mirek_valid=True
                )
        for (rtype, _), item in self.items.items():
            if rtype == "scene":
                item["status"] = {"active": "static" if item is scene else "inactive"}

    def answer(self, method, path, body):
        self.calls.append((method, path, body))
        parts = path[len(probe.RESOURCE) + 1 :].split("/")
        rtype, rid = parts[0], parts[1] if len(parts) > 1 else None
        item = self.items.get((rtype, rid))
        if method == "GET" and rid is None:
            return 200, compact({"errors": [], "data": [i for (t, _), i in self.items.items() if t == rtype]})
        if method == "POST":
            if rtype in self.fail_post:
                return 400, compact({"data": [], "errors": [{"description": "invalid " + rtype}]}) + "\n"
            self.serial += 1
            item = dict(json.loads(json.dumps(body)), id="bbbbbbbb-0000-4000-8000-%012d" % self.serial, type=rtype)
            self.add(item)
            if rtype == "scene":
                item["status"] = {"active": "inactive"}
            if rtype == "smart_scene":  # a new smart scene starts at once (V12)
                week = body["week_timeslots"][0]
                item.update(state="active", active_timeslot={"timeslot_id": 0, "weekday": week["recurrence"][0]})
                self.apply(week["timeslots"][0]["target"]["rid"])
            return 201, ident(item["id"], rtype)
        if item is None:
            return 404, NOT_FOUND
        if method == "GET":
            if rtype == "smart_scene":
                self.smart_gets += 1
                slot = item["active_timeslot"]
                if self.advance_after is not None and self.smart_gets > self.advance_after and slot["timeslot_id"] == 0:
                    slot["timeslot_id"] = 1
                    self.apply(item["week_timeslots"][0]["timeslots"][1]["target"]["rid"])
            return 200, compact({"errors": [], "data": [item]})
        if method == "PUT":
            if "recall" in body:
                item["state"] = "active" if body["recall"]["action"] == "activate" else "inactive"
            if "on" in body:
                item["on"] = dict(body["on"])
            return 200, ident(rid, rtype)
        if rid in self.locked:  # DELETE refused
            return 403, compact({"data": [], "errors": [{"description": "locked"}]}) + "\n"
        del self.items[(rtype, rid)]  # DELETE
        if rtype == "scene":  # V14: the schedule that plays a deleted scene goes as well
            for key, other in list(self.items.items()):
                slots = [slot for week in other.get("week_timeslots", []) for slot in week["timeslots"]]
                if key[0] == "smart_scene" and any(slot["target"]["rid"] == rid for slot in slots):
                    del self.items[key]
        return 200, ident(rid, rtype)

    def probe_items(self):
        return sorted(
            t for (t, _), item in self.items.items() if item.get("metadata", {}).get("name", "").startswith("c4-hue")
        )


class FakeLoop:
    """tools/devctl.py and the controller: `run` queues a Hue Request and prints its id, `wait`
    answers everything queued into driver.log, each after a debug line of the driver's own."""

    def __init__(self, log_path, bridge):
        self.log_path = log_path
        self.bridge = bridge
        self.queue = []
        self.next_id = 100
        self.ticks = 0
        self.drop = set()  # (method, path) the bridge handles but whose answer never reaches the log
        self.refuse = None  # log "Hue Request: <refuse>" instead of answering
        self.runs = []

    def __call__(self, args):
        if args[0] == "run":
            self.runs.append(args)
            self.queue.append(dict(arg.split("=", 1) for arg in args[2:]))
            self.next_id += 1
            return 0, "%d\n" % self.next_id, ""
        if args[0] == "wait":
            assert int(args[1]) == self.next_id, args
            with open(self.log_path, "a", encoding="utf-8") as f:
                for params in self.queue:
                    self.ticks += 1
                    stamp = "12:%02d:%02d.250" % divmod(self.ticks % 3600, 60)
                    f.write("%s [DEBUG] Hue Bridge: ExecuteCommand Hue_Request\n" % stamp)
                    if self.refuse:
                        f.write("%s Hue Bridge: Hue Request: %s\n" % (stamp, self.refuse))
                        continue
                    body = json.loads(params["Body"]) if "Body" in params else None
                    code, text = self.bridge.answer(params["Method"], params["Path"], body)
                    if (params["Method"], params["Path"]) not in self.drop:
                        f.write(answer_lines(params["Method"], params["Path"], code, text, stamp))
            self.queue = []
            return 0, "", ""
        raise AssertionError("unexpected devctl call %r" % (args,))


class FakeClock:
    def __init__(self, start):
        self.moment = start

    def now(self):
        return self.moment

    def sleep(self, seconds):
        self.moment += datetime.timedelta(seconds=seconds)

    def monotonic(self):
        return (self.moment - SUNDAY).total_seconds()


# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------


class BrightnessTests(unittest.TestCase):
    def test_defaults_and_low_values_pass(self):
        self.assertEqual(probe.check_brightness(probe.DEFAULT_BRIGHTNESS), 1)
        self.assertIsInstance(probe.check_brightness(1.0), int)
        self.assertEqual(probe.check_brightness(5), 5)
        self.assertEqual(probe.check_brightness("0.5"), 0.5)

    def test_above_five_is_refused_without_allow_bright(self):
        for value in (5.01, 6, 50, 100):
            with self.assertRaisesRegex(probe.ProbeError, "--allow-bright"):
                probe.check_brightness(value)
        self.assertEqual(probe.check_brightness(50, allow_bright=True), 50)
        self.assertEqual(probe.check_brightness(100, allow_bright=True), 100)

    def test_out_of_range_and_not_numbers_are_refused_even_when_allowed(self):
        for value in (0, -1, 100.5, float("nan"), float("inf"), "dim", None):
            with self.assertRaises(probe.ProbeError):
                probe.check_brightness(value, allow_bright=True)

    def test_timing(self):
        probe.check_timing(3, 60000)
        probe.check_timing(2, 0)
        for minutes, transition in ((1, 0), (121, 60000), (3, 180000), (3, -1), (3, 1.5), (True, 0)):
            with self.assertRaises(probe.ProbeError):
                probe.check_timing(minutes, transition)


class SlotTimeTests(unittest.TestCase):
    def test_slot_a_is_the_current_minute(self):
        a, b = probe.slot_times(SUNDAY, 3)
        self.assertEqual((a, b), (datetime.datetime(2026, 10, 25, 14, 3), datetime.datetime(2026, 10, 25, 14, 6)))

    def test_in_the_first_seconds_of_a_minute_slot_a_is_the_one_before(self):
        a, b = probe.slot_times(datetime.datetime(2026, 10, 25, 14, 3, 5), 3)
        self.assertEqual((probe.hhmm(a), probe.hhmm(b)), ("14:02", "14:05"))

    def test_slot_b_past_midnight_adds_the_next_weekday(self):
        a, b = probe.slot_times(datetime.datetime(2026, 10, 24, 23, 58, 30), 3)  # a Saturday
        self.assertEqual((a.day, probe.hhmm(a), b.day, probe.hhmm(b)), (24, "23:58", 25, "00:01"))
        self.assertEqual(probe.recurrence(a, b), ["saturday", "sunday"])
        self.assertEqual(probe.recurrence(a, b, "all"), list(probe.APP_WEEK))

    def test_the_week_wraps_from_sunday_to_monday(self):
        a, b = probe.slot_times(datetime.datetime(2026, 10, 25, 23, 59, 40), 2)
        self.assertEqual(probe.recurrence(a, b), ["sunday", "monday"])

    def test_one_weekday_without_a_wrap(self):
        a, b = probe.slot_times(SUNDAY, 30)
        self.assertEqual(probe.recurrence(a, b), ["sunday"])
        self.assertEqual(probe.APP_WEEK[0], "sunday")
        self.assertEqual(len(set(probe.recurrence(a, b, "all"))), 7)

    def test_until(self):
        now = datetime.datetime(2026, 10, 25, 14, 3, 20)
        self.assertEqual(probe.until_time("14:09", now), datetime.datetime(2026, 10, 25, 14, 9))
        self.assertEqual(probe.until_time(" 16:05 ", now), datetime.datetime(2026, 10, 25, 16, 5))
        late = datetime.datetime(2026, 10, 25, 23, 58)
        self.assertEqual(probe.until_time("00:05", late), datetime.datetime(2026, 10, 26, 0, 5))
        for text in ("14:03", "13:00", "21:00", "25:00", "14:60", "2pm", ""):
            with self.assertRaises(probe.ProbeError):
                probe.until_time(text, now)


class BodyTests(unittest.TestCase):
    def test_smart_scene_body_has_the_shape_the_bridge_accepted(self):
        a = datetime.datetime(2026, 10, 25, 14, 3)
        body = probe.smart_scene_body(
            "c4-hue probe", ROOM, "room", SCENE_A, SCENE_B, a, a + datetime.timedelta(minutes=3)
        )
        self.assertEqual(
            body,
            {
                "metadata": {"name": "c4-hue probe"},
                "group": {"rid": ROOM, "rtype": "room"},
                "week_timeslots": [
                    {
                        "timeslots": [
                            {
                                "start_time": {"kind": "time", "time": {"hour": 14, "minute": 3, "second": 0}},
                                "target": {"rid": SCENE_A, "rtype": "scene"},
                            },
                            {
                                "start_time": {"kind": "time", "time": {"hour": 14, "minute": 6, "second": 0}},
                                "target": {"rid": SCENE_B, "rtype": "scene"},
                            },
                        ],
                        "recurrence": ["sunday"],
                    }
                ],
                "transition_duration": 60000,
            },
        )

    def test_smart_scene_body_past_midnight_keeps_slot_b_last(self):
        a, b = probe.slot_times(datetime.datetime(2026, 10, 24, 23, 58, 30), 3)
        body = probe.smart_scene_body("p", ZONE, "zone", SCENE_A, SCENE_B, a, b, "today", 5000)
        week = body["week_timeslots"][0]
        times = [slot["start_time"]["time"] for slot in week["timeslots"]]
        self.assertEqual(times, [{"hour": 23, "minute": 58, "second": 0}, {"hour": 0, "minute": 1, "second": 0}])
        self.assertEqual([slot["target"]["rid"] for slot in week["timeslots"]], [SCENE_A, SCENE_B])
        self.assertEqual(week["recurrence"], ["saturday", "sunday"])
        self.assertEqual((body["group"], body["transition_duration"]), ({"rid": ZONE, "rtype": "zone"}, 5000))
        every = probe.smart_scene_body("p", ROOM, "room", SCENE_A, SCENE_B, a, b, "all")
        self.assertEqual(every["week_timeslots"][0]["recurrence"], list(probe.APP_WEEK))

    def test_scene_body_takes_every_light_at_the_brightness(self):
        lights = [info(LAMP), info(FLOOR, 153, 400), info(PLUG + "w", ct=False), info(HALL, 400, 500)]
        body = probe.scene_body("c4-hue probe A", ROOM, "room", lights, 1, 454)
        self.assertEqual(
            (body["metadata"], body["group"]), ({"name": "c4-hue probe A"}, {"rid": ROOM, "rtype": "room"})
        )
        self.assertEqual(
            body["actions"][0],
            {
                "target": {"rid": LAMP, "rtype": "light"},
                "action": {"on": {"on": True}, "dimming": {"brightness": 1}, "color_temperature": {"mirek": 454}},
            },
        )
        self.assertEqual(body["actions"][1]["action"]["color_temperature"], {"mirek": 400})  # clamped to the lamp
        self.assertNotIn("color_temperature", body["actions"][2]["action"])  # white only
        scene_b = probe.scene_body("c4-hue probe B", ROOM, "room", lights, 1, 370)
        self.assertEqual(scene_b["actions"][3]["action"]["color_temperature"], {"mirek": 400})
        self.assertEqual(scene_b["actions"][0]["action"]["color_temperature"], {"mirek": 370})
        with self.assertRaises(probe.ProbeError):
            probe.scene_body("c4-hue probe A", ROOM, "room", [], 1, 454)

    def test_bodies_have_no_empty_containers(self):
        # Director's JsonEncode cannot tell an empty array from an empty object.
        a, b = probe.slot_times(SUNDAY, 3)
        bodies = [
            probe.scene_body("c4-hue probe A", ROOM, "room", [info(LAMP), info(FLOOR, ct=False)], 1, 454),
            probe.smart_scene_body("c4-hue probe", ROOM, "room", SCENE_A, SCENE_B, a, b),
        ]
        for body in bodies:
            self.assertEqual(json.loads(json.dumps(body)), body)
            self.assertFalse([v for v in walk(body) if isinstance(v, (dict, list)) and not v])

    def test_member_lights_of_a_room_and_of_a_zone(self):
        bridge = FakeBridge()
        lights = [item for (t, _), item in bridge.items.items() if t == "light"]
        kept, left_out = probe.member_lights(bridge.items[("room", ROOM)], lights)
        self.assertEqual([light["rid"] for light in kept], [LAMP, FLOOR])
        self.assertEqual([light["name"] for light in left_out], ["Plug"])
        self.assertEqual((kept[1]["mirek_min"], kept[1]["mirek_max"], kept[1]["on"]), (153, 454, False))
        zone = {"type": "zone", "children": [{"rid": HALL, "rtype": "light"}, {"rid": LAMP, "rtype": "light"}]}
        kept, left_out = probe.member_lights(zone, lights)
        self.assertEqual(([light["rid"] for light in kept], left_out), ([LAMP, HALL], []))
        kept, _ = probe.member_lights(bridge.items[("room", ROOM)], lights, only=(FLOOR,))
        self.assertEqual([light["rid"] for light in kept], [FLOOR])
        with self.assertRaisesRegex(probe.ProbeError, "not a light of this room"):
            probe.member_lights(bridge.items[("room", ROOM)], lights, only=(HALL,))

    def test_active_slot_reads_the_week_entry_of_the_weekday(self):
        item = probe.smart_scene_body("p", ROOM, "room", SCENE_A, SCENE_B, *probe.slot_times(SUNDAY, 3))
        item["active_timeslot"] = {"timeslot_id": 1, "weekday": "sunday"}
        self.assertEqual(probe.active_slot(item), (1, "sunday", "14:06", SCENE_B))
        item["active_timeslot"] = {"timeslot_id": 2, "weekday": "sunday"}
        self.assertIsNone(probe.active_slot(item))
        item["active_timeslot"] = {"timeslot_id": 0, "weekday": "monday"}
        self.assertIsNone(probe.active_slot(item))
        item["week_timeslots"][0]["timeslots"][0]["start_time"] = {"kind": "sunset", "time": {"hour": 0, "minute": 0}}
        item["week_timeslots"][0]["recurrence"].append("monday")
        self.assertEqual(probe.active_slot(item), (0, "monday", "sunset", SCENE_A))
        self.assertIsNone(probe.active_slot({"state": "inactive"}))


class StateFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "dev", probe.STATE_NAME)

    def test_round_trip(self):
        state = {"schema": probe.STATE_SCHEMA, "smart_scene": SMART, "lights": [{"rid": LAMP, "was_on": False}]}
        probe.save_state(self.path, state)
        self.assertEqual(probe.load_state(self.path), state)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), [probe.STATE_NAME])  # no .tmp left behind

    def test_missing_is_none_and_garbage_is_refused(self):
        self.assertIsNone(probe.load_state(self.path))
        os.makedirs(os.path.dirname(self.path))
        for text in ("{not json", "[1, 2]", '{"schema": 99}'):
            with open(self.path, "w", encoding="utf-8") as f:
                f.write(text)
            with self.assertRaises(probe.ProbeError):
                probe.load_state(self.path)


class LogReassemblyTests(unittest.TestCase):
    PATH = probe.resource_path("smart_scene", SMART)
    KEY = ("GET", PATH)

    def test_pieces_are_joined_in_order(self):
        body = compact({"errors": [], "data": [{"id": SMART, "metadata": {"name": "x" * 1900}}]})
        text = (
            "11:59:59.000 [DEBUG] Hue Bridge: ExecuteCommand Hue_Request\n"
            + answer_lines("GET", self.PATH, 200, body, "12:00:01.500")
            + "12:00:01.600 [DEBUG] Hue Bridge: event 1792855444:0 update: light\n"
        )
        answer = probe.parse_answers(text, [self.KEY]).answers[self.KEY]
        self.assertEqual((answer.total, len(answer.pieces), answer.complete), (3, 3, True))
        self.assertEqual(answer.body, body)
        self.assertEqual((answer.code, answer.ok, answer.stamp, answer.nbytes), (200, True, "12:00:01.500", len(body)))
        self.assertEqual(answer.item()["id"], SMART)

    def test_a_newline_in_the_body_continues_the_line_before(self):
        put = probe.resource_path("smart_scene", SMART)
        body = ident(SMART, "smart_scene")  # ends with a newline, as the bridge's PUT answers do
        text = answer_lines("PUT", put, 200, body)
        self.assertIn("\n\n", text)
        answer = probe.parse_answers(text, [("PUT", put)]).answers[("PUT", put)]
        self.assertEqual(answer.body, body)
        self.assertEqual(answer.data(), [{"rid": SMART, "rtype": "smart_scene"}])
        inner = '{"a":1,\n"b":"' + "y" * 790 + '"}'
        answer = probe.parse_answers(answer_lines("GET", self.PATH, 200, inner), [self.KEY]).answers[self.KEY]
        self.assertEqual((answer.body, answer.doc["a"]), (inner, 1))

    def test_not_found_and_transport_failures(self):
        text = answer_lines("GET", self.PATH, 404, NOT_FOUND) + answer_lines("DELETE", self.PATH, None, "")
        parsed = probe.parse_answers(text, [self.KEY, ("DELETE", self.PATH)])
        gone, failed = parsed.answers[self.KEY], parsed.answers[("DELETE", self.PATH)]
        self.assertEqual(
            (gone.code, gone.ok, gone.errors(), gone.problem()), (404, False, ["Not Found"], "HTTP 404: Not Found")
        )
        self.assertEqual((failed.code, failed.ok, failed.complete, failed.data()), (None, False, True, []))
        self.assertEqual(failed.problem(), "transfer failed (28): Timeout was reached")

    def test_incomplete_out_of_order_and_unfinished_lines_wait(self):
        body = "z" * 2000
        lines = answer_lines("GET", self.PATH, 200, body).splitlines(keepends=True)
        self.assertEqual(len(lines), 4)
        self.assertFalse(probe.parse_answers("".join(lines[:3]), [self.KEY]).answers[self.KEY].complete)
        swapped = lines[0] + lines[2] + lines[1] + lines[3]
        self.assertFalse(probe.parse_answers(swapped, [self.KEY]).answers[self.KEY].complete)
        unfinished = "".join(lines)[:-1]  # the last line has no newline yet
        self.assertFalse(probe.parse_answers(unfinished, [self.KEY]).answers[self.KEY].complete)
        self.assertTrue(probe.parse_answers(unfinished + "\n", [self.KEY]).answers[self.KEY].complete)

    def test_only_wanted_answers_and_the_first_of_each(self):
        other = probe.resource_path("light", LAMP)
        first = compact({"data": [{"id": SMART, "state": "active"}], "errors": []})
        later = compact({"data": [{"id": SMART, "state": "inactive"}], "errors": []})
        text = answer_lines("GET", other, 200, "{}") + answer_lines("GET", self.PATH, 200, first)
        text += answer_lines("GET", self.PATH, 200, later)
        parsed = probe.parse_answers(text, [self.KEY])
        self.assertEqual(list(parsed.answers), [self.KEY])
        self.assertEqual(parsed.answers[self.KEY].item()["state"], "active")

    def test_refusals(self):
        text = "12:00:00.000 Hue Bridge: Hue Request: bridge identity not verified yet; see Status\n"
        parsed = probe.parse_answers(text, [self.KEY])
        self.assertEqual((parsed.answers, parsed.refusals), ({}, ["bridge identity not verified yet; see Status"]))


# ---------------------------------------------------------------------------
# The commands against the fake dev loop
# ---------------------------------------------------------------------------


class ProbeFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bridge = FakeBridge()
        self.fake = FakeLoop(os.path.join(self.tmp.name, "driver.log"), self.bridge)
        self.clock = FakeClock(SUNDAY)
        self.loop = probe.DevLoop(
            state_dir=self.tmp.name, timeout=30, devctl=self.fake, sleep=self.clock.sleep, clock=self.clock.monotonic
        )
        self.lines = []
        self.state_path = os.path.join(self.tmp.name, probe.STATE_NAME)
        self.probe = probe.Probe(
            self.loop, self.state_path, out=self.lines.append, now=self.clock.now, sleep=self.clock.sleep
        )

    def output(self):
        return "\n".join(self.lines)

    def calls(self, method):
        return [(path, body) for m, path, body in self.bridge.calls if m == method]

    def test_create_makes_two_scenes_and_the_smart_scene_and_saves_their_ids(self):
        state = self.probe.create(ROOM, minutes=3, brightness=1)
        self.assertEqual(probe.load_state(self.state_path), state)
        posts = self.calls("POST")
        self.assertEqual(
            [path for path, _ in posts], [probe.resource_path("scene")] * 2 + [probe.resource_path("smart_scene")]
        )
        scene_a, scene_b, smart = (body for _, body in posts)
        self.assertEqual([a["target"]["rid"] for a in scene_a["actions"]], [LAMP, FLOOR])  # the plug left out
        self.assertEqual({a["action"]["color_temperature"]["mirek"] for a in scene_a["actions"]}, {454})
        self.assertEqual({a["action"]["color_temperature"]["mirek"] for a in scene_b["actions"]}, {370})
        self.assertEqual({a["action"]["dimming"]["brightness"] for a in scene_a["actions"]}, {1})
        week = smart["week_timeslots"][0]
        self.assertEqual([slot["target"]["rid"] for slot in week["timeslots"]], [state["scene_a"], state["scene_b"]])
        self.assertEqual((week["recurrence"], smart["metadata"]["name"]), (["sunday"], "c4-hue probe"))
        self.assertEqual(state["slots"]["a"] + " " + state["slots"]["b"], "14:03 14:06")
        self.assertEqual(state["lights"][1]["mirek"], {"a": 454, "b": 370})
        self.assertEqual((state["group"]["grouped_light"], state["bridge_time_zone"]), (GROUPED, "EST5EDT"))
        self.assertEqual(self.bridge.probe_items(), ["scene", "scene", "smart_scene"])
        self.assertIn("left out (cannot dim): Plug", self.output())
        self.assertIn("bridge time zone EST5EDT", self.output())
        get_lights = [run for run in self.fake.runs if "Path=" + probe.resource_path("light") in run]
        self.assertEqual(get_lights[0][:2], ["run", "Hue Request"])
        self.assertIn("Raw=true", get_lights[0])

    def test_create_refuses_lit_lights_a_second_probe_and_a_bright_level(self):
        self.bridge.light(FLOOR)["on"] = {"on": True}
        with self.assertRaisesRegex(probe.ProbeError, "Floor Lamp.*--allow-on"):
            self.probe.create(ROOM)
        self.assertEqual((self.calls("POST"), os.path.exists(self.state_path)), ([], False))
        state = self.probe.create(ROOM, allow_on=True, only=(FLOOR,))
        self.assertEqual([light["was_on"] for light in state["lights"]], [True])
        with self.assertRaisesRegex(probe.ProbeError, "run cleanup first"):
            self.probe.create(ROOM)
        with self.assertRaisesRegex(probe.ProbeError, "--allow-bright"):
            probe.Probe(self.loop, self.state_path + ".2").create(ROOM, brightness=10)

    def test_watch_reports_slot_b_when_it_starts(self):
        self.probe.create(ROOM)
        self.bridge.advance_after = 8  # the ninth poll, at 14:06:00
        self.lines.clear()
        tracker = self.probe.watch()
        out = self.output()
        self.assertIn("active, slot 0 (sunday 14:03) = A | A static, B inactive | Desk Lamp on 1 % mirek 454", out)
        self.assertIn(
            "active, slot 1 (sunday 14:06) = B | A inactive, B static | Desk Lamp on 1 % mirek 370   <- changed", out
        )
        self.assertIn("verdict: slot B started, first seen 12:", out)
        self.assertIn("scene B: static from", out)
        self.assertIn("light: mirek 370 (scene B's) from", out)
        self.assertEqual(len(tracker.slot_changes), 1)
        self.assertGreaterEqual(self.clock.now(), datetime.datetime(2026, 10, 25, 14, 9))
        self.assertLess(self.clock.now(), datetime.datetime(2026, 10, 25, 14, 9, 30))

    def test_watch_says_so_when_slot_b_never_starts(self):
        self.probe.create(ROOM)
        self.probe.activate()
        self.assertEqual([body for _, body in self.calls("PUT")], [{"recall": {"action": "activate"}}])
        self.lines.clear()
        self.probe.watch(until="14:05")
        out = self.output()
        self.assertIn("verdict: slot B NOT seen by", out)
        self.assertIn("scene B: never left inactive", out)
        self.assertIn("light: never at scene B's mirek 370", out)
        self.assertNotIn("<- changed", out)

    def test_watch_any_smart_scene_needs_until(self):
        state = self.probe.create(ROOM)
        with self.assertRaisesRegex(probe.ProbeError, "--until"):
            self.probe.watch(smart=state["smart_scene"])
        self.lines.clear()
        self.probe.watch(until="14:04", smart=state["smart_scene"], light=HALL)
        self.assertIn("= bbbbbbbb | Hall Lamp off", self.output())
        self.assertIn("no slot change from", self.output())

    def test_cleanup_deletes_confirms_and_turns_the_probe_lights_off(self):
        self.probe.create(ROOM)
        self.bridge.light(FLOOR)["dimming"]["brightness"] = 60.0  # somebody took the floor lamp over
        self.lines.clear()
        self.assertTrue(self.probe.cleanup())
        self.assertEqual(self.bridge.probe_items(), [])
        self.assertFalse(os.path.exists(self.state_path))
        self.assertEqual(
            [body for _, body in self.calls("PUT")], [{"recall": {"action": "deactivate"}}, {"on": {"on": False}}]
        )
        self.assertEqual(self.calls("PUT")[1][0], probe.resource_path("light", LAMP))
        self.assertEqual((self.bridge.light(LAMP)["on"]["on"], self.bridge.light(FLOOR)["on"]["on"]), (False, True))
        self.assertIn("Floor Lamp is at 60 %, above the probe's 1 %: changed since, left on", self.output())
        self.assertIn("all gone", self.output())
        deletes = [path for path, _ in self.calls("DELETE")]
        self.assertTrue(deletes[0].startswith(probe.resource_path("smart_scene")))
        self.assertEqual(len(deletes), 3)
        self.assertEqual(self.output().count("gone: "), 3)
        self.assertTrue(self.probe.cleanup())  # nothing left: says so
        self.assertIn("nothing to clean up", self.lines[-1])

    def test_run_cleans_up_after_a_refused_smart_scene(self):
        self.bridge.fail_post.add("smart_scene")
        with self.assertRaisesRegex(probe.ProbeError, "smart scene 'c4-hue probe' not created: HTTP 400: invalid"):
            self.probe.run(group_rid=ROOM)
        self.assertEqual(self.bridge.probe_items(), [])
        self.assertFalse(os.path.exists(self.state_path))
        self.assertIn("all gone", self.output())

    def test_a_lost_answer_leaves_a_note_that_cleanup_follows(self):
        self.fake.drop.add(("POST", probe.resource_path("smart_scene")))
        with self.assertRaisesRegex(probe.ProbeError, "may have made smart scene 'c4-hue probe' all the same"):
            self.probe.create(ROOM)
        state = probe.load_state(self.state_path)
        self.assertEqual((state["pending"], state.get("smart_scene")), ("c4-hue probe", None))
        self.assertEqual(self.bridge.probe_items(), ["scene", "scene", "smart_scene"])
        with self.assertRaisesRegex(probe.ProbeError, "create was cut off"):
            self.probe.activate()
        self.assertTrue(self.probe.cleanup())
        self.assertEqual(self.bridge.probe_items(), [])
        self.assertIn("'c4-hue probe' from the cut-off create: found 1", self.output())

    def test_cleanup_keeps_what_stays_for_the_next_one(self):
        state = self.probe.create(ROOM)
        self.bridge.locked.add(state["scene_b"])
        with self.assertRaisesRegex(probe.ProbeError, "still to remove: scene B; run cleanup again"):
            self.probe.cleanup()
        self.assertEqual(self.bridge.probe_items(), ["scene"])
        self.assertIn("STILL THERE: scene B", self.output())
        self.assertEqual(probe.load_state(self.state_path)["scene_b"], state["scene_b"])
        self.assertFalse(self.bridge.light(LAMP)["on"]["on"])  # the lights went off all the same
        self.bridge.locked.clear()
        self.assertTrue(self.probe.cleanup())
        self.assertEqual(self.bridge.probe_items(), [])

    def test_trouble_with_the_lights_leaves_nothing_on_the_bridge(self):
        self.probe.create(ROOM)
        self.fake.drop.add(("GET", probe.resource_path("light", LAMP)))
        self.assertTrue(self.probe.cleanup())
        self.assertEqual(self.bridge.probe_items(), [])
        self.assertFalse(os.path.exists(self.state_path))
        self.assertIn("probe lights not switched off (no complete answer", self.output())
        self.assertTrue(self.bridge.light(LAMP)["on"]["on"])

    def test_the_loop_reports_refusals_and_devctl_failures(self):
        self.fake.refuse = "not paired"
        with self.assertRaisesRegex(probe.ProbeError, "refused: not paired"):
            self.loop.requests([("GET", probe.resource_path("bridge"), None)])
        failing = probe.DevLoop(state_dir=self.tmp.name, devctl=lambda args: (1, "", "devctl: devserver not reachable"))
        with self.assertRaisesRegex(probe.ProbeError, "devserver not reachable"):
            failing.requests([("GET", probe.resource_path("bridge"), None)])
        with self.assertRaisesRegex(probe.ProbeError, "one request per method and path"):
            self.loop.requests([("GET", "/x", None), ("get", "/x", None)])

    def test_main_reports_errors_on_stderr(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = probe.main(
                ["--state-dir", self.tmp.name, "create", "--room", ROOM, "--brightness", "6"], loop=self.loop
            )
        self.assertEqual(code, 1)
        self.assertIn("--allow-bright", err.getvalue())
        out = []
        self.assertEqual(probe.main(["--state-dir", self.tmp.name, "cleanup"], loop=self.loop, out=out.append), 0)
        self.assertIn("nothing to clean up", out[0])


if __name__ == "__main__":
    unittest.main()
