# Simplifying the drivers: fewer actions, background tasks instead of clicks (#334)

Status: research phase, opened 2026-11-04 on the owner's request. Nothing in
`src/` changes until the proposal that comes out of this research is accepted.

## 0. Contract of the research phase

### 0.1 Goal

The Hue Bridge driver shows **32 actions** in Composer, the Hue Light 2, the
Hue Motion 3 and the Hue Scene 2. The owner wants the drivers as simple to
use as an Apple product: few visible actions, sensible defaults, the driver
looking after itself, and the installer clicking only where a choice is
really theirs. Some actions should disappear in favour of periodic or
event-driven background tasks inside the driver; others should be merged or
become a setting.

**Hard limit:** no feature designed or built up to beta 8 may be lost. Beta 8
is the next prerelease, `main` today equals beta 7 (build 425) plus nothing;
the feature list is in `CHANGELOG.md` (`## Unreleased`), `docs/status.md` and
the manuals in `src/*/www/documentation.html`. "Simpler" may change how a
feature is reached, never whether it exists.

### 0.2 Principles to test every proposal against

1. **Control4 is the source of truth** (owner, 2026-10-26, #280). Hue changes
   may be offered to Control4; nothing in Hue is silently imposed on a
   Control4 project, and nothing automatic may overwrite a name, room or
   link the installer set by hand.
2. **Edge cases before automation** (CLAUDE.md). Anything that acts on its own
   over the life of the system (importing, syncing names or rooms, creating or
   removing devices) needs its lifecycle corner cases enumerated on both
   sides (things added, moved, renamed, replaced, removed, restored from a
   backup), and a decision per case: **automatic**, **offered** (the driver
   proposes, one click accepts) or **forbidden without a click**. Automation
   that makes a later manual fix harder is wrong.
3. **Visible and stoppable.** Every background task says what it did in
   Status, Attention or Last Action, and can be switched off by one setting.
4. **Cheap.** Director allows four `C4:url` transfers at once, controller-wide
   across all drivers; Hue limits requests per second; the house controller
   runs OS 3.4.2 and must stay responsive. A task that costs requests names
   its budget.
5. **Nothing regresses.** The driver still works on OS 3.x and 4.x, with the
   Hue Bridge v2 and the Bridge Pro, offline-first, and every existing device,
   pairing and Composer project survives the update in place.

### 0.3 Inventory (generated from `src/*/driver.xml`, 2026-11-04)

Hue Bridge, 32 actions (the command string equals the name):

| Family | Actions |
| --- | --- |
| Pairing and connection | Pair Bridge, Test Connection, Connection Test, Connect Event Stream, Disconnect Event Stream, Reload Credentials, Check CA Pinning, Forget Pairing |
| Lights | Add Light, Import All New Lights, Add Zone Light, Re-link Device To Light, Re-link Zone Light, Link Devices, Forget Light |
| Names and rooms | Adopt Hue Names, Accept Names As They Are, Set Room Mapping, Map Rooms By Name, Room Audit |
| Scenes | Add Scene, Add All Scenes Of Room, Re-link Scene, Forget Scene, Refresh Scenes |
| Refresh | Refresh All |
| Motion | Add Motion Sensor, Import All New Motion Sensors, Add Motion Area, Re-link Motion Device, Forget Motion Device, Log Motion Diagnostics |

Children: Hue Light (Adopt Hue Name, Forget This Light), Hue Scene (Adopt Hue
Name, Forget This Scene), Hue Motion (Refresh From Bridge, Test: Motion,
Test: No Motion).

Bridge properties (29): Driver Version, Debug Mode, Status, Bridge IP
Address, Bridge ID, Bridge Model, Bridge Name, Bridge Firmware, Event Stream,
Lights, Attention, Last Action and Last Action (2) to (6), Room Mappings,
Scenes, Zone Lights, Motion Sensors, Stream Address, Events Received, Last
Event, Diagnostic Server, Dev Server, Stream Timeout (s), Event Stream
Transport, Stream Watchdog (s). Properties count as part of "simple" too: a
proposal may fold or hide properties, but the four lists (Lights, Scenes,
Zone Lights, Motion Sensors) and Room Mappings carry their own selection
actions and are in scope.

### 0.4 Decision vocabulary

Every research file ends each action it covers with exactly one of these
verdicts, plus one sentence of reason:

- **KEEP**: stays as it is.
- **MERGE into X**: one action does what several did (say how it decides).
- **SETTING**: becomes a property (say which, default, and what it does).
- **AUTOMATIC**: a background task does it (say the trigger: event, timer with
  cadence, startup, bridge reconnect; the guards; what Status shows).
- **OFFERED**: the driver notices and proposes (Attention text, a list row), a
  click accepts. Say how the click is reached with fewer actions.
- **MOVE to diagnostics**: stays for support but leaves the everyday list
  (say where it goes: one Diagnostics action, a Debug Mode level, or the
  dev loop).
- **RETIRE**: no longer needed (say what replaced the need, with evidence).

### 0.5 Research agents and the files they own

All research agents are read-only except for their one file. Others edit the
rest of the checkout at the same time. Nobody runs `git`.

| Agent | File it writes | Question |
| --- | --- | --- |
| import | `docs/simplify-research-import.md` | Lights, zone lights, scenes, names and rooms: what becomes automatic, offered or merged; the full lifecycle edge-case table |
| maintenance | `docs/simplify-research-maintenance.md` | Pairing, connection, credentials, pinning, refresh and motion: what the driver can do for itself; self-healing and its limits |
| composer | `docs/simplify-research-composer.md` | What Composer and DriverWorks can and cannot do (grouping, hiding, dynamic actions, list-as-trigger, device creation, discovery, setup pages), OS 3.x and 4.x |
| journeys | `docs/simplify-research-journeys.md` | The installer's and owner's end-to-end flows, clicks counted today, and the ideal Apple-like flow for each |
| compat | `docs/simplify-research-compat.md` | Traceability: what depends on each action (code, specs, manuals, tools, briefs, projects) and the upgrade path that loses nothing |
| scheduler | `docs/simplify-research-scheduler.md` | One background-task engine for the driver: tasks, cadence, jitter, backoff, budgets, persistence, observability, tests |
| comparables | `docs/simplify-research-comparables.md` | How other integrations (Control4's own Hue support, community drivers, Apple Home, the Hue app) keep setup simple |

### 0.6 What each file must contain

1. **Findings** (the answer first, five to ten bullet points).
2. **Evidence**: for every API or behaviour claim a citation, as
   `path:line` for this repository, the SDK doc file under
   `~/c4-tools/reference/` for DriverWorks, or a URL for the web, and each
   claim marked **verified** (seen in code, docs, a spec or a hardware
   report) or **assumed**. Do not invent DriverWorks API calls.
3. **Verdicts** in the vocabulary of 0.4 for every action in scope.
4. **Risks and open questions for the owner**, each with a recommended
   answer, so a decision costs one word.
5. Keep it to about 400 lines. No long quotations, no copied passages from
   the Snap One documentation or Signify's login-walled pages; at most one
   short quote (under 15 words) per source.

### 0.7 Rules for agents

- The repository is public: no LAN addresses, keys, bridge ids or project
  names. Placeholders only: `10.0.2.143` bridge, `192.0.2.7` VM,
  `001788fffe123abc` bridge id; in examples any `192.0.2.x`, `198.51.100.x`.
- Lua is 5.1; tabs; the driver is `src/hue_bridge/driver.lua` with modules in
  `src/hue_bridge/bridge/`. Read before you claim: the dispatch tables in
  `driver.lua`, `driver.xml`, the modules and `tests/spec/`.
- `gh issue list|view` and `gh api` GET calls are allowed (read-only); no
  `git`, no writes to GitHub, no edits outside your one file, no `tools/`
  runs that write to `build/`.
- Hardware facts that matter: the house controller runs OS 3.4.2; the house
  bridge is a Hue Bridge Pro; Director allows four `C4:url` transfers at once
  (the event stream uses a network connection instead since #317); the
  outside tester (Marc) owns motion sensors and a Hue Bridge v2.
- Finish with a hand-back of at most 15 lines: your five strongest
  recommendations and the one decision you most need from the owner.

### 0.8 Documents to read first

`docs/status.md`, `docs/design.md`, `docs/import-design.md`,
`docs/lights-design.md`, `docs/scenes-design.md`, `docs/zone-light-design.md`,
`docs/motion-design.md`, `docs/list-rows-design.md`,
`docs/lifecycle-refactor-design.md`, `docs/keypad-design.md`,
`docs/edge-cases-control4.md`, `docs/edge-cases-hue.md`,
`docs/edge-cases-ux.md`, `docs/edge-cases-motion.md`, `docs/dev-loop.md`,
`docs/composer-remote.md`, `docs/composer-checklist.md`, the manuals in
`src/*/www/documentation.html`, `CHANGELOG.md`, and issues #280, #305, #309,
#324 and #325.

## 1. Findings and proposal

To be written by the coordinator once the seven files exist.
