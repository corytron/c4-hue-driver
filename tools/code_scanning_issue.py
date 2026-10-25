#!/usr/bin/env python3
"""Keep one issue labelled "security" in step with the open code scanning alerts on main.

  code_scanning_issue.py [--repo OWNER/NAME] [--wait-for SHA] [--timeout SECONDS]
                         [--interval SECONDS] [--check]

The owner's rule (2026-10-25): every merge to main is scanned again (CodeQL default setup and the
Scorecard workflow run on each push to main) and whatever the scans find is addressed. This is the
follow-up .github/workflows/code-scanning-triage.yml runs after each push to main, daily and on
request. It reads the open code scanning alerts of the default branch and keeps exactly one open
issue labelled "security", titled "Code scanning: N open alert(s) on main":

  - alerts and no such issue open: the issue is created, with a table of the alerts;
  - the set of alerts changed: title and table are updated and one comment lists what is new
    and what is gone (fixed or dismissed);
  - the same set with other details (a line moved, the Dependabot count): the table is
    refreshed without a comment;
  - no alerts left: the issue is closed with a comment.

Closed issues are never reopened, edited or commented on, and a second issue is never opened (a
duplicate opened by hand is reported and left alone until no alerts remain). Other "security"
issues are not touched: the issue is recognised by the marker in its body or by its exact title.

Below the table go the open Dependabot and secret scanning alert counts when the token can read
them. A workflow's GITHUB_TOKEN reads Dependabot alerts with `vulnerability-alerts: read` and can
never read secret scanning alerts; what cannot be read is reported as "not readable with this
token" and does not fail the run.

--wait-for SHA first polls the code scanning analyses of the default branch until every tool and
category that analysed the recent commits there (CodeQL's languages, Scorecard's categories) has
an analysis of SHA, so the issue reflects the scan of the merge just made. When SHA stops being
the head of the branch, the run ends without touching the issue (the newer push has its own run);
after --timeout seconds (default 1800) it stops waiting and reports what is there.

--check changes nothing: it prints the alerts and what it would do to the issue.

Standard library only; GitHub through `gh` (gh api, gh issue), every call via run_gh() so the
unit tests can replace it. Exit codes: 0 done (whatever the alerts), 1 error, 2 usage.
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse

EXIT_OK, EXIT_ERROR = 0, 1

LABEL = "security"
TITLE_RE = re.compile(r"^Code scanning: \d+ open alerts? on \S+$")
MARKER_RE = re.compile(r"<!-- code-scanning-issue alerts=([0-9,]*) -->")
ALERT_LINK_RE = re.compile(r"/security/code-scanning/(\d+)\b")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PER_PAGE = 100
TABLE_LIMIT = 200  # rows; the issue body is capped at 65536 characters
GONE_LOOKUP_LIMIT = 20  # gone alerts whose state (fixed, dismissed) is looked up for the comment
RECENT_COMMITS = 3  # earlier commits whose analyses say which tools and categories to expect
DEFAULT_TIMEOUT = 1800
DEFAULT_INTERVAL = 30
NO_FILE = "no file associated with this alert"  # Scorecard's location for repository-wide checks
SEVERITY_RANK = {"critical": 0, "high": 1, "error": 1, "medium": 2, "warning": 2, "low": 3, "note": 3}
DISMISS_EXAMPLE = (
    'gh api -X PATCH repos/%s/code-scanning/alerts/N -f state=dismissed -f dismissed_reason="won\'t fix" '
    '-f dismissed_comment="why"'
)


class TriageError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


class GhError(TriageError):
    """gh exited non-zero. http_status is the code gh names on stderr ("HTTP 403"), or None."""

    def __init__(self, args, returncode, stdout, stderr):
        self.gh_args = list(args)
        self.stderr = stderr or ""
        match = re.search(r"HTTP (\d{3})", self.stderr)
        self.http_status = int(match.group(1)) if match else None
        detail = self.stderr.strip() or (stdout or "").strip()[:300] or "exit %d" % returncode
        super().__init__("gh %s failed: %s" % (" ".join(self.gh_args[:3]), detail))


# ---------------------------------------------------------------------------
# GitHub, through run_gh only; time, through now() and sleep() (the tests replace all three)
# ---------------------------------------------------------------------------


def run_gh(args, input=None):
    """The one place that runs gh. Returns stdout; raises GhError when gh exits non-zero."""
    try:
        proc = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    except FileNotFoundError:
        raise TriageError("gh is not installed or not on PATH") from None
    if proc.returncode != 0:
        raise GhError(args, proc.returncode, proc.stdout, proc.stderr)
    return proc.stdout


def now():
    return time.monotonic()


def sleep(seconds):
    time.sleep(seconds)


def api(path):
    """One REST GET; the decoded JSON reply, or None for an empty one."""
    out = run_gh(["api", path])
    if not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError as err:
        raise TriageError("gh api %s returned something that is not JSON (%s)" % (path, err)) from err


def resolve_repo(spec):
    """OWNER/NAME from --repo or from the checkout gh sees."""
    if spec:
        parts = spec.split("/")
        if len(parts) != 2 or not all(parts):
            raise TriageError("--repo wants OWNER/NAME, got %r" % spec)
        return spec
    return json.loads(run_gh(["repo", "view", "--json", "nameWithOwner"]))["nameWithOwner"]


def default_branch(repo):
    return (api("repos/%s" % repo) or {}).get("default_branch") or "main"


def branch_head(repo, branch):
    info = api("repos/%s/branches/%s" % (repo, urllib.parse.quote(branch, safe=""))) or {}
    return (info.get("commit") or {}).get("sha")


# ---------------------------------------------------------------------------
# Analyses: waiting for the scans of one commit
# ---------------------------------------------------------------------------


def list_analyses(repo, ref):
    """The newest analyses of ref, newest first (one page: the last pushes' worth); [] before the first."""
    path = "repos/%s/code-scanning/analyses?ref=%s&per_page=%d" % (repo, urllib.parse.quote(ref, safe="/"), PER_PAGE)
    try:
        return api(path) or []
    except GhError as err:
        if err.http_status == 404:  # "no analysis found"
            return []
        raise


def analysis_kind(analysis):
    """(tool, category): one stream of analyses, such as ("CodeQL", "/language:python")."""
    return ((analysis.get("tool") or {}).get("name") or "?", analysis.get("category") or "")


def expected_kinds(analyses, sha):
    """The kinds that analysed the RECENT_COMMITS newest commits other than sha."""
    commits = []
    for analysis in analyses:
        commit = analysis.get("commit_sha")
        if commit and commit != sha and commit not in commits:
            commits.append(commit)
            if len(commits) == RECENT_COMMITS:
                break
    return {analysis_kind(analysis) for analysis in analyses if analysis.get("commit_sha") in commits}


def describe_kinds(kinds):
    return ", ".join(("%s %s" % kind).strip() for kind in sorted(kinds)) or "none"


READY, TIMED_OUT, SUPERSEDED = "ready", "timed out", "superseded"


def wait_for_analyses(repo, branch, ref, sha, timeout, interval):
    """Poll until every expected kind has an analysis of sha (any analysis, when the branch has no
    history yet): READY. SUPERSEDED when sha stopped being the head of the branch (the newer push
    has its own run), TIMED_OUT when the time ran out. A GitHub error of 500 or above, or one
    without a status (no network), is retried until then; any other error is raised."""
    deadline = now() + timeout
    while True:
        try:
            analyses = list_analyses(repo, ref)
            expected = expected_kinds(analyses, sha)
            done = {analysis_kind(a) for a in analyses if a.get("commit_sha") == sha}
            missing = expected - done if expected else (set() if done else {("any tool", "")})
            if not missing:
                print("analyses of %s: %s" % (sha[:12], describe_kinds(done)))
                return READY
            head = branch_head(repo, branch)
            if head and head != sha:
                print("%s is no longer the head of %s (now %s)" % (sha[:12], branch, head[:12]))
                return SUPERSEDED
            waiting = "missing %s" % describe_kinds(missing)
        except GhError as err:
            if err.http_status is not None and err.http_status < 500:
                raise
            waiting = "GitHub error, retrying: %s" % err
        left = deadline - now()
        if left <= 0:
            print("gave up waiting for the analyses of %s after %d s (%s)" % (sha[:12], timeout, waiting))
            return TIMED_OUT
        print("waiting for the analyses of %s: %s; %d s left" % (sha[:12], waiting, left), flush=True)
        sleep(min(interval, left))


# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------


def open_alerts(repo, ref):
    """Every open code scanning alert of ref, all pages."""
    alerts, page = [], 1
    while True:
        path = "repos/%s/code-scanning/alerts?state=open&ref=%s&per_page=%d&page=%d" % (
            repo,
            urllib.parse.quote(ref, safe="/"),
            PER_PAGE,
            page,
        )
        try:
            batch = api(path) or []
        except GhError as err:
            if err.http_status in (401, 403):
                raise TriageError(
                    "the token cannot read the code scanning alerts of %s (HTTP %d): a workflow needs "
                    "`security-events: read`, a personal token the repo or security_events scope"
                    % (repo, err.http_status)
                ) from err
            if err.http_status == 404:
                raise TriageError(
                    "no code scanning analysis of %s in %s (HTTP 404): is code scanning on?" % (ref, repo)
                ) from err
            raise
        alerts.extend(batch)
        if len(batch) < PER_PAGE:
            return alerts
        page += 1


def severity(alert):
    rule = alert.get("rule") or {}
    return rule.get("security_severity_level") or rule.get("severity") or "unknown"


def tool_name(alert):
    return (alert.get("tool") or {}).get("name") or "?"


def rule_id(alert):
    return (alert.get("rule") or {}).get("id") or "?"


def location(alert):
    """path:line, or "" when the alert has no file (Scorecard's repository-wide checks)."""
    where = (alert.get("most_recent_instance") or {}).get("location") or {}
    path = where.get("path") or ""
    if not path or path == NO_FILE:
        return ""
    return "%s:%s" % (path, where["start_line"]) if where.get("start_line") else path


def sort_alerts(alerts):
    return sorted(alerts, key=lambda a: (SEVERITY_RANK.get(severity(a), 4), tool_name(a), a["number"]))


def alert_url(repo, alert):
    return alert.get("html_url") or "https://github.com/%s/security/code-scanning/%d" % (repo, alert["number"])


def describe_alert(repo, alert, markdown=True):
    where = location(alert)
    if not markdown:
        return "#%d %s %s %s %s" % (
            alert["number"],
            tool_name(alert),
            rule_id(alert),
            severity(alert),
            where or "(no file)",
        )
    return "[#%d](%s) %s `%s` (%s)%s" % (
        alert["number"],
        alert_url(repo, alert),
        tool_name(alert),
        rule_id(alert),
        severity(alert),
        " at `%s`" % where if where else "",
    )


def describe_gone(repo, number, looked_up):
    """One line for an alert that is no longer open: how it closed, when that could be read."""
    alert = looked_up.get(number)
    if not alert:
        return "#%d (no longer open)" % number
    state = alert.get("state") or "closed"
    if state == "dismissed" and alert.get("dismissed_reason"):
        state = "dismissed (%s)" % alert["dismissed_reason"]
    return "[#%d](%s) %s `%s`: %s" % (number, alert_url(repo, alert), tool_name(alert), rule_id(alert), state)


def look_up(repo, numbers):
    """{number: alert} for up to GONE_LOOKUP_LIMIT alerts; one that cannot be read is left out."""
    found = {}
    for number in numbers[:GONE_LOOKUP_LIMIT]:
        try:
            alert = api("repos/%s/code-scanning/alerts/%d" % (repo, number))
        except GhError:
            continue
        if alert:
            found[number] = alert
    return found


# ---------------------------------------------------------------------------
# Dependabot and secret scanning: counts only, when the token can read them
# ---------------------------------------------------------------------------

OTHER_ALERTS = (
    ("Dependabot", "dependabot/alerts", "security/dependabot"),
    ("Secret scanning", "secret-scanning/alerts", "security/secret-scanning"),
)


def other_alerts(repo):
    """[(name, text)]: "N open" with the Security tab's link, or why the count is missing."""
    lines = []
    for name, endpoint, page in OTHER_ALERTS:
        try:
            items = api("repos/%s/%s?state=open&per_page=%d" % (repo, endpoint, PER_PAGE)) or []
        except GhError as err:
            if err.http_status in (401, 403, 404):
                lines.append((name, "not readable with this token (HTTP %d)" % err.http_status))
            else:
                lines.append(
                    (name, "not read (%s)" % (("HTTP %d" % err.http_status) if err.http_status else "gh failed"))
                )
            continue
        count = "%d or more" % PER_PAGE if len(items) >= PER_PAGE else "%d" % len(items)
        lines.append((name, "%s open (https://github.com/%s/%s)" % (count, repo, page)))
    return lines


# ---------------------------------------------------------------------------
# The issue
# ---------------------------------------------------------------------------


def issue_title(count, branch):
    return "Code scanning: %d open alert%s on %s" % (count, "" if count == 1 else "s", branch)


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def issue_body(repo, branch, alerts, others):
    numbers = ",".join(str(n) for n in sorted(alert["number"] for alert in alerts))
    tools = {}
    for alert in alerts:
        tools[tool_name(alert)] = tools.get(tool_name(alert), 0) + 1
    by_tool = ", ".join("%s %d" % item for item in sorted(tools.items()))
    lines = [
        "<!-- code-scanning-issue alerts=%s -->" % numbers,
        "**%d** open code scanning alert%s on `%s` (%s), as the Security tab lists them: "
        "https://github.com/%s/security/code-scanning"
        % (len(alerts), "" if len(alerts) == 1 else "s", branch, by_tool, repo),
        "",
        "| Alert | Tool | Rule | Severity | File:line | Link |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for alert in alerts[:TABLE_LIMIT]:
        where = location(alert)
        lines.append(
            "| #%d | %s | `%s` | %s | %s | [view](%s) |"
            % (
                alert["number"],
                cell(tool_name(alert)),
                cell(rule_id(alert)),
                cell(severity(alert)),
                "`%s`" % cell(where) if where else "(no file)",
                alert_url(repo, alert),
            )
        )
    if len(alerts) > TABLE_LIMIT:
        lines.append("")
        lines.append("… and %d more on the Security tab." % (len(alerts) - TABLE_LIMIT))
    lines += [
        "",
        "Other alerts (counts only): %s." % "; ".join("%s: %s" % item for item in others),
        "",
        "For each alert: a real problem gets its own issue and a pull request that fixes it; a false positive, or "
        "a check that cannot apply to this repository, is dismissed with its reason (`%s`; reasons: `false positive`, "
        "`won't fix`, `used in tests`)." % (DISMISS_EXAMPLE % repo),
        "",
        "Kept by `tools/code_scanning_issue.py` from `.github/workflows/code-scanning-triage.yml` (after every push "
        "to `%s`, daily, and on request): updated when the alerts change, closed when none remain. "
        "Edits by hand are overwritten." % branch,
    ]
    return "\n".join(lines) + "\n"


def previous_numbers(body):
    """The alert numbers the issue listed last time: from the marker, else from the alert links."""
    body = body or ""
    match = MARKER_RE.search(body)
    if match:
        return {int(n) for n in match.group(1).split(",") if n}
    return {int(n) for n in ALERT_LINK_RE.findall(body)}


def is_ours(issue):
    return bool(MARKER_RE.search(issue.get("body") or "")) or bool(TITLE_RE.match((issue.get("title") or "").strip()))


def our_open_issues(repo):
    """The open issues labelled security that this script keeps, oldest first. Closed ones never appear."""
    out = run_gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--label",
            LABEL,
            "--state",
            "open",
            "--json",
            "number,title,body,url",
            "--limit",
            "100",
        ]
    )
    issues = json.loads(out) if out.strip() else []
    return sorted((issue for issue in issues if is_ours(issue)), key=lambda issue: issue["number"])


