"""Unit tests for tools/deploy.py: no network, gh replaced by FakeGh.

Run: python3 -m unittest discover -s tools/tests -v
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import deploy  # noqa: E402

REPO = "octo/hue"
COMMIT = "a" * 40
OTHER_COMMIT = "c" * 40
AT = "2026-10-24T21:04:00-04:00"
APPROVAL = "The owner's standing approval covers this install: act without asking again."
PACKAGE_BYTES = {
    "hue_bridge.c4z": b"bridge package bytes",
    "hue_light.c4z": b"light package bytes",
    "hue_scene.c4z": b"scene package bytes",
}
PACKAGES = sorted(PACKAGE_BYTES)
# A prerelease that adds a fourth driver (#268): the package list is the manifest's, never three names.
BETA_TAG = "v1.1-beta.1"
BETA_BUILD = 412
BETA_COMMIT = "b" * 40
BETA_PACKAGE_BYTES = {
    "hue_bridge.c4z": b"beta bridge package bytes",
    "hue_light.c4z": b"beta light package bytes",
    "hue_motion.c4z": b"beta motion package bytes",
    "hue_scene.c4z": b"beta scene package bytes",
}
BETA_DRIVERS = "hue_bridge hue_light hue_motion hue_scene"
# Release and prerelease tags (docs/prerelease-design.md, section 1).
GOOD_TAGS = ("v1.0", "v1.1", "v0.9", "v12.34", "v1.1-beta.1", "v1.1-beta.9", "v1.1-beta.10", "v2.0-beta.123")
BAD_TAGS = (
    "1.0",
    "v1",
    "v1.0.1",
    "v1.0-rc1",
    "v1.1-rc.1",
    "v1.1-alpha.1",
    "v1.1-beta",
    "v1.1-beta.",
    "v1.1-beta.0",
    "v1.1-beta.01",
    "v1.1-Beta.1",
    "v1.1-beta.1.1",
    "v1.1beta1",
    "v1.1-beta-1",
    "V1.0",
    "vv1.0",
    "v1.0+build.5",
    "v\u0661.\u0660",
)
HEX16 = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{16}(?![0-9a-fA-F])")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tag_object(tag):
    return sha(("tag:" + tag).encode())[:40]


def manifest_for(build=252, tag="v1.0", commit=COMMIT, dev=False, packages=None):
    packages = packages or PACKAGE_BYTES
    return {
        "schema": 1,
        "tag": tag,
        "version": tag[1:] if tag else None,
        "build": build,
        "commit": commit,
        "built_at": "2026-10-25T03:12:45Z",
        "dev": dev,
        "packages": {name: {"sha256": sha(data), "bytes": len(data)} for name, data in packages.items()},
    }


def sums_for(packages=None):
    packages = packages or PACKAGE_BYTES
    return "".join("%s  %s\n" % (sha(data), name) for name, data in packages.items())


def release_assets(manifest=None, with_manifest=True, packages=None):
    packages = packages or PACKAGE_BYTES
    assets = dict(packages)
    assets["SHA256SUMS.txt"] = sums_for(packages).encode()
    if with_manifest:
        assets["manifest.json"] = json.dumps(manifest or manifest_for(packages=packages)).encode()
    return assets


def house_text(**overrides):
    values = {
        "environment": "house",
        "release": "v1.0",
        "build": "252",
        "drivers": "hue_bridge hue_light hue_scene",
        "stream_timeout_s": "3600",
        "stream_watchdog_s": "600",
        "debug_mode": "Off",
    }
    for key, value in overrides.items():
        if value is None:
            values.pop(key, None)
        else:
            values[key] = value
    return "# desired state\n" + "".join("%s: %s\n" % item for item in values.items())


def attestation_for(digest, name="hue_bridge.c4z", predicate="https://slsa.dev/provenance/v1"):
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": name, "digest": {"sha256": digest}}],
        "predicateType": predicate,
        "predicate": {},
    }
    payload = base64.b64encode(json.dumps(statement).encode()).decode()
    envelope = {"payload": payload, "payloadType": "application/vnd.in-toto+json", "signatures": [{"sig": "x"}]}
    return {"attestations": [{"bundle": {"dsseEnvelope": envelope}, "repository_id": 1}]}


def verified_result(repo=REPO, workflow=".github/workflows/release.yml", ref="refs/heads/main"):
    """One entry of what `gh attestation verify --format json` prints (the fields deploy.py reads)."""
    san = "https://github.com/%s/%s@%s" % (repo, workflow, ref)
    return {
        "attestation": {"bundle": {"mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json"}},
        "verificationResult": {
            "mediaType": "application/vnd.dev.sigstore.verificationresult+json;version=0.1",
            "signature": {"certificate": {"subjectAlternativeName": san, "sourceRepositoryRef": ref}},
        },
    }


class FakeGh:
    """Stands in for deploy.run_gh: canned GitHub state, every call recorded.

    Rules it enforces as assertions: only open deploy issues are listed; a closed issue is never
    edited, commented on or closed again; `gh issue reopen` and `gh issue delete` do not exist.
    """

    def __init__(self):
        self.calls = []
        self.repo = REPO
        self.deployments = {}
        self.statuses = {}
        self.assets = {}
        self.tags = {}
        self.annotated = True
        self.attestations = {}
        self.issues = {}
        self.next_id = 500
        self.next_issue = 10
        self.clock = 0
        self.fail_once = None  # (method, path fragment): the next matching api call fails
        self.version = "2.103.2"  # what `gh --version` names
        self.verify_failures = {}  # digest -> gh's stderr when `gh attestation verify` refuses that package
        self.verify_output = {}  # digest -> what `gh attestation verify` prints instead of one good result

    # -- plumbing ---------------------------------------------------------

    def __call__(self, args, input=None):
        args = list(args)
        self.calls.append((args, input))
        if args[0] == "repo":
            return json.dumps({"nameWithOwner": self.repo})
        if args[0] == "--version":
            return "gh version %s (2026-10-23)\nhttps://github.com/cli/cli/releases/tag/v%s\n" % ((self.version,) * 2)
        if args[0] == "attestation":
            return self.attestation_verify(args)
        if args[0] == "api":
            return self.api(args, input)
        if args[0] == "release":
            return self.release_download(args)
        if args[0] == "issue":
            return self.issue(args, input)
        raise AssertionError("unexpected gh call %r" % (args,))

    def calls_matching(self, *prefix):
        return [(a, i) for a, i in self.calls if a[: len(prefix)] == list(prefix)]

    def api_calls(self, method, fragment):
        found = []
        for args, input in self.calls:
            if args[0] != "api":
                continue
            m = args[args.index("-X") + 1] if "-X" in args else "GET"
            path = [a for a in args[1:] if not a.startswith("-") and a not in ("-",)]
            path = [p for p in path if p != m][-1]
            if m == method and fragment in path:
                found.append((path, json.loads(input) if input else None))
        return found

    def _not_found(self, args):
        raise deploy.GhError(args, 1, '{"message":"Not Found","status":"404"}', "gh: Not Found (HTTP 404)")

    def _stamp(self):
        self.clock += 1
        return "2026-10-25T%02d:%02d:00Z" % divmod(self.clock, 60)

    def add_deployment(self, tag, build, states, recorded=False):
        """A deployment with the given status states in order (the last is the latest)."""
        self.next_id += 1
        dep = {
            "id": self.next_id,
            "url": "https://api.github.com/repos/%s/deployments/%d" % (self.repo, self.next_id),
            "ref": tag,
            "environment": "house",
            "description": "Build %d (%s) to the house" % (build, tag),
            "payload": {"tag": tag, "build": build, "commit": COMMIT, "packages": {}, "note": "", "recorded": recorded},
            "created_at": self._stamp(),
        }
        self.deployments[dep["id"]] = dep
        self.statuses[dep["id"]] = []
        for state in states:
            self.statuses[dep["id"]].append(
                {
                    "id": len(self.statuses[dep["id"]]) + 1,
                    "state": state,
                    "description": state,
                    "created_at": self._stamp(),
                }
            )
        return dep

    def add_issue(self, title, state="open"):
        self.next_issue += 1
        issue = {
            "number": self.next_issue,
            "title": title,
            "body": "",
            "state": state,
            "comments": [],
            "url": "https://github.com/%s/issues/%d" % (self.repo, self.next_issue),
        }
        self.issues[issue["number"]] = issue
        return issue

    # -- gh api -------------------------------------------------------------

    def api(self, args, input):
        method, path = "GET", None
        rest = args[1:]
        i = 0
        while i < len(rest):
            if rest[i] == "-X":
                method = rest[i + 1]
                i += 2
            elif rest[i] == "--input":
                i += 2
            else:
                path = rest[i]
                i += 1
        body = json.loads(input) if input is not None else None
        if self.fail_once and self.fail_once[0] == method and self.fail_once[1] in path:
            self.fail_once = None
            raise deploy.GhError(args, 1, "", "gh: Validation Failed (HTTP 422)")
        base, _, query = path.partition("?")
        parts = base.split("/")
        assert parts[0] == "repos" and "/".join(parts[1:3]) == self.repo, path
        tail = parts[3:]
        if tail == ["deployments"] and method == "GET":
            assert "environment=house" in query, query
            return json.dumps(sorted(self.deployments.values(), key=lambda d: d["id"], reverse=True))
        if tail == ["deployments"] and method == "POST":
            self.next_id += 1
            dep = {
                "id": self.next_id,
                "url": "https://api.github.com/repos/%s/deployments/%d" % (self.repo, self.next_id),
                "ref": body["ref"],
                "environment": body["environment"],
                "description": body["description"],
                "payload": body.get("payload"),
                "created_at": self._stamp(),
            }
            self.deployments[dep["id"]] = dep
            self.statuses[dep["id"]] = []
            return json.dumps(dep)
        if len(tail) == 2 and tail[0] == "deployments" and method == "GET":
            dep = self.deployments.get(int(tail[1]))
            if dep is None:
                self._not_found(args)
            return json.dumps(dep)
        if len(tail) == 3 and tail[0] == "deployments" and tail[2] == "statuses":
            dep_id = int(tail[1])
            if dep_id not in self.deployments:
                self._not_found(args)
            if method == "GET":
                return json.dumps(sorted(self.statuses[dep_id], key=lambda s: s["id"], reverse=True))
            assert method == "POST"
            assert len(body["description"]) <= 140, body["description"]
            status = {
                "id": len(self.statuses[dep_id]) + 1,
                "state": body["state"],
                "description": body["description"],
                "created_at": self._stamp(),
            }
            self.statuses[dep_id].append(status)
            return json.dumps(status)
        if tail[:3] == ["git", "ref", "tags"]:
            tag = tail[3]
            if tag not in self.tags:
                self._not_found(args)
            if self.annotated:
                return json.dumps({"ref": "refs/tags/" + tag, "object": {"type": "tag", "sha": tag_object(tag)}})
            return json.dumps({"ref": "refs/tags/" + tag, "object": {"type": "commit", "sha": self.tags[tag]}})
        if tail[:2] == ["git", "tags"]:
            for tag, commit in self.tags.items():
                if tag_object(tag) == tail[2]:
                    return json.dumps({"tag": tag, "sha": tail[2], "object": {"type": "commit", "sha": commit}})
            self._not_found(args)
        if tail[0] == "attestations":
            digest = tail[1].split(":", 1)[1]
            if digest not in self.attestations:
                self._not_found(args)
            return json.dumps(self.attestations[digest])
        self._not_found(args)

    # -- gh attestation verify ----------------------------------------------

    def attestation_verify(self, args):
        """gh attestation verify FILE --repo R --signer-workflow R/.github/workflows/release.yml --format json:
        the file's digest decides the answer, as on GitHub."""
        assert args[1] == "verify", args
        assert args[args.index("--repo") + 1] == self.repo, args
        assert args[args.index("--signer-workflow") + 1] == self.repo + "/.github/workflows/release.yml", args
        assert args[args.index("--format") + 1] == "json", args
        with open(args[2], "rb") as handle:
            digest = sha(handle.read())
        if digest in self.verify_failures:
            raise deploy.GhError(args, 1, "", self.verify_failures[digest])
        if digest not in self.attestations:
            raise deploy.GhError(args, 1, "", "✗ No attestations found for subject sha256:%s" % digest)
        if digest in self.verify_output:
            return self.verify_output[digest]
        return json.dumps([verified_result(self.repo)]) + "\n"

    # -- gh release download ----------------------------------------------

    def release_download(self, args):
        tag = args[2]
        directory = args[args.index("--dir") + 1]
        patterns = [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]
        assert "--clobber" in args and args[args.index("--repo") + 1] == self.repo
        if tag not in self.assets:
            raise deploy.GhError(args, 1, "", "release not found")
        matched = [p for p in patterns if p in self.assets[tag]]
        if not matched:
            raise deploy.GhError(args, 1, "", "no assets match the file pattern")
        for name in matched:
            with open(os.path.join(directory, name), "wb") as handle:
                handle.write(self.assets[tag][name])
        return ""

    # -- gh issue -----------------------------------------------------------

    def issue(self, args, input):
        verb = args[1]
        if verb == "list":
            assert args[args.index("--state") + 1] == "open", "only open issues may be listed: %r" % (args,)
            assert args[args.index("--label") + 1] == "deploy"
            listed = [
                {"number": n, "title": i["title"], "url": i["url"]}
                for n, i in sorted(self.issues.items())
                if i["state"] == "open"
            ]
            return json.dumps(listed)
        if verb == "create":
            assert args[args.index("--label") + 1] == "deploy"
            issue = self.add_issue(args[args.index("--title") + 1])
            issue["body"] = input
            return issue["url"] + "\n"
        number = int(args[2])
        issue = self.issues[number]
        assert issue["state"] == "open", "a closed issue was touched: %r" % (args,)
        if verb == "edit":
            issue["title"] = args[args.index("--title") + 1]
            issue["body"] = input
            return ""
        if verb == "comment":
            issue["comments"].append(input)
            return ""
        if verb == "close":
            issue["state"] = "closed"
            issue["comments"].append(args[args.index("--comment") + 1])
            return ""
        raise AssertionError("gh issue %s is never used" % verb)


