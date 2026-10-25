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
developer's own test system and are never supported as a production driver.

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
  controller and never shows it: not in a property, not in the Lua output,
  not in `Last Action`. Any way to read it back out of the driver (a
  property, a log line, an action result, a file in a package) is a
  vulnerability.
- **TLS.** All traffic to the bridge is HTTPS, verified against the two
  Signify root certificates shipped in `src/hue_bridge/certs/`. Anything that
  makes the driver accept another certificate, fall back to plain HTTP, or
  send the key to a host that is not the paired bridge counts.
- **The development loop.** Development builds (`--dev`) fetch driver code
  from a developer's machine (`tools/devserver.py`) and run actions queued
  with `tools/devctl.py`. A release build must contain none of it
  (`tools/build.sh` checks); a released package that does, or a way to make a
  release build fetch or run code from the network, is a vulnerability.

Not covered here: Control4 OS, Composer Pro, Director and the Hue bridge
firmware belong to Snap One and Signify; report problems in them to those
companies. What someone already on your LAN can do by talking to the bridge
directly is the Hue API's own threat model, not this driver's.

## What is checked automatically

- **Secrets and private data.** Every pull request and every push to `main`
  runs `gitleaks` over the working tree and the whole git history with the
  repository's rules (`.gitleaks.toml`); the same check runs locally in
  `tools/check.sh`. A real key, token, private key or LAN address fails it.
- **Code scanning.** GitHub's CodeQL default setup scans the Python tooling
  and the workflows; alerts are on the repository's Security tab.
- **OpenSSF Scorecard** rates the repository's practices (pinned actions,
  branch protection, token permissions, signed releases) on every push to
  `main` and weekly:
  <https://scorecard.dev/viewer/?uri=github.com/corytron/c4-hue-driver>.
- **Build provenance.** The Release workflow builds the packages and signs a
  provenance attestation for each; the bundle is also attached to the
  release as `attestations.sigstore.json`. Verify a download with
  `gh attestation verify hue_bridge.c4z --repo corytron/c4-hue-driver`
  (GitHub CLI 2.49 or newer; repeat per package) and its checksum against
  `SHA256SUMS.txt`. A package that fails either check was not built by this
  repository's workflow: do not install it, and report it.

## What to expect

A personal project: no service level, no bounty. The author reads reports as
soon as he can, confirms receipt, and fixes a confirmed problem in a new
build on the Releases page, with a release note saying what changed. You are
credited there if you want to be. Please allow a reasonable time before
publishing details.
