# Simplifying the drivers: fewer actions, background tasks instead of clicks (#334)

Status: decided by the owner on 2026-11-05 (section 1.8); the build is 1.2.
The two-way names (D6) and local discovery (D5) get their edge-case research before code.

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
4. **Cheap.** Hue limits requests per second, and the house controller runs
   OS 3.4.2 and must stay responsive. A task that costs requests names its
   budget. **Correction of 2026-11-04 (owner):** Director's four-transfer limit
   is not a design constraint any more. It bit us only because the event
   stream held a `C4:url` transfer for good; since #317 the stream is a
   network connection (`bridge/netstream.lua`) and no `C4:url` transfer waits
   for it. Do not size or limit a proposal by that number. What is still true
   today: the REST requests (`bridge/http.lua`) still use `C4:url`, and
   Director runs one `C4:url` transfer per host at a time
   (`bridge/commands.lua`, `docs/design.md` "C4:url transfer scheduling"), so
   a burst of requests queues behind each other. The owner's view is that the
   TCP module could carry the REST calls too; a proposal may use that, saying
   what it would cost to build and what it would remove.
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
  bridge is a Hue Bridge Pro; the event stream uses a network connection since #317, so the old
  four-transfer limit no longer shapes the design (see principle 4); the
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

## 1. Findings and proposal (coordinator, 2026-11-04)

Merged from the seven research files:
[import](simplify-research-import.md), [maintenance](simplify-research-maintenance.md),
[composer](simplify-research-composer.md), [journeys](simplify-research-journeys.md),
[compat](simplify-research-compat.md), [scheduler](simplify-research-scheduler.md) and
[comparables](simplify-research-comparables.md). Where they disagreed, the
choice and its reason are in 1.6. Nothing here is built yet: the owner's
answers in 1.7 come first.

### 1.1 What the research found

- **The count.** A release build shows 29 bridge actions (32 in a dev build)
  and 7 on the three child drivers: 36 buttons, most of them the same few
  jobs repeated per kind of thing (light, zone, scene, sensor, area).
- **The platform's limits.** Composer's Actions tab is fixed by `driver.xml`:
  no hiding, grouping or renaming at runtime, no result, no wizard. Creating a
  device must follow a person's click (the SDK's AddDevice contract), and no
  API deletes a device or moves it to another room. A background task can
  therefore notice and prepare, never create or delete.
- **What the platform allows.** Merged actions with a "what" picker (proven on
  OS 3.4.2), settings instead of action pairs, timers with persisted due
  times, and the events the driver already receives. Renaming or removing an
  action is safe in an in-place update: programming never refers to actions.
- **No engine today.** Background work is ad hoc: no safety-net read behind
  the event stream, a failed resync after a connect is never retried, a
  rejected key stays locked until someone clicks, and an IP change is never
  noticed (Status keeps saying Paired).
- **Clicks per job barely drop; the number of things to learn does.** The
  gain is 36 buttons down to 10, plus jobs the driver does for itself.
- **Comparable products** merge by intent (one import, one inbox of finds),
  follow the bridge by its id when its address changes, keep the installer's
  names and rooms, and never auto-delete.
- **Compatibility.** Keep every removed command string as a hidden alias until
  2.0 (the dev loop, `tools/regress.sh` and the Windows briefs call actions by
  command), never reshape the persisted store, and add a ledger spec that
  proves every feature still has a path before any action changes.

### 1.2 The proposed actions (39 become 10)

Hue Bridge, 9 actions in release builds:

