# Slimming review, 2026-10-24: the brief every reviewer works from

The owner asked, before the first public release, for fewer lines of code and
less memory and CPU on the controller, with no new bugs, regressions or
security flaws. This page is the contract the review agents share; each
writes one findings file under `docs/reviews/` and changes nothing else.

## What counts

- **Driver code** that runs on the controller: `src/hue_bridge/driver.lua`
  and `src/hue_bridge/bridge/*.lua`, `src/hue_light/driver.lua` and
  `src/hue_light/light/*.lua`, `src/hue_scene/driver.lua`, `src/common/*.lua`
  (`devloop.lua` ships only in dev builds). About 17,500 lines today.
- **Runtime cost**: the controller is an OS 3.4.2 Control4 controller running
  Lua 5.1 (no LuaJIT assumptions, no C modules). The hot paths are the event
  stream (`bridge/stream.lua` → `sse.lua` → `driver.lua` `on_container` →
  `lights:on_container` → `scenes:on_container` → `zone_lights:on_container`),
  the command queues (`bridge/commands.lua`), the resync GETs (the scene
  catalogue is 351 KB on the house bridge), timers, and the proxy
  notifications in the two device drivers.
- Tests (`tests/`) and tools (`tools/`) are out of scope for slimming; they
  are the safety net.

## Rules a proposal must respect

1. **No behaviour change visible to the owner.** Every Composer property
   text, action name, picker text, Last Action text, Status text, proxy
   notification and bridge↔device message is documented in the manuals
   (`src/*/www/documentation.html`) and pinned by specs; they stay
   byte-for-byte. The contracts under `docs/*-design.md` describe the
   behaviour; `docs/status.md` describes the present.
2. **No new attack surface.** Keep every hardening from
   `docs/code-analysis-2026-10-22.md` (bounds on timers and timeouts, no key
   in logs, no arbitrary requests in release builds, TLS pinning as is).
3. **Lua 5.1 only**, tabs, `.luacheckrc` clean, `busted tests` green
   (1060 specs). A proposal that needs a spec change must say which spec and
   why the spec, not the code, was wrong.
4. **Risk is the first column.** A hundred lines saved by merging two
   modules' lifecycle code is worth less than ten lines of dead code removed,
   unless the merge is pinned by the existing specs end to end.
5. **One writer per file later.** Say which files a proposal touches, so the
   coordinator can hand it to one implementation agent without overlap.

## What to look for

- Dead code: handlers no caller reaches, guards for module states that no
  longer exist ("until lights.lua's integration lands"), compatibility
  shims for earlier builds, duplicate helpers.
- Duplication between `lights.lua`, `scenes.lua` and `zone_lights.lua`
  (registry lifecycle, pickers, attention items, name handling) and between
  `hue_light/driver.lua` and `hue_scene/driver.lua` (keypad Button Links,
  LEDs, binding re-check, dimmer fallbacks, hello/configure plumbing).
- Per-event allocation: tables and strings built for every container,
  `string.format` in debug lines that run even when debug is off, JSON
  re-encoding, closures created per call, `pairs` over whole registries for
  one rid.
- Work that scales with the bridge: loops over all lights or all scenes per
  event, re-sending CONFIGURE/STATE when nothing changed, re-reading the
  whole catalogue when one item changed.
- Timers: repeating timers that could be one-shot, timers left running,
  the same check scheduled from several places.
- Memory held for the life of the driver: caches that duplicate each other
  (`lights.models`, group caches, scene catalogue copies), logs or histories
  that grow.
- Over-general helpers used once; string concatenation in loops; `tostring`
  on values that are already strings.

## Output: `docs/reviews/slim-<area>.md`

1. A one-paragraph summary: lines today, lines the proposals would save,
   and the two or three biggest runtime wins.
2. A table, ranked by (benefit ÷ risk): `#`, file and lines, what to change,
   lines saved (estimate), runtime effect (memory, CPU, per-event or
   per-startup), risk (low / medium / high and why), the specs that already
   pin the behaviour or the spec to add, security note (none / improves /
   needs care).
3. A "do not touch" list: code that looks redundant but is not, with the
   reason (hardware quirk, Director behaviour, a contract decision).
4. Open questions for the coordinator.

Cite file paths with line numbers for every claim. Do not edit any file but
your own findings file; do not run git, the build, or anything against the
controller or the bridge.
