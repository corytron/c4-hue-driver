#!/usr/bin/env python3
"""Deploy, record and reconcile the house installation of the Hue drivers.

The GitOps roles (docs/cicd-gitops-design.md, sections 6, 7 and 7.1):

  desired state   deploy/house.yaml, the source of truth: the release tag and build number the
                  house is meant to run, and the bridge settings to read back after an install.
                  It changes only through a pull request.
  observed state  the GitHub Deployments of the environment "house": the newest deployment whose
                  latest status is success says which build is installed, since when and from
                  which release. Nothing else records what runs on the controller.
  actuator        the Windows Composer session (docs/composer-remote.md). The controller has no
                  install API, so the Composer click is never automatic: `start` verifies the
                  release and writes the brief the coordinator sends to that session, and `done`
                  or `failed` records what the session reported.

Subcommands (exit codes: 0 success or in sync, 1 error, 3 drift; a usage error exits 2):

  validate [--online]
      Schema and value checks of deploy/house.yaml (section 6). --online also downloads the
      release's manifest.json and fails when its build differs from the file's.
  start [--tag TAG] [--supersede] [--note TEXT] [--no-attestation]
      Downloads manifest.json, SHA256SUMS.txt and the three packages of the release into
      build/release/<tag>/ (a fresh directory); verifies every sha256 against both files, that
      manifest.build is deploy/house.yaml's build and manifest.commit the tag's commit, and that
      a provenance attestation names each package (presence and subject only). Refuses while a
      deployment of the environment is still in progress unless --supersede marks it inactive.
      Then creates the GitHub Deployment with status in_progress, writes deployment.json and
      BRIEF.md next to the packages, and prints the brief's path and the deployment's URL.
  done [--devices N] [--note TEXT] [--deployment ID]
      Re-reads the release's manifest (the assets must not have changed since start), sets the
      deployment's status to success and runs the drift logic, which closes the deploy issue.
  failed --note TEXT [--deployment ID]
      Status failure with the note; the open deploy issue gets the note as a comment and stays open.
  record --tag TAG --build N --at TIME --note TEXT [--no-manifest] [--commit SHA]
      A success deployment for an install made without this tool (build 247, installed on
      2026-10-24, and any out-of-band install): payload.recorded is true and the install time is
      kept in the description and in payload.installed_at (GitHub sets created_at itself).
  status
      Prints desired and observed; exit 0 when tag and build agree, 3 on drift.
  drift [--issue]
      status plus the online manifest check; with --issue it keeps at most one open issue
      labelled "deploy": opened on drift, retitled when the desired state changes, closed when the
      observed state catches up. Closed issues are never reopened, edited or deleted.

Standard library only. GitHub is reached through `gh` (gh api, gh release download, gh issue);
every call goes through run_gh(), which the unit tests replace with a fake. The repository is
the one `gh repo view` resolves from the current directory, or --repo OWNER/NAME.
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

EXIT_OK, EXIT_ERROR, EXIT_DRIFT = 0, 1, 3

ENVIRONMENT = "house"
DRIVERS = ("hue_bridge", "hue_light", "hue_scene")
PACKAGES = tuple(name + ".c4z" for name in DRIVERS)
RELEASE_FILES = ("manifest.json", "SHA256SUMS.txt") + PACKAGES
HOUSE_KEYS = ("environment", "release", "build", "drivers", "stream_timeout_s", "stream_watchdog_s", "debug_mode")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOUSE_FILE = os.path.join(ROOT, "deploy", "house.yaml")
RELEASE_DIR = os.path.join(ROOT, "build", "release")

TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DESCRIPTION_LIMIT = 140  # GitHub's limit for a deployment status description
STATUS_IN_PROGRESS = "Packages verified; install through Composer pending"

# Texts that never leave the VM (the repository is public). Every match refuses a brief or a
# note; the documented placeholders (10.0.2.143, 192.0.2.7, 001788fffe123abc) pass.
PLACEHOLDER_BRIDGE_ID = "001788fffe123abc"
PRIVATE_PATTERNS = (
    (re.compile(r"(?<![\d.])10\.0\.1\."), "an address starting with 10.0.1."),
    (re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{16}(?![0-9a-fA-F])"), "a 16-digit hexadecimal id (a bridge id)"),
    (re.compile(r"c4[:-]?29[:-]?96", re.IGNORECASE), "the string c42996 (a bridge id prefix)"),
    (re.compile(r"hue_app_key"), "the string hue_app_key (the application key's store name)"),
)


class DeployError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


class GhError(DeployError):
    """gh exited non-zero. http_status is the code gh names on stderr ("HTTP 404"), or None."""

    def __init__(self, args, returncode, stdout, stderr):
        self.gh_args = list(args)
        self.returncode = returncode
        self.stdout = stdout or ""
        self.stderr = stderr or ""
        match = re.search(r"HTTP (\d{3})", self.stderr)
        self.http_status = int(match.group(1)) if match else None
        detail = self.stderr.strip() or self.stdout.strip()[:300] or "exit %d" % returncode
        super().__init__("gh %s failed: %s" % (" ".join(self.gh_args[:3]), detail))


# ---------------------------------------------------------------------------
# Talking to GitHub: everything goes through run_gh
# ---------------------------------------------------------------------------


def run_gh(args, input=None):
    """The one place that runs gh. Returns stdout; raises GhError when gh exits non-zero."""
    try:
        proc = subprocess.run(["gh", *args], input=input, capture_output=True, text=True)
    except FileNotFoundError:
        raise DeployError("gh is not installed or not on PATH") from None
    if proc.returncode != 0:
        raise GhError(args, proc.returncode, proc.stdout, proc.stderr)
    return proc.stdout


def api(path, method="GET", body=None):
    """One REST call; the decoded JSON reply, or None for an empty one."""
    args = ["api"]
    if method != "GET":
        args += ["-X", method]
    args.append(path)
    data = None
    if body is not None:
        args += ["--input", "-"]
        data = json.dumps(body)
    out = run_gh(args, input=data)
    if not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError as err:
        raise DeployError("gh api %s returned something that is not JSON (%s)" % (path, err)) from err


def api_optional(path):
    """A GET that answers None on 404."""
    try:
        return api(path)
    except GhError as err:
        if err.http_status == 404:
            return None
        raise


def resolve_repo(spec):
    """OWNER/NAME from --repo or from the checkout gh sees."""
    if spec:
        parts = spec.split("/")
        if len(parts) != 2 or not all(parts):
            raise DeployError("--repo wants OWNER/NAME, got %r" % spec)
        return spec
    try:
        info = json.loads(run_gh(["repo", "view", "--json", "nameWithOwner"]))
    except GhError as err:
        raise DeployError("gh repo view failed (run inside the repository or pass --repo): %s" % err) from err
    return info["nameWithOwner"]


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clip(text, limit=DESCRIPTION_LIMIT):
    """One line of at most `limit` characters, for a deployment status description."""
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def private_findings(text):
    """Why `text` may not leave the VM: one reason per pattern found, naming the first line."""
    found = []
    for pattern, meaning in PRIVATE_PATTERNS:
        for match in pattern.finditer(text):
            if match.group(0).lower() == PLACEHOLDER_BRIDGE_ID:
                continue
            line = text.count("\n", 0, match.start()) + 1
            found.append("%s (line %d)" % (meaning, line))
            break
    return found


def refuse_private(text, what):
    problems = private_findings(text or "")
    if problems:
        raise DeployError("%s holds private data: %s" % (what, "; ".join(problems)))


# ---------------------------------------------------------------------------
# Desired state: deploy/house.yaml
# ---------------------------------------------------------------------------


def parse_house(text):
    """The flat `key: value` subset of section 6: comments, blank lines, a trailing comment, quotes."""
    values = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, rest = line.partition(":")
        key = key.strip()
        if not sep or not key:
            raise DeployError("deploy/house.yaml line %d is not `key: value`: %s" % (number, line))
        value = re.sub(r"(^|\s)#.*$", "", rest).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key in values:
            raise DeployError("deploy/house.yaml line %d repeats the key %s" % (number, key))
        values[key] = value
    return values


def _integer(value):
    return int(value) if re.fullmatch(r"-?\d+", value or "") else None


def validate_house(values):
    """The problems with a parsed house file; an empty list when it is valid."""
    problems = []
    for key in HOUSE_KEYS:
        if key not in values:
            problems.append("missing key %s" % key)
    for key in values:
        if key not in HOUSE_KEYS:
            problems.append("unknown key %s" % key)
    if "environment" in values and values["environment"] != ENVIRONMENT:
        problems.append("environment must be %s, not %r" % (ENVIRONMENT, values["environment"]))
    if "release" in values and not TAG_RE.match(values["release"]):
        problems.append("release must look like v1.0, not %r" % values["release"])
    if "build" in values:
        build = _integer(values["build"])
        if build is None or build <= 0:
            problems.append("build must be a positive integer, not %r" % values["build"])
    if "drivers" in values and sorted(values["drivers"].split()) != sorted(DRIVERS):
        problems.append("drivers must be exactly: %s (got %r)" % (" ".join(DRIVERS), values["drivers"]))
    timeout = watchdog = None
    if "stream_timeout_s" in values:
        timeout = _integer(values["stream_timeout_s"])
        if timeout is None or not 60 <= timeout <= 86400:
            problems.append("stream_timeout_s must be an integer from 60 to 86400, not %r" % values["stream_timeout_s"])
    if "stream_watchdog_s" in values:
        watchdog = _integer(values["stream_watchdog_s"])
        if watchdog is None or not 30 <= watchdog <= 3600:
            problems.append(
                "stream_watchdog_s must be an integer from 30 to 3600, not %r" % values["stream_watchdog_s"]
            )
        elif timeout is not None and watchdog >= timeout:
            problems.append("stream_watchdog_s (%d) must be below stream_timeout_s (%d)" % (watchdog, timeout))
    if "debug_mode" in values and values["debug_mode"] != "Off":
        problems.append(
            "debug_mode must be Off, not %r (a release never ships with debugging on)" % values["debug_mode"]
        )
    return problems


def load_house(path):
    """The validated desired state; raises DeployError naming every problem."""
    try:
        with open(path, encoding="utf-8") as handle:
            values = parse_house(handle.read())
    except OSError as err:
        raise DeployError("cannot read %s: %s" % (path, err)) from err
    problems = validate_house(values)
    if problems:
        raise DeployError("%s is not valid:\n  %s" % (display_path(path), "\n  ".join(problems)))
    return values


def desired(house):
    """(tag, build) of a validated house file."""
    return house["release"], int(house["build"])


# ---------------------------------------------------------------------------
# The release's assets: download and verification
# ---------------------------------------------------------------------------


def download_assets(repo, tag, names, directory):
    """gh release download of the named assets into directory. Returns the names that are missing."""
    args = ["release", "download", tag, "--repo", repo, "--dir", directory, "--clobber"]
    for name in names:
        args += ["--pattern", name]
    try:
        run_gh(args)
    except GhError as err:
        if "no assets match" not in err.stderr:
            raise
    return [name for name in names if not os.path.isfile(os.path.join(directory, name))]


def read_manifest(path):
    """build/manifest.json as the release workflow attaches it (section 5.2), shape-checked."""
    try:
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as err:
        raise DeployError("cannot read %s: %s" % (path, err)) from err
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise DeployError("manifest.json: unknown schema %r (this tool reads schema 1)" % (manifest.get("schema"),))
    if not isinstance(manifest.get("build"), int) or manifest["build"] <= 0:
        raise DeployError("manifest.json: build must be a positive integer, not %r" % (manifest.get("build"),))
    if not isinstance(manifest.get("commit"), str) or not COMMIT_RE.match(manifest["commit"]):
        raise DeployError("manifest.json: commit must be a 40-digit sha, not %r" % (manifest.get("commit"),))
    packages = manifest.get("packages")
    if not isinstance(packages, dict):
        raise DeployError("manifest.json: packages must be an object")
    for name in PACKAGES:
        entry = packages.get(name)
        digest = entry.get("sha256") if isinstance(entry, dict) else None
        if not isinstance(digest, str) or not SHA256_RE.match(digest.lower()):
            raise DeployError("manifest.json: no sha256 for %s" % name)
    return manifest


def fetch_manifest(repo, tag):
    """The release's manifest.json as a dict, or None when the release carries none."""
    with tempfile.TemporaryDirectory(prefix="deploy-manifest-") as tmp:
        if download_assets(repo, tag, ["manifest.json"], tmp):
            return None
        return read_manifest(os.path.join(tmp, "manifest.json"))


