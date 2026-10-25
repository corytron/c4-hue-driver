# Status of the Hue driver (2026-10-24)

**Release 1.0 "Cassian" (build 237), tag `v1.0`**, published on GitHub with the three
`.c4z` files built by the release workflow; re-cut from build 228 (PR #33)
with the bridge-compatibility check (PR #35) and the public-repository files
(PR #34). The house runs it since 2026-10-24 19:26. **The repository is
public since 2026-10-24** (history rewritten: placeholder addresses, two
screenshots dropped): main is protected (pull requests only, CI `test` and
`build` required, no force pushes), secret scanning and private
vulnerability reporting are on, Issues, Discussions and the public project
board "Hue driver" track the work, and every open item below is an issue. The milestone `1.0 "Cassian"` holds
the project's history: the 37 merged pull requests and 98 closed issues
(#71–#187) describing every problem found and fixed, each naming its fix;
the project board holds them all. Releases are codenamed after Star Wars:
Andor.

The single page that says what is built, what runs on the house, and what is
open. Feature contracts and design notes keep their history; where they and
this page disagree about the present, this page and the code win.

## What runs on the house

- **Build 247** (no dev loop), on all three drivers (installed 2026-10-24
  21:04; release 1.0 "Cassian" is build 237 plus PRs #69, #70 and #130:
  `Last Action` word-wrapped at 72 characters onto read-only rows `Last
  Action (2)` to `(6)` that are shown only while used, their visibility sent
  400 ms after the texts and again at 1.5 s because Composer drops attribute
  changes that arrive with the text updates; the four item lists editable,
  since a read-only list is a disabled control in Composer; `Debug Mode`
  Off, a dev build had left it On): Hue Bridge, Hue Light, Hue Scene. Read back from Composer: Bridge
  Model "Hue Bridge Pro (BSB003)", Bridge Name "Hue Bridge Pro", Bridge
  Firmware "2071524040 (API 1.78.0)"; `Stream Timeout (s)` 3600, `Stream
  Watchdog (s)` 600. Controller on OS 3.4.2, Composer Pro 3.4.2, Hue
  Bridge Pro (BSB003), paired.
- **Devices.** Two Hue Scene devices in the Master Bedroom: "Shine" (device
  1162, the ordinary scene Shine) and "Golden hours" (device 1164, the
  room's time-of-day scene, created 2026-10-24 12:06); two zone lights
  in the Master Bedroom, created with Add Zone Light on 2026-10-24: "Bedside
  Lights" (device 1166, the Hue zone of the two bedside lamps) and "Master
  Bedroom Lights" (device 1168, the whole Hue room). No Hue Light devices: all 47
  lights were deleted in Composer on 2026-10-22 and are remembered as
  deleted (Add Light brings any of them back). 126 scenes on the bridge, 1
  imported.
- **Keypads.** The "Bedside Lights Switch" (a Control4 switch run as a
  2-button keypad, Buttons Control Load off) has its top and bottom buttons
  bound to Shine's Top and Bottom Button Links. The "Floor Lamp Switch" is
  not bound to anything.
- **Composer project** has been left unsaved through the test rounds; the
  owner saves and backs it up.

## What the drivers do (current behaviour)

- **Bridge**: pairing (link button), CLIP v2 over HTTPS with the
  application key, the event stream on its own connection (padded address
  spellings) with resync on every connect, room mappings, import of lights
  (Add Light, Import All New Lights), lifecycle (renames: Attention, Adopt
  Hue Names, Accept Names As They Are; Forget Light; Link Devices;
  Re-link Device To Light; deletions remembered as tombstones), scenes (Add
  Scene, Add All Scenes Of Room, Re-link Scene, Forget Scene, Refresh
  Scenes), diagnostics. Follows each Hue room/zone's on/off and brightness
  from the event feed and tells scene devices.
  **Composer properties fit the column** (2026-10-24): Composer shows a value
  on one line of about 75 characters and clips the rest, so `Room Mappings`,
  `Lights`, `Scenes`, `Zone Lights` and `Last Action` are drop-down lists
  (the summary or text on the row, every item or a long text's "; "-parts
  in the list, a pick snaps back; commas read as "‚" there, since the list
  is comma-delimited), `Scenes` reads "126 + 15
  time-based on bridge, 2 imported, 2 deleted" (missing and unbound only
  when not zero) and `Stream Address` reads "10.00.002.143 (own queue,
  spelling 1 of 7)" or "… (shared queue with commands: <reason>)". Verified in
  Composer (build 185): a property-type change installs without a reboot;
  the list needs `UpdateProperty` beside `UpdatePropertyList` to move the
  row; the list is comma-delimited, so no summary or item may hold a comma.
- **Hue Light** (light_v2 proxy, dimmer, colour and colour temperature when
  the bulb supports them): two-way state; keypad Button Links (Top, Bottom,
  Toggle): tap top = On preset (100 %) over the click rate, tap bottom = off,
  hold = Hue's own relative dim (dimming_delta with a ramp, stop on release),
  hold top while off = on at 1 % then brighten, hold bottom while off =
  nothing; keypad LEDs follow on/off; button colours default to blue (top lit
  when on, bottom lit when off).
- **Time-of-day scenes** (Hue "Golden hours" / "Natural light", CLIP
  `smart_scene`; build 180): the same Hue Scene device with a kind. Listed
  in Add Scene as "<Room>: <name> (time-based)" first in each room or zone,
  the Hue app's number dropped from the name, zone ones named "<Zone>
  <name>"; ordinary scenes a schedule uses are marked "(in <schedule>)";
  Add All Scenes Of Room includes them. ON starts the schedule at its
  current slot, OFF stops it and turns the room off, slider and holds dim
  the room while it runs (a whole-room dim keeps it running, verified);
  from off a level or a held top button starts it and then moves or
  brightens; on exactly while Hue's state is active (ends on room off,
  another scene of the room, another schedule on its lights, or its own
  OFF); Recall As hidden; Status "Hue time-based scene Golden hours in
  Master Bedroom; now Arise (from 07:00)" / "…; not running". Contract
  `docs/smart-scenes-design.md`, checks `docs/smart-scenes-research.md` §7.
- **Hue Scene** (light_v2 proxy, **dimmer** since build 160): ON plays the
  scene (Recall As: As set in Hue / Static / Dynamic), OFF turns its room or
  zone off (a zone with no lights, which has no group light, only reports
  off). The level is the room/zone brightness Hue reports; the slider moves
  the room relative to it (keeping the scene's colours and per-light
  differences; while the room's level is not yet known it sets one absolute
  level for all its lights instead), 0 % = off, a level from off plays the
  scene at that level, 100 % from off plays it as designed. **On rule**: on from any activation
  (Control4, keypad, Hue app) until the room/zone turns off, another scene
  of it is played, or the device itself is turned off; persisted across
  restarts. ON is one request (dropped back if it fails); OFF and slider
  moves go through the group queue and are retried like light commands.
  Keypad: tap top plays, tap bottom turns off (taps are immediate: the scene
  declares no click rates), hold dims the room (relative), hold top while off
  plays at 1 % and brightens; LEDs follow the on state.
- **Both device drivers** declare `hide_proxy_properties`, so the proxy's
  own settings (click and hold rates, button LED colours) are not shown in
  Composer: the defaults apply (lights: On preset 100 %, click 250 ms; both:
  hold 5 s for the full range, blue LEDs). Exposing them is a small open
  change: either a `driver.xml` capability change (needs the reboot) or,
  per the light_v2 reference, switching `hide_proxy_properties` at run time
  with `DYNAMIC_CAPABILITIES_CHANGED` (documented, not tried on the house).
- **Zone lights** (build 196, contract `docs/zone-light-design.md`): a Hue
  zone or room added as a Hue Light device of kind "group" with the bridge's
  `Add Zone Light` (Group, Room) action; `Re-link Zone Light`, `Forget Light`
  (zone-light devices after the lights), the `Zone Lights` property ("7
  zones, 16 rooms on bridge; 1 imported"). The device: Status "Hue zone
  Bedside Lights (2 lights)", Model "Hue zone (2 lights)", Hue Light ID
  "zone #9 (b90ea7b4…)"; on while any lamp is lit, level = the group's
  average; ON = every lamp to 100 %, slider absolute on the group, keypad
  holds relative (`dimming_delta`), colour and colour temperature to the
  group, capabilities the union of the members'; the tile's colour is the
  first lit lamp's. The grouped_light queue is paced at one request a
  second with a burst of three (closes the pacing item below). A group with
  no lights is offline; a zone deleted in Hue leaves the device gone until
  Re-link Zone Light or Forget Light.
- **Bridge compatibility** (2026-10-24, after 1.0; `docs/bridge-compat-design.md`):
  pairing refuses the round first-generation bridge (BSB001), a device that
  is not a Hue bridge, and bridge software older than 1948086000 (the first
  with the CLIP v2 API), each with its own Status text; the identity check
  at every start refuses a first-generation bridge too. `Bridge Model` shows
  the friendly name with the id ("Hue Bridge Pro (BSB003)"); new rows
  `Bridge Name` (the bridge's own name) and `Bridge Firmware` (version and
  API version, with an update note when old).
- **Binding re-check**: a light or scene that is unbound at start looks again
  at 5, 15, 30 and 60 s (after a Director restart the binding can be late).
- **Documentation tab** in every driver (the owner's manual on the bridge),
  **icons** (Bridge Pro; the dimmer-switch remote for lights; the same lit in
  colours for scenes); a light or scene device shows the new 16 px icon in
  the tree if it was created under a build that declared a custom icon; the
  32 px List View tile stays the standard light icon.

## How builds reach the house (verified)

`tools/build.sh` from the branch to install, copy to `build/release/`, serve
it on port 8090, the Windows Claude session downloads it with checksums and
runs Driver ▸ "Add or Update Driver or Agent…" for all three files. **A build
that changes a driver's capabilities** (driver.xml `<capabilities>`) makes
Composer ask "Restart Director?"; answering Yes does **not** restart
Director, and the devices keep the old code until the owner **reboots the
controller from System Manager** (it runs elevated; the Windows session
cannot operate it). Builds that only change Lua or connections take effect
at once.

## Verified on hardware

Pairing, the event stream and resync, import and the whole light lifecycle
(2026-10-21/22), scenes (add, recall, OFF, deleted in Hue, Forget, Re-link),
the Documentation tab and icons, keypad Button Links on a light, keypad
hold-to-dim and LEDs on a scene (Hue accepts `dimming_delta` with `dynamics`
and the `stop` action on a grouped_light), the scene dimmer in the iPhone app
and its LEDs (2026-10-24), the light staying bound through a controller
reboot, time-of-day scenes activated and deactivated from the bridge and
listed in Composer (2026-10-24, build 180), the readable Room Mappings
list (build 185), Add Zone Light creating the Bedside Lights zone light and the Master
Bedroom room light with the right texts, pickers and counts, Forget Light
and a Composer delete of a zone light (builds 196–199); the Bedside Lights
zone light from the owner's phone and keypad (2026-10-24, build 199): ON,
the slider, colour and OFF reach both lamps and the tile follows the Hue
app, which also confirms that a grouped_light PUT takes `color` and
`color_temperature`.

## Release preparation (2026-10-24, branch `release-prep`, not yet installed)

- **Slimmed** by four agents from five reviews (`docs/reviews/slim-*.md`):
  release Lua code 16,665 → 15,917 lines and 1,438 more lines dev-only
  (`bridge/devtools.lua`, `conntest.lua`, `pinning.lua`, `common/devloop.lua`);
  the two device drivers share `common/device.lua`; the bridge modules share
  `bridge/util.lua` and `bridge/project.lua`. Per event: no watchdog timer
  churn, the three per-container property writes coalesced to one a second,
  no debug strings with debug off, the zone module touches only the groups
  an item can change, one grouped_light GET per resync, the owner-facing rows
  refreshed twice per reconnect (after the lights' resync and after the
  chain) instead of three times
  (`docs/reviews/efficiency-2026-10-24.md`: nine of fifteen costs gone).
- **Release builds** carry no dev loop, diagnostics or insecure TLS mode
  (`tools/build.sh` strips them and refuses to package a release that still
  has them); `Stream Timeout (s)` default 3600 and `Stream Watchdog (s)` 600
  (idle resyncs from every 10 minutes to every hour; set the house's Timeout
  row to 3600 at the install, Director keeps the old value otherwise).
- **Security** (`docs/reviews/security-2026-10-24.md`): the bridge's identity
  is now verified without the key (GET `/api/0/config`) before any request
  carries it, after start and after an address change; a different bridge
  at the address gets nothing and Status says so; an unreachable one is
  asked again every 30 s. Also capped: one SSE event's data (1 MB), the
  device drivers' pre-late-init buffer (200); persisted dates are range
  checked; `bridge_request` ignores a caller's TLS table. Open from that
  review (dev builds only): the dev loop is an unauthenticated LAN surface
  by design; never install a dev build where the LAN is not trusted.
- **Behaviour fixes found by the manual review**: a corrected `Bridge IP
  Address` restarts the feed by itself (it used to stay Stopped).
- **Docs**: README, LICENSE (Apache 2.0), NOTICE, CONTRIBUTING, `docs/README.md`;
  both manuals reviewed against the code (`docs/reviews/manual-*.md`) and
  corrected; the release checklist (`docs/release-checklist.md`) names 1.0.
- **Done for 1.0**: the dev-build regression pass (build 224,
  `tools/regress.sh` all pass, the reconnect chain clean in the shipped
  log), the release installs (226, 228, 237) and the Composer checks of the
  release checklist §2, the tag `v1.0` and the GitHub release, the history
  rewrite and the flip to public. Still open as issues: the owner's phone
  and keypad pass (#38), the screenshot retake (#61), the GitHub Support
  purge of the pre-rewrite commits (#62).

## Open


- Zone lights: Shine's tile going off on a zone OFF, and a change of the
  zone's lights in Hue reaching a live tile's colour controls, not yet seen
  by the owner. (Settled on the way, build 199: a device created by AddDevice has an
  empty property table at its first init, so a property written only by
  the replay of the property handlers, `Driver Version`, stayed blank until
  a reload; the three drivers now write it at late init and look again at 5
  and 15 s. The controller words a missing module "An unknown error
  occurred", which release builds no longer report as a dev-loop error.) The manual's chapter
  7 has no screenshot of Add Zone Light yet (shots are in `build/shots/img/`).


- Time-of-day scenes: a running schedule advanced to its 16:00 slot and
  the device showed "now Shine (from 16:00)" within two minutes (2026-10-24;
  `docs/smart-scenes-research.md` §7), though whether the room had been
  dimmed before that is not known; whether `Recall As`
  reappears on an ordinary device after a re-link from a time-based one
  (`SetPropertyAttribs(…, 0)`, assumed); the keypad on a time-of-day scene
  not yet tried by the owner.
- Second-priority hardening items in `docs/code-analysis-2026-10-22.md`.
- Proxy settings hidden on light and scene devices (above).
- List View 32 px icons for lights and scenes.
- Not verified: whether a revoked key answers HTTP 401 or 403; the
  binding re-check path itself (the reboot test ended bound, but which path
  got there is not visible from Composer); a slider level from off sets all
  of the scene's lights to that level (follows Hue's brightness override).
- Code: `Stream Watchdog (s)` is declared with a minimum of 0 in
  `hue_bridge/driver.xml` but the code treats anything below 60 as 60.
  (Resolved 2026-10-24: release builds no longer carry the Dev Server and
  Diagnostic Server properties, the Connection Test, Reload Credentials and
  Check CA Pinning actions, the conntest and pinning modules, the Test
  Connection host override or the scene driver's `HUE_DUMP`; development
  builds keep them.)
- The Composer project is unsaved.
- Approvals: the owner approves everything, always (2026-10-24); the
  Windows session asked him once on its side to confirm that standing rule.
