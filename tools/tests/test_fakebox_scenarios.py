"""The scenarios of tests/fixtures/syncbox_scenarios.json against the Python fake sync box (#547).

docs/fakebox-design.md §4: every scenario runs against tools/fakebox/model.py's Box (requests with
box.request, events with box.event, state checks on box.state()), and a sample of them once more
through tools/fakebox/server.py over real HTTPS, with the fake CA of tools/fakebox/ca.py in a
temporary folder. The Lua fake runs the same file (tests/spec/syncbox_scenarios_spec.lua): both fakes
keep the one behaviour of docs/syncbox-behaviour.md, whose §14 is the file's format. A scenario the
model fails is a failed subtest naming every mismatch of the step, never a skip.

The file itself is checked whether or not the model exists: version 1, at least 120 scenarios, unique
ids, known models and events, every rule of docs/syncbox-behaviour.md in at least one scenario and
every scenario's rules in the document, `assumed` true exactly when one of its rules is [assumed];
and tests/fixtures/hue_syncbox.json is what tools/fakebox/export_fixtures.lua writes (when lua5.1 is
installed). Without tools/fakebox/model.py (agent F1's) the model tests skip with that reason.

Placeholders only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL. Nothing leaves
127.0.0.1; ports are picked free; files go to a temporary folder.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_scenarios.py -v
"""

import copy
import http.client
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

SCENARIOS = os.path.join(ROOT, "tests", "fixtures", "syncbox_scenarios.json")
FIXTURES = os.path.join(ROOT, "tests", "fixtures", "hue_syncbox.json")
BEHAVIOUR = os.path.join(ROOT, "docs", "syncbox-behaviour.md")
EXPORT = os.path.join(TOOLS, "fakebox", "export_fixtures.lua")

try:
    from fakebox import model  # noqa: E402
except ImportError as error:  # agent F1's module is not there yet
    model = None
    MODEL_MISSING = "tools/fakebox/model.py (agent F1) cannot be imported yet: %s" % error
else:
    MODEL_MISSING = None

try:
    from fakebox import ca, server  # noqa: E402
except ImportError as error:
    ca = server = None
    SERVER_MISSING = "tools/fakebox/server.py or ca.py (agents F1, F2) cannot be imported yet: %s" % error
else:
    SERVER_MISSING = None

WRONG_TOKEN = "WRONG-TOKEN-NOT-REAL"
EVENTS = frozenset(
    {
        "button", "cec_active_source", "hotplug", "signal", "tv_standby", "usb_power_lost", "idle", "bridge",
        "rename", "app_deletes", "firmware", "reboot", "advance", "address",
    }
)  # fmt: skip
EXPECT_KEYS = frozenset(
    {"status", "code", "has", "state", "absent", "body", "body_absent", "body_exact", "present", "changed", "no_answer"}
)
# The scenarios also run over HTTPS (server.BoxServer): one of each kind of request and event.
HTTPS_SAMPLE = (
    "SC-REQ-1", "SC-REQ-2", "SC-REQ-4", "SC-REQ-8", "SC-STATE-6", "SC-ORDER-1", "SC-PAIR-1", "SC-PAIR-12",
    "SC-BRIDGE-4", "SC-EVT-12", "SC-DEV-4", "SC-BEH-6",
)  # fmt: skip

_MISSING = object()


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def behaviour_rules(text=None):
    """{"SB1": the rule's text, ...} from docs/syncbox-behaviour.md: every item "- **SBn** ...", to the
    next item or heading."""
    if text is None:
        with open(BEHAVIOUR, encoding="utf-8") as handle:
            text = handle.read()
    found = {}
    for match in re.finditer(r"^- \*\*(SB\d+)\*\* (.*?)(?=^- \*\*SB|^#|\Z)", text, re.S | re.M):
        found[match.group(1)] = match.group(2)
    return found