class DeployCase(unittest.TestCase):
    """A fake repository with release v1.0 (build 252, attested) and a valid house file for build 252."""

    def setUp(self):
        self.gh = FakeGh()
        self.gh.tags["v1.0"] = COMMIT
        self.gh.assets["v1.0"] = release_assets()
        for name, data in PACKAGE_BYTES.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.house = os.path.join(self.tmp.name, "house.yaml")
        self.write_house()
        self._saved = (deploy.run_gh, deploy.RELEASE_DIR)
        deploy.run_gh = self.gh
        deploy.RELEASE_DIR = os.path.join(self.tmp.name, "release")
        self.addCleanup(self.restore)

    def restore(self):
        deploy.run_gh, deploy.RELEASE_DIR = self._saved

    def write_house(self, **overrides):
        with open(self.house, "w", encoding="utf-8") as handle:
            handle.write(house_text(**overrides))

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = deploy.main(list(argv) + ["--file", self.house])
        return code, out.getvalue(), err.getvalue()

    def release_file(self, name):
        return os.path.join(deploy.RELEASE_DIR, "v1.0", name)


# ---------------------------------------------------------------------------
# deploy/house.yaml
# ---------------------------------------------------------------------------


class ParseHouseTest(unittest.TestCase):
    def test_contract_sample(self):
        text = (
            "# Desired state of the house installation.\n"
            "environment: house\n"
            "release: v1.0        # the GitHub release whose assets are installed\n"
            "build: 247           # the build number its packages carry\n"
            "drivers: hue_bridge hue_light hue_scene\n"
            "\n"
            "stream_timeout_s: 3600\n"
            "stream_watchdog_s: 600\n"
            'debug_mode: "Off"\n'
        )
        self.assertEqual(
            deploy.parse_house(text),
            {
                "environment": "house",
                "release": "v1.0",
                "build": "247",
                "drivers": "hue_bridge hue_light hue_scene",
                "stream_timeout_s": "3600",
                "stream_watchdog_s": "600",
                "debug_mode": "Off",
            },
        )
        self.assertEqual(deploy.validate_house(deploy.parse_house(text)), [])

    def test_quotes_and_url_values(self):
        values = deploy.parse_house("a: 'x y'\nb: http://example.test/path#frag\nc: v # note\n")
        self.assertEqual(values, {"a": "x y", "b": "http://example.test/path#frag", "c": "v"})

    def test_line_without_colon(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.parse_house("environment: house\nbuild 247\n")
        self.assertIn("line 2", str(ctx.exception))

    def test_repeated_key(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.parse_house("build: 1\nbuild: 2\n")
        self.assertIn("repeats", str(ctx.exception))

    def test_committed_house_file_is_valid(self):
        house = deploy.load_house(deploy.HOUSE_FILE)
        self.assertEqual(house["environment"], "house")
        # A stable tag or a prerelease (docs/prerelease-design.md §4).
        self.assertRegex(house["release"], deploy.TAG_RE)


class ValidateHouseTest(unittest.TestCase):
    def problems(self, **overrides):
        return deploy.validate_house(deploy.parse_house(house_text(**overrides)))

    def test_valid(self):
        self.assertEqual(self.problems(), [])

    def test_every_failure_names_its_key(self):
        cases = {
            "environment": ["prod", "House"],
            "release": ["1.0", "v1", "v1.0.1", "v1.0-rc1", "v1.1-beta.0", "v1.1-beta", "v1.1-rc.1"],
            "build": ["0", "-3", "abc", "247.0", ""],
            # Which drivers is the release's question (validate --online, start); offline only
            # their form: driver names, each once.
            "drivers": [
                "",
                "hue_bridge hue_light hue_light",
                "hue_bridge.c4z hue_light.c4z hue_scene.c4z",
                "hue_bridge ../hue_light",
                "-hue_bridge hue_light",
            ],
            "stream_timeout_s": ["29", "86401", "-60", "soon", ""],
            "stream_watchdog_s": ["59", "3601", "30", "x", ""],
            "debug_mode": ["On", "off", ""],
        }
        for key, values in cases.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    found = self.problems(**{key: value})
                    self.assertTrue(found, "%s=%r should fail" % (key, value))
                    self.assertTrue(any(key in p for p in found), found)

    def test_watchdog_must_be_below_timeout(self):
        self.assertTrue(any("below" in p for p in self.problems(stream_timeout_s="600", stream_watchdog_s="600")))
        self.assertTrue(any("below" in p for p in self.problems(stream_timeout_s="600", stream_watchdog_s="700")))
        self.assertEqual(self.problems(stream_timeout_s="600", stream_watchdog_s="599"), [])

    # Issue #237: exactly the ranges src/hue_bridge/driver.xml declares, Stream Timeout (s) 30 to
    # 86400 and Stream Watchdog (s) 60 to 3600; validate accepted 60 to 86400 and 30 to 3600 before.
    def test_accepts_the_bounds_driver_xml_declares(self):
        for timeout, watchdog in (("86400", "3600"), ("61", "60"), ("3601", "3600"), ("30000", "120")):
            with self.subTest(timeout=timeout, watchdog=watchdog):
                self.assertEqual(self.problems(stream_timeout_s=timeout, stream_watchdog_s=watchdog), [])
        # 30 to 60 s are timeouts Composer takes; the rule that the watchdog stays below the timeout
        # then refuses every watchdog, since driver.xml's smallest is 60.
        for timeout in ("30", "59", "60"):
            with self.subTest(timeout=timeout):
                found = self.problems(stream_timeout_s=timeout, stream_watchdog_s="60")
                self.assertEqual(["stream_watchdog_s (60) must be below stream_timeout_s (%s)" % timeout], found)

    def test_refuses_what_composer_cannot_set(self):
        cases = (
            {"stream_timeout_s": "29"},
            {"stream_timeout_s": "86401"},
            {"stream_timeout_s": "86400", "stream_watchdog_s": "30"},
            {"stream_timeout_s": "86400", "stream_watchdog_s": "59"},
            {"stream_timeout_s": "86400", "stream_watchdog_s": "3601"},
        )
        for overrides in cases:
            key = "stream_watchdog_s" if "stream_watchdog_s" in overrides else "stream_timeout_s"
            with self.subTest(**overrides):
                found = self.problems(**overrides)
                self.assertEqual(1, len(found), found)
                self.assertTrue(found[0].startswith(key + " must be an integer from"), found)
                self.assertIn("in src/hue_bridge/driver.xml", found[0])

    def test_an_out_of_range_timeout_is_not_compared_with_the_watchdog(self):
        found = self.problems(stream_timeout_s="20", stream_watchdog_s="600")
        self.assertEqual(
            [
                "stream_timeout_s must be an integer from 30 to 86400 "
                "(Stream Timeout (s) in src/hue_bridge/driver.xml), not '20'"
            ],
            found,
        )

    def test_ranges_are_driver_xml_ranges(self):
        """deploy.py's ranges are the minimum and maximum the bridge's driver.xml declares."""
        tree = ET.parse(os.path.join(deploy.ROOT, "src", "hue_bridge", "driver.xml"))
        declared = {}
        for prop in tree.iter("property"):
            name = (prop.findtext("name") or "").strip()
            if name in ("Stream Timeout (s)", "Stream Watchdog (s)"):
                self.assertEqual("RANGED_INTEGER", (prop.findtext("type") or "").strip(), name)
                declared[name] = (int(prop.findtext("minimum")), int(prop.findtext("maximum")))
        self.assertEqual(
            {"Stream Timeout (s)": deploy.STREAM_TIMEOUT_RANGE, "Stream Watchdog (s)": deploy.STREAM_WATCHDOG_RANGE},
            declared,
        )

    def test_missing_and_unknown_keys(self):
        self.assertIn("missing key build", self.problems(build=None))
        self.assertIn("unknown key colour", self.problems(colour="blue"))

    def test_load_house_reports_every_problem(self):
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
            handle.write(house_text(build="x", debug_mode="On"))
        self.addCleanup(os.unlink, handle.name)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.load_house(handle.name)
        self.assertIn("build", str(ctx.exception))
        self.assertIn("debug_mode", str(ctx.exception))


# ---------------------------------------------------------------------------
# Package and manifest verification
# ---------------------------------------------------------------------------


class VerificationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = self.tmp.name

    def write_release(self, packages=None, sums=None, manifest=None):
        packages = packages or PACKAGE_BYTES
        for name, data in packages.items():
            with open(os.path.join(self.dir, name), "wb") as handle:
                handle.write(data)
        with open(os.path.join(self.dir, "SHA256SUMS.txt"), "w") as handle:
            handle.write(sums if sums is not None else sums_for(packages))
        manifest = manifest or manifest_for(packages=packages)
        with open(os.path.join(self.dir, "manifest.json"), "w") as handle:
            json.dump(manifest, handle)
        return manifest

    def test_all_good(self):
        manifest = self.write_release()
        hashes = deploy.verify_packages(self.dir, deploy.read_manifest(os.path.join(self.dir, "manifest.json")))
        self.assertEqual(hashes, {name: sha(data) for name, data in PACKAGE_BYTES.items()})
        deploy.check_manifest(manifest, "v1.0", 252, COMMIT)

    def test_tampered_package(self):
        manifest = self.write_release()
        with open(os.path.join(self.dir, "hue_light.c4z"), "wb") as handle:
            handle.write(b"something else")
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        text = str(ctx.exception)
        self.assertIn("hue_light.c4z", text)
        self.assertIn("SHA256SUMS.txt", text)
        self.assertIn("manifest.json", text)
        self.assertNotIn("hue_bridge.c4z", text)

    def test_sums_file_lacks_a_package(self):
        manifest = self.write_release(sums="%s  hue_bridge.c4z\n" % sha(PACKAGE_BYTES["hue_bridge.c4z"]))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("does not list hue_light.c4z", str(ctx.exception))

    def test_manifest_bytes_differ(self):
        manifest = manifest_for()
        manifest["packages"]["hue_scene.c4z"]["bytes"] += 1
        self.write_release(manifest=manifest)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("bytes", str(ctx.exception))

    def test_parse_sums_accepts_binary_marker(self):
        with open(os.path.join(self.dir, "SHA256SUMS.txt"), "w") as handle:
            handle.write("%s *hue_bridge.c4z\n%s  hue_light.c4z\n" % ("A" * 64, "b" * 64))
        self.assertEqual(
            deploy.parse_sums(os.path.join(self.dir, "SHA256SUMS.txt")),
            {"hue_bridge.c4z": "a" * 64, "hue_light.c4z": "b" * 64},
        )

    def test_check_manifest_failures(self):
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(build=252), "v1.0", 247, COMMIT)
        self.assertIn("carries build 252", str(ctx.exception))
        self.assertIn("deploy/house.yaml says build 247", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(), "v1.0", 252, OTHER_COMMIT)
        self.assertIn("commit", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(dev=True), "v1.0", 252, COMMIT)
        self.assertIn("dev", str(ctx.exception))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_manifest(manifest_for(tag="v1.1"), "v1.0", 252, COMMIT)
        self.assertIn("tag", str(ctx.exception))
        deploy.check_manifest(manifest_for(tag=None), "v1.0", 252, COMMIT)  # a local build names no tag

    def test_read_manifest_shape(self):
        for broken in (
            {"schema": 2},
            {"schema": 1, "build": "252", "commit": COMMIT, "packages": {}},
            {"schema": 1, "build": 252, "commit": "short", "packages": {}},
            {"schema": 1, "build": 252, "commit": COMMIT, "packages": {"hue_bridge.c4z": {"sha256": "zz"}}},
        ):
            with self.subTest(broken=broken):
                path = os.path.join(self.dir, "manifest.json")
                with open(path, "w") as handle:
                    json.dump(broken, handle)
                with self.assertRaises(deploy.DeployError):
                    deploy.read_manifest(path)

    def test_read_manifest_refuses_names_that_are_not_packages(self):
        good = {"sha256": "a" * 64, "bytes": 1}
        path = os.path.join(self.dir, "manifest.json")
        for packages in (
            {},
            {"../hue_bridge.c4z": good},
            {"sub/hue_bridge.c4z": good},
            {"hue_bridge.zip": good},
            {".c4z": good},
            {"-hue_bridge.c4z": good},
            {"hue bridge.c4z": good},
        ):
            with self.subTest(packages=packages):
                with open(path, "w") as handle:
                    json.dump({"schema": 1, "build": 252, "commit": COMMIT, "packages": packages}, handle)
                with self.assertRaises(deploy.DeployError) as ctx:
                    deploy.read_manifest(path)
                self.assertIn("manifest.json: ", str(ctx.exception))

    def test_the_package_list_is_the_manifests(self):
        """Four packages as well as three (docs/prerelease-design.md, section 2): nothing counts them."""
        for packages in (PACKAGE_BYTES, BETA_PACKAGE_BYTES):
            with self.subTest(count=len(packages)):
                self.write_release(packages=packages)
                manifest = deploy.read_manifest(os.path.join(self.dir, "manifest.json"))
                self.assertEqual(deploy.manifest_packages(manifest), sorted(packages))
                hashes = deploy.verify_packages(self.dir, manifest)
                self.assertEqual(hashes, {name: sha(data) for name, data in packages.items()})

    def test_sums_file_lists_a_package_the_manifest_does_not(self):
        manifest = self.write_release(sums=sums_for() + "%s  hue_extra.c4z\n" % ("e" * 64))
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.verify_packages(self.dir, manifest)
        self.assertIn("SHA256SUMS.txt lists hue_extra.c4z, which manifest.json does not", str(ctx.exception))

    def test_check_drivers(self):
        house = deploy.parse_house(house_text(drivers="hue_scene hue_bridge hue_light"))
        deploy.check_drivers(house, manifest_for(), "v1.0")  # the order of the names does not matter
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.check_drivers(house, manifest_for(packages=BETA_PACKAGE_BYTES), BETA_TAG)
        self.assertEqual(
            str(ctx.exception),
            "deploy/house.yaml names the drivers hue_bridge hue_light hue_scene, but the release v1.1-beta.1 carries "
            "hue_bridge.c4z, hue_light.c4z, hue_motion.c4z, hue_scene.c4z (manifest.json): drivers: must name exactly "
            "the release's packages",
        )


# ---------------------------------------------------------------------------
# Attestations and tags (through the fake gh)
# ---------------------------------------------------------------------------


class GitHubReadsTest(DeployCase):
    def test_attestation_subject_matches(self):
        digest = sha(PACKAGE_BYTES["hue_bridge.c4z"])
        found = deploy.attestation_check(REPO, "hue_bridge.c4z", digest)
        self.assertEqual(found, {"count": 1, "predicate_types": ["https://slsa.dev/provenance/v1"]})

    def test_attestation_subject_mismatch(self):
        digest = sha(PACKAGE_BYTES["hue_bridge.c4z"])
        self.gh.attestations[digest] = attestation_for("f" * 64)
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.attestation_check(REPO, "hue_bridge.c4z", digest)
        self.assertIn("none names its digest", str(ctx.exception))

    def test_attestation_absent(self):
        self.assertIsNone(deploy.attestation_check(REPO, "x.c4z", "0" * 64))  # 404
        self.gh.attestations["1" * 64] = {"attestations": []}
        self.assertIsNone(deploy.attestation_check(REPO, "x.c4z", "1" * 64))

    def test_attestation_without_payload(self):
        self.gh.attestations["2" * 64] = {"attestations": [{"bundle": {"dsseEnvelope": {}}}]}
        with self.assertRaises(deploy.DeployError):
            deploy.attestation_check(REPO, "x.c4z", "2" * 64)

    def test_gh_version(self):
        self.assertEqual(deploy.gh_version(), (2, 103, 2))
        self.gh.version = "2.46.0"
        self.assertEqual(deploy.gh_version(), (2, 46, 0))
        deploy.run_gh = lambda args, input=None: "gh version DEV\n"
        with self.assertRaises(deploy.DeployError) as ctx:
            deploy.gh_version()
        self.assertIn("cannot read gh's version", str(ctx.exception))

    def test_tag_commit_annotated_and_lightweight(self):
        self.assertEqual(deploy.tag_commit(REPO, "v1.0"), COMMIT)
        self.assertTrue(self.gh.api_calls("GET", "git/tags/" + tag_object("v1.0")))
        self.gh.annotated = False
        self.assertEqual(deploy.tag_commit(REPO, "v1.0"), COMMIT)
        with self.assertRaises(deploy.DeployError):
            deploy.tag_commit(REPO, "v9.9")

    def test_fetch_manifest(self):
        self.assertEqual(deploy.fetch_manifest(REPO, "v1.0")["build"], 252)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        self.assertIsNone(deploy.fetch_manifest(REPO, "v1.0"))
        with self.assertRaises(deploy.GhError):
            deploy.fetch_manifest(REPO, "v9.9")

    def test_clip(self):
        self.assertEqual(deploy.clip("a  b\nc"), "a b c")
        self.assertEqual(len(deploy.clip("x" * 500)), 140)
        self.assertTrue(deploy.clip("x" * 500).endswith("…"))

    def test_private_findings(self):
        self.assertEqual(deploy.private_findings("bridge 10.0.2.143, VM 192.0.2.7, id 001788fffe123abc"), [])
        # The vectors are assembled at run time so the repository's own private-data
        # scan (gitleaks, .gitleaks.toml) does not see them as literals.
        found = deploy.private_findings("bridge at 10.0." + "1.9\nid 001788" + "fffeabcdef\nhue_app_key")
        self.assertEqual(len(found), 3)
        self.assertEqual(deploy.private_findings("sha256 " + "a" * 64 + " commit " + "b" * 40), [])


# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------


class StartTest(DeployCase):
    def test_start_creates_deployment_brief_and_record(self):
        code, out, err = self.run_main("start", "--note", "changes <capabilities>: reboot the controller afterwards")
        self.assertEqual(code, 0, err)
        posts = self.gh.api_calls("POST", "deployments")
        self.assertEqual(len(posts), 2, posts)  # the deployment, then its in_progress status
        path, body = posts[0]
        self.assertEqual(path, "repos/octo/hue/deployments")
        self.assertEqual(body["ref"], "v1.0")
        self.assertEqual(body["environment"], "house")
        self.assertIs(body["auto_merge"], False)
        self.assertEqual(body["required_contexts"], [])
        self.assertIs(body["production_environment"], True)
        self.assertEqual(body["description"], "Build 252 (v1.0) to the house")
        self.assertEqual(body["payload"]["tag"], "v1.0")
        self.assertEqual(body["payload"]["build"], 252)
        self.assertEqual(body["payload"]["commit"], COMMIT)
        self.assertEqual(body["payload"]["packages"], {n: sha(d) for n, d in PACKAGE_BYTES.items()})
        self.assertIn("reboot", body["payload"]["note"])
        self.assertEqual(
            posts[1][1], {"state": "in_progress", "description": "Packages verified; install through Composer pending"}
        )

        with open(self.release_file("deployment.json")) as handle:
            record = json.load(handle)
        self.assertEqual((record["id"], record["tag"], record["build"], record["commit"]), (501, "v1.0", 252, COMMIT))
        self.assertTrue(record["url"].endswith("/deployments/501"))
        self.assertTrue(record["created"])
        for name in PACKAGES:
            self.assertTrue(os.path.isfile(self.release_file(name)))

        lines = out.strip().splitlines()
        self.assertEqual(lines[-2], self.release_file("BRIEF.md"))
        self.assertEqual(lines[-1], record["url"])

        with open(self.release_file("BRIEF.md"), encoding="utf-8") as handle:
            brief = handle.read()
        for name, data in PACKAGE_BYTES.items():
            self.assertIn("https://github.com/octo/hue/releases/download/v1.0/%s" % name, brief)
            self.assertIn(sha(data), brief)
        self.assertEqual(brief.count("Invoke-WebRequest"), 3)
        self.assertIn("Get-FileHash", brief)
        self.assertIn("C:\\c4-hue\\drivers\\v1.0\\", brief)
        self.assertIn("`Driver Version` = 252", brief)
        self.assertIn("`Stream Timeout (s)` = 3600, `Stream Watchdog (s)` = 600 and `Debug Mode` = Off", brief)
        self.assertIn(APPROVAL, brief)
        self.assertIn("Add or Update Driver or Agent", brief)
        self.assertIn("Never delete and re-add", brief)
        self.assertIn('Note from the coordinator: "changes <capabilities>: reboot the controller afterwards"', brief)
        self.assertIn("--signer-workflow octo/hue/.github/workflows/release.yml", brief)
        self.assertIn("no LAN address and no bridge id", brief)
        self.assertNotIn("10.0.1.", brief)
        self.assertNotIn("hue_app_key", brief)
        self.assertEqual({m.group(0).lower() for m in HEX16.finditer(brief)} - {"001788fffe123abc"}, set())

    def test_start_refuses_while_in_progress(self):
        self.gh.add_deployment("v1.0", 250, ["in_progress"])
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("still in_progress", err)
        self.assertIn("--supersede", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.assertEqual(self.gh.calls_matching("release"), [])

    def test_start_refuses_while_a_deployment_has_no_status(self):
        self.gh.add_deployment("v1.0", 250, [])
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("pending", err)

    def test_start_supersedes(self):
        old = self.gh.add_deployment("v1.0", 250, ["in_progress"])
        code, out, err = self.run_main("start", "--supersede")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[old["id"]][-1]
        self.assertEqual(latest["state"], "inactive")
        self.assertIn("Superseded", latest["description"])
        self.assertIn("superseded deployment %d" % old["id"], out)
        new_id = max(self.gh.deployments)
        self.assertNotEqual(new_id, old["id"])
        self.assertEqual(self.gh.statuses[new_id][-1]["state"], "in_progress")

    def test_start_fails_without_attestation_unless_flagged(self):
        del self.gh.attestations[sha(PACKAGE_BYTES["hue_scene.c4z"])]
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("no provenance attestation for hue_scene.c4z", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        code, out, err = self.run_main("start", "--no-attestation")
        self.assertEqual(code, 0, err)
        self.assertIn("no provenance attestation", err)
        with open(self.release_file("BRIEF.md"), encoding="utf-8") as handle:
            brief = handle.read()
        self.assertIn("hue_scene.c4z: NO provenance attestation", brief)
        self.assertIn("hue_bridge.c4z: provenance verified, signed by", brief)
        # The two attested packages were still verified; the third has nothing to verify.
        verified = [args[2] for args, _ in self.gh.calls_matching("attestation", "verify")]
        self.assertEqual(verified, [self.release_file("hue_bridge.c4z"), self.release_file("hue_light.c4z")])

    def read_brief(self):
        with open(self.release_file("BRIEF.md"), encoding="utf-8") as handle:
            return handle.read()

    def test_start_verifies_each_package_against_the_release_workflow(self):
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        calls = self.gh.calls_matching("attestation", "verify")
        self.assertEqual([args[2] for args, _ in calls], [self.release_file(name) for name in PACKAGES])
        policy = ["--repo", "octo/hue", "--signer-workflow", "octo/hue/.github/workflows/release.yml"]
        for args, _ in calls:
            self.assertEqual(args[3:], policy + ["--format", "json"])
        signer = "https://github.com/octo/hue/.github/workflows/release.yml@refs/heads/main"
        self.assertIn("attestation hue_light.c4z: verified (gh 2.103.2), signed by " + signer, out)
        brief = self.read_brief()
        for name in PACKAGES:
            self.assertIn("- %s: provenance verified, signed by %s" % (name, signer), brief)
        self.assertIn(
            "Verified on the VM with gh 2.103.2: `gh attestation verify <file> --repo octo/hue --signer-workflow "
            "octo/hue/.github/workflows/release.yml` for each package",
            brief,
        )

    def test_start_refuses_an_attestation_another_workflow_signed(self):
        digest = sha(PACKAGE_BYTES["hue_light.c4z"])
        self.gh.verify_failures[digest] = (
            "Loaded digest sha256:%s for file://hue_light.c4z\n✗ Verification failed\n"
            'Error: verifying with issuer "sigstore.dev": certificate SAN '
            "https://github.com/octo/hue/.github/workflows/scorecard.yml@refs/heads/main does not match" % digest
        )
        for extra in ((), ("--no-attestation",)):
            with self.subTest(extra=extra):
                code, out, err = self.run_main("start", *extra)
                self.assertEqual(code, 1)
                self.assertIn("hue_light.c4z: gh attestation verify refused it", err)
                self.assertIn("the signer must be octo/hue/.github/workflows/release.yml", err)
                self.assertIn("scorecard.yml", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.assertFalse(os.path.isfile(self.release_file("BRIEF.md")))

    def test_start_refuses_a_gh_that_cannot_pin_the_signer(self):
        for version in ("2.46.0", "2.101.0"):
            with self.subTest(version=version):
                self.gh.version = version
                code, out, err = self.run_main("start", "--no-attestation")
                self.assertEqual(code, 1)
                self.assertIn("gh %s cannot check who signed the attestations" % version, err)
                self.assertIn("needs gh 2.102.0 or newer", err)
        self.assertEqual(self.gh.calls_matching("attestation"), [])
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        self.gh.version = "2.102.0"
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)

    def test_start_without_any_attestation_verifies_nothing(self):
        self.gh.attestations.clear()
        self.gh.version = "2.46.0"  # too old to verify, and there is nothing to verify
        code, out, err = self.run_main("start", "--no-attestation")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.calls_matching("--version"), [])
        self.assertEqual(self.gh.calls_matching("attestation"), [])
        brief = self.read_brief()
        self.assertEqual(brief.count("NO provenance attestation"), 3)
        self.assertIn("No package carries an attestation, so nothing was verified (--no-attestation).", brief)

    def test_start_refuses_when_gh_verifies_nothing(self):
        digest = sha(PACKAGE_BYTES["hue_bridge.c4z"])
        for printed, reason in (
            ("[]\n", "reported no verified attestation"),
            ('{"verified": true}', "reported no verified attestation"),
            ("✓ Verification succeeded!", "not JSON"),
        ):
            with self.subTest(printed=printed):
                self.gh.verify_output[digest] = printed
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("hue_bridge.c4z: gh attestation verify", err)
                self.assertIn(reason, err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_checks_the_signer_gh_reports(self):
        """A gh that matched loosely (as 2.51 to 2.101 did) still cannot pass a lookalike signer."""
        digest = sha(PACKAGE_BYTES["hue_scene.c4z"])
        for result in (
            verified_result(workflow=".github/workflows/release.yml.bak.yml"),
            verified_result(workflow=".github/workflows/Release.yml"),
            verified_result(workflow=".github/workflows/scorecard.yml"),
            verified_result(repo="octo/hue-fork"),
            {"verificationResult": {"signature": {}}},
            "not an object",
        ):
            with self.subTest(result=result):
                self.gh.verify_output[digest] = json.dumps([verified_result(), result])
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("hue_scene.c4z: a verified attestation names the signer", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])
        # A release cut from a pushed tag, and the owner's name in another case, are the same signer.
        self.gh.verify_output[digest] = json.dumps(
            [verified_result(ref="refs/tags/v1.0"), verified_result(repo="Octo/Hue")]
        )
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        self.assertIn(
            "hue_scene.c4z: provenance verified, signed by "
            "https://github.com/Octo/Hue/.github/workflows/release.yml@refs/heads/main, "
            "https://github.com/octo/hue/.github/workflows/release.yml@refs/tags/v1.0",
            self.read_brief(),
        )

    def test_start_fails_on_attestation_subject_mismatch(self):
        digest = sha(PACKAGE_BYTES["hue_light.c4z"])
        self.gh.attestations[digest] = attestation_for("f" * 64, name="hue_light.c4z")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("none names its digest", err)

    def test_start_needs_the_manifest(self):
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("lacks manifest.json", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_build_that_differs_from_house(self):
        self.write_house(build="247")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("carries build 252", err)
        self.assertIn("deploy/house.yaml says build 247", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_commit_that_is_not_the_tags(self):
        self.gh.tags["v1.0"] = OTHER_COMMIT
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("commit", err)

    def test_start_refuses_a_tampered_package(self):
        self.gh.assets["v1.0"]["hue_bridge.c4z"] = b"not the package"
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertIn("hue_bridge.c4z", err)
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_start_refuses_a_private_note_before_doing_anything(self):
        code, out, err = self.run_main("start", "--note", "the bridge at 10.0." + "1.20 answered")
        self.assertEqual(code, 1)
        self.assertIn("private data", err)
        self.assertEqual(self.gh.calls, [])

    def test_start_writes_the_record_before_the_status_can_fail(self):
        self.gh.fail_once = ("POST", "statuses")
        code, out, err = self.run_main("start")
        self.assertEqual(code, 1)
        self.assertTrue(os.path.isfile(self.release_file("deployment.json")))
        self.assertFalse(os.path.isfile(self.release_file("BRIEF.md")))
        self.assertEqual(len(self.gh.deployments), 1)

    def test_start_with_bad_tag(self):
        code, out, err = self.run_main("start", "--tag", "1.0")
        self.assertEqual(code, 1)
        self.assertIn("--tag", err)


# ---------------------------------------------------------------------------
# done, failed
# ---------------------------------------------------------------------------


class DoneTest(DeployCase):
    def start(self):
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        return max(self.gh.deployments)

    def test_done_records_success_and_closes_the_issue(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 252) to the house")
        dep_id = self.start()
        code, out, err = self.run_main("done", "--devices", "5", "--note", "no Restart Director prompt")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[dep_id][-1]
        self.assertEqual(latest["state"], "success")
        self.assertEqual(
            latest["description"],
            "Driver Version 252 on 5 devices, settings as deploy/house.yaml; no Restart Director prompt",
        )
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")
        self.assertEqual(
            self.gh.issues[issue["number"]]["comments"][-1],
            "Build 252 (v1.0) recorded as deployed: https://api.github.com/repos/octo/hue/deployments/%d" % dep_id,
        )
        self.assertIn("in sync: build 252 (v1.0)", out)
        with open(self.release_file("deployment.json")) as handle:
            self.assertEqual(json.load(handle)["result"], "success")

    def test_done_without_devices(self):
        dep_id = self.start()
        code, out, err = self.run_main("done")
        self.assertEqual(code, 0, err)
        self.assertEqual(
            self.gh.statuses[dep_id][-1]["description"],
            "Driver Version 252 on every device, settings as deploy/house.yaml",
        )

    def test_done_refuses_when_the_assets_changed(self):
        dep_id = self.start()
        self.gh.assets["v1.0"]["manifest.json"] = json.dumps(manifest_for(build=253)).encode()
        code, out, err = self.run_main("done", "--devices", "5")
        self.assertEqual(code, 1)
        self.assertIn("now carries build 253", err)
        self.assertEqual(self.gh.statuses[dep_id][-1]["state"], "in_progress")
        other = {n: b"replaced " + d for n, d in PACKAGE_BYTES.items()}
        self.gh.assets["v1.0"]["manifest.json"] = json.dumps(manifest_for(packages=other)).encode()
        code, out, err = self.run_main("done", "--devices", "5")
        self.assertEqual(code, 1)
        self.assertIn("replaced", err)

    def test_done_by_deployment_id(self):
        dep = self.gh.add_deployment("v1.0", 252, ["in_progress"])
        code, out, err = self.run_main("done", "--deployment", str(dep["id"]), "--devices", "4")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.statuses[dep["id"]][-1]["state"], "success")

    def test_done_without_a_record(self):
        code, out, err = self.run_main("done")
        self.assertEqual(code, 1)
        self.assertIn("deployment.json", err)
        self.assertIn("--deployment", err)

    def test_failed_records_failure_and_comments(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 252) to the house")
        dep_id = self.start()
        code, out, err = self.run_main("failed", "--note", "Composer refused the file; the house still runs build 247")
        self.assertEqual(code, 0, err)
        latest = self.gh.statuses[dep_id][-1]
        self.assertEqual(latest["state"], "failure")
        self.assertIn("still runs build 247", latest["description"])
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "open")
        self.assertIn("still runs build 247", self.gh.issues[issue["number"]]["comments"][-1])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 3)


# ---------------------------------------------------------------------------
# record
# ---------------------------------------------------------------------------


class RecordTest(DeployCase):
    def test_record_with_matching_manifest(self):
        issue = self.gh.add_issue("Deploy v1.0 (build 252) to the house")
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "252", "--at", AT, "--note", "installed by hand"
        )
        self.assertEqual(code, 0, err)
        dep = self.gh.deployments[max(self.gh.deployments)]
        self.assertIs(dep["payload"]["recorded"], True)
        self.assertEqual(dep["payload"]["installed_at"], AT)
        self.assertEqual(dep["payload"]["build"], 252)
        self.assertEqual(dep["payload"]["commit"], COMMIT)
        self.assertEqual(dep["payload"]["packages"], {n: sha(d) for n, d in PACKAGE_BYTES.items()})
        status = self.gh.statuses[dep["id"]][-1]
        self.assertEqual(status["state"], "success")
        self.assertIn("Driver Version 252 installed " + AT, status["description"])
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")

    def test_record_refuses_another_build_than_the_manifest(self):
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "247", "--at", AT, "--note", "built on the VM"
        )
        self.assertEqual(code, 1)
        self.assertIn("--no-manifest", err)
        self.assertEqual(self.gh.deployments, {})

    def test_record_with_no_manifest_flag(self):
        self.write_house(build="247")
        code, out, err = self.run_main(
            "record",
            "--tag",
            "v1.0",
            "--build",
            "247",
            "--at",
            AT,
            "--note",
            "built on the VM",
            "--no-manifest",
            "--commit",
            OTHER_COMMIT,
        )
        self.assertEqual(code, 0, err)
        dep = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(dep["payload"]["build"], 247)
        self.assertEqual(dep["payload"]["packages"], {})
        self.assertEqual(dep["payload"]["commit"], OTHER_COMMIT)
        self.assertIs(dep["payload"]["recorded"], True)
        self.assertIn("unverified", err)

    def test_record_without_a_manifest_in_the_release(self):
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("record", "--tag", "v1.0", "--build", "247", "--at", AT, "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("--no-manifest", err)
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "247", "--at", AT, "--note", "x", "--no-manifest"
        )
        self.assertEqual(code, 3)  # recorded, but the house file wants 252: drift
        self.assertIsNone(self.gh.deployments[max(self.gh.deployments)]["payload"]["commit"])

    def test_record_rejects_bad_time_and_unknown_tag(self):
        code, out, err = self.run_main("record", "--tag", "v1.0", "--build", "252", "--at", "yesterday", "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("--at", err)
        code, out, err = self.run_main(
            "record", "--tag", "v1.0", "--build", "252", "--at", "2026-10-24T21:04:00", "--note", "x"
        )
        self.assertEqual(code, 1)
        self.assertIn("offset", err)
        code, out, err = self.run_main("record", "--tag", "v9.9", "--build", "252", "--at", AT, "--note", "x")
        self.assertEqual(code, 1)
        self.assertIn("no tag v9.9", err)
        self.assertEqual(self.gh.deployments, {})


# ---------------------------------------------------------------------------
# status and drift
# ---------------------------------------------------------------------------


class StatusTest(DeployCase):
    def test_no_deployment_is_drift(self):
        code, out, err = self.run_main("status")
        self.assertEqual(code, 3)
        self.assertIn("observed  none", out)
        self.assertIn("drift:", out)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_agreement(self):
        self.gh.add_deployment("v1.0", 252, ["in_progress", "success"])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 0, err)
        self.assertIn("in sync: build 252 (v1.0)", out)

    def test_build_or_tag_differs(self):
        self.gh.add_deployment("v1.0", 247, ["success"])
        self.assertEqual(self.run_main("status")[0], 3)
        self.gh.add_deployment("v1.1", 252, ["success"])
        self.assertEqual(self.run_main("status")[0], 3)

    def test_latest_status_counts(self):
        self.gh.add_deployment("v1.0", 252, ["success"])
        self.gh.add_deployment("v1.0", 253, ["in_progress", "failure"])
        code, out, err = self.run_main("status")
        self.assertEqual(code, 0, err)
        self.assertIn("v1.0 build 252", out)
        self.gh.add_deployment("v1.0", 253, ["success", "inactive"])
        self.assertEqual(self.run_main("status")[0], 0)

    def test_payload_as_string(self):
        dep = self.gh.add_deployment("v1.0", 252, ["success"])
        dep["payload"] = json.dumps(dep["payload"])
        self.assertEqual(self.run_main("status")[0], 0)

    def test_drift_without_issue_only_prints(self):
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_drift_online_check(self):
        self.write_house(build="247")
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 1)
        self.assertIn("carries build 252", err)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("drift")
        self.assertEqual(code, 3)
        self.assertIn("warning: release v1.0 carries no manifest.json", err)

    def test_validate_online(self):
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 0, err)
        self.assertIn("manifest.json build 252 matches", out)
        self.write_house(build="247")
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 1)
        self.gh.assets["v1.0"] = release_assets(with_manifest=False)
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 1)
        self.assertIn("no manifest.json", err)
        self.assertEqual(self.run_main("validate")[0], 0)