def same_text(a, b):
    return (a or "").replace("\r\n", "\n").strip() == (b or "").replace("\r\n", "\n").strip()


def commit_note(sha):
    return " (commit %s)" % sha[:12] if sha else ""


def change_comment(repo, branch, sha, new, gone, looked_up, total):
    lines = ["The open code scanning alerts on `%s` changed%s:" % (branch, commit_note(sha)), ""]
    lines += ["- new: %s" % describe_alert(repo, alert) for alert in new]
    lines += ["- gone: %s" % describe_gone(repo, number, looked_up) for number in gone]
    lines += ["", "Now %d open; the table above is current." % total]
    return "\n".join(lines) + "\n"


def close_comment(repo, branch, sha, gone, looked_up, others):
    lines = ["No open code scanning alerts remain on `%s`%s." % (branch, commit_note(sha))]
    if gone:
        lines += [""] + ["- gone: %s" % describe_gone(repo, number, looked_up) for number in gone]
    lines += ["", "Other alerts (counts only): %s." % "; ".join("%s: %s" % item for item in others)]
    return "\n".join(lines) + "\n"


def create_issue(repo, title, body):
    return run_gh(
        ["issue", "create", "--repo", repo, "--title", title, "--label", LABEL, "--body-file", "-"], input=body
    ).strip()


