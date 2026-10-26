#!/usr/bin/env python3
"""Check CHANGELOG.md and render it for the Documentation tabs, the release notes and a release.

  changelog.py check  [--file CHANGELOG.md]
  changelog.py html   [--file F] [--release VERSION --build N --date YYYY-MM-DD] [--dev-build N]
                      [--codename NAME]
  changelog.py notes  [--file F] --version VERSION --build N --date YYYY-MM-DD [--codename NAME]
                      [--template .github/release-notes.md]
  changelog.py stamp  [--file F] --version VERSION --build N --date YYYY-MM-DD [--codename NAME]

The contract is docs/changelog-design.md (issue #255). CHANGELOG.md lists every release, newest
first, below a "## Unreleased" entry that collects the changes of the next one (section 1).

VERSION is MAJOR.MINOR for a release (1.0) or MAJOR.MINOR-beta.N for a prerelease (1.1-beta.1;
docs/prerelease-design.md, issue #269). A prerelease is never an entry of CHANGELOG.md: html shows
the Unreleased entry as '1.1 beta 1 "Cassian" (prerelease), build N (date)', never as the release;
notes fills .github/prerelease-notes.md; stamp refuses it. A prerelease of a version the file lists
already is refused: it comes before its release.

check   validates section 1 and prints "CHANGELOG.md: ok (N releases)", or every problem as
        FILE:LINE: message on stderr.
html    prints the fragment tools/build.sh puts in place of the <!-- CHANGELOG --> line of each
        driver's documentation.html: plain h2, h3, p, b, ul, li and code, no attribute but the h2's
        id, no script, no link, no external resource, ASCII only. A non-empty Unreleased entry
        shows as the release (or prerelease) with --release, as "Unreleased (development build N)"
        with --dev-build, else as "Unreleased"; an empty one never shows.
notes   prints the release's notes: the template with {version}, {codename}, {build}, {date},
        {this_build} (the Unreleased entry's categories and bullets) and {history} (the earlier
        builds of the version) filled in. Refuses an empty Unreleased entry. For a prerelease the
        template is .github/prerelease-notes.md, with {version} (1.1-beta.1), {release} (1.1),
        {beta} (1), {codename}, {build}, {date}, {this_build}, {stable} (the heading of the newest
        release in the file, the one the prerelease follows) and {stable_version} (its version), and
        no {history}.
stamp   turns "## Unreleased" into the release's heading below a new, empty "## Unreleased" and
        writes the file only when the result passes check. Refuses an empty Unreleased entry, a
        build that has an entry already and a prerelease.

A release's codename is the one of the newest entry of its major version; the first release of a
new major version names it with --codename. html, notes and stamp refuse a file that fails check,
and a release whose build or date would not make it the newest entry.

Standard library only. Exit codes: 0 done, 1 refused or invalid, 2 usage.
"""

import argparse
import dataclasses
import datetime
import os
import re
import sys

EXIT_OK, EXIT_REFUSED = 0, 1  # argparse exits 2 on a usage error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG_FILE = os.path.join(ROOT, "CHANGELOG.md")
TEMPLATE_FILE = os.path.join(ROOT, ".github", "release-notes.md")
PRERELEASE_TEMPLATE_FILE = os.path.join(ROOT, ".github", "prerelease-notes.md")

TITLE = "# Changelog"
UNRELEASED = "## Unreleased"
CATEGORIES = ("Added", "Changed", "Fixed", "Security", "Known limits")
# The contract's pattern; re.ASCII keeps \d to 0-9.
RELEASE_RE = re.compile(r'^## (\d+)\.(\d+) "([^"]+)", build (\d+) \((\d{4}-\d{2}-\d{2})\)$', re.ASCII)
RELEASE_SHAPE = '## 1.0 "Cassian", build 349 (2026-10-25)'
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
PLACEHOLDERS = ("version", "codename", "build", "date", "this_build", "history")
# A prerelease's notes have no {history}: prereleases are not entries of CHANGELOG.md.
PRERELEASE_PLACEHOLDERS = (
    "version",
    "release",
    "beta",
    "codename",
    "build",
    "date",
    "this_build",
    "stable",
    "stable_version",
)
PLACEHOLDER_RE = re.compile(r"\{([a-z_]+)\}")
# A release 1.0 or a prerelease 1.1-beta.1 (docs/prerelease-design.md, section 1), matched whole.
VERSION_RE = re.compile(r"([0-9]+)\.([0-9]+)(?:-beta\.([1-9][0-9]*))?")

# The sentence under the Documentation tab's "Changelog" heading.
INTRO = (
    "Every release of the Hue Bridge, Hue Light and Hue Scene drivers, newest first; the build number is "
    "the Driver Version that Composer shows for each device."
)

CATEGORY_ORDER = "the categories are Added, Changed, Fixed, Security and Known limits, in that order, each once"
INTRO_HEADING = "no headings before '## Unreleased': the introduction is plain text"