| # | Action | What it does | Replaces |
| --- | --- | --- | --- |
| 1 | **Pair Bridge** | One click; waits up to 2 minutes for the link button. Opens by itself when an address is entered on a never-paired driver. | Pair Bridge |
| 2 | **Import All New** | One click, no dialog: every new light and motion sensor into the Control4 room its Hue room maps to; skips a likely replacement of a gone device and offers the re-link instead. | Import All New Lights, Import All New Motion Sensors |
| 3 | **Add From Hue** | One picker of everything on the bridge not yet in Control4: lights, zones and rooms, scenes (with "all scenes of this room" rows), motion sensors and MotionAware areas; then a room. | Add Light, Add Zone Light, Add Scene, Add All Scenes Of Room, Add Motion Sensor, Add Motion Area |
| 4 | **Link Device** | Points a gone, unbound or unlinked device of any kind at a Hue thing, the driver's suggestion pre-chosen; a row "every device with a suggested match" does them all. | Re-link Device To Light, Re-link Zone Light, Re-link Scene, Re-link Motion Device, Link Devices |
| 5 | **Forget Device** | Releases a device of any kind from the bridge, leaving it in the project; asks for confirmation. | Forget Light, Forget Scene, Forget Motion Device, Forget This Light, Forget This Scene |
| 6 | **Resolve Names** | Rename to the Hue names, or keep the Composer names, for all or one device. | Adopt Hue Names, Accept Names As They Are, both Adopt Hue Name |
| 7 | **Set Room Mapping** | The one hand choice of a Control4 room per Hue room or zone, now also "none". | Set Room Mapping |
| 8 | **Diagnostics** | One picker: check the connection now; read everything from the bridge now; reconnect the event stream; stop the event stream until the next start; log motion diagnostics (10 minutes). Dev builds add the connection experiment, reload credentials and check CA pinning. | Test Connection, Refresh All, Refresh Scenes, Connect and Disconnect Event Stream, Log Motion Diagnostics, Connection Test, Reload Credentials, Check CA Pinning |
| 9 | **Forget Pairing** | Unchanged, plus a confirmation. | Forget Pairing |

