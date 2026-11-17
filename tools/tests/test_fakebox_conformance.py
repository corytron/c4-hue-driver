"""The conformance probe (tools/fakebox/conformance.py) against the Python fake box (#547).

The probe settles docs/syncbox-behaviour.md's rules against a real box; here it runs against the fake
of tools/fakebox/server.py, which keeps those rules, so every rule the probe checks must read
"confirmed", and a fake answer altered on purpose must read "contradicted". The hands-on steps run
too, the owner's physical actions played by the fake's events (a source's CEC and link, a cable, the
bridge's link, a restart). The probe trusts the fake's CA (its --cafile test option) instead of
Signify's root.

Also: what the probe writes holds no box id, address, name or token (the fake's box id and address
here are not the placeholders, so the redaction is seen to work); the restore brings the box back;
the identity check refuses another CA and another box; plan_restore, the redactor, and §16 of the
behaviour document against the probe's checks and steps.

Nothing leaves 127.0.0.1; ports are picked free; files go to temporary folders. Without the fake
(tools/fakebox/server.py) or the openssl command the probe tests skip with that reason.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_conformance.py -v
"""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

from fakebox import conformance  # noqa: E402

try:
    from fakebox import ca, model, server  # noqa: E402
except ImportError as error:  # agent F1's or F2's modules are not there yet
    ca = model = server = None
    FAKE_MISSING = "tools/fakebox/server.py, model.py or ca.py cannot be imported yet: %s" % error
else:
    FAKE_MISSING = None if shutil.which("openssl") else "the openssl command is not installed"

SCRIPT = os.path.join(TOOLS, "fakebox", "conformance.py")
BEHAVIOUR = os.path.join(ROOT, "docs", "syncbox-behaviour.md")
BOX_ID = "ABCDEF012345"  # not a placeholder: nothing written may hold it
ADDRESS = "192.168.1.77"  # the device.ipAddress the fake reports; never written either
FAST = {"settle_s": 1.0, "steady_s": 0.0, "poll_s": 0.01, "hands_wait_s": 5.0, "restart_silence_s": (0.3, 20.0)}
# What the fake cannot show: SB97 needs a standalone box; the rest are the rules no check covers.
EXPECT_NOT_CHECKED = {"SB97"}
HANDS_RULES = {"SB56", "SB63", "SB70", "SB71", "SB72", "SB73", "SB74", "SB78", "SB82", "SB91", "SB93", "SB120"}

CERTS = None


def setUpModule():
    global CERTS
    if FAKE_MISSING:
        return
    CERTS = tempfile.mkdtemp(prefix="conformance-certs-")
    ca.ensure_ca(CERTS)


def tearDownModule():
    if CERTS:
        shutil.rmtree(CERTS, ignore_errors=True)


def start_fake(fixture="HSB2", box_id=BOX_ID, time_scale=20.0):
    box = server.make_box(fixture, box_id, fixtures=model.load_fixtures(), time_scale=time_scale, address=ADDRESS)
    fake = server.BoxServer(box, port=0, cert_base=CERTS, log=lambda *_: None)
    fake.start()
    return fake


def client_for(fake):
    return conformance.BoxClient("127.0.0.1", fake.port, cafile=ca.ensure_ca(CERTS), pace_s=0.0, timeout_s=5.0)


def press(fake):
    return lambda _which: fake.call(lambda box: box.event("button"))


class Quiet:
    """A log that keeps every line (to search for secrets) and prints nothing."""

    def __init__(self):
        self.lines = []

    def __call__(self, text):
        self.lines.append(str(text))

    @property
    def text(self):
        return "\n".join(self.lines)


def files_under(folder):
    for base, _, names in os.walk(folder):
        for name in names:
            yield os.path.join(base, name)