# Blocks (section 1): under a ### heading only "- " bullets and their continuation lines, indented
# by two spaces; no nested lists, no tables, no HTML.
HEADING_RE = re.compile(r"^(#{1,6})(?:[ \t]|$)")
INDENTED_HEADING_RE = re.compile(r"^ {1,3}#{1,6}(?:[ \t]|$)")
BULLET_RE = re.compile(r"^- (\S.*)$")
LIST_ITEM_RE = re.compile(r"^([-*+]|[0-9]{1,9}[.)])(?:[ \t]+(.*))?$")
NESTED_BULLET_RE = re.compile(r"^[-*+][ \t]+\S")
NESTED_NUMBER_RE = re.compile(r"^([0-9]{1,9})[.)][ \t]+\S")
THEMATIC_BREAK_RE = re.compile(r"^([-*_])[ \t]*(?:\1[ \t]*){2,}$")
SETEXT_RE = re.compile(r"^(?:=+|-+)[ \t]*$")
TASK_BOX_RE = re.compile(r"^\[[ xX]\](?:[ \t]|$)")

# Inline markup (section 1): `code`, **bold**, [text](url) shown as its text, #123 as text.
ASCII_PUNCTUATION = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
LINK_RE = re.compile(r"(!?)\[((?:\\.|[^\[\]\\])*)\]\(([^()\s]*)\)")
SHOWN = "only **bold**, `code` and the text of [links](url) show in Composer"
# Applied to a paragraph with code spans, escaped characters, link targets and ** markers blanked
# out (see inline_problems): what is left that GitHub would render and the HTML would not.
INLINE_RULES = (
    (re.compile(r"<!--|</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"), "no HTML: put a tag in `backticks` to show it"),
    (re.compile(r"<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*>"), "a link is written [text](url)"),
    (
        re.compile(r"&(?:[A-Za-z][A-Za-z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});"),
        "no HTML entities: write the character itself",
    ),
    (re.compile(r"\]\(|\]\["), "a link is written [text](url), with no space in the url"),
    (re.compile(r"(?<![\w*])\*(?=[^\s*])(?:[^*]*?[^\s*])?\*(?![\w*])"), "no *italic*: " + SHOWN),
    (re.compile(r"(?<!\w)_(?=[^\s_])(?:[^_]*?[^\s_])?_(?!\w)"), "no _italic_: " + SHOWN),
    (re.compile(r"(?<!~)~~?(?=[^\s~])(?:[^~]*?[^\s~])?~~?(?!~)"), "no ~~strikethrough~~: " + SHOWN),
)


class ChangelogError(Exception):
    """A refusal: printed to stderr, exit 1."""


@dataclasses.dataclass(frozen=True)
class Version:
    """A version from the command line: MAJOR.MINOR for a release, with beta N for a prerelease."""

    major: int
    minor: int
    beta: int | None = None

    @property
    def release(self):
        """(major, minor): the version as CHANGELOG.md's headings name it."""
        return (self.major, self.minor)

    def __str__(self):
        text = "%d.%d" % self.release
        return text if self.beta is None else "%s-beta.%d" % (text, self.beta)


# ---------------------------------------------------------------------------
# The parsed file
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Paragraph:
    """One paragraph of a bullet: its lines joined by single spaces, and where each line starts."""

    text: str = ""
    starts: list = dataclasses.field(default_factory=list)  # (offset in text, line number) per line

    def add(self, content, number):
        if self.text:
            self.text += " "
        self.starts.append((len(self.text), number))
        self.text += content

    def line_at(self, offset):
        """The line number of the character at offset."""
        return [number for start, number in self.starts if start <= offset][-1]


@dataclasses.dataclass
class Bullet:
    """A "- " line and its continuation lines."""

    line: int
    paragraphs: list
    source: list  # its lines as written, with one blank line between two paragraphs


@dataclasses.dataclass
class Section:
    """A ### category heading and its bullets."""

    name: str
    line: int
    bullets: list = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class Entry:
    """A ## heading and its categories. kind is "unreleased", "release" or "invalid" (a heading that
    is neither). A release has its version (major, minor), codename, build and date; date is None
    when the heading names a day that does not exist."""

    kind: str
    heading: str  # the text after "## "
    line: int
    version: tuple | None = None
    codename: str | None = None
    build: int | None = None
    date: str | None = None
    sections: list = dataclasses.field(default_factory=list)

    def bullet_count(self):
        return sum(len(section.bullets) for section in self.sections)


@dataclasses.dataclass
class Changelog:
    entries: list
    problems: list  # (line number, message), in line order

    @property
    def unreleased(self):
        """The "## Unreleased" entry when it is the first entry, else None."""
        if self.entries and self.entries[0].kind == "unreleased":
            return self.entries[0]
        return None

    @property
    def releases(self):
        """The released entries in file order: newest first in a file that passes check."""
        return [entry for entry in self.entries if entry.kind == "release"]