def edit_issue(repo, number, title, body):
    run_gh(["issue", "edit", str(number), "--repo", repo, "--title", title, "--body-file", "-"], input=body)


def comment_issue(repo, number, body):
    run_gh(["issue", "comment", str(number), "--repo", repo, "--body-file", "-"], input=body)


def close_issue(repo, number, comment):
    run_gh(["issue", "close", str(number), "--repo", repo, "--comment", comment])


# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------


def triage(repo, wait_for, timeout, interval, check):
    branch = default_branch(repo)
    ref = "refs/heads/" + branch
    if wait_for:
        if wait_for_analyses(repo, branch, ref, wait_for, timeout, interval) == SUPERSEDED:
            print("the issue is left to the run of the newer push")
            return EXIT_OK
        sha = wait_for
    else:
        sha = branch_head(repo, branch)
    alerts = sort_alerts(open_alerts(repo, ref))
    others = other_alerts(repo)
    print(
        "%d open code scanning alert%s on %s%s"
        % (len(alerts), "" if len(alerts) == 1 else "s", branch, commit_note(sha))
    )
    for alert in alerts:
        print("  " + describe_alert(repo, alert, markdown=False))
    for name, text in others:
        print("%s: %s" % (name, text))

    title = issue_title(len(alerts), branch)
    body = issue_body(repo, branch, alerts, others)
    issues = our_open_issues(repo)
    for extra in issues[1:] if alerts else []:
        print("warning: a second open code scanning issue #%d is left alone (close it by hand)" % extra["number"])
    current = {alert["number"] for alert in alerts}

    if not alerts:
        if not issues:
            print("no open alerts and no open code scanning issue: nothing to do")
            return EXIT_OK
        for issue in issues:
            gone = sorted(previous_numbers(issue.get("body")))
            if check:
                print("would close issue #%d" % issue["number"])
                continue
            close_issue(repo, issue["number"], close_comment(repo, branch, sha, gone, look_up(repo, gone), others))
            print("closed issue #%d" % issue["number"])
        return EXIT_OK

    if not issues:
        if check:
            print('would open an issue labelled %s: "%s"' % (LABEL, title))
            print(body)
            return EXIT_OK
        print("opened issue %s" % create_issue(repo, title, body))
        return EXIT_OK

    issue = issues[0]
    previous = previous_numbers(issue.get("body"))
    new = [alert for alert in alerts if alert["number"] not in previous]
    gone = sorted(previous - current)
    if new or gone:
        if check:
            print('would update issue #%d to "%s": %d new, %d gone' % (issue["number"], title, len(new), len(gone)))
            return EXIT_OK
        edit_issue(repo, issue["number"], title, body)
        comment_issue(
            repo, issue["number"], change_comment(repo, branch, sha, new, gone, look_up(repo, gone), len(alerts))
        )
        print("updated issue #%d: %d new, %d gone" % (issue["number"], len(new), len(gone)))
    elif not same_text(issue.get("title"), title) or not same_text(issue.get("body"), body):
        if check:
            print("would refresh issue #%d (same alerts, other details)" % issue["number"])
            return EXIT_OK
        edit_issue(repo, issue["number"], title, body)
        print("refreshed issue #%d (same alerts, other details)" % issue["number"])
    else:
        print("issue #%d is current: %s" % (issue["number"], issue.get("url", "")))
    return EXIT_OK