def lookup(node, path):
    """The value at a dotted path, or _MISSING."""
    for part in str(path).split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            return _MISSING
    return node


def set_path(node, path, value):
    parts = str(path).split(".")
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    node[parts[-1]] = copy.deepcopy(value)


def same(a, b):
    """JSON equality: true and 1 differ, 1 and 1.0 do not."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b, strict=True))
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    return type(a) is type(b) and a == b


def show(value):
    if value is _MISSING:
        return "(absent)"
    return json.dumps(value, sort_keys=True)


def describe(step):
    if "event" in step:
        args = " ".join("%s=%s" % (k, show(v)) for k, v in sorted(step.items()) if k not in ("event", "expect"))
        return ("event %s %s" % (step["event"], args)).rstrip()
    text = "%s %s" % (step["do"], step.get("path", ""))
    if "body" in step:
        text += " " + json.dumps(step["body"], sort_keys=True)
    elif "raw" in step:
        text += " raw " + json.dumps(step["raw"])
    return text


def mismatches(expect, status, body, before, after):
    """Every way one step's outcome differs from its expect, as text."""
    out = []
    if expect.get("no_answer"):
        if status is not None:
            out.append("expected no answer, got HTTP %s %s" % (status, show(body)))
    elif "status" in expect and status != expect["status"]:
        out.append("status: expected %s, got %s %s" % (expect["status"], status, show(body)))
    if "code" in expect:
        code = body.get("code", _MISSING) if isinstance(body, dict) else _MISSING
        if not same(code, expect["code"]):
            out.append("code: expected %s, got %s" % (expect["code"], show(code)))
    for key in expect.get("has", ()):
        if not isinstance(body, dict) or key not in body:
            out.append("body has no %s" % key)
    for path, want in sorted(expect.get("body", {}).items()):
        got = lookup(body, path)
        if got is _MISSING or not same(got, want):
            out.append("body %s: expected %s, got %s" % (path, show(want), show(got)))
    for path in expect.get("body_absent", ()):
        if lookup(body, path) is not _MISSING:
            out.append("body %s should be absent" % path)
    if "body_exact" in expect and not same(body, expect["body_exact"]):
        out.append("body: expected exactly %s, got %s" % (show(expect["body_exact"]), show(body)))
    for path, want in sorted(expect.get("state", {}).items()):
        got = lookup(after, path)
        if got is _MISSING or not same(got, want):
            out.append("state %s: expected %s, got %s" % (path, show(want), show(got)))
    for path in expect.get("absent", ()):
        got = lookup(after, path)
        if got is not _MISSING:
            out.append("state %s should be absent, is %s" % (path, show(got)))
    for path in expect.get("present", ()):
        if lookup(after, path) is _MISSING:
            out.append("state %s should be present" % path)
    for path in expect.get("changed", ()):
        old, new = lookup(before, path), lookup(after, path)
        if old is not _MISSING and new is not _MISSING and same(old, new):
            out.append("state %s should have changed, still %s" % (path, show(new)))
        elif new is _MISSING:
            out.append("state %s should have changed, is absent" % path)
    return out


class ScenarioFailure(AssertionError):
    pass


