# Control4 ⇄ Philips Hue driver

Custom Control4 DriverWorks driver that controls Philips Hue lighting through the Hue bridge's local API. Personal project for one home; the repo is private and must stay private (see "Licensing" below).

## How I want you to work

- **Plan first, then wait.** For any new feature or fix, explore, then present the approach and the files you'll touch, and wait for my approval before writing code. Small mechanical edits I've already asked for are fine without a separate plan.
- Commit in small, working steps with clear messages. Never push directly to `main` once the first scaffold is merged; use a branch and open a PR with `gh`.
- When something about the Control4 or Hue APIs is uncertain, check the docs (paths below) and tell me what you verified versus what you're assuming. Do not invent DriverWorks API calls.
- Never commit secrets: Hue application keys, bridge IPs from my LAN, or certificates. Use placeholders in tests and examples.

## Environment

- This repo lives on an Ubuntu 26.04 VM on my home LAN. You run everything here: builds, lint, tests.
- I drive you from a Mac via the Claude Desktop app (SSH session). I can't run commands on the Mac for you.
- Loading the driver onto the real controller happens in **Composer Pro on a separate Windows VM**. You can't run Composer. Your job ends at a built `.c4z` plus clear instructions for what I should click and observe.
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
- Build: `tools/build.sh` → `build/hue_bridge.c4z`, `build/hue_light.c4z` (`--dev` enables the Lua command window; `<version>` = git commit count)
- Design notes: `docs/design.md`; Composer checklist: `docs/composer-checklist.md`
- Deploy: TBD — copy the `.c4z` to a folder the Windows VM can see; I'll import it in Composer Pro.

## Hue references

- CLIP v2 docs: https://developers.meethue.com/develop/hue-api-v2/ (full reference needs a free developer login; ask me to paste a page if you can't reach it)
- Getting a key: POST `/api` with `{"devicetype": "...", "generateclientkey": true}` after the link button is pressed.

## Licensing

The DriverWorks documentation and libraries are Snap One property and carry restrictive terms. Keep this repo private, don't copy large passages of the docs into the repo, and don't publish the driver without me deciding that explicitly.