@unittest.skipIf(FAKE_MISSING, FAKE_MISSING or "")
class TestAgainstTheFake(unittest.TestCase):
    """register --twice, run, the four hands-on steps and forget, on one fake HSB2."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="conformance-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = os.path.join(self.tmp, "out")
        self.store = conformance.Store(os.path.join(self.tmp, "cfg", "probe.json"))
        self.fake = start_fake()
        self.addCleanup(self.fake.stop)
        self.log = Quiet()

    def events(self, step, phase):
        """The owner's physical action of each hands-on step, as the fake's events."""
        plays = {
            (2, "off"): [("signal", {"input": "input1", "status": "plugged"})],
            (2, "on"): [
                ("cec_active_source", {"input": "input1"}),
                ("signal", {"input": "input1", "status": "linked"}),
            ],
            (3, "out"): [("signal", {"input": "input1", "status": "unplugged"})],
            (3, "in"): [("hotplug", {"input": "input1"}), ("signal", {"input": "input1", "status": "linked"})],
            (4, "pull"): [("bridge", {"state": "disconnected"})],
            (4, "plug"): [("bridge", {"state": "connected"})],
            (5, "restart"): [("reboot", {})],
        }
        for name, args in plays[(step, phase)]:
            self.fake.call(lambda box, n=name, a=args: box.event(n, **a))

    def test_every_check_confirms_and_the_box_is_restored(self):
        start = self.fake.call(lambda box: box.state())
        conformance.register(
            client_for(self.fake), self.store, twice=True, wait_s=2.0, every_s=0.01, log=self.log,
            on_wait=press(self.fake), out_dir=self.out,
        )  # fmt: skip
        entry = self.store.box(BOX_ID)
        self.assertTrue(entry and entry.get("token") and entry["second"].get("token"), "two registrations stored")
        tokens = [entry["token"], entry["second"]["token"]]
        self.assertEqual(0o600, stat.S_IMODE(os.stat(self.store.path).st_mode))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(os.path.dirname(self.store.path)).st_mode))

        code, final, run = conformance.run_probe(
            client_for(self.fake), self.store, out_dir=self.out, log=self.log, **FAST
        )
        self.assertEqual(0, code, self.log.text)
        checked = set()
        for _, _, rules, _ in conformance.CHECKS:
            checked |= set(rules)
        checked |= {"SB3", "SB4", "SB8", "SB10", "SB11", "SB90", "SB113"}
        verdicts = run.v.items
        wrong = {
            r: [e["detail"] for e in verdicts.get(r, ())]
            for r in sorted(checked - EXPECT_NOT_CHECKED)
            if conformance.combine(verdicts.get(r, [])) != "confirmed"
        }
        self.assertEqual({}, wrong, "rules the run did not confirm on the fake")
        self.assertEqual("not checked", final["SB97"])
        # The restore: what the probe changed reads as before.
        now = self.fake.call(lambda box: box.state())
        self.assertEqual([], conformance.restore_diff(start, now))
        self.assertNotIn("second", self.store.box(BOX_ID), "the second registration was deleted by SB86's check")

        for step in (2, 3, 4, 5):
            code, items, _ = conformance.hands_probe(
                client_for(self.fake), self.store, step, out_dir=self.out, log=self.log,
                on_prompt=self.events, **FAST,
            )  # fmt: skip
            self.assertEqual(0, code, "step %d\n%s" % (step, self.log.text))
            bad = {r: e for r, e in items.items() if conformance.combine(e) != "confirmed"}
            self.assertEqual({}, bad, "hands-on step %d" % step)
        now = self.fake.call(lambda box: box.state())
        self.assertEqual([], conformance.restore_diff(start, now))

        path, final = conformance.write_report(self.out)
        unsettled = sorted(r for r in HANDS_RULES if final.get(r) != "confirmed")
        self.assertEqual([], unsettled, "hands-on rules not confirmed")
        contradicted = sorted(r for r, v in final.items() if v == "contradicted")
        self.assertEqual([], contradicted)
        with open(path, encoding="utf-8") as handle:
            report = handle.read()
        self.assertIn("| SB2 | yes | confirmed |", report)

        # Nothing written or printed holds a token, the box's id or address, or a name of the house.
        secrets = tokens + [BOX_ID, BOX_ID.lower(), ADDRESS, "127.0.0.1", "Living Room Sync Box", "Apple TV"]
        for name in files_under(self.out):
            with open(name, encoding="utf-8") as handle:
                text = handle.read()
            for secret in secrets:
                self.assertNotIn(secret, text, "%s holds %r" % (name, secret[:6]))
        for token in tokens:
            self.assertNotIn(token, self.log.text)
        fixtures = os.listdir(os.path.join(self.out, "fixtures"))
        for name in ("device_unkeyed.json", "device.json", "errors.json", "registrations.json", "state_start.json"):
            self.assertIn(name, fixtures)
        with open(os.path.join(self.out, "fixtures", "state_start.json"), encoding="utf-8") as handle:
            state = json.load(handle)
        self.assertEqual("0A1B2C3D4E5F", state["device"]["uniqueId"])
        self.assertEqual("10.0.2.150", state["device"]["ipAddress"])

        # forget through the command line, under python3 -I.
        result = subprocess.run(
            [sys.executable, "-I", SCRIPT, "forget", "--address", "127.0.0.1:%d" % self.fake.port,
             "--cafile", ca.ensure_ca(CERTS), "--probe-file", self.store.path, "--out", self.out, "--pace-ms", "0"],
            capture_output=True, text=True, timeout=60, check=False,
        )  # fmt: skip
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        for token in tokens:
            self.assertNotIn(token, result.stdout + result.stderr)
        self.assertFalse(os.path.exists(self.store.path))
        regs = self.fake.call(lambda box: box.state()["registrations"])
        self.assertEqual(["1"], sorted(regs), "only the Hue Sync app's registration is left")


@unittest.skipIf(FAKE_MISSING, FAKE_MISSING or "")
class TestContradictionsAndIdentity(unittest.TestCase):
    """An altered fake reads contradicted; another CA or another box stops the probe."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="conformance-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = os.path.join(self.tmp, "out")
        self.store = conformance.Store(os.path.join(self.tmp, "probe.json"))
        self.fake = start_fake()
        self.addCleanup(self.fake.stop)
        self.log = Quiet()
        conformance.register(
            client_for(self.fake), self.store, wait_s=2.0, every_s=0.01, log=self.log, on_wait=press(self.fake),
            out_dir=self.out,
        )  # fmt: skip

    def test_an_altered_answer_reads_contradicted(self):
        box = self.fake.box
        real = box.request

        def altered(method, path, headers=None, body=None):
            if method == "GET" and str(path).endswith("/nothing"):
                return 404, {"code": 99, "message": "Elsewhere"}
            if method == "PUT" and str(path).endswith("/execution") and body in (b"{}", "{}"):
                return 200, {}
            return real(method, path, headers, body)

        box.request = altered
        code, final, run = conformance.run_probe(
            client_for(self.fake), self.store, only=["SB2", "SB17"], out_dir=self.out, log=self.log, **FAST
        )
        self.assertEqual(0, code)
        self.assertEqual("contradicted", final["SB2"])
        self.assertEqual("contradicted", final["SB17"])
        details = " ".join(e["detail"] for e in run.v.items["SB2"] if e["verdict"] == "contradicted")
        self.assertIn('"code":99', details)
        self.assertEqual("confirmed", conformance.combine(run.v.items["SB10"]))
        self.assertNotIn("SB42", run.v.items, "--only leaves the other checks out")

    def test_another_ca_stops_the_probe_before_any_token(self):
        self.fake.faults.add("wrong_cert")
        with self.assertRaisesRegex(conformance.ProbeError, "does not chain"):
            conformance.run_probe(client_for(self.fake), self.store, out_dir=self.out, log=self.log, **FAST)

    def test_another_box_at_the_address_stops_the_probe(self):
        self.fake.faults.add("other_id")
        with self.assertRaisesRegex(conformance.ProbeError, "another box"):
            conformance.run_probe(client_for(self.fake), self.store, out_dir=self.out, log=self.log, **FAST)
        self.assertFalse(any(e.get("keyed") for e in self.fake.recent(50) if e.get("path") != "/api/v1/registrations"))

    def test_the_guard_refuses_what_is_never_sent(self):
        run = conformance.Run(client_for(self.fake), self.store, out_dir=self.out, log=self.log)
        run.identify()
        run.begin()
        for method, path, body in (
            ("PUT", "/hue", {"bridgeUniqueId": "x", "username": "y", "clientKey": "z"}),
            ("PUT", "/device", {"action": "doSoftwareRestart"}),
            ("PUT", "/device", {"update": {"autoUpdateEnabled": False}}),
            ("PUT", "/ir/scan", {"active": True}),
            ("POST", "/presets", {"name": "x"}),
            ("DELETE", "/registrations/1", None),
            ("PUT", "/behavior", {"hpdOutputEnableMs": 1}),
            ("PUT", "/behavior", {"input1": {"hdrMode": 1}}),
        ):
            with self.subTest(method=method, path=path):
                before = self.fake.recent(1)
                with self.assertRaisesRegex(conformance.ProbeError, "guard"):
                    run.req(method, path, body)
                self.assertEqual(before, self.fake.recent(1), "nothing reached the box")


