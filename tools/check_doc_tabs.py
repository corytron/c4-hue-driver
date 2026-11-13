#!/usr/bin/env python3
"""The doc-tabs check: nothing in a Documentation tab runs, or reaches past the package.

Composer shows src/<driver>/www/documentation.html in an embedded Internet Explorer control on the
dealer's Windows PC, and the controller serves everything under www/ to the LAN (security review
2026-11-13, I-7; docs/security-fixes-2026-11-design.md, #492). The tabs are static, and this check
keeps them so. In every src/*/www/*.html (or the files named on the command line) it refuses:

  - elements that run or embed something: script, iframe, frame, frameset, object, embed, applet,
    form, base, link (no stylesheet or other resource comes from outside the page), and a meta
    refresh;
  - every event-handler attribute (on...=);
  - any src, srcset, background, poster, data, codebase, action, formaction, lowsrc, dynsrc or
    xlink:href that is not a relative path inside www/ (no scheme, no leading / or \\, no ..);
  - a link (href on a or area) with a scheme other than http, https or mailto (javascript:,
    vbscript:, data:, file: ...), or a UNC path; an href anywhere else is taken as a src;
  - in a style element or attribute: url() that is not such a relative path, @import, expression(),
    behavior and -moz-binding;
  - Internet Explorer's conditional comments, which that control honours, and processing
    instructions.

Usage: tools/check_doc_tabs.py [FILE.html ...]
Exit 0 when every tab is clean, 1 with one "path:line:column: reason" line per finding.
JOBS (environment) caps how many files are read at once (default: nproc); JOBS=1 reads them in
one process, one after the other. The output is in file order whatever JOBS is.
Standard library only.
"""

import concurrent.futures
import glob
import os
import re
import sys
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATTERN = os.path.join("src", "*", "www", "*.html")

FORBIDDEN_ELEMENTS = {
    "script",
    "iframe",
    "frame",
    "frameset",
    "object",
    "embed",
    "applet",
    "form",
    "base",
    "link",
    "portal",
}
# Attributes whose value the browser fetches, or submits to: a relative path inside www/ only.
RESOURCE_ATTRIBUTES = {
    "src",
    "srcset",
    "background",
    "poster",
    "data",
    "codebase",
    "action",
    "formaction",
    "lowsrc",
    "dynsrc",
    "xlink:href",
    "manifest",
    "ping",
    "archive",
    "classid",
}
LINK_SCHEMES = {"http", "https", "mailto"}
SCHEME = re.compile(r"^([a-zA-Z][a-zA-Z0-9+.-]*):")
# What browsers drop from a URL before reading its scheme: ASCII white space and controls.
URL_NOISE = re.compile(r"[\x00-\x20\x7f]+")
CSS_URL = re.compile(r"url\s*\(\s*(['\"]?)(.*?)\1\s*\)", re.IGNORECASE | re.DOTALL)
CSS_FORBIDDEN = (
    (re.compile(r"@import", re.IGNORECASE), "@import in a style"),
    (re.compile(r"expression\s*\(", re.IGNORECASE), "expression() in a style"),
    (re.compile(r"(?<![a-z-])behavior\s*:", re.IGNORECASE), "an IE behavior in a style"),
    (re.compile(r"-moz-binding", re.IGNORECASE), "-moz-binding in a style"),
)
CSS_ESCAPE = re.compile(r"\\([0-9a-fA-F]{1,6}\s?|.)", re.DOTALL)