class Runner:
    """One scenario on one box. Subclasses say how a request and an event reach the box."""

    def __init__(self, scenario, fixtures):
        self.scenario = scenario
        self.fixtures = fixtures
        self.tokens = {}
        self.ids = {}
        self.paired = scenario.get("setup") == "paired"

    def initial_state(self):
        state = copy.deepcopy(self.fixtures["state"][self.scenario["model"]])
        for path in sorted(self.scenario.get("given", {})):
            set_path(state, path, self.scenario["given"][path])
        return state

    # What a subclass provides.
    def request(self, method, path, headers, body):  # -> (status or None, decoded body)
        raise NotImplementedError

    def event(self, name, args):
        raise NotImplementedError

    def view(self):
        raise NotImplementedError

    # The run.
    def token_for(self, step):
        name = step.get("token", "t" if self.paired else "none")
        if name == "none":
            return None
        if name == "wrong":
            return WRONG_TOKEN
        if name not in self.tokens:
            raise ScenarioFailure("no token saved as %r" % name)
        return self.tokens[name]

    def expand(self, path):
        def one(match):
            if match.group(1) not in self.ids:
                raise ScenarioFailure("no registration saved as %r" % match.group(1))
            return str(self.ids[match.group(1)])

        return re.sub(r"\{(\w+)\}", one, path or "")

    def step(self, number, step):
        expect = step.get("expect")
        before = self.view() if expect and expect.get("changed") else None
        status = body = None
        if "event" in step:
            self.event(step["event"], {k: v for k, v in step.items() if k not in ("event", "expect")})
        else:
            headers = {}
            token = self.token_for(step)
            if token is not None:
                headers["Authorization"] = "Bearer " + token
            if "raw" in step:
                data = step["raw"]
            elif "body" in step:
                data = json.dumps(step["body"])
            else:
                data = None
            if data is not None:
                headers["Content-Type"] = "application/json"
            status, body = self.request(step["do"], "/api/v1" + self.expand(step.get("path", "")), headers, data)
            if expect is None:  # a request without expect prepares the next steps: it must succeed
                expect = {"status": 200}
            if step.get("save_token") and status == 200 and isinstance(body, dict):
                self.tokens[step["save_token"]] = body.get("accessToken")
                self.ids[step["save_token"]] = body.get("registrationId")
        if expect is None:
            return
        needs_state = any(k in expect for k in ("state", "absent", "present", "changed"))
        after = self.view() if needs_state else None
        found = mismatches(expect, status, body, before, after)
        if found:
            raise ScenarioFailure(
                "%s step %d (%s):\n  %s" % (self.scenario["id"], number, describe(step), "\n  ".join(found))
            )

    def run(self):
        if self.paired:
            self.step(0, {"event": "button"})
            self.step(
                0,
                {
                    "do": "POST",
                    "path": "/registrations",
                    "token": "none",
                    "body": {"appName": self.fixtures["APP_NAME"], "instanceName": "Scenario"},
                    "save_token": "t",
                    "expect": {"status": 200, "has": ["registrationId", "accessToken"]},
                },
            )
        for number, step in enumerate(self.scenario["steps"], 1):
            self.step(number, step)


def decode(body):
    if body is None or isinstance(body, (dict, list)):
        return body
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    try:
        return json.loads(body) if body else None
    except ValueError:
        return body


class ModelRunner(Runner):
    """The scenario on model.Box, through box.request and box.event."""

    def __init__(self, scenario, fixtures):
        super().__init__(scenario, fixtures)
        self.box = model.Box(self.initial_state(), model.ManualClock())

    def request(self, method, path, headers, body):
        status, answer = self.box.request(method, path, headers, body)
        return status, decode(answer)

    def event(self, name, args):
        self.box.event(name, **args)

    def view(self):
        return self.box.state()


class HttpsRunner(ModelRunner):
    """The scenario on a model.Box served by server.BoxServer over HTTPS on 127.0.0.1: the chain
    checked against the fake CA, the leaf's common name against the box id (as the drivers' identity
    check does; the host name is not checked, as the drivers set ssl_verify_host false)."""

    def __init__(self, scenario, fixtures, cert_base):
        super().__init__(scenario, fixtures)
        self.server = server.BoxServer(self.box, port=0, cert_base=cert_base, log=lambda *_: None)
        self.server.start()
        self.context = ssl.create_default_context(cafile=ca.ensure_ca(cert_base))
        self.context.check_hostname = False
        self.box_id = self.box.box_id

    def close(self):
        self.server.stop()

    def request(self, method, path, headers, body):
        connection = http.client.HTTPSConnection("127.0.0.1", self.server.port, context=self.context, timeout=10)
        try:
            try:
                connection.connect()
            except (ConnectionError, socket.timeout, OSError):
                return None, None
            subject = dict(item[0] for item in connection.sock.getpeercert()["subject"])
            if subject.get("commonName") != self.box_id:
                raise ScenarioFailure("the leaf names %r, not the box %s" % (subject.get("commonName"), self.box_id))
            data = body.encode("utf-8") if isinstance(body, str) else body
            try:
                connection.request(method, path, body=data, headers=headers)
                response = connection.getresponse()
                raw = response.read()
            except (ConnectionError, http.client.HTTPException, socket.timeout, OSError):
                return None, None
            return response.status, decode(raw)
        finally:
            connection.close()

    def event(self, name, args):
        self.server.call(lambda box: box.event(name, **args))

    def view(self):
        return self.server.call(lambda box: box.state())


