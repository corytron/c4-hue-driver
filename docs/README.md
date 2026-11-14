# The docs folder

What each file here is for, and whether it describes the drivers as they are
now or is a dated record.

One rule runs through all of them: `status.md` is the single
page of the present. Every other note keeps its history as written, with
dated "Superseded" or "Current" lines where behaviour changed later. Where a
note and `status.md` disagree about the present, `status.md` and the code
win.

The owner's manuals are not here but in the drivers, as each one's
Documentation tab in Composer: the
[Hue Bridge](../src/hue_bridge/www/documentation.html) (the full manual),
and one page each for the
[Hue Light](../src/hue_light/www/documentation.html),
[Hue Scene](../src/hue_scene/www/documentation.html) and
[Hue Motion Sensor](../src/hue_motion/www/documentation.html). What each
release changed is in [`CHANGELOG.md`](../CHANGELOG.md); the working rules
of the AI sessions that build the drivers are in [`CLAUDE.md`](../CLAUDE.md).

Labels used below: **current** = kept true for the drivers as they are;
**contract** = the specification a feature was built against, with dated
notes where it changed later; **record** = a dated note that stays as
written.

## Start here

- [`status.md`](status.md) (current): what is released, what runs on the
  author's house, what is not yet checked there, what is open (with the
  GitHub issues), and the history of every release.
- [`design.md`](design.md) (overview current, sections a record): the
  engineering notebook. Its overview names the four drivers and the
  modules, and points to the contracts; the dated sections hold the
  targets (OS versions, Lua 5.1), networking and the certificate bundle,
  the TLS self-check, a rejected key, the event stream and the measured
  `C4:url` limits on OS 3.4.2, lights, keypads, the hardware rounds,
  discovery, commands and rate limiting, colour mapping and storage. Each
  API claim is marked verified or assumed.
