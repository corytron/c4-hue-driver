# Documentation coherence review, 2026-11-13 (#478)

The record of the review under [`doc-coherence-design.md`](../doc-coherence-design.md).
Six agents reviewed and fixed their own files, and the coordinator fixed what
crossed files. This is what they found, grouped by kind, worst first.

## Logical errors a reader met

- **Counts that contradicted each other.**
  - The README said "Three `.c4z` drivers", then listed four.
  - "Nine actions" appeared in the README, the release checklist and a
    `driver.xml` comment; there are ten since 1.5.
  - "Install all three", "stamps all three" and "the three new files" in
    the runbooks, CONTRIBUTING, the PR template and NOTICE.
  - The changelog's 1.1 entry offered "the three drivers" in the release
    that added the fourth.
  - `simplify-actions-design.md` gave 32, 29 and 39 actions without saying
    what each counted.
  - `status.md` said "39 become 9".
- **Stale beta-era text that later passages contradicted.**
  - The bridge manual's chapter 14 opened "A beta, written before the
    hardware" while 14.13 reported a MotionAware area watched on the house.
  - The motion tab said the developer's house had no sensor.
  - The issue templates sent readers to a Test Connection action that 1.2
    removed.
  - The motion diagnostics told owners to use the Beta feedback issue
    after motion was released (the driver's own texts, fixed too).
- **Stale "now".**
  - `status.md` led with history: a "What runs on the house" of beta 4,
    and an "Open" list that was mostly closed issues. Its "current
    behaviour" section described build 316.
  - `dev-loop.md` said a dev build was running.
  - `composer-remote.md` stopped at round 43.
  - The lighting checklist never recorded 1.4's tap stop: L44 still read
    Gap.
  - `docs/README.md` called the raw stream "never built"; it has been the
    default since 1.1.
- **Behaviour descriptions from before 1.6.**
  - Scene tiles showing the room's level, and the old keypad defaults
    (250 ms click rate).
  - Colour on mode "Preset (the default)": Composer applies its own
    default.
- **Wrong references.**
  - Departure D17 was cited for load groups (it is D18).
  - Bare decision numbers in the lighting checklist read as departures.
  - Citations pointed at a `status.md` section that no longer existed.
  - A case table was announced as "the five rows below" over twelve rows.
  - A fixture file name was wrong in `simplify-research-compat.md`.
- **One thing under two names.** The bridge manual used "zone or room light"
  and "room light" in its prose. It now uses "zone light", defined once.
  The Light tab keeps "room light" only where the device's own texts
  distinguish a room from a zone.
- **Compatibility claimed beyond what was tried.** "Runs on OS 4.x" is now
  "meant for OS 3.x and 4.x; run on OS 3.4; OS 4 not tried". The Bridge v2
  is recorded as run by an outside tester (#309).

## Organisation

- **README.** One story: what it does, status and compatibility, download
  and verify, install, use, documentation, help and security,
  contributing, license.
- **Bridge manual.** The contents are grouped (Getting started, the Hue
  Bridge device, Lights and scenes, Help and reference, Motion and Hue
  automations), with one action table instead of two. About 70
  version-history notes were moved out, with the upgrade notes that owners
  need kept. Chapter numbers and anchors are unchanged.
- **Light, Scene and Motion tabs.** One shared shape (about, setup,
  everyday use, keypads, properties, programming, troubleshooting), each
  with a contents list.
- **`docs/README.md`.** Every file is linked once, grouped by area, and each
  is labelled current, contract or record.
- **`status.md`.** Now, What runs on the house, Not yet checked on the
  house, What the drivers do, How builds reach the house, then History.
- **Records** (contracts, research, reviews). History kept as written, slips
  fixed, and about 40 dated "Current (2026-11-13, #478)" notes added.

## Removed

Fifteen screenshots that no page showed any more (the actions dialogs of
1.0 and the pictures 1.2 made obsolete). They shipped in every package; the
Hue Bridge package drops from 821 KB to 654 KB.

## Follow-ups

- Retake the properties screenshots. They are from build 329, without
  Load Groups or Keypad Follows, and the captions say so.
- A whole-home scene's Status reads `in (no room)`, while the bridge's
  lists say `(whole home)` since 1.6 (`src/hue_scene/driver.lua`).
