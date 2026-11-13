"""Unit tests for tools/serve_install.py: only the named packages, under a random path, nothing
listed, gone when the server stops (security review 2026-11-13, I-1). The server runs on
127.0.0.1, port 0, over scratch packages; nothing else is contacted.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import hashlib
import io
import os
import re
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import zipfile
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import serve_install  # noqa: E402


def make_package(path, version="627", kind=None, devkey=False):
    """A small .c4z: driver.xml with its <version>, and the build's own stamps."""
    with zipfile.ZipFile(path, "w") as package:
        package.writestr("driver.xml", "<devicedata><version>%s</version></devicedata>" % version)
        package.writestr("driver.lua", "-- %s\n" % os.path.basename(path))
        if kind:
            package.writestr("common/build_kind.lua", 'return "%s"\n' % kind)
        if devkey:
            package.writestr("common/devkey.lua", 'return "%s"\n' % ("0" * 64))
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


class SyncOut(io.StringIO):
    """stdout for a server thread, read by the test thread."""

    def __init__(self):
        super().__init__()
        self.lock = threading.Lock()

    def write(self, text):
        with self.lock:
            return super().write(text)

    def text(self):
        with self.lock:
            return self.getvalue()


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = os.path.join(self.tmp.name, "build")
        os.mkdir(self.dir)
        self.sums = {}
        for name in ("hue_bridge.c4z", "hue_light.c4z"):
            self.sums[name] = make_package(os.path.join(self.dir, name), kind="dev", devkey=True)
        # What must never be reachable: other packages and files beside the named ones.
        make_package(os.path.join(self.dir, "hue_scene.c4z"))
        with open(os.path.join(self.dir, "manifest.json"), "w", encoding="utf-8") as handle:
            handle.write("{}")

    def named(self, *names):
        return [os.path.join(self.dir, name) for name in names or ("hue_bridge.c4z", "hue_light.c4z")]


class CheckPackagesTest(Case):
    def test_only_existing_c4z_packages_each_once(self):
        self.assertEqual(
            [("hue_bridge.c4z", self.named()[0]), ("hue_light.c4z", self.named()[1])],
            serve_install.check_packages(list(reversed(self.named()))),
        )
        other = os.path.join(self.tmp.name, "hue_bridge.c4z")
        make_package(other)
        for paths, reason in (
            ([], "at least one"),
            ([os.path.join(self.dir, "manifest.json")], "only <driver>.c4z packages"),
            ([os.path.join(self.dir, "missing.c4z")], "no such file"),
            ([self.dir], "only <driver>.c4z packages"),
            ([self.named()[0], other], "two packages named hue_bridge.c4z"),
            ([os.path.join(self.dir, "-x.c4z")], "only <driver>.c4z packages"),
        ):
            with self.subTest(paths=paths):
                with self.assertRaises(serve_install.ServeError) as caught:
                    serve_install.check_packages(paths)
                self.assertIn(reason, str(caught.exception))


