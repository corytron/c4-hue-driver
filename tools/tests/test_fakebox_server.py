"""Unit tests for tools/fakebox/server.py, control.py and tools/fakebox.py: the fake sync box over HTTPS (#547).

Each test class runs its boxes on 127.0.0.1, on ports the kernel picks, with the fake CA of
tools/fakebox/ca.py made in a temporary folder (openssl), so the tests run in parallel with anything.
Clients verify the chain against that CA and read the leaf's common name, as the drivers do (the host
name is not checked: the drivers set ssl_verify_host false). Nothing leaves this host.

Placeholders only: boxes 0A1B2C3D4E5F and 0A1B2C3D4E60, bridge 001788fffe123abc, tokens
TEST-TOKEN-NOT-REAL.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_server.py -v
"""

import http.client
import json
import os
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

from fakebox import ca, control, model, server  # noqa: E402

FIXTURES = model.load_fixtures()
BOX_ID = "0A1B2C3D4E5F"
OTHER_ID = "0A1B2C3D4E60"
TOKEN = model.TOKEN
CERTS = None  # the module's CA folder (setUpModule)


def setUpModule():
    global CERTS
    if not shutil.which("openssl"):
        raise unittest.SkipTest("the openssl command is not installed")
    CERTS = tempfile.mkdtemp(prefix="fakebox-certs-")
    ca.ensure_ca(CERTS)


def tearDownModule():
    if CERTS:
        shutil.rmtree(CERTS, ignore_errors=True)


def client_context(cafile=None):
    context = ssl.create_default_context(cafile=cafile or ca.ensure_ca(CERTS))
    context.check_hostname = False
    return context


def start_box(fixture="HSB2", box_id=BOX_ID, logs=None, **options):
    box = server.make_box(fixture, box_id, fixtures=FIXTURES, registrations={"7": TOKEN}, token_factory=None, **options)
    bs = server.BoxServer(box, port=0, cert_base=CERTS, log=(logs.append if logs is not None else None))
    return bs.start()


class Client:
    """One kept-alive HTTPS connection to a box."""

    def __init__(self, port, timeout=5.0, context=None):
        self.connection = http.client.HTTPSConnection(
            "127.0.0.1", port, context=context or client_context(), timeout=timeout
        )

    def leaf(self):
        self.connection.connect()
        cert = self.connection.sock.getpeercert()
        return dict(item[0] for item in cert["subject"])

    def call(self, method, path, body=None, token=TOKEN):
        headers = {"Authorization": "Bearer " + token} if token else {}
        data = json.dumps(body) if isinstance(body, dict) else body
        if data is not None:
            headers["Content-Type"] = "application/json"
        self.connection.request(method, "/api/v1" + path, body=data, headers=headers)
        response = self.connection.getresponse()
        raw = response.read()
        return response.status, (json.loads(raw) if raw else None), response

    def close(self):
        self.connection.close()


def call_once(port, method, path, body=None, token=TOKEN, timeout=5.0):
    client = Client(port, timeout=timeout)
    try:
        return client.call(method, path, body, token)
    finally:
        client.close()


