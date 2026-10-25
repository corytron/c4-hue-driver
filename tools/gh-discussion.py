#!/usr/bin/env python3
"""Post to this repository's GitHub Discussions through `gh api graphql`.

  gh-discussion.py --category "Show and tell" --title "2026-10-24 — Subject" --body-file report.md [--pin]
  gh-discussion.py --comment 12 --body-file reply.md
  gh-discussion.py --check --category General --title "…" --body-file draft.md

The first form creates a discussion and prints its URL. --pin asks GitHub to
pin it; the GraphQL API has no pinDiscussion mutation as of 2026-10-24, so the
result says to pin it from the discussion's menu in the browser (the attempt
stays in case GitHub adds the mutation). The second form appends the body as
a comment to discussion number 12 and prints the comment's URL. --check runs
every check (repository, category, title, body) and prints what would be
posted, without posting anything.

A body or title is refused when it holds an obvious private pattern: an
address starting with 10.0.1., the string c42996 (also spelled c4:29:96) or
the string hue_app_key; a body is also refused over GitHub's limit of 65,536
characters. Replace the data or trim the text and run again. The documented
placeholders (10.0.2.143, 192.0.2.7, 001788fffe123abc) pass. A title that one
of the repository's latest 100 discussions already carries is refused as
well, so a retry after a server error cannot post twice (GitHub has answered
"Something went wrong" after creating the discussion all the same);
--allow-duplicate-title posts anyway.

The repository is the one `gh repo view` resolves from the current directory,
or --repo owner/name. Standard library only; needs `gh` logged in with the
repo scope (`gh auth status`).

Exit codes: 0 success, 1 error (gh failed, unknown category, bad arguments),
2 body or title refused (private pattern, too long, or a title already used).
"""
import argparse
import json
import re
import subprocess
import sys

EXIT_OK, EXIT_ERROR, EXIT_REFUSED = 0, 1, 2
BODY_LIMIT = 65536

# (pattern, what it is). Every match refuses the post.
PRIVATE_PATTERNS = (
    (re.compile(r"(?<![\d.])10\.0\.1\."), "an address starting with 10.0.1."),
    (re.compile(r"c4[:-]?29[:-]?96", re.IGNORECASE), "the string c42996 (a bridge id prefix)"),
    (re.compile(r"hue_app_key"), "the string hue_app_key (the application key's store name)"),
)

REPO_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 25) { nodes { id name slug } }
  }
}
"""

CREATE_MUTATION = """
mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {repositoryId: $repositoryId, categoryId: $categoryId, title: $title, body: $body}) {
    discussion { id number url }
  }
}
"""

PIN_MUTATION = """
mutation($discussionId: ID!) {
  pinDiscussion(input: {discussionId: $discussionId}) { discussion { number } }
}
"""

TITLES_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    discussions(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number title url } }
  }
}
"""

