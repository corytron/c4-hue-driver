"""Unit tests for tools/changelog.py, on small synthetic changelogs and codenames files in a temporary
directory; never the repository's CHANGELOG.md (docs/changelog-design.md).

Run: python3 -m unittest discover -s tools/tests -v
"""

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from html.parser import HTMLParser

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import changelog  # noqa: E402

SCRIPT = os.path.join(TOOLS, "changelog.py")

# Line numbers: 5 "## Unreleased", 7 its "### Fixed", 8 and 9 its bullets (9 continues on 10),
# 12 build 349 (14 Added, 16 Fixed), 19 build 259 (21 Changed, 24 Known limits), 27 build 120 of 0.9.
UNRELEASED_BODY = (
    "### Fixed\n"
    "- The scene slider no longer jumps back after a recall (#301).\n"
    "- Keypad LEDs follow a scene recalled in the Hue app,\n"
    "  also after a bridge restart (#302).\n"
    "\n"
)
SAMPLE = (
    "# Changelog\n"
    "\n"
    "Every release of the drivers, newest first; builds count the commits of the repository.\n"
    "\n"
    "## Unreleased\n"
    "\n" + UNRELEASED_BODY + '## 1.0 "Cassian", build 349 (2026-10-25)\n'
    "\n"
    "### Added\n"
    "- Scenes show `Last Recalled` in Composer (#240).\n"
    "### Fixed\n"
    "- **Pairing** survives a bridge restart; see [the manual](https://example.com/manual#pairing) (#236).\n"
    "\n"
    '## 1.0 "Cassian", build 259 (2026-10-24)\n'
    "\n"
    "### Changed\n"
    "- Lights import into the room their Hue room maps to.\n"
    "\n"
    "### Known limits\n"
    "- No motion sensors yet.\n"
    "\n"
    '## 0.9 "Ferrix", build 120 (2026-09-01)\n'
    "\n"
    "### Added\n"
    "- The first build.\n"
)
EMPTY_UNRELEASED = SAMPLE.replace(UNRELEASED_BODY, "")

# The codenames file of the tests (.github/codenames.json, issue #304): SAMPLE's 0.9 and 1.0, and 1.1
# for the next release and its betas; 2.0 has none. "Luthen" is only ever a name that is refused.
CODENAME_OF = {"0.9": "Ferrix", "1.0": "Cassian", "1.1": "Brasso"}
CODENAMES = json.dumps(CODENAME_OF, indent=2) + "\n"

TEMPLATE = (
    '## {version} "{codename}" (build {build})\n'
    "\n"
    'Released {date}. Braces that name no placeholder stay: {"key": 1}, ${{ github.sha }}, {Version}.\n'
    "\n"
    "### New in build {build}\n"
    "\n"
    "{this_build}\n"
    "\n"
    "### Earlier builds of {version}\n"
    "\n"
    "{history}\n"
    "\n"
    "Every release: CHANGELOG.md.\n"
)

RELEASE = ("--version", "1.0", "--build", "360", "--date", "2026-11-02")
HTML_RELEASE = ("--release", "1.0", "--build", "360", "--date", "2026-11-02")
NEW_HEADING = '## 1.0 "Cassian", build 360 (2026-11-02)'

# Prereleases (docs/prerelease-design.md): the same Unreleased entry, never shown as the release.
PRERELEASE = ("--version", "1.1-beta.1", "--build", "360", "--date", "2026-11-02")
HTML_PRERELEASE = ("--release", "1.1-beta.1", "--build", "360", "--date", "2026-11-02")
PRERELEASE_H3 = "<h3>1.1 beta 1 &quot;Brasso&quot; (prerelease), build 360 (2026-11-02)</h3>"
PRERELEASE_TEMPLATE = (
    '## {release} beta {beta} "{codename}" (build {build})\n'
    "\n"
    "Version {version}, built {date}, follows [{stable}](https://example.com/v{stable_version}).\n"
    "\n"
    "{this_build}\n"
)


def text_of(*rows):
    """A file made of rows, one per line: row k is line k + 1."""
    return "\n".join(rows) + "\n"


class TagCollector(HTMLParser):
    """Every tag of an HTML fragment with its attributes, and whether it holds anything else."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.other = []

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, attrs))

    def handle_startendtag(self, tag, attrs):
        self.tags.append((tag, attrs))

    def handle_comment(self, data):
        self.other.append("comment " + data)

    def handle_decl(self, decl):
        self.other.append("declaration " + decl)

    def handle_pi(self, data):
        self.other.append("processing instruction " + data)


# ---------------------------------------------------------------------------
# The parser
# ---------------------------------------------------------------------------


class ParseTest(unittest.TestCase):
    def test_entries_with_their_fields_and_line_numbers(self):
        parsed = changelog.parse(SAMPLE)
        self.assertEqual(parsed.problems, [])
        self.assertEqual(
            [
                (entry.kind, entry.line, entry.version, entry.codename, entry.build, entry.date)
                for entry in parsed.entries
            ],
            [
                ("unreleased", 5, None, None, None, None),
                ("release", 12, (1, 0), "Cassian", 349, "2026-10-25"),
                ("release", 19, (1, 0), "Cassian", 259, "2026-10-24"),
                ("release", 27, (0, 9), "Ferrix", 120, "2026-09-01"),
            ],
        )
        self.assertIs(parsed.unreleased, parsed.entries[0])
        self.assertEqual([entry.build for entry in parsed.releases], [349, 259, 120])
        self.assertEqual(parsed.entries[1].heading, '1.0 "Cassian", build 349 (2026-10-25)')
        self.assertEqual(
            [[(section.name, section.line) for section in entry.sections] for entry in parsed.entries],
            [[("Fixed", 7)], [("Added", 14), ("Fixed", 16)], [("Changed", 21), ("Known limits", 24)], [("Added", 29)]],
        )
        fixed = parsed.unreleased.sections[0]
        self.assertEqual([bullet.line for bullet in fixed.bullets], [8, 9])
        self.assertEqual(
            fixed.bullets[1].paragraphs[0].text,
            "Keypad LEDs follow a scene recalled in the Hue app, also after a bridge restart (#302).",
        )
        self.assertEqual(
            fixed.bullets[1].source,
            ["- Keypad LEDs follow a scene recalled in the Hue app,", "  also after a bridge restart (#302)."],
        )
        self.assertEqual(parsed.unreleased.bullet_count(), 2)

    def test_empty_unreleased_entry(self):
        parsed = changelog.parse(EMPTY_UNRELEASED)
        self.assertEqual(parsed.problems, [])
        self.assertEqual(parsed.unreleased.sections, [])
        self.assertEqual(parsed.unreleased.bullet_count(), 0)

    def test_crlf_line_endings(self):
        parsed = changelog.parse(SAMPLE.replace("\n", "\r\n"))
        self.assertEqual(parsed.problems, [])
        self.assertEqual([entry.build for entry in parsed.releases], [349, 259, 120])
        self.assertEqual(parsed.unreleased.sections[0].bullets[1].source[1], "  also after a bridge restart (#302).")


class MultiParagraphTest(unittest.TestCase):
    """A blank line, then a line indented by two spaces: the bullet's next paragraph."""

    TEXT = text_of(
        "# Changelog",
        "",
        "## Unreleased",
        "",
        "### Fixed",
        "- First paragraph of the bullet,",  # 6
        "  wrapped once.",
        "",
        "  Second paragraph of the same bullet (#9).",  # 9
        "- Next bullet.",  # 10
    )

    def test_parsed_as_two_paragraphs_of_one_bullet(self):
        parsed = changelog.parse(self.TEXT)
        self.assertEqual(parsed.problems, [])
        bullets = parsed.unreleased.sections[0].bullets
        self.assertEqual([bullet.line for bullet in bullets], [6, 10])
        self.assertEqual(
            [paragraph.text for paragraph in bullets[0].paragraphs],
            ["First paragraph of the bullet, wrapped once.", "Second paragraph of the same bullet (#9)."],
        )
        self.assertEqual(
            bullets[0].source,
            ["- First paragraph of the bullet,", "  wrapped once.", "", "  Second paragraph of the same bullet (#9)."],
        )
        self.assertEqual(bullets[0].paragraphs[1].line_at(0), 9)

    def test_html_gives_each_paragraph_its_p(self):
        out = changelog.render_html(changelog.parse(self.TEXT), "Unreleased")
        self.assertIn(
            "<li><p>First paragraph of the bullet, wrapped once.</p>"
            "<p>Second paragraph of the same bullet (#9).</p></li>\n<li>Next bullet.</li>",
            out,
        )

    def test_notes_keep_the_lines_as_written(self):
        self.assertEqual(
            changelog.markdown_sections(changelog.parse(self.TEXT).unreleased),
            "**Fixed**\n\n- First paragraph of the bullet,\n  wrapped once.\n\n"
            "  Second paragraph of the same bullet (#9).\n- Next bullet.",
        )

    def test_a_problem_in_the_second_paragraph_names_its_line(self):
        text = self.TEXT.replace("same bullet (#9).", "same <b>bullet</b> (#9).")
        self.assertEqual([line for line, _ in changelog.parse(text).problems], [9])