class StageTest(Case):
    def test_copies_only_the_named_packages_under_a_random_segment(self):
        root, segment, entries = serve_install.stage(serve_install.check_packages(self.named()), max_workers=4)
        self.addCleanup(lambda: os.path.isdir(root) and shutil.rmtree(root))
        self.assertRegex(segment, r"^[0-9a-f]{32}$")
        self.assertEqual([segment], os.listdir(root))
        self.assertEqual(["hue_bridge.c4z", "hue_light.c4z"], sorted(os.listdir(os.path.join(root, segment))))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(root).st_mode))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(os.path.join(root, segment)).st_mode))
        for entry in entries:
            self.assertEqual(self.sums[entry["name"]], entry["sha256"])
            self.assertEqual(0o600, stat.S_IMODE(os.stat(entry["path"]).st_mode))
            self.assertEqual(("627", True), (entry["version"], entry["dev"]))
        self.assertFalse(os.path.commonpath([root, self.dir]) == self.dir, "never inside build/")
        second, other, _ = serve_install.stage(serve_install.check_packages(self.named()[:1]))
        shutil.rmtree(second)
        self.assertNotEqual(segment, other)

    def test_a_release_package_is_not_a_dev_build(self):
        release = os.path.join(self.tmp.name, "hue_motion.c4z")
        make_package(release, version="624", kind="release")
        old_dev = os.path.join(self.tmp.name, "hue_scene.c4z")
        make_package(old_dev, version="538", devkey=True)  # a dev build from before build_kind.lua
        self.assertEqual(("624", False), serve_install.describe(release))
        self.assertEqual(("538", True), serve_install.describe(old_dev))
        broken = os.path.join(self.tmp.name, "hue_broken.c4z")
        with open(broken, "wb") as handle:
            handle.write(b"not a zip")
        with self.assertRaises(serve_install.ServeError):
            serve_install.describe(broken)

    def test_a_failed_stage_leaves_no_folder(self):
        before = set(os.listdir(tempfile.gettempdir()))
        broken = os.path.join(self.tmp.name, "hue_broken.c4z")
        with open(broken, "wb") as handle:
            handle.write(b"not a zip")
        with self.assertRaises(serve_install.ServeError):
            serve_install.stage(serve_install.check_packages([broken]))
        after = {name for name in os.listdir(tempfile.gettempdir()) if name.startswith("c4-hue-install-")}
        self.assertEqual(set(), after - before)