class DriftIssueTest(DeployCase):
    TITLE = "Deploy v1.0 (build 252) to the house"

    def open_issues(self):
        return [i for i in self.gh.issues.values() if i["state"] == "open"]

    def test_drift_without_issue_opens_one(self):
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(len(self.open_issues()), 1)
        issue = self.open_issues()[0]
        self.assertEqual(issue["title"], self.TITLE)
        self.assertIn("**252**", issue["body"])
        self.assertIn("no deployment of environment `house`", issue["body"])
        self.assertIn("python3 tools/deploy.py start", issue["body"])
        self.assertIn("System Manager", issue["body"])
        self.assertIn("https://github.com/octo/hue/releases/tag/v1.0", issue["body"])
        self.assertIn("opened deploy issue " + issue["url"], out)

    def test_second_run_creates_no_second_issue(self):
        self.run_main("drift", "--issue")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(len(self.open_issues()), 1)
        self.assertIn("is current", out)
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)
        self.assertEqual(self.gh.calls_matching("issue", "edit"), [])
        self.assertEqual(self.gh.calls_matching("issue", "comment"), [])

    def test_desired_state_change_retitles_the_open_issue(self):
        old = self.gh.add_issue("Deploy v1.0 (build 250) to the house")
        self.gh.add_deployment("v1.0", 247, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[old["number"]]["title"], self.TITLE)
        self.assertIn("build **247**", self.gh.issues[old["number"]]["body"])
        self.assertEqual(len(self.gh.issues[old["number"]]["comments"]), 1)
        self.assertIn("desired state changed", self.gh.issues[old["number"]]["comments"][0])
        self.assertEqual(self.gh.calls_matching("issue", "create"), [])
        self.assertEqual(len(self.open_issues()), 1)

    def test_no_drift_closes_every_open_issue_and_leaves_closed_ones(self):
        self.gh.add_issue(self.TITLE, state="closed")
        a = self.gh.add_issue("Deploy v1.0 (build 250) to the house")
        b = self.gh.add_issue(self.TITLE)
        dep = self.gh.add_deployment("v1.0", 252, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        for number in (a["number"], b["number"]):
            self.assertEqual(self.gh.issues[number]["state"], "closed")
            self.assertEqual(
                self.gh.issues[number]["comments"], ["Build 252 (v1.0) recorded as deployed: %s" % dep["url"]]
            )
        self.assertEqual(len(self.gh.calls_matching("issue", "close")), 2)
        self.assertEqual(self.gh.calls_matching("issue", "create"), [])

    def test_no_drift_and_nothing_open_touches_nothing(self):
        self.gh.add_issue(self.TITLE, state="closed")
        self.gh.add_deployment("v1.0", 252, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.calls_matching("issue"), self.gh.calls_matching("issue", "list"))

    def test_two_open_issues_edit_the_oldest_only(self):
        first = self.gh.add_issue("Deploy v1.0 (build 240) to the house")
        second = self.gh.add_issue("Deploy v1.0 (build 241) to the house")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[first["number"]]["title"], self.TITLE)
        self.assertEqual(self.gh.issues[second["number"]]["title"], "Deploy v1.0 (build 241) to the house")
        self.assertIn("second open deploy issue", err)

    def test_other_issues_with_the_label_are_never_touched(self):
        # 2026-10-25: `done` closed #237, a tooling bug that only shared the
        # deploy label.
        other = self.gh.add_issue("deploy.py accepts a watchdog below driver.xml's minimum")
        drift = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment("v1.0", 252, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[drift["number"]]["state"], "closed")
        self.assertEqual(self.gh.issues[other["number"]]["state"], "open")
        self.assertEqual(self.gh.issues[other["number"]]["comments"], [])

    def test_drift_with_only_another_labelled_issue_opens_its_own(self):
        other = self.gh.add_issue("Some other deploy-labelled issue")
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.issues[other["number"]]["title"], "Some other deploy-labelled issue")
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)