def parse_sums(path):
    """SHA256SUMS.txt (sha256sum output) as {file name: digest}."""
    sums = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 2:
                    sums[parts[1].lstrip("*")] = parts[0].lower()
    except OSError as err:
        raise DeployError("cannot read %s: %s" % (path, err)) from err
    return sums


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_packages(directory, manifest):
    """Every package's sha256 against SHA256SUMS.txt and manifest.json. Returns {name: sha256}."""
    sums = parse_sums(os.path.join(directory, "SHA256SUMS.txt"))
    hashes = {}
    problems = []
    for name in PACKAGES:
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            problems.append("%s is missing" % name)
            continue
        actual = sha256_file(path)
        hashes[name] = actual
        if name not in sums:
            problems.append("SHA256SUMS.txt does not list %s" % name)
        elif sums[name] != actual:
            problems.append("%s: sha256 %s, but SHA256SUMS.txt says %s" % (name, actual, sums[name]))
        entry = manifest["packages"][name]
        if entry["sha256"].lower() != actual:
            problems.append("%s: sha256 %s, but manifest.json says %s" % (name, actual, entry["sha256"]))
        if isinstance(entry.get("bytes"), int) and entry["bytes"] != os.path.getsize(path):
            problems.append("%s: %d bytes, but manifest.json says %d" % (name, os.path.getsize(path), entry["bytes"]))
    if problems:
        raise DeployError("the packages failed verification:\n  %s" % "\n  ".join(problems))
    return hashes