# ---------------------------------------------------------------------------
# check: every rule of section 1, each with its line number
# ---------------------------------------------------------------------------


class CheckRulesTest(unittest.TestCase):
    HEAD = ["# Changelog", "## Unreleased", "### Fixed", "- A fix."]  # a fifth row is line 5

    def assertProblems(self, rows, *expected, codenames=None):
        """Exactly the expected (line, fragment of the message) problems, in line order."""
        problems = changelog.parse(text_of(*rows), codenames).problems
        self.assertEqual([line for line, _ in problems], [line for line, _ in expected], problems)
        for (_, message), (_, fragment) in zip(problems, expected, strict=True):
            self.assertIn(fragment, message)

    def release(self, build, date="2026-10-25", codename="Cassian", version="1.0"):
        return ['## %s "%s", build %d (%s)' % (version, codename, build, date), "### Fixed", "- A fix."]

    def test_sample_passes(self):
        self.assertEqual(changelog.parse(SAMPLE).problems, [])
        self.assertEqual(changelog.parse(EMPTY_UNRELEASED).problems, [])

    def test_first_line_is_the_title(self):
        self.assertProblems(["# Change log", "", "## Unreleased"], (1, "the first line must be '# Changelog'"))
        self.assertProblems(["## Unreleased"], (1, "the first line must be '# Changelog', not '## Unreleased'"))
        self.assertProblems(
            ["# Changelog", "", "# Second title", "## Unreleased"], (3, "no headings before '## Unreleased'")
        )

    def test_no_headings_in_the_introduction(self):
        self.assertProblems(
            ["# Changelog", "", "### Notes", "Text.", "  ## Indented", "", "## Unreleased"],
            (3, "no headings before '## Unreleased'"),
            (5, "no headings before '## Unreleased'"),
        )

    def test_first_entry_heading_is_unreleased(self):
        self.assertProblems(
            ["# Changelog", ""] + self.release(349),
            (3, "the first ## heading must be '## Unreleased' (it may be empty), not '## 1.0"),
        )
        self.assertProblems(["# Changelog", "## unreleased"], (2, "not '## unreleased'"))
        self.assertProblems(["# Changelog", "", "Intro."], (3, "no '## Unreleased' heading"))
        self.assertProblems([], (1, "the first line must be"), (1, "no '## Unreleased' heading"))

    def test_unreleased_only_once(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(349) + ["## Unreleased"],
            (6, "'## Unreleased' only once"),
        )

    def test_unreleased_may_be_empty(self):
        self.assertProblems(["# Changelog", "", "## Unreleased", ""] + self.release(349))
        self.assertProblems(["# Changelog", "## Unreleased"])

    def test_release_heading_shape(self):
        for heading in (
            '## 1.0 "Cassian" build 349 (2026-10-25)',
            "## 1.0 Cassian, build 349 (2026-10-25)",
            '## v1.0 "Cassian", build 349 (2026-10-25)',
            '## 1 "Cassian", build 349 (2026-10-25)',
            '## 1.0 "", build 349 (2026-10-25)',
            '## 1.0 "Cassian", Build 349 (2026-10-25)',
            '## 1.0 "Cassian", build 349 (25.10.2026)',
            '## 1.0 "Cassian", build 349 (2026-10-25) ',
            '##  1.0 "Cassian", build 349 (2026-10-25)',
            "## Released",
        ):
            with self.subTest(heading=heading):
                self.assertProblems(
                    ["# Changelog", "## Unreleased", heading, "### Fixed", "- A fix."],
                    (3, "a release heading reads '## 1.0 \"Cassian\", build 349 (2026-10-25)', not %r" % heading),
                )

    def test_release_date_exists(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(349, date="2026-02-30"), (3, "no such date: 2026-02-30")
        )

    def test_builds_strictly_decrease(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(300) + self.release(349, date="2026-10-24"),
            (6, "build 349 is below build 300 on line 3"),
        )
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(349) + self.release(349),
            (6, "build 349 has an entry already, on line 3"),
        )

    def test_dates_never_increase(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased"] + self.release(349, date="2026-10-24") + self.release(300),
            (6, "2026-10-25 is below 2026-10-24 on line 3"),
        )
        self.assertProblems(["# Changelog", "## Unreleased"] + self.release(349) + self.release(300))  # same day

    def test_each_release_carries_the_codename_of_its_version(self):
        codenames = changelog.parse_codenames(CODENAMES)
        head = ["# Changelog", "## Unreleased"]
        self.assertProblems(
            head
            + self.release(400, version="1.1", codename="Brasso")
            + self.release(349)
            + self.release(120, version="0.9", codename="Ferrix"),
            codenames=codenames,
        )
        # One codename per X.Y, not per major version: 1.1 does not take 1.0's, nor any other.
        self.assertProblems(
            head + self.release(400, version="1.1", codename="Cassian") + self.release(349),
            (3, '1.1 is named "Brasso" in .github/codenames.json, not "Cassian"'),
            codenames=codenames,
        )
        self.assertProblems(
            head + self.release(400, version="1.1", codename="Luthen") + self.release(349, codename="cassian"),
            (3, '1.1 is named "Brasso" in .github/codenames.json, not "Luthen"'),
            (6, '1.0 is named "Cassian" in .github/codenames.json, not "cassian"'),
            codenames=codenames,
        )
        self.assertProblems(
            head + self.release(500, version="2.0", codename="Mon Mothma") + self.release(349),
            (3, "2.0 has no codename in .github/codenames.json: each X.Y gets its own there before its first build"),
            codenames=codenames,
        )
        # Without a codenames file the parser checks the form only.
        self.assertProblems(
            head + self.release(500, version="2.0", codename="Mon Mothma") + self.release(349, codename="cassian")
        )

    def test_only_known_categories(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Removed", "- A removal."], (3, "unknown category 'Removed'")
        )
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed ", "- A fix."], (3, "unknown category 'Fixed '")
        )
        self.assertProblems(["# Changelog", "## Unreleased", "### fixed", "- A fix."], (3, "unknown category 'fixed'"))

    def test_categories_in_order(self):
        self.assertProblems(self.HEAD + ["### Added", "- An addition."], (5, "### Added after ### Fixed"))
        self.assertProblems(
            ["# Changelog", "## Unreleased"]
            + ["### Added", "- a.", "### Changed", "- b.", "### Fixed", "- c.", "### Security", "- d."]
            + ["### Known limits", "- e."]
        )

    def test_each_category_at_most_once(self):
        self.assertProblems(
            self.HEAD + ["### Fixed", "- Another fix."], (5, "### Fixed a second time in this entry (first on line 3)")
        )

    def test_a_category_has_bullets(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed", "", "### Security", "- A fix."],
            (3, "### Fixed has no bullets"),
        )

    def test_every_released_entry_has_a_bullet(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", '## 1.0 "Cassian", build 349 (2026-10-25)', ""],
            (3, '1.0 "Cassian", build 349 (2026-10-25) has no bullets'),
        )

    def test_nothing_outside_a_category(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "Some text.", "- A bullet."],
            (3, "text outside a ### category"),
            (4, "a bullet outside a ### category"),
        )

    def test_only_bullets_and_continuation_lines_under_a_category(self):
        for line, fragment in (
            ("* A star bullet.", "bullets start with '- ', not '* '"),
            ("+ A plus bullet.", "bullets start with '- ', not '+ '"),
            ("1. A numbered line.", "no numbered lists"),
            ("| a | b |", "no tables"),
            ("<div>HTML</div>", "no HTML"),
            ("```", "no code blocks"),
            ("> A quote.", "no block quotes"),
            ("---", "no horizontal rules"),
            ("Plain text.", "only bullets ('- ' and the text) and their continuation lines"),
            ("-x", "only bullets ('- ' and the text) and their continuation lines"),
            (" one space", "indented by exactly two spaces, not 1"),
            ("   three spaces", "indented by exactly two spaces, not 3"),
            ("      code block", "indented by exactly two spaces, not 6"),
            ("\ttab", "not a tab"),
            ("  \ttab", "not a tab"),
            ("-", "an empty bullet"),
            ("- ", "an empty bullet"),
            ("-  Two spaces.", "one space after the dash"),
            ("#### Deeper heading", "only ## and ### headings"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD + [line], (5, fragment))

    def test_no_nested_lists_or_other_blocks_in_a_bullet(self):
        for line, fragment in (
            ("  - A nested bullet.", "no nested lists"),
            ("  * A nested star.", "no nested lists"),
            ("  1. A nested number.", "no nested lists"),
            ("  > A quote.", "no block quotes"),
            ("  | a | b |", "no tables"),
            ("  ---", "no rules or underlined headings"),
            ("  ===", "no rules or underlined headings"),
            ("  # A heading.", "no headings inside a bullet"),
            ("  ~~~", "no code blocks"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD + [line], (5, fragment))
        for line, fragment in (
            ("- - A nested bullet.", "no nested lists"),
            ("- 2. A nested number.", "no nested lists"),
            ("- # A heading.", "no headings inside a bullet"),
            ("- [ ] A task.", "no task-list boxes"),
            ("- > A quote.", "no block quotes"),
        ):
            with self.subTest(line=line):
                self.assertProblems(self.HEAD[:3] + [line], (4, fragment))
        # After a blank line any number starts a list; within a paragraph only 1 does.
        self.assertProblems(self.HEAD + ["", "  2. A list after a blank line."], (6, "no nested lists"))
        self.assertProblems(self.HEAD[:3] + ["- Wrapped in the", "  2026. year, as text (#5)."])

    def test_continuation_line_needs_a_bullet(self):
        self.assertProblems(
            ["# Changelog", "## Unreleased", "### Fixed", "", "  An orphan.", "- A fix."],
            (5, "a continuation line (two spaces) with no bullet above it"),
        )

    def test_inline_markup_rules(self):
        for bullet, fragment in (
            ("- Unclosed `code here.", "unclosed `code`"),
            ("- Closed `code` then a stray ` here.", "unclosed `code`"),
            ("- Unclosed **bold here.", "unclosed **bold**"),
            ("- Three **markers** and ** one.", "unclosed **bold**"),
            ("- Inline <b>HTML</b>.", "no HTML"),
            ("- A <br/> break.", "no HTML"),
            ("- A comment <!-- note -->.", "no HTML"),
            ("- An entity &amp; here.", "no HTML entities"),
            ("- A number &#38; here.", "no HTML entities"),
            ("- An image ![alt](https://example.com/a.png).", "no images"),
            ("- An autolink <https://example.com/a>.", "a link is written [text](url)"),
            ("- A [broken link](https://example.com/a b).", "with no space in the url"),
            ("- A [reference][1] link.", "with no space in the url"),
            ("- Some *italic* text.", "no *italic*"),
            ("- Some _italic_ text.", "no _italic_"),
            ("- Some ~~struck~~ text.", "no ~~strikethrough~~"),
            ("- Italic code *`x`*.", "no *italic*"),
        ):
            with self.subTest(bullet=bullet):
                self.assertProblems(self.HEAD[:3] + [bullet], (4, fragment))

    def test_inline_problem_names_the_line_it_is_on(self):
        self.assertProblems(
            self.HEAD[:3] + ["- First line of the bullet,", "  then <b>HTML</b> on the second,", "  and a third."],
            (5, "no HTML"),
        )
        self.assertProblems(
            self.HEAD[:3] + ["- A `code span", "  across two lines` is fine, but **bold", "  never closes."],
            (5, "unclosed **bold**"),
        )

    def test_allowed_inline_markup_passes(self):
        self.assertProblems(
            self.HEAD[:3]
            + [
                "- `<!-- CHANGELOG -->` in code, and `a*b*c`, `x_y_z`, `&amp;`, `<b>` (#255).",
                "- **Bold**, **`bold code`**, [a link](https://example.com/x_y_z?a=1&b=2) and [`code`](https://example.com).",
                "- Escaped \\*stars\\*, \\_underscores\\_, \\`backticks\\` and \\<b> stay text.",
                "- Sums 2 * 3 * 4, snake_case_name, __init__, a < b, x > y, R&D;, A & B, C# and #123.",
                "- About ~5 to ~10 seconds, ~/path and 5 ~ 6.",
                "- Code ``with `ticks` inside`` and ``` `` ```.",
                "- A box [ ] in the middle of a bullet is text.",
            ]
        )


class CodenamesFileTest(unittest.TestCase):
    """.github/codenames.json (docs/changelog-design.md, section 1; issue #304): each X.Y its own name."""

    def problems(self, text):
        return changelog.parse_codenames(text).problems

    def test_names_each_version(self):
        codenames = changelog.parse_codenames(CODENAMES)
        self.assertEqual(
            (codenames.path, codenames.names, codenames.problems),
            (changelog.CODENAMES_FILE, {(0, 9): "Ferrix", (1, 0): "Cassian", (1, 1): "Brasso"}, []),
        )
        self.assertEqual((changelog.parse_codenames("{}").names, self.problems("{}")), ({}, []))
        self.assertEqual(self.problems('{"10.0": "Cassian", "0.10": "Brasso"}'), [])
        for name in ("K-2SO", "Mon Mothma", "B2EMO", "Saw Gerrera", "Kreegyr", "0-0-0"):
            with self.subTest(name=name):
                self.assertEqual(self.problems(json.dumps({"12.34": name})), [])

    def test_no_name_twice(self):
        self.assertEqual(
            self.problems('{"1.0": "Cassian", "1.1": "Brasso", "1.2": "Brasso", "2.0": "CASSIAN"}'),
            [
                '"1.2": "Brasso" names 1.1 already: each X.Y has its own codename',
                '"2.0": "CASSIAN" names 1.0 already (as "Cassian"): each X.Y has its own codename',
            ],
        )

    def test_a_key_is_a_version_x_y(self):
        for key in ("1.1-beta.1", "v1.1", "1", "1.1.0", "01.1", "1.01", "1.", ".1", "", " 1.1", "1.1 ", "1,1"):
            with self.subTest(key=key):
                self.assertEqual(
                    self.problems(json.dumps({key: "Brasso"})),
                    [
                        '%s: a key is a version X.Y, such as "1.1", without leading zeros; a beta takes the '
                        "codename of its X.Y" % json.dumps(key)
                    ],
                )
        self.assertEqual(len(self.problems('{"\\u0661.\\u0661": "Brasso"}')), 1)  # ASCII digits only

    def test_a_version_once(self):
        codenames = changelog.parse_codenames('{"1.1": "Brasso", "1.1": "Luthen"}')
        self.assertEqual(codenames.problems, ['"1.1" is a key twice: each X.Y has one codename'])
        self.assertEqual(codenames.names, {(1, 1): "Brasso"})

    def test_a_codename_is_plain(self):
        cases = [(text, text) for text in ('""', '" Brasso"', '"Brasso "', '"Bras  so"', '"-Brasso"', '"Brasso-"')]
        cases += [(text, text) for text in ('"Bras--so"', '"Brasso!"', '"Say \\"hi\\""', '"Br\\u00e4sso"')]
        cases += [('"Bras\\nso"', '"Bras\\nso"'), ('"Bras\\tso"', '"Bras\\tso"'), ("42", "42"), ("null", "null")]
        cases += [("true", "true"), ('["Brasso"]', "an array"), ('{"name": "Brasso"}', "an object")]
        for value, shown in cases:
            with self.subTest(value=value):
                self.assertEqual(
                    self.problems('{"1.1": %s}' % value),
                    ['"1.1": a codename is %s, not %s' % (changelog.CODENAME_SHAPE, shown)],
                )

    def test_refuses_what_is_not_one_json_object(self):
        for text, fragment in (
            ("", ".github/codenames.json is not JSON: Expecting value: line 1 column 1"),
            ('{"1.1": "Brasso",}', ".github/codenames.json is not JSON: "),
            ('{"1.1": "Brasso"} {}', "is not JSON: Extra data"),
            ("\ufeff{}", "is not JSON: Unexpected UTF-8 BOM"),
            (
                '["Brasso"]',
                '.github/codenames.json holds one JSON object that names each version X.Y, such as {"1.1": "Brasso"}, '
                "not an array",
            ),
            ('"Brasso"', 'X.Y, such as {"1.1": "Brasso"}, not "Brasso"'),
            ("null", "not null"),
        ):
            with self.subTest(text=text):
                with self.assertRaises(changelog.ChangelogError) as raised:
                    changelog.parse_codenames(text)
                self.assertIn(fragment, str(raised.exception))

    def test_the_repository_file(self):
        self.assertEqual(changelog.CODENAMES_FILE, os.path.join(os.path.dirname(TOOLS), ".github", "codenames.json"))
        codenames = changelog.read_codenames(changelog.CODENAMES_FILE)
        self.assertEqual(codenames.problems, [])
        # A released or prereleased version keeps its name (issue #304).
        self.assertEqual((codenames.names[(1, 0)], codenames.names[(1, 1)]), ("Cassian", "Brasso"))


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------


class CliCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = os.path.join(self.tmp.name, "CHANGELOG.md")
        self.template = os.path.join(self.tmp.name, "release-notes.md")
        self.codenames = os.path.join(self.tmp.name, "codenames.json")
        self.write(SAMPLE)
        self.write_codenames(CODENAMES)
        with open(self.template, "w", encoding="utf-8") as handle:
            handle.write(TEMPLATE)

    def write(self, text):
        with open(self.file, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)

    def write_codenames(self, text):
        with open(self.codenames, "w", encoding="utf-8") as handle:
            handle.write(text)

    def read(self):
        with open(self.file, encoding="utf-8", newline="") as handle:
            return handle.read()

    def run_main(self, command, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = changelog.main([command, "--file", self.file, "--codenames", self.codenames, *argv])
        return code, out.getvalue(), err.getvalue()

    def usage_error(self, command, *argv):
        """The exit code and stderr of a run that argparse ends."""
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                changelog.main([command, "--file", self.file, "--codenames", self.codenames, *argv])
        return raised.exception.code, err.getvalue()

    def html(self, *argv):
        code, out, err = self.run_main("html", *argv)
        self.assertEqual(code, 0, err)
        return out

    def notes(self, *argv):
        return self.run_main("notes", "--template", self.template, *argv)


class CheckCommandTest(CliCase):
    def test_ok(self):
        self.assertEqual(self.run_main("check"), (0, "%s: ok (3 releases)\n" % self.file, ""))
        self.write(
            text_of("# Changelog", "## Unreleased", '## 1.0 "Cassian", build 7 (2026-10-01)', "### Added", "- One.")
        )
        self.assertEqual(self.run_main("check")[1], "%s: ok (1 release)\n" % self.file)

    def test_every_problem_with_its_line_number(self):
        self.write(SAMPLE.replace("### Changed", "### Removed").replace("(2026-09-01)", "(2026-12-01)"))
        code, out, err = self.run_main("check")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        lines = err.splitlines()
        self.assertEqual(len(lines), 3, err)
        self.assertTrue(lines[0].startswith("%s:21: unknown category 'Removed'" % self.file), lines[0])
        self.assertTrue(lines[1].startswith("%s:27: 2026-12-01 is below 2026-10-24 on line 19" % self.file), lines[1])
        self.assertEqual(lines[2], "%s: 2 problems" % self.file)

    def test_missing_file(self):
        os.unlink(self.file)
        code, out, err = self.run_main("check")
        self.assertEqual(code, 1)
        self.assertIn("error: cannot read %s" % self.file, err)

    def test_every_release_against_the_codenames_file(self):
        self.write_codenames(json.dumps({"1.0": "Cassian", "1.1": "Brasso", "1.2": "brasso"}))
        self.write(SAMPLE.replace('## 1.0 "Cassian", build 259', '## 1.0 "Luthen", build 259'))
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(
            err.splitlines(),
            [
                '%s:19: 1.0 is named "Cassian" in %s, not "Luthen"' % (self.file, self.codenames),
                "%s:27: 0.9 has no codename in %s: each X.Y gets its own there before its first build"
                % (self.file, self.codenames),
                '%s: "1.2": "brasso" names 1.1 already (as "Brasso"): each X.Y has its own codename' % self.codenames,
                "%s: 2 problems" % self.file,
                "%s: 1 problem" % self.codenames,
            ],
        )

    def test_a_codenames_file_that_fails_alone(self):
        self.write_codenames(json.dumps({**CODENAME_OF, "1.1": "Ferrix"}))
        self.assertEqual(
            self.run_main("check"),
            (
                1,
                "",
                '%s: "1.1": "Ferrix" names 0.9 already: each X.Y has its own codename\n%s: 1 problem\n'
                % (self.codenames, self.codenames),
            ),
        )

    def test_a_codenames_file_that_cannot_be_read(self):
        self.write_codenames('{"1.0": "Cassian",}')
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: %s is not JSON: " % self.codenames, err)
        os.unlink(self.codenames)
        code, out, err = self.run_main("check")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: cannot read %s" % self.codenames, err)


class HtmlTest(CliCase):
    SMALL = text_of(
        "# Changelog",
        "",
        "Intro.",
        "",
        "## Unreleased",
        "",
        "### Fixed",
        "- A fix with `code` (#2).",
        "",
        '## 1.0 "Cassian", build 349 (2026-10-25)',
        "",
        "### Added",
        "- **New** things; see [the manual](https://example.com/m) (#1).",
        "### Known limits",
        "- One limit.",
    )

    def test_fragment(self):
        self.write(self.SMALL)
        self.assertEqual(
            self.html(),
            '<h2 id="changelog">Changelog</h2>\n'
            "<p>%s</p>\n"
            "<h3>Unreleased</h3>\n"
            "<p><b>Fixed</b></p>\n"
            "<ul>\n"
            "<li>A fix with <code>code</code> (#2).</li>\n"
            "</ul>\n"
            "<h3>1.0 &quot;Cassian&quot;, build 349 (2026-10-25)</h3>\n"
            "<p><b>Added</b></p>\n"
            "<ul>\n"
            "<li><b>New</b> things; see the manual (#1).</li>\n"
            "</ul>\n"
            "<p><b>Known limits</b></p>\n"
            "<ul>\n"
            "<li>One limit.</li>\n"
            "</ul>\n" % changelog.INTRO,
        )

    def test_escaping_of_lt_amp_and_quotes_in_bullets(self):
        self.write(SAMPLE.replace("- The first build.", "- Levels <5 & >2 stay \"as typed\" and 'quoted' (#7)."))
        self.assertIn(
            "<li>Levels &lt;5 &amp; &gt;2 stay &quot;as typed&quot; and &#39;quoted&#39; (#7).</li>", self.html()
        )

    def test_inline_markup(self):
        self.write(
            SAMPLE.replace(
                "- The first build.",
                "- `<!-- CHANGELOG -->` and `a & b`, **bold `code`**, [the text](https://example.com/x) "
                "and \\*escaped\\* stay; #123 is text; café … ▸.",
            )
        )
        self.assertIn(
            "<li><code>&lt;!-- CHANGELOG --&gt;</code> and <code>a &amp; b</code>, <b>bold <code>code</code></b>, "
            "the text and *escaped* stay; #123 is text; caf&#233; &#8230; &#9656;.</li>",
            self.html(),
        )

    def test_unreleased_as_it_stands(self):
        out = self.html()
        self.assertIn("<h3>Unreleased</h3>\n<p><b>Fixed</b></p>", out)
        self.assertLess(out.index("<h3>Unreleased</h3>"), out.index("build 349"))

    def test_unreleased_as_a_development_build(self):
        out = self.html("--dev-build", "412")
        self.assertIn("<h3>Unreleased (development build 412)</h3>\n<p><b>Fixed</b></p>", out)
        self.assertEqual(out.count("<h3>"), 4)

    def test_unreleased_as_the_release(self):
        out = self.html(*HTML_RELEASE)
        self.assertIn("<h3>1.0 &quot;Cassian&quot;, build 360 (2026-11-02)</h3>\n<p><b>Fixed</b></p>", out)
        self.assertNotIn("Unreleased", out)
        self.assertEqual(out.count("<h3>"), 4)

    def test_unreleased_as_a_prerelease(self):
        out = self.html(*HTML_PRERELEASE)
        self.assertIn(PRERELEASE_H3 + "\n<p><b>Fixed</b></p>", out)
        self.assertNotIn("Unreleased", out)
        self.assertNotRegex(out, r"<h3>1\.1 &quot;Brasso&quot;")  # never as the release 1.1
        self.assertEqual(out.count("<h3>"), 4)
        self.assertLess(out.index(PRERELEASE_H3), out.index("build 349"))
        # Every beta of 1.1 takes the codename the codenames file gives 1.1, not 1.0's.
        beta_4 = "<h3>1.1 beta 4 &quot;Brasso&quot; (prerelease), build 400 (2026-11-03)</h3>"
        for extra in ((), ("--codename", "Brasso")):
            with self.subTest(extra=extra):
                out = self.html("--release", "1.1-beta.4", "--build", "400", "--date", "2026-11-03", *extra)
                self.assertIn(beta_4 + "\n<p><b>Fixed</b></p>", out)
                self.assertNotIn("beta 4 &quot;Cassian&quot;", out)
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Mon Mothma"}))
        out = self.html("--release", "2.0-beta.3", "--build", "360", "--date", "2026-11-02")
        self.assertIn("<h3>2.0 beta 3 &quot;Mon Mothma&quot; (prerelease), build 360 (2026-11-02)</h3>", out)

    def test_prerelease_refusals(self):
        for argv, fragment in (
            (
                ("--release", "1.0-beta.1", "--build", "360", "--date", "2026-11-02"),
                "1.0-beta.1 is a prerelease of 1.0, but CHANGELOG.md lists 1.0 already (line 12): a prerelease comes "
                "before its version's release, so name a later version, such as 1.1-beta.1",
            ),
            (("--release", "0.9-beta.2", "--build", "360", "--date", "2026-11-02"), "lists 1.0 already (line 12)"),
            (("--release", "1.1-beta.1", "--build", "349", "--date", "2026-11-02"), "build 349 has an entry already"),
            (
                ("--release", "1.1-beta.1", "--build", "300", "--date", "2026-11-02"),
                "build 300 is older than build 349",
            ),
            (("--release", "1.1-beta.1", "--build", "360", "--date", "2026-10-01"), "2026-10-01 is before 2026-10-25"),
            (
                ("--release", "2.0-beta.1", "--build", "360", "--date", "2026-11-02"),
                "2.0 has no codename in %s: each X.Y gets its own there before its first build" % self.codenames,
            ),
            (HTML_PRERELEASE + ("--codename", "Luthen"), '1.1 is named "Brasso" in %s, not "Luthen"' % self.codenames),
            (
                HTML_PRERELEASE + ("--codename", "Cassian"),
                '1.1 is named "Brasso" in %s, not "Cassian"' % self.codenames,
            ),
        ):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)

    def test_empty_unreleased_never_shows(self):
        self.write(EMPTY_UNRELEASED)
        for argv in ((), ("--dev-build", "412"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                out = self.html(*argv)
                self.assertNotIn("Unreleased", out)
                self.assertNotIn("build 360", out)
                self.assertEqual(out.count("<h3>"), 3)
        self.write(text_of("# Changelog", "## Unreleased"))
        self.assertIn("<p>No release yet.</p>", self.html())

    def test_release_codename_comes_from_the_codenames_file(self):
        out = self.html("--release", "1.1", "--build", "360", "--date", "2026-11-02")
        self.assertIn("<h3>1.1 &quot;Brasso&quot;, build 360 (2026-11-02)</h3>", out)
        self.assertIn(
            "<h3>1.0 &quot;Cassian&quot;, build 360 (2026-11-02)</h3>",
            self.html(*HTML_RELEASE, "--codename", "Cassian"),
        )
        # A version the file does not name is refused, --codename or not: the file is the one source.
        missing = "2.0 has no codename in %s: each X.Y gets its own there before its first build" % self.codenames
        for extra in ((), ("--codename", "Mon Mothma")):
            with self.subTest(extra=extra):
                code, out, err = self.run_main(
                    "html", "--release", "2.0", "--build", "360", "--date", "2026-11-02", *extra
                )
                self.assertEqual((code, out, err), (1, "", "error: %s\n" % missing))
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Mon Mothma"}))
        out = self.html("--release", "2.0", "--build", "360", "--date", "2026-11-02")
        self.assertIn("<h3>2.0 &quot;Mon Mothma&quot;, build 360 (2026-11-02)</h3>", out)

    def test_the_default_codenames_file_is_the_repository_one(self):
        self.write(SAMPLE[: SAMPLE.index('## 0.9 "Ferrix"')])
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = changelog.main(
                ["html", "--file", self.file, "--release", "1.1-beta.4", "--build", "400", "--date", "2026-11-03"]
            )
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn("<h3>1.1 beta 4 &quot;Brasso&quot; (prerelease), build 400 (2026-11-03)</h3>", out.getvalue())

    def test_release_refusals(self):
        for argv, fragment in (
            (
                ("--release", "1.0", "--build", "349", "--date", "2026-11-02"),
                "build 349 has an entry already, on line 12",
            ),
            (("--release", "1.0", "--build", "300", "--date", "2026-11-02"), "build 300 is older than build 349"),
            (("--release", "1.0", "--build", "360", "--date", "2026-10-01"), "2026-10-01 is before 2026-10-25"),
            (HTML_RELEASE + ("--codename", "Luthen"), '1.0 is named "Cassian" in %s, not "Luthen"' % self.codenames),
            (HTML_RELEASE + ("--codename", "Brasso"), '1.0 is named "Cassian" in %s, not "Brasso"' % self.codenames),
        ):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)

    def test_composer_safe(self):
        self.write(SAMPLE.replace("- The first build.", "- `<script>alert(1)</script>` and `<img src=x>` stay text."))
        for argv in ((), ("--dev-build", "412"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                out = self.html(*argv)
                collector = TagCollector()
                collector.feed(out)
                collector.close()
                self.assertEqual(collector.other, [])
                self.assertTrue(collector.tags)
                for tag, attrs in collector.tags:
                    self.assertIn(tag, {"h2", "h3", "p", "b", "ul", "li", "code"})
                    self.assertEqual(attrs, [("id", "changelog")] if tag == "h2" else [])
                self.assertEqual([tag for tag, _ in collector.tags].count("h2"), 1)
                self.assertTrue(out.isascii())
                self.assertNotIn("example.com", out)
                self.assertNotIn("<script", out)
                self.assertIn("&lt;script&gt;", out)

    def test_refuses_a_file_that_fails_check(self):
        self.write(SAMPLE.replace("### Changed", "### Removed"))
        code, out, err = self.run_main("html")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("%s:21: unknown category 'Removed'" % self.file, err)
        self.assertIn("error: %s fails check: nothing done" % self.file, err)

    def test_refuses_a_codenames_file_that_fails_check(self):
        self.write_codenames(json.dumps({**CODENAME_OF, "1.2": "Brasso"}))
        for argv in ((), ("--dev-build", "412"), HTML_RELEASE, HTML_PRERELEASE):
            with self.subTest(argv=argv):
                code, out, err = self.run_main("html", *argv)
                self.assertEqual((code, out), (1, ""))
                self.assertEqual(
                    err.splitlines(),
                    [
                        '%s: "1.2": "Brasso" names 1.1 already: each X.Y has its own codename' % self.codenames,
                        "error: %s fails check: nothing done" % self.codenames,
                    ],
                )
        self.write(SAMPLE.replace('"Cassian", build 259', '"Luthen", build 259'))
        code, out, err = self.run_main("html")
        self.assertEqual((code, out), (1, ""))
        self.assertIn('%s:19: 1.0 is named "Cassian" in %s, not "Luthen"' % (self.file, self.codenames), err)
        self.assertIn("error: %s and %s fail check: nothing done" % (self.file, self.codenames), err)

    def test_usage_errors(self):
        for argv in (
            ("--release", "1.0"),
            ("--build", "360", "--date", "2026-11-02"),
            HTML_RELEASE + ("--dev-build", "361"),
            ("--codename", "Cassian"),
            ("--dev-build", "0"),
            ("--release", "1.0.1", "--build", "360", "--date", "2026-11-02"),
            ("--release", "1.1-beta.0", "--build", "360", "--date", "2026-11-02"),
            ("--release", "1.1-rc.1", "--build", "360", "--date", "2026-11-02"),
            ("--release", "v1.1-beta.1", "--build", "360", "--date", "2026-11-02"),
            HTML_PRERELEASE + ("--codename", "Brasso!"),
        ):
            with self.subTest(argv=argv):
                self.assertEqual(self.usage_error("html", *argv)[0], 2)


class NotesTest(CliCase):
    def test_notes_from_the_template(self):
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out,
            '## 1.0 "Cassian" (build 360)\n'
            "\n"
            'Released 2026-11-02. Braces that name no placeholder stay: {"key": 1}, ${{ github.sha }}, {Version}.\n'
            "\n"
            "### New in build 360\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- The scene slider no longer jumps back after a recall (#301).\n"
            "- Keypad LEDs follow a scene recalled in the Hue app,\n"
            "  also after a bridge restart (#302).\n"
            "\n"
            "### Earlier builds of 1.0\n"
            "\n"
            '### 1.0 "Cassian", build 349 (2026-10-25)\n'
            "\n"
            "**Added**\n"
            "\n"
            "- Scenes show `Last Recalled` in Composer (#240).\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- **Pairing** survives a bridge restart; see [the manual](https://example.com/manual#pairing) (#236).\n"
            "\n"
            '### 1.0 "Cassian", build 259 (2026-10-24)\n'
            "\n"
            "**Changed**\n"
            "\n"
            "- Lights import into the room their Hue room maps to.\n"
            "\n"
            "**Known limits**\n"
            "\n"
            "- No motion sensors yet.\n"
            "\n"
            "Every release: CHANGELOG.md.\n",
        )

    def test_refuses_an_empty_unreleased_entry(self):
        self.write(EMPTY_UNRELEASED)
        code, out, err = self.notes(*RELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: a release must say what it changes", err)

    def test_first_build_of_a_new_version(self):
        code, out, err = self.notes("--version", "1.1", "--build", "360", "--date", "2026-11-02")
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.1 "Brasso" (build 360)\n'), out)
        self.assertIn("### Earlier builds of 1.1\n\nNone: build 360 is the first build of 1.1.\n", out)
        argv = ("--version", "2.0", "--build", "360", "--date", "2026-11-02")
        for extra in ((), ("--codename", "Mon Mothma")):
            with self.subTest(extra=extra):
                code, out, err = self.notes(*argv, *extra)
                self.assertEqual((code, out), (1, ""))
                self.assertIn("error: 2.0 has no codename in %s" % self.codenames, err)
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Mon Mothma"}))
        code, out, err = self.notes(*argv)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 2.0 "Mon Mothma" (build 360)\n'), out)

    def test_codename_option_must_agree_with_the_codenames_file(self):
        for argv, version, name in (
            (RELEASE, "1.0", "Brasso"),
            (RELEASE, "1.0", "Luthen"),
            (PRERELEASE, "1.1", "Cassian"),
            (PRERELEASE, "1.1", "Luthen"),
        ):
            with self.subTest(argv=argv, name=name):
                code, out, err = self.notes(*argv, "--codename", name)
                self.assertEqual((code, out), (1, ""))
                named = CODENAME_OF[version]
                self.assertIn('error: %s is named "%s" in %s, not "%s"' % (version, named, self.codenames, name), err)

    def test_values_are_not_filled_in_again(self):
        self.write(SAMPLE.replace("after a recall (#301).", "after a recall; the notes name `{build}` (#301)."))
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn("the notes name `{build}` (#301).", out)

    def test_template_refusals(self):
        for template, fragment in (
            (TEMPLATE + "{tag}\n", "names {tag}; the placeholders are {version}, {codename}"),
            (TEMPLATE.replace("{this_build}", "nothing"), "has no {this_build}"),
        ):
            with self.subTest(fragment=fragment):
                with open(self.template, "w", encoding="utf-8") as handle:
                    handle.write(template)
                code, out, err = self.notes(*RELEASE)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(fragment, err)
        os.unlink(self.template)
        code, out, err = self.notes(*RELEASE)
        self.assertEqual(code, 1)
        self.assertIn("cannot read", err)

    def test_prerelease_notes_from_the_template(self):
        with open(self.template, "w", encoding="utf-8") as handle:
            handle.write(PRERELEASE_TEMPLATE)
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertEqual(
            out,
            '## 1.1 beta 1 "Brasso" (build 360)\n'
            "\n"
            'Version 1.1-beta.1, built 2026-11-02, follows [1.0 "Cassian", build 349 (2026-10-25)]'
            "(https://example.com/v1.0).\n"
            "\n"
            "**Fixed**\n"
            "\n"
            "- The scene slider no longer jumps back after a recall (#301).\n"
            "- Keypad LEDs follow a scene recalled in the Hue app,\n"
            "  also after a bridge restart (#302).\n",
        )

    def test_each_kind_has_its_default_template(self):
        prerelease_template = os.path.join(self.tmp.name, "prerelease-notes.md")
        with open(prerelease_template, "w", encoding="utf-8") as handle:
            handle.write(PRERELEASE_TEMPLATE)
        for name, path in (("TEMPLATE_FILE", self.template), ("PRERELEASE_TEMPLATE_FILE", prerelease_template)):
            self.addCleanup(setattr, changelog, name, getattr(changelog, name))
            setattr(changelog, name, path)
        code, out, err = self.run_main("notes", *PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.1 beta 1 "Brasso" (build 360)\n'), out)
        code, out, err = self.run_main("notes", *RELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.0 "Cassian" (build 360)\n'), out)

    def test_prerelease_refusals(self):
        with open(self.template, "w", encoding="utf-8") as handle:
            handle.write(PRERELEASE_TEMPLATE + "{history}\n")
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn(
            "names {history}; the placeholders are {version}, {release}, {beta}, {codename}, {build}, {date}, "
            "{this_build}, {stable}, {stable_version}",
            err,
        )
        with open(self.template, "w", encoding="utf-8") as handle:
            handle.write(PRERELEASE_TEMPLATE)
        code, out, err = self.notes("--version", "1.0-beta.2", "--build", "360", "--date", "2026-11-02")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("CHANGELOG.md lists 1.0 already (line 12)", err)
        code, out, err = self.notes("--version", "2.0-beta.1", "--build", "360", "--date", "2026-11-02")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("error: 2.0 has no codename in %s" % self.codenames, err)
        self.write(EMPTY_UNRELEASED)
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: a prerelease must say what it changes", err)
        self.write(text_of("# Changelog", "## Unreleased", "### Added", "- The first thing."))
        code, out, err = self.notes(*PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn(
            "1.1-beta.1: a prerelease's notes name the release it follows, and %s lists none" % self.file, err
        )

    def test_the_repository_prerelease_template_fills(self):
        code, out, err = self.run_main("notes", "--template", changelog.PRERELEASE_TEMPLATE_FILE, *PRERELEASE)
        self.assertEqual(code, 0, err)
        self.assertTrue(out.startswith('## 1.1 beta 1 "Brasso" (build 360)\n'), out[:80])
        self.assertIsNone(changelog.PLACEHOLDER_RE.search(out), "every placeholder is filled")
        self.assertIn(
            "Codename **Brasso**: each X.Y release of this project has its own codename from Star Wars: Andor "
            "(a widely recognised name for an X.0, a lesser character, place or object for a point release), and "
            "every build of 1.1, prereleases included, keeps it.",
            out,
        )
        self.assertIn(
            "- Keypad LEDs follow a scene recalled in the Hue app,\n  also after a bridge restart (#302).", out
        )
        self.assertIn(
            '[1.0 "Cassian", build 349 (2026-10-25)](https://github.com/corytron/c4-hue-driver/releases/tag/v1.0)', out
        )
        self.assertNotIn("build 259", out)  # no history: prereleases are not in CHANGELOG.md
        # docs/prerelease-design.md, section 3, in this order: a prerelease for testing, the release it
        # follows, install, going back, how to report, verify a download, the license.
        marks = [
            "**A prerelease for testing**",
            "It follows the stable release",
            'Driver ▸ "Add or Update Driver or Agent…"',
            "[latest stable release](https://github.com/corytron/c4-hue-driver/releases/latest)",
            "issues/new?template=beta-feedback.yml",
            "sha256sum -c SHA256SUMS.txt",
            "Apache License 2.0",
        ]
        self.assertEqual([out.find(mark) for mark in marks], sorted(out.find(mark) for mark in marks))
        self.assertNotIn(-1, [out.find(mark) for mark in marks])

    def test_every_beta_of_1_1_is_brasso(self):
        for beta in (1, 4, 12):
            with self.subTest(beta=beta):
                code, out, err = self.run_main(
                    "notes",
                    "--template",
                    changelog.PRERELEASE_TEMPLATE_FILE,
                    *("--version", "1.1-beta.%d" % beta, "--build", "400", "--date", "2026-11-03"),
                )
                self.assertEqual(code, 0, err)
                self.assertTrue(out.startswith('## 1.1 beta %d "Brasso" (build 400)\n' % beta), out[:80])
                self.assertIn("Codename **Brasso**", out)

    def test_the_repository_templates_count_no_packages(self):
        for path in (changelog.TEMPLATE_FILE, changelog.PRERELEASE_TEMPLATE_FILE):
            with self.subTest(path=path):
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
                self.assertIn("every `.c4z` file of", text)
                self.assertIsNone(re.search(r"\bthree\b|hue_[a-z]+\.c4z", text, re.IGNORECASE))

    def test_the_repository_template_fills(self):
        code, out, err = self.run_main("notes", "--template", changelog.TEMPLATE_FILE, *RELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn(
            "- Keypad LEDs follow a scene recalled in the Hue app,\n  also after a bridge restart (#302).", out
        )
        self.assertIn('### 1.0 "Cassian", build 259 (2026-10-24)', out)
        self.assertNotIn("Ferrix", out)
        self.assertIsNone(changelog.PLACEHOLDER_RE.search(out), "every placeholder is filled")
        self.assertIn(
            "Codename: **Cassian**. Each X.Y release of this project has its own codename from Star Wars: Andor "
            "(a widely recognised name for an X.0, a lesser character, place or object for a point release); "
            "every build of 1.0 keeps it.",
            out,
        )


class StampTest(CliCase):
    def test_round_trip(self):
        code, out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual(code, 0, err)
        self.assertIn("'## Unreleased' is now '%s', below a new empty '## Unreleased'" % NEW_HEADING, out)
        stamped = self.read()
        self.assertEqual(stamped, SAMPLE.replace("## Unreleased\n", "## Unreleased\n\n%s\n" % NEW_HEADING, 1))
        self.assertEqual(self.run_main("check"), (0, "%s: ok (4 releases)\n" % self.file, ""))
        parsed = changelog.parse(stamped)
        self.assertEqual(parsed.unreleased.sections, [])
        self.assertEqual((parsed.releases[0].line, parsed.releases[0].build), (7, 360))
        out = self.html()
        self.assertNotIn("Unreleased", out)
        self.assertIn("<h3>1.0 &quot;Cassian&quot;, build 360 (2026-11-02)</h3>\n<p><b>Fixed</b></p>", out)
        # The release's notes and Documentation tab, rendered before the stamp, describe the same entry.
        self.write(SAMPLE)
        self.assertIn("<h3>1.0 &quot;Cassian&quot;, build 360 (2026-11-02)</h3>", self.html(*HTML_RELEASE))

    def test_refuses_an_empty_unreleased_entry(self):
        self.assertEqual(self.run_main("stamp", *RELEASE)[0], 0)
        stamped = self.read()
        code, out, err = self.run_main("stamp", "--version", "1.0", "--build", "361", "--date", "2026-11-02")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("'## Unreleased' (line 5) has no bullets: nothing to stamp", err)
        self.assertEqual(self.read(), stamped)

    def test_refuses_a_prerelease(self):
        code, out, err = self.run_main("stamp", *PRERELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn(
            "1.1-beta.1 is a prerelease: CHANGELOG.md lists releases only, and the 1.1 entry will carry these "
            "changes (docs/prerelease-design.md); nothing stamped",
            err,
        )
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_a_build_that_has_an_entry(self):
        code, out, err = self.run_main("stamp", "--version", "1.0", "--build", "349", "--date", "2026-11-02")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("build 349 has an entry already, on line 12", err)
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_an_older_build_or_date(self):
        for argv, fragment in (
            (("--version", "1.0", "--build", "300", "--date", "2026-11-02"), "build 300 is older than build 349"),
            (("--version", "1.0", "--build", "360", "--date", "2026-10-24"), "2026-10-24 is before 2026-10-25"),
        ):
            with self.subTest(argv=argv):
                code, _out, err = self.run_main("stamp", *argv)
                self.assertEqual(code, 1)
                self.assertIn(fragment, err)
                self.assertEqual(self.read(), SAMPLE)

    def test_codename_of_a_new_version(self):
        argv = ("--version", "2.0", "--build", "360", "--date", "2026-11-02")
        for extra in ((), ("--codename", "Mon Mothma")):
            with self.subTest(extra=extra):
                code, _out, err = self.run_main("stamp", *argv, *extra)
                self.assertEqual(code, 1)
                self.assertIn(
                    "2.0 has no codename in %s: each X.Y gets its own there before its first build" % self.codenames,
                    err,
                )
                self.assertEqual(self.read(), SAMPLE)
        # 1.1 takes the name the codenames file gives it, not 1.0's.
        code, _out, err = self.run_main("stamp", "--version", "1.1", "--build", "360", "--date", "2026-11-02")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 1.1 "Brasso", build 360 (2026-11-02)\n', self.read())
        self.assertEqual(self.run_main("check")[0], 0)
        # Every build of 1.1 keeps it: another name is refused.
        self.write(self.read().replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n- Another fix.\n", 1))
        unstamped = self.read()
        later = ("--version", "1.1", "--build", "370", "--date", "2026-11-03")
        for name in ("Luthen", "Cassian"):
            with self.subTest(name=name):
                code, _out, err = self.run_main("stamp", *later, "--codename", name)
                self.assertEqual(code, 1)
                self.assertIn('1.1 is named "Brasso" in %s, not "%s"' % (self.codenames, name), err)
                self.assertEqual(self.read(), unstamped)
        code, _out, err = self.run_main("stamp", *later, "--codename", "Brasso")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 1.1 "Brasso", build 370 (2026-11-03)\n', self.read())
        # 2.0 once the file names it, with a space in the name.
        self.write(self.read().replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n- A third fix.\n", 1))
        self.write_codenames(json.dumps({**CODENAME_OF, "2.0": "Mon Mothma"}))
        code, _out, err = self.run_main("stamp", "--version", "2.0", "--build", "380", "--date", "2026-11-04")
        self.assertEqual(code, 0, err)
        self.assertIn('\n## 2.0 "Mon Mothma", build 380 (2026-11-04)\n', self.read())
        self.assertEqual(self.run_main("check"), (0, "%s: ok (6 releases)\n" % self.file, ""))

    def test_keeps_crlf_line_endings(self):
        self.write(SAMPLE.replace("\n", "\r\n"))
        self.assertEqual(self.run_main("stamp", *RELEASE)[0], 0)
        expected = SAMPLE.replace("## Unreleased\n", "## Unreleased\n\n%s\n" % NEW_HEADING, 1)
        self.assertEqual(self.read(), expected.replace("\n", "\r\n"))

    def test_writes_only_a_result_that_passes_check(self):
        saved = changelog.release_title
        changelog.release_title = lambda *args: ("Cassian", "1.0 Cassian build 360")
        self.addCleanup(setattr, changelog, "release_title", saved)
        code, out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("a release heading reads", err)
        self.assertIn("stamped, the file would fail check", err)
        self.assertEqual(self.read(), SAMPLE)

    def test_refuses_a_file_that_fails_check(self):
        broken = SAMPLE.replace("### Changed", "### Removed")
        self.write(broken)
        code, _out, err = self.run_main("stamp", *RELEASE)
        self.assertEqual(code, 1)
        self.assertIn("fails check: nothing done", err)
        self.assertEqual(self.read(), broken)

    def test_refuses_a_codenames_file_that_fails_check(self):
        for text in (json.dumps({**CODENAME_OF, "1.2": "ferrix"}), "[]"):
            with self.subTest(text=text):
                self.write_codenames(text)
                code, _out, err = self.run_main("stamp", *RELEASE)
                self.assertEqual(code, 1)
                self.assertIn("error: %s " % self.codenames, err)
                self.assertEqual(self.read(), SAMPLE)


class VersionTest(unittest.TestCase):
    """docs/prerelease-design.md, section 1: MAJOR.MINOR, or MAJOR.MINOR-beta.N for a prerelease, whole."""

    def test_accepted(self):
        for text, version in (
            ("1.0", changelog.Version(1, 0)),
            ("0.9", changelog.Version(0, 9)),
            ("12.34", changelog.Version(12, 34)),
            ("1.1-beta.1", changelog.Version(1, 1, 1)),
            ("1.1-beta.10", changelog.Version(1, 1, 10)),
            ("2.0-beta.123", changelog.Version(2, 0, 123)),
        ):
            with self.subTest(text=text):
                self.assertEqual(changelog.version_arg(text), version)
                self.assertEqual(str(version), text)
                self.assertEqual(version.release, (version.major, version.minor))

    def test_refused(self):
        for text in (
            "1",
            "1.0.1",
            "v1.0",
            "1.1-beta",
            "1.1-beta.",
            "1.1-beta.0",
            "1.1-beta.01",
            "1.1-Beta.1",
            "1.1-rc.1",
            "1.1-alpha.1",
            "1.1-beta.1.1",
            "1.1beta1",
            "1.1-beta-1",
            "1.0+5",
            " 1.0",
            "1.0 ",
            "1.0\n",
            "1.1-beta.1\n",
            "",
            "\u0661.\u0660",
        ):
            with self.subTest(text=text):
                with self.assertRaises(argparse.ArgumentTypeError):
                    changelog.version_arg(text)


class CommandLineTest(CliCase):
    def test_help_of_the_tool_and_of_every_subcommand(self):
        env = dict(os.environ, NO_COLOR="1")
        env.pop("FORCE_COLOR", None)
        for argv in ([], ["check"], ["html"], ["notes"], ["stamp"]):
            with self.subTest(argv=argv):
                done = subprocess.run(
                    [sys.executable, "-I", SCRIPT, *argv, "--help"],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                )
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn("changelog.py", done.stdout)
                self.assertIn("--file" if argv else "Exit codes: 0 done, 1 refused or invalid, 2 usage.", done.stdout)
                if argv:
                    self.assertIn("--codenames", done.stdout)

    def test_usage_errors_exit_2_and_change_nothing(self):
        for command, *argv in (
            ("bogus",),
            ("notes", "--build", "360", "--date", "2026-11-02"),
            ("notes", "--version", "1", "--build", "360", "--date", "2026-11-02"),
            ("stamp", "--version", "1.0", "--build", "x", "--date", "2026-11-02"),
            ("stamp", "--version", "1.0", "--build", "0", "--date", "2026-11-02"),
            ("stamp", "--version", "1.0", "--build", "360", "--date", "2026-13-01"),
            ("stamp", "--version", "1.0", "--build", "360", "--date", "2026-11-2"),
            ("stamp", "--version", "1.1-beta.0", "--build", "360", "--date", "2026-11-02"),
            ("notes", "--version", "1.1-rc.1", "--build", "360", "--date", "2026-11-02"),
            ("notes", "--version", "1.1-beta", "--build", "360", "--date", "2026-11-02"),
            ("stamp", *RELEASE, "--codename", 'Say "hi"'),
            ("stamp", *RELEASE, "--codename", " Luthen"),
            ("stamp", *RELEASE, "--codename", ""),
            ("stamp", *RELEASE, "--codename", "Cassian!"),
            ("notes", *PRERELEASE, "--codename", "Bras  so"),
            ("notes", *PRERELEASE, "--codename", "-Brasso"),
        ):
            with self.subTest(argv=[command, *argv]):
                code, err = self.usage_error(command, *argv)
                self.assertEqual(code, 2)
                self.assertIn("usage:", err)
                self.assertEqual(self.read(), SAMPLE)


if __name__ == "__main__":
    unittest.main()