# ---------------------------------------------------------------------------
# Prereleases (docs/prerelease-design.md, sections 1, 2 and 4)
# ---------------------------------------------------------------------------


class TagPatternTest(DeployCase):
    """v1.0 and v1.1-beta.1, and nothing else, wherever a tag is taken."""

    def test_is_tag(self):
        for tag in GOOD_TAGS:
            self.assertTrue(deploy.is_tag(tag), tag)
        for tag in BAD_TAGS + ("", " v1.0", "v1.0 ", "v1.0\n", "v1.1-beta.1\n", None):
            self.assertFalse(deploy.is_tag(tag), repr(tag))

    def test_is_prerelease(self):
        self.assertEqual([tag for tag in GOOD_TAGS if deploy.is_prerelease(tag)], [t for t in GOOD_TAGS if "-" in t])

    def test_house_release(self):
        for tag in GOOD_TAGS:
            with self.subTest(tag=tag):
                self.assertEqual(deploy.validate_house(deploy.parse_house(house_text(release=tag))), [])
        for tag in BAD_TAGS:
            with self.subTest(tag=tag):
                self.assertEqual(
                    deploy.validate_house(deploy.parse_house(house_text(release=tag))),
                    ["release must look like v1.0 (a release) or v1.1-beta.1 (a prerelease), not %r" % tag],
                )

    def test_start_and_record_refuse_a_bad_tag_before_any_call(self):
        for tag in ("v1.1-beta.0", "v1.0-rc1", "1.1-beta.1", "v1.1-beta.1\n"):
            for argv in (
                ("start", "--tag", tag),
                ("record", "--tag", tag, "--build", "252", "--at", AT, "--note", "x"),
            ):
                with self.subTest(argv=argv):
                    code, out, err = self.run_main(*argv)
                    self.assertEqual(code, 1)
                    self.assertIn("--tag must look like v1.0 (a release) or v1.1-beta.1 (a prerelease)", err)
        self.assertEqual(self.gh.calls, [])


