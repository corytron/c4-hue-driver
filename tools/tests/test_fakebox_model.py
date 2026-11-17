"""Unit tests for tools/fakebox/model.py: the fake sync box's state machine (#547).

The rules are docs/syncbox-behaviour.md's (SB<n>); tests/fixtures/syncbox_scenarios.json runs every one
of them through tools/tests/test_fakebox_scenarios.py. These tests cover the model's own API (fixtures,
clocks, paths, headers, bodies, registrations given at start, set/unset/get, status, history) and the
rules where an interaction is easy to get wrong (the order inside one PUT, 16 judged on the result,
auto-sync's moments, the powersave masking, levels after a firmware update). Pure: no network, no
files but the fixtures JSON.

Placeholders only: box 0A1B2C3D4E5F, bridge 001788fffe123abc, token TEST-TOKEN-NOT-REAL.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_model.py -v
"""

import copy
import json
import os
import sys
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

from fakebox import model  # noqa: E402

FIXTURES = model.load_fixtures()
TV = FIXTURES["AREA"]["tv"]
OFFICE = FIXTURES["AREA"]["office"]


def paired(name="HSB2", given=None, **options):
    """A box from a fixture (with `given` dotted paths set first), paired as registration 7."""
    state = copy.deepcopy(FIXTURES["state"][name])
    for path, value in (given or {}).items():
        node = state
        parts = path.split(".")
        for part in parts[:-1]:
            node = node[part]
        node[parts[-1]] = value
    box = model.Box(state, model.ManualClock(), fixtures=FIXTURES, **options)
    box.event("button")
    status, body = box.request("POST", "/registrations", {}, {"appName": "c4-hue", "instanceName": "Test"})
    assert status == 200, body
    return box, model.auth(body["accessToken"])


def put(box, headers, path, body):
    return box.request("PUT", path, headers, json.dumps(body))


class TestFixturesAndConstruction(unittest.TestCase):
    def test_every_fixture_model_builds_and_its_view_is_the_fixture(self):
        for name in FIXTURES["models"]:
            with self.subTest(model=name):
                box = model.Box(name, fixtures=FIXTURES)
                self.assertEqual(FIXTURES["state"][name], box.state())

    def test_a_name_the_fixtures_lack_is_refused(self):
        with self.assertRaises(ValueError):
            model.Box("HSB9", fixtures=FIXTURES)
        with self.assertRaises(ValueError):
            model.Box({"execution": {}})

    def test_the_fixture_is_copied_not_shared(self):
        state = copy.deepcopy(FIXTURES["state"]["HSB2"])
        box, headers = paired(given={})
        model.Box(state, fixtures=FIXTURES).set("execution.brightness", 7)
        self.assertEqual(100, state["execution"]["brightness"])
        self.assertEqual(100, box.get("execution.brightness"))
        del headers

    def test_box_id_and_address_options(self):
        box = model.Box("HSB2", box_id="0a1b2c3d4e60", address="10.0.2.151", fixtures=FIXTURES)
        self.assertEqual("0A1B2C3D4E60", box.box_id)
        status, device = box.request("GET", "/device")
        self.assertEqual(200, status)
        self.assertEqual("0A1B2C3D4E60", device["uniqueId"])
        self.assertEqual("10.0.2.151", device["ipAddress"])

    def test_unkeyed_device_is_the_fixtures_and_follows_a_rename(self):
        box = model.Box("HSB1", fixtures=FIXTURES)
        self.assertEqual((200, FIXTURES["device"]["HSB1"]), box.request("GET", "/api/v1/device"))
        box.event("rename", name="Cinema Box")
        self.assertEqual("Cinema Box", box.request("GET", "/device")[1]["name"])

    def test_a_device_override_answers_the_unkeyed_get(self):
        box = model.Box("HSB2", device=FIXTURES["device"]["HSC001"], fixtures=FIXTURES)
        self.assertEqual("HSC001", box.request("GET", "/device")[1]["deviceType"])

    def test_registrations_given_at_start_are_paired_and_never_listed_with_tokens(self):
        box = model.Box("HSB2", registrations={"7": model.TOKEN}, fixtures=FIXTURES)
        status, body = box.request("GET", "", model.auth(model.TOKEN))
        self.assertEqual(200, status)
        self.assertNotIn(model.TOKEN, json.dumps(body))
        self.assertEqual({"1", "7"}, set(body["registrations"]))
        self.assertEqual(["7"], box.status()["paired"])
        with self.assertRaises(ValueError):
            model.Box("HSB2", registrations={"7": ""}, fixtures=FIXTURES)

    def test_events_list(self):
        for name in ("button", "cec_active_source", "hotplug", "signal", "tv_standby", "usb_power_lost", "idle"):
            self.assertIn(name, model.EVENTS)
        for name in ("bridge", "rename", "app_deletes", "firmware", "reboot", "advance", "address"):
            self.assertIn(name, model.EVENTS)


