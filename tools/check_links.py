#!/usr/bin/env python3
"""Check the links of the repository's Markdown documents and of the drivers' Documentation tabs.

  check_links.py [--root DIR] [--unlinked]

Issue #263: every link in every Markdown document resolves, checked on every change by
tools/check.sh (the "links" check) and CI.

Files: every Markdown file git tracks (git ls-files '*.md', read-only) and the three Documentation
tabs, src/*/www/documentation.html.

Links: in Markdown, [text](target), ![alt](target), the reference definitions [id]: target, and the
href of an <a> and the src of an <img> written in HTML; in the HTML manuals, every href and src.
Nothing in a fenced or indented code block, a code span or an HTML comment is a link: Markdown is
read with CommonMark's block and inline rules (block quotes, list items, HTML blocks, lazy lines)
and GitHub's tables and bare https:// links.

A link is broken when
  - its target is not a file or folder git tracks. A relative target is taken from the linking
    file's folder; in Markdown a leading / is the root of the repository, as on GitHub. A link to
    this repository on github.com, https://github.com/corytron/c4-hue-driver/(blob|tree|raw)/main/
    <path>, is checked as the local <path>; other http, https and mailto links are not checked
    (there is no network);
  - its #anchor names no place in the target: in a Markdown file a heading, by GitHub's slug rules
    (lower-case; punctuation removed except hyphens and spaces; spaces become hyphens; a repeated
    slug gets -1, -2, ...), or an explicit id="..." or <a name="...">; in an HTML file an id, a
    manual's <!-- CHANGELOG --> line counting as the <h2 id="changelog"> that tools/build.sh puts
    there. #top names the top of any page. On other files only GitHub's line anchors (#L12,
    #L12-L20) are checked, against the file's length.

--unlinked also lists, as "FILE: not reachable from README.md", every Markdown file at the top level
and under docs/ that README.md does not reach by following links, directly or through other
documents, except what EXEMPT names. The list is input to a decision (would visitors to the
project's GitHub page find the document useful?), so it never changes the exit status.

Output: every broken link as FILE:LINE: message, then "links: N files, M links, K problems", where M
counts the links checked (relative ones and those to this repository) and K the broken ones.

Standard library only; git runs read-only (rev-parse, ls-files). Exit codes: 0 no broken link,
1 broken links, 2 usage (argparse, or --root not the top of a git work tree).
"""

import argparse
import bisect
import dataclasses
import difflib
import fnmatch
import html
import html.parser
import os
import posixpath
import re
import subprocess
import sys
import unicodedata
import urllib.parse

EXIT_OK, EXIT_BROKEN, EXIT_USAGE = 0, 1, 2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPOSITORY = "corytron/c4-hue-driver"
START = "README.md"
MANUALS = "src/*/www/documentation.html"

# The documents --unlinked never lists, as (fnmatch pattern, reason).
EXEMPT = (
    ("docs/reviews/*", "historical records, reached through their own index or the design notes"),
    (".github/*", "GitHub's own templates (the pull request form, the release notes), used where GitHub shows them"),
)

# The ids tools/build.sh adds to a manual in place of a marker line: the changelog that replaces
# <!-- CHANGELOG --> starts with tools/changelog.py's <h2 id="changelog"> (docs/changelog-design.md).
MARKER_IDS = {"<!-- CHANGELOG -->": ("changelog",)}

ESCAPABLE = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

# Block starts, matched after at most three spaces of indentation (CommonMark 0.31, sections 4 and 5).
ATX_HEADING_RE = re.compile(r"#{1,6}(?:[ \t]|$)")
ATX_CLOSING_RE = re.compile(r"(?:^|[ \t]+)#+[ \t]*$")
FENCE_RE = re.compile(r"(`{3,}|~{3,})(.*)$")
CLOSING_FENCE_RE = re.compile(r" {0,3}(`{3,}|~{3,})[ \t]*$")
THEMATIC_BREAK_RE = re.compile(r"([-*_])[ \t]*(?:\1[ \t]*){2,}$")
SETEXT_UNDERLINE_RE = re.compile(r"(?:=+|-+)[ \t]*$")
LIST_MARKER_RE = re.compile(r"(?:[-+*]|([0-9]{1,9})[.)])(?=[ \t]|$)")
# GitHub's tables: a delimiter row under a header row with as many cells.
DELIMITER_ROW_RE = re.compile(r"\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$")

