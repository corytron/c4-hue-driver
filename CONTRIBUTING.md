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
  development machine, `001788fffe25b8f8` for a bridge id (Signify's own
  documentation example), and the RFC 5737 ranges (`192.0.2.0/24`,
  `198.51.100.0/24`, `203.0.113.0/24`) for any other example address in
  code, tests and design notes (the manual and the README may use
  home-network-looking examples such as `192.168.1.50`). Screenshots are
  taken on a demo project with invented names.
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
- **Commits.** Small, working steps with clear messages; one branch and one
  pull request per feature.

## Pull request checklist

- `luacheck src tests tools` and `busted tests` pass; `tools/build.sh` builds
  the three `.c4z` files.
- The manual and `docs/status.md` are updated if behaviour or a text changed.
- A change to a `driver.xml` `<capabilities>` block is called out in the PR
  description: installing it makes Composer ask "Restart Director?" and users
  must reboot their controller.
- No private data (grep for your own addresses and ids before pushing).
- Say whether you ran it on a controller, and with which Control4 OS and
  bridge model; an untested change is fine if it says so.

## Reporting a problem

Open a GitHub issue with the details the README asks for (Driver Version,
Control4 OS version, bridge model, the property texts, the Lua output with
private data replaced). For something security-sensitive, for example a way
to read the stored application key, use GitHub's private vulnerability
reporting on this repository, if it is enabled, or contact the author
privately instead of opening a public issue.