DISCUSSION_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    discussion(number: $number) { id url title }
  }
}
"""

COMMENT_MUTATION = """
mutation($discussionId: ID!, $body: String!) {
  addDiscussionComment(input: {discussionId: $discussionId, body: $body}) { comment { url } }
}
"""


class GhError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


# ---------------------------------------------------------------------------
# Talking to gh
# ---------------------------------------------------------------------------

def run_gh(args, stdin=None):
    try:
        return subprocess.run(["gh"] + args, input=stdin, capture_output=True, text=True)
    except FileNotFoundError:
        raise GhError("gh is not installed or not on PATH")


def graphql(query, variables):
    """Run one GraphQL document with variables; return its `data` or raise."""
    payload = json.dumps({"query": query, "variables": variables})
    proc = run_gh(["api", "graphql", "--input", "-"], stdin=payload)
    data = None
    if proc.stdout.strip():
        try:
            data = json.loads(proc.stdout)
        except ValueError:
            data = None
    if isinstance(data, dict) and data.get("errors"):
        messages = "; ".join(str(e.get("message", e)) for e in data["errors"])
        raise GhError("GraphQL: " + messages)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "exit %d" % proc.returncode
        raise GhError("gh api graphql failed: " + detail)
    if not isinstance(data, dict) or "data" not in data:
        raise GhError("gh api graphql returned no data: " + proc.stdout[:200])
    return data["data"]


def resolve_repo(spec):
    """owner, name from --repo or from the checkout gh sees."""
    if spec:
        parts = spec.split("/")
        if len(parts) != 2 or not all(parts):
            raise GhError("--repo wants owner/name, got %r" % spec)
        return parts[0], parts[1]
    proc = run_gh(["repo", "view", "--json", "owner,name"])
    if proc.returncode != 0:
        raise GhError("gh repo view failed (run it inside the repository or pass --repo): "
                      + proc.stderr.strip())
    info = json.loads(proc.stdout)
    return info["owner"]["login"], info["name"]


def repo_and_categories(owner, name):
    repo = graphql(REPO_QUERY, {"owner": owner, "name": name})["repository"]
    if repo is None:
        raise GhError("repository %s/%s not found or not readable" % (owner, name))
    return repo["id"], repo["discussionCategories"]["nodes"]


def existing_with_title(owner, name, title):
    """The latest discussions whose title equals `title`."""
    nodes = graphql(TITLES_QUERY, {"owner": owner, "name": name})["repository"]["discussions"]["nodes"]
    return [d for d in nodes if d["title"].strip() == title.strip()]


def pick_category(categories, wanted):
    key = wanted.strip().lower()
    for cat in categories:
        if key in (cat["name"].lower(), cat["slug"].lower()):
            return cat
    names = ", ".join(c["name"] for c in categories)
    raise GhError("no discussion category %r; the repository has: %s" % (wanted, names))


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def refusals(text, what):
    """Reasons to refuse `text`, each naming the first offending line."""
    found = []
    for pattern, meaning in PRIVATE_PATTERNS:
        match = pattern.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            found.append("%s holds %s (line %d)" % (what, meaning, line))
    return found


def read_body(path):
    if path == "-":
        body = sys.stdin.read()
    else:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
    if not body.strip():
        raise GhError("the body is empty")
    return body


def check_text(body, title):
    problems = refusals(body, "the body")
    if title is not None:
        problems += refusals(title, "the title")
    if len(body) > BODY_LIMIT:
        problems.append("the body is %d characters; GitHub allows %d (trim it)" % (len(body), BODY_LIMIT))
    return problems


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def create(args, body):
    owner, name = resolve_repo(args.repo)
    repo_id, categories = repo_and_categories(owner, name)
    category = pick_category(categories, args.category)
    same = existing_with_title(owner, name, args.title)
    if same and not args.allow_duplicate_title:
        print("refused: a discussion with this title exists: %s (--allow-duplicate-title posts anyway)"
              % same[0]["url"], file=sys.stderr)
        return EXIT_REFUSED
    if args.check:
        print("OK: would post to %s in %s/%s: %r (%d characters%s)"
              % (category["name"], owner, name, args.title, len(body), ", then pin it" if args.pin else ""))
        return EXIT_OK
    result = graphql(CREATE_MUTATION, {
        "repositoryId": repo_id, "categoryId": category["id"], "title": args.title, "body": body,
    })
    discussion = result["createDiscussion"]["discussion"]
    print(discussion["url"])
    if args.pin:
        try:
            graphql(PIN_MUTATION, {"discussionId": discussion["id"]})
            print("pinned", file=sys.stderr)
        except GhError as err:
            if "pinDiscussion" in str(err):
                print("not pinned: GitHub's API has no pinDiscussion mutation; pin it from the "
                      "discussion's menu in the browser", file=sys.stderr)
            else:
                print("not pinned: %s" % err, file=sys.stderr)
    return EXIT_OK


def comment(args, body):
    owner, name = resolve_repo(args.repo)
    repo = graphql(DISCUSSION_QUERY, {"owner": owner, "name": name, "number": args.comment})["repository"]
    discussion = repo and repo.get("discussion")
    if not discussion:
        raise GhError("no discussion #%d in %s/%s" % (args.comment, owner, name))
    if args.check:
        print("OK: would comment on #%d %r in %s/%s (%d characters)"
              % (args.comment, discussion["title"], owner, name, len(body)))
        return EXIT_OK
    result = graphql(COMMENT_MUTATION, {"discussionId": discussion["id"], "body": body})
    print(result["addDiscussionComment"]["comment"]["url"])
    return EXIT_OK


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="gh-discussion.py",
        description="Create a GitHub discussion, or comment on one, through gh api graphql.",
        epilog=__doc__.split("\n\n", 1)[1],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--category", help="category name or slug (Announcements, General, Ideas, Polls, Q&A, Show and tell)")
    parser.add_argument("--title", help="the discussion's title, YYYY-MM-DD — subject")
    parser.add_argument("--body-file", required=True, metavar="PATH", help="Markdown file holding the body; - reads standard input")
    parser.add_argument("--pin", action="store_true", help="ask GitHub to pin the new discussion (see below)")
    parser.add_argument("--allow-duplicate-title", action="store_true",
                        help="post even if a discussion with the same title exists")
    parser.add_argument("--comment", type=int, metavar="NUMBER", help="append the body as a comment to this discussion instead")
    parser.add_argument("--repo", metavar="OWNER/NAME", help="the repository (default: the one gh resolves here)")
    parser.add_argument("--check", action="store_true", help="run the checks and print what would be posted; post nothing")
    args = parser.parse_args(argv)
    if args.comment is not None:
        if args.category or args.title or args.pin or args.allow_duplicate_title:
            parser.error("--comment takes only --body-file (and --repo, --check)")
    else:
        if not args.category or not args.title:
            parser.error("--category and --title are required to create a discussion")
    return args


def main(argv):
    args = parse_args(argv)
    try:
        body = read_body(args.body_file)
        problems = check_text(body, args.title)
        if problems:
            for problem in problems:
                print("refused: " + problem, file=sys.stderr)
            return EXIT_REFUSED
        if args.comment is not None:
            return comment(args, body)
        return create(args, body)
    except GhError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, KeyError, ValueError) as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