class DeployIssueTitleTest(unittest.TestCase):
    """The drift issue's title (#244): "Deploy <tag> (build N) to the house" for a release or a
    prerelease tag, and nothing else, so that no other issue with the deploy label is touched."""

    def test_both_forms(self):
        for tag, build in (("v1.0", 252), ("v1.1-beta.1", 412), ("v12.34-beta.10", 1)):
            title = deploy.issue_title(tag, build)
            self.assertEqual(title, "Deploy %s (build %d) to the house" % (tag, build))
            self.assertTrue(deploy.DEPLOY_ISSUE_TITLE.fullmatch(title), title)

    def test_nothing_else(self):
        for title in (
            "Deploy v1.0 (build 252) to the house!",
            "Deploy v1.0 (build 252) to the house\n",
            "deploy v1.0 (build 252) to the house",
            "Re: Deploy v1.0 (build 252) to the house",
            "Deploy v1.1-beta.1 (build 412) to the house, again",
            "Deploy v1.0 (build) to the house",
            "Deploy v1.0 (build 2a) to the house",
            "Deploy v1.0 (build \u0662\u0665\u0662) to the house",
            "Deploy v1.0 build 252 to the house",
        ):
            self.assertIsNone(deploy.DEPLOY_ISSUE_TITLE.fullmatch(title), repr(title))
        for tag in BAD_TAGS:
            self.assertIsNone(deploy.DEPLOY_ISSUE_TITLE.fullmatch("Deploy %s (build 1) to the house" % tag), tag)