def css_text(css):
    """CSS with its comments removed and its escapes resolved. A comment goes without a trace:
    Internet Explorer read expr/**/ession( as expression(."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.DOTALL)

    def unescape(match):
        text = match.group(1)
        if re.fullmatch(r"[0-9a-fA-F]{1,6}\s?", text):
            try:
                return chr(int(text.strip(), 16))
            except (ValueError, OverflowError):
                return "\ufffd"
        return text

    return CSS_ESCAPE.sub(unescape, css)


def relative_problem(value):
    """Why a fetched URL is not a relative path inside www/, or None when it is one."""
    url = URL_NOISE.sub("", value)
    if not url:
        return "an empty address"
    if SCHEME.match(url):
        return "a URL with a scheme (%s)" % SCHEME.match(url).group(1).lower()
    if url.startswith(("/", "\\")) or "\\" in url:
        return "an absolute or Windows path"
    if ".." in re.split(r"[/?#]", url):
        return "a path out of www/ (..)"
    return None


def link_problem(value):
    """Why an href may not stay, or None: in-page and relative links, http, https and mailto pass."""
    url = URL_NOISE.sub("", value)
    if url.startswith("\\\\") or url.startswith("//") or "\\" in url:
        return "a UNC or protocol-relative link"
    match = SCHEME.match(url)
    if match and match.group(1).lower() not in LINK_SCHEMES:
        return "a %s: link" % match.group(1).lower()
    return None


def srcset_values(value):
    """The URLs of a srcset value (each candidate is "url [descriptor]")."""
    return [part.strip().split()[0] for part in value.split(",") if part.strip()]


class TabChecker(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.findings = []
        self.in_style = False

    def add(self, reason):
        line, column = self.getpos()
        self.findings.append((line, column + 1, reason))

    def check_style(self, css, where):
        css = css_text(css)
        for pattern, reason in CSS_FORBIDDEN:
            if pattern.search(css):
                self.add("%s (%s)" % (reason, where))
        for match in CSS_URL.finditer(css):
            problem = relative_problem(match.group(2))
            if problem:
                self.add("url() in %s is %s: %r" % (where, problem, match.group(2)[:80]))

    def handle_starttag(self, tag, attrs):
        self.check_tag(tag, attrs)
        if tag == "style":
            self.in_style = True

    def handle_startendtag(self, tag, attrs):
        self.check_tag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "style":
            self.in_style = False

    def check_tag(self, tag, attrs):
        if tag in FORBIDDEN_ELEMENTS:
            self.add("a <%s> element" % tag)
        values = {}
        for name, value in attrs:
            value = value or ""
            values[name] = value
            if name.startswith("on"):
                self.add("an event handler attribute %s= on <%s>" % (name, tag))
            elif name in RESOURCE_ATTRIBUTES:
                urls = srcset_values(value) if name == "srcset" else [value]
                for url in urls:
                    problem = relative_problem(url)
                    if problem:
                        self.add("%s= on <%s> is %s: %r" % (name, tag, problem, url[:80]))
            elif name == "href" and tag in ("a", "area"):
                problem = link_problem(value)
                if problem:
                    self.add("href= on <%s> is %s: %r" % (tag, problem, value[:80]))
            elif name == "href":  # an href that fetches (svg use, image): as src
                problem = relative_problem(value)
                if problem:
                    self.add("href= on <%s> is %s: %r" % (tag, problem, value[:80]))
            elif name == "style":
                self.check_style(value, "a style attribute on <%s>" % tag)
        if tag == "meta" and values.get("http-equiv", "").strip().lower() in ("refresh", "set-cookie"):
            self.add('a <meta http-equiv="%s">' % values["http-equiv"].strip())

    def handle_data(self, data):
        if self.in_style:
            self.check_style(data, "a <style> element")

    def handle_comment(self, data):
        if re.match(r"\s*\[\s*if\b", data, re.IGNORECASE) or re.search(r"<!\[\s*endif", data, re.IGNORECASE):
            self.add("an Internet Explorer conditional comment")

    def unknown_decl(self, data):
        if re.match(r"\s*(end)?if\b", data, re.IGNORECASE):
            self.add("an Internet Explorer conditional comment")

    def handle_pi(self, data):
        self.add("a processing instruction <?%s>" % data[:40])


def check_file(path):
    """(path, [(line, column, reason)]) for one file; an unreadable file is a finding."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as err:
        return path, [(1, 1, "cannot read it: %s" % err)]
    checker = TabChecker()
    checker.feed(text)
    checker.close()
    if checker.in_style:
        checker.findings.append((checker.getpos()[0], 1, "a <style> element that is never closed"))
    return path, checker.findings


def jobs():
    text = os.environ.get("JOBS")
    if text:
        if not re.fullmatch(r"[1-9][0-9]*", text):
            raise SystemExit("check_doc_tabs.py: JOBS must be a whole number from 1, not %r" % text)
        return int(text)
    return os.cpu_count() or 1


def check_all(paths, max_workers):
    """Every file's findings, in the order of paths; one process a file when max_workers > 1."""
    if max_workers <= 1 or len(paths) <= 1:
        return [check_file(path) for path in paths]
    with concurrent.futures.ProcessPoolExecutor(max_workers=min(max_workers, len(paths))) as pool:
        return list(pool.map(check_file, paths))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    paths = list(argv) or sorted(glob.glob(os.path.join(ROOT, PATTERN)))
    if not paths:
        print("check_doc_tabs.py: no %s" % PATTERN, file=sys.stderr)
        return 1
    results = check_all(paths, jobs())
    count = 0
    for path, findings in results:
        shown = os.path.relpath(path, ROOT) if os.path.isabs(path) else path
        for line, column, reason in findings:
            print("%s:%d:%d: %s" % (shown, line, column, reason))
            count += 1
    if count:
        print("check_doc_tabs.py: %d finding(s) in %d Documentation tab(s)" % (count, len(paths)))
        return 1
    print("check_doc_tabs.py: %d Documentation tab(s), nothing runs or reaches outside the package" % len(paths))
    return 0


if __name__ == "__main__":
    sys.exit(main())
