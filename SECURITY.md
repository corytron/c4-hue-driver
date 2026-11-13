# Security policy

This is a personal project for one Control4 home, offered as is under the
Apache License 2.0. Security reports are welcome all the same and are handled
in good faith, on a best-effort basis.

## Supported versions

Only the **latest release** on the
[Releases page](https://github.com/corytron/c4-hue-driver/releases) is
supported: the four `.c4z` files attached to it, identified by the build
number they show as **Driver Version** in Composer. Older builds get no
fixes; update in place through Composer's *Add or Update Driver or Agent...*
([README, Updating](README.md#updating)). Prereleases for testers
(`X.Y-beta.N`) are not supported versions: what you find in one goes to its
Beta feedback form, or, when it is security-sensitive, privately as below.
Development builds (`tools/build.sh --dev`) are for the developer's own test
system, carry the developer's dev-loop key, and are never supported as a
production driver; their Driver Version reads the build number followed by
`-dev`, so one can be told from the release of the same number.

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
  bridge counts, apart from the known case of a rooted Hue bridge
  ([Trust boundaries](#trust-boundaries), the address follow-up).
- **The development loop.** Development builds (`--dev`) fetch driver code
  from a developer's machine (`tools/devserver.py`) and run actions queued
  with `tools/devctl.py`, both signed with the developer's dev key, which
  each development package carries. A release build must contain none of it,
  neither the dev-loop modules nor the key nor the development-only
  properties and actions (`tools/build.sh` refuses to package one that
  does); a released package that does, or a way to make a release build
  fetch or run code from the network, is a vulnerability. A release build
  also tells Director that Composer's Lua command window may not run code
  in it, and warns in its Lua output at start if a development module is
  loaded. The developer serves a development or test package to the
  controller only for the length of an install, from a temporary folder
  under a random path (`tools/serve_install.py`) that is deleted
  afterwards.

Not covered here: Control4 OS, Composer Pro, Director and the Hue bridge
firmware belong to Snap One and Signify; report problems in them to those
companies. What someone already on your LAN can do by talking to the bridge
directly is the Hue API's own threat model, not this driver's.

## Trust boundaries

What the drivers rely on, and what follows where that does not hold.

- **Other drivers in the same Control4 project (#483).** Control4 does not
  tell a driver which driver sent it a command or a message. So any driver
  installed in the same project can run the Hue Bridge's actions just as
  Composer's Actions tab does, **Forget Pairing** and **Hue Automations**
  included, and can send messages to the Hue Light, Hue Scene and Hue
  Motion Sensor devices. Install only drivers you trust. A Control4 driver
  can already command every other device in the house, so a hostile one
  gains little here that it lacks elsewhere.
  - *Protected:* no action or message reads out, shows or passes on the
    application key; none makes the Hue Bridge driver send a request of the
    caller's choosing (each request has a fixed form and names a light,
    scene or automation the driver already knows); and a linked device
    ignores a message that names another Hue light, scene or sensor than
    its own, or none. A device takes Control4's light and keypad commands
    only on the connections meant for them, and every number and identifier
    that comes from another driver is checked and dropped when it does not
    fit.
  - *Not protected:* such a driver can forget the pairing (pairing again
    takes a press of the bridge's link button), switch Hue automations off
    or on, rename lights and scenes on either side, add or forget devices,
    and switch, dim or recall the lights and scenes. A driver that knows a
    device's own Hue identifier can also send that device a state message,
    such as a motion report, which Control4 programming then acts on. Every one of the Hue
    Bridge's actions writes its **Last Action**, so a forged action shows
    there, and each can be undone.
- **The address follow-up (#491).** When the paired bridge has not answered
  at its address for 5 minutes, or another bridge answers there, the Hue
  Bridge driver searches the local network for it. It moves **Bridge IP
  Address** only to a bridge that has a certificate from Signify's roots,
  reports the paired bridge's identifier and passes the TLS check, and it
  says so in **Last Action** and, for a day, in **Attention**. The residual
  risk: the identifier is public, and no Control4 API lets the driver
  compare it with the name in the certificate. A host on the LAN that holds
  a Signify-issued bridge certificate *and its private key*, in practice a
  Hue bridge whose owner has rooted it, could answer with the paired
  identifier while the real bridge is away (a power cut, a router restart,
  a long update). The driver would follow it and send it the application
  key, which controls every Hue light. A stock Hue bridge cannot do this.
  The follow-up stays, by the owner's decision of 2026-11-13: without it,
  every Hue light stops each time the router gives the bridge a new
  address, until someone types the new one; and such a host could take the
  bridge's address on the network anyway (ARP or DHCP), which the
  follow-up only spares it. Reserve the bridge's address in the router and
  the follow-up never has to run. A move in **Last Action** that you cannot
  explain is worth a look at the router's list of devices, and a report.
- **Debug Mode (#493).** With **Debug Mode** On a driver writes much more
  to its Lua output (names, levels, motion states, the bridge's address;
  never the application key), and Director logs the messages between the
  Hue Bridge and its devices. So that this does not stay on because someone
  forgot it, Debug Mode turns itself Off 8 hours after it was set to On, on
  each of the four drivers, and **Last Action** says so. A restart of the
  controller or the driver keeps the time that is left.

## What is checked automatically

- **Secrets and private data.** Every pull request and every push to `main`
  runs `gitleaks` with the repository's rules (`.gitleaks.toml`) over the
  working tree and the git history of the commit under test; locally,
  `tools/check.sh` runs the same rules over the tree and the history of
  every local branch and tag. A real key, token, private key or LAN address
  fails it. GitHub's secret scanning and push protection are on as well.
- **The Documentation tabs.** Composer shows each driver's Documentation
  tab in a web view, so the `doc-tabs` check (in `tools/check.sh` and CI's
  tooling job) refuses a script, a frame, an embedded object, an `on…=`
  attribute, or a source or stylesheet that is not a relative path, in any
  of them.
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
- **Build provenance.** The Release workflow lints and tests in one job and
  builds the packages from a clean checkout in another, which installs none
  of the lint and test tools; both have read-only access. A third job, which
  runs no third-party code, signs one build-provenance attestation naming
  the four packages; the
  bundle is also attached to the release as `attestations.sigstore.json`,
  and its in-toto envelope as `hue-drivers.intoto.jsonl`. Verify a download,
  once per package, with

  ```sh
  gh attestation verify hue_bridge.c4z --repo corytron/c4-hue-driver \
    --signer-workflow corytron/c4-hue-driver/.github/workflows/release.yml \
    --source-digest <commit> --signer-digest <commit> --deny-self-hosted-runners
  ```

  where `<commit>` is the `commit` from the release's `manifest.json`, and
  check the checksum against `SHA256SUMS.txt`. The two digests tie the
  package to the commit it was built from and to that commit's own Release
  workflow; `tools/deploy.py` also checks that the commit is on `main` (#482).
  Use GitHub CLI 2.102.0 or newer: `--signer-workflow` is what makes the
  Release workflow the only accepted signer (without it, any workflow of the
  repository would do), and older versions either lack it or match only the
  start of the workflow's path (GHSA-wjmr-j3rp-mh2g). `tools/deploy.py
  start` runs the same command for each package before an install of the
  house, pinned as well to `main` and to the commit the release's tag
  points at, which must be on `main`. It refuses a package that fails it,
  and a manifest that names another tag or does not say it is a release
  build. A package that fails either
  check was not built by this repository's Release workflow: do not install
  it, and report it.

## What to expect

A personal project: no service level, no bounty. The author reads reports as
soon as he can, confirms receipt, and fixes a confirmed problem in a new
build on the Releases page, with a release note saying what changed. You are
credited there if you want to be. Please allow a reasonable time before
publishing details.