class ServerTest(Case):
    def start(self, until_fetched=True):
        self.root, self.segment, self.entries = serve_install.stage(serve_install.check_packages(self.named()))
        self.addCleanup(lambda: shutil.rmtree(self.root, ignore_errors=True))
        self.out = SyncOut()
        self.server = serve_install.InstallServer(
            ("127.0.0.1", 0), self.segment, self.entries, until_fetched=until_fetched, out=self.out
        )
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def get(self, path, method="GET"):
        req = urllib.request.Request(self.base + path, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            with exc:
                return exc.code, exc.read()

    def test_serves_exactly_the_staged_files(self):
        self.start(until_fetched=False)
        status, body = self.get("/%s/hue_bridge.c4z" % self.segment)
        self.assertEqual(200, status)
        self.assertEqual(self.sums["hue_bridge.c4z"], hashlib.sha256(body).hexdigest())
        self.assertEqual((200, b""), self.get("/%s/hue_light.c4z" % self.segment, method="HEAD"))
        for path in (
            "/",
            "/index.html",
            "/%s" % self.segment,
            "/%s/" % self.segment,
            "/%s/hue_scene.c4z" % self.segment,
            "/%s/manifest.json" % self.segment,
            "/%s/../%s/hue_bridge.c4z" % (self.segment, self.segment),
            "/%s/hue_bridge.c4z" % ("0" * 32),
            "/hue_bridge.c4z",
            "/%s/hue_bridge.c4z/" % self.segment,
            "/%s%%2Fhue_bridge.c4z" % self.segment,
        ):
            with self.subTest(path=path):
                status, body = self.get(path)
                self.assertEqual(404, status)
                self.assertEqual(b"not found\n", body)
        self.assertEqual(501, self.get("/%s/hue_bridge.c4z" % self.segment, method="POST")[0])

    def test_stops_once_every_package_was_downloaded(self):
        self.start()
        self.get("/%s/hue_bridge.c4z" % self.segment)
        self.get("/%s/hue_bridge.c4z" % self.segment, method="HEAD")
        self.get("/nothing")
        self.assertTrue(self.thread.is_alive(), "one package is still to come")
        self.get("/%s/hue_light.c4z" % self.segment)
        self.thread.join(5)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual({"hue_bridge.c4z": 1, "hue_light.c4z": 1}, self.server.downloads)
        self.assertIn("every package has been downloaded once: stopping", self.out.text())

    def test_request_lines_are_cleaned(self):
        self.start(until_fetched=False)
        # A raw request line with an escape sequence, which http.client refuses to send.
        with socket.create_connection(("127.0.0.1", self.server.server_address[1]), timeout=5) as sock:
            sock.sendall(b"GET /a\x1b[2Jb\x85 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            reply = b""
            while chunk := sock.recv(4096):
                reply += chunk
        self.assertTrue(reply.startswith(b"HTTP/1.1 404"), reply[:40])
        self.assertIn("GET /a [2Jb", self.out.text())
        self.assertNotIn("\x1b", self.out.text())

    def test_brief_names_urls_hashes_and_the_dev_driver_version(self):
        self.start()
        base = self.base + "/%s/" % self.segment
        text = serve_install.brief_text(base, self.entries, "dev-627")
        for name, digest in self.sums.items():
            self.assertIn(
                "| %s | 627 (dev build: Driver Version reads 627-dev) | `%s` | %s%s |" % (name, digest, base, name),
                text,
            )
            self.assertIn("    '%s' = '%s'" % (name, digest), text)
        self.assertIn("$dir = 'C:\\c4-hue\\drivers\\dev-627'", text)
        self.assertEqual(2, text.count("Invoke-WebRequest"))
        self.assertEqual("dev-627", serve_install.default_label(self.entries))


class MainTest(Case):
    def run_main(self, argv):
        out = SyncOut()
        result = {}
        thread = threading.Thread(target=lambda: result.setdefault("code", serve_install.main(argv, out=out)))
        thread.start()
        return thread, out, result

    def wait_for(self, out, pattern, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            match = re.search(pattern, out.text())
            if match:
                return match
            time.sleep(0.02)
        self.fail("no %r in %r" % (pattern, out.text()))

    def test_serves_then_deletes_the_folder(self):
        thread, out, result = self.run_main(["--bind", "127.0.0.1", "--port", "0", "--timeout", "30"] + self.named())
        match = self.wait_for(out, r"Uri '(http://127\.0\.0\.1:\d+/[0-9a-f]{32}/)hue_bridge\.c4z'")
        root = self.wait_for(out, r"serving 2 package\(s\) from (\S+) ").group(1)
        self.assertTrue(os.path.isdir(root))
        self.assertIn("WARNING dev packages carry the dev key", out.text())
        for name in ("hue_bridge.c4z", "hue_light.c4z"):
            with urllib.request.urlopen(match.group(1) + name, timeout=10) as resp:
                self.assertEqual(self.sums[name], hashlib.sha256(resp.read()).hexdigest())
        thread.join(10)
        self.assertFalse(thread.is_alive())
        self.assertEqual(0, result["code"])
        self.assertFalse(os.path.exists(root), "the temporary folder is deleted when the server stops")
        self.assertIn("stopped; downloads: hue_bridge.c4z 1, hue_light.c4z 1", out.text())
        self.assertTrue(os.path.isfile(self.named()[0]), "the sources stay where they are")

    def test_the_timeout_stops_it(self):
        thread, out, result = self.run_main(["--bind", "127.0.0.1", "--port", "0", "--timeout", "0.3"] + self.named())
        thread.join(10)
        self.assertFalse(thread.is_alive())
        self.assertIn("stopped; downloads: hue_bridge.c4z 0, hue_light.c4z 0", out.text())

    def test_refusals_serve_nothing(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(1, serve_install.main(["--bind", "127.0.0.1", os.path.join(self.dir, "manifest.json")]))
            self.assertEqual(1, serve_install.main(["--bind", "127.0.0.1", "--label", "a b"] + self.named()))
            with mock.patch.object(serve_install.devserver, "lan_address", return_value=None):
                self.assertEqual(1, serve_install.main(self.named()))
        self.assertIn("only <driver>.c4z packages", err.getvalue())
        self.assertIn("--label", err.getvalue())
        self.assertIn("pass --bind", err.getvalue())

    def test_the_default_bind_is_the_lan_address(self):
        self.assertIsNone(serve_install.build_parser().parse_args(["x.c4z"]).bind, "no 0.0.0.0 default")
        self.assertEqual(8090, serve_install.build_parser().parse_args(["x.c4z"]).port)


if __name__ == "__main__":
    unittest.main()