# ---------------------------------------------------------------------------
# Parsing and checking (section 1)
# ---------------------------------------------------------------------------


def is_date(text):
    if not DATE_RE.match(text):
        return False
    try:
        datetime.date.fromisoformat(text)
    except ValueError:
        return False
    return True


def parse(text):
    """The text of a changelog as a Changelog: its entries, and every problem of section 1 of the
    contract with its line number. Line endings may be LF or CRLF."""
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    lines = [line[:-1] if line.endswith("\r") else line for line in lines]
    parser = Parser()
    if not lines or lines[0] != TITLE:
        parser.problem(1, "the first line must be %r, not %r" % (TITLE, lines[0] if lines else ""))
    for number, line in enumerate(lines, 1):
        if number > 1 or line != TITLE:
            parser.feed(number, line)
    parser.finish(len(lines))
    return Changelog(parser.entries, sorted(parser.problems, key=lambda problem: problem[0]))


class Parser:
    """One pass over the lines of the file, collecting entries and problems; parse() drives it."""

    def __init__(self):
        self.problems = []
        self.entries = []
        self.entry = self.section = self.bullet = None
        self.blank = False  # a blank line since the current bullet's last line

    def problem(self, number, message):
        self.problems.append((number, message))

    def feed(self, number, line):
        heading = HEADING_RE.match(line)
        if heading:
            self.bullet = None
            self.heading(number, line, len(heading.group(1)))
        elif self.entry is None:
            if INDENTED_HEADING_RE.match(line):
                self.problem(number, INTRO_HEADING)
        elif not line.strip():
            self.blank = True
        elif self.section is not None:
            self.section_line(number, line)
        elif LIST_ITEM_RE.match(line):
            self.problem(
                number,
                "a bullet outside a ### category: put it under ### Added, Changed, Fixed, Security or Known limits",
            )
        else:
            self.problem(number, "text outside a ### category: an entry holds ### headings and their bullets")

    def heading(self, number, line, level):
        if level == 2:
            self.entry_heading(number, line)
        elif self.entry is None:
            if number > 1:  # a wrong first line is reported once, as the title
                self.problem(number, INTRO_HEADING)
        elif level == 3:
            self.category(number, line)
        elif level == 1:
            self.problem(number, "only the title on the first line is a '#' heading")
        else:
            self.problem(number, "only ## and ### headings, not %r" % line)

    def entry_heading(self, number, line):
        release = RELEASE_RE.match(line)
        first = not self.entries
        if line == UNRELEASED:
            kind = "unreleased"
            if not first:
                self.problem(number, "'## Unreleased' only once, as the first ## heading")
        else:
            kind = "release" if release else "invalid"
            if first:
                self.problem(number, "the first ## heading must be '## Unreleased' (it may be empty), not %r" % line)
            elif not release:
                self.problem(number, "a release heading reads %r, not %r" % (RELEASE_SHAPE, line))
        entry = Entry(kind, line[2:].strip(), number)
        if release:
            entry.version = (int(release.group(1)), int(release.group(2)))
            entry.codename = release.group(3)
            entry.build = int(release.group(4))
            entry.date = release.group(5)
            if not is_date(entry.date):
                self.problem(number, "no such date: %s" % entry.date)
                entry.date = None
        self.entries.append(entry)
        self.entry, self.section = entry, None

    def category(self, number, line):
        name = line[4:] if line.startswith("### ") else line[3:]
        earlier = [section for section in self.entry.sections if section.name in CATEGORIES]
        self.section = Section(name, number)
        self.entry.sections.append(self.section)
        if name not in CATEGORIES:
            self.problem(number, "unknown category %r: %s" % (name, CATEGORY_ORDER))
            return
        repeated = [section for section in earlier if section.name == name]
        later = [section for section in earlier if CATEGORIES.index(section.name) > CATEGORIES.index(name)]
        if repeated:
            self.problem(number, "### %s a second time in this entry (first on line %d)" % (name, repeated[0].line))
        elif later:
            self.problem(number, "### %s after ### %s: %s" % (name, later[0].name, CATEGORY_ORDER))

    def section_line(self, number, line):
        bullet = BULLET_RE.match(line)
        item = LIST_ITEM_RE.match(line)
        if bullet:
            self.start_bullet(number, line, bullet.group(1), check=True)
        elif item and not THEMATIC_BREAK_RE.match(line):
            self.problem(number, list_item_problem(item))
            self.start_bullet(number, line, item.group(2) or "", check=False)
        elif line.startswith("  ") and line[2] not in " \t":
            self.continuation(number, line)
        else:
            self.problem(number, stray_line_problem(line))

    def start_bullet(self, number, line, text, check):
        paragraph = Paragraph()
        paragraph.add(text.rstrip(), number)
        self.bullet = Bullet(number, [paragraph], [line.rstrip()])
        self.section.bullets.append(self.bullet)
        self.blank = False
        if check:
            message = "no task-list boxes" if TASK_BOX_RE.match(text) else block_problem(text, continues=False)
            if message:
                self.problem(number, message)

    def continuation(self, number, line):
        if self.bullet is None:
            self.problem(number, "a continuation line (two spaces) with no bullet above it")
            return
        content = line[2:].rstrip()
        if self.blank:  # a blank line, then two spaces: the bullet's next paragraph
            self.bullet.paragraphs.append(Paragraph())
            self.bullet.source.append("")
        self.bullet.paragraphs[-1].add(content, number)
        self.bullet.source.append(line.rstrip())
        message = block_problem(content, continues=not self.blank)
        if message:
            self.problem(number, message)
        self.blank = False

    def finish(self, count):
        if not self.entries:
            self.problem(max(count, 1), "no '## Unreleased' heading: it is the first ## heading, empty or not")
        for entry in self.entries:
            for section in entry.sections:
                if not section.bullets:
                    self.problem(section.line, "### %s has no bullets" % section.name)
                for bullet in section.bullets:
                    for paragraph in bullet.paragraphs:
                        for offset, message in inline_problems(paragraph.text):
                            self.problem(paragraph.line_at(offset), message)
            if entry.kind == "release" and not entry.bullet_count():
                self.problem(entry.line, "%s has no bullets: a release lists what it changed" % entry.heading)
        self.order([entry for entry in self.entries if entry.kind == "release"])

    def order(self, releases):
        """Builds strictly decreasing, dates never increasing, one codename per major version."""
        builds, named = {}, {}
        previous = None
        for entry in releases:
            if entry.build in builds:
                self.problem(
                    entry.line, "build %d has an entry already, on line %d" % (entry.build, builds[entry.build])
                )
            elif previous is not None and entry.build > previous.build:
                self.problem(
                    entry.line,
                    "build %d is below build %d on line %d: newest first, builds go down"
                    % (entry.build, previous.build, previous.line),
                )
            if previous is not None and entry.date and previous.date and entry.date > previous.date:
                self.problem(
                    entry.line,
                    "%s is below %s on line %d: newest first, dates never go up"
                    % (entry.date, previous.date, previous.line),
                )
            major = entry.version[0]
            first = named.setdefault(major, entry)
            if first.codename != entry.codename:
                self.problem(
                    entry.line,
                    '%d.x is named "%s" on line %d, not "%s": one codename per major version'
                    % (major, first.codename, first.line, entry.codename),
                )
            builds.setdefault(entry.build, entry.line)
            previous = entry


