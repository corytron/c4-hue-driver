# The docs folder

What each file here is for. One rule runs through all of them: `status.md` is
the single page of the present; every other note keeps its history as
written, with dated "Superseded" lines where behaviour changed later, and
where a note and `status.md` disagree about the present, `status.md` and the
code win. The owner's manual itself is not here but in the driver:
`src/hue_bridge/www/documentation.html` (the Documentation tab in Composer).

## Start here

- [`status.md`](status.md): what runs on the author's house, what the three
  drivers do today, what was verified on hardware, and what is open.
- [`design.md`](design.md): the engineering notebook. Targets (OS versions,
  Lua 5.1), the three-driver structure, networking and the certificate
  bundle, the event stream and the measured `C4:url` transfer scheduling on
  OS 3.4.2, the stream address rotation, lights, keypads, the hardware
  verification rounds, discovery, commands and rate limiting, colour mapping
  and storage. Dated sections; each API claim is marked verified or assumed.
- [`release-checklist.md`](release-checklist.md): what a build must pass on
  this VM, on the dev loop, in Composer and on the owner's phone and keypads
  before it is called good, and the naming of the 1.0 release.

## Feature contracts

Written before the code of each feature, against the research below, and
built by parallel agents. They are the specification; `status.md` says what
of it is live.

- [`import-design.md`](import-design.md): the lifecycle contract for lights,
  rooms and scenes: Add Light and Import All New Lights, the Hue room to
  Control4 room mapping, renames (Attention, Adopt Hue Names, Accept Names As
  They Are), replacements and deletions on either side (Re-link, Forget,
  tombstones), Link Devices.
- [`lights-design.md`](lights-design.md): representing Hue lights as
  `light_v2` devices: state, commands, the message protocol between the
  bridge and the light driver, the command queue and coalescing.
- [`scenes-design.md`](scenes-design.md): one Hue Scene device per Hue
  scene, created only by the owner; the on rule and the room or zone OFF.
- [`scene-dimmer-design.md`](scene-dimmer-design.md): the Hue Scene as a
  dimmer whose level is the room or zone's brightness, kept in sync with Hue.
- [`smart-scenes-design.md`](smart-scenes-design.md): Hue's time-of-day
  ("smart") scenes as Hue Scene devices: start, stop, dim while running,
  listing and naming.
- [`zone-light-design.md`](zone-light-design.md): a Hue zone or room as one
  Hue Light device (zone light, room light): Add Zone Light, the tile's
  state, the grouped command pace, capabilities, renames and deletions.
- [`keypad-design.md`](keypad-design.md): Button Links on Hue Light and Hue
  Scene devices: taps, hold-to-dim through Hue's relative dimming, keypad
  LEDs, decoupled Control4 switches.
- [`documentation-plan.md`](documentation-plan.md): the Documentation tab in
  every driver, the manual's chapter plan and the Composer icons.
- [`raw-stream-design.md`](raw-stream-design.md): historical, never built: the
  event stream on a raw SSL network connection instead of `C4:url`. Kept as
  the documented alternative to the padded-address design in `design.md`.

## Research and edge cases

Read-only research written before designing, with a decision per lifecycle
case: automatic, only offered, or never without a click. Historical
(2026-10-21): "today" in them is that day's code; the decisions are in the
contracts above.

- [`edge-cases-hue.md`](edge-cases-hue.md): what the bridge does when the
  house changes (a bulb added, moved, replaced, renamed; a room or scene
  edited; the bridge replaced or restored) and what the driver can see of it.
- [`edge-cases-control4.md`](edge-cases-control4.md): what Director and
  Composer do to the devices behind the driver's back (renames, moves,
  deletions, project restores, binding changes) and what the driver can know.
- [`edge-cases-ux.md`](edge-cases-ux.md): the owner-facing policy that came
  out of the two: what is automatic, what is offered, what is forbidden.
- [`smart-scenes-research.md`](smart-scenes-research.md): the time-of-day
  scene research, the owner's answers and the checks made on the house
  bridge.
- [`licensing-research.md`](licensing-research.md): what is in the
  repository and under whose terms, Snap One's and Signify's terms, the
  privacy findings before going public, the license recommendation (Apache
  2.0) and the publication checklist.

## Checklists and process

- [`composer-checklist.md`](composer-checklist.md): the steps only Composer,
  a Navigator, a keypad or the Hue app can show, as the owner runs them, with
  a "Done" line per step.
- [`spike-checklist.md`](spike-checklist.md): historical: the first pairing
  and event-stream spike's checklist.
- [`dev-loop.md`](dev-loop.md): the development loop: a `--dev` build of the
  bridge fetches its Lua from `tools/devserver.py`, reloads itself, runs
  actions queued with `tools/devctl.py` and ships its log back.
- [`composer-remote.md`](composer-remote.md): driving Composer Pro from here
  through a Claude Code session on the Windows machine (UI Automation from
  PowerShell, `tools/composer/Composer.psm1`), and the test rounds run that
  way.

## Reviews

- [`code-analysis-2026-10-22.md`](code-analysis-2026-10-22.md): the summary of
  four read-only analyses of the release code (security, leaks, races) and
  what was fixed; the four reports are
  [`reviews/analysis-1-networking.md`](reviews/analysis-1-networking.md),
  [`reviews/analysis-2-lights-registry.md`](reviews/analysis-2-lights-registry.md),
  [`reviews/analysis-3-scenes-model.md`](reviews/analysis-3-scenes-model.md)
  and [`reviews/analysis-4-devices-common.md`](reviews/analysis-4-devices-common.md).
- [`reviews/slim-2026-10-24-brief.md`](reviews/slim-2026-10-24-brief.md): the
  brief of the slimming review before the first release (fewer lines, less
  memory and CPU on the controller, no regressions), and its five area
  reports: [`reviews/slim-bridge-driver.md`](reviews/slim-bridge-driver.md),
  [`reviews/slim-device-drivers.md`](reviews/slim-device-drivers.md),
  [`reviews/slim-lights.md`](reviews/slim-lights.md),
  [`reviews/slim-runtime.md`](reviews/slim-runtime.md) and
  [`reviews/slim-scenes-zones.md`](reviews/slim-scenes-zones.md).