class PrereleaseTest(DeployCase):
    """deploy/house.yaml names the prerelease v1.1-beta.1 (build 412), whose manifest lists four packages."""

    TITLE = "Deploy v1.1-beta.1 (build 412) to the house"

    def setUp(self):
        super().setUp()
        self.gh.tags[BETA_TAG] = BETA_COMMIT
        manifest = manifest_for(build=BETA_BUILD, tag=BETA_TAG, commit=BETA_COMMIT, packages=BETA_PACKAGE_BYTES)
        self.gh.assets[BETA_TAG] = release_assets(manifest, packages=BETA_PACKAGE_BYTES)
        for name, data in BETA_PACKAGE_BYTES.items():
            self.gh.attestations[sha(data)] = attestation_for(sha(data), name=name)
        self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers=BETA_DRIVERS)

    def beta_file(self, name):
        return os.path.join(deploy.RELEASE_DIR, BETA_TAG, name)

    def open_issues(self):
        return [issue for issue in self.gh.issues.values() if issue["state"] == "open"]

    def test_validate_offline_and_online(self):
        code, out, err = self.run_main("validate")
        self.assertEqual(code, 0, err)
        self.assertIn("valid (v1.1-beta.1 build 412;", out)
        code, out, err = self.run_main("validate", "--online")
        self.assertEqual(code, 0, err)
        self.assertIn("release v1.1-beta.1: manifest.json build 412 matches", out)
        self.assertIn("hue_bridge.c4z, hue_light.c4z, hue_motion.c4z, hue_scene.c4z", out)

    def test_start_install_and_done(self):
        issue = self.gh.add_issue(self.TITLE)
        code, out, err = self.run_main("start")
        self.assertEqual(code, 0, err)
        names = sorted(BETA_PACKAGE_BYTES)
        self.assertIn("downloaded 6 files", out)
        # The manifest first, then exactly the packages it names.
        downloads = [args for args, _ in self.gh.calls_matching("release", "download")]
        patterns = [[args[i + 1] for i, arg in enumerate(args) if arg == "--pattern"] for args in downloads]
        self.assertEqual(patterns, [["manifest.json", "SHA256SUMS.txt"], names])
        body = self.gh.api_calls("POST", "deployments")[0][1]
        self.assertEqual((body["ref"], body["description"]), (BETA_TAG, "Build 412 (v1.1-beta.1) to the house"))
        self.assertEqual(body["payload"]["packages"], {name: sha(data) for name, data in BETA_PACKAGE_BYTES.items()})
        verified = [args[2] for args, _ in self.gh.calls_matching("attestation", "verify")]
        self.assertEqual(verified, [self.beta_file(name) for name in names])

        with open(self.beta_file("BRIEF.md"), encoding="utf-8") as handle:
            brief = handle.read()
        self.assertTrue(brief.startswith("# Install build 412 (v1.1-beta.1, a prerelease) on the house\n"), brief[:80])
        self.assertIn("v1.1-beta.1 is a prerelease: a build for testing, marked Pre-release on GitHub", brief)
        self.assertEqual(brief.count("Invoke-WebRequest"), 4)
        for name, data in BETA_PACKAGE_BYTES.items():
            self.assertIn("https://github.com/octo/hue/releases/download/v1.1-beta.1/%s" % name, brief)
            self.assertIn("    '%s' = '%s'" % (name, sha(data)), brief)
            self.assertIn("- %s: provenance verified, signed by" % name, brief)
        self.assertIn(
            "Fetch the 4 packages of the release (hue_bridge.c4z, hue_light.c4z, hue_motion.c4z and hue_scene.c4z)",
            brief,
        )
        self.assertIn("pick all 4 files from `C:\\c4-hue\\drivers\\v1.1-beta.1\\` at once", brief)
        self.assertIn(
            "`Driver Version` = 412 (every device of the drivers hue_bridge, hue_light, hue_motion and hue_scene)",
            brief,
        )
        self.assertEqual({m.group(0).lower() for m in HEX16.finditer(brief)} - {"001788fffe123abc"}, set())

        code, out, err = self.run_main("done", "--devices", "9")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[issue["number"]]["state"], "closed")
        self.assertIn("in sync: build 412 (v1.1-beta.1)", out)
        self.assertEqual(self.run_main("status")[0], 0)

    def test_start_refuses_drivers_that_are_not_the_releases(self):
        for drivers in (
            "hue_bridge hue_light hue_scene",
            "hue_bridge hue_light hue_motion hue_scene hue_extra",
            "hue_bridge hue_light hue_sensor hue_scene",
        ):
            with self.subTest(drivers=drivers):
                self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers=drivers)
                before = len(self.gh.calls)
                code, out, err = self.run_main("start")
                self.assertEqual(code, 1)
                self.assertIn("deploy/house.yaml names the drivers %s, but" % " ".join(sorted(drivers.split())), err)
                self.assertIn("v1.1-beta.1 carries hue_bridge.c4z, hue_light.c4z, hue_motion.c4z, hue_scene.c4z", err)
                downloads = [args for args, _ in self.gh.calls[before:] if args[:2] == ["release", "download"]]
                self.assertEqual(len(downloads), 1, "only manifest.json and SHA256SUMS.txt are downloaded")
        self.assertEqual(self.gh.api_calls("POST", "deployments"), [])

    def test_online_checks_refuse_drivers_that_are_not_the_releases(self):
        self.write_house(release=BETA_TAG, build=str(BETA_BUILD), drivers="hue_bridge hue_light hue_scene")
        self.assertEqual(self.run_main("validate")[0], 0)  # offline only the form is checked
        for argv in (("validate", "--online"), ("drift",), ("drift", "--issue")):
            with self.subTest(argv=argv):
                code, out, err = self.run_main(*argv)
                self.assertEqual(code, 1)
                self.assertIn("names the drivers hue_bridge hue_light hue_scene, but the release v1.1-beta.1", err)
        self.assertEqual(self.gh.calls_matching("issue"), [])

    def test_drift_issue_names_the_prerelease(self):
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        [issue] = self.open_issues()
        self.assertEqual(issue["title"], self.TITLE)
        self.assertIn("v1.1-beta.1 is a prerelease, a build for testing", issue["body"])
        self.assertIn("https://github.com/octo/hue/releases/tag/v1.1-beta.1", issue["body"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        self.assertIn("is current", out)
        self.assertEqual(len(self.gh.calls_matching("issue", "create")), 1)

    def test_going_back_to_the_release_retitles_the_issue(self):
        issue = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment(BETA_TAG, BETA_BUILD, ["success"])
        self.write_house()  # back to v1.0, build 252, three drivers: an ordinary desired-state change
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 3)
        updated = self.gh.issues[issue["number"]]
        self.assertEqual(updated["title"], "Deploy v1.0 (build 252) to the house")
        self.assertNotIn("is a prerelease", updated["body"])
        self.assertEqual(
            updated["comments"],
            ['desired state changed: now v1.0 (build 252); this issue was "%s".' % self.TITLE],
        )

    def test_only_the_two_title_forms_are_drift_issues(self):
        lookalikes = [
            self.gh.add_issue(title)
            for title in (
                "Deploy v1.1-beta.0 (build 412) to the house",
                "Deploy v1.1-rc.1 (build 412) to the house",
                "Deploy v1.1-beta.1 (build 412) to the house, again",
            )
        ]
        drift_issue = self.gh.add_issue(self.TITLE)
        self.gh.add_deployment(BETA_TAG, BETA_BUILD, ["success"])
        code, out, err = self.run_main("drift", "--issue")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.issues[drift_issue["number"]]["state"], "closed")
        for issue in lookalikes:
            self.assertEqual(self.gh.issues[issue["number"]]["state"], "open")
            self.assertEqual(self.gh.issues[issue["number"]]["comments"], [])

    def test_record_a_prerelease(self):
        code, out, err = self.run_main(
            "record", "--tag", BETA_TAG, "--build", str(BETA_BUILD), "--at", AT, "--note", "installed by hand"
        )
        self.assertEqual(code, 0, err)
        deployment = self.gh.deployments[max(self.gh.deployments)]
        self.assertEqual(deployment["ref"], BETA_TAG)
        self.assertEqual(deployment["payload"]["commit"], BETA_COMMIT)
        self.assertEqual(
            deployment["payload"]["packages"], {name: sha(data) for name, data in BETA_PACKAGE_BYTES.items()}
        )
        self.assertIn("in sync: build 412 (v1.1-beta.1)", out)

    def test_done_refuses_when_the_release_gained_a_package(self):
        self.assertEqual(self.run_main("start")[0], 0)
        more = dict(BETA_PACKAGE_BYTES, **{"hue_extra.c4z": b"extra package bytes"})
        manifest = manifest_for(build=BETA_BUILD, tag=BETA_TAG, commit=BETA_COMMIT, packages=more)
        self.gh.assets[BETA_TAG]["manifest.json"] = json.dumps(manifest).encode()
        code, out, err = self.run_main("done")
        self.assertEqual(code, 1)
        self.assertIn("the release v1.1-beta.1 replaced hue_extra.c4z after start", err)


if __name__ == "__main__":
    unittest.main()