def list_item_problem(item):
    """Why a list item under a ### heading is not a "- " bullet."""
    marker, text = item.group(1), (item.group(2) or "").strip()
    if marker in ("*", "+"):
        return "bullets start with '- ', not '%s '" % marker
    if marker != "-":
        return "no numbered lists: bullets start with '- '"
    if not text:
        return "an empty bullet"
    return "a bullet is '- ' and its text, one space after the dash"


def stray_line_problem(line):
    """Why a line under a ### heading is neither a bullet nor a continuation line."""
    indent = len(line) - len(line.lstrip(" \t"))
    if "\t" in line[:indent]:
        return "indent continuation lines with two spaces, not a tab"
    if indent:
        return "continuation lines are indented by exactly two spaces, not %d" % indent
    if THEMATIC_BREAK_RE.match(line):
        return "no horizontal rules"
    if line.startswith("|"):
        return "no tables"
    if line.startswith("<"):
        return "no HTML"
    if line.startswith(("```", "~~~")):
        return "no code blocks: put code in `backticks` inside a bullet"
    if line.startswith(">"):
        return "no block quotes"
    return "under a ### heading only bullets ('- ' and the text) and their continuation lines (two spaces)"


def block_problem(content, continues):
    """Why content, a bullet's text or a continuation line without its two spaces, would start a
    Markdown block of its own instead of being text of the bullet; None when it would not.
    continues: the line continues a paragraph, which only a numbered list starting at 1 interrupts."""
    if HEADING_RE.match(content):
        return "no headings inside a bullet"
    number = NESTED_NUMBER_RE.match(content)
    if NESTED_BULLET_RE.match(content) or (number and (not continues or int(number.group(1)) == 1)):
        return "no nested lists"
    if content.startswith(">"):
        return "no block quotes"
    if content.startswith(("```", "~~~")):
        return "no code blocks: put code in `backticks`"
    if content.startswith("|"):
        return "no tables"
    if THEMATIC_BREAK_RE.match(content) or (continues and SETEXT_RE.match(content)):
        return "no rules or underlined headings"
    return None


# ---------------------------------------------------------------------------
# Inline markup: one tokenizer for the checks and the HTML
# ---------------------------------------------------------------------------


def backtick_run(text, index):
    end = index
    while end < len(text) and text[end] == "`":
        end += 1
    return end - index