class TestClocks(unittest.TestCase):
    def test_manual_clock(self):
        clock = model.ManualClock()
        self.assertEqual(0, clock.now())
        clock.advance(1500)
        self.assertEqual(1500, clock.now())

    def test_scaled_clock_runs_faster_and_takes_advance(self):
        ticks = iter([100.0, 102.0, 102.0])
        clock = model.ScaledClock(10, monotonic=lambda: next(ticks))
        self.assertAlmostEqual(20000.0, clock.now())
        clock.advance(500)
        self.assertAlmostEqual(20500.0, clock.now())
        with self.assertRaises(ValueError):
            model.ScaledClock(0)

    def test_the_pairing_window_and_the_restart_follow_the_clock(self):
        box = model.Box("HSB2", model.ManualClock(), fixtures=FIXTURES)
        box.event("button")
        self.assertTrue(box.status()["pairing_open"])
        box.event("advance", ms=4999)
        self.assertTrue(box.status()["pairing_open"])
        box.event("advance", ms=1)
        self.assertFalse(box.status()["pairing_open"])
        body = {"appName": "c4-hue", "instanceName": "Late"}
        self.assertEqual(16, box.request("POST", "/registrations", {}, body)[1]["code"])
        box.event("button", window=60)
        box.event("advance", ms=30000)
        self.assertEqual(200, box.request("POST", "/registrations", {}, body)[0])


