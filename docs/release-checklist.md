# Release checklist: what a build must pass before it is called good

Written 2026-10-24 for the first release build, after the slimming pass. The
owner's rule: after any code change that is more than a text, test for
functional regressions on the dev loop **and** on the real system before the
code is called good. Three passes, in this order; every line is a check with
its expected result, and the result goes into `docs/status.md`.

## 0. On this VM

- `luacheck src tests tools` clean; `busted tests` green (the count is in
  `docs/status.md`).
- `tools/build.sh` (release) and `tools/build.sh --dev`: the release
  `hue_bridge.c4z` has 22 actions and no `Dev Server`, `Diagnostic Server`,
  `Connection Test`, `Reload Credentials`, `Check CA Pinning`; no
  `common/devloop.lua`, `bridge/conntest.lua`, `bridge/pinning.lua`. The dev
  build has all of them. Every `driver.xml` parses.
- `unzip -l build/<driver>.c4z` lists `LICENSE` and `NOTICE` in each of the
  three packages (Apache 2.0 §4).
- No LAN address, Hue application key or private certificate in `src/`,
  `docs/`, `tools/`, `tests/` (`git grep` for the house's addresses; the
  placeholders 10.0.2.143 and 192.0.2.7 are the only ones allowed).

## 1. Dev loop on the house (dev build of the bridge)

Install the three `--dev` files through the Windows session (Deploy in
`CLAUDE.md`); set `Dev Server` to this VM's `host:8080`; `tools/devserver.py`
running, `tools/devctl.py status` shows the bridge polling. Then, through
`tools/devctl.py run`, with the shipped log (`build/dev/driver.log`) as the
evidence (`docs/dev-loop.md`):

1. Startup: the log shows the resync (lights, scenes, smart scenes,
   grouped_light GETs), the stream connecting on its padded spelling, and
   `Lights`, `Scenes`, `Zone Lights`, `Room Mappings` summaries matching the
   house (47 lights; 126 + 15 scenes; 7 zones, 16 rooms; 23 mappings).
2. `Test Connection` → `Status` "Test OK: HTTP 200 via … bridge …".
3. `Refresh Scenes` → `Last Action` "Scenes refreshed: 126 + 15 time-based on
   bridge, 2 imported, 2 deleted" (counts as on the house).
4. `Room Audit`, `Link Devices`, `Adopt Hue Names`, `Accept Names As They
   Are` → their texts, nothing changed (no new devices, no renames unless a
   name differs).
5. Zone light round trip on the Bedside Lights zone light (device 1166):
   `Proxy_Command` / the owner's tile: ON → one PUT `{"on":{"on":true},
   "dimming":{"brightness":100}}` on grouped_light 75952a96…; a level → one
   absolute PUT; OFF → `{"on":{"on":false}}`; the Hue app's change → one
   `HUE_STATE` to device 1166 within 2 s; at most one grouped_light PUT a
   second during a drag.
6. Scene round trip on Shine (1162): ON → one scene recall PUT; OFF → one
   grouped_light off; the keypad hold (owner) → `dimming_delta` up/down and
   `stop`.
7. Time-of-day scene: Golden hours (1164) ON → `smart_scene` activate; OFF →
   deactivate and the room off.
8. Light lifecycle: `Add Light` of one light (Left Bedside Light) into the
   Master Bedroom → a device with Status "Hue light …" and Driver Version
   at once; `Forget Light` + delete in Composer → tombstone, `Add Light`
   lists it "(deleted from Composer …)".
9. Events: a Hue-app change of a lamp → one `HUE_STATE` only to the devices
   that show it; `Events Received` rises; no error line in the log.
10. Thirty minutes idle: no reconnect storms, no timer errors, memory steady
    (the dev loop's `status` shows the driver's Lua memory if available).

## 2. Release build on the house (Windows session, Composer)

Install the three release files; no "Restart Director?" unless a
capability changed (then the owner reboots the controller). Read:

1. `Driver Version` on the bridge, Shine, Golden hours, Bedside Lights and
   Master Bedroom Lights = the build.
2. The bridge's Properties page: no `Dev Server` / `Diagnostic Server` rows;
   `Lights`, `Scenes`, `Zone Lights`, `Room Mappings`, `Last Action` are
   drop-downs whose lists hold every item (47 lights; 141 scenes; 23 groups;
   23 mappings); a pick snaps back and leaves the Last Action note.
3. The Actions tab: 22 actions, none of the three diagnostics.
4. `Add Zone Light` for a throwaway zone, Driver Version at once, `Forget
   Light`, delete: as in round 25 (`docs/composer-remote.md`).
5. The Documentation tab opens and shows the manual's title and the
   chapter list (and the three device pages).
6. The Lua tab of a device during the install: no `[ERROR]` line.

## 3. The owner, on the phone and keypads

1. Bedside Lights tile: ON, slider, colour, colour temperature, OFF reach
   both lamps; the Hue app's change reaches the tile.
2. Shine's tile: ON plays, slider dims the room, OFF turns the room off;
   LEDs on the Bedside Lights Switch follow.
3. Golden hours tile: ON starts the schedule (Status "now <slot>"), OFF
   stops it and turns the room off.
4. Keypad taps and holds on whichever device the switch is bound to.

A build passes when every line reads as expected; anything else goes to
`docs/status.md` "Open" with the build number, and the release waits.

## Naming

The release of this spike is **1.0** (owner, 2026-10-24): git tag `v1.0`, a
GitHub release titled "1.0" with the three release `.c4z` files attached,
and "1.0 (build N)" in the README and status page, where N is the build
number the drivers show as `Driver Version` (Control4 needs an integer
there, so the driver files keep the commit count). Later releases of the
same spike move the tag and the attached files; a new version number comes
when development here is finished. **How a release is cut:** stamp the
build number into the README and the status page in a PR, merge it, tag
the merge commit (`git tag -f -a vX.Y`), push the tag; the release
workflow (`.github/workflows/release.yml`) lints, tests, builds and
attaches the three packages and `SHA256SUMS.txt` to the release of that
tag (creating it if needed); then edit the release notes. The local
`tools/build.sh` of the same commit is only for the Windows session's
install.
