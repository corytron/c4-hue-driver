# Control4 ⇄ Philips Hue driver

Custom Control4 DriverWorks driver that controls Philips Hue lighting through the Hue bridge's local API. Personal project for one home, public on GitHub under the Apache License 2.0 since 2026-10-24 (see "Licensing" below).

## How I want you to work

- **Plan first, then build.** For any new feature or fix, explore, then state the approach and the files you'll touch. **Standing approval (2026-10-24): I approve everything, every time** — plans, installs, Director restarts, Composer changes, deletes, merges. Don't stop to ask me to confirm; do it and report. Ask only when a real design choice needs my answer or something needs my hands (a controller reboot from System Manager, a physical switch test).
- **Edge cases before automation.** Before designing anything that acts on its own over the life of the system (importing, syncing names or rooms, creating or removing devices), send research agents to enumerate the lifecycle corner cases on both sides (Hue and Control4: things added, moved, renamed, replaced, removed, restored from backup) and decide per case what is automatic, what is only offered, and what is forbidden without a click. The findings go into the feature's contract under `docs/` before any code. Automation that makes a later manual fix harder is wrong.
- Commit in small, working steps with clear messages. Never push directly to `main` (it is protected: pull requests only, the four CI checks of `.github/workflows/ci.yml` must pass, the branch must be current); use a branch and open a PR with `gh`.
- **Everything runs through GitHub** (owner, 2026-10-24, the repository is public): find or create the issue first (`gh issue create`, labels from `.github/labels.json`, added to project board 1 "Hue driver"); branch from `main` with the issue number in the name; open the PR early with "Closes #N" in its body; close an issue a merged PR fixed with a one-line comment naming the PR and the build; releases are tags `vX.Y` (`docs/release-checklist.md`); decisions for me go into an issue labelled `question`; hardware findings go into the issue as comments. `docs/status.md` stays the summary and points at the issues. **GitHub Discussions is the archive of every report** (owner, 2026-10-24): each sub-agent hand-back, each Windows Composer session round, each review or research document and each release is posted there as it arrives (`tools/gh-discussion.py`; releases in Announcements, reports in Show and tell or General, decisions in Ideas), with private data replaced by the placeholders. **Major versions are codenamed after Star Wars: Andor** (1.0 is "Cassian", and every 1.x release keeps that name): before cutting a new major version, propose a widely recognised character, place or object from the show and wait for my approval.
- **Code scanning after every merge** (owner, 2026-10-25): every push to `main` is scanned again (CodeQL default setup for Python and Actions, and the Scorecard workflow). `.github/workflows/code-scanning-triage.yml` then waits for those scans and keeps one issue labelled `security`, "Code scanning: N open alert(s) on main" (`tools/code_scanning_issue.py`; it opens, updates and closes that issue itself and never dismisses anything). After every merge, read that issue or `gh api "repos/corytron/c4-hue-driver/code-scanning/alerts?state=open"`. Open an issue per real finding and fix it through a PR that closes it. Dismiss a false positive, or a Scorecard check that cannot apply to a one-maintainer project, with its reason (`gh api -X PATCH repos/corytron/c4-hue-driver/code-scanning/alerts/N -f state=dismissed -f dismissed_reason="false positive|won't fix|used in tests" -f dismissed_comment="…"`), and say so in the issue or PR that decided it. The workflow's token cannot read secret scanning alerts: check those with `gh api "repos/corytron/c4-hue-driver/secret-scanning/alerts?state=open"`. The triage issue is opened with `GITHUB_TOKEN`, which cannot add it to the project board: add it with `gh project item-add 1 --owner corytron --url <issue>`.
- **One branch and one PR per feature.** Create the branch from `main` when the feature's contract is written, before any agent starts, so every commit lands somewhere reviewable under the right title; open the PR with `gh` as soon as the first integrated commit is on it. When a branch has done its job, merge it rather than letting the next feature pile onto it.
- When something about the Control4 or Hue APIs is uncertain, check the docs (paths below) and tell me what you verified versus what you're assuming. Do not invent DriverWorks API calls.
- Never commit secrets: Hue application keys, bridge IPs from my LAN, or certificates. Use placeholders in tests and examples.

## Working with agents

**Parallel by default.** For every piece of work, split it into parts that touch disjoint files and run them as background agents at the same time: module and its spec, VM-side tooling, changes to existing modules and their specs, docs and design notes. A single serial pass is only acceptable when the work truly cannot be split (one file, a handful of edits). Before starting any task, say in one line how it is being split and which agent owns which files; if it is not being split, say why.