class TestRequests(unittest.TestCase):
    def test_paths_with_and_without_the_api_prefix(self):
        box, headers = paired()
        self.assertEqual(box.request("GET", "/api/v1/execution", headers), box.request("GET", "/execution", headers))
        self.assertEqual(200, box.request("GET", "/api/v1", headers)[0])
        self.assertEqual(200, box.request("GET", "/api/v1/", headers)[0])
        self.assertEqual(200, box.request("GET", "/api/v1/hdmi/input1?x=1", headers)[0])
        self.assertEqual(404, box.request("GET", "/api/v2", headers)[0])
        self.assertEqual(404, box.request("GET", "/api/v1x", headers)[0])

    def test_headers_any_case_and_a_list_of_pairs(self):
        box, headers = paired()
        token = headers["Authorization"].split()[1]
        self.assertEqual(200, box.request("GET", "", {"authorization": "bearer " + token})[0])
        self.assertEqual(200, box.request("GET", "", [("AUTHORIZATION", "Bearer " + token)])[0])
        self.assertEqual(401, box.request("GET", "", {"Authorization": token})[0])
        self.assertEqual(401, box.request("GET", "/device", {"Authorization": "Bearer " + model.WRONG_TOKEN})[0])

    def test_bodies_as_text_bytes_or_objects(self):
        box, headers = paired()
        for body in ('{"brightness": 120}', b'{"brightness": 121}', {"brightness": 122}):
            self.assertEqual((200, {}), box.request("PUT", "/execution", headers, body))
        self.assertEqual(122, box.get("execution.brightness"))
        self.assertEqual(12, box.request("PUT", "/execution", headers, "{nope")[1]["code"])
        self.assertEqual(12, box.request("PUT", "/execution", headers, "[1]")[1]["code"])
        self.assertEqual(12, box.request("PUT", "/execution", headers, "5")[1]["code"])
        self.assertEqual(13, box.request("PUT", "/execution", headers, "{}")[1]["code"])

    def test_no_body_and_an_empty_list_are_an_empty_put(self):
        """As the Lua fake: R1 §2.6's empty PUT is 13, and an empty Lua table encodes as []."""
        box, headers = paired()
        for body in (None, "", "  ", b"", "[]", []):
            with self.subTest(body=body):
                self.assertEqual((400, 13), self._code(box.request("PUT", "/execution", headers, body)))
                self.assertEqual((400, 13), self._code(box.request("POST", "/registrations", {}, body)))
        self.assertEqual((400, 12), self._code(box.request("PUT", "/behavior", headers, [1])))
        self.assertEqual((400, 13), self._code(box.request("PUT", "/execution", headers, {"palette": "neutral"})))

    @staticmethod
    def _code(answer):
        return answer[0], answer[1]["code"]

    def test_error_bodies_are_the_fixtures(self):
        box, headers = paired()
        for name, (method, path, body) in {
            "unauthorized": ("GET", "/execution", None),
            "invalid_json": ("PUT", "/execution", "x"),
            "invalid_key": ("PUT", "/execution", "{}"),
            "invalid_value": ("PUT", "/execution", '{"brightness": 201}'),
            "not_found": ("GET", "/nothing", None),
        }.items():
            with self.subTest(error=name):
                status, answer = box.request(method, path, headers if name != "unauthorized" else {}, body)
                self.assertEqual(FIXTURES["error_status"][name], status)
                self.assertEqual(FIXTURES["error"][name], answer)

    def test_a_refused_put_changes_nothing(self):
        box, headers = paired()
        before = box.state()
        self.assertEqual(15, put(box, headers, "/execution", {"brightness": 50, "mode": "ambient"})[1]["code"])
        self.assertEqual(13, put(box, headers, "/execution", {"brightness": 300, "colour": 1})[1]["code"])
        after = box.state()
        for state in (before, after):
            state["registrations"]["7"].pop("lastUsed")
        self.assertEqual(before, after)

    def test_lastused_moves_with_each_keyed_request(self):
        box, headers = paired()
        box.event("advance", ms=60000)
        box.request("GET", "/hue", headers)
        self.assertEqual(60000, box.get("registrations.7.lastUsed"))
        self.assertEqual(0, box.get("registrations.7.created"))
        self.assertFalse(box.get("registrations.7.verified"))