def check_manifest(manifest, tag, build, commit):
    """manifest.json against the tag, the desired build and the tag's commit."""
    problems = []
    if manifest.get("dev") is True:
        problems.append("manifest.json says dev: true; a development build is never installed as the production driver")
    if manifest.get("tag") not in (None, tag):
        problems.append("manifest.json names the tag %s, not %s" % (manifest.get("tag"), tag))
    if manifest["build"] != build:
        problems.append(
            "the release %s carries build %d but deploy/house.yaml says build %d: "
            "change deploy/house.yaml first (the desired state leads)" % (tag, manifest["build"], build)
        )
    if commit and manifest["commit"] != commit:
        problems.append(
            "manifest.json commit %s is not the commit the tag %s points at (%s)" % (manifest["commit"], tag, commit)
        )
    if problems:
        raise DeployError("the release %s does not match:\n  %s" % (tag, "\n  ".join(problems)))


def tag_commit(repo, tag):
    """The commit a tag points at; an annotated tag is dereferenced through git/tags."""
    ref = api_optional("repos/%s/git/ref/tags/%s" % (repo, tag))
    if ref is None:
        raise DeployError("no tag %s in %s" % (tag, repo))
    obj = ref["object"]
    for _hop in range(3):
        if obj["type"] != "tag":
            break
        obj = api("repos/%s/git/tags/%s" % (repo, obj["sha"]))["object"]
    if obj["type"] != "commit":
        raise DeployError("tag %s points at a %s, not a commit" % (tag, obj["type"]))
    return obj["sha"]


def attestation_check(repo, name, digest):
    """Provenance for one package: None when GitHub has no attestation for the digest, otherwise
    {"count", "predicate_types"} after checking that a subject carries the digest."""
    data = api_optional("repos/%s/attestations/sha256:%s" % (repo, digest))
    attestations = (data or {}).get("attestations") or []
    if not attestations:
        return None
    matched = 0
    predicate_types = set()
    for attestation in attestations:
        envelope = (attestation.get("bundle") or {}).get("dsseEnvelope") or {}
        payload = envelope.get("payload")
        if not payload:
            raise DeployError("an attestation for %s carries no DSSE payload" % name)
        try:
            statement = json.loads(base64.b64decode(payload + "=" * (-len(payload) % 4)))
        except (ValueError, TypeError) as err:
            raise DeployError("an attestation for %s has an unreadable payload: %s" % (name, err)) from err
        subjects = statement.get("subject") or []
        if any(((s.get("digest") or {}).get("sha256") or "").lower() == digest for s in subjects):
            matched += 1
            predicate_types.add(statement.get("predicateType") or "unknown predicate")
    if not matched:
        raise DeployError(
            "%d attestation(s) found for %s, but none names its digest %s as a subject"
            % (len(attestations), name, digest)
        )
    return {"count": matched, "predicate_types": sorted(predicate_types)}


# ---------------------------------------------------------------------------
# Observed state: the deployments of the environment
# ---------------------------------------------------------------------------


def payload_of(deployment):
    """A deployment's payload as a dict (GitHub returns it as given: an object or a JSON string)."""
    payload = deployment.get("payload")
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except ValueError:
            payload = {}
    return payload if isinstance(payload, dict) else {}