- **Coordinator first.** Before spawning, write the contract the pieces share (an interface, a wire protocol, a file layout) into `docs/` so every agent builds against the same text. Then spawn them in one go, in the background.
- **One writer per file.** Each brief names the exact files the agent may create or edit and says that others are editing the rest of the checkout concurrently. No agent runs `git`; the coordinator integrates, runs `tools/check.sh` (every check CI runs) and `tools/build.sh`, and commits.
- **Briefs are self-contained.** Agents start cold: include the doc paths to read, the conventions (Lua 5.1, tabs, `.luacheckrc`, busted style, the fake C4 runtime), the hardware facts that matter, and what "done" looks like, including the verification commands to run.
- **Research agents are read-only** and write one new file under `docs/` (for example a design for a new transport), citing the SDK doc file for every API claim.
- Typical split for a feature: VM-side tooling (Python) / driver-side Lua module plus its spec / changes to existing modules plus their specs / a design or research document. Integration into `driver.lua`, `driver.xml`, `tools/build.sh` and `CLAUDE.md` stays with the coordinator.
- Don't spawn for quick things (one file, a handful of edits); do it inline. Everything larger is split.
- Spawn every agent at the highest effort (`effort: "max"`; the owner calls it "ultracode"), whatever the task.
- While agents run, the coordinator does the integration pieces nobody else owns (`driver.lua`, `driver.xml`, `tools/build.sh`, `CLAUDE.md`) and verifies through the dev loop, rather than waiting idle.

## Environment

- This repo lives on an Ubuntu 26.04 VM on my home LAN. You run everything here: builds, lint, tests.
- I drive you from a Mac via the Claude Desktop app (SSH session). I can't run commands on the Mac for you.
- Loading the driver onto the real controller happens in **Composer Pro on a separate Windows VM**. You can't run Composer yourself, but a Claude Code session in the Claude app **on that Windows VM** can: both sessions have Remote Control on, it shows up as a peer in `ListAgents`, and you brief it with `SendMessage` (`docs/composer-remote.md`). It reads Composer through Windows UI Automation from PowerShell, clicks, and takes screenshots; reading and cancelling are always fine, anything hard to undo (deleting devices, Update Driver, Connections, project load/save, restarts) is covered by my standing approval: say so in every brief, so the Windows session acts without asking me again on its side. Since 2026-10-22 the house runs **production builds** (no dev loop); installs go through the Windows session (Deploy below). A build that changes a driver's `<capabilities>` makes Composer ask "Restart Director?", and answering Yes does **not** load it: the owner must **reboot the controller from System Manager** (it runs elevated; the Windows session cannot operate it), so say so in the brief. Lua-only and connection-only changes take effect at once. To test Lua on the live controller yourself, the **dev loop** (`docs/dev-loop.md`) is still there: install a `--dev` build the same way, and the bridge fetches its code from `tools/devserver.py`, runs actions queued with `tools/devctl.py` and ships its log back; a release build ends it again. Always update the driver **in place** in Composer; deleting and re-adding it loses the pairing.
- The controller runs OS 3.4.2 and is on this VM's LAN; the house bridge is a Hue Bridge Pro (BSB003).
- Local tools installed by `setup-vm.sh`:
  - `lua5.1`, `luacheck` (lint), `busted` (unit tests)
  - `~/c4-tools/drivers-driverpackager/` — official Python packager for `.c4z` files (read its README for invocation)
  - `~/c4-tools/drivers-common-public/` — Snap One's helper Lua libraries (JSON, timers, URL requests, etc.), for reading only: **never vendor Snap One code into `src/`** (their license keeps derivative works theirs); the driver uses the C4 API and its own modules, nothing else
  - `~/c4-tools/reference/` — DriverWorks API and Fundamentals docs, for reading only

## Targets

- **Control4:** must work on OS 3.x and OS 4.x controllers, managed from Composer Pro 3.x-era builds and the newer date-versioned Composer Pro releases. My house currently runs OS 3.x. DriverWorks SDK APIs are designed to be OS-version-independent, so stick to documented APIs and set an explicit minimum OS in `driver.xml` (to be decided; justify the choice).
- **Lua:** the controller's Lua sandbox (Lua 5.1 — verify in the SDK docs). No Lua 5.2+ features, no C modules, no `require` of anything not packaged in the driver.
- **Hue:** CLIP API v2 only (`/clip/v2/...`), HTTPS only, authenticated with the `hue-application-key` header. Must work with both the Hue Bridge (v2, square) and the **Hue Bridge Pro**. Use the bridge's event stream (`/eventstream/clip/v2`, server-sent events) for state updates instead of polling where the Control4 networking APIs allow it.

## Scope (v1, refine during the first planning session)

- Bridge pairing from Composer: discover or enter the bridge IP, press-the-link-button flow to obtain an application key, store it in a driver property or persistent storage.
- Import the bridge's lights and represent each as a Control4 light using the **light_v2 proxy**: on/off, dimming, color temperature, and full color where the bulb supports it.
- Live two-way state: changes from the Hue app or Hue switches show up in Control4 promptly.
- Hue rooms/zones and scene recall available to Control4 programming.
- Graceful handling of bridge offline, IP change, and key revocation, with useful Composer properties showing status.

Later, not v1: Hue motion sensors and MotionAware (Bridge Pro only), entertainment areas, multiple bridges.

## Things to investigate before designing (report findings to me)

