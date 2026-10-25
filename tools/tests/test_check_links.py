"""Unit tests for tools/check_links.py (issue #263), on small fixture trees in temporary directories;
only RealRepositoryReport reads this repository, read-only, and it never fails on what it finds.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import changelog  # noqa: E402
import check_links  # noqa: E402

SCRIPT = os.path.join(TOOLS, "check_links.py")
GITHUB = "https://github.com/corytron/c4-hue-driver"


def text_of(*rows):
    """A file made of rows, one per line: row k is line k + 1."""
    return "\n".join(rows) + "\n"


class TreeCase(unittest.TestCase):
    """A fixture repository in a temporary directory; write() adds a file that git tracks unless told
    otherwise, and the fake git of run_main() lists exactly those."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        self.tracked = []

    def write(self, path, text="", tracked=True):
        full = os.path.join(self.root, *path.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        if tracked and path not in self.tracked:
            self.tracked.append(path)

    def report(self):
        return check_links.check(self.root, sorted(self.tracked))

    def assertBroken(self, expected):
        """expected: (file, line, a piece of the message) of every problem, in the order printed."""
        problems = self.report().problems
        self.assertEqual([problem[:2] for problem in problems], [item[:2] for item in expected], problems)
        for (_path, _line, message), (_file, _number, piece) in zip(problems, expected, strict=True):
            self.assertIn(piece, message)

    def assertClean(self):
        self.assertEqual(self.report().problems, [])

    def fake_git(self, root, *args):
        if args == ("rev-parse", "--show-toplevel"):
            return root + "\n"
        self.assertEqual(args, ("ls-files", "-z"))
        return "".join(path + "\0" for path in self.tracked)

    def run_main(self, *argv, git=None, root=None):
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(check_links, "run_git", git or self.fake_git),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = check_links.main(["--root", root or self.root, *argv])
        return code, out.getvalue(), err.getvalue()


# ---------------------------------------------------------------------------
# Rule 3: relative targets
# ---------------------------------------------------------------------------


class RelativeLinkTest(TreeCase):
    def test_every_kind_of_link_that_resolves(self):
        self.write("docs/a.md", "# A\n")
        self.write("docs/my file.md", "# Spaces\n")
        self.write("img/p.png")
        self.write(
            "README.md",
            text_of(
                "# Project",
                "",
                '[inline](docs/a.md), ![image](img/p.png), [title](docs/a.md "A title"), [folder](docs/),',
                "[from the root](/docs/a.md), [query](docs/a.md?plain=1), [itself](README.md), [here](./),",
                "[encoded](docs/my%20file.md), [angle](<docs/my file.md>), [escaped](docs\\/a.md)",
                '<a href="docs/a.md">html</a> <img src="img/p.png" alt="">',
                "",
                "[ref]: docs/a.md",
                '[ref2]: <docs/my file.md> "title"',
            ),
        )
        report = self.report()
        self.assertEqual(report.problems, [])
        self.assertEqual((report.files, report.links), (3, 15))

    def test_broken_links_with_the_line_of_their_target(self):
        self.write(
            "README.md",
            text_of(
                "# Project",
                "",
                "[gone](docs/gone.md) and ![gone](img/gone.png); a paragraph",
                "whose link text",
                "[spans",
                "lines](docs/also-gone.md)",
                "",
                '<a href="docs/b.md">inline HTML</a>',
                "",
                '<img src="docs/c.png" alt="an HTML block">',
                "",
                "[ref]:",
                "  docs/d.md",
            ),
        )
        self.assertBroken(
            [
                ("README.md", 3, "broken link docs/gone.md: docs/gone.md does not exist"),
                ("README.md", 3, "broken link img/gone.png: img/gone.png does not exist"),
                ("README.md", 6, "docs/also-gone.md does not exist"),
                ("README.md", 8, "docs/b.md does not exist"),
                ("README.md", 10, "docs/c.png does not exist"),
                ("README.md", 13, "docs/d.md does not exist"),
            ]
        )

    def test_targets_are_relative_to_the_linking_file(self):
        self.write("README.md")
        self.write("docs/b.md")
        self.write("docs/a.md", text_of("[sibling](b.md) [up](../README.md) [doubled](docs/b.md)"))
        self.assertBroken([("docs/a.md", 1, "broken link docs/b.md: docs/docs/b.md does not exist")])

    def test_outside_the_repository_untracked_and_empty_targets(self):
        self.write("notes.txt", "local notes", tracked=False)
        self.write("README.md", text_of("[up](../outside.md) [local](notes.txt) [nothing]()"))
        self.assertBroken(
            [
                ("README.md", 1, "broken link ../outside.md: it points outside the repository"),
                ("README.md", 1, "notes.txt is not tracked by git, so GitHub does not have it"),
                ("README.md", 1, "its target is empty"),
            ]
        )

    def test_external_links_are_neither_checked_nor_counted(self):
        self.write(
            "README.md",
            text_of(
                "[web](https://example.com/x.md) [plain](http://example.com) [mail](mailto:someone@example.com)",
                "<https://example.com/auto> <someone@example.com> [scheme-relative](//example.com/x)",
                "[issues](%s/issues) [a tag](%s/blob/v1.0/gone.md)" % (GITHUB, GITHUB),
                "[another repository](https://github.com/someone/else/blob/main/gone.md)",
            ),
        )
        report = self.report()
        self.assertEqual((report.problems, report.links), ([], 0))

    def test_unreadable_files_are_problems(self):
        self.write("README.md", "[latin](latin.md)\n")
        with open(os.path.join(self.root, "latin.md"), "wb") as handle:
            handle.write(b"caf\xe9\n")
        self.tracked += ["latin.md", "deleted.md"]
        self.assertBroken([("deleted.md", 1, "cannot read it"), ("latin.md", 1, "not UTF-8")])

    def test_html_python_cannot_parse_is_reported(self):
        self.write("README.md", text_of("Text.", "", "<div>", "<![ odd", "</div>"))
        with mock.patch.object(check_links.TagScanner, "feed", side_effect=AssertionError("unknown status keyword")):
            self.assertBroken([("README.md", 1, "cannot read the HTML on line 3: unknown status keyword")])

    def test_line_endings_tabs_and_a_byte_order_mark(self):
        self.write("README.md", "﻿# Title\r\n\r\n-\t[a](#title) [b](missing.md)\r\n")
        self.assertBroken([("README.md", 3, "missing.md does not exist")])


# ---------------------------------------------------------------------------
# Rule 2: where links can be
# ---------------------------------------------------------------------------


class CodeAndCommentsTest(TreeCase):
    """Nothing in code or an HTML comment is a link; what is around them still is."""

    def test_code_spans_fences_indented_code_and_comments(self):
        self.write(
            "README.md",
            text_of(
                "Spans: `[a](gone-1.md)`, ``[b](gone-2.md) with a ` inside``, and one over",
                "two lines: `[c](gone-3.md)",
                "still code`; [real](missing-1.md).",
                "",
                "```markdown",
                "[d](gone-4.md)",
                "[e]: gone-5.md",
                "```",
                "",
                "~~~~",
                "[f](gone-6.md)",
                "```",
                "~~~~",
                "",
                "    [g](gone-7.md) in an indented code block",
                "",
                "<!-- [h](gone-8.md)",
                "",
                "[i](gone-9.md) -->",
                "Text <!-- [j](gone-10.md) --> [real](missing-2.md)",
            ),
        )
        self.assertBroken([("README.md", 3, "missing-1.md"), ("README.md", 20, "missing-2.md")])

    def test_an_unclosed_fence_runs_to_the_end(self):
        self.write("README.md", text_of("[real](missing.md)", "", "```", "[a](gone.md)", "", "[b](gone.md)"))
        self.assertBroken([("README.md", 1, "missing.md")])

    def test_list_items_and_block_quotes(self):
        self.write(
            "README.md",
            text_of(
                "1. An item whose second paragraph is indented by four spaces:",
                "",
                "    [para](missing-1.md) is no code: the item's text starts at column 3.",
                "",
                "   ```",
                "   [fenced](gone-1.md)",
                "   ```",
                "",
                "       [code](gone-2.md) is code: seven spaces, four more than the item's text.",
                "",
                "> A quote whose next line is a lazy continuation:",
                "[lazy](missing-2.md)",
                "",
                "Text",
                "    [continued](missing-3.md): indented code cannot interrupt a paragraph.",
                "",
                "-",
                "",
                "      [after an empty item](gone-3.md) is code: the item ended at the blank line.",
            ),
        )
        self.assertBroken(
            [("README.md", 3, "missing-1.md"), ("README.md", 12, "missing-2.md"), ("README.md", 15, "missing-3.md")]
        )

    def test_html_blocks(self):
        self.write(
            "README.md",
            text_of(
                "<details>",
                "<summary>More</summary>",
                "[markdown](gone.md) is text inside an HTML block",
                '<a href="missing-1.md">an HTML link is a link</a>',
                "",
                "[after](missing-2.md): Markdown again after the blank line",
                "",
                "</details>",
            ),
        )
        self.assertBroken([("README.md", 4, "missing-1.md"), ("README.md", 6, "missing-2.md")])

    def test_tables(self):
        self.write(
            "README.md",
            text_of(
                "| Document | Note |",
                "|---|:---:|",
                "| [one](missing-1.md) | `[a](gone.md)` |",
                "| `a \\| b` [two](missing-2.md) | `x | [three](missing-3.md)` |",
            ),
        )
        # A pipe splits a cell even between backticks, as on GitHub: the last cell's link is a link.
        self.assertBroken(
            [("README.md", 3, "missing-1.md"), ("README.md", 4, "missing-2.md"), ("README.md", 4, "missing-3.md")]
        )

    def test_text_that_only_looks_like_a_definition(self):
        self.write(
            "README.md",
            text_of(
                "[verified: API 32]: empty-string values are dropped",
                "",
                '[label]: missing.md "a title"',
                "",
                "[^note]: a footnote, not a link",
                "",
                "[undefined] and [text][undefined] are text, [label] and [it][label] use the definition.",
            ),
        )
        self.assertBroken([("README.md", 3, "missing.md")])


# ---------------------------------------------------------------------------
# Rule 3: anchors
# ---------------------------------------------------------------------------


class AnchorTest(TreeCase):
    def test_github_slugs(self):
        self.write("docs/a.md")
        self.write("docs/p.png")
        self.write(
            "docs/b.md",
            text_of(
                "# 1. The source: `CHANGELOG.md`",
                "## C4:url transfer scheduling (OS 3.4.2)",
                "## Keypads (builds 146–160)",
                "## Control4 ⇄ Philips Hue",
                "## _Emphasis_ and snake_case and **bold**",
                "## [A link](a.md) and an ![image](p.png)",
                "## Ünïcödé Straße",
                "### R1. `importing` / `resyncing` guard (Medium)",
                "## Trailing hashes ##",
                "Setext heading",
                "==============",
            ),
        )
        anchors = (
            "1-the-source-changelogmd",
            "c4url-transfer-scheduling-os-342",
            "keypads-builds-146160",
            "control4--philips-hue",
            "emphasis-and-snake_case-and-bold",
            "a-link-and-an-",
            "ünïcödé-straße",
            "r1-importing--resyncing-guard-medium",
            "trailing-hashes",
            "setext-heading",
        )
        self.write("README.md", "".join("[x](docs/b.md#%s)\n" % anchor for anchor in anchors))
        self.assertClean()

    def test_a_missing_anchor_with_a_suggestion(self):
        self.write("docs/x.md", "# Elsewhere\n")
        self.write("README.md", text_of("# Getting started", "", "[a](#getting-startd) [b](docs/x.md#nowhere)"))
        self.assertBroken(
            [
                (
                    "README.md",
                    3,
                    'broken link #getting-startd: no heading or id "getting-startd" in this file '
                    "(did you mean #getting-started?)",
                ),
                ("README.md", 3, 'broken link docs/x.md#nowhere: no heading or id "nowhere" in docs/x.md'),
            ]
        )

    def test_repeated_headings_are_numbered(self):
        self.write(
            "README.md",
            text_of(
                "# Usage",
                "## Usage",
                "### Usage",
                "## Foo-1",
                "## Foo",
                "## Foo",
                "",
                "[a](#usage) [b](#usage-1) [c](#usage-2) [d](#foo-1) [e](#foo) [f](#foo-2) [g](#usage-3)",
            ),
        )
        self.assertBroken([("README.md", 8, 'no heading or id "usage-3"')])

    def test_explicit_ids_and_html_headings(self):
        self.write(
            "README.md",
            text_of(
                '<a id="install"></a>',
                '<a name="old-anchor"></a>',
                "",
                'Text with <span id="inline-id">an inline id</span>.',
                "",
                '<h2 id="html-id">Raw <em>HTML</em> heading</h2>',
                "",
                "[a](#install) [b](#old-anchor) [c](#inline-id) [d](#html-id) [e](#raw-html-heading)",
                "[top](#top) [empty](#) [encoded](#inline%2Did)",
            ),
        )
        self.assertClean()

    def test_folders_line_anchors_and_files_without_headings(self):
        self.write("docs/README.md", "# Index\n")
        self.write("tools/run.sh", "one\ntwo\nthree\n")
        self.write(
            "README.md",
            text_of(
                "[a](docs/#index) [b](docs#index) [c](tools/run.sh#L2) [d](tools/run.sh#L1-L3)",
                "[e](README.md?plain=1#L2) [f](tools/run.sh#anything-else-is-not-checked)",
                "[g](docs/#nowhere) [h](tools/run.sh#L4) [i](tools/#section)",
            ),
        )
        self.assertBroken(
            [
                ("README.md", 3, 'no heading or id "nowhere" in docs/README.md'),
                ("README.md", 3, "tools/run.sh has 3 lines"),
                ("README.md", 3, "tools has no README.md"),
            ]
        )

    def test_fragments_are_percent_decoded(self):
        self.write("README.md", text_of("# Größe", "", "[a](#gr%C3%B6%C3%9Fe) [b](#größe) [c](#Größe)"))
        self.assertBroken([("README.md", 3, 'no heading or id "Größe" in this file (did you mean #größe?)')])


# ---------------------------------------------------------------------------
# Rule 3: this repository on github.com
# ---------------------------------------------------------------------------


class GitHubLinkTest(TreeCase):
    def test_links_to_this_repository_are_local_paths(self):
        self.write("docs/a.md", "# Section\n")
        self.write(
            "README.md",
            text_of(
                "[blob](%s/blob/main/docs/a.md) [tree](%s/tree/main/docs) [root](%s/tree/main)" % ((GITHUB,) * 3),
                "[anchor](%s/blob/main/docs/a.md#section) [raw](%s/raw/main/docs/a.md)" % (GITHUB, GITHUB),
                "[any case](https://GitHub.com/Corytron/C4-Hue-Driver/blob/main/docs/a.md)",
                "[gone](%s/blob/main/docs/gone.md) [bad anchor](%s/blob/main/docs/a.md#nowhere)" % (GITHUB, GITHUB),
                "An autolink <%s/blob/main/docs/auto.md>, a bare %s/blob/main/docs/bare.md." % (GITHUB, GITHUB),
                "`%s/blob/main/docs/in-code.md`" % GITHUB,
            ),
        )
        self.assertBroken(
            [
                ("README.md", 4, "broken link %s/blob/main/docs/gone.md: docs/gone.md does not exist" % GITHUB),
                ("README.md", 4, 'no heading or id "nowhere" in docs/a.md'),
                ("README.md", 5, "docs/auto.md does not exist"),
                ("README.md", 5, "broken link %s/blob/main/docs/bare.md: docs/bare.md does not exist" % GITHUB),
            ]
        )
        self.assertEqual(self.report().links, 10)


# ---------------------------------------------------------------------------
# The Documentation tabs
# ---------------------------------------------------------------------------


class ManualTest(TreeCase):
    MANUAL = "src/hue_demo/www/documentation.html"

    def test_href_and_src_of_a_manual(self):
        self.write("README.md")
        self.write("src/hue_demo/www/img/a.png")
        self.write(
            self.MANUAL,
            text_of(
                "<html><body>",
                '<p><a href="#ch1">One</a> <a href="#changelog">Changelog</a> <a href="#ch9">Nine</a></p>',
                '<h2 id="ch1">1. One</h2>',
                '<img src="img/a.png" alt=""> <img src="img/missing.png" alt="">',
                '<!-- <img src="img/commented-out.png"> -->',
                '<a href="https://example.com/x">external</a> <a href="/img/a.png">from the root</a>',
                "<!-- CHANGELOG -->",
                "</body></html>",
            ),
        )
        self.assertBroken(
            [
                (self.MANUAL, 2, 'broken link #ch9: no heading or id "ch9" in this file'),
                (self.MANUAL, 4, "img/missing.png: src/hue_demo/www/img/missing.png does not exist"),
                (self.MANUAL, 6, "a manual's links are relative to its folder, src/hue_demo/www"),
            ]
        )
        self.assertEqual(self.report().files, 2)

    def test_only_the_documentation_tabs_are_html_sources(self):
        self.write("src/hue_demo/www/other.html", '<a href="gone.html">x</a>\n')
        self.write("docs/page.html", '<p id="here"><a href="gone.html">x</a></p>\n')
        self.write("README.md", "[page](docs/page.html#here) [section](docs/page.html#section)\n")
        self.assertBroken([("README.md", 1, 'no heading or id "section" in docs/page.html')])
        self.assertEqual(self.report().files, 1)

    def test_marker_ids_are_those_of_the_changelog_fragment(self):
        fragment = changelog.render_html(changelog.parse("# Changelog\n\n## Unreleased\n"), "Unreleased")
        self.assertEqual(list(check_links.MARKER_IDS), ["<!-- CHANGELOG -->"])
        self.assertEqual(check_links.html_document(fragment)[1], set(check_links.MARKER_IDS["<!-- CHANGELOG -->"]))
        with open(os.path.join(TOOLS, "build.sh"), encoding="utf-8") as handle:
            self.assertIn("<!-- CHANGELOG -->", handle.read())


# ---------------------------------------------------------------------------
# --unlinked
# ---------------------------------------------------------------------------


class UnlinkedTest(TreeCase):
    UNLINKED = ["CLAUDE.md", "docs/c.md", "docs/d.md", "docs/f.md", "docs/g.md"]

    def setUp(self):
        super().setUp()
        self.write(
            "README.md",
            text_of(
                "[docs](docs/README.md) [a folder](sub/) [on GitHub](%s/blob/main/USING.md)" % GITHUB,
                "In code, `[f](docs/f.md)` is no link.",
            ),
        )
        self.write("USING.md")
        self.write("sub/README.md")
        self.write("docs/README.md", "[a](a.md) [reviews](reviews/index.md)\n")
        self.write("docs/a.md", "[b](b.md)\n")
        self.write("docs/b.md")
        self.write("docs/c.md", "[d](d.md)\n")
        self.write("docs/d.md")
        self.write("docs/f.md")
        self.write("docs/g.md")
        self.write("docs/h.md")
        self.write("docs/reviews/index.md", "[h](../h.md)\n")
        self.write("docs/reviews/old.md", "[g](../g.md)\n")
        self.write("CLAUDE.md")
        self.write(".github/PULL_REQUEST_TEMPLATE.md")
        self.write("src/hue_demo/notes.md")

    def test_the_documents_readme_does_not_reach(self):
        self.assertEqual(self.report().unlinked, self.UNLINKED)

    def test_listed_only_with_the_option_and_never_failing(self):
        code, out, err = self.run_main()
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out, "links: 16 files, 9 links, 0 problems\n")
        code, out, err = self.run_main("--unlinked")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(
            out.splitlines(),
            ["%s: not reachable from README.md" % path for path in self.UNLINKED]
            + ["links: 16 files, 9 links, 0 problems"],
        )

    def test_broken_links_still_decide_the_exit_status(self):
        self.write("docs/c.md", "[gone](gone.md)\n")
        code, out, _err = self.run_main("--unlinked")
        self.assertEqual(code, 1)
        lines = out.splitlines()
        self.assertEqual(lines[0], "docs/c.md:1: broken link gone.md: docs/gone.md does not exist")
        self.assertEqual(lines[1:-1], ["%s: not reachable from README.md" % path for path in self.UNLINKED])
        self.assertEqual(lines[-1], "links: 16 files, 9 links, 1 problem")

    def test_without_a_readme_nothing_is_reached(self):
        self.tracked.remove("README.md")
        self.assertEqual(
            self.report().unlinked,
            ["CLAUDE.md", "USING.md"] + ["docs/%s.md" % name for name in "README a b c d f g h".split()],
        )

    def test_exemptions_have_reasons(self):
        self.assertEqual([pattern for pattern, _reason in check_links.EXEMPT], ["docs/reviews/*", ".github/*"])
        for pattern, reason in check_links.EXEMPT:
            self.assertTrue(reason.strip(), pattern)


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------