def environment_page(repo):
    return "https://github.com/%s/deployments/%s" % (repo, ENVIRONMENT)


class Deployments:
    """The deployments of the environment and their statuses, fetched once per run."""

    def __init__(self, repo):
        self.repo = repo
        self._deployments = None
        self._statuses = {}

    def _newest_first(self, items):
        return sorted(items, key=lambda item: (item.get("created_at") or "", item.get("id") or 0), reverse=True)

    def all(self):
        if self._deployments is None:
            listed = api("repos/%s/deployments?environment=%s&per_page=100" % (self.repo, ENVIRONMENT)) or []
            self._deployments = self._newest_first(listed)
        return self._deployments

    def get(self, deployment_id):
        deployment = api_optional("repos/%s/deployments/%s" % (self.repo, deployment_id))
        if deployment is None:
            raise DeployError("no deployment %s in %s" % (deployment_id, self.repo))
        return deployment

    def latest_status(self, deployment_id):
        if deployment_id not in self._statuses:
            listed = api("repos/%s/deployments/%s/statuses?per_page=100" % (self.repo, deployment_id)) or []
            ordered = self._newest_first(listed)
            self._statuses[deployment_id] = ordered[0] if ordered else None
        return self._statuses[deployment_id]

    def observed(self):
        """The newest deployment whose latest status is success, as {"tag", "build", "deployment",
        "status"}; None when the environment has no successful deployment."""
        for deployment in self.all():
            status = self.latest_status(deployment["id"])
            if status and status.get("state") == "success":
                payload = payload_of(deployment)
                build = payload.get("build")
                return {
                    "tag": payload.get("tag") or deployment.get("ref"),
                    "build": int(build) if _integer(str(build)) is not None else build,
                    "deployment": deployment,
                    "status": status,
                }
        return None

    def active(self):
        """(deployment, state) of an install still under way: latest status in_progress, pending or
        queued, or no status at all (the create succeeded and nothing after it); else None."""
        for deployment in self.all():
            status = self.latest_status(deployment["id"])
            state = status.get("state") if status else "pending"
            if state in ("in_progress", "pending", "queued"):
                return deployment, state
        return None

    def create(self, tag, build, commit, packages, note, extra=None):
        payload = {"tag": tag, "build": build, "commit": commit, "packages": packages, "note": note or ""}
        payload.update(extra or {})
        body = {
            "ref": tag,
            "environment": ENVIRONMENT,
            "auto_merge": False,
            "required_contexts": [],
            "production_environment": True,
            "description": "Build %d (%s) to the house" % (build, tag),
            "payload": payload,
        }
        deployment = api("repos/%s/deployments" % self.repo, "POST", body)
        if not isinstance(deployment, dict) or "id" not in deployment:
            raise DeployError("GitHub did not return a deployment: %r" % (deployment,))
        self._deployments = None
        return deployment

    def set_status(self, deployment_id, state, description):
        body = {"state": state, "description": clip(description)}
        status = api("repos/%s/deployments/%s/statuses" % (self.repo, deployment_id), "POST", body)
        self._deployments = None
        self._statuses.pop(deployment_id, None)
        return status


# ---------------------------------------------------------------------------
# The deploy issue (drift logic, section 7.1)
# ---------------------------------------------------------------------------


def open_deploy_issues(repo):
    out = run_gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--label",
            "deploy",
            "--state",
            "open",
            "--json",
            "number,title,url",
            "--limit",
            "100",
        ]
    )
    issues = json.loads(out) if out.strip() else []
    return sorted(issues, key=lambda issue: issue["number"])


def create_issue(repo, title, body):
    out = run_gh(
        ["issue", "create", "--repo", repo, "--title", title, "--label", "deploy", "--body-file", "-"], input=body
    )
    return out.strip()


def edit_issue(repo, number, title, body):
    run_gh(["issue", "edit", str(number), "--repo", repo, "--title", title, "--body-file", "-"], input=body)


def comment_issue(repo, number, body):
    run_gh(["issue", "comment", str(number), "--repo", repo, "--body-file", "-"], input=body)


def close_issue(repo, number, comment):
    run_gh(["issue", "close", str(number), "--repo", repo, "--comment", comment])


def issue_title(tag, build):
    return "Deploy %s (build %d) to the house" % (tag, build)


def describe_observed(observed):
    if observed is None:
        return "none: no deployment of environment %s has been recorded as success" % ENVIRONMENT
    deployment, status = observed["deployment"], observed["status"]
    return "%s build %s, deployment %s, success %s: %s" % (
        observed["tag"],
        observed["build"],
        deployment.get("id"),
        status.get("created_at"),
        status.get("description") or "",
    )


def observed_url(observed):
    return observed["deployment"].get("url") or "deployment %s" % observed["deployment"].get("id")


def issue_body(repo, tag, build, observed):
    if observed is None:
        seen = "no deployment of environment `%s` has been recorded as success yet." % ENVIRONMENT
    else:
        seen = 'build **%s** (%s), recorded as success on %s by deployment %s (%s): "%s".' % (
            observed["build"],
            observed["tag"],
            observed["status"].get("created_at"),
            observed["deployment"].get("id"),
            observed_url(observed),
            observed["status"].get("description") or "",
        )
    return (
        "**Desired** (`deploy/house.yaml` on `main`): release **%s**, build **%d**.\n"
        "**Observed** (GitHub Deployments, environment `%s`): %s\n"
        "\n"
        "Release: https://github.com/%s/releases/tag/%s\n"
        "Environment: %s\n"
        "\n"
        "To deploy, on the VM:\n"
        "\n"
        "    python3 tools/deploy.py start            # verifies the release's packages and provenance, "
        "records the deployment, writes build/release/%s/BRIEF.md\n"
        "    # send the brief to the Windows Composer session (docs/composer-remote.md); it installs through Composer\n"
        '    python3 tools/deploy.py done --devices N # or: python3 tools/deploy.py failed --note "..."\n'
        "\n"
        "The Composer click is the Windows session's: the controller has no install API and nothing here installs "
        'anything by itself. A build that changes a driver\'s `<capabilities>` makes Composer ask "Restart Director?"; '
        "answering Yes does not load it, and the owner must reboot the controller from System Manager afterwards.\n"
        "\n"
        "Opened by `tools/deploy.py drift --issue` (docs/cicd-gitops-design.md, section 7.1); it is closed by the tool "
        "when a deployment records build %d.\n"
        % (tag, build, ENVIRONMENT, seen, repo, tag, environment_page(repo), tag, build)
    )