class TestTLSAndRequests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.logs = []
        cls.bs = start_box(logs=cls.logs)

    @classmethod
    def tearDownClass(cls):
        cls.bs.stop()

    def setUp(self):
        with self.bs.lock:
            self.bs.faults.clear()

    def test_the_leaf_names_the_box_and_its_model_under_the_fake_ca(self):
        client = Client(self.bs.port)
        try:
            subject = client.leaf()
            self.assertEqual(BOX_ID, subject["commonName"])
            self.assertEqual("HSB2", subject["organizationalUnitName"])
            self.assertEqual("TLSv1.3", client.connection.sock.version())
        finally:
            client.close()

    def test_a_client_without_the_fake_ca_refuses_the_box(self):
        context = ssl.create_default_context()  # the system's roots only
        context.check_hostname = False
        with self.assertRaises(ssl.SSLCertVerificationError):
            Client(self.bs.port, context=context).leaf()

    def test_requests_answer_from_the_model_and_keep_the_connection(self):
        client = Client(self.bs.port)
        try:
            status, device, _ = client.call("GET", "/device", token=None)
            self.assertEqual((200, BOX_ID), (status, device["uniqueId"]))
            status, state, response = client.call("GET", "")
            self.assertEqual(200, status)
            self.assertEqual("application/json", response.getheader("Content-Type"))
            self.assertEqual("fakebox", response.getheader("Server"))
            self.assertNotIn(TOKEN, json.dumps(state))
            self.assertEqual((200, {}), client.call("PUT", "/execution", {"brightness": 90})[:2])
            self.assertEqual(90, client.call("GET", "/execution")[1]["brightness"])
            status, body, _ = client.call("GET", "", token="WRONG-TOKEN-NOT-REAL")
            self.assertEqual((401, 2), (status, body["code"]))
            status, body, _ = client.call("PUT", "/execution", "{nope")
            self.assertEqual((400, 12), (status, body["code"]))
        finally:
            client.close()

    def test_one_request_at_a_time(self):
        with self.bs.lock:
            self.bs.faults.add("latency", ms=300)
        times = []

        def one():
            started = time.monotonic()
            call_once(self.bs.port, "GET", "/hue")
            times.append(time.monotonic() - started)

        threads = [threading.Thread(target=one) for _ in range(2)]
        started = time.monotonic()
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertGreaterEqual(time.monotonic() - started, 0.58)
        self.assertGreaterEqual(max(times), 0.58)

    def test_the_log_shows_requests_and_never_a_token(self):
        call_once(
            self.bs.port, "PUT", "/hue", {"bridgeUniqueId": "001788fffe123abc", "username": "u", "clientKey": "k"}
        )
        entry = self.bs.recent(1)[0]
        self.assertEqual(("PUT", "/api/v1/hue", 400), (entry["method"], entry["path"], entry["status"]))
        self.assertEqual("7", entry["registration"])
        self.assertTrue(entry["keyed"])
        self.assertEqual(server.REDACTED, entry["body"]["username"])
        self.assertEqual(server.REDACTED, entry["body"]["clientKey"])
        self.assertIn("auth=<redacted> reg=7", self.logs[-1])
        everything = json.dumps(list(self.bs.entries)) + "\n".join(self.logs)
        self.assertNotIn(TOKEN, everything)

    def test_a_body_too_large_is_refused(self):
        # Only the header is sent: the box answers 413 at once and closes, without reading a body.
        client = Client(self.bs.port)
        try:
            headers = {"Authorization": "Bearer " + TOKEN, "Content-Length": str(server.MAX_REQUEST_BYTES + 1)}
            client.connection.request("PUT", "/api/v1/execution", headers=headers)
            self.assertEqual(413, client.connection.getresponse().status)
        finally:
            client.close()


