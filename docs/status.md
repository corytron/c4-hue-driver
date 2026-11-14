# Status of the Hue driver

The single page that says what is true now: what is released, what runs on
the author's house, and what is open. Everything under "History" is the
record as it was written at the time. Feature contracts and design notes
keep their history too; where they and this page disagree about the
present, this page and the code win. Brought up to date on 2026-11-13
(#478).

## Now (2026-11-13)

- **2.0 "Luthen" beta stage 1 (#514) is built, not released**
  (2026-11-14), on the branch `feat/hdmi-sync-stage1-514`: entertainment
  areas on the bridge, lights that say when their lamps sync with a TV,
  and the hidden 1.1 aliases and On State Follows removed as announced
  (`docs/hdmi-sync-stage1-design.md`). The house runs 1.8. Checks T0 to
  T9 (`docs/entertainment-areas-research.md` §4.5) wait for a sync on the
  house; the Composer steps for an installed beta are
  `docs/composer-checklist.md` section T.
- **Latest release: 1.8 "B2EMO", build 644**, released 2026-11-13
  ([release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.8),
  #509): a Hue Scene that is on shows its last level after a reload instead of
  100 until the bridge reports (#505). Lua only, no reboot.
- **The house runs 1.8, build 644: installed** at 01:10 local; deployment
  7758551474 recorded as a success, deploy issue #511 closed. All eight Hue
  devices read 644 exactly with `Debug Mode` Off, every one Online, no error
  or warning in the log. The #505 check passed on a second reload: Shine,
  on at 17 %, held 17 and never showed 100.
- **Before it: 1.7 "Clem", build 636**, released 2026-11-13
  ([release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.7),
  #500): the fixes of the security review of 2026-11-13 (#480, PR #496,
  issues #481 to #493). What owners notice: Debug Mode turns itself Off
  after 8 hours; a development build's Driver Version reads `<build>-dev`;
  devices ignore bridge messages for another resource; a burst of light
  commands goes out at most three requests at a time. No `<capabilities>`
  change, so no controller reboot.
- **Before that the house ran 1.7, build 636.** The Windows session installed
  it in place at 00:15 local; deployment 7757781288 is recorded as a success
  (2026-11-13 05:19 UTC), and the deploy issue #502 is closed. All eight Hue
  devices read Driver Version 636 exactly (no `-dev`), with `Debug Mode` Off,
  every one Online with the same Status as on 1.6, and the log since the
  install shows no error or warning. The first release from the four-job Release
  workflow, verified by `deploy.py` against the tag's commit and `main`.
- **Before it: 1.6 "Kassa", build 624**, released 2026-11-13
  ([release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.6),
  #474). It carries the four drivers: Hue Bridge (`hue_bridge.c4z`), Hue
  Light (`hue_light.c4z`), Hue Scene (`hue_scene.c4z`) and Hue Motion
  Sensor (`hue_motion.c4z`). Install all four from the same release.
- **Before that the house ran 1.6, build 624.** `deploy/house.yaml` names
  v1.6, build 624 (PR #475). The Windows session installed it in place at
  22:56 local time; deployment 7756665067 on the environment
  [`house`](https://github.com/corytron/c4-hue-driver/deployments/house)
  is recorded as a success (2026-11-13 04:06 UTC: "Driver Version 624 on 8
  devices, settings as deploy/house.yaml"), and the deploy issue #476 is
  closed. All eight Hue devices read Driver Version 624, with `Debug Mode`
  Off. The Environments page is the authority on what the house runs.
- **No Restart Director prompt and no controller reboot:** 1.6 changes no
  `<capabilities>`. Its checks on the house are
  `docs/composer-checklist.md` section S: steps 140, 141, 148 and 149
  passed on 2026-11-13 (Keypad Follows carried `Room/zone lights` on Shine
  and Golden hours, On State Follows is gone, the scene folders name their
  room, and both refusals read as designed); steps 142 to 147 (the owner's
  checks in the Control4 app) and 150 to 154 are open.
- **Open issues** (`gh issue list --state open`): #478 (this documentation
  review), #480 (a security review of the driver source), #237 (the tag
  ruleset still blocks deletion only; its range half was fixed in #244) and
  #62 (the GitHub Support purge of old pull request revisions). The
  hardware checks nobody has run yet are listed under "Not yet checked on
  the house".

What 1.6 changes (#469, contract `docs/scene-tracking-design.md`, research
in [Discussion #471](https://github.com/corytron/c4-hue-driver/discussions/471)):
- **Scene tiles follow their own scene.**
  - A Hue Scene's tile reads on, at its room's level, only while that
    scene is playing. Another scene, a scene without a device, lamps turned
    on by hand or a scene of an overlapping zone all leave it at 0.
  - The slider, ON and Toggle on a scene that is not playing switch the
    room to it.
- **Keypad Follows** replaces On State Follows (the value is copied once;
  the old row is hidden). It decides only what a bound keypad treats as on,
  so the bedroom switch stays lit with the room (departure D20, the owner's
  exception).
- **Scenes stay in their mapped room.**
  - Add From Hue and Link Device accept a scene only in the Control4 room
    its Hue room or zone maps to.
  - Unmapped rooms are refused with a pointer to Set Room Mapping. There
    are no one-to-many mappings.
  - Set Room Mapping can map the whole home (for scenes only), offers the
    mappings it found, and counts devices left in other rooms.

## What runs on the house

What is installed and set on 2026-11-13: release 1.6, build 624, on every
device (the Environments page is the authority).

- **Controller and bridge.** The controller reports OS 3.4.3 (the
  diagnostics of 2026-10-26 read `3.4.3.727848-res`; notes before that day
  say 3.4.2). Composer Pro 3.4.2 on the Windows VM. A Hue Bridge Pro
  (BSB003), paired.
- **Eight Hue devices**, all on one build:
  - the Hue Bridge;
  - two Hue Scene devices in the Master Bedroom: "Shine" (device 1162, the
    ordinary scene Shine) and "Golden hours" (device 1164, the room's
    time-of-day scene);
  - two zone lights in the Master Bedroom: "Bedside Lights" (device 1166,
    the Hue zone of the two bedside lamps) and "Master Bedroom Lights"
    (device 1168, the whole Hue room);
  - two single-light Hue Light devices (made with Add Light on 2026-10-26),
    the lamps of the motion programming;
  - one Hue Motion Sensor device for the house's one MotionAware area, the
    Stairwell (the bridge has no motion sensors).

  The bridge's other lights have no device: every light device was deleted
  in Composer on 2026-10-22, and a deleted light stays remembered as
  deleted until Add From Hue brings it back.
- **Bridge settings:** Event Stream Transport `Network connection` (the
  default since #317, 1.1), `Stream Timeout (s)` 3600, `Stream Watchdog (s)`
  600, `Debug Mode` Off (as `deploy/house.yaml` wants).
- **Device settings changed from their defaults:**
  - the four Hue Light devices: Click Rates 3.000 / 3.000 s (2026-11-09) and
    Color On Mode Preset (2026-11-10; Composer's default was Dim-To-Warm);
  - Shine and Golden hours: click rates 3.000 / 3.000 s (2026-11-10);
  - the motion device: Occupancy Hold Time 60 s (2026-11-09; 300 s before).
- **Keypads.** The "Bedside Lights Switch" (a Control4 switch run as a
  2-button keypad, Buttons Control Load off) has its top and bottom buttons
  bound to Golden hours' Top and Bottom Button Links (read in Composer on
  2026-10-27). The "Floor Lamp Switch" rocker is bound to a Control4
  dimmer, not to a Hue device. The bedside switches' ambient LED profile
  never turns the LEDs off (2026-11-09), and since 2026-11-11 (#467) the
  three bedroom switches' Status LED curve is a ramp (dark below ambient
  10, bright above 50) with the night minimum halved (13 on the keypad
  dimmer, 17 on the two switches; maximum 255). Set in Composer through each
  device's Ambient Light Customization editor.
- **Programming.** When the MotionAware area senses motion, two lamps rise
  by 30 points, and they go back to their saved level when it stops (#297;
  built in Composer by the Windows session on 2026-10-26).
- **Hue automations.** One: the Stairwell MotionAware set-up, set to do
  nothing on motion and on no motion, so Control4 alone decides; the Hue
  Automations row reads it as "Does nothing: Control4 decides" (#280).
- **Composer project:** the owner saves and backs it up (#38, closed
  2026-11-09: "everything works on the phone and the keypads").

## Not yet checked on the house

Nothing here blocks a release; each is a check of normal use.

- **From 1.6:** `docs/composer-checklist.md` section S, steps 142 to 147
  (the owner moves sliders and plays scenes) and 150 to 154 (a test scene
  device made and removed again).
- **From 1.5:** the owner skipped the bedroom visit on 2026-11-10 ("assume
  they pass, ship it"; #431 and #40 closed that day): the Advanced Lighting
  Scenes holds and tracking (B1), the tile taps (B2), the keypad on Golden
  hours (B3), the keypad taps of checklist sections O, Q and R, and a
  Shine timed ramp that may jump (the bridge reported 19.76 % about a
  second into a 10 s ramp; a new issue if it shows).
- **From 1.3:** the group holds, including a time-based scene that keeps
  running through a stepped hold; the turn-on guard; ON at Default On
  Brightness; the resumed motion hold.
- **From 1.2:** the write paths of the new actions; the automatic re-link
  by radio; the bridge-away Attention items (covered by specs).

## What the drivers do

The owner's manuals say it in full: the Hue Bridge's Documentation tab
([`src/hue_bridge/www/documentation.html`](../src/hue_bridge/www/documentation.html))
and the device pages of the
[Hue Light](../src/hue_light/www/documentation.html),
[Hue Scene](../src/hue_scene/www/documentation.html) and
[Hue Motion Sensor](../src/hue_motion/www/documentation.html). What each
release changed is in [`CHANGELOG.md`](../CHANGELOG.md). In short:

- **Hue Bridge** (its own proxy): pairs with one Hue bridge through the
  link button, finds it on the local network (mDNS, then a bounded sweep;
  never the internet), checks the bridge's identity and the controller's
  certificate pinning before any request that carries the key, holds the
  event stream and reads everything again after every connect, creates and
  links the other devices, keeps names in step both ways, maps Hue rooms
  and zones to Control4 rooms, and reports what needs a decision in
  `Attention`. Ten actions: Pair Bridge, Import All New, Add From Hue, Link
  Device, Forget Device, Resolve Names, Set Room Mapping, Hue Automations,
  Diagnostics, Forget Pairing. Contracts: `docs/import-design.md`,
  `docs/simplify-actions-design.md`, `docs/bridge-compat-design.md`,
  `docs/hue-automation-audit-design.md`, `docs/offline-design.md`,
  `docs/raw-stream-design.md`.
- **Hue Light** (`light_v2`, a dimmer with colour and colour temperature
  where the bulb has them): one Hue light, or a whole Hue room or zone as
  one zone light. Keypad Button Links, Control4's turn-on behaviour, load
  groups, its own button events, Raise Level By and Restore Saved Level.
  Contracts: `docs/lights-design.md`, `docs/zone-light-design.md`,
  `docs/keypad-design.md`, `docs/tap-stop-design.md`,
  `docs/turn-on-design.md`, `docs/load-groups-design.md`,
  `docs/light-events-design.md`, `docs/relative-level-design.md`.
- **Hue Scene** (`light_v2`, a dimmer): one Hue scene, ordinary or
  time-of-day. Its tile follows its own scene, its slider switches the room
  to it and dims it, and Keypad Follows decides what a bound keypad treats
  as on. Contracts: `docs/scenes-design.md`, `docs/scene-dimmer-design.md`,
  `docs/smart-scenes-design.md`, `docs/group-hold-design.md`,
  `docs/scene-tracking-design.md`.
- **Hue Motion Sensor** (Control4's stock motion sensor): a Hue motion
  sensor, or a MotionAware area (Bridge Pro only), with Occupancy Hold Time
  and the sensor's light level, temperature and battery. Contracts:
  `docs/motion-design.md`, `docs/motion-hold-restart-design.md`.

**Where they have run.** The drivers are meant for Control4 OS 3.x and
4.x (minimum OS 3.3.0 in every `driver.xml`; `docs/design.md`, "Targets")
and have run on OS 3.4 only: **OS 4.x has not been tried.** On the Hue
side they have run with a Hue Bridge Pro (the house) and a Hue Bridge v2
(an outside tester, on the 1.1 betas, #309).

## How builds reach the house (GitOps since 2026-10-25)

The house runs a GitHub release, never a VM build
(`docs/cicd-gitops-design.md`; `docs/release-checklist.md`, "Deploy to the
house"; CLAUDE.md "Deploy"):

1. The Release workflow (Actions ▸ Release ▸ Run workflow with the version
   `X.Y`, or a pushed tag) lints, tests and builds from `main` in a job
   without write access, tags the commit `vX.Y` (a later run of the same
   version moves that tag; a prerelease tag `vX.Y-beta.N` never moves),
   then attests and publishes in a second job: the four `.c4z`,
   `SHA256SUMS.txt`, `manifest.json`, `attestations.sigstore.json` and
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
   installs all four at once with Driver ▸ "Add or Update Driver or Agent…"
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
hardware test goes around the tool: it is served with
`python3 -I tools/serve_install.py <packages>`, which serves only those files
from a random temporary path, prints their URLs and hashes for the brief and
stops after the download (#481; `build/release/` is never served whole), and
it is recorded afterwards with `deploy.py record --no-manifest`, which marks
it a dev build, so the drift issue shows the house off its desired state until
a release is installed again; a release install ends the dev loop. A dev build
reads `<build>-dev` in Driver Version (#492).

## History

Newest first. Each entry is the record as it was written then; the present
is above.

### 1.5 "Kenari", build 609 (released 2026-11-10)

[Release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.5),
#457; installed on the house on 2026-11-10 (deployment 7675806649, "Driver
Version 609 on 8 devices"), until 1.6 replaced it on 2026-11-13. What
1.5 changes:
- **Hue automation audit** (#280, `docs/hue-automation-audit-design.md`): a
  Hue Automations row and Attention items for Hue automations that act on
  Control4 lights, and a tenth bridge action that disables, restores or
  keeps one. On the house: 1 automation, the Stairwell MotionAware set-up,
  read as "Does nothing: Control4 decides".
- **Turn-on behaviour** (#429, #427, #430, `docs/turn-on-design.md`):
  Control4's brightness On Mode, On and Dim colours and colour on modes,
  the default rate and the rate ranges on Hue Lights; click rates in
  Composer on Hue Scenes.
- **Offline** (#428, `docs/offline-design.md`): every Hue device goes
  offline after 5 minutes without the bridge and back at the first answer;
  a command that did not reach the bridge never shows as done.
- **Load groups** (#435, `docs/load-groups-design.md`): Hue Lights join
  Control4 load groups; whole Hue rooms and zones move as one request.
- **The light's own button events, Set All LEDs, and Hue-side level reports
  once a second** (#432, #433, `docs/light-events-design.md`).
- **Composer tooltips and motion event order** (#434).
- **Capabilities changed:** the owner rebooted the controller from System
  Manager on 2026-11-10 at about 01:38, with dev build 604 (the same code)
  installed; the release went over it with no second reboot.
- **Checked on the house on 2026-11-10 (dev build 604, no hands):** #238
  holds (no device marked unbound after the reboot, no `[ERROR]`); #65's
  rate is 82 reconnects in 24 h on 1.4 (watchdog ceiling 144 a day); the
  offline round trip with the offline time at 30 s (all 7 devices offline at
  30 s and back 3 s after the bridge answered, the motion Offline and
  Online events once each, the Attention item shown and cleared); the
  zone light's timed ramp (one grouped_light request with a duration); the
  button events through the proxy route (Top Push, Top Release); Composer
  offers the four Hue Lights to a Dimmer Load Group and not the scenes;
  Programming lists the light's 15 button events; the Hue Automations row
  and the tenth action; the new On Mode and colour fields.
- **Not checked, skipped by the owner ("assume they pass, ship it"):** the
  owner's bedroom visit: #431's Advanced Lighting Scenes holds and tracking
  (B1), the tile taps (B2), #40's keypad on Golden hours (B3), the keypad
  taps of checklist sections O, Q and R (tap counting, `BUTTON_EVENTS_MODE`
  stays "count"), and a Shine timed ramp that may jump (the bridge
  reported 19.76 % about a second into a 10 s ramp). #431 and #40 were
  closed on that decision; the checklist keeps the steps.
- **House settings set the same night:** Shine and Golden hours click rates
  3.000 / 3.000 s; Color On Mode Preset on the four Hue Lights (Composer's
  default was Dim-To-Warm); Debug Mode Off.

### 1.4 "Maarva", build 565 (released 2026-11-09)

[Release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.4);
build reports, the house measurement and the keypad test in
[Discussion #439](https://github.com/corytron/c4-hue-driver/discussions/439);
installed through `deploy/house.yaml` (#441). What 1.4 changes (#421,
contract `docs/tap-stop-design.md`):
- **Hue Lights** (single, zone and room): a keypad tap ramps to the Default
  On Brightness or to off over 3 s for the whole range (was 250 ms), and a
  tap while it ramps stops it, written as the device's estimate with a 1 s
  glide.
- **Hue Scenes:** a tap fades the scene in or its group out over a fixed
  3 s, and a stop keeps every lamp at its own level. Time-of-day scenes
  stay instant.
- **Double taps:** a second tap within 0.6 s changes nothing.
- **Real stops:** `SET_BRIGHTNESS_STOP` and the Brightness Stop link now
  stop the lamp.
- **Measured on the house** on 2026-11-09 with the owner watching (§10 of
  the contract). A keypad test on a zone light passed: "All looks good and
  right". Scene taps on a keypad were tried later the same day and work
  (owner: "scene taps work fine").
- **House settings changed the same night:**
  - the four Hue Light devices' Click Rates are 3.000 / 3.000 s (were
    0.250 / 0.750);
  - the stairwell motion device's hold time is 60 s (was 300);
  - the bedroom switches' ambient LED profile never turns the LEDs off.
  - **2026-11-11, #467:** the three bedroom switches' Status LED curve is
    now a ramp (dark below ambient 10, bright above 50, was a step at
    74/75) with the night minimum halved (13 on the keypad dimmer, 17 on
    the two switches; maximum 255), so the keypad no longer sits at the
    night level while the switches are at full by day. Set in Composer
    through each device's Ambient Light Customization editor, read back
    from Composer's log; nothing is saved to the project file.
- **Then planned for 1.5** (one controller reboot), built on feature
  branches on 2026-11-09 after the owner's decisions on the audit issues:
  the Hue automation audit (#280, PR #285, merged first: no reboot of its
  own), Composer tooltips (#434, merged), turn-on behaviour (#429, #427,
  #430, PR #451), load groups (#435, PR #452), offline after 5 minutes
  (#428, PR #453), the light's button events and throttled reports (#432,
  #433, PR #454); the house round for #238, #65, #431 and #40 follows the
  install (`docs/house-checks-plan.md`). #38 closed as not needed.
- **Process:** the Control4 lighting guidelines rule and checklist
  (`docs/c4-lighting-guidelines.md`, #422). Its gaps are filed as #427 to
  #435.

### 1.3 "Kerri", build 539 (released 2026-11-08)

[Release](https://github.com/corytron/c4-hue-driver/releases/tag/v1.3);
agent reports and the hardware round in
[Discussion #401](https://github.com/corytron/c4-hue-driver/discussions/401).
What 1.3 changed is in `CHANGELOG.md`:
- **Holds:** a hold on a scene, zone light or room light ramps instead of
  jumping (#249).
- **Motion:** a motion hold resumes after a restart (#371).
- **ON and TOGGLE:** they follow Default On Brightness (#233).
- **Fixes:** #243, #246, #308 and #329.
- **Under the hood:** the bridge driver's main chunk is down from 199
  locals to 137 (#373), and dev-loop reloads clean up after themselves
  (#247, #376).

The dev build 538 checks passed on the house. The owner chose to ship
without the lamp tests (2026-11-08); they are listed under "Not yet checked
on the house".

### 1.2 "Taramyn", build 488, and 1.1 "Brasso", build 447 (both released 2026-11-05)

1.2: [Discussion #387](https://github.com/corytron/c4-hue-driver/discussions/387);
1.1: [Discussion #382](https://github.com/corytron/c4-hue-driver/discussions/382).
1.2 (#334, PR #353, contract `docs/simplify-actions-design.md`) was checked
on the house in two dev rounds:
- dev 467 ([Discussion #369](https://github.com/corytron/c4-hue-driver/discussions/369));
- dev 477, wave 3 ([Discussion #378](https://github.com/corytron/c4-hue-driver/discussions/378)).

What 1.2 does:
- **Bridge actions:** a release's 29 become 9 (Pair Bridge, Import All New,
  Add From Hue, Link Device, Forget Device, Resolve Names, Set Room
  Mapping, Diagnostics, Forget Pairing). The contract's inventory of 39
  also counts the 3 dev-only bridge actions and the 7 device actions. Since
  1.5 there are ten: Hue Automations sits between Set Room Mapping and
  Diagnostics. The light and scene devices have no actions; the old
  commands answer as hidden aliases until 2.0.
  Current (2.0, #514, 2026-11-14): as announced, 2.0 removes those hidden
  aliases; the old commands no longer answer.
- **By itself:** it reads the bridge in tiers, re-checks a rejected key,
  finds the bridge on the LAN (mDNS, then a bounded sweep, never the
  internet), maps rooms by exact name, and re-links a returned bulb by its
  radio.
- **Names:** they sync both ways.
- **Attention:** it wraps onto continuation rows and says when the bridge
  is away, missing, moved or answering elsewhere.

Follow-ups filed then: #371, the occupancy hold after a restart; #373,
driver.lua near Lua 5.1's limit of 200 locals; #376, dev-loop reload
leftovers, also on 1.1. All three shipped in 1.3.

### The 1.1 betas (2026-10-26 to 2026-11-05)

Prereleases, never Latest (`docs/prerelease-design.md`, #269):
`v1.1-beta.1` (build 376) and `v1.1-beta.2` (build 381) add the fourth
driver, `hue_motion.c4z`: Hue motion sensors and MotionAware areas (Hue
Bridge Pro) as stock Control4 motion sensors (#268,
`docs/motion-design.md`), built for an outside tester who owns sensors (the
house has none). Beta 2 fixes a MotionAware area flapping between motion
and no motion (#288). `v1.1-beta.3` (build 394, 2026-10-26; the tester's
round is #305) adds the Hue Light's Raise Level By and Restore Saved Level
programming commands (#297, `docs/relative-level-design.md`) and fixes a
newly added light or scene device that failed its start (#298).
`v1.1-beta.4` (build 400, cut 2026-10-27 from `main` at 508452d) adds On
State Follows to every Hue Scene device: by default its tile and keypad
LEDs follow the lights of its Hue room or zone, not only its own scene
(#310, PR #311, `docs/scene-led-design.md`; replaced by Keypad Follows in
1.6). Betas 5 to 8 (2026-10-27 to 2026-11-05) followed; among them the
event stream moved onto a network connection (#317,
`docs/raw-stream-design.md`), and beta 8 was the last before 1.1. The stable release, and the README's
download links, stayed 1.0 build 359 until 1.1. Design north star (owner,
2026-10-26): Control4, not the Hue app, is the source of truth for
automations; the Hue automation audit (#280) followed in 1.5.

What ran on the house then:

- **Prerelease v1.1-beta.4, build 400, installed (2026-10-27)**: the
  desired-state PR #313 set `deploy/house.yaml` to it; the Windows session
  installed all four drivers in place, no Restart Director prompt, Driver
  Version 400 on eight devices, deployment 7370529823 recorded as success
  (17:14 local), and both scene devices read On State Follows `Room/zone
  lights`. Since beta 3 only the Hue Scene driver's code changed (On State
  Follows, #310, PR #311; the manual too), not its capabilities, so no
  reboot was needed.
- **Prerelease v1.1-beta.3, build 394, before that** (PR #301; deployment
  recorded 2026-10-26 21:05, closing #302; the Composer round is
  Discussions #307): all four drivers, Driver Version 394 on eight devices
  (the bridge, two scenes, two zone lights, two single lights and the motion
  device), no reboot (no capability change since 1.0). Its walk test ran the
  first Control4 motion programming, built in Composer by the Windows
  session (two walks, both correct): two lamps raised by 30 points when the
  MotionAware area senses motion and restored to their saved level when it
  stops (#297); the motion device's hold time was 300 s from then (60 s
  since 2026-11-09). A light that had failed its start on build 381 came up
  by itself (#298). Beta 2 (build 381) ran from 20:05 that day, beta 1
  (build 376) from 16:17. The motion device stands for the house's one
  MotionAware area (the bridge has no motion sensors); its Hue automation
  is set to do nothing on motion and on no motion, so Control4 alone
  decides what the lights do, and beta 2's walk test showed motion
  reaching Control4 within about a second (#288, Discussions #290).

### 1.0 "Cassian", build 359, tag `v1.0` (2026-10-25)

Cut 2026-10-25 by the two-job Release workflow from `main` at ad0ad7c; build
349 plus the changelog of #255, which every release's notes and every
Documentation tab now carry: the review leftovers (#214), the shared
lifecycle base and keypad machine (#216), the security fixes of 2026-10-25
(#221), code scanning triage (#223), the scene probe (#218), the screenshot
tooling (#227), the documentation accuracy pass (#240), the pairing and
Status fixes (#245), the device fixes (#242) and the retaken pictures in
all three manuals of the time (#251). Builds 316 and 329, published earlier
that day, are superseded; build 329 ran on the house from 10:32 until the
final build's install. Until 1.1 every build of 1.0 moved the tag `v1.0`;
from 1.1 each version has its own tag.

**The repository is public since 2026-10-24** (history rewritten that day:
placeholder addresses, two screenshots dropped; rewritten again on
2026-10-25 for three more spellings of the house address, #62): main is
protected (pull requests only, the four CI checks of
`.github/workflows/ci.yml` required, branch current before merge, admins
included, no force pushes), secret scanning, push protection, CodeQL,
Dependabot security updates and private vulnerability reporting are on,
and Issues, Discussions and the public project board "Hue driver" track
the work. The milestone `1.0 "Cassian"` holds the project's history: 37
pull requests (36 merged, #7 closed unmerged) and 98 closed issues
(#71–#187) describing every problem found and fixed, each naming its fix;
the project board holds them all. Every X.Y release has its own codename
(`.github/codenames.json`, #304).

**Since 2026-10-25 the project is run as CI/CD and GitOps**
(`docs/cicd-gitops-design.md`, PR #205): one script, `tools/check.sh`, runs
every check on the VM and in CI; releases are cut by the Release workflow
and carry `manifest.json` and provenance attestations; `deploy/house.yaml`
is the desired state of the house and the GitHub environment
[`house`](https://github.com/corytron/c4-hue-driver/deployments/house)
records every install (`tools/deploy.py`); a drift workflow keeps one issue
labelled `deploy` open while they differ (a run that finds drift is a green
run since PR #210). The Composer click stays with the Windows session: the
controller has no install API. OpenSSF Scorecard's first score was 6.2; on
2026-10-25 it read 7 (below 10: Maintained, Code-Review, Fuzzing and
CII-Best-Practices at 0, the last one #224; Branch-Protection and
Contributors at 3).

What ran on the house then:

- **The proxy's settings on the devices since 2026-10-25** (#59): the owner
  rebooted the controller from System Manager during the night's hardware
  pass (dev build 284), which loaded the capability change of #59
  (`hide_proxy_properties` False on both device drivers); builds 309, 316
  and 329 kept it.
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
  until the dev install of 2026-10-25 03:24. Build 247 is recorded there as
  deployment 7307525952 (installed 2026-10-24 21:04, before the tool
  existed).
- **Build 247** (superseded by 259 above; no dev loop), on the three drivers
  of the time (installed 2026-10-24 21:04; release 1.0 "Cassian" is build
  237 plus PRs #69, #70 and #130: `Last Action` word-wrapped at 72
  characters onto read-only rows `Last Action (2)` to `(6)` that are shown
  only while used, their visibility sent 400 ms after the texts and again
  1.5 s later because Composer drops attribute changes that arrive with the
  text updates; the four item lists editable, since a read-only list is a
  disabled control in Composer; `Debug Mode` Off, a dev build had left it
  On): Hue Bridge, Hue Light, Hue Scene. Read back from Composer: Bridge
  Model "Hue Bridge Pro (BSB003)", Bridge Name "Hue Bridge Pro", Bridge
  Firmware "2071524040 (API 1.78.0)"; `Stream Timeout (s)` 3600, `Stream
  Watchdog (s)` 600. Controller on OS 3.4.2, Composer Pro 3.4.2, Hue Bridge
  Pro (BSB003), paired.
- **Devices then.** Two Hue Scene devices in the Master Bedroom: "Shine"
  (device 1162) and "Golden hours" (device 1164, created 2026-10-24 12:06);
  two zone lights in the Master Bedroom, created with Add Zone Light on
  2026-10-24: "Bedside Lights" (device 1166) and "Master Bedroom Lights"
  (device 1168). 126 + 15 time-based scenes on the bridge, 2 imported.
- **Composer project** was left unsaved through the test rounds; the owner
  saves and backs it up (#38).

### What the drivers did at build 316 (2026-10-25)

Written for the documentation accuracy pass (#231) and not brought up to
date since: it describes 1.0's 29 actions and texts. What the drivers do
now is "What the drivers do" above and the manuals.

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
  with 200 ends the lock. Keyed requests refuse redirects; a failed command
  is retried for at most 30 s after its last change, and `not paired`, `key
  rejected` and `TLS check failed` end it at once.
- **Event stream**: at most two stream transfers are open at once, live and
  abandoned together (`stream.MAX_ABANDONED + 1`; Director runs at most four
  `C4:url` transfers, `docs/design.md` "Concurrent transfers"); a new one
  waits meanwhile, and `Event Stream` reads `Waiting for an earlier stream
  transfer to close`. The row counts the reconnects since the driver
  started: `Connected since 23:11:46 (2 reconnects since 10-25 23:11)`, then
  `Connected since 23:11:46, 120 containers, last 23:40:02; 2 reconnects`
  (#65). (Since #317, 1.1, the stream runs on a network connection by
  default and `C4:url` only with Event Stream Transport `Web transfer`.)
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
  brightens; on while Hue's state is active (ends on room off, another
  scene of the room, another schedule on its lights, or its own OFF):
  exactly then with On State Follows `This scene`, by default also while
  the room's or zone's lights are on (below); Recall As hidden; Status
  "Hue time-based scene Golden hours in Master Bedroom; now Arise (from
  07:00)" / "…; not running". Contract `docs/smart-scenes-design.md`,
  checks `docs/smart-scenes-research.md` §7.
- **Hue Scene** (light_v2 proxy, **dimmer** since build 160): ON plays the
  scene (Recall As: As set in Hue / Static / Dynamic), OFF turns its room or
  zone off (a zone with no lights, which has no group light, only reports
  off). The level is the room/zone brightness Hue reports; the slider moves
  the room relative to it (keeping the scene's colours and per-light
  differences; while the room's level is not yet known it sets one absolute
  level for all its lights instead), 0 % = off, a level from off plays the
  scene at that level, 100 % from off plays it as designed. **On rule** (the
  whole on state with On State Follows `This scene`, below): on from any
  activation (Control4, keypad, Hue app) until the room/zone turns off,
  another scene of it is played, or the device itself is turned off;
  persisted across restarts. ON is one request (dropped back if it fails);
  OFF and slider moves go through the group queue and are retried like
  light commands. Keypad: tap top plays, tap bottom turns off (taps are
  immediate: the scene declares no click rates), hold dims the room
  (relative), hold top while off plays at 1 % and brightens; LEDs follow
  the on state.
- **On State Follows** (Hue Scene, since build 400; #310, PR #311, contract
  `docs/scene-led-design.md`; replaced by Keypad Follows in 1.6): a
  property on every Hue Scene device. `Room/zone lights`, the default (also
  for existing devices after the update), shows the device on while the on
  rule holds **or** any light of its Hue room or zone is on (the group's
  on/off, which the bridge already sends; not persisted, it comes again with
  the answer to the device's hello): another scene of the room, or a light
  of it turned on from the Hue app, a Hue switch or a Hue Light device,
  keeps it on, and it shows off once they are all off. `This scene` is the
  on rule alone, as before. That one on state drives the tile and slider,
  the keypad LEDs, the on and off events, TOGGLE, whether the slider moves
  the room or plays the scene, and which way a hold goes; what ON, OFF and
  the taps do is unchanged. A whole-home scene or an empty zone gets no
  group state, so its on rule alone decides.
- **Keypad settings** (since build 296, #59; on the house since the
  owner's reboot of 2026-10-25): both device drivers declare
  `hide_proxy_properties` False, so the proxy's own settings show in
  Composer above the driver's properties. The drivers act on Default On
  Brightness (lights; 1–100 %, default 100), the click rates (lights;
  default 250 ms, 3000 ms since 1.4), the hold rates (default 5 s for the
  full range; rates 0–86400000 ms) and the button LED colours; each setting
  persists per device, is confirmed to the proxy with a bare-value
  notification at late init and after every change, and a value out of
  range is refused (`common/device.lua`, one keypad machine for both
  drivers since #216). The light's page also shows a colour-on mode, which
  the driver did not handle then (handled since 1.5, #430).
- **Zone lights** (build 196, contract `docs/zone-light-design.md`): a Hue
  zone or room added as a Hue Light device of kind "group" with the bridge's
  `Add Zone Light` (Group, Room) action; `Re-link Zone Light`, `Forget
  Light` (zone-light devices after the lights), the `Zone Lights` property
  ("7 zones, 16 rooms on bridge; 2 imported"). The device: Status "Hue zone
  Bedside Lights (2 lights)", Model "Hue zone (2 lights)", Hue Light ID
  "zone #9 (b90ea7b4…)"; on while any lamp is lit, level = the group's
  average; ON = every lamp to 100 % (Default On Brightness since 1.3,
  #233), slider absolute on the group, keypad holds relative
  (`dimming_delta`), colour and colour temperature to the group,
  capabilities the union of the members' (the colour temperature range
  their common one, to which the bridge also clamps, #58); the tile's
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

### Verified on hardware (2026-10-21 to 2026-10-25)

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

Later hardware results are in each release's entry above, its issues and
its Discussion.

### Release preparation for 1.0 (2026-10-24)

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

### Open list of 2026-11-07 (history)

What was open then and how it ended:
#280 (the Hue automation audit) shipped in 1.5; #65 (the reconnect count)
was measured on 2026-11-10 (82 a day, under the ceiling of 144); #38 (the
owner's pass on the phone and keypads) was closed by the owner on
2026-11-09 as no longer needed; #238 (no device unbound after a reboot)
held on 2026-11-10; #308, #329, #243, #246, #247 and #376 were fixed in
1.3; #40 (time-of-day scenes) was closed on 2026-11-10 by the owner's
decision to skip the manual tests. Still open: #62 and #237 ("Now").