- [`c4-lighting-guidelines.md`](c4-lighting-guidelines.md) (current): Control4's
  lighting guidelines for function and UI as one checklist (from the
  light_v2 best practices, the proxy protocols and Control4's dealer
  documentation), each row with the drivers' status and its evidence; the
  gaps ranked with their issues, and the departures Hue forces. Every
  lighting feature contract cites its rows in a "Control4 guidelines"
  section (#422).

## Runbooks

How the work is done today; each is kept in step with the tools.

- [`release-checklist.md`](release-checklist.md) (current): what a build
  must pass on the development machine, on the dev loop, in Composer and on
  the owner's phone and keypads before it is called good, and after a
  controller OS upgrade; versions and codenames; how a release and a
  prerelease are cut (the Release workflow); how a release reaches the
  house (`tools/deploy.py`).
- [`dev-loop.md`](dev-loop.md) (current): the development loop. A `--dev`
  build of the bridge fetches its Lua from `tools/devserver.py`, reloads
  itself and the light and scene devices, runs actions queued with
  `tools/devctl.py` and ships its log back; every bundle and command is
  signed with the developer's dev key.
- [`composer-remote.md`](composer-remote.md) (current, with a dated
  history): driving Composer Pro from the development machine through a
  Claude Code session on the Windows machine (UI Automation from
  PowerShell, `tools/composer/Composer.psm1`), the rules every brief
  carries, and the test rounds run that way.
- [`composer-checklist.md`](composer-checklist.md) (current steps, dated
  results): the steps only Composer, a Navigator, a keypad or the Hue app
  can show, by section and release, each with a "Done" line. Section L is
  release 1.2's (#334), N the Hue automation audit (#280), O to R release
  1.5's, S release 1.6's scene tracking (#469).

## Feature contracts

Written before the code of each feature, against the research below, and
built by parallel agents. They are the specification; `status.md` says
what of it runs on the house, and dated "Current" lines inside each say
where the code later moved on.

### Bridge, pairing and the event stream

- [`bridge-compat-design.md`](bridge-compat-design.md) (contract): bridge
  generations and software: what pairing refuses (the round BSB001, a
  device that is not a Hue bridge, software older than 1948086000), the
  same model check at every start, and the Bridge Model, Bridge Name and
  Bridge Firmware rows.
- [`raw-stream-design.md`](raw-stream-design.md) (contract since
  2026-10-27, #317): the event stream on a network connection instead of
  `C4:url`, the default since 1.1 (Event Stream Transport `Network
  connection`; `Web transfer` is the fallback). §0 is the contract; the
  rest is the research of 2026-10-21, when the design was first set aside.
- [`offline-design.md`](offline-design.md) (contract): Hue devices go
  offline after the bridge has been unreachable for 5 minutes (#428), and a
  command that could not be delivered never shows as done (2026-11-09).
- [`hue-automation-audit-design.md`](hue-automation-audit-design.md)
  (contract, shipped in 1.5): what counts as a conflicting Hue automation,
  the Attention items and the "Hue Automations" row, the tenth bridge action
  with its one-click Disable, Restore and Keep, the record that survives
  updates and reboots, and the Hue app steps for what the API refuses
  (2026-11-09, #280).

### Importing, rooms and the bridge's actions

- [`import-design.md`](import-design.md) (contract; its action names are
  1.1's): the lifecycle of lights, rooms and scenes: adding and importing,
  the Hue room to Control4 room mapping, renames, replacements and
  deletions on either side (re-link, forget, tombstones).
- [`simplify-actions-design.md`](simplify-actions-design.md) (contract of
  1.2): fewer actions and more background tasks (2026-11-04, #334): the
  research phase, the inventory of the 39 actions, the verdicts, the
  merged proposal with the owner's decisions, what the dev build of
  2026-11-05 showed, and the build contracts of 1.2 (nine actions; 1.5
  added the tenth). Its research is listed under "Research".
- [`list-rows-design.md`](list-rows-design.md) (contract): one wording for
  the bridge's bulk actions and one format for its four list rows
  (2026-10-28, #325).

### Lights

- [`lights-design.md`](lights-design.md) (contract): Hue lights as
  `light_v2` devices: state, commands, the messages between the bridge and
  the light driver, the command queue and coalescing.
- [`zone-light-design.md`](zone-light-design.md) (contract): a Hue zone or
  room as one Hue Light device (a zone light): adding it, the tile's state,
  the grouped command pace, capabilities, renames and deletions.
- [`turn-on-design.md`](turn-on-design.md) (contract, 1.5): Control4's
  turn-on behaviour for Hue lights (#429, #427, #430): brightness On Mode
  Preset and Previous, the On and Dim colours and colour on modes, the
  default rate and the rate ranges (2026-11-09).
- [`load-groups-design.md`](load-groups-design.md) (contract, 1.5): Hue
  lights in Control4 load groups (#435), and one request per whole Hue room
  or zone so those lamps move together (2026-11-09).
- [`light-events-design.md`](light-events-design.md) (contract, 1.5): the
  light's own button events firing as on a Control4 dimmer, `SET_ALL_LED`,
  and Hue-side level reports throttled to one a second (#432, #433).
- [`relative-level-design.md`](relative-level-design.md) (contract): the
  Hue Light's Raise Level By and Restore Saved Level programming commands
  (2026-10-26, #297), for motion programming that raises lamps and puts
  them back.

### Keypads, taps and holds

- [`keypad-design.md`](keypad-design.md) (contract): Button Links on Hue
  Light and Hue Scene devices: taps, hold-to-dim through Hue's relative
  dimming, keypad LEDs, decoupled Control4 switches, and the keypad settings
  shown in Composer since 2026-10-25 (#59).
- [`group-hold-design.md`](group-hold-design.md) (contract, 1.3): holds on
  Hue Scene devices, zone lights and room lights (#249): Hue ignores the
  ramp time on a whole-group dim, so a hold dims each lit lamp (up to 10)
  or steps the group once a second.
- [`tap-stop-design.md`](tap-stop-design.md) (contract, 1.4): a keypad tap
  ramps over the click rate, a second tap after the double-tap window stops
  it, and the default click rates are slow enough to catch (#421,
  2026-11-08).

### Scenes

- [`scenes-design.md`](scenes-design.md) (contract): one Hue Scene device
  per Hue scene, created only by the owner; the on rule and the room or
  zone OFF.
- [`scene-dimmer-design.md`](scene-dimmer-design.md) (contract): the Hue
  Scene as a dimmer whose level is the room or zone's brightness.
- [`smart-scenes-design.md`](smart-scenes-design.md) (contract): Hue's
  time-of-day ("smart") scenes as Hue Scene devices: start, stop, dim while
  running, listing and naming.
- [`scene-led-design.md`](scene-led-design.md) (contract, superseded in
  1.6): On State Follows, a scene device's tile and keypad LEDs following
  its room or zone's lights (#310).
- [`scene-tracking-design.md`](scene-tracking-design.md) (contract, 1.6): a
  scene device's tile follows its own scene, its slider switches the room
  to it, Keypad Follows keeps the keypad on the room's lights, and scenes
  stay in the Control4 room their Hue room or zone maps to (#469).

### Motion

- [`motion-design.md`](motion-design.md) (contract, 1.1): Hue motion
  sensors and MotionAware areas as Control4 motion sensors (2026-10-26,
  #268): `hue_motion.c4z` as a stock `contactsingle_motionsensor`, the
  decisions D1–D16, the messages between the bridge and the device, the
  diagnostics for testers.
- [`motion-hold-restart-design.md`](motion-hold-restart-design.md)
  (contract, 1.3): the motion devices' Occupancy Hold Time across a restart
  (2026-11-07, #371): a hold resumes for the time it has left, timed on the
  controller's clock alone; the decisions R1–R12 and the corner cases
  L1–L27.

### HDMI sync boxes (2.0)

- [`hdmi-sync-design.md`](hdmi-sync-design.md) (contract, proposed, for the
  owner's review): the 2.0 design: the Hue Sync Box driver as a Control4
  HDMI switch, entertainment areas owned by the box, lights while their
  lamps stream, pairing and identity, testing and the release train, and
  the owner's questions (#514).
- [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md) (contract, proposed):
  the box driver's `driver.xml`, the box's API as used and the state model,
  the Lua modules, AV routing, the bridge ↔ box messages, the bridge's and
  the light devices' changes, tests, build and release.

### Code health and security

- [`driver-locals-design.md`](driver-locals-design.md) (contract, current
  rule): the bridge driver's local-variable budget (#373): Lua 5.1 compiles
  at most 200 locals in a function, so whole groups moved into `bridge/`
  modules, and the `lua-limits` check fails above 180 locals or 50
  upvalues.
- [`lifecycle-refactor-design.md`](lifecycle-refactor-design.md)
  (contract): one lifecycle base for the bridge's lights, scenes and zone
  lights (`bridge/owner.lua`, #56) and one keypad machine for the device
  drivers (`common/device.lua`, #57), with no owner-visible change.
- [`review-leftovers-design.md`](review-leftovers-design.md) (contract):
  the fixes for the open findings of the reviews of 2026-10-22 and
  2026-10-24 (#43–#65).
- [`security-fixes-2026-11-design.md`](security-fixes-2026-11-design.md)
  (contract): the fixes for the security review of 2026-11-13 (#481 to
  #493): one number and date helper, trust between drivers, rid checks,
  parser and transfer limits, discovery, provenance, the install server,
  and Debug Mode turning itself off.
- [`security-fixes-design.md`](security-fixes-design.md) (contract): the
  fixes for the security review of 2026-10-25 (#217): the gate on keyed
  requests, the TLS verdict, the limit on open stream transfers, cleaned
  names, the development handlers, the two-job Release workflow and its
  pinned inputs.

### Release, CI and documentation

- [`cicd-gitops-design.md`](cicd-gitops-design.md) (contract, current
  runbook): CI/CD and GitOps (2026-10-25, #204): `tools/check.sh` for the
  development machine and CI, the four required jobs, the code scanning
  issue, attested releases cut by the two-job Release workflow from pinned
  inputs, `deploy/house.yaml` as the desired state, the GitHub Deployment as
  the observed state, the drift issue, `tools/deploy.py`, and what is
  automatic, offered or never without a click.
- [`changelog-design.md`](changelog-design.md) (contract, current runbook):
  `CHANGELOG.md`'s format, `tools/changelog.py` (check, the release notes,
  the Documentation tab's Changelog chapter, the stamp), the codename files,
  and where each release's entry appears (2026-10-25, #255).
- [`prerelease-design.md`](prerelease-design.md) (contract, current
  runbook): prereleases for testers (2026-10-26, #269): versions
  `X.Y-beta.N` with tags that never move, built from `main` like every
  release, their notes, the one list of packages, the house on a
  prerelease, and the Beta feedback form.
- [`documentation-plan.md`](documentation-plan.md) (contract): the
  Documentation tab in every driver, the manual's chapter plan, what
  Composer's tab can render, and the Composer icons.
- [`doc-accuracy-design.md`](doc-accuracy-design.md) (contract, record):
  the documentation accuracy pass of 2026-10-25 (#231): every document a
  reader sees, checked against the drivers at build 316.
- [`doc-coherence-design.md`](doc-coherence-design.md) (contract): the
  coherence review of 2026-11-13 (#478): the facts every document agrees
  with, the readers and tiers, and who edits which file.

## Research

Read-only research written before designing, dated; what was built from it
is in the contracts above and in `status.md`.

### Lifecycle edge cases

Each holds a decision per case: automatic, only offered, or never without a
click. "Today" in them is the day they were written.

- [`edge-cases-hue.md`](edge-cases-hue.md) (record, 2026-10-21): what the
  bridge does when the house changes (a bulb added, moved, replaced,
  renamed; a room or scene edited; the bridge replaced or restored) and
  what the driver can see of it.
- [`edge-cases-control4.md`](edge-cases-control4.md) (record, 2026-10-21):
  what Director and Composer do to the devices behind the driver's back and
  what the driver can know.
- [`edge-cases-ux.md`](edge-cases-ux.md) (record, 2026-10-21): the
  owner-facing policy that came out of the two: what is automatic, what is
  offered, what is forbidden.
- [`edge-cases-motion.md`](edge-cases-motion.md) (record, 2026-10-26,
  #268): sensors and MotionAware areas on both sides.
- [`edge-cases-automations.md`](edge-cases-automations.md) (record,
  2026-10-26, #280): a Hue automation audit on both sides: detection
  automatic and read-only, remedies only on a click and reversible.

### Control4, Hue and the house

- [`motion-control4-research.md`](motion-control4-research.md) (record,
  2026-10-26, #268): how Control4 models a motion sensor (proxy,
  connections, programming, temperature, history).
- [`motion-hue-research.md`](motion-hue-research.md) (record, 2026-10-26,
  #268): the Hue motion sensor and MotionAware resources and events, the
  fixtures and the diagnostics plan.
- [`hue-automations-research.md`](hue-automations-research.md) (record,
  2026-10-26, #280): Hue's automations in CLIP v2, what a client can read
  and switch off, MotionAware's own automation and the v1 blind spot.
- [`smart-scenes-research.md`](smart-scenes-research.md) (record,
  2026-10-23 to 25): the time-of-day scene research, the owner's answers,
  the checks made on the house bridge (§7) and the plan of the remaining
  hardware checks (§8, #40).
- [`scene-tracking-research.md`](scene-tracking-research.md) (record,
  2026-11-12, #469): why every scene tile of a room mirrored the room's
  level, what a scene's tile, slider and keypad should follow, and
  Control4's scene tracking.
- [`scene-rooms-research.md`](scene-rooms-research.md) (record,
  2026-11-12, #469): keeping each scene device in the Control4 room its Hue
  room or zone maps to, case by case on both sides.
- [`tap-stop-research-c4.md`](tap-stop-research-c4.md) (record,
  2026-11-08, #421): the Control4 side of tap to ramp and tap to stop: how
  taps and double taps arrive, click rates, stops, and a stock Control4
  dimmer.
- [`tap-stop-research-hue.md`](tap-stop-research-hue.md) (record,
  2026-11-08, #421): the Hue side: how a lamp, a zone or a room ramp can be
  stopped, what the bridge reports, groups and queues, and the measurement
  plan.
- [`tls-probe-bindings-research.md`](tls-probe-bindings-research.md)
  (record, 2026-11-08, #329): the bindings the network connection's TLS
  check leaves in Director, the one documented call that can delete them,
  and the checks for the house.
- [`icons-research.md`](icons-research.md) (record, 2026-10-25, #60): why
  a light or scene device shows Control4's own light picture in a room's
  List View and the drivers' icon only in the project tree.
- [`licensing-research.md`](licensing-research.md) (record, 2026-10-24):
  before going public: what was in the repository and under whose terms,
  Snap One's and Signify's terms, the privacy findings, the license
  recommendation (Apache 2.0) and the publication checklist.

### HDMI sync boxes and entertainment areas (2.0, #514)

The research for 2.0, written on 2026-11-13 before its design.

- [`syncbox-api-research.md`](syncbox-api-research.md) (record): the sync
  devices (HSB1, HSB2, HSB3, the HSC001 camera) and their local API: TLS,
  discovery, pairing, every resource and command, polling, what the box
  does by itself.
- [`entertainment-areas-research.md`](entertainment-areas-research.md)
  (record): entertainment areas on the bridge, what happens to lamps while
  a box streams, what this driver does with them today, and the mapping to
  Control4.
- [`syncbox-control4-research.md`](syncbox-control4-research.md) (record):
  the box as a Control4 AV switch: connections, capabilities, routing and
  sequencing, programming and Navigator.
- [`edge-cases-syncbox.md`](edge-cases-syncbox.md) (record): 85 lifecycle
  cases for boxes, areas and Control4, each automatic, offered or never
  without a click.
- [`syncbox-architecture-research.md`](syncbox-architecture-research.md)
  (record): a fifth driver, networking and TLS on the controller, security,
  codebase integration, testing and the 2.x release train.
- [`syncbox-comparables-research.md`](syncbox-comparables-research.md)
  (record): other Control4 drivers for the box, other ecosystems, Hue's own
  Sync app, and the lessons.

### The research for 1.2's actions (#334)

All records of 2026-11-04 and 05, behind `simplify-actions-design.md`:

- [`simplify-research-import.md`](simplify-research-import.md): the
  actions for lights, zone lights, scenes, names and rooms, and the list
  rows.
- [`simplify-research-maintenance.md`](simplify-research-maintenance.md):
  the pairing, connection, credentials, pinning, refresh and motion
  actions, and the connection rows.
- [`simplify-research-composer.md`](simplify-research-composer.md): what
  Composer Pro and DriverWorks allow a simpler driver, on OS 3.x and 4.x.
- [`simplify-research-journeys.md`](simplify-research-journeys.md): the
  dealer's, the owner's and the tester's journeys, today's clicks and the
  ideal flow.
- [`simplify-research-compat.md`](simplify-research-compat.md): what
  depends on each of the 39 actions, and an upgrade that loses nothing.
- [`simplify-research-scheduler.md`](simplify-research-scheduler.md): one
  engine for the bridge's background tasks (built as
  `bridge/housekeeping.lua`).
- [`simplify-research-comparables.md`](simplify-research-comparables.md):
  how comparable products keep setup and upkeep simple.
- [`simplify-research-names-sync.md`](simplify-research-names-sync.md): for
  the owner's answer D5: two-way names for lights, scenes and motion
  sensors, the edge cases, pacing and the texts.
- [`simplify-research-discovery.md`](simplify-research-discovery.md): for
  the owner's answer D6: finding the bridge on the local network only
  (mDNS, a bounded subnet probe, the Bridges Found row and the address
  follow-up).

## Reviews

Dated records of the code as it was when each was written; what was fixed
is in the contracts, the issues and `status.md`.

- [`code-analysis-2026-10-22.md`](code-analysis-2026-10-22.md): the summary
  of four read-only analyses of the release code (security, leaks, races)
  and what was fixed; the four reports are
  [`reviews/analysis-1-networking.md`](reviews/analysis-1-networking.md),
  [`reviews/analysis-2-lights-registry.md`](reviews/analysis-2-lights-registry.md),
  [`reviews/analysis-3-scenes-model.md`](reviews/analysis-3-scenes-model.md)
  and [`reviews/analysis-4-devices-common.md`](reviews/analysis-4-devices-common.md).
- [`reviews/slim-2026-10-24-brief.md`](reviews/slim-2026-10-24-brief.md):
  the brief of the slimming review before the first release (fewer lines,
  less memory and CPU on the controller, no regressions), and its five area
  reports: [`reviews/slim-bridge-driver.md`](reviews/slim-bridge-driver.md),
  [`reviews/slim-device-drivers.md`](reviews/slim-device-drivers.md),
  [`reviews/slim-lights.md`](reviews/slim-lights.md),
  [`reviews/slim-runtime.md`](reviews/slim-runtime.md) and
  [`reviews/slim-scenes-zones.md`](reviews/slim-scenes-zones.md).
- [`reviews/security-2026-10-24.md`](reviews/security-2026-10-24.md): the
  read-only security review of the slimmed release code and
  `tools/build.sh` on `release-prep` before 1.0, checked item by item
  against the 2026-10-22 analyses.
- [`reviews/diff-review-2026-10-24.md`](reviews/diff-review-2026-10-24.md):
  the read-only review of the slimming's diff hunk by hunk against the
  brief's rule that no owner-visible behaviour changes.
- [`reviews/efficiency-2026-10-24.md`](reviews/efficiency-2026-10-24.md):
  the efficiency review after the slimming: the five paths
  `slim-runtime.md` costed, re-costed on `release-prep`.
- [`reviews/manual-bridge-2026-10-24.md`](reviews/manual-bridge-2026-10-24.md):
  the release review of the owner's manual (the Hue Bridge Documentation
  tab) against the code, with the corrections applied before 1.0.
- [`reviews/manual-devices-readme-2026-10-24.md`](reviews/manual-devices-readme-2026-10-24.md):
  the release review of the Hue Light and Hue Scene device pages, the
  README set and the manual's install chapters against the code, with the
  corrections applied before 1.0.
- [`reviews/security-2026-10-25.md`](reviews/security-2026-10-25.md): the
  read-only security review of the review leftovers and the lifecycle
  refactor (PRs #214 and #216, build 292) and of the tooling: fourteen
  findings, fixed under `security-fixes-design.md` (#217).
- [`reviews/diff-review-2026-10-25.md`](reviews/diff-review-2026-10-25.md):
  the read-only diff and efficiency review of the same branch against the
  refactor's rule that no owner-visible behaviour changes.
- [`reviews/coherence-2026-11-13.md`](reviews/coherence-2026-11-13.md):
  record. The documentation coherence review (#478): the contradictions,
  stale statements and organisation fixed across the manuals, the front
  page and `docs/`, and its follow-ups.
- [`reviews/doc-accuracy-review-2026-10-25.md`](reviews/doc-accuracy-review-2026-10-25.md):
  the documentation accuracy pass (#231) at build 316, finding by finding,
  with the corrections applied under `doc-accuracy-design.md`.

## History

Plans and checklists whose work is done; kept as the record.

- [`spike-checklist.md`](spike-checklist.md) (record, 2026-10-19 to 21): the
  first pairing and event-stream spike's checklist.
- [`screenshots-plan.md`](screenshots-plan.md) (record, #61): how the
  manual's pictures were retaken in the house project: crops that never
  show the title or status bar, house texts painted over with a neutral
  example set, and the plan as JSON for `tools/composer/Shots.ps1`. The
  pictures were retaken for 1.0 (#251).
- [`house-checks-plan.md`](house-checks-plan.md) (record, 2026-11-09): one
  house round around the 1.5 install and its reboot for #238, #65, #431
  and #40: what was checked, by which tool or person. The round ran on
  2026-11-10 (`status.md`, 1.5).
