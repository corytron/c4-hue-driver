# Status of the Hue driver (2026-10-24, build 180)

The single page that says what is built, what runs on the house, and what is
open. Feature contracts and design notes keep their history; where they and
this page disagree about the present, this page and the code win.

## What runs on the house

- **Build 180**, production (no dev loop), on all three drivers (installed
  2026-10-24 12:09; time-of-day scenes, the first build with them): Hue Bridge,
  Hue Light, Hue Scene. Controller on OS 3.4.2, Composer Pro 3.4.2, Hue
  Bridge Pro (BSB003), paired.
- **Devices.** Two Hue Scene devices in the Master Bedroom: "Shine" (device
  1162, the ordinary scene Shine) and "Golden hours" (device 1164, the
  room's time-of-day scene, created 2026-10-24 12:06). No Hue Light devices: all 47
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
  on one line of about 75 characters and clips the rest, so `Room Mappings`
  is a drop-down list (summary on the row, one mapping per line in the
  list, a pick snaps back to the summary), `Scenes` reads "126 + 15
  time-based on bridge, 2 imported, 2 deleted" (missing and unbound only
  when not zero) and `Stream Address` reads "10.00.002.143 (own queue,
  spelling 1 of 7)" or "… (shared queue with commands: <reason>)".
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
listed in Composer (2026-10-24, build 180).

## Open

- Time-of-day scenes: whether a running schedule still advances to its
  next slot after a whole-room dim (a 16:00 check on 2026-10-24 reads the
  Golden hours device's Status after its 16:00 slot); whether `Recall As`
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
  `hue_bridge/driver.xml` but the code treats anything below 60 as 60; the
  group queue (scene OFF, dims) is paced at up to 10 requests a second
  although Hue's guidance for groups is about one a second (a comment in
  `driver.lua` now says so). Release builds also keep two diagnostic paths:
  Test Connection's Host override and Connection Test's "Diagnostic Server"
  target (insecure TLS), and the scene driver's `HUE_DUMP` handler is not
  gated on the dev loop.
- The manual's `img/room-mappings.png` still shows the old one-line row; to be
  re-shot by the Windows session once the list is on the house.
- The Composer project is unsaved.
- Approvals: the owner approves everything, always (2026-10-24); the
  Windows session asked him once on its side to confirm that standing rule.