def reconcile(repo, house, observed, with_issue):
    """Print desired and observed; with_issue keeps the one deploy issue in step. Exit code 0 or 3."""
    tag, build = desired(house)
    print("desired   %s build %d (deploy/house.yaml)" % (tag, build))
    print("observed  %s" % describe_observed(observed))
    drift = observed is None or observed["build"] != build or observed["tag"] != tag
    if drift:
        seen = "none" if observed is None else "build %s (%s)" % (observed["build"], observed["tag"])
        print("drift: desired build %d (%s), observed %s" % (build, tag, seen))
    else:
        print("in sync: build %d (%s)" % (build, tag))
    if not with_issue:
        return EXIT_DRIFT if drift else EXIT_OK
    issues = open_deploy_issues(repo)
    if drift:
        title = issue_title(tag, build)
        body = issue_body(repo, tag, build, observed)
        if not issues:
            print("opened deploy issue %s" % create_issue(repo, title, body))
        else:
            issue = issues[0]
            if issue["title"].strip() == title:
                print("deploy issue #%d is current: %s" % (issue["number"], issue.get("url", "")))
            else:
                edit_issue(repo, issue["number"], title, body)
                comment_issue(
                    repo,
                    issue["number"],
                    'desired state changed: now %s (build %d); this issue was "%s".' % (tag, build, issue["title"]),
                )
                print('updated deploy issue #%d to "%s"' % (issue["number"], title))
            for extra in issues[1:]:
                print(
                    "warning: a second open deploy issue #%d is left alone (close it by hand)" % extra["number"],
                    file=sys.stderr,
                )
        return EXIT_DRIFT
    for issue in issues:
        close_issue(
            repo, issue["number"], "Build %d (%s) recorded as deployed: %s" % (build, tag, observed_url(observed))
        )
        print("closed deploy issue #%d" % issue["number"])
    return EXIT_OK


def online_check(repo, house, strict):
    """deploy/house.yaml's build against the release's manifest.json. A release without a manifest
    is an error when strict (validate --online) and a warning otherwise (drift)."""
    tag, build = desired(house)
    manifest = fetch_manifest(repo, tag)
    if manifest is None:
        message = "release %s carries no manifest.json, so its build cannot be checked against deploy/house.yaml" % tag
        if strict:
            raise DeployError(message + " (a release cut by the release workflow has one)")
        print("warning: " + message, file=sys.stderr)
        return None
    if manifest["build"] != build:
        raise DeployError(
            "deploy/house.yaml says build %d, but the release %s carries build %d (manifest.json)"
            % (build, tag, manifest["build"])
        )
    return manifest


# ---------------------------------------------------------------------------
# The brief for the Windows Composer session
# ---------------------------------------------------------------------------


