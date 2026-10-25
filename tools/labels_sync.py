#!/usr/bin/env python3
"""Create and update the repository's labels from .github/labels.json; never delete one.

  labels_sync.py [--repo OWNER/NAME] [--file .github/labels.json] [--check]

The file is the desired set (docs/cicd-gitops-design.md, section 8): a label the repository
lacks is created, a label whose colour or description differs is updated, and a label the
repository has that the file does not is only listed (deleting it would lose its history on
issues, so that stays a decision made by hand). One plain line per action.

--check changes nothing: it prints what would be created or updated and exits 3 when the
repository is out of sync, 0 when it matches. .github/workflows/labels.yml runs the real
form on a push to main that touches the file.

Standard library only; GitHub through `gh api`, every call via run_gh() so the unit tests can
replace it. Exit codes: 0 in sync (or made so), 1 error, 3 out of sync (--check only).
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse

EXIT_OK, EXIT_ERROR, EXIT_OUT_OF_SYNC = 0, 1, 3
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS_FILE = os.path.join(ROOT, ".github", "labels.json")
COLOUR_RE = re.compile(r"^[0-9a-fA-F]{6}$")
DESCRIPTION_LIMIT = 100  # GitHub's limit


class SyncError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


def run_gh(args, input=None):
    """The one place that runs gh. Returns stdout; raises SyncError when gh exits non-zero."""
    try:
        proc = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    except FileNotFoundError:
        raise SyncError("gh is not installed or not on PATH") from None
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()[:300] or "exit %d" % proc.returncode
        raise SyncError("gh %s failed: %s" % (" ".join(args[:3]), detail))
    return proc.stdout


def api(path, method="GET", body=None):
    args = ["api"]
    if method != "GET":
        args += ["-X", method]
    args.append(path)
    data = None
    if body is not None:
        args += ["--input", "-"]
        data = json.dumps(body)
    out = run_gh(args, input=data)
    return json.loads(out) if out.strip() else None


def resolve_repo(spec):
    if spec:
        parts = spec.split("/")
        if len(parts) != 2 or not all(parts):
            raise SyncError("--repo wants OWNER/NAME, got %r" % spec)
        return spec
    return json.loads(run_gh(["repo", "view", "--json", "nameWithOwner"]))["nameWithOwner"]


def load_labels(path):
    """The file's labels as [{name, color, description}], checked."""
    try:
        with open(path, encoding="utf-8") as handle:
            labels = json.load(handle)
    except (OSError, ValueError) as err:
        raise SyncError("cannot read %s: %s" % (path, err)) from err
    if not isinstance(labels, list):
        raise SyncError("%s must hold a list of labels" % path)
    seen = set()
    for label in labels:
        if not isinstance(label, dict) or not isinstance(label.get("name"), str) or not label["name"].strip():
            raise SyncError("every label needs a name: %r" % (label,))
        if not COLOUR_RE.match(str(label.get("color", ""))):
            raise SyncError("label %s: color must be six hex digits, not %r" % (label["name"], label.get("color")))
        description = label.get("description", "")
        if not isinstance(description, str) or len(description) > DESCRIPTION_LIMIT:
            raise SyncError(
                "label %s: description must be text of at most %d characters" % (label["name"], DESCRIPTION_LIMIT)
            )
        key = label["name"].strip().lower()
        if key in seen:
            raise SyncError("label %s is listed twice" % label["name"])
        seen.add(key)
    return [
        {"name": lb["name"].strip(), "color": lb["color"].lower(), "description": lb.get("description", "")}
        for lb in labels
    ]


def fetch_labels(repo):
    """Every label of the repository, all pages."""
    labels = []
    page = 1
    while True:
        batch = api("repos/%s/labels?per_page=100&page=%d" % (repo, page)) or []
        labels.extend(batch)
        if len(batch) < 100:
            return labels
        page += 1


def plan(wanted, existing):
    """(create, update, extra): labels to create, (current, wanted) pairs to update, and the
    repository's labels the file does not name. Names compare without regard to case, as GitHub does."""
    by_name = {label["name"].lower(): label for label in existing}
    create, update = [], []
    for label in wanted:
        current = by_name.get(label["name"].lower())
        if current is None:
            create.append(label)
            continue
        same_colour = (current.get("color") or "").lower() == label["color"]
        same_text = (current.get("description") or "") == label["description"]
        if not (same_colour and same_text):
            update.append((current, label))
    named = {label["name"].lower() for label in wanted}
    extra = [label for label in existing if label["name"].lower() not in named]
    return create, update, extra


def describe_change(current, label):
    parts = []
    if (current.get("color") or "").lower() != label["color"]:
        parts.append("colour %s -> %s" % (current.get("color") or "none", label["color"]))
    if (current.get("description") or "") != label["description"]:
        parts.append("description %r -> %r" % (current.get("description") or "", label["description"]))
    return "; ".join(parts)


def sync(repo, wanted, check):
    create, update, extra = plan(wanted, fetch_labels(repo))
    for label in create:
        if check:
            print("would create %s (%s, %r)" % (label["name"], label["color"], label["description"]))
        else:
            api(
                "repos/%s/labels" % repo,
                "POST",
                {"name": label["name"], "color": label["color"], "description": label["description"]},
            )
            print("created %s (%s, %r)" % (label["name"], label["color"], label["description"]))
    for current, label in update:
        if check:
            print("would update %s: %s" % (label["name"], describe_change(current, label)))
        else:
            path = "repos/%s/labels/%s" % (repo, urllib.parse.quote(current["name"], safe=""))
            api(path, "PATCH", {"color": label["color"], "description": label["description"]})
            print("updated %s: %s" % (label["name"], describe_change(current, label)))
    for label in extra:
        print("not in the file (left alone): %s" % label["name"])
    if not create and not update:
        print("%d labels in sync" % len(wanted))
        return EXIT_OK
    if check:
        print("out of sync: %d to create, %d to update" % (len(create), len(update)))
        return EXIT_OUT_OF_SYNC
    print("%d labels in sync after %d created, %d updated" % (len(wanted), len(create), len(update)))
    return EXIT_OK


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="labels_sync.py",
        description="Create and update the repository's labels from .github/labels.json; never delete.",
        epilog="Exit codes: 0 in sync (or made so), 1 error, 3 out of sync (--check only).",
    )
    parser.add_argument("--repo", metavar="OWNER/NAME", help="the repository (default: the one gh resolves here)")
    parser.add_argument(
        "--file", default=LABELS_FILE, metavar="PATH", help="the labels file (default .github/labels.json)"
    )
    parser.add_argument("--check", action="store_true", help="report only; exit 3 when out of sync")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        wanted = load_labels(args.file)
        return sync(resolve_repo(args.repo), wanted, args.check)
    except SyncError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, KeyError, ValueError, TypeError) as err:
        print("error: %s: %s" % (type(err).__name__, err), file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