# HTML in Markdown (CommonMark 0.31, sections 4.6 and 6.6).
TAG_NAME = r"[A-Za-z][A-Za-z0-9-]*"
ATTRIBUTE = r"""\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?"""
OPEN_TAG = r"<(?P<name>%s)(?P<attributes>(?:%s)*)\s*/?>" % (TAG_NAME, ATTRIBUTE)
CLOSING_TAG = r"</(?P<closing>%s)\s*>" % TAG_NAME
INLINE_HTML_RE = re.compile(
    "|".join(
        (
            OPEN_TAG,
            CLOSING_TAG,
            r"<!---?>",
            r"<!--[\s\S]*?-->",
            r"<\?[\s\S]*?\?>",
            r"<![A-Za-z][^>]*>",
            r"<!\[CDATA\[[\s\S]*?\]\]>",
        )
    )
)
ATTRIBUTE_RE = re.compile(r"""\s+([A-Za-z_:][A-Za-z0-9_.:-]*)(?:\s*=\s*([^\s"'=<>`]+|'[^']*'|"[^"]*"))?""")
COMPLETE_TAG_RE = re.compile(r"(?:%s|%s)[ \t]*$" % (OPEN_TAG, CLOSING_TAG))
BLOCK_TAG_RE = re.compile(r"</?(%s)(?:[ \t]|/?>|$)" % TAG_NAME)
BLOCK_TAGS = frozenset(
    "address article aside base basefont blockquote body caption center col colgroup dd details dialog dir div "
    "dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe "
    "legend li link main menu menuitem nav noframes ol optgroup option p param search section summary table "
    "tbody td tfoot th thead title tr track ul".split()
)
# HTML blocks of kinds 1 to 5: (start, the line that ends it, whether its tags are read).
HTML_BLOCKS = (
    (
        re.compile(r"<(?:pre|script|style|textarea)(?:[ \t>]|$)", re.IGNORECASE),
        re.compile(r"</(?:pre|script|style|textarea)>", re.IGNORECASE),
        True,
    ),
    (re.compile(r"<!--"), re.compile(r"-->"), False),
    (re.compile(r"<\?"), re.compile(r"\?>"), False),
    (re.compile(r"<![A-Za-z]"), re.compile(r">"), False),
    (re.compile(r"<!\[CDATA\["), re.compile(r"\]\]>"), False),
)
HEADING_TAGS = frozenset(("h1", "h2", "h3", "h4", "h5", "h6"))
# The links GitHub keeps from HTML written in Markdown.
MARKDOWN_HTML_LINKS = {"a": "href", "img": "src"}

# Inlines (CommonMark 0.31, section 6).
SPECIAL_RE = re.compile(r"[\\`<!\[\]&_]")
AUTOLINK_RE = re.compile(r"<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\x00-\x20<>]*)>")
EMAIL_AUTOLINK_RE = re.compile(
    r"<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*)>"
)
ENTITY_RE = re.compile(r"&(?:#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});")
ESCAPE_OR_ENTITY_RE = re.compile(r"\\([!-/:-@\[-`{-~])|(%s)" % ENTITY_RE.pattern)
LINK_LABEL_RE = re.compile(r"\[((?:[^\\\[\]]|\\.){0,999})\]", re.DOTALL)
LABEL_TEXT_RE = re.compile(r"(?:[^\\\[\]]|\\.){1,999}", re.DOTALL)

# Targets.
SCHEME_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
REPO_HOST = r"github\.com/" + re.escape(REPOSITORY)
REPO_URL_RE = re.compile(
    r"(?i:https?://(?:www\.)?%s)/(?:blob|tree|raw)/main(?P<path>/[^?#]*)?(?P<rest>[?#].*)?$" % REPO_HOST, re.DOTALL
)
# GitHub turns a bare URL into a link where it starts a line or follows a space, *, _, ~ or (.
BARE_REPO_URL_RE = re.compile(
    r"(?:(?<=[\s*_~(])|^)(?i:(?:https?://(?:www\.)?|www\.)%s)(?:[/?#][^\s<]*)?" % REPO_HOST, re.MULTILINE
)
LINE_ANCHOR_RE = re.compile(r"L([0-9]+)(?:C[0-9]+)?(?:-L([0-9]+)(?:C[0-9]+)?)?")


class UsageError(Exception):
    """A run that cannot start: printed to stderr, exit 2."""


class HtmlError(Exception):
    """HTML that Python's parser gives up on (before 3.13 it raises AssertionError on a malformed <![
    section): the file is reported instead of checked."""


# ---------------------------------------------------------------------------
# Markdown: blocks
# ---------------------------------------------------------------------------


def indent_of(text):
    """The number of spaces text starts with."""
    return len(text) - len(text.lstrip(" "))


class Quote:
    """An open block quote."""


class Item:
    """An open list item: a non-blank line belongs to it when indented by at least indent columns, a
    blank line once it has content (a list item begins with at most one blank line)."""

    def __init__(self, indent, content):
        self.indent = indent
        self.content = content


class Paragraph:
    """An open paragraph: its lines as (line number, text without its indentation)."""

    def __init__(self, number, text):
        self.lines = [(number, text)]


class Fence:
    """An open fenced code block: nothing in it is a link."""

    def __init__(self, char, length):
        self.char = char
        self.length = length

    def closed_by(self, text):
        match = CLOSING_FENCE_RE.match(text)
        return bool(match) and match.group(1)[0] == self.char and len(match.group(1)) >= self.length


class IndentedCode:
    """An open indented code block: nothing in it is a link."""


class HtmlBlock:
    """An HTML block: end matches the line that ends it (None: a blank line ends it); scanned says
    whether its tags are read (not for a comment, a declaration, a processing instruction or CDATA)."""

    def __init__(self, end, scanned):
        self.end = end
        self.scanned = scanned
        self.lines = []  # (line number, text)


class Table:
    """An open table: its header and body rows as (line number, text)."""

    def __init__(self, number, header):
        self.rows = [(number, header)]


@dataclasses.dataclass
class Inline:
    """Inline content: a paragraph (from begin on, after its link reference definitions), a heading or
    a table cell, with the offset in text and the line number where each of its lines starts."""

    text: str
    offsets: list
    numbers: list
    begin: int = 0
    heading: bool = False

    def line_at(self, offset):
        return self.numbers[bisect.bisect_right(self.offsets, offset) - 1]


