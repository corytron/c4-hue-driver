"""Unit tests for tools/code_scanning_issue.py: no network, gh and the clock replaced by fakes.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import json
import os
import re
import sys
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import code_scanning_issue as csi  # noqa: E402

REPO = "octo/hue"
OLD = ["1" * 40, "2" * 40, "3" * 40, "4" * 40]  # older commits on main, newest first
NEW = "a" * 40  # the commit just merged
NEWER = "b" * 40  # a later push
WORKFLOW = os.path.join(os.path.dirname(TOOLS), ".github", "workflows", "code-scanning-triage.yml")

KINDS = [
    ("CodeQL", "/language:python"),
    ("CodeQL", "/language:actions"),
    ("Scorecard", "supply-chain/local"),
    ("Scorecard", "supply-chain/online-scm"),
]


def alert(number, tool="CodeQL", rule="py/path-injection", sev="high", path="tools/collect.py", line=42, state="open"):
    return {
        "number": number,
        "state": state,
        "tool": {"name": tool},
        "rule": {"id": rule, "security_severity_level": sev},
        "most_recent_instance": {"location": {"path": path, "start_line": line}},
        "html_url": "https://github.com/%s/security/code-scanning/%d" % (REPO, number),
    }


def scorecard(number, rule="CodeReviewID", sev="high"):
    return alert(number, tool="Scorecard", rule=rule, sev=sev, path="no file associated with this alert", line=1)


def analyses_of(sha, kinds=KINDS):
    return [{"commit_sha": sha, "tool": {"name": tool}, "category": category} for tool, category in kinds]


def history():
    """Analyses of the three commits before NEW, newest first, as the API lists them."""
    return analyses_of(OLD[0]) + analyses_of(OLD[1]) + analyses_of(OLD[2])


def gh_error(status, message="failed"):
    return csi.GhError(["api"], 1, "", "gh: %s (HTTP %d)" % (message, status))


class FakeGh:
    """The GitHub the script sees: a repository with code scanning, alerts and issues.
    Every write to a closed issue fails the test: closed issues are never touched."""

    def __init__(self):
        self.default_branch = "main"
        self.heads = [NEW]  # successive heads of main; the last one repeats
        self.analysis_pages = [history() + analyses_of(NEW)]  # successive answers; the last repeats
        self.alerts = []
        self.details = {}  # number -> alert in any state, for GET alerts/N
        self.alerts_error = None
        self.dependabot = []
        self.secret = gh_error(403, "Resource not accessible by integration")
        self.issues = []
        self.comments = {}
        self.calls = []
        self.analysis_calls = 0

    # -- helpers for the tests
    def add_issue(self, number, title, body, state="open", labels=("security",)):
        self.issues.append(
            {
                "number": number,
                "title": title,
                "body": body,
                "state": state,
                "labels": list(labels),
                "url": "https://github.com/%s/issues/%d" % (REPO, number),
            }
        )

    def issue(self, number):
        return [i for i in self.issues if i["number"] == number][0]

    def writes(self):
        return [(a, i) for a, i in self.calls if a[0] == "issue" and a[1] in ("create", "edit", "comment", "close")]

    # -- gh
    def __call__(self, args, input=None):
        args = list(args)
        self.calls.append((args, input))
        if args[0] == "repo":
            return json.dumps({"nameWithOwner": REPO})
        if args[0] == "api":
            assert len(args) == 2, "only GETs: %r" % (args,)
            return json.dumps(self.api(args[1]))
        if args[0] == "issue":
            return self.issue_command(args[1:], input)
        raise AssertionError("unexpected gh call %r" % (args,))

    def api(self, path):
        base, _, query = path.partition("?")
        if base == "repos/%s" % REPO:
            return {"default_branch": self.default_branch}
        if base == "repos/%s/branches/main" % REPO:
            head = self.heads[0] if len(self.heads) == 1 else self.heads.pop(0)
            return {"commit": {"sha": head}}
        if base == "repos/%s/code-scanning/analyses" % REPO:
            assert "ref=refs/heads/main" in query, query
            self.analysis_calls += 1
            page = self.analysis_pages[0] if len(self.analysis_pages) == 1 else self.analysis_pages.pop(0)
            if isinstance(page, Exception):
                raise page
            return page
        if base == "repos/%s/code-scanning/alerts" % REPO:
            assert "state=open" in query and "ref=refs/heads/main" in query and "per_page=100" in query, query
            if self.alerts_error:
                raise self.alerts_error
            page = int(re.search(r"page=(\d+)$", query).group(1))
            return self.alerts[(page - 1) * 100 : page * 100]
        match = re.match(r"^repos/%s/code-scanning/alerts/(\d+)$" % REPO, base)
        if match:
            number = int(match.group(1))
            if number not in self.details:
                raise gh_error(404, "Not Found")
            return self.details[number]
        if base == "repos/%s/dependabot/alerts" % REPO:
            if isinstance(self.dependabot, Exception):
                raise self.dependabot
            return self.dependabot
        if base == "repos/%s/secret-scanning/alerts" % REPO:
            if isinstance(self.secret, Exception):
                raise self.secret
            return self.secret
        raise AssertionError("unexpected path %s" % path)

    def issue_command(self, args, input):
        verb = args[0]
        if verb == "list":
            assert args[1:] == [
                "--repo",
                REPO,
                "--label",
                "security",
                "--state",
                "open",
                "--json",
                "number,title,body,url",
                "--limit",
                "100",
            ], args
            listed = [i for i in self.issues if i["state"] == "open" and "security" in i["labels"]]
            return json.dumps([{k: i[k] for k in ("number", "title", "body", "url")} for i in listed])
        if verb == "create":
            assert args[1:3] == ["--repo", REPO] and "--label" in args and args[args.index("--label") + 1] == "security"
            number = max([i["number"] for i in self.issues] + [99]) + 1
            self.add_issue(number, args[args.index("--title") + 1], input)
            return "https://github.com/%s/issues/%d\n" % (REPO, number)
        number = int(args[1])
        issue = self.issue(number)
        assert issue["state"] == "open", "%s on closed issue #%d" % (verb, number)
        assert args[2:4] == ["--repo", REPO], args
        if verb == "edit":
            issue["title"] = args[args.index("--title") + 1]
            issue["body"] = input
            return ""
        if verb == "comment":
            self.comments.setdefault(number, []).append(input)
            return ""
        if verb == "close":
            issue["state"] = "closed"
            self.comments.setdefault(number, []).append(args[args.index("--comment") + 1])
            return ""
        raise AssertionError("unexpected issue command %r" % (args,))


class Clock:
    def __init__(self):
        self.t = 1000.0
        self.sleeps = []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += seconds


class Base(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGh()
        self.clock = Clock()
        saved = (csi.run_gh, csi.now, csi.sleep)
        csi.run_gh, csi.now, csi.sleep = self.gh, self.clock.now, self.clock.sleep
        self.addCleanup(self.restore, saved)

    def restore(self, saved):
        csi.run_gh, csi.now, csi.sleep = saved

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = csi.main(["--repo", REPO] + list(argv))
        return code, out.getvalue(), err.getvalue()

    def ours(self):
        return [i for i in self.gh.issues if csi.is_ours(i)]


class IssueTest(Base):
    def test_create_when_alerts_and_no_issue(self):
        self.gh.alerts = [alert(2, line=43), scorecard(6), alert(1)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        writes = self.gh.writes()
        self.assertEqual([w[0][1] for w in writes], ["create"])
        issue = self.gh.issue(100)
        self.assertEqual(issue["title"], "Code scanning: 3 open alerts on main")
        self.assertEqual(issue["labels"], ["security"])
        body = issue["body"]
        self.assertIn("<!-- code-scanning-issue alerts=1,2,6 -->", body)
        self.assertIn("| Alert | Tool | Rule | Severity | File:line | Link |", body)
        self.assertIn(
            "| #1 | CodeQL | `py/path-injection` | high | `tools/collect.py:42` | "
            "[view](https://github.com/octo/hue/security/code-scanning/1) |",
            body,
        )
        self.assertIn("| #6 | Scorecard | `CodeReviewID` | high | (no file) |", body)
        self.assertIn("Dependabot: 0 open (https://github.com/octo/hue/security/dependabot)", body)
        self.assertIn("Secret scanning: not readable with this token (HTTP 403)", body)
        self.assertIn("dismissed_reason=", body)
        self.assertEqual(self.gh.comments, {})
        self.assertIn("opened issue https://github.com/octo/hue/issues/100", out)

    def test_title_singular(self):
        self.assertEqual(csi.issue_title(1, "main"), "Code scanning: 1 open alert on main")
        self.assertEqual(csi.issue_title(0, "main"), "Code scanning: 0 open alerts on main")

    def test_unchanged_does_nothing(self):
        self.gh.alerts = [alert(1), alert(2, line=43)]
        self.assertEqual(self.run_main()[0], 0)
        before = len(self.gh.writes())
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.gh.writes()), before)
        self.assertIn("issue #100 is current", out)

    def test_update_when_the_set_changes(self):
        self.gh.alerts = [alert(1), alert(2, line=43), scorecard(4, "PinnedDependenciesID", "medium")]
        self.run_main()
        self.gh.alerts = [alert(2, line=43), alert(9, rule="py/clear-text-logging-sensitive-data", path="tools/x.py")]
        self.gh.details = {
            1: alert(1, state="fixed"),
            4: dict(scorecard(4, "PinnedDependenciesID"), state="dismissed", dismissed_reason="won't fix"),
        }
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        verbs = [w[0][1] for w in self.gh.writes()]
        self.assertEqual(verbs, ["create", "edit", "comment"])
        issue = self.gh.issue(100)
        self.assertEqual(issue["title"], "Code scanning: 2 open alerts on main")
        self.assertIn("alerts=2,9 -->", issue["body"])
        comment = self.gh.comments[100][0]
        self.assertIn("changed (commit %s)" % NEW[:12], comment)
        self.assertIn(
            "- new: [#9](https://github.com/octo/hue/security/code-scanning/9) CodeQL "
            "`py/clear-text-logging-sensitive-data` (high) at `tools/x.py:42`",
            comment,
        )
        self.assertIn("- gone: [#1](https://github.com/octo/hue/security/code-scanning/1) CodeQL", comment)
        self.assertIn("`py/path-injection`: fixed", comment)
        self.assertIn("`PinnedDependenciesID`: dismissed (won't fix)", comment)
        self.assertIn("Now 2 open", comment)
        self.assertIn("updated issue #100: 1 new, 2 gone", out)

    def test_gone_alert_that_cannot_be_read(self):
        self.gh.alerts = [alert(1), alert(2)]
        self.run_main()
        self.gh.alerts = [alert(2)]
        self.run_main()
        self.assertIn("- gone: #1 (no longer open)", self.gh.comments[100][0])

    def test_same_set_other_details_refreshes_without_a_comment(self):
        self.gh.alerts = [alert(1), alert(2, line=43)]
        self.run_main()
        self.gh.alerts = [alert(1), alert(2, line=50)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create", "edit"])
        self.assertIn("`tools/collect.py:50`", self.gh.issue(100)["body"])
        self.assertEqual(self.gh.comments, {})
        self.assertIn("refreshed issue #100", out)

    def test_close_when_none_remain(self):
        self.gh.alerts = [alert(1), scorecard(6)]
        self.run_main()
        self.gh.alerts = []
        self.gh.details = {1: alert(1, state="fixed")}
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        issue = self.gh.issue(100)
        self.assertEqual(issue["state"], "closed")
        comment = self.gh.comments[100][-1]
        self.assertIn("No open code scanning alerts remain on `main` (commit %s)" % NEW[:12], comment)
        self.assertIn("`py/path-injection`: fixed", comment)
        self.assertIn("- gone: #6 (no longer open)", comment)
        self.assertIn("Other alerts (counts only): Dependabot: 0 open", comment)
        self.assertIn("closed issue #100", out)
        # Nothing left to do on the next run, and the closed issue is not touched again.
        before = len(self.gh.writes())
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.gh.writes()), before)
        self.assertIn("nothing to do", out)

    def test_no_alerts_and_no_issue_writes_nothing(self):
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.gh.writes(), [])

    def test_never_a_second_issue(self):
        self.gh.add_issue(10, "Code scanning: 1 open alert on main", "<!-- code-scanning-issue alerts=1 -->\n")
        self.gh.add_issue(11, "Code scanning: 1 open alert on main", "<!-- code-scanning-issue alerts=1 -->\n")
        self.gh.alerts = [alert(1), alert(2)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        writes = self.gh.writes()
        self.assertEqual([w[0][1] for w in writes], ["edit", "comment"])
        self.assertTrue(all(w[0][2] == "10" for w in writes), writes)
        self.assertIn("a second open code scanning issue #11 is left alone", out)
        self.assertEqual(self.gh.issue(11)["body"], "<!-- code-scanning-issue alerts=1 -->\n")
        # A second run with the same alerts changes nothing, and still opens nothing.
        before = len(self.gh.writes())
        self.run_main()
        self.assertEqual(len(self.gh.writes()), before)

    def test_closed_issues_are_never_touched(self):
        closed_body = "<!-- code-scanning-issue alerts=1 -->\nold table\n"
        self.gh.add_issue(5, "Code scanning: 1 open alert on main", closed_body, state="closed")
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create"])
        closed = self.gh.issue(5)
        self.assertEqual((closed["state"], closed["body"]), ("closed", closed_body))
        self.assertNotIn(5, self.gh.comments)
        # Closing the new one when the alert goes leaves the old one as it was.
        self.gh.alerts = []
        self.run_main()
        self.assertEqual(self.gh.issue(5)["body"], closed_body)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create", "close"])

    def test_other_security_issues_are_left_alone(self):
        self.gh.add_issue(52, "Dev loop security: authenticate the dev server", "No marker here.")
        self.gh.add_issue(53, "Code scanning misses the Lua driver", "Not a generated title either.")
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create"])
        self.assertEqual(self.gh.issue(52)["body"], "No marker here.")
        # And with no alerts they are not closed either.
        self.gh.alerts = []
        self.run_main()
        self.assertEqual(self.gh.issue(52)["state"], "open")
        self.assertEqual(self.gh.issue(53)["state"], "open")

    def test_an_issue_without_its_marker_is_still_recognised_by_its_title(self):
        self.gh.add_issue(20, "Code scanning: 3 open alerts on main", "Rewritten by hand.")
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["edit", "comment"])
        self.assertIn("- new: [#1]", self.gh.comments[20][0])

    def test_previous_numbers_falls_back_to_the_links(self):
        body = (
            "| #3 | x | [view](https://github.com/octo/hue/security/code-scanning/3) |\nsee /security/code-scanning\n"
        )
        self.assertEqual(csi.previous_numbers(body), {3})
        self.assertEqual(csi.previous_numbers("<!-- code-scanning-issue alerts= -->"), set())
        self.assertEqual(csi.previous_numbers(None), set())

    def test_check_changes_nothing(self):
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main("--check")
        self.assertEqual(code, 0, err)
        self.assertIn('would open an issue labelled security: "Code scanning: 1 open alert on main"', out)
        self.assertEqual(self.gh.writes(), [])
        self.run_main()  # now it exists
        self.gh.alerts = [alert(1), alert(2)]
        code, out, err = self.run_main("--check")
        self.assertIn("would update issue #100", out)
        self.gh.alerts = []
        code, out, err = self.run_main("--check")
        self.assertIn("would close issue #100", out)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create"])
        self.assertEqual(self.gh.issue(100)["state"], "open")

    def test_counts_when_the_token_reads_them(self):
        self.gh.dependabot = [{"number": 1}, {"number": 2}]
        self.gh.secret = [{"number": 1}]
        self.gh.alerts = [alert(1)]
        self.run_main()
        body = self.gh.issue(100)["body"]
        self.assertIn("Dependabot: 2 open", body)
        self.assertIn("Secret scanning: 1 open (https://github.com/octo/hue/security/secret-scanning)", body)

    def test_unreadable_counts_do_not_fail_the_run(self):
        self.gh.dependabot = gh_error(403, "Resource not accessible by integration")
        self.gh.secret = gh_error(404, "Not Found")
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        body = self.gh.issue(100)["body"]
        self.assertIn("Dependabot: not readable with this token (HTTP 403)", body)
        self.assertIn("Secret scanning: not readable with this token (HTTP 404)", body)
        self.gh.dependabot = gh_error(502, "Bad Gateway")
        self.assertEqual(csi.other_alerts(REPO)[0], ("Dependabot", "not read (HTTP 502)"))

    def test_code_scanning_unreadable_is_an_error(self):
        self.gh.alerts_error = gh_error(403, "Resource not accessible by integration")
        code, out, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("security-events: read", err)
        self.assertEqual(self.gh.writes(), [])
        self.gh.alerts_error = gh_error(404, "no analysis found")
        code, out, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("is code scanning on?", err)

    def test_every_page_of_alerts_is_read(self):
        self.gh.alerts = [alert(n) for n in range(1, 151)]
        saved = csi.TABLE_LIMIT
        csi.TABLE_LIMIT = 5
        self.addCleanup(setattr, csi, "TABLE_LIMIT", saved)
        code, out, err = self.run_main()
        self.assertEqual(code, 0, err)
        pages = [a[1] for a, _ in self.gh.calls if a[0] == "api" and "code-scanning/alerts?" in a[1]]
        self.assertEqual([p.rsplit("page=", 1)[1] for p in pages], ["1", "2"])
        issue = self.gh.issue(100)
        self.assertEqual(issue["title"], "Code scanning: 150 open alerts on main")
        self.assertIn("… and 145 more on the Security tab.", issue["body"])
        self.assertIn("alerts=%s -->" % ",".join(str(n) for n in range(1, 151)), issue["body"])

    def test_table_cells_are_escaped_and_sorted_by_severity(self):
        alerts = csi.sort_alerts([alert(3, sev="low"), alert(1, rule="a|b", sev="medium"), alert(2, sev="critical")])
        self.assertEqual([a["number"] for a in alerts], [2, 1, 3])
        body = csi.issue_body(REPO, "main", alerts, [("Dependabot", "0 open")])
        self.assertIn("`a\\|b`", body)


class WaitTest(Base):
    def test_waits_until_every_expected_kind_has_analysed_the_commit(self):
        self.gh.analysis_pages = [
            history(),
            analyses_of(NEW, KINDS[:1]) + history(),
            analyses_of(NEW) + history(),
        ]
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main("--wait-for", NEW)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.clock.sleeps, [30, 30])
        self.assertEqual(self.gh.analysis_calls, 3)
        self.assertIn("missing CodeQL /language:actions, CodeQL /language:python, Scorecard", out)
        self.assertIn("analyses of %s: CodeQL /language:actions" % NEW[:12], out)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create"])

    def test_gives_up_after_the_timeout_and_reports_what_is_there(self):
        self.gh.analysis_pages = [history()]
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main("--wait-for", NEW, "--timeout", "100", "--interval", "30")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.clock.sleeps, [30, 30, 30, 10])
        self.assertIn("gave up waiting for the analyses of %s after 100 s" % NEW[:12], out)
        self.assertEqual([w[0][1] for w in self.gh.writes()], ["create"])

    def test_stops_and_leaves_the_issue_when_main_moved_on(self):
        self.gh.analysis_pages = [history()]
        self.gh.heads = [NEWER]
        self.gh.alerts = [alert(1)]
        code, out, err = self.run_main("--wait-for", NEW)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.clock.sleeps, [])
        self.assertIn("no longer the head of main (now %s)" % NEWER[:12], out)
        self.assertIn("left to the run of the newer push", out)
        self.assertFalse([a for a, _ in self.gh.calls if a[0] == "issue"])

    def test_without_history_any_analysis_of_the_commit_will_do(self):
        self.gh.analysis_pages = [gh_error(404, "no analysis found"), analyses_of(NEW, KINDS[:1])]
        code, out, err = self.run_main("--wait-for", NEW)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.clock.sleeps, [30])
        self.assertIn("missing any tool", out)

    def test_server_errors_are_retried_client_errors_are_not(self):
        self.gh.analysis_pages = [gh_error(502, "Bad Gateway"), analyses_of(NEW) + history()]
        code, out, err = self.run_main("--wait-for", NEW)
        self.assertEqual(code, 0, err)
        self.assertIn("GitHub error, retrying", out)
        self.gh.analysis_pages = [gh_error(403, "Resource not accessible by integration")]
        code, out, err = self.run_main("--wait-for", NEW)
        self.assertEqual(code, 1)
        self.assertIn("HTTP 403", err)

    def test_expected_kinds_come_from_the_three_newest_earlier_commits(self):
        stale = analyses_of(OLD[3], [("Retired", "gone")])
        analyses = analyses_of(NEW, KINDS[:1]) + history() + stale
        self.assertEqual(csi.expected_kinds(analyses, NEW), set(KINDS))

    def test_wait_for_wants_a_full_sha(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaises(SystemExit) as raised:
                csi.parse_args(["--wait-for", "HEAD"])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("40-character", err.getvalue())


class WorkflowTest(unittest.TestCase):
    def test_the_triage_workflow_runs_this_script_with_least_privilege(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("python3 tools/code_scanning_issue.py", text)
        self.assertIn("--wait-for", text)
        for permission in ("security-events: read", "issues: write", "contents: read"):
            self.assertIn(permission, text)
        self.assertNotIn("write-all", text)
        self.assertNotIn("${{ github.event", text)


if __name__ == "__main__":
    unittest.main()
