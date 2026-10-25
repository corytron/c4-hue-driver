# Contributing

This is a personal project for one Control4 home, offered as is: there is no
roadmap and no support obligation. Bug reports and pull requests are welcome
all the same. This page says what a contribution has to respect; the
[README](README.md) says what the driver does and how it is built and tested.

## License of contributions

Contributions are accepted under the Apache License 2.0 (License §5, inbound
= outbound): by submitting a pull request you agree that your contribution is
licensed under the same terms as the project, without any additional terms or
conditions. No contributor agreement is needed. Signing off your commits
(`git commit -s`, the Developer Certificate of Origin) is welcome but
optional.

## What never goes into the repository

- **Code or text from Snap One.** Nothing from `drivers-common-public`,
  `drivers-template-code-public`, `drivers-driverpackager` or the DriverWorks
  documentation (API, Fundamentals, proxy references): their license keeps them
  confidential and assigns derivative works to Snap One. Cite a documentation
  file by name when you rely on it; do not quote it, and re-implement rather
  than vendor. The packager is cloned separately by whoever builds.
- **Text from Signify's login-walled developer pages.** The Hue Developer
  Program Terms forbid republishing API content. Facts in your own words
  (endpoint names, limits, field meanings) are fine, with a citation.
- **Private data.** Never a real LAN address, bridge id, application key,
  certificate other than the two public Signify roots in
  `src/hue_bridge/certs/`, Composer project name, or a screenshot of a real
  project. Placeholders: `10.0.2.143` for the bridge, `192.0.2.7` for the
  development machine, `001788fffe123abc` for a bridge id in documents and
  `001788fffe25b8f8` (Signify's own documentation example) in the test
  fixtures, and the RFC 5737 ranges (`192.0.2.0/24`, `198.51.100.0/24`,
  `203.0.113.0/24`) for any other example address, in code, tests and
  documents, the manual and the README included (the secrets check accepts
  zero-padded spellings of `10.0.2.143` and of `192.0.2.x`, but in
  `198.51.100.x` and `203.0.113.x` only of the last number). Screenshots
  are taken on a demo project with invented names. Since 2026-10-25 these
  rules are enforced: the `secrets` check runs `gitleaks` with the
  repository's rules (`.gitleaks.toml`) over the working tree and the whole
  history, in CI on every pull request and locally in `tools/check.sh`; the
  placeholders above are allowed, and anything that looks like a key, a
  token, a private key or one of the author's addresses fails the check.
- **Logos, badges or trade dress** of Snap One or Signify, and any wording
  that suggests affiliation, certification or endorsement. "Works with
  Philips Hue" and "for Philips Hue" are the allowed phrasings.

## Conventions

- **Lua 5.1.** The controller runs the drivers under LuaJIT with Lua 5.1
  semantics: no 5.2+ features, no C modules, no `require` of anything that is
  not packaged in the driver. Only documented DriverWorks APIs; when a call's
  behaviour is uncertain, say in the PR what you verified on a controller and
  what you assumed, naming the documentation file.
- **Style.** Tabs for indentation, lines of at most 120 characters,
  `luacheck src tests tools` clean (the rules are in `.luacheckrc`, including
  the list of DriverWorks entry points and the `CUSTOM_SELECT` list functions
  each `driver.xml` names).
- **Tests.** `busted` specs in `tests/spec/*_spec.lua`, in the style of the
  existing ones, run the drivers against the fake DriverWorks runtime in
  `tests/helpers/fake_c4.lua` (add a method there when a driver starts using
  a new documented API, mirroring the real colon-call signature) and the
  invented Hue resources in `tests/fixtures/hue_resources.lua`. Every change
  of behaviour comes with a spec; `busted tests` stays green.
- **Three drivers, one build.** `tools/build.sh` stages `src/common/` into
  each driver (the bridge without `device.lua`; release builds without
  `devloop.lua` and the bridge's development modules) and stamps all three
  with the same build number (the commit count), so a change to a shared
  module is a change to all three.
- **Texts users read.** Property texts, `Last Action` results and `Attention`
  lines are part of the contract: the manual
  (`src/hue_bridge/www/documentation.html`) quotes them. A change to one
  changes the manual too, and `docs/status.md` records what now runs.
- **Automation needs a contract first.** Anything that acts on its own over
  the life of the system (importing, syncing names or rooms, creating or
  removing devices) starts with the lifecycle corner cases on both sides,
  written up under `docs/` with a decision per case: automatic, offered, or
  forbidden without a click. The driver never creates, renames, moves or
  deletes a Control4 device by itself; keep it that way.
- **Tooling.** Python under `tools/` is 3.12 or newer, standard library only,
  `ruff` clean under `ruff.toml` (`ruff check tools` and `ruff format --check
  tools`), with `unittest` tests under `tools/tests/`. Shell scripts are bash
  with `set -euo pipefail` and `shellcheck -S style` clean. Workflows pass
  `actionlint` and `zizmor`: every action pinned to a full commit SHA with
  the version in a trailing comment, every job with `timeout-minutes` and
  the least `permissions:` it needs.
- **Commits.** Small, working steps with clear messages; one branch and one
  pull request per feature.

## Checks

One script runs every check, the same way on your machine and in CI:

```sh
tools/setup-checks.sh   # once: installs the tools below into ~/.local/bin, without sudo
tools/check.sh          # before a pull request
```

| Check | What it runs | What it covers |
| --- | --- | --- |
| `lua-lint` | `luacheck src tests tools` | the drivers, the specs and the Lua in `tools/` |
| `lua-test` | `busted tests` | the specs, against the fake DriverWorks runtime |
| `shell` | `shellcheck -S style tools/*.sh` | the shell scripts |
| `python-lint` | `ruff check tools`, `ruff format --check tools` | the Python tooling |
| `python-test` | `python3 -m unittest discover -s tools/tests` | the tooling's unit tests |
| `xml` | an `xml.etree` parse | every `src/*/driver.xml` is well-formed |
| `powershell` | `Invoke-ScriptAnalyzer -Severity Error` | `tools/composer/`; skipped without `pwsh` |
| `workflows` | `actionlint`, `zizmor --min-severity medium` | `.github/workflows/` |
| `secrets` | `gitleaks dir`, `gitleaks git` with `.gitleaks.toml` | the working tree and the whole history |
| `house` | `python3 tools/deploy.py validate` | `deploy/house.yaml`, the house's desired state |

`tools/check.sh --only <name>...` runs a selection. A check whose tool is
not installed is reported as `skip` and does not fail the run; CI runs the
same script with `--strict`, where a skip is a failure, in four jobs whose
names are the required checks on `main`: *Lint and test (Lua 5.1)*, *Build
the three .c4z packages*, *Tooling checks (shell, Python, XML, workflows)*
and *Secrets and private data*. The tool versions are pinned with their
sha256: actionlint and gitleaks in `tools/setup-checks.sh`, which verifies
what it downloads, and ruff, zizmor and shellcheck-py in
`tools/requirements-checks.txt`, which pip enforces (`--require-hashes`).

## Pull request checklist

- `tools/check.sh` passes (CI runs the same checks with `--strict`) and
  `tools/build.sh` builds the three `.c4z` files.
- The manual and `docs/status.md` are updated if behaviour or a text changed.
- A change to a `driver.xml` `<capabilities>` block is called out in the PR
  description: installing it makes Composer ask "Restart Director?" and users
  must reboot their controller.
- No private data: the `secrets` check runs gitleaks, but grep for your own
  addresses and ids before pushing all the same; the rules are above.
- Say whether you ran it on a controller, and with which Control4 OS and
  bridge model; an untested change is fine if it says so.

## Labels and merging

Issues and pull requests carry the labels in `.github/labels.json`, which a
workflow keeps in sync (it creates and updates labels and never deletes one).
Two of them concern the tooling: `ci` for workflows, checks and the
development tooling, and `deploy` for the house installation, the one issue
the drift workflow opens while `deploy/house.yaml` and the recorded
deployment differ. A pull request is merged by the maintainer once the four
checks are green and the review is done. The one exception is Dependabot's
updates of the pinned actions, labelled `dependencies`, which merge on their
own when the checks pass; no other pull request is auto-merged.

## Reporting a problem

Open a GitHub issue with the details the README asks for (Driver Version,
Control4 OS version, bridge model, the property texts, the Lua output with
private data replaced). For something security-sensitive, for example a way
to read the stored application key, use GitHub's private vulnerability
reporting on this repository, if it is enabled, or contact the author
privately instead of opening a public issue.