def sha_argument(text):
    if not SHA_RE.match(text):
        raise argparse.ArgumentTypeError("a full 40-character commit sha in lower case, not %r" % text)
    return text


def positive_int(text):
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("a whole number of seconds, not %r" % text) from None
    if value < 1:
        raise argparse.ArgumentTypeError("at least 1, not %d" % value)
    return value


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="code_scanning_issue.py",
        description="Keep one issue labelled security in step with the open code scanning alerts on main.",
        epilog="Exit codes: 0 done (whatever the alerts), 1 error, 2 usage.",
    )
    parser.add_argument("--repo", metavar="OWNER/NAME", help="the repository (default: the one gh resolves here)")
    parser.add_argument(
        "--wait-for", metavar="SHA", type=sha_argument, help="first wait for the analyses of this commit on main"
    )
    parser.add_argument(
        "--timeout",
        metavar="SECONDS",
        type=positive_int,
        default=DEFAULT_TIMEOUT,
        help="how long --wait-for waits at most (default %d)" % DEFAULT_TIMEOUT,
    )
    parser.add_argument(
        "--interval",
        metavar="SECONDS",
        type=positive_int,
        default=DEFAULT_INTERVAL,
        help="seconds between two polls of --wait-for (default %d)" % DEFAULT_INTERVAL,
    )
    parser.add_argument("--check", action="store_true", help="print the alerts and what would change; change nothing")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        return triage(resolve_repo(args.repo), args.wait_for, args.timeout, args.interval, args.check)
    except TriageError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, KeyError, ValueError, TypeError) as err:
        print("error: %s: %s" % (type(err).__name__, err), file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