class CommandLineTest(TreeCase):
    def test_output_and_exit_status(self):
        self.write("README.md", "[itself](README.md) [gone](gone.md)\n")
        self.assertEqual(
            self.run_main(),
            (1, "README.md:1: broken link gone.md: gone.md does not exist\nlinks: 1 file, 2 links, 1 problem\n", ""),
        )
        self.write("gone.md")
        self.assertEqual(self.run_main(), (0, "links: 2 files, 2 links, 0 problems\n", ""))

    def test_usage_errors_exit_2(self):
        for argv in (["--bogus"], ["--root", os.path.join(self.root, "missing")], ["extra"]):
            with self.subTest(argv=argv):
                err = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                    with self.assertRaises(SystemExit) as raised:
                        check_links.main(argv)
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("usage:", err.getvalue())

    def test_a_root_that_is_not_a_work_tree_exits_2(self):
        def failing(root, *args):
            raise check_links.UsageError("git rev-parse --show-toplevel failed in %s: not a git repository" % root)

        self.assertEqual(self.run_main(git=failing)[:2], (2, ""))
        self.assertIn("not a git repository", self.run_main(git=failing)[2])
        os.makedirs(os.path.join(self.root, "docs"))
        code, out, err = self.run_main(git=self.fake_git_at_root, root=os.path.join(self.root, "docs"))
        self.assertEqual((code, out), (2, ""))
        self.assertIn("is not the top of a git work tree", err)

    def fake_git_at_root(self, _root, *args):
        return self.root + "\n" if args[0] == "rev-parse" else ""

    def test_tracked_files_come_from_git_ls_files(self):
        calls = []

        def git(root, *args):
            calls.append(args)
            return root + "\n" if args[0] == "rev-parse" else "b.md\0a dir/c.md\0"

        with mock.patch.object(check_links, "run_git", git):
            self.assertEqual(check_links.tracked_files(self.root), ["a dir/c.md", "b.md"])
        self.assertEqual(calls, [("rev-parse", "--show-toplevel"), ("ls-files", "-z")])

    @unittest.skipIf(shutil.which("git") is None, "git is not installed")
    def test_real_git_refuses_a_directory_outside_a_work_tree(self):
        with self.assertRaises(check_links.UsageError):
            check_links.tracked_files(self.root)

    def test_help(self):
        env = dict(os.environ, NO_COLOR="1")
        env.pop("FORCE_COLOR", None)
        done = subprocess.run(
            [sys.executable, "-I", SCRIPT, "--help"], capture_output=True, text=True, env=env, check=False
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        text = " ".join(done.stdout.split())
        for piece in ("check_links.py", "--root DIR", "--unlinked", "Exit codes: 0 no broken link, 1 broken links"):
            self.assertIn(piece, text)


# ---------------------------------------------------------------------------
# This repository, report only
# ---------------------------------------------------------------------------


class RealRepositoryReport(unittest.TestCase):
    """Report only: runs the checker read-only on this repository, with --unlinked, and prints what it
    finds for the coordinator to fix. Broken links never fail this test (tools/check.sh's links check
    is what gates them); only a crash or a usage error does."""

    def test_report_on_this_repository(self):
        if shutil.which("git") is None:
            self.skipTest("git is not installed")
        top = subprocess.run(
            ["git", "-C", REPO, "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False
        )
        if top.returncode != 0 or os.path.realpath(top.stdout.strip()) != os.path.realpath(REPO):
            self.skipTest("%s is not the top of a git work tree" % REPO)
        done = subprocess.run(
            [sys.executable, "-I", "-B", SCRIPT, "--root", REPO, "--unlinked"],
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        sys.stderr.write(
            "\ncheck_links.py --unlinked on this repository (report only, exit %d):\n%s%s"
            % (done.returncode, done.stdout, done.stderr)
        )
        self.assertIn(done.returncode, (0, 1), done.stderr)
        self.assertRegex(done.stdout.splitlines()[-1], r"^links: [0-9]+ files?, [0-9]+ links?, [0-9]+ problems?$")


if __name__ == "__main__":
    unittest.main()
