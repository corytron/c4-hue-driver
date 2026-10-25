# CI/CD and GitOps for the Hue driver (contract)

Issue #204 (owner, 2026-10-25: "fully CI/CD and gitops compliant in all the
best ways"). This document is the contract the pieces are built against;
where it and the code disagree after the work is merged, fix one of them in a
PR that says which.

## 1. What the words mean here

- **CI**: every pull request and every push to `main` runs the same checks a
  developer runs on the VM, for every file type in the repository, and
  `main` cannot take a change those checks refuse.
- **CD**: a release is an immutable, attested build artifact on the Releases
  page, cut by a workflow; nothing is built by hand for an install.
- **GitOps**: the state the house is meant to be in is a file in git
  (`deploy/house.yaml`); the state it is observed to be in is a GitHub
  Deployment on the environment `house`; a workflow compares the two and
  opens one issue when they differ. The actuator is the Windows Composer
  session: the controller has no install API, so the Composer click is
  **never automatic**. Deployment is approval-gated (the owner's standing
  approval), recorded and reconciled, not autonomous.

## 2. Files and owners

| Path | Owner | Purpose |
| --- | --- | --- |
| `docs/cicd-gitops-design.md` | coordinator | this contract |
| `deploy/house.yaml` | coordinator (schema §6) | desired state of the house |
| `.github/labels.json` | coordinator | labels, now with `ci`, `deploy`, `dependencies` |
| `ruff.toml` | coordinator | Python lint settings (line length 120, rules E F W I B) |
| `CLAUDE.md`, `docs/status.md` | coordinator | working rules, current state |
| `.github/workflows/ci.yml` | agent **workflows** | the four required jobs (§4) |
| `.github/workflows/release.yml` | agent workflows | attested release on tag push or dispatch (§5) |
| `.github/workflows/drift.yml` | agent workflows | desired vs observed (§7) |
| `.github/workflows/labels.yml` | agent workflows | labels from `labels.json` (§8) |
| `.github/workflows/scorecard.yml` | agent workflows | OpenSSF Scorecard, weekly and on push (§4.5) |
| `.github/workflows/dependabot-auto-merge.yml` | agent workflows | auto-merge for action-pin updates (§8) |
| `.github/release.yml`, `.github/dependabot.yml`, `.gitleaks.toml`, `.github/zizmor.yml`, `.github/actionlint.yaml` (if needed) | agent workflows | release-note categories, update schedule, scan rules, linter settings |
| `tools/deploy.py`, `tools/labels_sync.py`, `tools/tests/test_*.py`, lint fixes in the existing `tools/*.py` | agent **tooling** | the deploy and drift tool, label sync, their unit tests |
| `tools/check.sh`, `tools/setup-checks.sh`, `README.md`, `CONTRIBUTING.md`, `docs/release-checklist.md`, `docs/README.md`, `SECURITY.md` | agent **checks-and-docs** | one check script for VM and CI, its installer, the documents |
| `tools/requirements-checks.txt` | coordinator (#222) | hash-pinned Python check tools (§3) |
| `.github/workflows/code-scanning-triage.yml`, `tools/code_scanning_issue.py`, `tools/tests/test_code_scanning_issue.py` | coordinator (#222) | the one code scanning issue (§4.6) |

Current (2026-10-25, build 316): there is no `.github/zizmor.yml`; zizmor
runs with its defaults at `--min-severity medium`
(`tools/check.sh:check_workflows`).

Everything else in the checkout is edited by others at the same time. No
agent runs `git`; the coordinator integrates and commits on the branch
`ci/cicd-gitops-204` (PR "Closes #204").

Conventions: Python 3.12, standard library only (`tools/` has no
dependencies; `pyyaml` is **not** assumed: `deploy/house.yaml` is written in
the flat `key: value` subset §6 defines and parsed with a few lines), `ruff`
clean under `ruff.toml`, unit tests with `unittest` under `tools/tests/`
(`python3 -m unittest discover -s tools/tests -v`), shell scripts bash with
`set -euo pipefail` and shellcheck clean, workflows actionlint and zizmor
clean, every action pinned to a full commit SHA with the version in a
trailing comment (`uses: actions/checkout@<sha> # v7.0.0`), every job with
`timeout-minutes` and the least `permissions:` it needs (the workflow level
sets `permissions: {}` or `contents: read`, jobs add what they need).
Dates and build numbers in documents are absolute.

## 3. One script runs the checks: `tools/check.sh`

`tools/check.sh [--strict] [--only <name>...]`

Runs, in this order, printing one line per check (`ok`, `FAIL`, `skip
(<tool> not installed)`), and exits 1 if any failed; `--strict` turns every
skip into a failure (CI uses it, so nothing is silently skipped on the
runner):

| Name | Command | Scope |
| --- | --- | --- |
| `lua-lint` | `luacheck src tests tools` | as today |
| `lua-test` | `busted tests` | as today |
| `shell` | `shellcheck -S style` | `tools/*.sh`, `setup-vm.sh` if present in the repository (it is not today) |
| `python-lint` | `ruff check tools` and `ruff format --check tools` | `tools/**/*.py` |
| `python-test` | `python3 -B -m unittest discover -s tools/tests` (`-B`: no `__pycache__`, whose constant-folded test vectors the `secrets` tree scan would flag) | `tools/tests` |
| `xml` | well-formedness of every `src/*/driver.xml` with `python3 -c` and `xml.etree` (no xmllint: it needs apt) | `src/*/driver.xml` |
| `powershell` | `pwsh -c "Invoke-ScriptAnalyzer -Path tools/composer -Recurse -Severity Error -EnableExit"` | `tools/composer/*.psm1`; skip when `pwsh` is missing (the VM has none; GitHub's Ubuntu runners have it) |
| `workflows` | `actionlint` then `zizmor --min-severity medium .github/workflows` | `.github/workflows/*.yml` |
| `secrets` | `gitleaks dir . --config .gitleaks.toml --no-banner --redact` then `gitleaks git . --config .gitleaks.toml --no-banner --redact --log-opts=<refs>`: on the VM `--all`, the history of every local ref (branches, tags, stashes, remote-tracking refs), because a stale tag or branch can hold history that never reached GitHub and a `--tags` or `--mirror` push would publish it (security review 2026-10-25, finding 14); in CI (`GITHUB_ACTIONS=true`) `HEAD`, the history a pull request publishes (its `fetch-depth: 0` checkout also holds every other branch and tag, whose findings are not the pull request's) | tree and history |
| `house` | `python3 tools/deploy.py validate` (§6; offline: schema and value checks only) | `deploy/house.yaml` |

`tools/setup-checks.sh` installs what the VM lacks into `~/.local/bin`
without `sudo`. `ruff`, `zizmor` and `shellcheck-py` come from
`tools/requirements-checks.txt`, which pins each by version and by the
sha256 of every file PyPI has for it; they are installed one at a time with
`python3 -m pip install --require-hashes --no-deps --only-binary=:all:
--user --break-system-packages`, so pip refuses an unlisted hash, any
dependency and any source build. `actionlint` and `gitleaks` are pinned
release binaries whose sha256 the script carries and verifies. Today:
ruff 0.17.2, zizmor 1.31.1, shellcheck-py 0.10.0.1, actionlint 1.7.12,
gitleaks 8.30.1. CI runs the same script (ubuntu-latest has `shellcheck`
and `pwsh` already; the script skips what is present). It prints each
tool's version at the end. Without `python3 -m pip` it fails with a clear
line: the hash check is pip's, so there is no `pipx` or `uv` fallback.

## 4. CI: `.github/workflows/ci.yml`

Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`, and
`schedule` weekly (Monday 06:00 UTC) so a broken tool install shows up
without a PR. `concurrency` cancels superseded runs of the same ref.

Four jobs; **their `name:` strings are the required status checks on
`main`** and must not change without updating branch protection
(coordinator):

1. `Lint and test (Lua 5.1)`: as today (apt Lua 5.1, luarocks, luacheck,
   busted, dkjson, every rock at an exact version since 2026-10-25, §5.5),
   then `tools/check.sh --strict --only lua-lint lua-test`.
   Cache `~/.luarocks` and `/usr/local/lib/luarocks` keyed on the workflow
   file if it saves time; otherwise leave it.
2. `Build the three .c4z packages`: as today (`needs: test`, full-depth
   checkout, packager fetched at build time at its pinned commit, §5.5,
   LICENSE and NOTICE in each package, artifact upload), plus
   `tools/build.sh` output `build/manifest.json`
   (§5.2) uploaded with the packages.
3. `Tooling checks (shell, Python, XML, workflows)`: `tools/setup-checks.sh`
   then `tools/check.sh --strict --only shell python-lint python-test xml
   powershell workflows house`. Needs `pwsh` (present on ubuntu-latest).
4. `Secrets and private data`: full-depth checkout, `tools/setup-checks.sh`,
   `tools/check.sh --strict --only secrets`.

Jobs 3 and 4 do not depend on 1. `permissions: contents: read` everywhere.
Every job `timeout-minutes: 15` (build 20).

### 4.5 Scorecard and CodeQL

`.github/workflows/scorecard.yml`: `ossf/scorecard-action` on `push` to
`main`, `schedule` weekly and `branch_protection_rule`; `permissions:
security-events: write, id-token: write, contents: read, actions: read`;
`publish_results: true`; upload the SARIF with `github/codeql-action/upload-sarif`.
The README gets the Scorecard badge next to the CI badge. CodeQL default
setup (Python and Actions) is enabled by the coordinator through the API,
not a workflow file.

### 4.6 The code scanning issue

CodeQL default setup and `scorecard.yml` analyse every push to `main`.
`.github/workflows/code-scanning-triage.yml` (push to `main`, daily 07:41
UTC, dispatch; `contents: read`, `security-events: read`,
`vulnerability-alerts: read`, `issues: write`; concurrency group
`code-scanning-triage`, never cancelled) runs `tools/code_scanning_issue.py`,
on a push with `--wait-for $GITHUB_SHA`. It waits up to 30 minutes until
every tool and category that analysed the three previous commits has
analysed this one; a newer push ends the wait and leaves the issue to the
newer run. Then it keeps exactly one open issue labelled `security`, "Code
scanning: N open alert(s) on main": created when alerts exist and none is
open; title and table updated, with one comment naming what is new and
gone, when the set changes; refreshed silently when only details change;
closed with a comment when none remain. It never dismisses, never touches
closed issues, never opens a second, and ignores other `security` issues
(recognised by a body marker and the exact title). `GITHUB_TOKEN` cannot
read secret scanning alerts; the issue says so, and the coordinator checks
them with `gh api`.

## 5. Releases: `.github/workflows/release.yml`

### 5.1 Triggers and the rule

- `push` of a tag `v*` (as today), and
- `workflow_dispatch` with input `version` (`1.0`, `1.1`, …): the run
  verifies the input matches `^[0-9]+\.[0-9]+$`, builds `main`'s head, and
  once the packages are built, checked and attested tags it `v<version>`
  (force-moving an existing tag: "later releases of the same spike move the
  tag", `docs/release-checklist.md`) with `git tag -f -a` and pushes with
  `--force`, all in the same run, because a tag pushed with `GITHUB_TOKEN`
  starts no second workflow. A run that fails before that leaves the tag
  where it was. The jobs and their permissions: §5.4.

A release is built only from a commit on `main`: the job fails when
`git merge-base --is-ancestor "$GITHUB_SHA" origin/main` is false (for the
tag trigger; the dispatch trigger runs on `main` by construction). Lint and
tests run before the build, as today.
Current (2026-10-25, build 316): a dispatch from any ref but `main` is
refused too, in both jobs' tag step, before anything is built
(`.github/workflows/release.yml`).

### 5.2 `build/manifest.json`

`tools/build.sh` (coordinator edit) writes it next to the packages:

```json
{
  "schema": 1,
  "tag": "v1.0",            // from `git describe --tags --exact-match`, or null locally
  "version": "1.0",         // tag without the v, or null
  "build": 252,             // git rev-list --count HEAD; the drivers' <version>
  "commit": "<40-hex sha>",
  "built_at": "2026-10-25T03:12:45Z",
  "dev": false,             // true for tools/build.sh --dev (never released)
  "packages": {
    "hue_bridge.c4z": {"sha256": "<64 hex>", "bytes": 123456},
    "hue_light.c4z":  {"sha256": "...", "bytes": 0},
    "hue_scene.c4z":  {"sha256": "...", "bytes": 0}
  }
}
```

The release workflow attaches `hue_bridge.c4z`, `hue_light.c4z`,
`hue_scene.c4z`, `SHA256SUMS.txt`, `manifest.json`, and the provenance
bundle(s) from `actions/attest-build-provenance` (`subject-path:` the three
packages by name; also write the bundle to a file and attach it as
`attestations.sigstore.json`, so verifiers without `gh attestation` and the
Scorecard "Signed-Releases" check can see it), and the bundle's DSSE
envelope as `hue-drivers.intoto.jsonl` (one compact JSON line: the in-toto
v1 statement with the SLSA provenance v1 of the three packages, which
Signed-Releases scores 10 where the bundle alone gets 8). `--clobber` replaces
everything when the tag moves. Since #255 (2026-10-25) the release's title
and notes come from `CHANGELOG.md` on every run (`docs/changelog-design.md`):
the build job writes `build/release-notes.md` with `tools/changelog.py notes`
(the template `.github/release-notes.md`, this build's changes from the
`Unreleased` entry, the earlier builds of the version) and fails when
`Unreleased` is empty; the publish job checks it with the packages and sets
it with `gh release create --notes-file` or `gh release edit --notes-file`,
the title being the notes' first heading without the build
(`1.0 "Cassian"`). Nothing in the notes is edited by hand any more.
Current (2026-10-25, build 316): `.github/release.yml` ends with a sixth
category, "Other changes", for every other pull request.

### 5.3 Tag protection

A repository ruleset (coordinator, API) on tags `v*`: deletion blocked,
creation and update allowed to the repository admin and GitHub Actions.
Current (2026-10-25): the ruleset "Protect release tags" has one rule,
deletion, which the admin role may bypass; creating and moving `v*` tags
is not restricted beyond write access (read with `gh api
repos/corytron/c4-hue-driver/rulesets`).

### 5.4 Two jobs (security review 2026-10-25, finding 11)

No third-party code runs where the write token or the signing identity is:

- **build** (`Lint, test and build the packages`; `contents: read`, no
  `id-token`, no `GH_TOKEN`): checkout, the tag check of §5.1 (before any
  third-party code; on dispatch it also tags the commit locally, annotated,
  so that `tools/build.sh` names the tag in the manifest), the pinned rocks,
  lint and test, the pinned packager, the build, the package and manifest
  checks, `SHA256SUMS.txt`, then `actions/upload-artifact` of the three
  packages, `SHA256SUMS.txt` and `manifest.json` as
  `hue-drivers-<tag>-build`.
- **publish** (`Attest the packages and publish the release`; `needs:
  build`; `contents: write`, `id-token: write`, `attestations: write`): only
  `actions/*` pinned by SHA (checkout, download-artifact, attest-build-provenance,
  upload-artifact), `git`, `gh` and short `python3` steps of its own. It works
  the tag out again from the event (it takes nothing from the build job but
  the files), downloads the artifact, and checks it before signing: exactly
  the five files, `sha256sum --check --strict SHA256SUMS.txt`, and a manifest
  naming this tag, version and run's commit, `dev: false`, with each
  package's sha256 and size. Then the attestation, the bundle and the
  in-toto file (§5.2), the workflow artifact `hue-drivers-<tag>` with all
  seven release files (the six of the single job before, and the in-toto
  file), the tag push (dispatch only, a one-commit checkout without
  credentials), and the release with its title and notes from
  `CHANGELOG.md` (§5.2).
- `GH_TOKEN` (`github.token`) is set only on the steps that push the tag or
  call `gh`: the tag push and the release with its files, title and notes.

What a compromised tool in the build job can still do: put its own code
into the packages, which the attestation then truthfully describes as built
by `release.yml` from this commit. What it can no longer do: push or move
tags, replace the assets of any release, or sign provenance for files of its
choosing.

### 5.5 Pinned build inputs

Everything the CI and release jobs run is pinned, so that a new upstream
release reaches a build only through a reviewed change:

- **Actions** by full commit SHA (§2 conventions). Dependabot proposes new
  versions once a week, no sooner than **7 days** after their release
  (`cooldown: default-days: 7` in `.github/dependabot.yml`, finding 13;
  GitHub Actions supports `default-days` only, and security updates are never
  delayed), and `dependabot-auto-merge.yml` merges them once CI is green.
- **Snap One's packager** (`snap-one/drivers-driverpackager`) at a reviewed
  commit, fetched by SHA (`git init`, `git fetch --depth 1 origin <sha>`,
  `git checkout FETCH_HEAD`) in `ci.yml` and `release.yml`: today
  `16eef8beb70303606f066524cda516b2aa7ce38d`, the head of its master branch
  on 2026-10-25 (last changed 2024-08-28) and the commit of the VM's
  `~/c4-tools/drivers-driverpackager`. To move it: pull that copy, read
  `git log -p <pinned>..HEAD` there, and change the sha in both workflows in
  one pull request.
- **luarocks**: every rock at an exact version, dependencies included, each
  installed with `--deps-mode=none`, so luarocks fetches nothing the list
  does not name and a missing rock fails the job instead of arriving
  unpinned. The versions current on 2026-10-25, which the jobs installed
  before the pin and the VM runs: luacheck 1.2.0-1 (argparse 0.7.2-1,
  luafilesystem 1.9.0-1), busted 2.3.0-1 (dkjson 2.11-1, lua_cliargs
  3.0.2-1, luasystem 0.7.1-1, say 1.4.1-3, luassert 1.9.0-1, lua-term 0.8-1,
  penlight 1.15.0-1, mediator_lua 1.1.2-0). The same list stands in both
  workflows; move a rock in both in one pull request, after reading its
  changes.

The packager and the rocks are no Dependabot ecosystem, so nothing proposes
their updates: the weekly CI run keeps proving that the pinned set installs.

## 6. Desired state: `deploy/house.yaml`

Flat `key: value` lines, `#` comments, no nesting, no lists, no quoting
needed; `deploy.py` parses exactly this (split on the first `:`; strip;
ignore blank and comment lines; a value `"Off"` or `Off` is the string `Off`):

```yaml
# Desired state of the house installation. This file is the source of truth;
# a GitHub Deployment on the environment "house" is the observed state;
# .github/workflows/drift.yml opens one issue labelled "deploy" when they differ.
# docs/cicd-gitops-design.md, section 6.
environment: house
release: v1.0        # the GitHub release whose assets are installed
build: 247           # the build number its packages carry (Driver Version in Composer)
drivers: hue_bridge hue_light hue_scene
stream_timeout_s: 3600
stream_watchdog_s: 600
debug_mode: Off
```

`python3 tools/deploy.py validate` (exit 0/1): `environment` is `house`;
`release` matches `^v[0-9]+\.[0-9]+$`; `build` is a positive integer;
`drivers` is exactly the three names; `stream_timeout_s` 30–86400 and
`stream_watchdog_s` 60–3600, the minimum and maximum
`src/hue_bridge/driver.xml` declares for `Stream Timeout (s)` and `Stream
Watchdog (s)`, so that every value that validates can be set in Composer
(`tools/deploy.py`, `STREAM_TIMEOUT_RANGE` and `STREAM_WATCHDOG_RANGE`; a
unit test reads both ranges from the XML); the watchdog below the timeout,
so with a timeout of 30 to 60 s no watchdog validates; `debug_mode` is `Off`
(a release build never ships with debugging on). With `--online` it also
fetches the release's `manifest.json` and fails when its `build` differs
from the file's (CI runs the offline form; `drift` uses the online form).
Until issue #237 (2026-10-25) `validate` took 60–86400 and 30–3600, so a
watchdog of 30 to 59 s validated that Composer refuses.

Changing the desired state is a PR that edits `build:` (and `release:` when
the version changes). The release must exist first (§5), so the order is:
merge the code → cut the release → PR that bumps `deploy/house.yaml` →
merge → the drift workflow opens the deploy issue → the coordinator runs
`deploy.py start` → the Windows session installs → `deploy.py done`.

## 7. Observed state and the deploy tool: `tools/deploy.py`

Standard library only; talks to GitHub through `gh` (`gh api`, `gh release
download`, and for provenance `gh attestation verify`, which needs gh
2.102.0 or newer: the VM's apt `gh` 2.46 has no `gh attestation` at all),
repository from `gh repo view` or `--repo`. Subcommands:

- `validate [--online]`: §6.
- `start [--tag v1.0] [--supersede] [--note TEXT] [--no-attestation]`:
  resolves the tag (default `release:` from `house.yaml`), downloads
  `manifest.json`, `SHA256SUMS.txt` and the three packages from the
  release into `build/release/<tag>/`
  (fresh directory), verifies every sha256 against both files and that
  `manifest.build` equals `house.yaml`'s `build` and `manifest.commit` is the
  tag's commit; checks that a provenance attestation for each package's
  digest exists at `GET /repos/{owner}/{repo}/attestations/sha256:<digest>`
  and names that digest as a subject, then verifies who signed it (security
  review 2026-10-25, finding 12): `gh attestation verify <file> --repo
  <o>/<r> --signer-workflow <o>/<r>/.github/workflows/release.yml --format
  json` for each package, which checks the Sigstore signature and that the
  signing certificate names the release workflow, after which `start`
  checks again that every verified attestation's identity is
  `https://github.com/<o>/<r>/.github/workflows/release.yml@<ref>`. It
  refuses a gh older than 2.102.0 (2.51.0 to 2.101.0 match only the start of
  the workflow path, GHSA-wjmr-j3rp-mh2g; older ones lack the option), a
  failed verification and an empty result. `--no-attestation` accepts a
  package that has no attestation at all (a release cut before attestations
  existed), never one whose attestation fails; the brief says which packages
  were verified, with which gh and command;
  refuses when a deployment of environment `house` is still `in_progress`
  or `pending` unless `--supersede` (which marks that one `inactive` with a
  comment-style description); then creates the GitHub Deployment
  (`POST /repos/{o}/{r}/deployments`: `ref` = tag, `environment` = `house`,
  `auto_merge: false`, `required_contexts: []`, `production_environment:
  true`, `description` = `Build <N> (<tag>) to the house`, `payload` =
  `{"tag", "build", "commit", "packages": {name: sha256}, "note"}`), sets its
  status `in_progress` ("Packages verified; install through Composer
  pending"), writes `build/release/<tag>/deployment.json` (`id`, `url`,
  `tag`, `build`, `created`) and `build/release/<tag>/BRIEF.md`, and prints
  the brief's path and the deployment URL. The brief is what the
  coordinator sends to the Windows session (`docs/composer-remote.md`): the
  three GitHub download URLs
  (`https://github.com/<o>/<r>/releases/download/<tag>/<file>`), each
  file's sha256, the PowerShell to fetch them into
  `C:\c4-hue\drivers\<tag>\` and verify with `Get-FileHash`, the Composer
  steps (Driver ▸ Add or Update Driver or Agent…, all three at once, in
  place), what to read back (every device's `Driver Version` = `<N>`, the
  bridge's `Stream Timeout (s)`, `Stream Watchdog (s)` and `Debug Mode`
  against `house.yaml`), and the standing-approval sentence. The brief
  carries **no LAN address and no bridge id**. `--note` is quoted in the
  brief (for example "changes <capabilities>: the owner reboots the
  controller from System Manager after the install").
- `done [--devices N] [--note TEXT]`: reads `deployment.json` of the tag (or
  `--deployment ID`), sets status `success` with description `Driver
  Version <N> on <devices> devices, settings as deploy/house.yaml` (+ note),
  then runs the drift logic (§7.1) so the deploy issue closes at once.
- `failed --note TEXT`: status `failure` with the note (what the Windows
  session saw; which build the house still runs).
- `record --tag v1.0 --build 247 --at 2026-10-24T21:04:00-04:00 --note TEXT`:
  a success deployment for an install that happened before this tool
  existed (used once for build 247; also for any out-of-band install),
  `payload.recorded: true`. Refuses when `--build` does not match the
  release's manifest unless `--no-manifest` (build 247 has no manifest: it
  was built on the VM).
- `status`: prints desired (file) and observed (the newest deployment of
  `house` whose latest status is `success`, by `created_at`), exit 0 when
  `build` and `tag` agree, **3** on drift, 1 on error.
- `drift --issue`: §7.1 (what `drift.yml` runs). Without `--issue` it only
  prints, like `status`.

Current (2026-10-25, build 316): `start` also refuses while a deployment
is `queued` or has no status yet, and `deployment.json` also holds
`commit`, `repo`, `environment`, `environment_page`, `packages` and
`note`; `failed` also posts the note on the open deploy issue; `record`
also refuses a release without `manifest.json` unless `--no-manifest`,
takes `--commit SHA`, keeps the install time in `payload.installed_at`,
and runs the drift logic as `done` does (`tools/deploy.py:cmd_start`,
`cmd_failed`, `cmd_record`).

### 7.1 Drift logic

Desired: `house.yaml` (`release`, `build`). Observed: the newest `success`
deployment's payload (`tag`, `build`); none counts as drift. Drift when
`build` differs or `tag` differs.

With `--issue` (needs `issues: write`; in the workflow `GH_TOKEN` is
`GITHUB_TOKEN`):

- drift and no open issue labelled `deploy`: create `Deploy <tag> (build
  <N>) to the house` with label `deploy`, body: desired, observed (build,
  when, by which deployment), the release link, the command to run
  (`python3 tools/deploy.py start`), the reminder that the Composer click
  is the Windows session's and that a `<capabilities>` change needs the
  controller rebooted from System Manager;
- drift and an open `deploy` issue with another title: edit title and body,
  add one comment "desired state changed: …" (never a second issue);
- drift and the open issue already current: do nothing;
- no drift: close every open `deploy` issue with the comment `Build <N>
  (<tag>) recorded as deployed: <deployment url>`; never reopen, never
  delete, never edit closed issues.

Adding the issue to the project board needs a user token (`GITHUB_TOKEN`
cannot touch user projects): the workflow does not try; the coordinator
adds it when seen, with `gh project item-add 1 --owner corytron --url`.

`.github/workflows/drift.yml`: `push` to `main` with `paths:
[deploy/house.yaml]`, `deployment_status`, `schedule` weekly (Monday 06:30
UTC), `workflow_dispatch`; `permissions: contents: read, issues: write,
deployments: read`; runs `python3 tools/deploy.py drift --issue` and treats its exit 3 (drift) as
success, since drift is the report the run exists to make; exit 1 (an error)
fails the run. `GH_TOKEN: ${{ github.token }}`. The `deployment_status` trigger fires for statuses the
VM's `deploy.py` posts (a user token), so a `done` closes the issue twice
over: once from the VM, once from the workflow finding nothing to do.

## 8. Repository policy (coordinator, through the API, after the merge)

- Branch protection on `main`: required checks = the four job names of §4;
  `strict: true` (branch up to date before merge); `enforce_admins: true`;
  conversation resolution on (already); no force pushes, no deletions
  (already). Repository: `allow_auto_merge: true`, `allow_update_branch:
  true`, `delete_branch_on_merge` (already). Actions: default token
  read-only (already), `can_approve_pull_request_reviews` stays false.
  Dependabot security updates on. CodeQL default setup on. Tag ruleset §5.3.
- Labels: `.github/labels.json` gains `ci` ("Workflows, checks and the
  development tooling", `0e8a16`), `deploy` ("The house installation: drift
  between deploy/house.yaml and the recorded deployment", `1d76db`),
  `dependencies` ("Dependabot updates of pinned actions", `0366d6`).
  `tools/labels_sync.py [--repo o/n] [--check]`: creates missing labels,
  updates colour and description of existing ones, **never deletes**
  (prints the labels the repository has that the file does not);
  `--check` only reports (exit 3 when out of sync). `.github/workflows/labels.yml`
  runs it on `push` to `main` with `paths: [.github/labels.json]` and on
  dispatch (`permissions: issues: write`).
- `.github/workflows/dependabot-auto-merge.yml`: on `pull_request` from
  `dependabot[bot]` for the `github-actions` ecosystem only
  (`dependabot/fetch-metadata`), `gh pr merge --auto --merge` so it merges
  when the required checks pass; `permissions: contents: write,
  pull-requests: write`. Nothing else is ever auto-merged. (If a workflow
  of ours would be run against a Dependabot PR with secrets it needs, it
  isn't: our workflows need none.)
- `.github/dependabot.yml`: `github-actions` weekly grouped (as today) with
  the label `dependencies`, and `pip` for `/tools`
  (`tools/requirements-checks.txt`), weekly, grouped, label `dependencies`;
  reviewed, not auto-merged.
  Current (2026-10-25, build 316): the `pip` entry has the same 7-day
  cooldown as the actions (§5.5).

## 9. Automation decisions (edge cases before automation)

| Automation | Decision | Why |
| --- | --- | --- |
| CI checks on every PR and push | automatic | read-only, reproducible |
| Merging a PR | manual (coordinator) after green checks; auto-merge only for Dependabot action pins | code review stays human |
| Building the release artifacts | automatic on tag push or dispatch | from `main` only |
| Moving the `v1.0` tag | explicit trigger (dispatch or tag push), never on merge | a release is a decision |
| Installing on the house | **never automatic**: `deploy.py start` records intent and prepares; the Windows session installs; `deploy.py done`/`failed` records the result | no install API; a wrong install needs hands to undo |
| Drift issue | automatic open/update/close of one `deploy` issue; never reopen, never delete, never edit closed ones | a record, not an actor |
| Labels | automatic create/update; delete forbidden | a deleted label loses its history on issues |
| Dependabot | automatic PRs; auto-merge for action pins only | CI gates them; everything else is reviewed |
| Scorecard, CodeQL | automatic, read-only reports | |
| Code scanning issue | automatic open/update/close of one `security` issue; never dismisses an alert, never reopens or edits closed issues, never a second | a record, not an actor; a dismissal is a decision with a reason |

Corner cases decided: the tag moves while a deployment is `in_progress` →
`deploy.py start` of the new build refuses until `done`/`failed`/`--supersede`;
the assets are replaced after `start` → `done` re-reads the manifest and
refuses when the recorded build differs; `house.yaml` names a build the
release does not carry → `validate --online` fails (CI's offline form
passes; the drift run fails loudly in Actions); the Windows session cannot
install → `failed`, the deploy issue stays open with the note; a GitHub
error after the deployment is created → `start` writes `deployment.json`
before anything that can fail afterwards and `start --resume` is not
needed: `done --deployment ID` takes the id from the deployment list;
`deploy.py` run from any branch or a dirty checkout → unaffected, it reads
GitHub, not the tree (except `house.yaml`); a package whose attestation a
workflow other than `release.yml` signed, or a `gh` too old to tell
(before 2.102.0) → `start` refuses before the deployment exists, with or
without `--no-attestation` (§7).

## 10. Done when

- A PR on this branch shows the four jobs green; `tools/check.sh --strict`
  passes on the VM after `tools/setup-checks.sh` (with `powershell`
  skipped: no `pwsh` on the VM, so the VM run is `--strict` with
  `--only` everything but `powershell`, and the contract says so).
- `v1.0` re-cut from the merge commit by the dispatch path carries the
  packages, `SHA256SUMS.txt`, `manifest.json` and the attestation bundle,
  and the generated notes.
  Current (2026-10-25): `v1.0` carries the seven files of §5.2, the
  in-toto file included (read with `gh release view v1.0`).
- `deploy/house.yaml` set to that build in a PR; the drift workflow opens
  `Deploy v1.0 (build N) to the house`; `deploy.py start` → the Windows
  session installs from the GitHub URLs → `deploy.py done` → the issue is
  closed by the tool, the environment page shows the deployment, `deploy.py
  status` exits 0.
- Branch protection, repository settings, labels, tag ruleset, CodeQL as §8.
- README (badges, "How a change reaches the house"), CONTRIBUTING (the
  checks, `tools/check.sh`), `docs/release-checklist.md` (release by
  dispatch, deploy by `deploy.py`, no build-number stamping: the README
  and status link to the Releases and Environments pages instead),
  `CLAUDE.md` (Deploy section), `docs/status.md`, this document, and a
  Discussions post of the hand-backs.