def table_cells(row):
    """The cells of a table row: split at every pipe no backslash escapes, without the outer ones; an
    escaped pipe is a pipe of the cell's text (GitHub's tables)."""
    row = row.strip()
    if row.startswith("|"):
        row = row[1:]
    if row.endswith("|") and not row.endswith("\\|"):
        row = row[:-1]
    return [cell.replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", row)]


def html_block(after, in_paragraph):
    """The HTML block that a line starting with after (its indentation removed) opens, or None.
    The seventh kind, a line holding one complete tag, cannot interrupt a paragraph, nor end one that
    the line may continue lazily (as cmark, which GitHub uses, also for a lone </pre>)."""
    if not after.startswith("<"):
        return None
    for start, end, scanned in HTML_BLOCKS:
        if start.match(after):
            return HtmlBlock(end, scanned)
    tag = BLOCK_TAG_RE.match(after)
    if tag and tag.group(1).lower() in BLOCK_TAGS:
        return HtmlBlock(None, True)
    if not in_paragraph and COMPLETE_TAG_RE.match(after):
        return HtmlBlock(None, True)
    return None


class BlockParser:
    """CommonMark's block structure, reduced to what decides where a link can be: block quotes and
    list items (with lazy continuation lines), fenced and indented code, HTML blocks, headings,
    GitHub's tables and paragraphs. Tabs count as four columns."""

    def __init__(self):
        self.containers = []  # the open block quotes and list items, outermost first
        self.leaf = None  # the open leaf block of the innermost container
        self.blocks = []  # Inline and HtmlBlock, in document order
        self.definitions = {}  # normalized label: destination; the first definition of a label wins
        self.links = []  # (line, destination) of every link reference definition

    def parse(self, lines):
        for number, line in enumerate(lines, 1):
            self.feed(number, line.expandtabs(4))
        self.close(0)
        return self

    def close(self, depth):
        """Close the open leaf block and every container deeper than depth."""
        leaf, self.leaf = self.leaf, None
        if isinstance(leaf, Paragraph):
            self.paragraph(leaf.lines, heading=False)
        elif isinstance(leaf, Table):
            for number, row in leaf.rows:
                self.blocks.extend(Inline(cell, [0], [number]) for cell in table_cells(row))
        elif isinstance(leaf, HtmlBlock) and leaf.scanned and leaf.lines:
            self.blocks.append(leaf)
        del self.containers[depth:]

    def match(self, line):
        """(where the line's text starts after the markers and indentation of the open containers it
        continues, how many it continues)."""
        pos = 0
        for depth, container in enumerate(self.containers):
            rest = line[pos:]
            indent = indent_of(rest)
            if isinstance(container, Quote):
                if indent > 3 or not rest.startswith(">", indent):
                    return pos, depth
                pos += indent + 1
                if line.startswith(" ", pos):
                    pos += 1
            elif indent < len(rest):
                if indent < container.indent:
                    return pos, depth
                pos += container.indent
                container.content = True
            elif not container.content:
                return pos, depth
        return pos, len(self.containers)

    def feed(self, number, line):
        pos, matched = self.match(line)
        continued = matched == len(self.containers)
        if continued and isinstance(self.leaf, Fence):
            if self.leaf.closed_by(line[pos:]):
                self.leaf = None
            return
        if continued and isinstance(self.leaf, HtmlBlock):
            self.html_line(number, line[pos:])
            return
        interrupts = continued and isinstance(self.leaf, Paragraph)
        opened = False  # a container opened on this line
        while True:
            rest = line[pos:]
            indent = indent_of(rest)
            if indent >= 4 or indent == len(rest):
                break
            after = rest[indent:]
            if after.startswith(">"):
                self.close(matched)
                self.containers.append(Quote())
                matched += 1
                pos += indent + 1
                if line.startswith(" ", pos):
                    pos += 1
                interrupts, opened = False, True
                continue
            if ATX_HEADING_RE.match(after):
                self.close(matched)
                content = ATX_CLOSING_RE.sub("", after.lstrip("#").strip()).strip()
                self.blocks.append(Inline(content, [0], [number], heading=True))
                return
            fence = FENCE_RE.match(after)
            if fence and not (fence.group(1).startswith("`") and "`" in fence.group(2)):
                self.close(matched)
                self.leaf = Fence(fence.group(1)[0], len(fence.group(1)))
                return
            block = html_block(after, isinstance(self.leaf, Paragraph))
            if block is not None:
                self.close(matched)
                self.leaf = block
                self.html_line(number, rest)
                return
            if interrupts and SETEXT_UNDERLINE_RE.match(after):
                lines, self.leaf = self.leaf.lines, None
                self.paragraph(lines, heading=True)
                return
            if THEMATIC_BREAK_RE.match(after):
                self.close(matched)
                return
            if interrupts and "|" in after and DELIMITER_ROW_RE.match(after):
                header_number, header = self.leaf.lines[-1]
                if len(table_cells(header)) == len(table_cells(after)):
                    lines, self.leaf = self.leaf.lines[:-1], None
                    if lines:
                        self.paragraph(lines, heading=False)
                    self.leaf = Table(header_number, header)
                    return
            item = LIST_MARKER_RE.match(after)
            if item:
                width = item.end()
                spaces = indent_of(after[width:])
                blank = width + spaces == len(after)
                ordered_not_one = item.group(1) is not None and int(item.group(1)) != 1
                if not (interrupts and (blank or ordered_not_one)):
                    self.close(matched)
                    content = 1 if blank or spaces > 4 else spaces
                    self.containers.append(Item(indent + width + content, not blank))
                    matched += 1
                    pos += indent + width + min(content, spaces)
                    interrupts, opened = False, True
                    continue
            break
        rest = line[pos:]
        indent = indent_of(rest)
        if indent == len(rest):  # a blank line
            if not continued and not opened:
                self.close(matched)
            elif isinstance(self.leaf, (Paragraph, Table)):
                self.close(len(self.containers))
            return
        if not continued and not opened:
            if isinstance(self.leaf, Paragraph):  # a lazy continuation line
                self.leaf.lines.append((number, rest[indent:]))
                return
            self.close(matched)
        if isinstance(self.leaf, Paragraph):
            self.leaf.lines.append((number, rest[indent:]))
        elif isinstance(self.leaf, Table):
            self.leaf.rows.append((number, rest[indent:]))
        elif indent >= 4:
            if not isinstance(self.leaf, IndentedCode):
                self.close(len(self.containers))
                self.leaf = IndentedCode()
        else:
            self.close(len(self.containers))
            self.leaf = Paragraph(number, rest[indent:])

    def html_line(self, number, text):
        block = self.leaf
        if block.end is None and not text.strip():
            self.close(len(self.containers))
            return
        block.lines.append((number, text))
        if block.end is not None and block.end.search(text):
            self.close(len(self.containers))

    def paragraph(self, lines, heading):
        """Take the link reference definitions at the start of a closed paragraph (or setext heading),
        then keep the rest as inline content."""
        if heading:
            lines = [(number, content.rstrip(" \t")) for number, content in lines]
        offsets, numbers, offset = [], [], 0
        for number, content in lines:
            offsets.append(offset)
            numbers.append(number)
            offset += len(content) + 1
        text = "\n".join(content for _, content in lines)
        begin = 0
        while True:
            found = definition(text, begin)
            if found is None:
                break
            label, target, start, begin = found
            self.links.append((numbers[bisect.bisect_right(offsets, start) - 1], target))
            self.definitions.setdefault(normalize_label(label), target)
        if text[begin:].strip():
            self.blocks.append(Inline(text, offsets, numbers, begin, heading))


# ---------------------------------------------------------------------------
# Markdown: link destinations, titles and reference definitions
# ---------------------------------------------------------------------------


def skip_blanks(text, index):
    """index moved past spaces and tabs."""
    while index < len(text) and text[index] in " \t":
        index += 1
    return index


def skip_spaces(text, index):
    """index moved past spaces and tabs and at most one line ending."""
    index = skip_blanks(text, index)
    if text.startswith("\n", index):
        index = skip_blanks(text, index + 1)
    return index


def line_end(text, index):
    """Where the next line starts when only spaces and tabs follow index on its line, else None."""
    index = skip_blanks(text, index)
    if index == len(text):
        return index
    return index + 1 if text[index] == "\n" else None


def unescape(text):
    """text with its backslash escapes and entity references resolved."""
    return ESCAPE_OR_ENTITY_RE.sub(lambda match: match.group(1) or html.unescape(match.group(2)), text)


def normalize_label(label):
    """A link label as CommonMark matches it: case-folded, its runs of white space one space."""
    return " ".join(label.split()).casefold()


def destination(text, index):
    """A link destination at index: (destination, its offset, the offset after it), or None."""
    if text.startswith("<", index):
        end = index + 1
        while end < len(text):
            char = text[end]
            if char == "\\" and text[end + 1 : end + 2] in ESCAPABLE:
                end += 2
            elif char == ">":
                return unescape(text[index + 1 : end]), index + 1, end + 1
            elif char in "<\n":
                return None
            else:
                end += 1
        return None
    end, depth = index, 0
    while end < len(text):
        char = text[end]
        if char == "\\" and text[end + 1 : end + 2] in ESCAPABLE:
            end += 2
            continue
        if char <= " " or char == "\x7f":
            break
        if char == "(":
            depth += 1
        elif char == ")":
            if not depth:
                break
            depth -= 1
        end += 1
    if end == index or depth:
        return None
    return unescape(text[index:end]), index, end


def title_end(text, index):
    """The offset after the link title ("...", '...' or (...)) that starts at index, or None."""
    closer = ")" if text[index] == "(" else text[index]
    end = index + 1
    while end < len(text):
        char = text[end]
        if char == "\\" and text[end + 1 : end + 2] in ESCAPABLE:
            end += 2
            continue
        if char == closer:
            return end + 1
        if closer == ")" and char == "(":
            return None
        end += 1
    return None


def inline_tail(text, index):
    """The (destination "title") of an inline link at index: (destination, its offset, the offset after
    the closing parenthesis), or None."""
    if not text.startswith("(", index):
        return None
    start = skip_spaces(text, index + 1)
    if text.startswith(")", start):
        return "", start, start + 1
    found = destination(text, start)
    if found is None:
        return None
    target, start, end = found
    after = skip_spaces(text, end)
    if end < after < len(text) and text[after] in "\"'(":
        stop = title_end(text, after)
        if stop is None:
            return None
        after = skip_spaces(text, stop)
    if text.startswith(")", after):
        return target, start, after + 1
    return None


def definition(text, index):
    """A link reference definition at index: (label, destination, its offset, where the next line
    starts), or None. A label starting with ^ is a footnote (GitHub), not a definition."""
    label = LINK_LABEL_RE.match(text, index)
    if not label or not label.group(1).strip() or label.group(1).startswith("^"):
        return None
    if not text.startswith(":", label.end()):
        return None
    found = destination(text, skip_spaces(text, label.end() + 1))
    if found is None:
        return None
    target, start, end = found
    after = skip_spaces(text, end)
    if end < after < len(text) and text[after] in "\"'(":
        stop = title_end(text, after)
        if stop is not None and line_end(text, stop) is not None:
            return label.group(1), target, start, line_end(text, stop)
    stop = line_end(text, end)  # without a title, or with one that is not alone on its line(s)
    return None if stop is None else (label.group(1), target, start, stop)


# ---------------------------------------------------------------------------
# Markdown: inlines
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
    """A code span's content as CommonMark shows it: line endings as spaces, and one space off each
    end when both ends have one and it is not all spaces."""
    raw = raw.replace("\n", " ")
    if len(raw) >= 2 and raw[0] == raw[-1] == " " and raw.strip(" "):
        return raw[1:-1]
    return raw


def is_punctuation(char):
    """ASCII punctuation or a Unicode P category: what cmark-gfm, GitHub's parser, takes for punctuation
    when it decides whether an underscore opens or closes emphasis."""
    return char in ESCAPABLE or unicodedata.category(char)[0] == "P"


def trim_bare_url(url):
    """A bare URL without the trailing characters GitHub leaves out of the link."""
    while url:
        last = url[-1]
        if last in "?!.,:*_~'\"":
            url = url[:-1]
        elif last == ")" and url.count(")") > url.count("("):
            url = url[:-1]
        elif last == ";" and re.search(r"&[A-Za-z0-9]+;$", url):
            url = url[: url.rindex("&")]
        else:
            return url
    return url


@dataclasses.dataclass
class Opener:
    """An unmatched [ or ![: where it is in the text and in the rendered pieces."""

    index: int
    offset: int
    image: bool
    active: bool = True


class Delimiter:
    """A run of underscores that may open or close emphasis; only a heading's anchor needs them.
    count is what is left of the run once emphasis has taken some, length what it was."""

    def __init__(self, length, can_open, can_close):
        self.count = self.length = length
        self.can_open = can_open
        self.can_close = can_close

    def matches(self, opener):
        """Whether this closer may close emphasis that opener opens (CommonMark's rule of three)."""
        both = opener.can_close or self.can_open
        return not (both and (opener.length + self.length) % 3 == 0 and (opener.length % 3 or self.length % 3))


class InlineScanner:
    """One pass over inline content, left to right as CommonMark reads it: backslash escapes, code
    spans, autolinks and raw HTML first, then links and images closed at their "]"."""

    def __init__(self, text, begin, definitions):
        self.text = text
        self.begin = begin
        self.definitions = definitions
        self.pieces = []  # the rendered text, as str and Delimiter
        self.openers = []
        self.links = []  # (offset of the destination, destination)
        self.tags = []  # (offset, tag name, attribute text) of every raw HTML start tag
        self.covered = []  # (start, end) of code spans, autolinks, raw HTML and links: no bare URL there

    def scan(self):
        text, index = self.text, self.begin
        while index < len(text):
            char = text[index]
            if char == "\\":
                index = self.backslash(index)
            elif char == "`":
                index = self.code(index)
            elif char == "<":
                index = self.angle(index)
            elif char == "[" or text.startswith("![", index):
                image = char == "!"
                self.openers.append(Opener(len(self.pieces), index, image))
                self.pieces.append("![" if image else "[")
                index += 2 if image else 1
            elif char == "]":
                index = self.bracket(index)
            elif char == "&":
                index = self.entity(index)
            elif char == "_":
                index = self.underscores(index)
            else:
                special = SPECIAL_RE.search(text, index + 1)
                end = special.start() if special else len(text)
                self.pieces.append(text[index:end])
                index = end
        for match in BARE_REPO_URL_RE.finditer(text, self.begin):
            if not any(start <= match.start() < end for start, end in self.covered):
                url = trim_bare_url(match.group(0))
                self.links.append((match.start(), "https://" + url if url[:4].lower() == "www." else url))
        return self

    def backslash(self, index):
        following = self.text[index + 1 : index + 2]
        if following and following in ESCAPABLE:
            self.pieces.append(following)
            return index + 2
        self.pieces.append("" if following == "\n" else "\\")  # before a line ending: a hard break
        return index + 1

    def code(self, index):
        run = backtick_run(self.text, index)
        close = closing_backticks(self.text, index + run, run)
        if close < 0:
            self.pieces.append("`" * run)
            return index + run
        self.pieces.append(code_text(self.text[index + run : close]))
        self.covered.append((index, close + run))
        return close + run

    def angle(self, index):
        text = self.text
        match = AUTOLINK_RE.match(text, index) or EMAIL_AUTOLINK_RE.match(text, index)
        if match:
            if match.re is AUTOLINK_RE:
                self.links.append((index + 1, match.group(1)))
            self.pieces.append(match.group(1))
        else:
            match = INLINE_HTML_RE.match(text, index)
            if match is None:
                self.pieces.append("<")
                return index + 1
            if match.group("name"):
                self.tags.append((index, match.group("name").lower(), match.group("attributes")))
        self.covered.append((index, match.end()))
        return match.end()

    def entity(self, index):
        match = ENTITY_RE.match(self.text, index)
        if match is None:
            self.pieces.append("&")
            return index + 1
        self.pieces.append(html.unescape(match.group(0)))
        return match.end()

    def underscores(self, index):
        text = self.text
        end = index
        while end < len(text) and text[end] == "_":
            end += 1
        before = text[index - 1] if index > 0 else "\n"
        after = text[end] if end < len(text) else "\n"
        left = not after.isspace() and (not is_punctuation(after) or before.isspace() or is_punctuation(before))
        right = not before.isspace() and (not is_punctuation(before) or after.isspace() or is_punctuation(after))
        can_open = left and (not right or is_punctuation(before))
        can_close = right and (not left or is_punctuation(after))
        self.pieces.append(Delimiter(end - index, can_open, can_close))
        return end

    def bracket(self, index):
        """The "]" at index: a link or an image when it closes the nearest [ or ![ with an inline
        destination or a defined reference; else plain text."""
        if not self.openers or not self.openers[-1].active:
            if self.openers:
                self.openers.pop()
            self.pieces.append("]")
            return index + 1
        opener = self.openers.pop()
        tail = inline_tail(self.text, index + 1)
        if tail is not None:
            target, start, end = tail
            self.links.append((start, target))
        else:
            end = self.reference(opener, index)
            if end is None:
                self.pieces.append("]")
                return index + 1
        self.pieces[opener.index] = ""
        if opener.image:  # an image's description is no text of the page
            self.pieces[opener.index :] = [""] * (len(self.pieces) - opener.index)
        else:  # no link inside a link
            for earlier in self.openers:
                if not earlier.image:
                    earlier.active = False
        self.covered.append((opener.offset, end))
        return end

    def reference(self, opener, index):
        """Where a reference link or image closed by the "]" at index ends, or None when its label
        names no definition: [text][label], [label][] or [label]."""
        text = self.text
        label = LINK_LABEL_RE.match(text, index + 1)
        if label is not None and label.group(1).strip():
            key, end = label.group(1), label.end()
        else:
            key = text[opener.offset + (2 if opener.image else 1) : index]
            end = label.end() if label is not None and not label.group(1) else index + 1
            if not LABEL_TEXT_RE.fullmatch(key):
                return None
        return end if normalize_label(key) in self.definitions else None

    def rendered(self):
        """The text GitHub makes a heading's anchor from: the text of its HTML, with the underscores
        that open and close emphasis taken out."""
        openers = []
        for piece in self.pieces:
            if not isinstance(piece, Delimiter):
                continue
            while piece.can_close and piece.count:
                position = next((at for at in range(len(openers) - 1, -1, -1) if piece.matches(openers[at])), None)
                if position is None:
                    break
                opener = openers[position]
                used = 2 if opener.count >= 2 and piece.count >= 2 else 1
                opener.count -= used
                piece.count -= used
                del openers[position + (1 if opener.count else 0) :]
            if piece.can_open and piece.count:
                openers.append(piece)
        return "".join("_" * piece.count if isinstance(piece, Delimiter) else piece for piece in self.pieces)


# ---------------------------------------------------------------------------
# HTML, anchors and documents
# ---------------------------------------------------------------------------


class TagScanner(html.parser.HTMLParser):
    """The links, ids and heading texts of HTML. every: every href and src (a manual); otherwise only
    the href of <a> and the src of <img>, the links GitHub keeps from HTML in Markdown."""

    def __init__(self, every):
        super().__init__(convert_charrefs=True)
        self.every = every
        self.links = []  # (line, target)
        self.ids = set()
        self.headings = []  # the text of every h1 to h6, in order
        self.heading = None  # the text of the open heading so far

    def handle_starttag(self, tag, attrs):
        self.attributes(tag, attrs)
        if tag in HEADING_TAGS:
            self.heading = []

    def handle_startendtag(self, tag, attrs):
        self.attributes(tag, attrs)

    def handle_endtag(self, tag):
        if tag in HEADING_TAGS and self.heading is not None:
            self.headings.append("".join(self.heading))
            self.heading = None

    def handle_data(self, data):
        if self.heading is not None:
            self.heading.append(data)

    def attributes(self, tag, attrs):
        line = self.getpos()[0]
        for name, value in attrs:
            if value is None:
                continue
            if name == "id" or (name == "name" and tag == "a"):
                self.ids.add(value)
            if (self.every and name in ("href", "src")) or MARKDOWN_HTML_LINKS.get(tag) == name:
                self.links.append((line, value))


def scan_html(text, every, first_line=1):
    """A TagScanner that has read text, which starts on line first_line of its file."""
    tags = TagScanner(every)
    try:
        tags.feed(text)
        tags.close()
    except AssertionError as err:
        raise HtmlError("cannot read the HTML on line %d: %s" % (first_line + tags.getpos()[0] - 1, err)) from err
    return tags


def attribute_values(text):
    """The attributes of a start tag, from the text after its name, as {lower-case name: value}."""
    values = {}
    for match in ATTRIBUTE_RE.finditer(text):
        value = match.group(2) or ""
        if value[:1] in ("'", '"'):
            value = value[1:-1]
        values.setdefault(match.group(1).lower(), html.unescape(value))
    return values


def is_word(char):
    """A character GitHub keeps in an anchor besides hyphens and spaces: a letter, a mark, a digit or
    a connector such as the underscore (Ruby's \\p{Word})."""
    category = unicodedata.category(char)
    return category[0] in "LM" or category in ("Nd", "Pc")


def slug(text):
    """GitHub's anchor for a heading with this text: lower-case, punctuation removed except hyphens and
    spaces, spaces become hyphens."""
    return "".join(char for char in text.lower() if char in "- " or is_word(char)).replace(" ", "-")


class Slugs:
    """The anchors of a document's headings in order: a repeated slug gets -1, -2, ..."""

    def __init__(self):
        self.seen = {}

    def next(self, text):
        base = result = slug(text)
        while result in self.seen:
            self.seen[base] += 1
            result = "%s-%d" % (base, self.seen[base])
        self.seen[result] = 0
        return result


def split_lines(text):
    return [line[:-1] if line.endswith("\r") else line for line in text.split("\n")]


def markdown_document(text):
    """The links of a Markdown text as (line, target), in line order, and the anchors it defines."""
    parser = BlockParser().parse(split_lines(text))
    links, anchors, slugs = list(parser.links), set(), Slugs()
    for block in parser.blocks:
        if isinstance(block, HtmlBlock):
            first = block.lines[0][0]
            tags = scan_html("\n".join(content for _, content in block.lines), False, first)
            links.extend((first + line - 1, target) for line, target in tags.links)
            anchors.update(tags.ids)
            anchors.update(slugs.next(heading) for heading in tags.headings)
            continue
        scanner = InlineScanner(block.text, block.begin, parser.definitions).scan()
        links.extend((block.line_at(offset), target) for offset, target in scanner.links)
        for offset, name, attributes in scanner.tags:
            values = attribute_values(attributes)
            if "id" in values:
                anchors.add(values["id"])
            if name == "a" and "name" in values:
                anchors.add(values["name"])
            if MARKDOWN_HTML_LINKS.get(name) in values:
                links.append((block.line_at(offset), values[MARKDOWN_HTML_LINKS[name]]))
        if block.heading:
            anchors.add(slugs.next(scanner.rendered()))
    links.sort(key=lambda link: link[0])
    return links, anchors


def html_document(text):
    """The links of an HTML text as (line, target), in line order, and its ids, with those that
    tools/build.sh adds in place of a marker line."""
    tags = scan_html(text, True)
    anchors = set(tags.ids)
    for line in split_lines(text):
        anchors.update(MARKER_IDS.get(line.strip(), ()))
    return tags.links, anchors


@dataclasses.dataclass
class Document:
    """A file as a link source or target: anchors is None for a file that is neither Markdown nor
    HTML; error says why it could not be read."""

    path: str
    links: list = dataclasses.field(default_factory=list)
    anchors: set | None = None
    lines: int = 0
    error: str | None = None


def load(root, path):
    try:
        with open(os.path.join(root, *path.split("/")), "rb") as handle:
            data = handle.read()
    except OSError as err:
        return Document(path, error="cannot read it: %s" % (err.strerror or err))
    lines = data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)
    if not path.lower().endswith((".md", ".html", ".htm")):
        return Document(path, lines=lines)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as err:
        return Document(path, lines=lines, error="not UTF-8: %s" % err)
    text = text.removeprefix("\ufeff")
    try:
        links, anchors = (markdown_document if path.lower().endswith(".md") else html_document)(text)
    except HtmlError as err:
        return Document(path, lines=lines, error=str(err))
    return Document(path, links, anchors, lines)


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------