def render_brief(repo, tag, build, commit, house, deployment, hashes, attestations, note):
    base = "https://github.com/%s/releases/download/%s/" % (repo, tag)
    folder = "C:\\c4-hue\\drivers\\%s" % tag
    lines = []
    add = lines.append
    add("# Install build %d (%s) on the house" % (build, tag))
    add("")
    add(
        "Deployment %s on the GitHub environment `%s`, created %s by `tools/deploy.py start` (%s; environment page %s)."
        % (
            deployment.get("id"),
            ENVIRONMENT,
            deployment.get("created_at"),
            deployment.get("url"),
            environment_page(repo),
        )
    )
    add("")
    add("The owner's standing approval covers this install: act without asking again.")
    add(
        "The rules that are not approvals stay (docs/composer-remote.md): read first, click second; stop on surprises "
        "and report; no ALT taps; System Manager is out of reach."
    )
    if note:
        add("")
        add('Note from the coordinator: "%s"' % note)
    add("")
    add(
        "This brief carries no LAN address and no bridge id: the controller and the bridge are the ones Composer "
        "already shows."
    )
    add("")
    add("## 1. Download and verify (PowerShell)")
    add("")
    add("Fetch the three packages from the GitHub release into `%s\\` and check every sha256:" % folder)
    add("")
    add("```powershell")
    add("[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12")
    add("$dir = '%s'" % folder)
    add("New-Item -ItemType Directory -Force -Path $dir | Out-Null")
    for name in PACKAGES:
        add("Invoke-WebRequest -UseBasicParsing -Uri '%s%s' -OutFile \"$dir\\%s\"" % (base, name, name))
    add("$expected = @{")
    for name in PACKAGES:
        add("    '%s' = '%s'" % (name, hashes[name]))
    add("}")
    add("foreach ($name in $expected.Keys) {")
    add('    $hash = (Get-FileHash "$dir\\$name" -Algorithm SHA256).Hash.ToLower()')
    add('    if ($hash -ne $expected[$name]) { throw "sha256 mismatch for $name: $hash" }')
    add('    "$name OK $hash"')
    add("}")
    add("```")
    add("")
    add("Expected sha256 (the same values are in the release's SHA256SUMS.txt and manifest.json):")
    add("")
    add("| File | URL | sha256 |")
    add("| --- | --- | --- |")
    for name in PACKAGES:
        add("| %s | %s%s | `%s` |" % (name, base, name, hashes[name]))
    add("")
    add("A hash that differs ends the round: report it and install nothing.")
    add("")
    add("## 2. Install in Composer Pro")
    add("")
    add(
        '1. Driver ▸ "Add or Update Driver or Agent…"; pick all three files from `%s\\` at once. Composer updates '
        "every existing Hue Bridge, Hue Light and Hue Scene device in place." % folder
    )
    add("2. Never delete and re-add a device: the bridge's pairing would be lost, and the devices' bindings with it.")
    add(
        '3. If Composer asks "Restart Director?", answer Yes and say so in the report: the build changed a driver\'s '
        "<capabilities>, and the devices run the new code only after the owner reboots the controller from System "
        "Manager (the Windows session cannot)."
    )
    add(
        "4. Re-orient after the update (Composer reloads the project view): re-select each device and open its "
        "Properties tab before reading."
    )
    add("")
    add("## 3. Read back and report")
    add("")
    add(
        "- Every device's `Driver Version` = %d (the bridge, every Hue Light and every Hue Scene device); name any "
        "device that shows another value." % build
    )
    add(
        "- The bridge's `Stream Timeout (s)` = %s, `Stream Watchdog (s)` = %s and `Debug Mode` = %s "
        "(deploy/house.yaml); report a row that differs, do not change it."
        % (house["stream_timeout_s"], house["stream_watchdog_s"], house["debug_mode"])
    )
    add(
        "- The bridge's `Status` and `Attention` texts, and any dialog or `[ERROR]` line in a Lua tab during the "
        "install."
    )
    add("- Exact texts as UIA reports them; screenshots under C:\\c4-hue\\shots\\.")
    add("")
    add(
        "The coordinator then records the result on the VM with `python3 tools/deploy.py done --devices N` "
        '(or `python3 tools/deploy.py failed --note "..."`).'
    )
    add("")
    add("## 4. Provenance")
    add("")
    for name in PACKAGES:
        found = attestations.get(name)
        if found is None:
            add(
                "- %s: NO provenance attestation at GET repos/%s/attestations/sha256:%s (installed with "
                "--no-attestation)." % (name, repo, hashes[name])
            )
        else:
            add(
                "- %s: provenance attestation present (%d, subject sha256 matches; %s)."
                % (name, found["count"], ", ".join(found["predicate_types"]))
            )
    add(
        "- Checked for presence and subject only: cryptographic verification needs gh 2.49 or newer "
        "(`gh attestation verify`), which the VM's gh 2.46 lacks."
    )
    add("- Build %d, commit %s, release https://github.com/%s/releases/tag/%s." % (build, commit, repo, tag))
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Files under build/release/<tag>/
# ---------------------------------------------------------------------------


def release_dir(tag):
    return os.path.join(RELEASE_DIR, tag)


def display_path(path):
    """A path relative to the repository when it is inside it, absolute otherwise."""
    relative = os.path.relpath(path, ROOT)
    return relative if not relative.startswith("..") else os.path.abspath(path)


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def note_deployment(record, **fields):
    """Add fields to build/release/<tag>/deployment.json when it exists."""
    path = record.get("_path")
    if not path or not os.path.isfile(path):
        return
    data = read_json(path)
    data.update(fields)
    write_json(path, data)


def resolve_deployment(args, house, deployments):
    """The deployment `done` or `failed` is about: --deployment ID from GitHub, otherwise the
    deployment.json `start` wrote for the tag."""
    if args.deployment:
        deployment = deployments.get(args.deployment)
        payload = payload_of(deployment)
        build = _integer(str(payload.get("build")))
        if build is None:
            raise DeployError(
                "deployment %s carries no build in its payload; it was not created by this tool" % args.deployment
            )
        return {
            "id": deployment["id"],
            "url": deployment.get("url"),
            "tag": payload.get("tag") or deployment.get("ref"),
            "build": build,
        }
    tag = args.tag or house["release"]
    path = os.path.join(release_dir(tag), "deployment.json")
    if not os.path.isfile(path):
        raise DeployError(
            "no %s: run `deploy.py start` first, or pass --deployment ID "
            "(gh api repos/<owner>/<repo>/deployments?environment=%s)" % (display_path(path), ENVIRONMENT)
        )
    record = read_json(path)
    record["_path"] = path
    return record


def parse_time(text):
    """An ISO 8601 time with its offset, as given (kept verbatim in the record)."""
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError as err:
        raise DeployError("--at must be an ISO 8601 time such as 2026-10-24T21:04:00-04:00, not %r" % text) from err
    if parsed.tzinfo is None:
        raise DeployError("--at needs a UTC offset (2026-10-24T21:04:00-04:00), not %r" % text)
    return text


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_validate(args):
    house = load_house(args.file)
    tag, build = desired(house)
    print(
        "%s: valid (%s build %d; stream_timeout_s %s, stream_watchdog_s %s, debug_mode %s)"
        % (
            display_path(args.file),
            tag,
            build,
            house["stream_timeout_s"],
            house["stream_watchdog_s"],
            house["debug_mode"],
        )
    )
    if args.online:
        repo = resolve_repo(args.repo)
        manifest = online_check(repo, house, strict=True)
        print("release %s: manifest.json build %d matches (commit %s)" % (tag, manifest["build"], manifest["commit"]))
    return EXIT_OK