Hue Light and Hue Scene: no actions (their Status already points to the
bridge). Hue Motion: one action, **Test Motion Programming**, a toggle that
sends the opposite of what the device shows and Hue's state again after 30 s
(replaces Test: Motion and Test: No Motion; Refresh From Bridge retires, the
hello at start and the bridge's reads cover it).

If Composer with OS 3.4.2 cannot show folders in the Add From Hue picker (a
dev-build test, 1.7 D9), it splits into three actions (lights and zones,
scenes, motion): 11 bridge actions instead of 9.

### 1.3 What the driver does by itself

One module, `bridge/housekeeping.lua`, runs every background job: one job
at a time, reads only, user commands always first (no housekeeping request
while a command queue is busy or within 1.5 s of a user write), nothing
optional in the first 5 minutes after a Director restart, at most 100 optional
requests an hour, due times persisted because timers die at every restart and
update. It never creates, renames, binds, moves or deletes a device, except
where the owner opts in (Names From Hue = Follow; D7).

| Job | When | Replaces the click |
| --- | --- | --- |
| Read lights, scenes, zone lights and sensors | every stream connect (as today, now retried on failure); when the data is 6 h old (quick) or 24 h old (full); every 10 min while the stream is down but the bridge answers | Refresh All, Refresh Scenes, Refresh From Bridge |
| Re-check a rejected key | 5 min, 15 min, 1 h, then hourly | Test Connection |
| Re-check the bridge's identity | after any stream outage of 60 s or more, before the key goes out again | (new safety) |
| Find the bridge at a new address | when it has been unreachable 5 min (D5) | (new; today only a typed address) |
| Map Hue rooms to Control4 rooms by exact unique name | when a room appears; never over a hand choice or a removed mapping | Map Rooms By Name |
| Mark devices whose Hue room and Control4 room differ | on every read, as a marker on the list rows | Room Audit |
| Adopt devices by remembered id | at start and at every bind (as today); name matches are offered on Link Device, not applied | Link Devices |
| Accept a name the installer typed in Composer | when Composer renames a device (D6) | Accept Names As They Are |
| Say the bridge or the stream has been away an hour | Attention | (new) |

Visible: each job writes one Last Action line or an Attention item; Attention
wraps like Last Action so the action hint is never cut. Stoppable: one
setting, **Background Tasks** On (default) / Off, where Off is exactly beta
7's behaviour.

### 1.4 Settings and rows

- New: **Background Tasks** (On / Off), **Names From Hue** (Ask, the
  default and today's behaviour / Follow: rename a device while its Composer
  name still equals the old Hue name, one rename at a time).
- Shown only with Debug Mode On or under Web transfer: Stream Address, Events
  Received, Last Event. **Stream Timeout (s), Stream Watchdog (s) and Event
  Stream Transport stay visible** until the install brief stops reading them
  back (`tools/deploy.py` checks them after every install); hiding them is a
  second step.
- Room Mappings shows how each mapping was made ("by name", by hand, none).

### 1.5 Order of work (release 1.2, after 1.1 is released)

1. The ledger spec (`tests/spec/ledger_spec.lua`, every feature of the
   compat ledger reachable, aliases with an expiry, background tasks that
   never create, rename or bind on their own over a simulated week) and a
   `sort_order` uniqueness spec. Before any action changes.
2. One dev build on the house: folders and multi-pick in the Add From Hue
   picker on OS 3.4.2, and, if D5 is yes, whether mDNS answers reach the
   driver.
3. The housekeeping engine with a fake clock in the specs.
4. The merged actions, with every old command as a hidden alias until 2.0.
5. Rows, Attention wrapping, manuals, checklists, screenshots, CHANGELOG.

Before that, in 1.1 beta 8 (small fixes found by the research): Import All
New Lights no longer imports a likely replacement as a duplicate; the manual
drops the "address below 8" advice that #317 made moot; the checklists and
the manual's actions picture stop saying 22 actions; `tools/regress.sh` stops
renaming devices on the house.

### 1.6 Where the research disagreed, and the choice

| Question | Positions | Choice |
| --- | --- | --- |
| Import All New as its own button | journeys yes (1 click today, 6 inside a picker); import and maintenance fold it into Add From Hue | its own button: the most frequent job stays one click |
| Child devices' actions | import and journeys none; composer keep Adopt Hue Name and Forget per device | none: one place to look, the bridge |
| Refresh All | scheduler and comparables keep a button; maintenance, journeys and composer automatic plus a Diagnostics entry | automatic plus Diagnostics: the reads run themselves |
| Event stream off | composer and scheduler a setting; maintenance a Diagnostics entry | Diagnostics: a support step, not a setting to forget |
| Offers | composer a Suggestions drop-down; import and journeys markers and Attention | markers and Attention: no list that acts on a pick |
| Link Devices | composer and journeys automatic; import offered | adoption by id automatic (as today), name matches offered |
| Background switch | scheduler On/Off; maintenance On / On, no internet / Off | On/Off; a separate switch only if D5 brings an internet lookup |
| Discovery | maintenance and comparables want it; scheduler says no phoning home | the owner's call: D5 |

### 1.7 Decisions for the owner

Each has a recommended answer; one word decides it.

| # | Question | Recommended |
| --- | --- | --- |
| D1 | Ship this as 1.2 after 1.1 is released, not in the 1.1 betas the tester follows? | yes |
| D2 | Keep Import All New as its own one-click button (9 bridge actions, not 8)? | yes |
| D3 | Take all actions off the Hue Light and Hue Scene devices? | yes |
| D4 | One Background Tasks switch (On/Off, Off = beta 7) instead of one per task? | yes |
| D5 | Find the bridge again at a new address by its id: ask Signify's discovery service (internet, at most hourly, only while the bridge is missing, switchable off), after testing local mDNS first? The driver then rewrites Bridge IP Address itself and says so. | yes |
| D6 | A rename typed in Composer counts as "keep this name", and Names From Hue = Ask by default? | yes |
| D7 | Re-link a gone device by itself when a new light carries its radio (MAC), after one test with a spare bulb on the house? | yes, after the test |
| D8 | The hourly key re-check may present a rejected key again (today only Test Connection does)? | yes |
| D9 | One dev build on the house (through the Windows session, when it is free) to test folders and multi-pick in the pickers? | yes |
| D10 | The small fixes of 1.5 in 1.1 beta 8 now? | yes |

### 1.8 The owner's answers (2026-11-05)

Where this section and the text above disagree, this section wins.

| # | Answer | What changes above |
| --- | --- | --- |
| D1 | **Build now, ship as 1.2** after 1.1 is released. | None. |
| D2 | **Import All New stays its own button**: 9 bridge actions. | None. |
| D3 | **The Hue Light and Hue Scene devices have no actions.** | None. |
| D4 | **Always on, no switch.** | The Background Tasks setting of 1.3 and 1.4 is dropped. Each job still writes Last Action or Attention, and Debug Mode logs every run, so support can tell what ran. |
| D5 | **Local only; internet reliance is always a bad choice.** When the driver is first loaded it finds the bridges on the network and lets the installer pick one; afterwards it finds the paired bridge again by itself when its address changes. | No Signify discovery service, not even as a fallback. Local means only: mDNS first (the dev build of D9 tests whether answers reach the driver), and if mDNS cannot work on Director, a bounded probe of the controller's subnet for the known bridge id (unauthenticated `GET /api/config`, under the TLS check). A new picker row lists the bridges found (name, model, id); choosing one sets the address and opens the pairing window. If nothing local works, Attention says the bridge is missing. |
| D6 | **Two-way names for lights, scenes and motion sensors** (not rooms): a rename in Composer renames the thing on the Hue bridge too, and a rename in Hue renames the Control4 device, automatically, so the two never drift. | Replaces Names From Hue (Ask/Follow) and most of Resolve Names: names sync both ways by themselves. Resolve Names stays only for what cannot sync (a name Hue refuses, such as too long or a duplicate scene name in a room) and for the first sync of devices whose names differ at the update. Rooms keep the hand mapping of Set Room Mapping. Edge cases first (CLAUDE.md): both sides renamed at once (Control4 wins: it is the source of truth), Hue's name length limit, duplicate names, echo loops, renames while the bridge is offline, zone lights. |
| D7 | **Automatic re-link when the MAC matches**: the same physical bulb back with new Hue ids (a bridge reset or swap, a delete and re-add) re-links its old device by itself and says so. A truly new bulb is only suggested, when it carries the same name in the same Hue room. | One delete-and-re-add test on the house first confirms the MAC survives (part of D9's dev build). |
| D8 | **Yes**: the rejected key is re-checked automatically (5 min, 15 min, 1 h, then hourly). | None. |
| D9 | **Yes**: one dev build on the house through the Windows session, once the Modern Forms work frees it, to test picker folders, mDNS answers and the bulb re-add of D7. | None. |
| D10 | **Yes**: the four small fixes of 1.5 go into 1.1 beta 8 now. | None. |

### 1.9 Two more answers (2026-11-05), from the follow-up research

| # | Answer | Source |
| --- | --- | --- |
| D11 | **At the 1.2 install, names that already differ are offered, not synced:** Resolve Names lists them once, with "Composer names to Hue" as the first row; from then on every rename syncs by itself both ways. Zone lights stay out of the automatic sync, like rooms. | [names-sync research](simplify-research-names-sync.md) |
| D12 | **Discovery keeps a second local stage:** if mDNS finds nothing while the paired bridge is missing, a TCP probe of port 443 on at most two /24 networks (around the last good address and around the controller), at most hourly, four connections at once; identity as at pairing (the Signify chain, the bridge id in its public config). Never the internet. | [discovery research](simplify-research-discovery.md) |

## 2. Build contract, wave 1 (coordinator, 2026-11-05)

Two pieces that touch no shared file, built in parallel on
`feature/simplify-1.2-334`; wiring into `driver.lua`, `driver.xml` and
`tools/build.sh` stays with the coordinator.

### 2.1 The engine: `bridge/housekeeping.lua`

The interface and rules are [scheduler research](simplify-research-scheduler.md)
§3.1 to §3.7 and §6 (tests), with these amendments from section 1.8:

- **No `enable()`**: background tasks are always on (D4). Debug Mode logs
  every run (task, trigger, requests used, result).
- **The engine only reads** (GETs). The writes that 1.2 adds, the name sync of
  D6, come from a person's rename and go through the user's command path, not
  through the engine; they count as user activity for the gate of §3.4.
- **Not wired yet.** Wave 1 delivers the module, `commands:busy()` in
  `bridge/commands.lua`, and their specs; no task is registered in
  `driver.lua` yet. A spec-only task table proves the rules.
- **Fake clock**: an `advance(ms)` helper in `tests/helpers/fake_c4.lua` that
  moves `c4.now_ms` and fires due timers in time order (the existing
  `fire_timers` stays as it is).

Owner files: `src/hue_bridge/bridge/housekeeping.lua`,
`src/hue_bridge/bridge/commands.lua`, `tests/spec/housekeeping_spec.lua`,
`tests/spec/commands_spec.lua`, `tests/helpers/fake_c4.lua`.

### 2.2 The dev-build probe: `bridge/probe12.lua`

One module, dev builds only (stripped like `bridge/devtools.lua`), that
answers the open questions of the D9 install in about two minutes through
signed dev-loop commands (`tools/devctl.py run`), so the Windows session only
installs in place:

- **Probe Discovery**: [discovery research](simplify-research-discovery.md)
  §6: the environment (controller address), the SSDP control, the mDNS
  variants (does an answer reach `ReceivedFromNetwork`, with which address
  record), and a timed TCP 443 sweep of one /24 with four connections at
  once, reporting each step to the log and Last Action.
- **Probe Names**: [names-sync research](simplify-research-names-sync.md) §8:
  rename one light, one scene, one motion sensor device and one MotionAware
  area to a marked test name and back, a 33-character name, and a duplicate
  scene name in one room, restoring every original name even after an error;
  reports Hue's answer to each.
- **Picker folders**: the handler for one DEV-ONLY test action whose
  CUSTOM_SELECT returns folders (the XML snippet goes into the hand-back; the
  coordinator adds it to `driver.xml`), logging what Composer sends back.

Owner files: `src/hue_bridge/bridge/probe12.lua`, `tests/spec/probe12_spec.lua`,
`src/hue_bridge/bridge/devtools.lua` (registration of the probe commands
only). The bulb re-add of D7 needs the owner's phone (delete one bulb in the
Hue app, add it again) and is read from the existing log afterwards.

### 2.3 What the dev build showed (2026-11-05, build 447 on the house)

The full report is on #334 and in Discussions (#358). What it settles:

- **Picker folders work on OS 3.4.2.** A CUSTOM_SELECT list function gets
  the current folder's value as its first argument (`""` at the top) and
  answers `list, back`. Entries with `folder = true` open on double-click; a
  "Back" row returns to `back`; a folder entry can itself be picked. **Add
  From Hue is one picker: 9 bridge actions** (1.2), not the fallback of 11.
- **Single selection only**: bulk adds stay as "All …" rows.
- **The pickers of one action are independent**: the second list function
  gets `""`, never the first picker's value. An action validates the pair
  when it runs and refuses a mismatch in Last Action.
- **mDNS works from the driver**: a legacy query from the driver's own port
  (UDP connection to 224.0.0.251:5353) gets the paired bridge's answer in
  milliseconds, with PTR, SRV, TXT (`bridgeid`, `modelid`) and A records.
  `ReceivedFromNetwork` names no sender, so the address comes from the A
  record. Port 5353 itself is Director's.
- **The sweep works**: 253 hosts in 83 s with 4 connections in flight; the
  identity check of the 9 open hosts took 2.4 s, and every non-Hue host
  failed at TLS before any HTTP request.
- **Names:** a light's device name and its light name are independent;
  Hue refuses 33 characters (`maxLength`) and 32 two-byte characters
  ("Invalid name"), so the limit is treated as **32 bytes of UTF-8**; a
  duplicate scene name in one room is accepted; a MotionAware area takes a
  name from the driver. Not tested: motion sensor renames (the house has
  none), names-sync tests T4 and T5 (our RenameDevice's echo, an adopted
  device's rename); they run on the first 1.2 dev build.
- **D7's bulb test was skipped by the owner** (2026-11-05): the MAC in
  `zigbee_connectivity` is the bulb's Zigbee IEEE address, fixed in hardware.

## 3. Build contract, wave 2 (coordinator, 2026-11-05)

Everything else of 1.2, on `feature/simplify-1.2-334`, in five parallel
pieces with disjoint files plus the coordinator's integration. Sections 1.2,
1.3, 1.8, 1.9 and 2.3 are the requirements; this section is the interface.
Where they disagree, this section wins.

### 3.1 Decisions taken from the research's recommendations

The owner answered D1 to D12. The names-sync research asked nine more
questions (its §7); Q1 and Q2 are D11. The others take the research's
recommended answer, reported to the owner and reversible in review:
a refused name is never cut by itself (Q3); a room prefix typed in Composer
stays on the Composer side (Q4); more than 5 differences found in one pass
are held and offered (Q5); a re-link, by click or by MAC, gives the Hue
thing the Composer name (Q6); motion's "no writes" rule is lifted for names
only (Q7); a Hue rename of a held device waits for Resolve Names (Q8).

The scheduler research's tiering stands: a **full** resync at the first
connect of a run, after an error reconnect and after an outage of 10
minutes or more; a **quick** one (no `/scene` and `/smart_scene`) after a
silence (watchdog) reconnect. This is the #65 split.

### 3.2 D7: automatic re-link by MAC, the cases

Runs on every lights or motion registry refresh (resync and stream `add`).
"Gone" means a linked Control4 device whose rid the last *successful* full
read did not contain; tombstoned (forgotten) devices are never candidates.

| # | Case | Behaviour | Class |
| --- | --- | --- | --- |
| M1 | A new rid carries the MAC of exactly one gone device of the same kind, single-light device | re-link that device to the new rid; Last Action "Re-linked Desk Lamp to its bulb (same radio, new Hue id)"; names N16 | auto |
| M2 | Several gone devices carry that MAC (two histories) | suggestion only (Link Device "(suggested)") | offered |
| M3 | Multi-light device (one MAC, several lights) | auto only when the light's position on its device (`service_id` / its index among the device's light services) matches exactly one gone entry; else suggested | auto / offered |
| M4 | The gone device was forgotten, or its Composer device deleted | nothing | — |
| M5 | The new rid is already linked to another device (imported meanwhile) | nothing automatic; Link Device suggests | offered |
| M6 | Bridge reset or replaced and re-paired (many at once) | every M1 match re-links, one Last Action summary ("Re-linked 47 devices by radio"); names follow at the paced rate of N16 | auto |
| M7 | Motion sensor: the same rule on the sensor's device MAC | as M1 to M5 | auto / offered |
| M8 | Same name, same Hue room, different MAC (a truly new bulb) | suggestion only, as beta 8 | offered |
| M9 | Scenes, zone lights, MotionAware areas | no MAC: never automatic (scene S4: suggested by unique name in the same group) | offered |

An automatic re-link never creates, deletes, moves or renames a device in
Composer, and Import All New skips any light or sensor that M1 to M7 would
re-link or suggest (the beta 8 rule).

### 3.3 The actions (driver.xml, the coordinator's)

Bridge, in this `sort_order`: 1 Pair Bridge, 2 Import All New, 3 Add From
Hue (params What, Room), 4 Link Device (params Device, To), 5 Forget Device
(params Device, Confirm), 6 Resolve Names (param Names), 7 Set Room Mapping
(params Hue Room, Control4 Room; as today plus a "none" target), 8
Diagnostics (param What), 9 Forget Pairing (param Confirm). Dev builds add
their three dev actions inside Diagnostics' list, not as actions. Confirm is
a LIST `No` / `Yes, forget`; anything but the second refuses with "Not
forgotten: choose Yes, forget".

Every removed action's command string stays a **hidden alias** in
`dispatch.commands` until 2.0 (compat research R2; the ledger checks it).
Hue Light and Hue Scene: no actions; their old commands stay aliases. Hue
Motion: one action, **Test Motion Programming**; Test: Motion, Test: No
Motion and Refresh From Bridge stay aliases.

### 3.4 Interfaces

**`bridge/actions.lua`** (piece C): the pickers and runners of actions 3 to
6 and 8, built only from the modules' public methods; it edits no module.

```lua
local actions = require("bridge.actions")
local a = actions.new(ctx)
-- ctx = { lights, scenes, zone_lights, motion, names, last_action = fn(text),
--         can = fn() -> bool, diagnostics = { [value] = { text, run = fn() } },
--         dev = bool }
a:add_list(folder)        -> list, back   -- What of Add From Hue
a:room_list()             -> list         -- Room (the lights' picker_rooms("add"))
a:link_list(folder)       -> list, back   -- Device of Link Device
a:link_target_list(folder)-> list, back   -- To of Link Device
a:forget_list(folder)     -> list, back
a:names_list()            -> list         -- Names of Resolve Names (from names)
a:diagnostics_list()      -> list
a:run_add(params)  a:run_link(params)  a:run_forget(params)
a:run_names(params)  a:run_diagnostics(params)   -- each ends in last_action
```

Value grammar (stable, logged, never shown): folders `f:lights`,
`f:groups`, `f:scenes`, `f:scenes:<group_rid>` (selectable: all scenes of
that room or zone), `f:motion`; leaves `light:<rid>`, `group:<rid>`,
`scene:<rid>`, `sensor:<rid>`, `area:<rid>`, `all:lights`, `all:motion`;
devices `dev:<device_id>`, `dev:suggested` (every device with a suggested
match). A folder whose list would be empty is left out; an empty picker
shows one explanatory row with value `""`.

**`bridge/names.lua`** (piece B): the two-way sync of names-sync research §5.

```lua
local names = require("bridge.names")
local n = names.new(ctx)
-- ctx = { store (persist get/set), registries = { light = lights, scene = scenes,
--         motion = motion }, put_name = fn(kind, rid, name, done(ok, err)),
--         rename_device = fn(proxy_id, name), display_name = fn(device_id) -> name,
--         user_active = fn() -> bool, last_action = fn(text), attention_changed = fn() }
n:on_composer_rename(proxy_id)          -- from OnSystemEvent OnItemNameChanged
n:on_hue_name(kind, rid, name)          -- from the modules' take_name paths
n:pass(kind)                            -- after each module's resync
n:relinked(kind, old_rid, new_rid)      -- N16
n:forgotten(kind, rid)
n:resolve_rows() -> list                -- for Resolve Names
n:resolve(value, done)
n:attention() -> list of texts
n:migrate(build)                         -- N19 at the first run of 1.2
```

**`bridge/discovery.lua`** (piece A, with any helper modules it needs):

```lua
local discovery = require("bridge.discovery")
local d = discovery.new(ctx)
-- ctx = { controller_ip = fn(), identify = fn(ip, done(info|nil, err)),
--         log, now_ms, timer = fn(ms, fn) }
d:find_all(done(list))          -- first load and "Search again": mDNS, then nothing more
d:find_subnet(done(list))       -- the offered subnet search (sweep), on a click
d:find_paired(bridge_id, last_ip, done(ip|nil, how))   -- the follow-up (D5, D12)
-- list items: { id, name, model, ip, how = "mdns"|"sweep" }
-- ReceivedFromNetwork(binding, port, data) is forwarded by driver.lua to d:received(...)
```

**Modules (piece B)** keep their public methods and resync signatures
(amended 2026-11-05: `driver.lua`'s `resync_all(done, tier)` makes the
quick tier itself by leaving out `scenes:resync`; the zone lights then read
`/grouped_light` themselves, as they already can). Motion's resync also sends every motion device the
bridge's answering state (the #247 side finding); lights and motion apply
3.2 inside their registry refresh and expose `suggested()` for
`dev:suggested`.

### 3.5 Pieces and owner files

| Piece | Owns (creates or edits only these) |
| --- | --- |
| A discovery | `src/hue_bridge/bridge/discovery.lua` (and `bridge/mdns.lua`, `bridge/sweep.lua` if split), `tests/spec/discovery_spec.lua` (and their specs) |
| B names and re-link | `src/hue_bridge/bridge/names.lua`, `tests/spec/names_spec.lua`, `src/hue_bridge/bridge/{owner,lights,scenes,zone_lights,motion}.lua`, `tests/spec/{owner,lights,scenes,zone_lights,motion}_spec.lua`, `tests/fixtures/hue_resources.lua`, `tests/fixtures/hue_motion.lua` |
| C actions | `src/hue_bridge/bridge/actions.lua`, `tests/spec/actions_spec.lua`, `tests/spec/ledger_spec.lua`, `tests/fixtures/ledger.lua` |
| D child drivers | `src/hue_light/**`, `src/hue_scene/**`, `src/hue_motion/**` except their `www/documentation.html`; `tests/spec/{light_driver,scene_driver,motion_driver,light_caps,light_state,light_relative_level}_spec.lua` |
| E documentation | every `www/documentation.html`, `docs/composer-checklist.md`, `docs/release-checklist.md`, `docs/import-design.md`, `docs/README.md`, `README.md`, `CHANGELOG.md` (the `## Unreleased` lines only) |
| Coordinator | `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml`, `src/hue_bridge/bridge/{housekeeping,commands,devtools,probe12}.lua`, `tools/**`, `tests/spec/{roundtrip,drivers,devloop,housekeeping,commands}_spec.lua`, the other roundtrip specs, `tests/helpers/fake_c4.lua`, this document, `docs/status.md`, `CLAUDE.md` |

A piece that needs a change in a file it does not own writes the exact
change into its hand-back instead. The coordinator wires: the housekeeping
tasks (scheduler research §5, with the tiers of 3.1 and the key re-check of
D8), the merged actions and aliases, Bridges Found and the address
follow-up, `OnItemNameChanged`, the Attention wrap and the rows.

## 4. Wave 3: what the documentation pass found (coordinator, 2026-11-05)

Piece G read every manual against the code and listed twelve places where
the code is wrong, or does less than this contract decided. Each is decided
here. Findings 6 and the identity re-check are not new decisions: §1.3 and
D5 promised them, and the code never had them.

| # | Finding | Decision | Piece |
| --- | --- | --- | --- |
| 1 | An Attention text longer than six rows is logged in full only with Debug Mode On (`log.info`), while Last Action's overflow is always logged | Log it as Last Action does (`log.always`) | H |
| 2 | Forget Pairing leaves Bridges Found reading "Paired with ..." and the automatic searches stopped until the driver restarts; a new pairing leaves "N found: pick one" up to 15 minutes | Both redraw the row at once; Forget Pairing starts the first-load searches again (3 s, 1 min, 5 min, then every 15 min) | H |
| 3 | Every automatic search of an unpaired driver writes Last Action ("Bridges Found: ...") every 15 minutes, over the owner's last result | Automatic searches write the log and the row only; Last Action is for searches the owner asked for (Search again, the subnet pick) | H |
| 4 | Picking a bridge in Bridges Found does not pass its id to the pairing, so another bridge answering at that address in the window would be paired | The pick's id is the expected one: a different id at the address is refused as Pair Bridge refuses one today | H |
| 5 | The Link Device row names the device twice | The suggestion suffix names only the Hue thing and the reason | I |
| 6 | Not built: Attention when the paired bridge is missing (D5: "If nothing local works, Attention says the bridge is missing"), the bridge or stream away an hour (§1.3), and the identity re-check before the key goes out again after an outage of 60 s or more (§1.3) | Build them as §1.3 and D5 say; the discovery research (simplify-research-discovery.md) has the texts of the missing, moved and typed-address-wrong cases, and its texts are used where they fit | H |
| 7 | safety_quick, safety_full and stream_down_read are not counted against the hourly budget of optional requests | They are counted; stream_down_read stays every 10 minutes while the stream is down and the bridge answers. A quick read costs 15 requests on a Bridge Pro, so six an hour cannot fit under 60: the hourly budget is 100 (piece H; at most one request every 36 s on average) | H |
| 8 | A new light with a re-link hint is told "(Import All New or Add From Hue)", which Import All New skips; a new motion sensor is told "(Add From Hue)", which Import All New imports | Hinted lights end "(Link Device)"; sensors end "(Import All New or Add From Hue)" | I |
| 9 | Name suggestions need the same Hue room or group id, so after a bridge reset nothing is suggested; zone lights have none | The same room is the same id or, failing that, the same room name; zone lights get suggestions by the same rule if their module allows it without a new picker, otherwise an issue for 1.3 | I |
| 10 | Inside Import All New the automatic re-link's Last Action is overwritten by the import's, and the import result never names the re-linked devices | Import All New's result names them ("re-linked 2: Lamp 3, Lamp 4"), and the re-link run inside an import writes no Last Action of its own | I |
| 11 | A room-mapping pass that finds only ambiguous names writes Last Action and changes nothing; a result can begin "re-mapped" in lowercase | Nothing changed, nothing written (the log keeps it); every Last Action begins with a capital | I |
| 12 | "Search every address of a.b.c.x" names the controller's /24, but the search starts with the Bridge IP Address's /24 | The label names what is searched | H |
| 13 | (dev 467 on the house) A Composer rename reaches Hue, but the device's Hue Name row keeps the old name: a name change arriving on the event stream updates the registry and sends no HUE_CONFIGURE, so the row waited for the next full read (as in 1.1, but with two-way names it reads as a failed sync) | A name change from the stream sends the device its configure at once, for lights, scenes, zone lights and motion alike | I |
| 14 | (dev 467) Composer's Select list reacts only to a click on a label's text, so the short "Back" row of Add From Hue and Link Device is hard to hit | The Back row names where it goes ("Back to Scenes", "Back to all folders"), wide enough to hit | I |

Owner files: **H** `src/hue_bridge/driver.lua`, `src/hue_bridge/bridge/{housekeeping,discovery,mdns,sweep}.lua`, `tests/spec/{drivers,housekeeping,discovery,devloop}_spec.lua`, the roundtrip specs, `tests/helpers/fake_c4.lua`. **I** `src/hue_bridge/bridge/{owner,lights,scenes,zone_lights,motion,actions,names}.lua`, their specs, `tests/fixtures/*`. **J** (after H and I) every `www/documentation.html`, `docs/composer-checklist.md`, `docs/release-checklist.md`, `docs/import-design.md`, `README.md`, `CHANGELOG.md` (`## Unreleased`). A piece that needs a change in a file it does not own writes the exact change into its hand-back.