def split_target(target):
    """(path, query, fragment) of a URL without a scheme, the path and fragment percent-decoded; the
    fragment is None when there is no #."""
    rest, hash_mark, fragment = target.partition("#")
    path, _, query = rest.partition("?")
    return urllib.parse.unquote(path), query, urllib.parse.unquote(fragment) if hash_mark else None


def shown(target):
    return target if target.isprintable() else repr(target)


def listed(path):
    """Whether --unlinked considers the document: at the top level or under docs/, and not exempt."""
    if "/" in path and not path.startswith("docs/"):
        return False
    return not any(fnmatch.fnmatchcase(path, pattern) for pattern, _reason in EXEMPT)


@dataclasses.dataclass
class Report:
    files: int  # the files checked
    links: int  # the links checked: relative ones and those to this repository
    problems: list  # (path, line, message) of every broken link, by file and line
    unlinked: list  # the documents --unlinked lists


class Checker:
    def __init__(self, root, tracked):
        self.root = root
        self.tracked = frozenset(tracked)
        self.folders = {"."}
        for path in tracked:
            folder = posixpath.dirname(path)
            while folder and folder not in self.folders:
                self.folders.add(folder)
                folder = posixpath.dirname(folder)
        self.documents = {}
        self.problems = []
        self.links = 0
        self.edges = {}  # Markdown file: the Markdown files its links reach

    def document(self, path):
        if path not in self.documents:
            self.documents[path] = load(self.root, path)
        return self.documents[path]

    def check_file(self, path):
        document = self.document(path)
        if document.error:
            self.problems.append((path, 1, document.error))
            return
        for line, target in document.links:
            message = self.check_link(document, target.strip())
            if message:
                self.problems.append((path, line, message))

    def check_link(self, document, target):
        """Why the link is broken, or None (also for a link that is not checked)."""
        repository = REPO_URL_RE.match(target)
        if repository:
            path = urllib.parse.unquote(repository.group("path") or "").strip("/")
            _, query, fragment = split_target(repository.group("rest") or "")
            resolved = posixpath.normpath(path) if path else "."
        elif not target:
            self.links += 1
            return "broken link: its target is empty"
        elif SCHEME_RE.match(target) or target.startswith("//"):
            return None
        else:
            path, query, fragment = split_target(target)
            if not path:
                resolved = document.path
            elif path.startswith("/"):
                if not document.path.endswith(".md"):
                    self.links += 1
                    return "broken link %s: a manual's links are relative to its folder, %s" % (
                        shown(target),
                        posixpath.dirname(document.path),
                    )
                resolved = posixpath.normpath(path.lstrip("/") or ".")
            else:
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(document.path), path))
        self.links += 1
        reason = self.reason(document, resolved, query, fragment)
        return None if reason is None else "broken link %s: %s" % (shown(target), reason)

    def reason(self, source, resolved, query, fragment):
        if resolved == ".." or resolved.startswith("../"):
            return "it points outside the repository"
        full = os.path.join(self.root, *resolved.split("/"))
        if resolved in self.tracked:
            if not os.path.exists(full):
                return "%s does not exist" % resolved
            folder = False
        elif resolved in self.folders:
            folder = True
        elif os.path.lexists(full):
            return "%s is not tracked by git, so GitHub does not have it" % resolved
        else:
            return "%s does not exist" % resolved
        if folder:
            readme = posixpath.normpath(posixpath.join(resolved, "README.md"))
            if source.path.endswith(".md") and readme in self.tracked:
                self.edges.setdefault(source.path, set()).add(readme)
        elif source.path.endswith(".md") and resolved.endswith(".md"):
            self.edges.setdefault(source.path, set()).add(resolved)
        if not fragment or fragment.lower() == "top":
            return None
        if folder:
            if readme not in self.tracked:
                return "%s has no README.md for #%s to name a heading of" % (resolved, fragment)
            resolved = readme
        target = self.document(resolved)
        if target.anchors is None or "plain=1" in query.split("&"):
            numbers = LINE_ANCHOR_RE.fullmatch(fragment)
            if numbers and max(int(number) for number in numbers.groups() if number) > target.lines:
                return "%s has %d lines" % (resolved, target.lines)
            return None
        if fragment in target.anchors:
            return None
        guess = difflib.get_close_matches(fragment, sorted(target.anchors), n=1)
        return 'no heading or id "%s" in %s%s' % (
            fragment,
            "this file" if resolved == source.path else resolved,
            " (did you mean #%s?)" % guess[0] if guess else "",
        )

    def unlinked(self, markdown):
        """The listed Markdown files that README.md does not reach, directly or through other documents."""
        reached, queue = set(), [START] if START in self.tracked else []
        while queue:
            path = queue.pop()
            if path not in reached:
                reached.add(path)
                queue.extend(self.edges.get(path, ()))
        return [path for path in markdown if listed(path) and path not in reached]