def cmd_start(args):
    house = load_house(args.file)
    tag = args.tag or house["release"]
    if not TAG_RE.match(tag):
        raise DeployError("--tag must look like v1.0, not %r" % tag)
    build = int(house["build"])
    if args.note:
        refuse_private(args.note, "--note")
    repo = resolve_repo(args.repo)
    deployments = Deployments(repo)

    active = deployments.active()
    if active and not args.supersede:
        deployment, state = active
        payload = payload_of(deployment)
        raise DeployError(
            "deployment %s (%s build %s) is still %s: finish it with `deploy.py done` or "
            "`deploy.py failed --note ...`, "
            "or pass --supersede to mark it inactive"
            % (deployment["id"], payload.get("tag"), payload.get("build"), state)
        )

    directory = release_dir(tag)
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory)
    missing = download_assets(repo, tag, RELEASE_FILES, directory)
    if missing:
        hint = ""
        if "manifest.json" in missing:
            hint = " (a release built before the release workflow wrote manifest.json; re-cut it from main)"
        raise DeployError("the release %s lacks %s%s" % (tag, ", ".join(missing), hint))
    print("downloaded %d files into %s" % (len(RELEASE_FILES), display_path(directory)))

    manifest = read_manifest(os.path.join(directory, "manifest.json"))
    hashes = verify_packages(directory, manifest)
    commit = tag_commit(repo, tag)
    check_manifest(manifest, tag, build, commit)
    print("verified build %d, commit %s: every sha256 matches SHA256SUMS.txt and manifest.json" % (build, commit))

    attestations = {}
    unattested = []
    for name in PACKAGES:
        found = attestation_check(repo, name, hashes[name])
        attestations[name] = found
        if found is None:
            unattested.append(name)
        else:
            print(
                "attestation %s: %d, subject matches (%s)" % (name, found["count"], ", ".join(found["predicate_types"]))
            )
    if unattested:
        if not args.no_attestation:
            raise DeployError(
                "no provenance attestation for %s (GET repos/%s/attestations/sha256:<digest>); a release cut by the "
                "release workflow carries one; --no-attestation installs without" % (", ".join(unattested), repo)
            )
        print(
            "warning: no provenance attestation for %s; continuing (--no-attestation)" % ", ".join(unattested),
            file=sys.stderr,
        )

    if active:
        deployment, state = active
        deployments.set_status(
            deployment["id"],
            "inactive",
            "Superseded on %s by a new start of %s (build %d) from the VM" % (now_iso(), tag, build),
        )
        print("superseded deployment %s (%s -> inactive)" % (deployment["id"], state))

    deployment = deployments.create(tag, build, commit, hashes, args.note)
    record = {
        "id": deployment["id"],
        "url": deployment.get("url"),
        "tag": tag,
        "build": build,
        "commit": commit,
        "created": deployment.get("created_at"),
        "repo": repo,
        "environment": ENVIRONMENT,
        "environment_page": environment_page(repo),
        "packages": hashes,
        "note": args.note or "",
    }
    write_json(os.path.join(directory, "deployment.json"), record)
    print("deployment %s created: %s" % (deployment["id"], deployment.get("url")))
    deployments.set_status(deployment["id"], "in_progress", STATUS_IN_PROGRESS)

    brief = render_brief(repo, tag, build, commit, house, deployment, hashes, attestations, args.note)
    refuse_private(brief, "the brief")
    brief_path = os.path.join(directory, "BRIEF.md")
    with open(brief_path, "w", encoding="utf-8") as handle:
        handle.write(brief)
    print(display_path(brief_path))
    print(deployment.get("url"))
    return EXIT_OK


def cmd_done(args):
    house = load_house(args.file)
    if args.note:
        refuse_private(args.note, "--note")
    repo = resolve_repo(args.repo)
    deployments = Deployments(repo)
    record = resolve_deployment(args, house, deployments)
    tag, build = record["tag"], int(record["build"])

    manifest = fetch_manifest(repo, tag)
    if manifest is None:
        raise DeployError("the release %s carries no manifest.json any more; not recording success" % tag)
    if manifest["build"] != build:
        raise DeployError(
            "the release %s now carries build %d, but deployment %s recorded build %d: the assets changed after "
            "start; run `deploy.py start` again" % (tag, manifest["build"], record["id"], build)
        )
    recorded = record.get("packages") or {}
    changed = [
        name for name in PACKAGES if name in recorded and recorded[name] != manifest["packages"][name]["sha256"].lower()
    ]
    if changed:
        raise DeployError(
            "the release %s replaced %s after start; run `deploy.py start` again" % (tag, ", ".join(changed))
        )

    devices = "%d devices" % args.devices if args.devices is not None else "every device"
    description = "Driver Version %d on %s, settings as deploy/house.yaml" % (build, devices)
    if args.note:
        description += "; " + args.note
    deployments.set_status(record["id"], "success", description)
    print("deployment %s: success (%s)" % (record["id"], clip(description)))
    note_deployment(record, finished=now_iso(), result="success", devices=args.devices)
    return reconcile(repo, house, deployments.observed(), with_issue=True)


def cmd_failed(args):
    house = load_house(args.file)
    refuse_private(args.note, "--note")
    repo = resolve_repo(args.repo)
    deployments = Deployments(repo)
    record = resolve_deployment(args, house, deployments)
    deployments.set_status(record["id"], "failure", args.note)
    print("deployment %s: failure (%s)" % (record["id"], clip(args.note)))
    note_deployment(record, finished=now_iso(), result="failure", failure_note=args.note)
    for issue in open_deploy_issues(repo):
        comment_issue(
            repo,
            issue["number"],
            "Install of build %s (%s) failed (deployment %s): %s"
            % (record["build"], record["tag"], record["id"], args.note),
        )
        print("commented on deploy issue #%d (it stays open)" % issue["number"])
    return EXIT_OK


