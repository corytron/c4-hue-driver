# Documentation coherence review (issue #478)

The contract for one pass over every document a reader of this project sees.
It covers the four drivers' Documentation tabs, the GitHub front page and
its policies, and `docs/`. The pass looks for logical errors as a reader
meets them (the owner's example: the README says three drivers and then
lists four), contradictions between documents, stale "now" statements, and
organisation that makes a document hard to follow.

It builds on the accuracy pass of #231 ([`doc-accuracy-design.md`](doc-accuracy-design.md)):
the code is the source of truth, and quoted texts are copied from it.

Branch `docs/coherence-478`. Agents edit disjoint files at the same time.
The coordinator integrates, runs `tools/check.sh` and `tools/build.sh`, and
commits.

## 1. The owner's words (2026-11-13)

"take a look at all documentation, both in the driver, and on github, and
look for logical errors as it reads. Like saying we have 3 drivers, then
pointing out later we have four. lets do a full review and try to make it
more coherent, cogent, and readably organized."

## 2. Facts every document agrees with

Checked by the coordinator on `main` at 98f9df9 (build 624). An agent that
finds the code saying otherwise reports it and does not change the fact
here.

| Fact | Value | Source |
|---|---|---|
| Drivers | **Four** `.c4z` drivers: **Hue Bridge** (`hue_bridge.c4z`), **Hue Light** (`hue_light.c4z`), **Hue Scene** (`hue_scene.c4z`), **Hue Motion Sensor** (`hue_motion.c4z`). Install all four from the same release. | `src/*/driver.xml` `<name>`; `tools/build.sh` |
| What each is | The Hue Bridge pairs with one Hue bridge, imports and creates the other devices, and talks to Hue. The Hue Light is one Hue light, or a whole Hue room or zone as one light (a zone light). The Hue Scene is one Hue scene, ordinary or time-of-day. The Hue Motion Sensor is a Hue motion sensor, or a MotionAware area (Bridge Pro only). | the manuals; `docs/zone-light-design.md`, `docs/smart-scenes-design.md`, `docs/motion-design.md` |
| Proxies | Light and Scene: `light_v2` (dimmers). Motion: Control4's stock motion sensor. Bridge: its own device. | `driver.xml` |
| Hue | CLIP API v2 only, HTTPS, `hue-application-key`. Hue Bridge (v2, square) and Hue Bridge Pro: the house runs a Bridge Pro, and an outside tester ran a Bridge v2 (BSB002) on the 1.1 betas. One bridge per Hue Bridge driver; several bridges are not supported yet. | `CLAUDE.md` Targets and Scope; #309 |
| Control4 | Minimum OS 3.3.0 (every `driver.xml`). Meant for OS 3.x and 4.x; run on OS 3.4 only (the house, and an outside tester on OS 3.4.3); OS 4 not tried. | `driver.xml` `<minimum_os_version>`; `docs/status.md`; #309 |
| Bridge actions | **Ten**: Pair Bridge, Import All New, Add From Hue, Link Device, Forget Device, Resolve Names, Set Room Mapping, Hue Automations, Diagnostics, Forget Pairing. 1.2 cut 29 actions to 9, and 1.5 added the tenth (Hue Automations). | `src/hue_bridge/driver.xml` `<actions>` |
| Latest release | **1.6 "Kassa", build 624** (2026-11-13). The codename is named in titles. Each release's notes open with what its name means. How names are picked is never written in public text. | `CHANGELOG.md`; `.github/codenames.json` |
| Scene device | The tile follows its own scene. **Keypad Follows** (since 1.6, formerly On State Follows) decides what a bound keypad treats as on. | `docs/scene-tracking-design.md` |
| Rooms | A Hue room or zone maps to one Control4 room (Set Room Mapping, or by name). Scenes go only into their mapped room (1.6). Lights, zone lights and motion may be added to any room picked. Nothing moves a device by itself. | `docs/scene-tracking-design.md` Part 2; `docs/simplify-actions-design.md` |
| Not affiliated | Not affiliated with, endorsed or supported by Snap One (Control4) or Signify (Philips Hue). The trademark lines of NOTICE and the manuals stay. | `NOTICE` |
| License | Apache License 2.0, public since 2026-10-24. | `LICENSE`, `CLAUDE.md` |

## 3. Readers and tiers