def closing_backticks(text, index, run):
    """Where the next run of exactly `run` backticks at or after index starts, or -1."""
    while index < len(text):
        if text[index] != "`":
            index += 1
            continue
        length = backtick_run(text, index)
        if length == run:
            return index
        index += length
    return -1


def code_text(raw):
    """A code span's content as CommonMark shows it: one space off each end when both ends have
    one and it is not all spaces."""
    if len(raw) >= 2 and raw[0] == raw[-1] == " " and raw.strip(" "):
        return raw[1:-1]
    return raw


def inline_tokens(text):
    """One paragraph's inline markup, left to right, as (kind, start, end, value) tuples:
    "text"; "escaped" (a backslash and the punctuation character it keeps literal, the value);
    "code" (value: the code, without its backticks); "stray" (backticks with no partner);
    "bold" (a ** marker); "link" and "image" (value: the text between the brackets, which starts
    one character after start for a link and two for an image)."""
    tokens = []
    plain = index = 0  # plain: where the pending run of plain text starts
    while index < len(text):
        char = text[index]
        token = None
        if char == "\\" and index + 1 < len(text) and text[index + 1] in ASCII_PUNCTUATION:
            token = ("escaped", index, index + 2, text[index + 1])
        elif char == "`":
            run = backtick_run(text, index)
            close = closing_backticks(text, index + run, run)
            if close < 0:
                token = ("stray", index, index + run, text[index : index + run])
            else:
                token = ("code", index, close + run, code_text(text[index + run : close]))
        elif text.startswith("**", index):
            token = ("bold", index, index + 2, "**")
        elif char == "[" or text.startswith("![", index):
            link = LINK_RE.match(text, index)
            if link:
                token = ("image" if link.group(1) else "link", index, link.end(), link.group(2))
        if token is None:
            index += 1
            continue
        if plain < index:
            tokens.append(("text", plain, index, text[plain:index]))
        tokens.append(token)
        index = plain = token[2]
    if plain < len(text):
        tokens.append(("text", plain, len(text), text[plain:]))
    return tokens


def masked(text, base, found):
    """text with code spans, escaped characters and link targets replaced by as many NUL
    characters, so the inline rules see the text and the markers at their own offsets. Adds the
    problems the tokens show by themselves to found, as (base + offset, message)."""
    out, markers = [], []
    for kind, start, end, value in inline_tokens(text):
        if kind in ("text", "bold"):
            out.append(text[start:end])
            if kind == "bold":
                markers.append(base + start)
        elif kind in ("link", "image"):
            opener = 2 if kind == "image" else 1
            if kind == "image":
                found.append((base + start, "no images"))
            inner = masked(value, base + start + opener, found)
            out.append("\0" * opener + inner + "\0" * (end - start - opener - len(value)))
        else:
            if kind == "stray":
                found.append((base + start, "unclosed `code`: a backtick with no partner"))
            out.append("\0" * (end - start))
    if len(markers) % 2:
        found.append((markers[-1], "unclosed **bold**"))
    return "".join(out)


def inline_problems(text):
    """The markup in one paragraph of a bullet that the HTML would not show as GitHub does, as
    (offset, message) pairs: unclosed `code` or **bold**, images, HTML, entities, malformed links,
    *italic*, _italic_ and ~~strikethrough~~. Each rule is reported once per paragraph."""
    found = []
    plain = masked(text, 0, found).replace("**", "\0\0")
    for pattern, message in INLINE_RULES:
        match = pattern.search(plain)
        if match:
            found.append((match.start(), message))
    return sorted(found)


def escape(text):
    """text for HTML: & < > and both quotes as references, every non-ASCII character as &#N;, so
    the fragment reads the same in whatever encoding the page is taken to be."""
    for char, reference in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ('"', "&quot;"), ("'", "&#39;")):
        text = text.replace(char, reference)
    return text.encode("ascii", "xmlcharrefreplace").decode("ascii")


def inline_html(text):
    """One paragraph of a bullet as HTML: escaped text, `code` as <code>, **bold** as <b>, a link
    as its text; #123 stays text."""
    tokens = inline_tokens(text)
    markers = [token[1] for token in tokens if token[0] == "bold"]
    unpaired = markers[-1] if len(markers) % 2 else None
    parts, bold = [], False
    for kind, start, _end, value in tokens:
        if kind == "code":
            parts.append("<code>%s</code>" % escape(value))
        elif kind in ("link", "image"):
            parts.append(inline_html(value))
        elif kind != "bold":
            parts.append(escape(value))
        elif start == unpaired:
            parts.append("**")
        else:
            parts.append("</b>" if bold else "<b>")
            bold = not bold
    return "".join(parts)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def bullet_html(bullet):
    paragraphs = [inline_html(paragraph.text) for paragraph in bullet.paragraphs]
    if len(paragraphs) == 1:
        return paragraphs[0]
    return "".join("<p>%s</p>" % paragraph for paragraph in paragraphs)