def cmd_record(args):
    house = load_house(args.file)
    if not TAG_RE.match(args.tag):
        raise DeployError("--tag must look like v1.0, not %r" % args.tag)
    if args.build <= 0:
        raise DeployError("--build must be a positive integer")
    installed_at = parse_time(args.at)
    refuse_private(args.note, "--note")
    if args.commit and not COMMIT_RE.match(args.commit):
        raise DeployError("--commit must be a 40-digit sha")
    repo = resolve_repo(args.repo)
    deployments = Deployments(repo)
    tag_commit(repo, args.tag)  # the tag must exist: it is the deployment's ref

    manifest = fetch_manifest(repo, args.tag)
    packages = {}
    commit = args.commit
    if manifest is None:
        if not args.no_manifest:
            raise DeployError(
                "the release %s carries no manifest.json; pass --no-manifest to record build %d on the operator's word"
                % (args.tag, args.build)
            )
        print(
            "warning: the release %s has no manifest.json; recording build %d unverified" % (args.tag, args.build),
            file=sys.stderr,
        )
    elif manifest["build"] != args.build:
        if not args.no_manifest:
            raise DeployError(
                "the release %s carries build %d, not %d; pass --no-manifest to record an out-of-band build"
                % (args.tag, manifest["build"], args.build)
            )
        print(
            "warning: the release %s carries build %d; recording build %d unverified"
            % (args.tag, manifest["build"], args.build),
            file=sys.stderr,
        )
    else:
        packages = {name: manifest["packages"][name]["sha256"].lower() for name in PACKAGES}
        commit = commit or manifest["commit"]

    extra = {"recorded": True, "installed_at": installed_at}
    deployment = deployments.create(args.tag, args.build, commit, packages, args.note, extra)
    print("deployment %s created: %s" % (deployment["id"], deployment.get("url")))
    deployments.set_status(
        deployment["id"],
        "success",
        "Recorded: Driver Version %d installed %s; %s" % (args.build, installed_at, args.note),
    )
    print("deployment %s: success (recorded; installed %s)" % (deployment["id"], installed_at))
    return reconcile(repo, house, deployments.observed(), with_issue=True)


def cmd_status(args):
    house = load_house(args.file)
    repo = resolve_repo(args.repo)
    return reconcile(repo, house, Deployments(repo).observed(), with_issue=False)


def cmd_drift(args):
    house = load_house(args.file)
    repo = resolve_repo(args.repo)
    online_check(repo, house, strict=False)
    return reconcile(repo, house, Deployments(repo).observed(), with_issue=args.issue)


# ---------------------------------------------------------------------------


def parse_args(argv):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", metavar="OWNER/NAME", help="the repository (default: the one gh resolves here)")
    common.add_argument(
        "--file", default=HOUSE_FILE, metavar="PATH", help="the desired-state file (default deploy/house.yaml)"
    )

    parser = argparse.ArgumentParser(
        prog="deploy.py",
        description="Deploy, record and reconcile the house installation (docs/cicd-gitops-design.md, section 7).",
        epilog="Exit codes: 0 success or in sync, 1 error, 3 drift (status, drift, done, record).",
    )
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser(
        "validate", parents=[common], help="check deploy/house.yaml (schema and values; --online: the release too)"
    )
    p.add_argument("--online", action="store_true", help="also fetch the release's manifest.json and compare its build")
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser(
        "start",
        parents=[common],
        help="verify the release's assets and provenance, create the deployment, write the brief",
    )
    p.add_argument("--tag", help="the release tag (default: release from deploy/house.yaml)")
    p.add_argument("--supersede", action="store_true", help="mark a deployment still in progress inactive and go on")
    p.add_argument("--note", help="quoted in the brief and kept in the deployment's payload")
    p.add_argument("--no-attestation", action="store_true", help="go on when a package has no provenance attestation")
    p.set_defaults(func=cmd_start)

    p = sub.add_parser("done", parents=[common], help="record success and close the deploy issue")
    p.add_argument("--devices", type=int, help="how many devices showed the new Driver Version")
    p.add_argument("--note", help="appended to the status description")
    p.add_argument(
        "--deployment", type=int, metavar="ID", help="the deployment (default: build/release/<tag>/deployment.json)"
    )
    p.add_argument("--tag", help="whose deployment.json to read (default: release from deploy/house.yaml)")
    p.set_defaults(func=cmd_done)

    p = sub.add_parser("failed", parents=[common], help="record failure; the deploy issue stays open with the note")
    p.add_argument("--note", required=True, help="what the Windows session saw and which build the house still runs")
    p.add_argument(
        "--deployment", type=int, metavar="ID", help="the deployment (default: build/release/<tag>/deployment.json)"
    )
    p.add_argument("--tag", help="whose deployment.json to read (default: release from deploy/house.yaml)")
    p.set_defaults(func=cmd_failed)

    p = sub.add_parser(
        "record", parents=[common], help="record an install made without this tool as a success deployment"
    )
    p.add_argument("--tag", required=True, help="the release tag the install came from")
    p.add_argument("--build", required=True, type=int, help="the build number the devices show as Driver Version")
    p.add_argument("--at", required=True, metavar="TIME", help="when it was installed, ISO 8601 with offset")
    p.add_argument("--note", required=True, help="what was installed and how")
    p.add_argument(
        "--no-manifest", action="store_true", help="record although the release has no manifest or another build"
    )
    p.add_argument("--commit", help="the commit the build was made from (default: the manifest's, or none)")
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("status", parents=[common], help="desired versus observed; exit 3 on drift")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser(
        "drift", parents=[common], help="status with the online check; --issue keeps the deploy issue in step"
    )
    p.add_argument("--issue", action="store_true", help="open, update or close the one issue labelled deploy")
    p.set_defaults(func=cmd_drift)

    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        return args.func(args)
    except DeployError as err:
        print("error: %s" % err, file=sys.stderr)
        return EXIT_ERROR
    except (OSError, KeyError, ValueError, TypeError) as err:
        print("error: %s: %s" % (type(err).__name__, err), file=sys.stderr)
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