def scenarios():
    return load_json(SCENARIOS)["scenarios"]


class TestScenarioFile(unittest.TestCase):
    """The scenarios file and the fixtures' JSON, whatever the fakes do."""

    @classmethod
    def setUpClass(cls):
        cls.file = load_json(SCENARIOS)
        cls.fixtures = load_json(FIXTURES)
        cls.rules = behaviour_rules()

    def test_version_count_and_unique_ids(self):
        self.assertEqual(1, self.file["version"])
        ids = [s["id"] for s in self.file["scenarios"]]
        self.assertGreaterEqual(len(ids), 120)
        self.assertEqual(len(ids), len(set(ids)), "duplicate scenario ids")

    def test_models_steps_and_expects_are_known(self):
        for s in self.file["scenarios"]:
            with self.subTest(scenario=s["id"]):
                self.assertIn(s["model"], self.fixtures["models"])
                self.assertIn(s.get("setup"), (None, "paired"))
                self.assertTrue(s["steps"])
                for step in s["steps"]:
                    self.assertTrue(("do" in step) != ("event" in step), step)
                    if "event" in step:
                        self.assertIn(step["event"], EVENTS)
                    else:
                        self.assertIn(step["do"], ("GET", "PUT", "POST", "DELETE"))
                    self.assertLessEqual(set(step.get("expect", {})), EXPECT_KEYS, step)

    def test_every_rule_in_a_scenario_and_every_scenario_rule_in_the_document(self):
        self.assertGreater(len(self.rules), 50, "docs/syncbox-behaviour.md lost its rules")
        used = set()
        for s in self.file["scenarios"]:
            self.assertTrue(s["rules"], s["id"])
            for rule in s["rules"]:
                self.assertIn(rule, self.rules, "%s names %s, which the document lacks" % (s["id"], rule))
                used.add(rule)
        self.assertEqual([], sorted(set(self.rules) - used, key=lambda r: int(r[2:])), "rules without a scenario")

    def test_assumed_flag_follows_the_rules(self):
        for s in self.file["scenarios"]:
            assumed = any("assumed" in self.rules.get(r, "") for r in s["rules"])
            self.assertEqual(assumed, s.get("assumed"), s["id"])

    def test_every_assumed_rule_has_a_house_check_or_is_a_convention(self):
        with open(BEHAVIOUR, encoding="utf-8") as handle:
            text = handle.read()
        table = text.split("## 16.", 1)[1]
        checked = set(re.findall(r"^\| (SB\d+) \|", table, re.M))
        for rule, body in self.rules.items():
            if "assumed" in body:
                self.assertIn(rule, checked, "%s is [assumed] but §16 has no house check for it" % rule)

    @unittest.skipUnless(shutil.which("lua5.1"), "lua5.1 is not installed")
    def test_fixtures_json_is_the_export_of_the_lua_fixtures(self):
        result = subprocess.run(["lua5.1", EXPORT], capture_output=True, text=True, check=False, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        with open(FIXTURES, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), result.stdout, "run: lua5.1 %s > %s" % (EXPORT, FIXTURES))