def check(root, tracked):
    """Check every link of the tracked Markdown files and of the manuals. tracked lists every file git
    tracks, as repository-relative paths with forward slashes."""
    tracked = sorted(set(tracked))
    checker = Checker(root, tracked)
    markdown = [path for path in tracked if path.endswith(".md")]
    manuals = [path for path in tracked if fnmatch.fnmatchcase(path, MANUALS)]
    for path in markdown + manuals:
        checker.check_file(path)
    problems = sorted(checker.problems, key=lambda problem: (problem[0], problem[1]))
    return Report(len(markdown) + len(manuals), checker.links, problems, checker.unlinked(markdown))


# ---------------------------------------------------------------------------
# git and the command line
# ---------------------------------------------------------------------------


def run_git(root, *args):
    """git's standard output for args, run in root; the unit tests replace this function."""
    try:
        done = subprocess.run(["git", "-C", root, *args], capture_output=True, check=False)
    except OSError as err:
        raise UsageError("cannot run git: %s" % err) from err
    if done.returncode != 0:
        error = done.stderr.decode("utf-8", "replace").strip()
        raise UsageError("git %s failed in %s: %s" % (" ".join(args), root, error))
    return done.stdout.decode("utf-8", "surrogateescape")


def tracked_files(root):
    """Every file git tracks in the work tree whose top is root, as repository-relative paths."""
    top = run_git(root, "rev-parse", "--show-toplevel").strip()
    if os.path.realpath(top) != os.path.realpath(root):
        raise UsageError("%s is not the top of a git work tree (that is %s)" % (root, top))
    return sorted(path for path in run_git(root, "ls-files", "-z").split("\0") if path)