class TestExecution(unittest.TestCase):
    def test_one_put_wakes_selects_and_syncs_in_that_inputs_mode(self):
        box, headers = paired("HSB2", given={"execution.mode": "powersave", "execution.syncActive": False})
        box.set("execution.hdmiActive", False)
        box.set("hue.connectionState", "connected")
        body = {"hdmiActive": True, "hdmiSource": "input2", "syncActive": True}
        self.assertEqual(200, put(box, headers, "/execution", body)[0])
        self.assertEqual("game", box.get("execution.mode"))
        self.assertEqual("input2", box.get("execution.hdmiSource"))
        self.assertTrue(box.get("execution.hdmiActive"))

    def test_mode_and_intensity_together_put_the_intensity_on_the_new_mode(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "game", "intensity": "subtle"})
        self.assertEqual("subtle", box.get("execution.game.intensity"))
        self.assertEqual("high", box.get("execution.video.intensity"))

    def test_mode_applies_before_syncactive(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "passthrough", "syncActive": True})
        self.assertEqual("video", box.get("execution.mode"))

    def test_sixteen_is_judged_on_the_result(self):
        box, headers = paired()
        put(box, headers, "/execution", {"syncActive": False})
        box.event("bridge", state="busy")
        self.assertEqual(16, put(box, headers, "/execution", {"brightness": 50, "syncActive": True})[1]["code"])
        self.assertEqual(100, box.get("execution.brightness"))
        # mode applies before syncActive (SB55): video then off is passthrough, which needs no stream
        self.assertEqual(200, put(box, headers, "/execution", {"mode": "video", "syncActive": False})[0])
        self.assertEqual("passthrough", box.get("execution.mode"))
        self.assertEqual("busy", box.get("hue.connectionState"))

    def test_choosing_the_area_in_the_same_put_clears_invalidgroup_first(self):
        box, headers = paired()
        put(box, headers, "/execution", {"syncActive": False})
        box.event("bridge", state="invalidgroup")
        self.assertEqual(200, put(box, headers, "/execution", {"hueTarget": OFFICE, "mode": "music"})[0])
        self.assertEqual("streaming", box.get("hue.connectionState"))
        self.assertTrue(box.get("hue.groups.%s.active" % OFFICE))

    def test_toggles_and_cycles(self):
        box, headers = paired()
        put(box, headers, "/execution", {"cycleSyncMode": "next"})
        self.assertEqual("music", box.get("execution.mode"))
        put(box, headers, "/execution", {"cycleSyncMode": "next"})
        self.assertEqual("game", box.get("execution.mode"))
        put(box, headers, "/execution", {"toggleSyncMode": "game"})
        self.assertEqual("passthrough", box.get("execution.mode"))
        put(box, headers, "/execution", {"toggleSyncActive": False})
        self.assertEqual("passthrough", box.get("execution.mode"))
        put(box, headers, "/execution", {"toggleHdmiActive": True})
        self.assertEqual("powersave", box.get("execution.mode"))
        put(box, headers, "/execution", {"cycleHdmiSource": "previous"})
        self.assertEqual("input4", box.get("execution.hdmiSource"))
        self.assertEqual("powersave", box.get("execution.mode"))
        put(box, headers, "/execution", {"cycleIntensity": "next"})
        self.assertEqual("subtle", box.get("execution.game.intensity"))

    def test_brightness_increment_is_clamped(self):
        box, headers = paired()
        put(box, headers, "/execution", {"brightness": 150, "incrementBrightness": 100})
        self.assertEqual(200, box.get("execution.brightness"))
        self.assertEqual(15, put(box, headers, "/execution", {"incrementBrightness": -201})[1]["code"])
        self.assertEqual(15, put(box, headers, "/execution", {"brightness": True})[1]["code"])

    def test_background_lighting_on_music_is_refused(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "music"})
        self.assertEqual(15, put(box, headers, "/execution", {"backgroundLighting": True})[1]["code"])
        self.assertEqual(200, put(box, headers, "/execution", {"video": {"backgroundLighting": True}})[0])
        self.assertTrue(box.get("execution.video.backgroundLighting"))
        self.assertEqual(13, put(box, headers, "/execution", {"music": {"colour": 1}})[1]["code"])

    def test_a_preset_runs_as_if_sent_in_the_same_put(self):
        presets = {"p1": {"name": "Movie", "execution": {"mode": "game", "brightness": 60}}}
        box, headers = paired(given={"presets": presets})
        box.event("advance", ms=2500)
        self.assertEqual(200, put(box, headers, "/execution", {"preset": "p1", "brightness": 80})[0])
        self.assertEqual("game", box.get("execution.mode"))
        self.assertEqual(80, box.get("execution.brightness"))
        self.assertEqual(2500, box.get("presets.p1.lastUsed"))
        self.assertEqual(15, put(box, headers, "/execution", {"preset": "p2"})[1]["code"])

    def test_the_area_moves_the_stream_and_groups_form(self):
        box, headers = paired()
        put(box, headers, "/execution", {"hueTarget": "groups/" + OFFICE})
        self.assertFalse(box.get("hue.groups.%s.active" % TV))
        self.assertTrue(box.get("hue.groups.%s.active" % OFFICE))
        self.assertEqual(15, put(box, headers, "/execution", {"hueTarget": "nowhere"})[1]["code"])

    def test_a_one_input_box_refuses_other_inputs(self):
        box, headers = paired("HSB3")
        self.assertEqual(15, put(box, headers, "/execution", {"hdmiSource": "input2"})[1]["code"])
        put(box, headers, "/execution", {"cycleHdmiSource": "next"})
        self.assertEqual("input1", box.get("execution.hdmiSource"))
        self.assertEqual(404, box.request("GET", "/hdmi/input2", headers)[0])

    def test_standalone_syncs_without_a_bridge_and_refuses_an_area(self):
        box, headers = paired("HSB3_standalone")
        hue = box.get("hue")
        self.assertEqual(200, put(box, headers, "/execution", {"mode": "video"})[0])
        self.assertEqual(hue, box.get("hue"))
        self.assertEqual(16, put(box, headers, "/execution", {"hueTarget": "anything"})[1]["code"])
        self.assertEqual(16, put(box, headers, "/hue", {"groupId": OFFICE})[1]["code"])