| Tier | Documents | Reader | What the pass does |
|---|---|---|---|
| **1. Product** | The four Documentation tabs (`src/*/www/documentation.html`) | Owners and dealers in Composer | Full coherence review. Make each tab read in order: what the driver is, install, first steps, everyday use, settings (properties), actions, troubleshooting, reference. Remove repetition and contradictions, and make terms consistent. Keep every anchor another file links to, or update the link in the same file. Follow `docs/documentation-plan.md` §4 (Composer's tab is an Internet Explorer control). |
| **1. Front page** | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE`, `.github/release-notes.md`, `.github/prerelease-notes.md`, `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md`, `CHANGELOG.md` (intro and the Unreleased entry only; released entries are history and stay as written, except for a factual slip such as a wrong issue number) | Visitors to GitHub | Full coherence review: one story from "what is this" to download, install, use, help, and contributing. |
| **2. Project state** | `docs/README.md` (the index), `docs/status.md`, `docs/design.md` | Contributors, the owner | Make the index match the files and group them so a reader finds things. Make `status.md` say clearly what is true now, with history below it and stale "current behaviour" sections brought up to date or marked as history. Make `design.md`'s overview match the four drivers and point to the contracts. |
| **2. Runbooks** | `docs/release-checklist.md`, `docs/dev-loop.md`, `docs/composer-remote.md`, `docs/composer-checklist.md`, `docs/changelog-design.md`, `docs/cicd-gitops-design.md`, `docs/prerelease-design.md` | The coordinator, the Windows session | Check that the steps agree with the tools as they are (`tools/*.py`, `tools/*.sh`, the workflows), and fix contradictions and stale steps. |
| **3. Records** | Every other file in `docs/`: the `*-design.md` contracts, `*-research.md`, `edge-cases-*.md`, `reviews/`, plans and analyses | Anyone tracing a decision | **History stays as written.** Fix only internal contradictions and factual slips (a wrong count, a wrong file name, a broken reference). Where a "now", "today" or "current" statement is no longer true, add one dated line in the file's own style ("Current (2026-11-13, #478): …") rather than rewriting it. Do not reorganise. |

Not reviewed: `CLAUDE.md` (the coordinator's), `CODE_OF_CONDUCT.md`
(standard text), `LICENSE`, the workflows' code, and past GitHub release
notes (they were edited on 2026-11-10 for #464).

## 4. Style for tiers 1 and 2

- Plain English and short sentences. Say what to do before why.
- One name for one thing, everywhere:
  - "Hue bridge" is the hardware; "Hue Bridge driver" or "the Hue Bridge
    device" is the Control4 side;
  - "Hue room", "Hue zone" and "Control4 room" are always qualified;
  - "zone light" is a Hue Light device that drives a whole Hue room or
    zone;
  - "time-of-day scene" is the owner-facing name; "time-based" is the
    code's;
  - "the Control4 app" is the phone and tablet app; "Navigator" is used
    only where Control4's own documents do.
- Counts and lists agree with section 2. Never write a number a later
  sentence contradicts. Prefer naming the items to counting them.
- Version history belongs in `CHANGELOG.md`. A manual says how the driver
  behaves now. "Since 1.x" appears only where an owner upgrading needs it
  (a changed default, a renamed property).
- No codename rule. No LAN addresses, keys or bridge ids (placeholders
  only: 10.0.2.143 bridge, 001788fffe123abc bridge id). Never copy
  passages of the Snap One or Signify documentation; paraphrase and cite.
- Exact quoted texts (properties, actions, list items, Status, Attention,
  Last Action) are copied from the code as it is at build 624.

## 5. Writers (one per file)

| Agent | Files |
|---|---|
| **M1** (bridge manual) | `src/hue_bridge/www/documentation.html` |
| **M2** (device manuals) | `src/hue_light/www/documentation.html`, `src/hue_scene/www/documentation.html`, `src/hue_motion/www/documentation.html` |
| **F** (front page) | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE`, `CHANGELOG.md`, `.github/release-notes.md`, `.github/prerelease-notes.md`, `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md` |
| **P** (project state and runbooks) | `docs/README.md`, `docs/status.md`, `docs/design.md`, `docs/release-checklist.md`, `docs/dev-loop.md`, `docs/composer-remote.md`, `docs/composer-checklist.md`, `docs/changelog-design.md`, `docs/cicd-gitops-design.md`, `docs/prerelease-design.md` |
| **R1** (records: contracts) | every other `docs/*-design.md`, plus `docs/c4-lighting-guidelines.md` |
| **R2** (records: research and reviews) | `docs/*-research*.md`, `docs/edge-cases-*.md`, the files already in `docs/reviews/` (a security review of 2026-11-13 adds new ones on its own branch), `docs/*-plan.md`, `docs/code-analysis-*.md`, `docs/spike-checklist.md` |
| Coordinator | this file, `CLAUDE.md`, the review record, integration |

Each agent's hand-back lists its findings: what was wrong, where, and
what it did, plus anything it saw in a file it does not own. The
coordinator gathers them into `docs/reviews/coherence-2026-11-13.md` and
fixes what crosses files.

## 6. Done

- `python3 tools/check_links.py` passes, so every anchor and link works.
- `tools/check.sh` passes, and `tools/build.sh` builds (the changelog is
  rendered into every tab).
- One `CHANGELOG.md` line under Unreleased (agent F) says the
  documentation was reviewed for coherence (#478).
