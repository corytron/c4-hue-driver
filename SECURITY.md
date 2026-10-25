# Security policy

This is a personal project for one Control4 home, offered as is under the
Apache License 2.0. Security reports are welcome all the same and are handled
in good faith, on a best-effort basis.

## Supported versions

Only the **latest release** on the
[Releases page](https://github.com/corytron/c4-hue-driver/releases) is
supported: the three `.c4z` files attached to it, identified by the build
number they show as **Driver Version** in Composer. Older builds get no
fixes; update in place through Composer's *Add or Update Driver or Agent...*
(see the README). Development builds (`tools/build.sh --dev`) are for the
developer's own test system, carry the developer's dev-loop key, and are
never supported as a production driver.

## Reporting a vulnerability

Please do not open a public issue for anything security-sensitive. Use
GitHub's private vulnerability reporting on this repository (**Security >
Report a vulnerability**, or
<https://github.com/corytron/c4-hue-driver/security/advisories/new>). If
that is not available to you, contact the author privately through his
GitHub profile, [@corytron](https://github.com/corytron), instead of
posting details anywhere public.

Include the build number (Driver Version), the Control4 OS version, the
bridge model, what you found and how to reproduce it. Replace your LAN
addresses and the bridge id with placeholders, and never send your
application key.

## What counts

- **The application key.** The driver stores the Hue application key on the
  controller, in its persistent storage with the encrypted flag, and a
  release build never shows it: not in a property, not in the Lua output,
  not in `Last Action`. Any way to read it back out of a release build (a
  property, a log line, an action result, a file in a package) is a
  vulnerability.
- **TLS.** All traffic to the bridge is HTTPS. Every request a release
  build sends there is verified against the two Signify root certificates
  shipped in `src/hue_bridge/certs/`, except the TLS self-check's one
  request without the key, which uses the decoy CA there and must fail. Host
  names are not checked, because the bridge's certificate names its bridge
  id, not its address; instead the driver asks the bridge for its id,
  without the key, and sends the key only to the paired one, once the TLS
  self-check has shown on this Director version that the controller applies
  the Signify roots. Anything that makes
  the driver accept a certificate that does not chain to those roots, fall
  back to plain HTTP, or send the key to a host that is not the paired
  bridge counts.
- **The development loop.** Development builds (`--dev`) fetch driver code
  from a developer's machine (`tools/devserver.py`) and run actions queued
  with `tools/devctl.py`, both signed with the developer's dev key, which
  each development package carries. A release build must contain none of it,
  neither the dev-loop modules nor the key nor the development-only
  properties and actions (`tools/build.sh` refuses to package one that
  does); a released package that does, or a way to make a release build
  fetch or run code from the network, is a vulnerability.

Not covered here: Control4 OS, Composer Pro, Director and the Hue bridge
firmware belong to Snap One and Signify; report problems in them to those
companies. What someone already on your LAN can do by talking to the bridge
directly is the Hue API's own threat model, not this driver's.

## What is checked automatically

- **Secrets and private data.** Every pull request and every push to `main`
  runs `gitleaks` with the repository's rules (`.gitleaks.toml`) over the
  working tree and the git history of the commit under test; locally,
  `tools/check.sh` runs the same rules over the tree and the history of
  every local branch and tag. A real key, token, private key or LAN address
  fails it. GitHub's secret scanning and push protection are on as well.
- **Code scanning.** GitHub's CodeQL default setup scans the Python tooling
  and the workflows on every pull request, every push to `main` and weekly,
  and OpenSSF Scorecard's findings land beside them on the Security tab.
  After each push to `main` the code scanning triage workflow waits (up to
  30 minutes) for the scans of that commit, and it runs daily and on request
  too. It keeps one issue labelled `security`, *Code scanning: N open
  alert(s) on main*, with a table of the open alerts and the count of open
  Dependabot alerts: opened when alerts appear, updated with a comment when
  the set changes, closed when none remain. It never dismisses an alert:
  the maintainer fixes each through a pull request or dismisses it with its
  reason, and checks secret scanning alerts separately, since the workflow's
  token cannot read them. CodeQL has no Lua support: the drivers are covered
  by luacheck and the busted specs.
- **Pinned dependencies.** Every GitHub Action in the workflows is pinned to
  a full commit SHA. Dependabot proposes updates once a week, grouped, no
  sooner than 7 days after an upstream release (its cooldown; security
  updates are not delayed), and Dependabot security updates are on. Action
  updates merge on their own once the four required checks pass; updates of
  the Python check tools, pinned with the sha256 of every file in
  `tools/requirements-checks.txt`, are reviewed by hand. Snap One's packager
  and the luarocks tools are pinned in the workflows (a commit, exact
  versions) and moved by hand after reading their changes.
- **OpenSSF Scorecard** rates the repository's practices (pinned actions,
  branch protection, token permissions, signed releases) on every push to
  `main`, when branch protection changes, and weekly:
  <https://scorecard.dev/viewer/?uri=github.com/corytron/c4-hue-driver>.
- **Build provenance.** The Release workflow builds the packages in one job,
  with read-only access, and in a second job that runs no third-party code
  signs one build-provenance attestation naming the three packages; the
  bundle is also attached to the release as `attestations.sigstore.json`,
  and its in-toto envelope as `hue-drivers.intoto.jsonl`. Verify a download,
  once per package, with

  ```sh
  gh attestation verify hue_bridge.c4z --repo corytron/c4-hue-driver \
    --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml
  ```

  and its checksum against `SHA256SUMS.txt`; `--source-digest` with the
  `commit` from `manifest.json` also checks the commit it was built from.
  Use GitHub CLI 2.102.0 or newer: `--signer-workflow` is what makes the
  Release workflow the only accepted signer (without it, any workflow of the
  repository would do), and older versions either lack it or match only the
  start of the workflow's path (GHSA-wjmr-j3rp-mh2g). `tools/deploy.py
  start` runs the same command for each package before an install of the
  house and refuses a package that fails it. A package that fails either
  check was not built by this repository's Release workflow: do not install
  it, and report it.

## What to expect

A personal project: no service level, no bounty. The author reads reports as
soon as he can, confirms receipt, and fixes a confirmed problem in a new
build on the Releases page, with a release note saying what changed. You are
credited there if you want to be. Please allow a reasonable time before
publishing details.