class TestOtherResources(unittest.TestCase):
    def test_behavior_keys_follow_model_and_level(self):
        cases = [
            ("HSB3", {"usbPowersave": 0}, 13),
            ("HSB2", {"forceDoviNative": 0}, 13),
            ("HSB1", {"input1": {"hpdInputPortSwitch": 1}}, 13),
            ("HSB1", {"input1": {"hdrMode": 3}}, 15),
            ("HSB2", {"cecPowersave": True}, 15),
            ("HSB2", {"inactivePowersave": 10001}, 15),
            ("HSB3", {"input2": {"cecInputSwitch": 1}}, 13),
        ]
        for name, body, code in cases:
            with self.subTest(model=name, body=body):
                box, headers = paired(name)
                self.assertEqual(code, put(box, headers, "/behavior", body)[1]["code"])
        box, headers = paired("HSB1")
        self.assertEqual(200, put(box, headers, "/behavior", {"input4": {"hdrMode": 1}, "inactivePowersave": 0})[0])
        self.assertEqual(1, box.get("behavior.input4.hdrMode"))

    def test_hdmi_device_and_hue_writes(self):
        box, headers = paired()
        self.assertEqual(200, put(box, headers, "/hdmi/input3", {"name": "Switch", "type": "nintendoswitch"})[0])
        self.assertEqual("Switch", box.get("hdmi.input3.name"))
        self.assertEqual(13, put(box, headers, "/hdmi/input3", {"status": "linked"})[1]["code"])
        self.assertEqual(404, put(box, headers, "/hdmi", {"input3": {"name": "x"}})[0])
        self.assertEqual(200, put(box, headers, "/device", {"name": "Den", "ledMode": 2})[0])
        self.assertEqual(13, put(box, headers, "/device", {"action": "doSoftwareRestart"})[1]["code"])
        bridge = {"bridgeUniqueId": "001788fffe123abc", "username": "x", "clientKey": "0" * 32}
        self.assertEqual(13, put(box, headers, "/hue", bridge)[1]["code"])
        self.assertEqual(404, box.request("POST", "/execution", headers, "{}")[0])

    def test_stopping_another_apps_stream(self):
        box, headers = paired()
        box.event("bridge", state="busy")
        self.assertEqual("other-app", box.get("hue.groups.%s.owner" % TV))
        self.assertEqual(200, put(box, headers, "/hue/groups/" + TV, {"active": False})[0])
        self.assertEqual("connected", box.get("hue.connectionState"))
        self.assertNotIn("owner", box.get("hue.groups.%s" % TV))
        self.assertEqual(15, put(box, headers, "/hue/groups/" + TV, {"active": True})[1]["code"])


