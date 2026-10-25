# Status of the Hue driver (2026-10-25)

**Release 1.0 "Cassian", build 316, tag `v1.0`** (re-cut 2026-10-25 by the
two-job Release workflow from `main` at e3ec53d): the review leftovers
(#214), the shared lifecycle base and keypad machine (#216), the security
fixes of 2026-10-25 (#221), code scanning triage (#223), the scene probe
(#218) and the screenshot tooling (#227). Its install on the house follows
the #40 hardware checks of 2026-10-25 10:00 (issue #228 tracks it). **The
repository is public since 2026-10-24** (history rewritten that day:
placeholder addresses, two screenshots dropped; rewritten again on
2026-10-25 for three more spellings of the house address, #62): main is
protected (pull requests only, the four CI checks of
`.github/workflows/ci.yml` required, branch current before merge, admins
included, no force pushes), secret scanning, push protection, CodeQL,
Dependabot security updates and private vulnerability reporting are on,
Issues, Discussions and the public project board "Hue driver" track the
work, and the open items below are issues (one hardware check still waits
for its own). The milestone `1.0 "Cassian"` holds the project's history: 37
pull requests (36 merged, #7 closed unmerged) and 98 closed issues
(#71–#187) describing every problem found and fixed, each naming its fix;
the project board holds them all. Major
versions are codenamed after Star Wars: Andor; every 1.x release keeps
"Cassian". **Since 2026-10-25 the project is run as CI/CD and GitOps**
(`docs/cicd-gitops-design.md`, PR #205): one script, `tools/check.sh`, runs
every check on the VM and in CI; releases are cut by the Release workflow
and carry `manifest.json` and provenance attestations; `deploy/house.yaml`
is the desired state of the house and the GitHub environment
[`house`](https://github.com/corytron/c4-hue-driver/deployments/house)
records every install (`tools/deploy.py`); a drift workflow keeps one issue
labelled `deploy` open while they differ (a run that finds drift is a green
run since PR #210). The Composer click stays with the Windows session: the
controller has no install API. OpenSSF Scorecard's first score was 6.2; on
2026-10-25 it reads 7 (below 10: Maintained, Code-Review, Fuzzing and
CII-Best-Practices at 0, the last one #224; Branch-Protection and
Contributors at 3).

The single page that says what is built, what runs on the house, and what is
open. Feature contracts and design notes keep their history; where they and
this page disagree about the present, this page and the code win.

## What runs on the house

- **Dev build 309 since 2026-10-25 03:24** (Composer round 43): `main` at
  d13e287 built with `tools/build.sh --dev`, installed in place on all five
  devices (no reboot: no capability change) so the signed dev loop (#52,
  with the fixes of #217) serves the hardware checks of #40. It carries the
  dev key; the release install replaces it. Recorded on the environment
  `house` as deployment 7310056842; `python3 tools/deploy.py status` reports
  drift (desired 316 since PR #229, observed 309) until then, and issue #228
  stays open. Its three `driver.xml` files are build 316's, so the release
  install needs no reboot.
- **The proxy's settings on the devices since 2026-10-25** (#59): the owner
  rebooted the controller from System Manager during the night's hardware
  pass (dev build 284), which loaded the capability change of #59
  (`hide_proxy_properties` False on both device drivers); builds 309 and 316
  keep it.
- **Build 259 = release 1.0 "Cassian"** (re-cut 2026-10-24 23:04 local from
  the merge of PR #205 with `manifest.json` and provenance attestations),
  installed 2026-10-24 23:11 local through the GitOps flow: PR #207 set
  `deploy/house.yaml`, the drift workflow opened issue #208,
  `tools/deploy.py start` verified the release assets and created deployment
  7307903445 on the environment `house`, the Windows Composer session
  installed from the GitHub release URLs (round 34: all five devices on
  Driver Version 259, no Restart Director, bridge Paired, stream connected),
  and `tools/deploy.py done` recorded success and closed the issue. Driver
  code and XML are identical to build 247. `deploy.py status` read "in sync"
  until the dev install of 2026-10-25 03:24. The Environments page is the
  authority on what the house runs; the build details below are the
  history. Build 247 is recorded there as deployment 7307525952 (installed
  2026-10-24 21:04, before the tool existed).
- **Build 247** (superseded by 259 above; no dev loop), on all three drivers
  (installed 2026-10-24 21:04; release 1.0 "Cassian" is build 237 plus PRs
  #69, #70 and #130: `Last Action` word-wrapped at 72 characters onto
  read-only rows `Last Action (2)` to `(6)` that are shown only while used,
  their visibility sent 400 ms after the texts and again 1.5 s later because
  Composer drops attribute changes that arrive with the text updates; the
  four item lists editable, since a read-only list is a disabled control in
  Composer; `Debug Mode` Off, a dev build had left it On): Hue Bridge, Hue
  Light, Hue Scene. Read back from Composer: Bridge Model "Hue Bridge Pro
  (BSB003)", Bridge Name "Hue Bridge Pro", Bridge Firmware "2071524040 (API
  1.78.0)"; `Stream Timeout (s)` 3600, `Stream Watchdog (s)` 600. Controller
  on OS 3.4.2, Composer Pro 3.4.2, Hue Bridge Pro (BSB003), paired.
- **Devices.** Two Hue Scene devices in the Master Bedroom: "Shine" (device
  1162, the ordinary scene Shine) and "Golden hours" (device 1164, the
  room's time-of-day scene, created 2026-10-24 12:06); two zone lights
  in the Master Bedroom, created with Add Zone Light on 2026-10-24: "Bedside
  Lights" (device 1166, the Hue zone of the two bedside lamps) and "Master
  Bedroom Lights" (device 1168, the whole Hue room). No single-light Hue
  Light devices: all 47 lights were deleted in Composer on 2026-10-22 and are
  remembered as deleted (Add Light brings any of them back). 126 + 15
  time-based scenes on the bridge, 2 imported (the two Hue Scene devices
  above).
- **Keypads.** The "Bedside Lights Switch" (a Control4 switch run as a
  2-button keypad, Buttons Control Load off) has its top and bottom buttons
  bound to Shine's Top and Bottom Button Links. The "Floor Lamp Switch" is
  not bound to anything.
- **Composer project** has been left unsaved through the test rounds; the
  owner saves and backs it up (#38).

## What the drivers do (current behaviour, build 316)

- **Bridge**: pairing (link button; `Pair Bridge`, `Forget Pairing`), CLIP
  v2 over HTTPS with the application key, the event stream on its own
  Director queue (a padded spelling of the bridge address, a different one
  at every connect where there are several) with a resync after every
  connect, room mappings (`Set Room Mapping`, `Map Rooms By Name`, `Room
  Audit`), import of lights (Add Light, Import All New Lights), lifecycle
  (renames: Attention, Adopt Hue Names, Accept Names As They Are; Forget
  Light; Link Devices; Re-link Device To Light; deletions remembered as
  tombstones), scenes (Add Scene, Add All Scenes Of Room, Re-link Scene,
  Forget Scene, Refresh Scenes), zone lights (below), and `Test
  Connection`, `Connect Event Stream` and
  `Disconnect Event Stream` (`Connection Test`, `Reload Credentials` and
  `Check CA Pinning` are in dev builds only). Follows each Hue room/zone's
  on/off and brightness from the event feed and tells scene devices. The
  lights, scenes and zone lights share one lifecycle base,
  `bridge/owner.lua` (#216).
- **Keyed requests** (#214, #221; `docs/design.md`, "Networking", "TLS
  self-check in release builds" and "A rejected key"): the application key
  goes only to the paired bridge, and only after two checks at every start
  and address change: the identity check without the key (`GET
  /api/0/config` must report the paired id; asked again every 30 s while
  the bridge does not answer) and the TLS self-check (`bridge/tlscheck.lua`:
  a request with a decoy CA bundle must fail certificate verification).
  Nothing keyed is sent before both have passed, and every keyed send is
  refused at once, with one answer, while the driver is not paired (`not
  paired`), after a failed TLS check (`TLS check failed`, until the next
  start or address change; Status `TLS check failed: nothing is sent (see
  Attention)`) and while the bridge rejects the key (`key rejected`). An
  inconclusive TLS check passes only on a Director version that answered
  `pinned` before; otherwise Status reads `TLS check inconclusive
  (<reason>): nothing is sent; checking again in 30 s`. A 401 or 403 on the
  stream stops it (`Stopped: key rejected (HTTP <code>)`); one on a REST
  request is first confirmed with one GET of the bridge resource. `Pair
  Bridge`, a new address, or a `Test Connection` the paired bridge answers
  with 200 ends the lock. Keyed requests refuse redirects; a failed command is retried
  for at most 30 s after its last change, and `not paired`, `key rejected`
  and `TLS check failed` end it at once.
- **Event stream**: at most two stream transfers are open at once, live and
  abandoned together (`stream.MAX_ABANDONED + 1`; Director runs at most four
  `C4:url` transfers, `docs/design.md` "Concurrent transfers"); a new one
  waits meanwhile, and `Event Stream` reads `Waiting for an earlier stream
  transfer to close`. The row counts the reconnects since the driver
  started: `Connected since 23:11:46 (2 reconnects since 10-25 23:11)`, then
  `Connected since 23:11:46, 120 containers, last 23:40:02; 2 reconnects`
  (#65).
- **Names**: a name the bridge hands to Control4 (a new device's name, Adopt
  Hue Names, the devices' `Hue Name` / `Hue Scene` and `Hue Room` rows, the
  light's `Model` row, `Bridge Name`) goes through `util.display_name`
  (control characters removed, trimmed, at most 100 characters), and names
  are compared through it; a device made under an older build keeps its raw
  name until the owner renames it (#221).
- **Composer properties fit the column** (2026-10-24): Composer shows a value
  on one line of about 75 characters and clips the rest, so `Room Mappings`,
  `Lights`, `Scenes` and `Zone Lights` are drop-down lists (the summary on
  the row, every item in the list, a pick snaps back; commas read as "‚"
  there, since the list is comma-delimited), and `Last Action` is
  word-wrapped at 72 characters onto read-only rows `Last Action (2)` to
  `(6)` that show only while used (a longer text ends in "… (Lua output)";
  #68). `Scenes` reads "126 + 15 time-based on bridge, 2 imported, 2
  deleted" (missing and unbound only when not zero) and `Stream Address`
  reads "10.000.002.143 (own queue, spelling 1 of 7)", "… (own queue, the
  only spelling)" or "… (shared queue with commands: <reason>)". Verified in
  Composer (build 185): a property-type change installs without a reboot;
  the list needs `UpdateProperty` beside `UpdatePropertyList` to move the
  row; the list is comma-delimited, so no summary or item may hold a comma.
- **Hue Light** (light_v2 proxy, dimmer, colour and colour temperature when
  the bulb supports them): two-way state; keypad Button Links (Top, Bottom,
  Toggle): tap top = the On preset (Default On Brightness, 100 % unless
  changed) over the click rate up, tap bottom = off over the click rate
  down, hold = Hue's own relative dim (dimming_delta with a ramp over the
  hold rate, stop on release), hold top while off = on at 1 % then
  brighten, hold bottom while off = nothing; keypad LEDs follow on/off;
  button colours default to blue (top and toggle lit when on, bottom lit
  when off).
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
  scene at that level, 100 % from off plays it as designed. **On rule**: on
  from any activation (Control4, keypad, Hue app) until the room/zone turns
  off, another scene of it is played, or the device itself is turned off;
  persisted across restarts. ON is one request (dropped back if it fails);
  OFF and slider moves go through the group queue and are retried like
  light commands. Keypad: tap top plays, tap bottom turns off (taps are
  immediate: the scene declares no click rates), hold dims the room
  (relative), hold top while off plays at 1 % and brightens; LEDs follow
  the on state.
- **Keypad settings** (since build 296, #59; on the house since the
  owner's reboot of 2026-10-25): both device drivers declare
  `hide_proxy_properties` False, so the proxy's own settings show in
  Composer above the driver's properties. The drivers act on Default On
  Brightness (lights; 1–100 %, default 100), the click rates (lights;
  default 250 ms), the hold rates (default 5 s for the full range; rates
  0–86400000 ms) and the button LED colours; each setting persists per
  device, is confirmed to the proxy with a bare-value notification at late
  init and after every change, and a value out of range is refused
  (`common/device.lua`, one keypad machine for both drivers since #216).
  The light's page also shows a colour-on mode, which the driver does not
  handle (no `SET_COLOR_ON_MODE` handler).
- **Zone lights** (build 196, contract `docs/zone-light-design.md`): a Hue
  zone or room added as a Hue Light device of kind "group" with the bridge's
  `Add Zone Light` (Group, Room) action; `Re-link Zone Light`, `Forget
  Light` (zone-light devices after the lights), the `Zone Lights` property
  ("7 zones, 16 rooms on bridge; 2 imported"). The device: Status "Hue zone
  Bedside Lights (2 lights)", Model "Hue zone (2 lights)", Hue Light ID
  "zone #9 (b90ea7b4…)"; on while any lamp is lit, level = the group's
  average; ON = every lamp to 100 %, slider absolute on the group, keypad
  holds relative (`dimming_delta`), colour and colour temperature to the
  group, capabilities the union of the members' (the colour temperature
  range their common one, to which the bridge also clamps, #58); the tile's
  colour is the first lit lamp's. The grouped_light queue is paced at one
  request a second with a burst of three; a keypad hold's start and stop do
  not wait for it. A group with no lights is offline; a zone deleted in Hue
  leaves the device gone until Re-link Zone Light or Forget Light.
- **Bridge compatibility** (2026-10-24, after 1.0;
  `docs/bridge-compat-design.md`): pairing refuses the round
  first-generation bridge (BSB001), a device that is not a Hue bridge, and
  bridge software older than 1948086000 (the first with the CLIP v2 API),
  each with its own Status text; the identity check at every start refuses
  a first-generation bridge too. `Bridge Model` shows the friendly name with
  the id ("Hue Bridge Pro (BSB003)"); new rows `Bridge Name` (the bridge's
  own name) and `Bridge Firmware` (version and API version, with an update
  note when old).
- **Binding re-check** (`common/device.lua`): a light or scene that is
  unbound at start looks again at 5, 15, 30 and 60 s (after a Director
  restart the binding can be late).
- **Documentation tab** in every driver (the owner's manual on the bridge),
  **icons** (Bridge Pro; the dimmer-switch remote for lights; the same lit
  in colours for scenes); a light or scene device shows the new 16 px icon
  in the tree if it was created under a build that declared a custom icon;
  the 32 px List View tile is Composer's own status tile for every light_v2
  device and cannot show a driver icon (verified 2026-10-25, issue #60; the
  likeness icons are kept, `docs/licensing-research.md`).

## How builds reach the house (GitOps since 2026-10-25)

The house runs a GitHub release, never a VM build
(`docs/cicd-gitops-design.md`; CLAUDE.md "Deploy"):

1. The Release workflow (Actions ▸ Release ▸ Run workflow with the version,
   or a pushed tag; every 1.x release moves the tag `v1.0`) lints, tests and
   builds from `main` in a job without write access, then attests and
   publishes in a second job: the three `.c4z`, `SHA256SUMS.txt`,
   `manifest.json`, `attestations.sigstore.json` and
   `hue-drivers.intoto.jsonl`.
2. A pull request sets `deploy/house.yaml` (the desired state) to that
   build; on merge the drift workflow opens one issue labelled `deploy`.
3. `python3 tools/deploy.py start` downloads the assets, checks them against
   `SHA256SUMS.txt` and `manifest.json`, verifies their provenance (`gh
   attestation verify … --signer-workflow
   corytron/c4-hue-driver/.github/workflows/release.yml`), creates the
   Deployment on the environment `house` and writes
   `build/release/<tag>/BRIEF.md`.
4. The Windows Composer session follows the brief: it fetches the files
   from the release URLs into `C:\c4-hue\drivers\<tag>\`, checks the hashes,
   installs all three at once with Driver ▸ "Add or Update Driver or Agent…"
   (every existing device is updated in place; never delete and re-add, the
   pairing would be lost) and reads back every device's `Driver Version`
   and the bridge's `Stream Timeout (s)`, `Stream Watchdog (s)` and `Debug
   Mode`.
5. `python3 tools/deploy.py done --devices N` records success and closes
   the issue (`deploy.py failed --note` records what went wrong);
   `deploy.py status` says whether desired and observed agree.

**A build that changes a driver's capabilities** (driver.xml
`<capabilities>`) makes Composer ask "Restart Director?"; answering Yes does
**not** load it, and the devices keep the old capabilities until the owner
**reboots the controller from System Manager** (it runs elevated; the
Windows session cannot operate it; `deploy.py start --note` carries that
into the brief). Builds that only change Lua or connections take effect at
once.

A dev build (`tools/build.sh --dev`, for the dev loop) or a feature-branch
hardware test goes around the tool: it is served from `build/release/` with
`python3 -I -m http.server 8090 --bind 0.0.0.0 --directory build/release`
(stopped afterwards), briefed with its hashes and recorded afterwards with
`deploy.py record --no-manifest`, so the drift issue shows the house off its
desired state until a release is installed again; a release install ends the
dev loop.

## Verified on hardware

Pairing, the event stream and resync, import and the whole light lifecycle
(2026-10-21/22), scenes (add, recall, OFF, deleted in Hue, Forget, Re-link),
the Documentation tab and icons, keypad Button Links on a light, keypad
hold-to-dim and LEDs on a scene (Hue accepts `dimming_delta` with `dynamics`
and the `stop` action on a grouped_light), the scene dimmer in the iPhone app
and its LEDs (2026-10-24), the light staying bound through a controller
reboot, time-of-day scenes activated and deactivated from the bridge and
listed in Composer (2026-10-24, build 180), the readable Room Mappings
list (build 185), Add Zone Light creating the Bedside Lights zone light and
the Master Bedroom room light with the right texts, pickers and counts,
Forget Light and a Composer delete of a zone light (builds 196–199); the
Bedside Lights zone light from the owner's phone and keypad (2026-10-24,
build 199): ON, the slider, colour and OFF reach both lamps and the tile
follows the Hue app, which also confirms that a grouped_light PUT takes
`color` and `color_temperature`.

On 2026-10-25 (OS 3.4.2, Bridge Pro; dev builds 276 and 284 and the branch
of #217; `docs/design.md`, "Hardware facts of the 2026-10-25 dev pass",
"Concurrent transfers" and "Hardware pass of 2026-10-25 night", and the
issues named):

- the signed dev loop end to end, with `C4:HMAC` present on the controller
  and `tools/regress.sh` passing (#52);
- the TLS self-check: the decoy bundle refused with curl error 60, so the
  configured bundle is consulted (#53);
- an unknown application key answered with HTTP 403 and an HTML body on a
  CLIP v2 GET and on the event stream (#44);
- `GetBoundConsumerDevices` answers nil for a binding with nothing bound
  (#48);
- Director runs at most four `C4:url` transfers at once; abandoned stream
  transfers stalled every command until a bridge event (the cap of two
  stream transfers follows);
- a zone light: a 1 % level from off, a colour pick, a temperature pick
  (mirek 366 for 2700 K) and a colour set while off each go out as one
  grouped_light PUT; a change made in Hue reaches the zone, room and scene
  devices within a second; OFF on the room light turns Shine and Golden
  hours off; a lamp added to the zone in Hue reaches the live device; 50
  slider targets in 5 s made 9 PUTs and no 429 (#39); the bridge sent at
  most 2 event containers a second (#65);
- a 1 % level on Shine from off recalls the scene at that brightness in its
  own colours (#41);
- after the owner's controller reboot, the proxy's settings page on light
  and scene devices, a changed hold rate reaching the next hold, and the
  bare-value confirmation the proxy keeps (#59);
- the shared keypad machine on a zone light and on Shine through the Lua
  windows (dev build 284): a hold from off, a hold then a click, a bottom
  tap;
- the security fixes of #217 before their merge (a dev build, the branch
  through the dev loop): keyed requests still got their bodies with the
  redirect guard (a full resync and Refresh Scenes), the TLS check answered
  pinned, and Test Connection passed the gate.

## Release preparation for 1.0 (history, 2026-10-24)

Done before the first release install, on the branch `release-prep`: four
agents slimmed the code from five reviews (`docs/reviews/slim-*.md`,
`docs/reviews/efficiency-2026-10-24.md`; the shared modules
`common/device.lua`, `bridge/util.lua` and `bridge/project.lua`); release
builds lost the dev loop and the diagnostics (`tools/build.sh` refuses to
package a release that still has them) and got `Stream Timeout (s)` 3600
and `Stream Watchdog (s)` 600; the security review of 2026-10-24
(`docs/reviews/security-2026-10-24.md`) brought the identity check without
the key and caps on one event's data and on the early message buffers; a
corrected `Bridge IP Address` restarts the feed by itself; README, LICENSE
(Apache 2.0), NOTICE, CONTRIBUTING, `docs/README.md` and both manuals were
written or reviewed (`docs/reviews/manual-*.md`); then the dev-build
regression pass (build 224), the release installs (226, 228, 237), the
Composer checks of `docs/release-checklist.md` §2, the tag `v1.0`, the
history rewrite and the flip to public. The dev loop's open LAN surface
noted then was closed by #52 on 2026-10-25 (signed bundles and commands).
What was left is under "Open" (#38, #61, #62).

## Open

Every open item is an issue (`gh issue list --state open`); this list says
where each stands on 2026-10-25.

- **#228** Install release 1.0 build 316 on the house after the #40
  checks (`deploy.py start`, the Windows session, `deploy.py done`; no
  reboot); then Debug Mode Off and the dev loop ends.
- **#40** Time-of-day scenes: the keypad, Recall As after a cross-kind
  re-link, a dim before a slot boundary and API-made schedules, run on
  2026-10-25 from 10:00 with `tools/smart_scene_probe.py` (plan:
  `docs/smart-scenes-research.md` §8); the 16:00 slot boundary and the
  after-sunset V8 check are later that day. No result is recorded yet.
- **#231** This documentation accuracy pass against build 316 (branch
  `docs/accuracy-231`).
- **#61** Retake the manual's pictures with `tools/composer/Shots.ps1`
  (`docs/screenshots-plan.md`) after the release install.
- **#65** Read the Event Stream reconnect count after a day on the release.
- **#38** The owner's pass on the phone and keypads, and saving and backing
  up the Composer project (still unsaved through the test rounds).
- **#62** The owner deletes the old edit revisions on PRs #6 and #2;
  GitHub Support ticket for the purge is pending.
- **#224** Decision: the OpenSSF Best Practices badge, or Scorecard's CII
  check stays at 0.
- **#238** After the next reboot from System Manager: the bridge's log
  right after it shows no "is not bound to this bridge" lines and Attention
  no unbound devices (diff review 2026-10-25 row 2).
- **#232, #234, #236** Code bugs found by the documentation pass: a light or
  zone light hold from mid-range ramps faster than its tile; device-driver
  persistence and setting edge cases; pairing and Status edge cases.
- **#237, #239** Tooling: `deploy.py`'s watchdog range and the tag ruleset;
  `devctl`, `Composer.psm1` and release-note leftovers.
- **#233** Decision: ON and TOGGLE at 100 % or at Default On Brightness.

Decided, not open:

- **Accepted** (security review and fixes of 2026-10-25, #217;
  `docs/dev-loop.md`, "What is left"): names the device drivers build from
  cleaned Hue names ("<Room> Lights", "<Zone> <Scene>") are bounded but not
  cut; hostname verification stays off for the bridge (no C4:url option); a
  Hue Request `POST /api` in a dev build logs the newly minted key.
- **Code scanning** after every merge (CLAUDE.md): on 2026-10-25 every
  alert is fixed or dismissed with its reason; the triage workflow keeps one
  issue open only while alerts are.