def render_html(changelog, heading):
    """The fragment for a Documentation tab: the Unreleased entry under heading when it has
    bullets and heading is not None, then every release, newest first."""
    shown = []
    unreleased = changelog.unreleased
    if heading is not None and unreleased is not None and unreleased.bullet_count():
        shown.append((heading, unreleased))
    shown.extend((entry.heading, entry) for entry in changelog.releases)
    out = ['<h2 id="changelog">Changelog</h2>', "<p>%s</p>" % escape(INTRO)]
    if not shown:
        out.append("<p>No release yet.</p>")
    for title, entry in shown:
        out.append("<h3>%s</h3>" % escape(title))
        for section in entry.sections:
            out.append("<p><b>%s</b></p>" % escape(section.name))
            out.append("<ul>")
            out.extend("<li>%s</li>" % bullet_html(bullet) for bullet in section.bullets)
            out.append("</ul>")
    return "\n".join(out) + "\n"


def markdown_sections(entry):
    """An entry's categories as bold lines, each followed by its bullets as CHANGELOG.md has them."""
    blocks = []
    for section in entry.sections:
        bullets = "\n".join(line for bullet in section.bullets for line in bullet.source)
        blocks.append("**%s**\n\n%s" % (section.name, bullets))
    return "\n\n".join(blocks)


def markdown_history(changelog, version, build):
    """The released entries of version, newest first, each under a ### heading."""
    entries = [entry for entry in changelog.releases if entry.version == version]
    if not entries:
        return "None: build %d is the first build of %d.%d." % (build, version[0], version[1])
    return "\n\n".join("### %s\n\n%s" % (entry.heading, markdown_sections(entry)) for entry in entries)


def fill(template, values, name):
    """The template with every {placeholder} replaced in one pass, so nothing a value brings in is
    replaced again. Refuses a placeholder it does not know and a template without {this_build}."""
    unknown = sorted({match.group(1) for match in PLACEHOLDER_RE.finditer(template)} - set(values))
    if unknown:
        raise ChangelogError(
            "%s names %s; the placeholders are %s"
            % (name, ", ".join("{%s}" % key for key in unknown), ", ".join("{%s}" % key for key in values))
        )
    if "{this_build}" not in template:
        raise ChangelogError("%s has no {this_build}: the notes would not say what the release changes" % name)
    return PLACEHOLDER_RE.sub(lambda match: values[match.group(1)], template).rstrip("\n") + "\n"


def entry_codename(changelog, major, build, date, codename):
    """The codename of a new build of major version `major`: the file's, or --codename for the
    first release of a new major version. Refuses a build that has an entry already, a build or
    date older than the newest entry's, a codename that is not the one of the major version, and a
    new major version's first release without one."""
    for entry in changelog.releases:
        if entry.build == build:
            raise ChangelogError("build %d has an entry already, on line %d" % (build, entry.line))
    newest = changelog.releases[0] if changelog.releases else None
    if newest is not None and build < newest.build:
        raise ChangelogError(
            "build %d is older than build %d, the newest entry (line %d)" % (build, newest.build, newest.line)
        )
    if newest is not None and date < newest.date:
        raise ChangelogError("%s is before %s, the newest entry's date (line %d)" % (date, newest.date, newest.line))
    named = next((entry for entry in changelog.releases if entry.version[0] == major), None)
    if named is None:
        if codename is None:
            raise ChangelogError("%d.x has no release yet: name its first one with --codename" % major)
    elif codename is not None and codename != named.codename:
        raise ChangelogError('%d.x is named "%s" (line %d), not "%s"' % (major, named.codename, named.line, codename))
    else:
        codename = named.codename
    return codename


def release_title(changelog, version, build, date, codename):
    """(codename, heading text without "## ") of the release the Unreleased entry becomes; version
    is (major, minor). Refuses what entry_codename refuses."""
    codename = entry_codename(changelog, version[0], build, date, codename)
    return codename, '%d.%d "%s", build %d (%s)' % (version[0], version[1], codename, build, date)


def prerelease_title(changelog, version, build, date, codename):
    """(codename, heading text) of a prerelease (a Version with beta), which shows the Unreleased
    entry as a build for testing, never as the release (docs/prerelease-design.md). Refuses what
    entry_codename refuses, and a version CHANGELOG.md lists already: a prerelease comes before its
    version's release."""
    listed = [entry for entry in changelog.releases if entry.version >= version.release]
    if listed:
        newest = max(listed, key=lambda entry: (entry.version, entry.build))
        major, minor = newest.version
        raise ChangelogError(
            "%s is a prerelease of %d.%d, but CHANGELOG.md lists %d.%d already (line %d): a prerelease comes before "
            "its version's release, so name a later version, such as %d.%d-beta.1"
            % (version, *version.release, major, minor, newest.line, major, minor + 1)
        )
    codename = entry_codename(changelog, version.major, build, date, codename)
    title = '%d.%d beta %d "%s" (prerelease), build %d (%s)' % (*version.release, version.beta, codename, build, date)
    return codename, title