class TestRegistrations(unittest.TestCase):
    def test_ids_are_never_reused_and_tokens_are_placeholders(self):
        box, headers = paired()
        self.assertEqual(200, box.request("DELETE", "/registrations/7", headers)[0])
        self.assertEqual(401, box.request("GET", "", headers)[0])
        box.event("button")
        status, body = box.request("POST", "/registrations", {}, {"appName": "c4-hue", "instanceName": "Again"})
        self.assertEqual((200, "8", model.TOKEN + "-8"), (status, body["registrationId"], body["accessToken"]))

    def test_a_token_factory_gives_the_tokens(self):
        box = model.Box("HSB2", fixtures=FIXTURES, token_factory=lambda reg: "RANDOM-%s" % reg)
        box.event("button")
        body = box.request("POST", "/registrations", {}, {"appName": "a", "instanceName": "b"})[1]
        self.assertEqual("RANDOM-7", body["accessToken"])

    def test_another_registrations_token_cannot_delete_it(self):
        box, headers = paired()
        self.assertEqual(401, box.request("DELETE", "/registrations/1", headers)[0])
        self.assertEqual(404, box.request("DELETE", "/registrations/999", headers)[0])
        box.event("app_deletes", registration="1")
        self.assertNotIn("1", box.get("registrations"))
        with self.assertRaises(ValueError):
            box.event("app_deletes", registration="1")

    def test_registration_body_checks_come_before_the_button(self):
        box = model.Box("HSB2", fixtures=FIXTURES)
        self.assertEqual(15, box.request("POST", "/registrations", {}, {"appName": "a"})[1]["code"])
        self.assertEqual(13, box.request("POST", "/registrations", {}, {"appName": "a", "x": 1})[1]["code"])
        names = {"appName": "a", "instanceName": "b"}
        self.assertEqual(16, box.request("POST", "/registrations", {}, names)[1]["code"])