@unittest.skipIf(model is None, MODEL_MISSING)
class TestModelScenarios(unittest.TestCase):
    """Every scenario against model.Box: one subtest each."""

    def test_scenarios(self):
        fixtures = load_json(FIXTURES)
        for s in scenarios():
            with self.subTest(scenario=s["id"], title=s.get("title")):
                try:
                    ModelRunner(s, fixtures).run()
                except ScenarioFailure:
                    raise
                except Exception as error:  # the model refused the step itself: report it as a failure
                    raise ScenarioFailure("%s: %s: %s" % (s["id"], type(error).__name__, error)) from error


@unittest.skipIf(model is None or server is None, MODEL_MISSING or SERVER_MISSING)
class TestServerScenarios(unittest.TestCase):
    """A sample of the scenarios over real HTTPS (server.BoxServer, the fake CA in a temporary folder)."""

    def setUp(self):
        self.cert_base = tempfile.mkdtemp(prefix="fakebox-scenarios-")
        self.addCleanup(shutil.rmtree, self.cert_base, True)

    def test_sample_over_https(self):
        fixtures = load_json(FIXTURES)
        by_id = {s["id"]: s for s in scenarios()}
        for scenario_id in HTTPS_SAMPLE:
            s = by_id[scenario_id]
            with self.subTest(scenario=scenario_id, title=s.get("title")):
                runner = HttpsRunner(s, fixtures, self.cert_base)
                try:
                    runner.run()
                except ScenarioFailure:
                    raise
                except Exception as error:
                    raise ScenarioFailure("%s: %s: %s" % (scenario_id, type(error).__name__, error)) from error
                finally:
                    runner.close()


class TestRunnerHelpers(unittest.TestCase):
    """The runner's own pieces, so a scenario failure is the fake's and not the runner's."""

    def test_lookup_and_set_path(self):
        doc = {"hue": {"groups": {"6a7b8c9d-0000-4000-8000-0000000ea001": {"active": True}}}, "a": [1, 2]}
        self.assertIs(True, lookup(doc, "hue.groups.6a7b8c9d-0000-4000-8000-0000000ea001.active"))
        self.assertIs(_MISSING, lookup(doc, "hue.groupId"))
        self.assertEqual(2, lookup(doc, "a.1"))
        set_path(doc, "presets.p1", {"name": "Movie"})
        self.assertEqual("Movie", lookup(doc, "presets.p1.name"))

    def test_same_keeps_booleans_apart_from_numbers(self):
        self.assertFalse(same(True, 1))
        self.assertFalse(same(0, False))
        self.assertTrue(same(2060000, 2060000.0))
        self.assertTrue(same({"a": [1, {"b": None}]}, {"a": [1, {"b": None}]}))
        self.assertFalse(same({}, {"a": 1}))

    def test_mismatches_names_each_difference(self):
        found = mismatches(
            {"status": 400, "code": 15, "state": {"execution.mode": "video"}, "absent": ["ir"], "has": ["x"]},
            200,
            {},
            None,
            {"execution": {"mode": "game"}, "ir": {}},
        )
        self.assertEqual(5, len(found), found)
        self.assertEqual([], mismatches({"no_answer": True}, None, None, None, None))
        self.assertEqual(1, len(mismatches({"no_answer": True}, 200, {}, None, None)))
        self.assertEqual(
            1, len(mismatches({"changed": ["r.t"]}, 200, {}, {"r": {"t": "a"}}, {"r": {"t": "a"}})), "unchanged"
        )

    def test_behaviour_rules_are_read_per_item(self):
        rules = behaviour_rules("# T\n\n- **SB1** one [assumed]\n  more.\n- **SB2** two [verified: x]\n\n## Next\n")
        self.assertEqual(["SB1", "SB2"], sorted(rules))
        self.assertIn("assumed", rules["SB1"])
        self.assertNotIn("assumed", rules["SB2"])


if __name__ == "__main__":
    unittest.main()