class TestPieces(unittest.TestCase):
    """The probe's pure parts."""

    def test_plan_restore_brings_back_mode_input_and_last_sync_modes(self):
        inputs = ["input1", "input2"]

        def state(mode, source, last, l1, l2):
            return {
                "execution": {"mode": mode, "hdmiSource": source, "lastSyncMode": last},
                "hdmi": {"input1": {"lastSyncMode": l1}, "input2": {"lastSyncMode": l2}},
            }

        snap = state("video", "input1", "video", "video", "game")
        self.assertEqual(
            [{"hdmiSource": "input2", "mode": "game"}, {"hdmiSource": "input1", "mode": "video"}],
            conformance.plan_restore(snap, state("passthrough", "input1", "music", "music", "video"), inputs),
        )
        snap = state("powersave", "input2", "video", "video", "game")
        plan = conformance.plan_restore(snap, state("game", "input1", "game", "game", "game"), inputs)
        self.assertEqual(
            [{"mode": "video"}, {"mode": "passthrough"}, {"hdmiSource": "input2"}, {"mode": "powersave"}], plan
        )
        self.assertEqual([], conformance.plan_restore(snap, snap, inputs))
        moved = state("passthrough", "input2", "video", "video", "game")
        self.assertEqual([{"mode": "powersave"}], conformance.plan_restore(snap, moved, inputs))

    def test_the_redactor_replaces_ids_addresses_names_and_secrets(self):
        r = conformance.Redactor()
        r.learn(
            {
                "device": {"uniqueId": "AB12CD000000", "ipAddress": "192.168.4.20", "name": "Den Box",
                           "wifi": {"ssid": "HomeNet5"}},
                "hue": {"bridgeUniqueId": "ab12cdfffe000000", "bridgeIpAddress": "192.168.4.2",
                        "groups": {"11111111-2222-4333-8444-555555555555": {"name": "Den TV"}}},
                "hdmi": {"input1": {"name": "Shield"}, "output": {"name": "OLED"}},
                "registrations": {"3": {"appName": "HomeHub", "instanceName": "Kitchen iPad"}},
            },
            address="192.168.4.20",
        )  # fmt: skip
        r.secret("SECRET-TOKEN-VALUE")
        text = r.text("box AB12CD000000 at 192.168.4.20 (bridge 192.168.4.2, ab12cdfffe000000), Den Box, "
                      "Den TV, Shield, SECRET-TOKEN-VALUE, 11111111-2222-4333-8444-555555555555, 198.51.100.77")  # fmt: skip
        for gone in ("AB12CD000000", "192.168.4.20", "192.168.4.2", "ab12cdfffe000000", "Den Box", "Den TV",
                     "Shield", "SECRET-TOKEN-VALUE", "11111111-2222", "198.51.100.77"):  # fmt: skip
            self.assertNotIn(gone, text)
        for placeholder in ("0A1B2C3D4E5F", "10.0.2.150", "10.0.2.143", "001788fffe123abc", "<redacted>"):
            self.assertIn(placeholder, text)
        body = r.json(
            {"accessToken": "abc", "clientKey": "k", "registrations": {"3": {"appName": "HomeHub",
             "instanceName": "Kitchen iPad"}}, "name": "Unknown Name", "wifi": {"ssid": "HomeNet5"}}
        )  # fmt: skip
        self.assertEqual("<redacted>", body["accessToken"])
        self.assertEqual("<redacted>", body["clientKey"])
        self.assertNotIn("HomeHub", json.dumps(body))
        self.assertNotIn("Kitchen iPad", json.dumps(body))
        self.assertEqual("Name", body["name"])
        self.assertEqual("ExampleNet", body["wifi"]["ssid"])

    def test_split_address_combine_and_cycle(self):
        self.assertEqual(("10.0.2.150", 443), conformance.split_address("10.0.2.150"))
        self.assertEqual(("127.0.0.1", 8450), conformance.split_address("127.0.0.1:8450"))
        self.assertEqual(("10.0.2.150", 8443), conformance.split_address("10.0.2.150", 8443))
        c = conformance.combine
        self.assertEqual("contradicted", c([{"verdict": "confirmed"}, {"verdict": "contradicted"}]))
        self.assertEqual("confirmed", c([{"verdict": "not checked"}, {"verdict": "confirmed"}]))
        self.assertEqual("not checked", c([]))
        self.assertEqual("music", conformance.cycle(conformance.SYNC_CYCLE, "video", "next"))
        self.assertEqual("game", conformance.cycle(conformance.SYNC_CYCLE, "video", "previous"))

    def test_store_keeps_tokens_private_and_removes_the_file_when_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = conformance.Store(os.path.join(tmp, "cfg", "probe.json"))
            store.put("0A1B2C3D4E5F", {"registration": "7", "token": "TEST-TOKEN-NOT-REAL"})
            self.assertEqual(0o600, stat.S_IMODE(os.stat(store.path).st_mode))
            self.assertEqual("7", store.box("0A1B2C3D4E5F")["registration"])
            store.put("0A1B2C3D4E5F", None)
            self.assertFalse(os.path.exists(store.path))

    def test_the_command_line_runs_under_python_isolated(self):
        result = subprocess.run([sys.executable, "-I", SCRIPT, "--help"], capture_output=True, text=True, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("VISIBLE CHANGES", result.stdout)
        result = subprocess.run([sys.executable, "-I", SCRIPT, "hands", "--list"], capture_output=True, text=True,
                                check=False)  # fmt: skip
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(len(conformance.HANDS_STEPS), len(result.stdout.strip().splitlines()))

    def test_a_cafile_that_is_missing_is_refused(self):
        with self.assertRaises(conformance.ProbeError):
            conformance.pinned_context("/nonexistent/hsb_ca.pem")
        conformance.pinned_context(os.path.join(ROOT, "src", "hue_syncbox", "certs", "hsb_ca.pem"))


class TestSection16(unittest.TestCase):
    """docs/syncbox-behaviour.md §16 against the probe: table A's rules are checked by `run`, table B's
    steps are the probe's hands-on steps (at most 10) and settle the rules they name, every [assumed]
    rule is in A, B or C."""

    @classmethod
    def setUpClass(cls):
        with open(BEHAVIOUR, encoding="utf-8") as handle:
            text = handle.read()
        cls.section = text.split("## 16.", 1)[1]
        cls.rules = dict(conformance.behaviour_rules(BEHAVIOUR))

    def table(self, letter):
        part = re.split(r"^### ", self.section, flags=re.M)
        found = [p for p in part if p.startswith("%s." % letter)]
        self.assertEqual(1, len(found), "§16 has one table %s" % letter)
        return found[0]

    def test_table_a_rules_are_the_runs(self):
        checked = {"SB3", "SB4", "SB8", "SB10", "SB11", "SB90", "SB113"}
        for _, _, rules, _ in conformance.CHECKS:
            checked |= set(rules)
        a = set(re.findall(r"^\| (SB\d+) \|", self.table("A"), re.M))
        self.assertTrue(a)
        self.assertEqual(set(), a - checked, "table A names rules no check of `run` covers")

    def test_table_b_steps_are_the_probes(self):
        b = self.table("B")
        steps = [int(n) for n in re.findall(r"^\| (\d+) \|", b, re.M)]
        self.assertEqual(sorted(conformance.HANDS_STEPS), steps)
        self.assertLessEqual(len(steps), 10)
        for rule, step in re.findall(r"^\| (SB\d+) \| (\d+) \|", b, re.M):
            self.assertIn(rule, conformance.HANDS_STEPS[int(step)][2], "%s is not settled by step %s" % (rule, step))

    def test_every_assumed_rule_is_in_a_table(self):
        found = set(re.findall(r"^\| (SB\d+) \|", self.section, re.M))
        missing = sorted(r for r, assumed in self.rules.items() if assumed and r not in found)
        self.assertEqual([], missing)


if __name__ == "__main__":
    unittest.main()
