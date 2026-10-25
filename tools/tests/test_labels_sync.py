"""Unit tests for tools/labels_sync.py: no network, gh replaced by a fake.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import labels_sync  # noqa: E402

REPO = "octo/hue"

FILE_LABELS = [
    {"name": "bug", "color": "d73a4a", "description": "The driver does something wrong"},
    {"name": "deploy", "color": "1d76db", "description": "The house installation"},
    {"name": "good first issue", "color": "7057ff", "description": "Small and self-contained"},
    {"name": "ci", "color": "0E8A16", "description": "Workflows"},
]

REPO_LABELS = [
    {"name": "bug", "color": "d73a4a", "description": "Something does not work"},  # description differs
    {"name": "Good First Issue", "color": "7057FF", "description": "Small and self-contained"},  # same (case)
    {"name": "ci", "color": "0e8a16", "description": "Workflows"},  # same
    {"name": "wontfix", "color": "ffffff", "description": "Not in the file"},  # extra
]


class FakeGh:
    def __init__(self, labels):
        self.labels = [dict(label) for label in labels]
        self.calls = []

    def __call__(self, args, input=None):
        args = list(args)
        self.calls.append((args, input))
        if args[0] == "repo":
            return json.dumps({"nameWithOwner": REPO})
        assert args[0] == "api", args
        method = args[args.index("-X") + 1] if "-X" in args else "GET"
        path = [a for a in args[1:] if a not in ("-X", method, "--input", "-")][0]
        body = json.loads(input) if input else None
        assert method != "DELETE", "labels are never deleted: %r" % (args,)
        base, _, query = path.partition("?")
        assert base.startswith("repos/%s/labels" % REPO), path
        if method == "GET":
            assert "page=1" in query, query
            return json.dumps(self.labels)
        if method == "POST":
            assert base == "repos/%s/labels" % REPO
            self.labels.append(dict(body))
            return json.dumps(body)
        if method == "PATCH":
            name = base.rsplit("/", 1)[1]
            assert "%20" in name or " " not in name, "the name must be URL-encoded: %r" % name
            name = name.replace("%20", " ")
            for label in self.labels:
                if label["name"] == name:
                    label.update(body)
                    return json.dumps(label)
            raise AssertionError("PATCH of a label the repository lacks: %r" % name)
        raise AssertionError("unexpected method %s" % method)

    def writes(self):
        return [(a, i) for a, i in self.calls if "-X" in a]


class LabelsSyncTest(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGh(REPO_LABELS)
        self._saved = labels_sync.run_gh
        labels_sync.run_gh = self.gh
        self.addCleanup(self.restore)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = os.path.join(self.tmp.name, "labels.json")
        self.write_file(FILE_LABELS)

    def restore(self):
        labels_sync.run_gh = self._saved

    def write_file(self, labels):
        with open(self.file, "w", encoding="utf-8") as handle:
            json.dump(labels, handle)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = labels_sync.main(["--file", self.file, "--repo", REPO] + list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_plan(self):
        wanted = labels_sync.load_labels(self.file)
        create, update, extra = labels_sync.plan(wanted, REPO_LABELS)
        self.assertEqual([label["name"] for label in create], ["deploy"])
        self.assertEqual([(cur["name"], new["name"]) for cur, new in update], [("bug", "bug")])
        self.assertEqual([label["name"] for label in extra], ["wontfix"])

    def test_sync_creates_updates_never_deletes(self):
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        writes = self.gh.writes()
        self.assertEqual(len(writes), 2, writes)
        post = [w for w in writes if "POST" in w[0]][0]
        self.assertEqual(
            json.loads(post[1]), {"name": "deploy", "color": "1d76db", "description": "The house installation"}
        )
        patch = [w for w in writes if "PATCH" in w[0]][0]
        self.assertIn("repos/octo/hue/labels/bug", patch[0])
        self.assertEqual(json.loads(patch[1]), {"color": "d73a4a", "description": "The driver does something wrong"})
        self.assertIn("created deploy", out)
        self.assertIn("updated bug", out)
        self.assertIn("not in the file (left alone): wontfix", out)
        self.assertNotIn("Good First Issue", out.replace("not in the file", ""))
        self.assertEqual(
            [label["name"] for label in self.gh.labels], ["bug", "Good First Issue", "ci", "wontfix", "deploy"]
        )
        # A second run finds everything in place.
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertIn("4 labels in sync", out)
        self.assertEqual(len(self.gh.writes()), 2)

    def test_patch_path_is_url_encoded(self):
        self.gh = FakeGh([{"name": "good first issue", "color": "000000", "description": ""}])
        labels_sync.run_gh = self.gh
        self.write_file([FILE_LABELS[2]])
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        patch = self.gh.writes()[0][0]
        self.assertTrue(any(a.endswith("labels/good%20first%20issue") for a in patch), patch)

    def test_check_reports_and_exits_3(self):
        code, out, err = self.run_main("--check")
        self.assertEqual(code, 3)
        self.assertEqual(self.gh.writes(), [])
        self.assertIn("would create deploy", out)
        self.assertIn("would update bug", out)
        self.assertIn("not in the file (left alone): wontfix", out)
        self.assertIn("out of sync: 1 to create, 1 to update", out)

    def test_check_in_sync_exits_0(self):
        self.write_file([FILE_LABELS[2], FILE_LABELS[3]])
        code, out, err = self.run_main("--check")
        self.assertEqual(code, 0, err)
        self.assertIn("2 labels in sync", out)
        self.assertEqual(self.gh.writes(), [])

    def test_file_validation(self):
        self.write_file([{"name": "x", "color": "red", "description": ""}])
        code, out, err = self.run_main("--check")
        self.assertEqual(code, 1)
        self.assertIn("six hex digits", err)
        self.write_file([{"name": "x", "color": "ffffff"}, {"name": "X", "color": "000000"}])
        code, out, err = self.run_main("--check")
        self.assertEqual(code, 1)
        self.assertIn("twice", err)
        self.write_file([{"name": "x", "color": "ffffff", "description": "d" * 101}])
        self.assertEqual(self.run_main("--check")[0], 1)
        self.assertEqual(self.gh.calls, [])

    def test_committed_labels_file_loads(self):
        labels = labels_sync.load_labels(labels_sync.LABELS_FILE)
        names = {label["name"] for label in labels}
        self.assertTrue({"ci", "deploy", "dependencies"} <= names, names)


if __name__ == "__main__":
    unittest.main()
