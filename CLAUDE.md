# Control4 ⇄ Philips Hue driver

Custom Control4 DriverWorks driver that controls Philips Hue lighting through the Hue bridge's local API. Personal project for one home; the repo is private and must stay private (see "Licensing" below).

## How I want you to work

- **Plan first, then wait.** For any new feature or fix, explore, then present the approach and the files you'll touch, and wait for my approval before writing code. Small mechanical edits I've already asked for are fine without a separate plan.
- **Edge cases before automation.** Before designing anything that acts on its own over the life of the system (importing, syncing names or rooms, creating or removing devices), send research agents to enumerate the lifecycle corner cases on both sides (Hue and Control4: things added, moved, renamed, replaced, removed, restored from backup) and decide per case what is automatic, what is only offered, and what is forbidden without a click. The findings go into the feature's contract under `docs/` before any code. Automation that makes a later manual fix harder is wrong.
- Commit in small, working steps with clear messages. Never push directly to `main`; use a branch and open a PR with `gh`.
- **One branch and one PR per feature.** Create the branch from `main` when the feature's contract is written, before any agent starts, so every commit lands somewhere reviewable under the right title; open the PR with `gh` as soon as the first integrated commit is on it. When a branch has done its job, merge it rather than letting the next feature pile onto it.
- When something about the Control4 or Hue APIs is uncertain, check the docs (paths below) and tell me what you verified versus what you're assuming. Do not invent DriverWorks API calls.
- Never commit secrets: Hue application keys, bridge IPs from my LAN, or certificates. Use placeholders in tests and examples.

## Working with agents

**Parallel by default.** For every piece of work, split it into parts that touch disjoint files and run them as background agents at the same time: module and its spec, VM-side tooling, changes to existing modules and their specs, docs and design notes. A single serial pass is only acceptable when the work truly cannot be split (one file, a handful of edits). Before starting any task, say in one line how it is being split and which agent owns which files; if it is not being split, say why.

- **Coordinator first.** Before spawning, write the contract the pieces share (an interface, a wire protocol, a file layout) into `docs/` so every agent builds against the same text. Then spawn them in one go, in the background.
- **One writer per file.** Each brief names the exact files the agent may create or edit and says that others are editing the rest of the checkout concurrently. No agent runs `git`; the coordinator integrates, runs `luacheck src tests`, `busted` and `tools/build.sh`, and commits.
- **Briefs are self-contained.** Agents start cold: include the doc paths to read, the conventions (Lua 5.1, tabs, `.luacheckrc`, busted style, the fake C4 runtime), the hardware facts that matter, and what "done" looks like, including the verification commands to run.
- **Research agents are read-only** and write one new file under `docs/` (for example a design for a new transport), citing the SDK doc file for every API claim.
- Typical split for a feature: VM-side tooling (Python) / driver-side Lua module plus its spec / changes to existing modules plus their specs / a design or research document. Integration into `driver.lua`, `driver.xml`, `tools/build.sh` and `CLAUDE.md` stays with the coordinator.
- Don't spawn for quick things (one file, a handful of edits); do it inline. Everything larger is split.
- While agents run, the coordinator does the integration pieces nobody else owns (`driver.lua`, `driver.xml`, `tools/build.sh`, `CLAUDE.md`) and verifies through the dev loop, rather than waiting idle.

## Environment

- This repo lives on an Ubuntu 26.04 VM on my home LAN. You run everything here: builds, lint, tests.
- I drive you from a Mac via the Claude Desktop app (SSH session). I can't run commands on the Mac for you.
- Loading the driver onto the real controller happens in **Composer Pro on a separate Windows VM**. You can't run Composer yourself, but a Claude Code session in the Claude app **on that Windows VM** can: both sessions have Remote Control on, it shows up as a peer in `ListAgents`, and you brief it with `SendMessage` (`docs/composer-remote.md`). It reads Composer through Windows UI Automation from PowerShell, clicks, and takes screenshots; reading and cancelling are always fine, anything hard to undo (deleting devices, Update Driver, Connections, project load/save) still needs my explicit OK, quoted in the brief. For `driver.xml` changes the deliverable is still a built `.c4z` plus the steps. **For Lua changes use the dev loop** (`docs/dev-loop.md`): a dev build of the bridge driver fetches its code from `tools/devserver.py` on this VM, reloads itself, runs actions queued with `tools/devctl.py` and ships its log back, so you can test on the live controller yourself. Always update the driver **in place** in Composer; deleting and re-adding it loses the pairing.
- The controller runs OS 3.4.2 and is on this VM's LAN; the house bridge is a Hue Bridge Pro (BSB003).
- Local tools installed by `setup-vm.sh`:
  - `lua5.1`, `luacheck` (lint), `busted` (unit tests)
  - `~/c4-tools/drivers-driverpackager/` — official Python packager for `.c4z` files (read its README for invocation)
  - `~/c4-tools/drivers-common-public/` — Control4's helper Lua libraries (JSON, timers, URL requests, etc.); vendor what we use into `src/` rather than referencing this path
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
src/            driver.lua, driver.xml, lib/ (vendored Lua libraries), www/ (docs, icons)
tests/          busted specs, with a fake C4 global and recorded Hue API fixtures
tools/          build.sh, deploy helper
build/          generated .c4z (gitignored)
docs/           design notes and the testing checklist I run in Composer
```

## Commands (fill in as they're created)

- Lint: `luacheck src tests`
- Test: `busted tests`
- Build: `tools/build.sh` → `build/hue_bridge.c4z`, `build/hue_light.c4z` (`<version>` = git commit count). `tools/build.sh --dev` adds the dev loop and the Lua command window; never install a dev build as the production driver.
- Dev loop: `tools/devserver.py` (background, once), `tools/devctl.py status|run|set|reload|wait|log`; details in `docs/dev-loop.md`
- Design notes: `docs/design.md`; Composer checklist: `docs/composer-checklist.md`
- Deploy: TBD — copy the `.c4z` to a folder the Windows VM can see; I'll import it in Composer Pro.

## Hue references

- CLIP v2 docs: https://developers.meethue.com/develop/hue-api-v2/ (full reference needs a free developer login; ask me to paste a page if you can't reach it)
- Getting a key: POST `/api` with `{"devicetype": "...", "generateclientkey": true}` after the link button is pressed.

## Licensing

The DriverWorks documentation and libraries are Snap One property and carry restrictive terms. Keep this repo private, don't copy large passages of the docs into the repo, and don't publish the driver without me deciding that explicitly.