# ---------------------------------------------------------------------------
# Files and output
# ---------------------------------------------------------------------------


def display_path(path):
    """A path relative to the repository when it is inside it, absolute otherwise."""
    relative = os.path.relpath(os.path.abspath(path), ROOT)
    return relative if not relative.startswith("..") else os.path.abspath(path)


def read_text(path):
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as err:
        raise ChangelogError("cannot read %s: %s" % (display_path(path), err)) from err


def report(problems, path):
    for number, message in problems:
        print("%s:%d: %s" % (display_path(path), number, message), file=sys.stderr)


def checked(changelog, path):
    """changelog, refused with every problem printed unless it passes check."""
    if changelog.problems:
        report(changelog.problems, path)
        raise ChangelogError("%s fails check: nothing done" % display_path(path))
    return changelog


def emit(text):
    """Write text to stdout as UTF-8 whatever the locale (the notes are not ASCII)."""
    buffer = getattr(sys.stdout, "buffer", None)
    if buffer is None:
        sys.stdout.write(text)
        return
    sys.stdout.flush()
    buffer.write(text.encode("utf-8"))
    buffer.flush()


def plural(count, noun):
    return "%d %s%s" % (count, noun, "" if count == 1 else "s")


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_check(args):
    changelog = parse(read_text(args.file))
    if changelog.problems:
        report(changelog.problems, args.file)
        print("%s: %s" % (display_path(args.file), plural(len(changelog.problems), "problem")), file=sys.stderr)
        return EXIT_REFUSED
    print("%s: ok (%s)" % (display_path(args.file), plural(len(changelog.releases), "release")))
    return EXIT_OK


def cmd_html(args):
    changelog = checked(parse(read_text(args.file)), args.file)
    if args.release is not None:
        heading = None
        if changelog.unreleased.bullet_count() and args.release.beta is None:
            heading = release_title(changelog, args.release.release, args.build, args.date, args.codename)[1]
        elif changelog.unreleased.bullet_count():
            heading = prerelease_title(changelog, args.release, args.build, args.date, args.codename)[1]
    elif args.dev_build is not None:
        heading = "Unreleased (development build %d)" % args.dev_build
    else:
        heading = "Unreleased"
    emit(render_html(changelog, heading))
    return EXIT_OK


def cmd_notes(args):
    changelog = checked(parse(read_text(args.file)), args.file)
    unreleased = changelog.unreleased
    version = args.version
    if not unreleased.bullet_count():
        raise ChangelogError(
            "'## Unreleased' (line %d) has no bullets: a %s must say what it changes"
            % (unreleased.line, "release" if version.beta is None else "prerelease")
        )
    if version.beta is None:
        codename, _title = release_title(changelog, version.release, args.build, args.date, args.codename)
        template = args.template or TEMPLATE_FILE
        values = {
            "version": "%d.%d" % version.release,
            "codename": codename,
            "build": str(args.build),
            "date": args.date,
            "this_build": markdown_sections(unreleased),
            "history": markdown_history(changelog, version.release, args.build),
        }
    else:
        codename, _title = prerelease_title(changelog, version, args.build, args.date, args.codename)
        if not changelog.releases:
            raise ChangelogError(
                "%s: a prerelease's notes name the release it follows, and %s lists none"
                % (version, display_path(args.file))
            )
        stable = changelog.releases[0]
        template = args.template or PRERELEASE_TEMPLATE_FILE
        values = {
            "version": str(version),
            "release": "%d.%d" % version.release,
            "beta": str(version.beta),
            "codename": codename,
            "build": str(args.build),
            "date": args.date,
            "this_build": markdown_sections(unreleased),
            "stable": stable.heading,
            "stable_version": "%d.%d" % stable.version,
        }
    emit(fill(read_text(template), values, display_path(template)))
    return EXIT_OK


def cmd_stamp(args):
    if args.version.beta is not None:
        raise ChangelogError(
            "%s is a prerelease: CHANGELOG.md lists releases only, and the %d.%d entry will carry these changes "
            "(docs/prerelease-design.md); nothing stamped" % (args.version, *args.version.release)
        )
    text = read_text(args.file)
    changelog = checked(parse(text), args.file)
    unreleased = changelog.unreleased
    if not unreleased.bullet_count():
        raise ChangelogError("'## Unreleased' (line %d) has no bullets: nothing to stamp" % unreleased.line)
    _codename, title = release_title(changelog, args.version.release, args.build, args.date, args.codename)
    lines = text.split("\n")
    ending = "\r" if lines[unreleased.line - 1].endswith("\r") else ""
    lines[unreleased.line - 1 : unreleased.line] = [UNRELEASED + ending, ending, "## " + title + ending]
    stamped = "\n".join(lines)
    result = parse(stamped)
    if result.problems:
        report(result.problems, args.file)
        raise ChangelogError("stamped, the file would fail check (above): %s is unchanged" % display_path(args.file))
    with open(args.file, "w", encoding="utf-8", newline="") as handle:
        handle.write(stamped)
    print("%s: '## Unreleased' is now '## %s', below a new empty '## Unreleased'" % (display_path(args.file), title))
    return EXIT_OK


