"""Unit tests for the one edit the Release workflow makes to existing notes (issue #239).

The publish job of .github/workflows/release.yml rewrites the build number that ends the first
heading of an existing release's notes, "(build N)", and nothing else. These tests take that
step's Python out of the workflow file and run it on sample notes, so the script tested is the
script that runs.

Run: python3 -m unittest discover -s tools/tests -v
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release.yml")
STEP = "- name: Name this build in the first heading of the notes"

# The notes of v1.0 as of build 329, shortened: the coordinator's heading and text above the
# generated part.
NOTES = (
    '## 1.0 "Cassian" (build 329)\n'
    "\n"
    "Codename: **Cassian**. Releases of this project are named after Star Wars: Andor.\n"
    "\n"
    "### New in build 329 (2026-10-25)\n"
    "\n"
    "This build of 1.0 replaces build 259 (and build 316, published earlier the same day).\n"
    "\n"
    "## What's Changed\n"
    "* Composer manuals: the review's fixes (build 329) by @corytron in #240\n"
)


def workflow_step():
    """The text of the step, from its name line to the next step."""
    with open(WORKFLOW, encoding="utf-8") as f:
        text = f.read()
    start = text.index(STEP)
    end = text.find("\n      - name:", start + 1)
    return text[start : end if end >= 0 else len(text)]


def heading_script():
    """The step's Python, as `python3 - <<'PY'` hands it to the interpreter."""
    lines = workflow_step().splitlines()
    begin = next(i for i, line in enumerate(lines) if line.rstrip().endswith("<<'PY'"))
    end = next(i for i in range(begin + 1, len(lines)) if lines[i].strip() == "PY")
    return textwrap.dedent("\n".join(lines[begin + 1 : end])) + "\n"


class FirstHeadingTest(unittest.TestCase):
    script = None

    @classmethod
    def setUpClass(cls):
        cls.script = heading_script()

    def run_step(self, body, build):
        """Run the step's Python on a release whose notes are `body`: the new notes, or None
        when the step writes none (and so makes no PATCH), and what it printed."""
        with tempfile.TemporaryDirectory() as tmp:
            source = os.path.join(tmp, "release.json")
            target = os.path.join(tmp, "notes.json")
            with open(source, "w", encoding="utf-8") as f:
                json.dump({"id": 123, "tag_name": "v1.0", "body": body}, f)
            done = subprocess.run(
                [sys.executable, "-I", "-", str(build), source, target],
                input=self.script,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, done.returncode, done.stderr)
            if not os.path.exists(target):
                return None, done.stdout
            with open(target, encoding="utf-8") as f:
                payload = json.load(f)
        self.assertEqual(["body"], list(payload), "the PATCH carries the notes and nothing else")
        return payload["body"], done.stdout

    def test_rewrites_only_the_build_that_ends_the_first_heading(self):
        notes, said = self.run_step(NOTES, 341)
        self.assertEqual(NOTES.replace('"Cassian" (build 329)', '"Cassian" (build 341)', 1), notes)
        self.assertIn("### New in build 329 (2026-10-25)", notes, "the rest is the coordinator's")
        self.assertIn("(build 329) by @corytron", notes)
        self.assertIn("build 329 -> 341", said)

    def test_keeps_line_endings_and_trailing_blanks(self):
        body = "## 1.0 (build 7)  \r\n\r\nText (build 7)\r\n"
        notes, _ = self.run_step(body, 8)
        self.assertEqual("## 1.0 (build 8)  \r\n\r\nText (build 7)\r\n", notes)

    def test_finds_the_first_heading_below_a_paragraph(self):
        notes, _ = self.run_step("Intro (build 4).\n\n## 1.0 (build 5)\n\n## Later (build 5)\n", 6)
        self.assertEqual("Intro (build 4).\n\n## 1.0 (build 6)\n\n## Later (build 5)\n", notes)

    def test_leaves_notes_alone_when_the_first_heading_has_another_shape(self):
        for body in (
            # What the workflow writes when it creates a release.
            "Build 329: the integer the three drivers show as **Driver Version** in Composer.\n\n"
            "## What's Changed\n* x by @y in #1\n",
            "## Notes\n\n## 1.0 (build 5)\n",  # only the first heading counts
            "## 1.0 (build 5) Cassian\n",  # not at the end
            "## 1.0 (Build 5)\n",
            "## 1.0 (build five)\n",
            "    ## 1.0 (build 5)\n",  # indented four: code, not a heading
            "#1.0 (build 5)\n",  # no blank after the hashes
            "No heading at all (build 5)\n",
            "",
        ):
            with self.subTest(body=body):
                notes, said = self.run_step(body, 6)
                self.assertIsNone(notes)
                self.assertIn("stay as they are", said)

    def test_leaves_notes_without_a_body_alone(self):
        notes, _ = self.run_step(None, 6)
        self.assertIsNone(notes)

    def test_writes_nothing_when_the_heading_names_this_build(self):
        notes, said = self.run_step(NOTES, 329)
        self.assertIsNone(notes)
        self.assertIn("names build 329 already", said)

    def test_the_step_runs_for_an_existing_release_only_and_patches_through_gh(self):
        step = workflow_step()
        self.assertIn("if: steps.release.outputs.existed == 'true'", step)
        self.assertIn("GH_TOKEN: ${{ github.token }}", step)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/releases/tags/$TAG"', step)
        self.assertIn('--input "$RUNNER_TEMP/notes.json"', step)
        self.assertIsNone(re.search(r"\buses:", step), "no action, and no third-party code")


if __name__ == "__main__":
    unittest.main()