1. Which DriverWorks networking API should hold a long-lived HTTPS SSE connection, and how the controller handles the bridge's certificate (Signify-signed, bridge ID as CN).
2. Driver structure: one bridge driver that creates child light devices, versus one driver per light bound to a bridge driver. What's supported on both OS 3.x and 4.x?
3. Minimum OS version to declare, and anything that behaves differently on OS 4.x.
4. Hue rate limits and connection limits for commands and the event stream, and how to queue/coalesce commands (dimmer slider spam).
5. Mapping between Hue color (xy + gamut, mirek) and what the light_v2 proxy expects.

## Repository layout (proposed; adjust in the first plan)

```
src/            driver.lua, driver.xml, bridge/ and common/ (our own modules), www/ (docs, icons)
tests/          busted specs, with a fake C4 global and recorded Hue API fixtures
tools/          build.sh, deploy helper
build/          generated .c4z (gitignored)
docs/           design notes and the testing checklist I run in Composer
```

## Commands (fill in as they're created)

- Checks: `tools/setup-checks.sh` once (installs the lint tools into `~/.local/bin`, no sudo), then `tools/check.sh` before every commit: the same checks CI runs as its four required jobs (`--strict` in CI; `--only <name>...` for a subset). Lint alone: `luacheck src tests tools`; tests alone: `busted tests`.
- Build: `tools/build.sh` → `build/hue_bridge.c4z`, `build/hue_light.c4z`, `build/hue_scene.c4z` (`<version>` = git commit count). `tools/build.sh --dev` adds the dev loop and the Lua command window; never install a dev build as the production driver.
- Dev loop (only while a `--dev` build is installed): `tools/devserver.py` (background, once), `tools/devctl.py status|run|set|reload|wait|log|pin|unpin`; details in `docs/dev-loop.md`. While agents edit `src/`, keep the loop **pinned** and re-pin only states that pass lint and tests. Since #52 every bundle and command list is signed with the VM's dev key (`~/.config/c4-hue-driver/devkey`, created on first use): never print it, commit it or put it in a report, and never hand a `--dev` package to anyone, because it carries the key.
- **Current state: `docs/status.md`** (what runs on the house, what is built, what is open; update it when that changes). Design notes: `docs/design.md`; Composer checklist: `docs/composer-checklist.md`; feature contracts: `docs/*-design.md`; Composer automation: `docs/composer-remote.md`, `tools/composer/Composer.psm1`.
- Deploy (GitOps; the contract is `docs/cicd-gitops-design.md`): the house runs a GitHub release, never a VM build. Cut the release from the Actions page (Release ▸ Run workflow ▸ version; every 1.x release moves the `v1.0` tag) or push the tag; the workflow lints, tests, builds from `main` only and attaches the three `.c4z`, `SHA256SUMS.txt`, `manifest.json` and the provenance attestations. Then a PR sets `deploy/house.yaml` (the desired state) to that build; on merge the drift workflow opens one issue labelled `deploy`. `python3 tools/deploy.py start` downloads and verifies the assets, creates the GitHub Deployment on the environment `house` (the observed state) and writes `build/release/<tag>/BRIEF.md`; send that brief to the Windows session: it fetches the files from the GitHub release URLs into `C:\c4-hue\drivers\<tag>\`, checks the hashes, installs all three at once through Driver ▸ "Add or Update Driver or Agent…" (updates every existing device in place; never delete and re-add, the pairing would be lost) and reads back every device's `Driver Version` and the bridge's `Stream Timeout (s)`, `Stream Watchdog (s)` and `Debug Mode`. `python3 tools/deploy.py done --devices N` records success and closes the issue; `failed --note` records what went wrong. A `<capabilities>` change still needs the owner to reboot the controller from System Manager (`start --note` carries that into the brief). `deploy.py status` says whether desired and observed agree. An install that bypassed the tool (a `--dev` build for the dev loop or a feature-branch hardware test, served from `build/release/` with `python3 -I -m http.server 8090 --bind 0.0.0.0 --directory build/release` and briefed with the hashes as before) is recorded afterwards with `deploy.py record --no-manifest`, so the drift issue shows the house is off its desired state until a release is installed again; a release install ends the dev loop. Stop the HTTP server afterwards.

## Hue references

- CLIP v2 docs: https://developers.meethue.com/develop/hue-api-v2/ (full reference needs a free developer login; ask me to paste a page if you can't reach it)
- Getting a key: POST `/api` with `{"devicetype": "...", "generateclientkey": true}` after the link button is pressed.

## Licensing

The DriverWorks documentation and libraries are Snap One property and carry restrictive terms, and the repository is public: never copy passages of the Snap One docs or of Signify's login-walled docs into it, never vendor Snap One code, keep every LAN address, key, bridge id and project name out of it (placeholders only: 10.0.2.143 bridge, 192.0.2.7 VM, 001788fffe123abc bridge id), and keep the trademark and non-affiliation lines of NOTICE and the manuals. Releases are GitHub releases with the three .c4z files attached (docs/release-checklist.md).