# ---------------------------------------------------------------------------


def version_arg(text):
    """A Version: MAJOR.MINOR (1.0) or MAJOR.MINOR-beta.N for a prerelease (1.1-beta.1)."""
    match = VERSION_RE.fullmatch(text)
    if not match:
        raise argparse.ArgumentTypeError(
            "a version is MAJOR.MINOR, such as 1.0, or MAJOR.MINOR-beta.N for a prerelease, such as 1.1-beta.1, "
            "not %r" % text
        )
    beta = int(match.group(3)) if match.group(3) else None
    return Version(int(match.group(1)), int(match.group(2)), beta)


def build_arg(text):
    if not re.fullmatch(r"[0-9]+", text) or int(text) < 1:
        raise argparse.ArgumentTypeError("a build number is a whole number from 1, not %r" % text)
    return int(text)


def date_arg(text):
    if not is_date(text):
        raise argparse.ArgumentTypeError("a date is YYYY-MM-DD, such as 2026-10-25, not %r" % text)
    return text


def codename_arg(text):
    if not text.strip() or text != text.strip() or any(char in text for char in '"\r\n'):
        raise argparse.ArgumentTypeError("a codename is a name without quotes, such as Cassian, not %r" % text)
    return text


def parse_args(argv):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--file", default=CHANGELOG_FILE, metavar="PATH", help="the changelog (default CHANGELOG.md)")

    release = argparse.ArgumentParser(add_help=False)
    release.add_argument(
        "--version",
        required=True,
        type=version_arg,
        metavar="VERSION",
        help="the release's version, such as 1.0, or a prerelease's, such as 1.1-beta.1",
    )
    release.add_argument(
        "--build", required=True, type=build_arg, metavar="N", help="its build number (the Driver Version)"
    )
    release.add_argument("--date", required=True, type=date_arg, metavar="YYYY-MM-DD", help="its date")
    release.add_argument(
        "--codename",
        type=codename_arg,
        metavar="NAME",
        help="the codename of a new major version's first release (default: its major version's, from the file)",
    )

    parser = argparse.ArgumentParser(
        prog="changelog.py",
        description="Check CHANGELOG.md and render it for the Documentation tabs, the release notes and a "
        "release (docs/changelog-design.md).",
        epilog="Exit codes: 0 done, 1 refused or invalid, 2 usage.",
    )
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser("check", parents=[common], help="validate the file; every problem with its line number")
    p.set_defaults(func=cmd_check)

    html = sub.add_parser(
        "html",
        parents=[common],
        help="print the changelog as an HTML fragment for a Documentation tab",
        epilog="--release, --build and --date go together. Without --release or --dev-build a non-empty "
        "Unreleased entry shows as Unreleased; an empty one never shows.",
    )
    html.add_argument(
        "--release",
        type=version_arg,
        metavar="VERSION",
        help="show a non-empty Unreleased entry as this release (1.0) or prerelease (1.1-beta.1)",
    )
    html.add_argument("--build", type=build_arg, metavar="N", help="the release's build number")
    html.add_argument("--date", type=date_arg, metavar="YYYY-MM-DD", help="the release's date")
    html.add_argument(
        "--dev-build",
        type=build_arg,
        metavar="N",
        help='show a non-empty Unreleased entry as "Unreleased (development build N)"',
    )
    html.add_argument(
        "--codename",
        type=codename_arg,
        metavar="NAME",
        help="with --release: the codename of a new major version's first release",
    )
    html.set_defaults(func=cmd_html)

    p = sub.add_parser(
        "notes",
        parents=[common, release],
        help="print the release's notes from the template; refuses an empty Unreleased entry",
    )
    p.add_argument(
        "--template",
        metavar="PATH",
        help="the notes' template (default .github/release-notes.md, for a prerelease .github/prerelease-notes.md)",
    )
    p.set_defaults(func=cmd_notes)

    p = sub.add_parser(
        "stamp",
        parents=[common, release],
        help="make the Unreleased entry the release's entry; refuses an empty one and a known build",
    )
    p.set_defaults(func=cmd_stamp)

    args = parser.parse_args(argv)
    if args.command == "html":
        given = [name for name in ("release", "build", "date") if getattr(args, name) is not None]
        if given and len(given) < 3:
            html.error("--release, --build and --date go together")
        if args.release is not None and args.dev_build is not None:
            html.error("--release and --dev-build exclude each other")
        if args.codename is not None and args.release is None:
            html.error("--codename goes with --release")
    return args


def main(argv):
    args = parse_args(argv)
    try:
        return args.func(args)
    except ChangelogError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_REFUSED
    except OSError as err:
        print("error: %s: %s" % (type(err).__name__, err), file=sys.stderr)
        return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