class TestFaults(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bs = start_box()

    @classmethod
    def tearDownClass(cls):
        cls.bs.stop()

    def setUp(self):
        with self.bs.lock:
            self.bs.faults.clear()

    def fault(self, kind, **kwargs):
        with self.bs.lock:
            return self.bs.faults.add(kind, **kwargs)

    def test_latency_adds_to_the_answer(self):
        self.fault("latency", count=1, ms=250)
        started = time.monotonic()
        self.assertEqual(200, call_once(self.bs.port, "GET", "/hue")[0])
        self.assertGreaterEqual(time.monotonic() - started, 0.24)
        self.assertEqual("latency", self.bs.recent(1)[0]["fault"])

    def test_5xx(self):
        self.fault("5xx", count=1, status=503)
        status, body, _ = call_once(self.bs.port, "GET", "")
        self.assertEqual((503, 500), (status, body["code"]))
        self.assertEqual(200, call_once(self.bs.port, "GET", "")[0])  # the count is used up

    def test_silence_until_the_client_gives_up(self):
        self.fault("silence", count=1)
        started = time.monotonic()
        with self.assertRaises((TimeoutError, socket.timeout)):
            call_once(self.bs.port, "GET", "/device", token=None, timeout=0.5)
        self.assertLess(time.monotonic() - started, 3)
        deadline = time.monotonic() + 5  # the held request ends once the client is gone
        while time.monotonic() < deadline and not self.bs.recent(1)[0].get("fault") == "silence":
            time.sleep(0.05)
        self.assertEqual(200, call_once(self.bs.port, "GET", "/device", token=None)[0])

    def test_drop_and_truncated(self):
        self.fault("drop", count=1)
        with self.assertRaises(http.client.RemoteDisconnected):
            call_once(self.bs.port, "GET", "")
        self.fault("truncated", count=1)
        with self.assertRaises(http.client.IncompleteRead):
            call_once(self.bs.port, "GET", "")

    def test_oversized_and_redirect(self):
        self.fault("oversized", count=1, bytes=300000)
        client = Client(self.bs.port)
        try:
            client.connection.request("GET", "/api/v1", headers={"Authorization": "Bearer " + TOKEN})
            raw = client.connection.getresponse().read()
        finally:
            client.close()
        self.assertGreaterEqual(len(raw), 300000)
        self.assertIn("device", json.loads(raw))
        self.fault("redirect", count=1, location="https://10.0.2.143/elsewhere")
        status, _, response = call_once(self.bs.port, "GET", "/device", token=None)
        self.assertEqual((302, "https://10.0.2.143/elsewhere"), (status, response.getheader("Location")))

    def test_filters_by_path_and_method(self):
        self.fault("5xx", path="/execution", method="PUT")
        self.assertEqual(200, call_once(self.bs.port, "GET", "/execution")[0])
        self.assertEqual(500, call_once(self.bs.port, "PUT", "/execution", {"brightness": 100})[0])

    def test_wrong_cert_fails_verification_and_is_logged(self):
        self.fault("wrong_cert", count=1)
        with self.assertRaises(ssl.SSLCertVerificationError):
            Client(self.bs.port).leaf()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and self.bs.recent(1)[0]["method"] != "TLS":
            time.sleep(0.05)
        self.assertEqual(("TLS", "wrong_cert"), (self.bs.recent(1)[0]["method"], self.bs.recent(1)[0]["fault"]))
        self.assertEqual(BOX_ID, Client(self.bs.port).leaf()["commonName"])  # the count is used up
        self.fault("wrong_cert", count=1)  # the leaf is the box's own id, from the other CA
        wrong_ca = os.path.join(ca.wrong_base(CERTS), "ca.pem")
        self.assertEqual(BOX_ID, Client(self.bs.port, context=client_context(wrong_ca)).leaf()["commonName"])

    def test_other_id_behind_the_same_address(self):
        self.fault("other_id")
        client = Client(self.bs.port)
        try:
            self.assertEqual(OTHER_ID, client.leaf()["commonName"])
            self.assertEqual(OTHER_ID, client.call("GET", "/device", token=None)[1]["uniqueId"])
            self.assertEqual(OTHER_ID, client.call("GET", "")[1]["device"]["uniqueId"])
        finally:
            client.close()

    def test_refuse_and_restart_close_the_port(self):
        self.fault("refuse")
        time.sleep(0.3)
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", self.bs.port), timeout=2).close()
        with self.bs.lock:
            self.bs.faults.clear("refuse")
        time.sleep(0.3)
        self.assertEqual(200, call_once(self.bs.port, "GET", "/device", token=None)[0])
        self.bs.call(lambda box: box.event("reboot"))
        time.sleep(0.3)
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", self.bs.port), timeout=2).close()
        self.bs.call(lambda box: box.event("advance", ms=30000))
        time.sleep(0.3)
        self.assertEqual(200, call_once(self.bs.port, "GET", "/device", token=None)[0])

    def test_unknown_faults_and_counts_are_refused(self):
        with self.assertRaises(ValueError):
            self.fault("meteor")
        with self.assertRaises(ValueError):
            self.fault("drop", count=0)
        with self.assertRaises(ValueError):
            self.fault("drop", path="execution")


class TestFleetAndMove(unittest.TestCase):
    def test_two_boxes_on_their_own_ports(self):
        first = server.BoxServer(server.make_box("HSB2", BOX_ID, fixtures=FIXTURES), cert_base=CERTS, log=None)
        second = server.BoxServer(server.make_box("HSB3", OTHER_ID, fixtures=FIXTURES), cert_base=CERTS, log=None)
        fleet = server.Fleet([first, second]).start()
        try:
            self.assertNotEqual(first.port, second.port)
            self.assertEqual("HSB3", call_once(second.port, "GET", "/device", token=None)[1]["deviceType"])
            self.assertEqual(OTHER_ID, Client(second.port).leaf()["commonName"])
            self.assertIs(second, fleet.find(OTHER_ID.lower()))
            with self.assertRaises(LookupError):
                fleet.find()
            with self.assertRaises(LookupError):
                fleet.find("0A1B2C3D4E61")
        finally:
            fleet.stop()

    def test_move_to_another_port(self):
        bs = start_box()
        try:
            old = bs.port
            probe = socket.socket()
            probe.bind(("127.0.0.1", 0))
            new = probe.getsockname()[1]
            probe.close()
            bs.move(new)
            self.assertEqual(new, bs.port)
            self.assertEqual(200, call_once(new, "GET", "/device", token=None)[0])
            with self.assertRaises(ConnectionRefusedError):
                socket.create_connection(("127.0.0.1", old), timeout=2).close()
        finally:
            bs.stop()

    def test_random_tokens_and_parse_spec(self):
        box = server.make_box("HSB2", BOX_ID, fixtures=FIXTURES)
        box.event("button")
        token = box.request("POST", "/registrations", {}, {"appName": "c4-hue", "instanceName": "x"})[1]["accessToken"]
        self.assertNotIn("TEST-TOKEN", token)
        self.assertGreaterEqual(len(token), 32)
        self.assertEqual(("HSB3_standalone", BOX_ID, 8450), server.parse_spec("HSB3_standalone:0a1b2c3d4e5f:8450"))
        for bad in ("HSB2", "HSB2:XYZ", "HSB2:0A1B2C3D4E5F:port", "HSB2:0A1B2C3D4E5F:70000"):
            with self.assertRaises(ValueError):
                server.parse_spec(bad)


class TestControl(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state_dir = tempfile.mkdtemp(prefix="fakebox-state-")
        cls.bs = start_box()
        cls.bs.fixture = "HSB2"
        cls.stopped = threading.Event()
        cls.controller = control.Controller(server.Fleet([cls.bs]), on_stop=cls.stopped.set)
        cls.ctl = control.ControlServer(cls.controller).start()
        control.write_state(cls.state_dir, {"control_url": cls.ctl.url, "token": cls.ctl.token, "pid": os.getpid()})
        cls.client = control.Client(cls.state_dir)

    @classmethod
    def tearDownClass(cls):
        cls.ctl.stop()
        cls.bs.stop()
        shutil.rmtree(cls.state_dir, ignore_errors=True)

    def test_state_file_is_private(self):
        mode = stat.S_IMODE(os.stat(control.state_path(self.state_dir)).st_mode)
        self.assertEqual(0o600, mode)

    def test_commands(self):
        c = self.client
        self.assertEqual(BOX_ID, c.call("GET", "/boxes")["boxes"][0]["id"])
        self.assertTrue(c.call("POST", "/button", {"window": 10})["status"]["pairing_open"])
        c.call("POST", "/event", {"name": "rename", "args": {"name": "Den Box"}})
        self.assertEqual("Den Box", c.call("GET", "/state", query={"path": "device.name"})["value"])
        c.call("POST", "/set", {"path": "execution.brightness", "value": 42})
        state = c.call("GET", "/state")
        self.assertEqual(42, state["state"]["execution"]["brightness"])
        self.assertNotIn(TOKEN, json.dumps(state))
        fault = c.call("POST", "/fault", {"kind": "5xx", "count": 1, "params": {"status": 502}})["fault"]
        self.assertEqual("5xx", fault["kind"])
        self.assertEqual(502, call_once(self.bs.port, "GET", "")[0])
        self.assertEqual(200, call_once(self.bs.port, "GET", "")[0])
        c.call("POST", "/fault", {"kind": "latency", "params": {"ms": 1}})
        self.assertEqual(1, c.call("POST", "/clear", {"kind": "latency"})["cleared"])
        entries = c.call("GET", "/log", query={"n": 2})["entries"]
        self.assertEqual(2, len(entries))
        self.assertNotIn(TOKEN, json.dumps(entries))
        c.call("POST", "/set", {"path": "device.undervolt", "unset": True})
        with self.assertRaises(control.ControlError):
            c.call("GET", "/state", query={"path": "device.undervolt"})
        with self.assertRaises(control.ControlError):
            c.call("POST", "/event", {"name": "explode"})
        with self.assertRaises(control.ControlError):
            c.call("POST", "/fault", {"kind": "meteor"})
        with self.assertRaises(control.ControlError):
            c.call("GET", "/nothing")
        self.assertTrue(c.call("POST", "/stop")["ok"])
        self.assertTrue(self.stopped.is_set())

    def test_refused_without_the_token_or_with_another_host(self):
        def raw(headers):
            connection = http.client.HTTPConnection("127.0.0.1", self.ctl.port, timeout=5)
            try:
                connection.request("GET", "/boxes", headers=headers)
                return connection.getresponse().status
            finally:
                connection.close()

        self.assertEqual(403, raw({}))
        self.assertEqual(403, raw({control.TOKEN_HEADER: "0" * 32}))
        self.assertEqual(403, raw({control.TOKEN_HEADER: self.ctl.token, "Host": "evil.example:%d" % self.ctl.port}))
        self.assertEqual(200, raw({control.TOKEN_HEADER: self.ctl.token}))

    def test_no_state_file(self):
        with self.assertRaises(control.ControlError):
            control.Client(os.path.join(self.state_dir, "nothing"))


class TestCommandLine(unittest.TestCase):
    """tools/fakebox.py serve in a child process, driven by the other commands."""

    def run_cli(self, state_dir, *args):
        proc = subprocess.run(
            [sys.executable, "-I", os.path.join(TOOLS, "fakebox.py"), "--state-dir", state_dir, *args],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def test_serve_and_drive_it(self):
        state_dir = tempfile.mkdtemp(prefix="fakebox-cli-")
        self.addCleanup(shutil.rmtree, state_dir, True)
        command = [sys.executable, "-I", os.path.join(TOOLS, "fakebox.py"), "--state-dir", state_dir, "serve"]
        command += ["--box", "HSB2:%s:0" % BOX_ID, "--box", "HSB3:%s:0" % OTHER_ID, "--control-port", "0"]
        command += ["--cert-base", CERTS, "--placeholder-tokens", "--registration", "%s=7=%s" % (OTHER_ID, TOKEN)]
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        info_path = control.state_path(state_dir)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not os.path.exists(info_path) and child.poll() is None:
            time.sleep(0.1)
        if not os.path.exists(info_path):
            child.kill()
            self.fail("serve wrote no server.json: %s" % child.communicate(timeout=10)[0])
        with open(info_path, encoding="utf-8") as handle:
            info = json.load(handle)
        ports = {box["id"]: int(box["url"].rsplit(":", 1)[1].split("/")[0]) for box in info["boxes"]}

        rc, out, err = self.run_cli(state_dir, "button")
        self.assertEqual(1, rc)  # two boxes: --box is needed
        self.assertIn("several boxes", err)
        rc, out, _ = self.run_cli(state_dir, "button", "--box", BOX_ID)
        self.assertEqual(0, rc, out)
        body = {"appName": "c4-hue", "instanceName": "CLI"}
        self.assertEqual(200, call_once(ports[BOX_ID], "POST", "/registrations", body, token=None)[0])
        self.assertEqual(200, call_once(ports[OTHER_ID], "GET", "", token=TOKEN)[0])
        rc, out, _ = self.run_cli(state_dir, "event", "signal", "input=1", "status=unplugged", "--box", BOX_ID)
        self.assertEqual(0, rc, out)
        rc, out, _ = self.run_cli(state_dir, "state", "--box", BOX_ID, "--path", "execution.mode")
        self.assertEqual("passthrough", json.loads(out)["value"])
        rc, out, _ = self.run_cli(state_dir, "set", "execution.brightness", "150", "--box", BOX_ID)
        self.assertEqual(0, rc, out)
        rc, out, _ = self.run_cli(state_dir, "fault", "5xx", "status=503", "--count", "1", "--box", OTHER_ID)
        self.assertEqual(0, rc, out)
        self.assertEqual(503, call_once(ports[OTHER_ID], "GET", "", token=TOKEN)[0])
        rc, out, _ = self.run_cli(state_dir, "fault", "clear", "--box", OTHER_ID)
        self.assertEqual(0, rc, out)
        rc, out, _ = self.run_cli(state_dir, "log", "--box", OTHER_ID, "-n", "5")
        self.assertIn("auth=<redacted> reg=7", out)
        self.assertIn("[5xx]", out)
        self.assertNotIn(TOKEN, out)
        rc, out, _ = self.run_cli(state_dir, "boxes")
        self.assertEqual({BOX_ID, OTHER_ID}, {box["id"] for box in json.loads(out)["boxes"]})
        rc, out, _ = self.run_cli(state_dir, "stop")
        self.assertEqual(0, rc, out)
        output, _ = child.communicate(timeout=20)
        self.assertEqual(0, child.returncode, output)
        self.assertIn("fakebox: stopped", output)
        self.assertNotIn(TOKEN, output)
        self.assertNotIn(info["token"], output)
        self.assertFalse(os.path.exists(info_path))

    def test_commands_without_a_running_fake(self):
        state_dir = tempfile.mkdtemp(prefix="fakebox-cli-")
        self.addCleanup(shutil.rmtree, state_dir, True)
        rc, _, err = self.run_cli(state_dir, "state")
        self.assertEqual(1, rc)
        self.assertIn("no fake running", err)


if __name__ == "__main__":
    unittest.main()