class TestEvents(unittest.TestCase):
    def test_powersave_masks_linked_ports_and_the_signal(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "powersave"})
        self.assertEqual("plugged", box.get("hdmi.input1.status"))
        self.assertEqual("", box.get("hdmi.contentSpecs"))
        self.assertFalse(box.get("hdmi.videoSyncSupported"))
        put(box, headers, "/execution", {"hdmiActive": True})
        self.assertEqual("linked", box.get("hdmi.input1.status"))
        self.assertEqual("3840 x 2160 @ 60000 - HDR10", box.get("hdmi.contentSpecs"))

    def test_autosync_on_a_new_link_but_never_on_a_request(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "powersave"})
        put(box, headers, "/execution", {"hdmiActive": True})
        self.assertEqual("passthrough", box.get("execution.mode"))  # a request never auto-syncs
        box.event("signal", input=1, status="plugged")
        box.event("signal", input=1, status="linked")
        self.assertEqual("video", box.get("execution.mode"))

    def test_cec_wake_onto_a_linked_input_autosyncs(self):
        box, headers = paired()
        put(box, headers, "/execution", {"mode": "powersave"})
        box.event("cec_active_source", input=1)
        self.assertEqual("video", box.get("execution.mode"))
        box.event("cec_active_source", input=3)  # cecInputSwitch 0 there
        self.assertEqual("input1", box.get("execution.hdmiSource"))
        box.event("cec_active_source", input=9)  # an input the model lacks: nothing
        self.assertEqual("input1", box.get("execution.hdmiSource"))

    def test_hotplug_plugs_and_switches_with_the_flags(self):
        box, headers = paired("HSB1")
        box.event("hotplug", input="input3")
        self.assertEqual("plugged", box.get("hdmi.input3.status"))
        self.assertEqual("input3", box.get("execution.hdmiSource"))  # HSB1's hpdInputSwitch is 1
        del headers

    def test_losing_the_link_ends_a_sync_and_idle_powers_down(self):
        box, headers = paired()
        box.event("signal", input="input1", status="unplugged")
        self.assertEqual("passthrough", box.get("execution.mode"))
        box.event("idle", minutes=19)
        self.assertEqual("passthrough", box.get("execution.mode"))
        box.event("idle", minutes=20)
        self.assertEqual("powersave", box.get("execution.mode"))
        with self.assertRaises(ValueError):
            box.event("signal", input=1, status="glowing")
        del headers

    def test_tv_standby_and_usb_power(self):
        box, _ = paired("HSB2")  # usbPowersave 0
        box.event("usb_power_lost")
        self.assertEqual("video", box.get("execution.mode"))
        box.event("tv_standby")
        self.assertEqual("powersave", box.get("execution.mode"))

    def test_bridge_events(self):
        box, headers = paired()
        box.event("bridge", state="connected")
        self.assertEqual("streaming", box.get("hue.connectionState"))
        box.event("bridge", state="disconnected")
        self.assertEqual(("passthrough", "disconnected"), (box.get("execution.mode"), box.get("hue.connectionState")))
        self.assertEqual(16, put(box, headers, "/execution", {"syncActive": True})[1]["code"])
        with self.assertRaises(ValueError):
            box.event("bridge", state="sideways")

    def test_reboot_and_firmware(self):
        box, headers = paired("HSB1")
        box.event("button")
        box.event("firmware", version="2.6.1", api_level=14)
        self.assertEqual((None, None), box.request("GET", "", headers))
        self.assertFalse(box.available())
        box.event("advance", ms=30000)
        self.assertTrue(box.available())
        self.assertFalse(box.status()["pairing_open"])
        state = box.request("GET", "", headers)[1]
        self.assertEqual((2060100, 14), (state["device"]["buildNumber"], state["device"]["apiLevel"]))
        self.assertEqual(TV, state["hue"]["groupId"])
        self.assertEqual(0, state["behavior"]["input2"]["hpdInputPortSwitch"])
        self.assertEqual(0, state["behavior"]["soloMode"])
        self.assertNotIn("operatingMode", state["hue"])  # HSB1 has no bridge-free mode
        self.assertFalse(state["registrations"]["1"]["verified"])

    def test_address_and_operating_mode(self):
        box, _ = paired("HSB3")
        box.event("address", address="10.0.2.152", port=8444)
        self.assertEqual("10.0.2.152", box.get("device.ipAddress"))
        box.event("operating_mode", mode="standalone")
        self.assertEqual("standalone", box.get("hue.operatingMode"))
        with self.assertRaises(ValueError):
            model.Box("HSB1", fixtures=FIXTURES).event("operating_mode", mode="standalone")

    def test_unknown_events_and_arguments(self):
        box = model.Box("HSB2", fixtures=FIXTURES)
        with self.assertRaises(ValueError):
            box.event("explode")
        with self.assertRaises(ValueError):
            box.event("rename")
        with self.assertRaises(ValueError):
            box.event("tv_standby", now=True)


class TestSetGetStatusHistory(unittest.TestCase):
    def test_set_unset_get(self):
        box = model.Box("HSB2", fixtures=FIXTURES)
        box.set("hue.connectionState", "busy")
        self.assertEqual("busy", box.get("hue.connectionState"))
        box.set("hdmi.contentSpecs", "1280 x 720 @ 50000 - SDR")
        self.assertEqual("1280 x 720 @ 50000 - SDR", box.get("hdmi.contentSpecs"))
        box.unset("device.undervolt")
        with self.assertRaises(KeyError):
            box.get("device.undervolt")
        with self.assertRaises(KeyError):
            box.set("nothing.here", 1)
        with self.assertRaises(ValueError):
            box.set("registrations.1.role", "user")

    def test_status_and_history(self):
        box, _ = paired()
        status = box.status()
        self.assertEqual(["1", "7"], status["registrations"])
        self.assertEqual(["7"], status["paired"])
        self.assertFalse(status["restarting"])
        box.event("tv_standby")
        self.assertTrue(any("powersave" in item["text"] for item in box.history))
        self.assertNotIn(model.TOKEN, json.dumps(box.history))


if __name__ == "__main__":
    unittest.main()