def plural(count, noun):
    return "%d %s%s" % (count, noun, "" if count == 1 else "s")


def directory(text):
    if not os.path.isdir(text):
        raise argparse.ArgumentTypeError("not a directory: %r" % text)
    return text


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="check_links.py",
        description="Check the links of every Markdown file git tracks and of the three Documentation tabs "
        "(issue #263): relative targets and links to this repository on github.com must name a tracked file or "
        "folder, and their #anchors a heading or id. Code blocks, code spans and HTML comments hold no links.",
        epilog="Output: FILE:LINE: message for every broken link, then 'links: N files, M links, K problems'. "
        "Exit codes: 0 no broken link, 1 broken links, 2 usage; --unlinked never changes the exit status.",
    )
    parser.add_argument(
        "--root",
        type=directory,
        default=ROOT,
        metavar="DIR",
        help="the top of the git work tree to check (default: the repository this script is in)",
    )
    parser.add_argument(
        "--unlinked",
        action="store_true",
        help="also list, as 'FILE: not reachable from README.md', the Markdown files at the top level and "
        "under docs/ that README.md does not reach (docs/reviews/ and .github/ are exempt)",
    )
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        tracked = tracked_files(args.root)
    except UsageError as err:
        print("check_links.py: error: %s" % err, file=sys.stderr)
        return EXIT_USAGE
    report = check(args.root, tracked)
    for path, line, message in report.problems:
        print("%s:%d: %s" % (path, line, message))
    if args.unlinked:
        for path in report.unlinked:
            print("%s: not reachable from %s" % (path, START))
    print(
        "links: %s, %s, %s"
        % (plural(report.files, "file"), plural(report.links, "link"), plural(len(report.problems), "problem"))
    )
    return EXIT_BROKEN if report.problems else EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
