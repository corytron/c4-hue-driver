"""Unit tests for tools/check_doc_tabs.py (security review 2026-11-13, I-7): nothing in a
Documentation tab runs, or reaches past the package.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import check_doc_tabs  # noqa: E402

HEAD = (
    '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">\n'
    '<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">\n'
    '<meta http-equiv="X-UA-Compatible" content="IE=edge">\n'
    '<style type="text/css">body { color: #222; } h1 { background: url(img/bar.png); }</style>\n'
    "</head><body>\n"
)
TAIL = "</body></html>\n"


def findings(body):
    """The reasons check_doc_tabs gives for a page holding `body`."""
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as handle:
        handle.write(HEAD + body + TAIL)
    try:
        return [reason for _, _, reason in check_doc_tabs.check_file(handle.name)[1]]
    finally:
        os.unlink(handle.name)


class CheckTest(unittest.TestCase):
    def test_what_the_manuals_hold_today_passes(self):
        body = (
            '<h1 id="top">Hue Bridge</h1><!-- a plain comment -->\n'
            '<p><a href="#setup">Setup</a>, <a href="#top">top</a>, <a name="x"></a></p>\n'
            '<img src="img/bridge-properties.png" alt="Properties" width="600">\n'
            '<a href="https://github.com/octo/hue/issues/1">an issue</a> <a href="mailto:x@example.com">mail</a>\n'
            '<a href="img/connections.png">a picture</a> <div style="margin: 0 4px; color: red">x</div>\n'
            "<table><tr><td><code>on</code> onclick text, script text, url(x)</td></tr></table>\n"
        )
        self.assertEqual([], findings(body))

    def test_the_repository_tabs_pass(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(0, check_doc_tabs.main([]), out.getvalue())
        self.assertIn("nothing runs or reaches outside the package", out.getvalue())

    def test_active_elements_are_refused(self):
        for body, reason in (
            ("<script>alert(1)</script>", "a <script> element"),
            ("<SCRIPT SRC=img/x.js></SCRIPT>", "a <script> element"),
            ('<iframe src="img/a.html"></iframe>', "a <iframe> element"),
            ('<object data="img/x.swf"></object>', "a <object> element"),
            ('<embed src="img/x.swf">', "a <embed> element"),
            ('<applet code="x"></applet>', "a <applet> element"),
            ('<form action="img/x"></form>', "a <form> element"),
            ('<base href="https://example.com/">', "a <base> element"),
            ('<link rel="stylesheet" href="img/x.css">', "a <link> element"),
            ('<frameset><frame src="x.html"></frameset>', "a <frameset> element"),
            ('<meta http-equiv="refresh" content="0;url=https://example.com/">', 'a <meta http-equiv="refresh">'),
            ('<meta http-equiv=" Refresh " content="5">', 'a <meta http-equiv="Refresh">'),
        ):
            with self.subTest(body=body):
                self.assertIn(reason, findings(body))

    def test_event_handlers_are_refused(self):
        for body in (
            '<img src="img/a.png" onerror="alert(1)">',
            '<p onClick="x()">x</p>',
            "<body onload=x()>",
            '<a href="#x" onmouseover="x()">x</a>',
            "<br onfocus=x />",
        ):
            with self.subTest(body=body):
                self.assertTrue(any(r.startswith("an event handler attribute on") for r in findings(body)), body)

    def test_fetched_addresses_must_be_relative_paths_inside_www(self):
        for body in (
            '<img src="https://example.com/pixel.png">',
            '<img src="http://example.com/pixel.png">',
            '<img src="//example.com/pixel.png">',
            '<img src="/etc/passwd">',
            '<img src="\\\\host\\share\\x.png">',
            '<img src="img\\x.png">',
            '<img src="../../x.png">',
            '<img src="img/../../x.png">',
            '<img src="file:///C:/x.png">',
            '<img src="data:image/png;base64,AAAA">',
            '<img src=" java\nscript:alert(1)">',
            '<img src="&#106;avascript:alert(1)">',
            '<img src="">',
            '<img srcset="img/a.png 1x, https://example.com/b.png 2x">',
            '<table background="https://example.com/x.png"><tr><td>x</td></tr></table>',
            '<video poster="https://example.com/x.png"></video>',
            '<svg><image href="https://example.com/x.png"/></svg>',
            '<svg><use xlink:href="https://example.com/x.svg#a"/></svg>',
            '<a href="#x" ping="https://example.com/">x</a>',
        ):
            with self.subTest(body=body):
                found = findings(body)
                self.assertEqual(1, len(found), found)
                self.assertRegex(found[0], r"= on <\w+> is ")

    def test_links_may_leave_but_never_run(self):
        for body, reason in (
            ('<a href="javascript:alert(1)">x</a>', "a javascript: link"),
            ('<a href="JaVaScRiPt:alert(1)">x</a>', "a javascript: link"),
            ('<a href="&#x6A;avascript:x">x</a>', "a javascript: link"),
            ('<a href=" vbscript:x">x</a>', "a vbscript: link"),
            ('<a href="data:text/html,x">x</a>', "a data: link"),
            ('<a href="file:///C:/Windows">x</a>', "a file: link"),
            ('<a href="\\\\host\\share">x</a>', "a UNC or protocol-relative link"),
            ('<a href="//example.com/">x</a>', "a UNC or protocol-relative link"),
            ('<area href="ms-settings:x">', "a ms-settings: link"),
        ):
            with self.subTest(body=body):
                self.assertTrue(any(reason in r for r in findings(body)), findings(body))

    def test_styles_fetch_nothing_and_run_nothing(self):
        for css in (
            "body { background: url(https://example.com/x.png) }",
            "body { background: url('//example.com/x.png') }",
            'body { background: url( "file:///C:/x" ) }',
            "@import 'img/x.css';",
            "body { width: expression(alert(1)) }",
            "body { width: expr/**/ession(alert(1)) }",
            "body { behavior: url(img/x.htc) }",
            "body { -moz-binding: url(img/x.xml#a) }",
            "body { background: u\\72l(https://example.com/x.png) }",
            "body { background: url(\\68ttps://example.com/x.png) }",
        ):
            with self.subTest(css=css):
                self.assertTrue(findings("<style>%s</style>" % css), css)
                self.assertTrue(findings('<p style="%s">x</p>' % css.replace('"', "'")), css)

    def test_conditional_comments_and_processing_instructions_are_refused(self):
        for body in (
            "<!--[if IE]><p>x</p><![endif]-->",
            "<!--[if lt IE 9]>x<![endif]-->",
            "<![if !IE]><p>x</p><![endif]>",
            '<?xml-stylesheet href="https://example.com/x.css"?>',
        ):
            with self.subTest(body=body):
                found = findings(body)
                self.assertTrue(found, body)

    def test_findings_name_the_line_and_column(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "documentation.html")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("<html><body>\n<p>fine</p>\n  <script>x</script>\n</body></html>\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(1, check_doc_tabs.main([path]))
        self.assertIn("documentation.html:3:3: a <script> element", out.getvalue())
        self.assertIn("1 finding(s) in 1 Documentation tab(s)", out.getvalue())

    def test_parallel_and_serial_runs_agree_and_keep_the_file_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for index in range(6):
                path = os.path.join(tmp, "tab%d.html" % index)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(HEAD + ("<script>%d</script>" % index if index % 2 else "<p>ok</p>") + TAIL)
                paths.append(path)
            serial = check_doc_tabs.check_all(paths, 1)
            parallel = check_doc_tabs.check_all(paths, 4)
        self.assertEqual(serial, parallel)
        self.assertEqual(paths, [path for path, _ in parallel])
        self.assertEqual([0, 1, 0, 1, 0, 1], [len(found) for _, found in parallel])

    def test_jobs(self):
        with mock.patch.dict(os.environ, {"JOBS": "3"}):
            self.assertEqual(3, check_doc_tabs.jobs())
        with mock.patch.dict(os.environ, {"JOBS": "0"}), self.assertRaises(SystemExit):
            check_doc_tabs.jobs()

    def test_an_unreadable_or_unclosed_file_is_a_finding(self):
        _, found = check_doc_tabs.check_file("/nonexistent/documentation.html")
        self.assertIn("cannot read it", found[0][2])
        self.assertIn("a <style> element that is never closed", findings("<style>body { color: red }"))


if __name__ == "__main__":
    unittest.main()
