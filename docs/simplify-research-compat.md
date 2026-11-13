# Simplifying the drivers: what depends on each action, and an upgrade that loses nothing (#334)

Research for `docs/simplify-actions-design.md` §0, agent "compat", 2026-11-04.
Read-only; nothing in `src/` changes. The question: what names or relies on
each of the 39 actions today, so that a simpler set loses no feature and
breaks no project. `main` = beta 7, build 425. Counts are lines found by
grep (word-bounded name or its `snake_case` dispatch key), excluding the
`docs/simplify-*` files and the stale worktree under `.claude/`.

Citations: `path:line` in this repository; **API**, **FUND**, **XML** = the
DriverWorks references under `~/c4-tools/reference/docs-driverworks-{api,fundamentals,xml}/source/includes/`;
**composer** = `docs/simplify-research-composer.md`. Each claim is marked
**verified** (code, docs, spec or hardware report) or **assumed**.

## 1. Findings

1. **No Composer project can refer to an action.** Programming uses a
   driver's `<commands>`, events, variables and conditionals. `<actions>`
   exist only on the Actions tab. Renaming, merging or removing an action
   cannot break programming, bindings, Navigators or keypads. What can break
   them is out of an action simplification's way: proxies, connections,
   `<commands>`, events, variables, persisted keys and dealer-set properties
   (§7).
2. **The `<command>` reaches the driver, not the shown `<name>`.** Changing
   only `<name>` renames the button with no change to code, dispatch, dev
   loop or spec invocations. Hue Motion already does this (`Test: Motion`
   sends `Test Motion`).
3. **Three outside callers use command strings:** the dev loop
   (`devctl.py run`, and `tools/regress.sh` with six actions), any driver in
   the project through `C4:SendToDevice` (ExecuteCommand has no sender), and
   briefs for the Windows session. A command that leaves `driver.xml` should
   stay as a hidden alias in the dispatch table until 2.0 (§5.3 R2).
4. **The update path is proven on hardware:**
   - Every dev → release install removed three actions and two properties
     in place.
   - Beta 7 renamed an action in place on 8 devices; no reboot, since
     actions are not capabilities.
   - Beta 4 added a LIST property, and its default reached the existing
     devices.

   Still unproven and risky: changing a LIST property's items, and renaming
   a property the dealer sets.
5. **A release build shows 29 bridge actions, not 32.** Connection Test,
   Reload Credentials and Check CA Pinning are DEV-ONLY. Three checklists and
   the manual's `bridge-actions.png` still show 22.
6. **The persisted store is the real contract:** 19 bridge keys, plus
   per-device keys (§5.2). Actions wrote most of it: the pairing, room
   mappings, tombstones, forgotten lists, accepted names and the one-time
   automap flag.
   - A simpler driver must keep honouring every key as beta 7 wrote it.
   - New state must go into new keys. Lights, zone lights and motion load
     their registries with a schema that drops unknown fields, so a new
     field would be lost on a rollback.
7. **The specs would not notice a lost action path.**
   - 9 bridge actions are never dispatched through `driver.lua` by any
     spec, and neither are 8 of the 17 picker functions.
   - No spec compares the bridge's action list with its handlers or with
     the manual.

   A ledger conformance spec (§6.2) should go in before any action changes.
8. **Texts are the bulk of the cost.**
   - 91 Lua lines name an action in a user text (Attention, Status, Last
     Action, picker placeholders), 7 of them in the device drivers.
   - The manuals have 545 lines and the specs 475.
   - The modules' `WORDS` tables hold most of the bridge texts.
9. **Few names live outside the repository:**
   - Test Connection: the bug-report form.
   - The motion actions and Refresh All: the tester's steps (#305, #309)
     and seven sets of beta notes.
   - 14 actions: the 1.0 release notes.

   Published notes are history. A rename needs a "Renamed" changelog line,
   not edits to old notes.

## 2. Evidence

| Claim | Evidence | Status |
| --- | --- | --- |
| Actions are installation-time configuration; programming uses commands, variables, conditionals and events | FUND `15_composerpro_interface_into_the_sdk/_6-ACTIONS.md`, `_7-PROGRAMMING.md`; composer §H | verified (docs) |
| Update guidance lists properties, events, variables and commands, never actions. Properties may be added or removed but not retyped. Events, variables and commands must not be removed | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | verified (docs) |
| A click arrives as `LUA_ACTION` with `ACTION` = the action's **command** | FUND `12.3_custom_select_implementation/_2-CUSTOMSELECTLIST.md` (Action Parameters); XML `30_actions/_20-command.md`; `src/common/dispatch.lua:36-45` | verified (docs, code) |
| Shown name ≠ command works in our code | `src/hue_motion/driver.xml:138-147`; `tests/spec/drivers_spec.lua:1613-1625` | verified (spec); never clicked on the house (`docs/composer-checklist.md:686-706`, "Done: open") |
| Any project driver can run any dispatch key | API `5_director_command/_1-ExecuteCommand.md`; `src/hue_bridge/bridge/devtools.lua:16-18` | verified (docs, code); no outside caller known (assumed) |
| The bridge declares no programming commands. Only the Hue Light has some (Raise Level By, Restore Saved Level) | `src/hue_bridge/driver.xml:560`; `src/hue_light/driver.xml:104-140` | verified |
| Release builds have no Lua command window, so dealer Lua cannot call the bridge | `tools/build.sh:8-11` (`--allowexecute` only with `--dev`) | verified |
| The dev loop runs `ExecuteCommand(command)` by name, so it reaches actions and `HUE_*` messages | `src/common/devloop.lua:876-895`; `tools/devctl.py:12,444`; `tools/regress.sh:49-74` | verified |
| Removing actions and properties in place: dev → release drops three actions and the Dev/Diagnostic Server rows | `tools/build.sh:111-118`; `docs/release-checklist.md:113-120` | verified (hardware, every release install) |
| Renaming an action in place: Add All New Motion Sensors → Import All New Motion Sensors | `docs/list-rows-design.md:8`; `tests/spec/motion_roundtrip_spec.lua:459-470`; deployment 7374829355 ("Driver Version 425 on 8 devices") | verified (install); the Actions tab after it was not read back |
| A new property's default reaches existing devices | `docs/scene-led-design.md:73`; `docs/status.md:68` (On State Follows) | verified (hardware) |
| STRING → DYNAMIC_LIST change installs without a reboot | `docs/status.md:209` (build 185) | verified (hardware) |
| A property value survives updates (Debug Mode kept through a release install) | `docs/release-checklist.md:110-112`; `docs/edge-cases-control4.md:223-226` | verified (hardware) |
| A renamed property loses its value | composer §H; FUND `14_…/_2` | assumed |
| A LIST whose stored value is not among the new items | not documented | assumed: Director keeps and replays the string |
| Every property handler is replayed at late init, before `late_init_done` | `src/hue_bridge/driver.lua:2309-2313`; the list rows ignore it (`:1488-1495`) | verified (code) |
| An action clicked before late init is dropped | `src/hue_bridge/driver.lua:2215-2233` | verified (code) |
| The bridge ignores the DIT argument (added, updated or restarted) | `src/hue_bridge/driver.lua:2265`; composer §1.8 | verified (code) |
| Registries with a schema drop unknown entry fields at load (lights, zone lights, motion; scenes keep them) | `src/hue_bridge/bridge/registry.lua:37-45`; `lights.lua:165`, `zone_lights.lua:159`, `motion.lua:344` | verified |
| Migrations on load exist already | automap flag `lights.lua:918-935`; netcheck key `_v2` `netcheck.lua:155-158`; registry v1 → `linked` `registry.lua:44` | verified |
| A device is created only from an owner's click; `AddDevice` is for user-started actions | `docs/import-design.md:28-33` (API 9/_0.1); composer §1.5 | verified (docs) |

## 3. Traceability matrix (all 39 actions)

How to read the columns:

- **XML**: the sort order and the parameter pickers, from `driver.xml`.
- **Handler**: the line in `driver.lua` (the bridge's, unless another file
  is named).
- **Texts**: Lua string literals that name the action.
- **Specs**: lines that run the action through `ExecuteCommand` / other
  lines that mention it, and the files where most of them are.
- **Manual**: lines in the bridge manual + lines in the device's own manual.
- **docs**: lines in all `docs/*.md` / in `composer-checklist.md` / in
  `screenshots-plan.md`.
- **Outside**: references outside the code and docs. "1.0 notes" are the
  GitHub release notes of `v1.0`. "β1-7" are the 1.1 prerelease notes.

| # | Action | XML | Handler | Texts | Specs | Manual | docs | Outside |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Pair Bridge | 1; — | 1266 | 5 | 8/6 drivers, dispatch | 23 | 37/1/1 | 1.0 notes ×3; README ×3; Status texts |
| 2 | Add Light | 2; Light→HueLightList, Room→RoomList | 1596 | 8 | 1/21 roundtrip; lights | 24+2 | 83/10/7 | 1.0 notes; add-light, attention pictures |
| 3 | Import All New Lights | 3; — | 1605 | 3 | 1/12 roundtrip; lights | 14+1 | 27/5/3 | 1.0 notes; #309 |
| 4 | Add Zone Light | 4; Group→ZoneGroupList, Room | 1769 | 3 | 2/11 drivers; zone_lights | 18+2 | 23/3/4 | release-checklist §2.4; picture |
| 5 | Re-link Device To Light | 5; Device→RelinkDeviceList, Light | 1611 | 3 | **0**/3 lights | 14+1 | 22/2/4 | 1.0 notes; two pictures |
| 6 | Re-link Zone Light | 6; Device→RelinkZoneLightList, Group | 1778 | 4 | **0**/8 zone_lights | 8+1 | 12/1/2 | — |
| 7 | Link Devices | 7; — | 1621 | 14 (7 in device drivers) | 2/33 drivers, motion_roundtrip; lights, scenes | 28+10 | 77/6/1 | regress.sh; Status of forgotten devices |
| 8 | Forget Light | 8; Device→ForgetDeviceList | 1630 | 11 | **0**/23 zone_lights, lights | 27+2 | 33/3/3 | 1.0 notes; release-checklist §2.4; picture |
| 9 | Adopt Hue Names | 9; — | 1690 | 2 | 1/32 motion_roundtrip; scenes, lights | 14+2 | 33/3/3 | regress.sh (renames on the house); 1.0 notes ×2 |
| 10 | Accept Names As They Are | 10; — | 1698 | 1 | 1/20 motion_roundtrip; scenes | 12+1 | 22/1/3 | regress.sh |
| 11 | Set Room Mapping | 11; Hue Room→HueRoomList, Room→MappingTargetList | 1705 | 7 | **0**/21 lights, motion | 32 | 29/3/4 | 1.0 notes; #309 ×2; two pictures |
| 12 | Map Rooms By Name | 12; — | 1722 | 4 | **0**/8 lights | 16 | 21/1/1 | 1.0 notes; also runs once by itself (`lights.lua:918`) |
| 13 | Room Audit | 13; — | 1739 | 2 | 2/0 drivers, roundtrip | 12 | 39/5/8 | regress.sh; the screenshot plan's only RunAction; picture |
| 14 | Add Scene | 14; Scene→SceneList, Room | 1878 | 7 | **0**/24 scenes, scene_roundtrip | 20+4 | 46/6/3 | 1.0 notes; picture; scene Status text |
| 15 | Add All Scenes Of Room | 15; Hue Room→SceneGroupList | 1887 | 1 | **0**/4 scenes | 13+2 | 23/4/3 | picture |
| 16 | Re-link Scene | 16; Device→RelinkSceneList, Scene | 1896 | 4 | **0**/5 scenes | 11+2 | 19/3/1 | — |
| 17 | Forget Scene | 17; Device→ForgetSceneList | 1906 | 6 | **0**/14 scenes | 13+1 | 18/3/1 | 1.0 notes |
| 18 | Refresh Scenes | 18; — | 1930 | 2 | 2/5 drivers; scenes | 8 | 17/1/2 | regress.sh |
| 19 | Refresh All | 19; — | 1917 | 1 | 1/1 drivers | 1 | 1/0/0 | β6, β7 notes; #324 (open); #309 ×4 (tester's workaround) |
| 20 | Add Motion Sensor | 20; Sensor→MotionSensorList, Room | 1805 | 8 | 3/18 motion_roundtrip, motion | 21+2 | 19/4/0 | β1-7 notes; #309 ×7; tester's checklist steps 61-72 |
| 21 | Import All New Motion Sensors | 21; — | 1816 | 0 | 1/4 motion_roundtrip (asserts the old name is gone) | 12+1 | 2/0/0 | β7 notes; #305 comment; #309 ×2 |
| 22 | Add Motion Area | 22; Area→MotionAreaList, Room | 1822 | 6 | 1/7 motion_roundtrip, motion | 20+2 | 7/4/0 | β1-7 notes |
| 23 | Re-link Motion Device | 23; Device→RelinkMotionDeviceList, Target→MotionTargetList | 1831 | 2 | 4/3 motion_roundtrip | 9+1 | 3/2/0 | — |
| 24 | Forget Motion Device | 24; Device→ForgetMotionDeviceList | 1841 | 3 | 1/10 motion_roundtrip, motion | 15+3 | 3/1/0 | — |
| 25 | Log Motion Diagnostics | 25; — | 1852 | 0 | 1/3 motion_roundtrip, motion_diag | 5+1 | 9/5/0 | β1-7 notes; manual 14.15; tester's step 63 |
| 26 | Test Connection | 26; — | 1386 | 6 | 13/15 drivers, devloop | 18 | 61/2/1 | **bug_report.yml:15**; 1.0 notes ×3; regress.sh |
| 27 | Connect Event Stream | 27; — | 2062 | 0 | 7/3 drivers, netcheck | 8 | 18/1/1 | 1.0 notes; #309 |
| 28 | Disconnect Event Stream | 28; — | 2078 | 0 | 5/0 drivers | 5+3 | 9/2/1 | #309 ×3 (beta 5 workaround) |
| 29 | Connection Test (DEV) | 29; Target LIST | `devtools.lua:651` | 1 | 5/10 devloop, drivers | 2 | 42/2/0 | `devctl.py` help; `test_devctl.py:145`; `dev-loop.md:345` |
| 30 | Reload Credentials (DEV) | 30; — | `devtools.lua:652` | 0 | 2/3 drivers | 2 | 18/1/0 | dev-loop.md |
| 31 | Check CA Pinning (DEV) | 31; — | `devtools.lua:653` | 0 | 2/4 drivers | 3 | 29/2/0 | release-checklist §4 |
| 32 | Forget Pairing | 32; — | 2082 | 1 | 6/11 drivers, netcheck | 16+3 | 34/1/1 | 1.0 notes ×3; refusal text `pairing.lua:105` |
| 33 | Adopt Hue Name (Light) | 1; — | `hue_light/driver.lua:590` | 0 | 13 lines light_driver (+XML name = command) | 16+2 | 38/3/2 | light-actions picture |
| 34 | Forget This Light | 2; — (sends HUE_FORGET) | `hue_light/driver.lua:607` | 0 | 5/4 light_driver | 8+4 | 12/1/1 | light-actions picture |
| 35 | Adopt Hue Name (Scene) | 1; — | `hue_scene/driver.lua:1091` | 0 | 11 lines scene_driver (+XML name = command) | (with 33)+4 | (with 33) | scene-actions picture |
| 36 | Forget This Scene | 2; — (sends HUE_SCENE_FORGET) | `hue_scene/driver.lua:1114` | 0 | 3/4 scene_driver, scene_roundtrip | 5+2 | 12/1/2 | scene-actions picture |
| 37 | Refresh From Bridge | 1; — (sends HUE_MOTION_HELLO) | `hue_motion/driver.lua:1094` | 0 | 1/6 motion_roundtrip, motion_driver | 3+2 | 2/1/0 | checklist 56 (open) |
| 38 | Test: Motion (`Test Motion`) | 2; — | `hue_motion/driver.lua:1104` | 0 | 6 lines motion_driver; XML loop | 3+1 | 10/4/0 | checklist 57 (open) |
| 39 | Test: No Motion (`Test No Motion`) | 3; — | `hue_motion/driver.lua:1108` | 0 | 3 lines motion_driver; XML loop | 3+1 | 10/4/0 | checklist 57 (open) |

Totals: driver.xml 78 lines, `src/**/*.lua` 325, specs 475, manuals 545,
README 18, CHANGELOG 26, `docs/` 920 (193 in `docs/reviews/`, which need no
edit; 298 in the checklists, the shot plan, the dev loop, the documentation
plan and status, which do), tools 22 (`regress.sh` 18, `devctl.py` 3, its
test 1).
`tools/composer/Composer.psm1` and `Shots.ps1` hold **no** action name: they
take one at run time (`Invoke-ComposerAction -Name`,
`tools/composer/Composer.psm1:299-306`). The shot plan's `Keep` list
(`docs/screenshots-plan.md:381-397`) and the briefs carry the names.
`tools/deploy.py`'s brief names no action, only properties
(`tools/deploy.py:1020-1032`).

What the matrix shows besides the counts:

- **Dispatch never run by a spec:**
  - The 9 rows marked **0**.
  - The pickers RelinkDeviceList, HueRoomList, MappingTargetList,
    SceneList, SceneGroupList, RelinkSceneList, ForgetSceneList and
    ForgetDeviceList.

  Their module methods are tested; the plumbing of `driver.lua` (parameter
  names Light, Room, Device, Hue Room, Group, Scene) is not. The scene and
  zone-light round trips stub the bridge's `ExecuteCommand`
  (`tests/spec/scene_roundtrip_spec.lua:104`,
  `zone_light_roundtrip_spec.lua:146`).
- **Never clicked on the house through the checklist:** Refresh All and
  Import All New Motion Sensors have no step. Refresh From Bridge and the
  two tests are steps 56-57, still open.
- **A handler without a path:** `HUE_MOTION_FORGET`
  (`src/hue_bridge/driver.lua:1870`) has no sender. Hue Motion has no
  "Forget This …" action, unlike lights and scenes. This is an asymmetry, not
  a lost feature: Forget Motion Device covers it.
- **Already stale today:** "22 actions" in `docs/composer-checklist.md:260`,
  `docs/release-checklist.md:120`, `docs/screenshots-plan.md:147` and the
  picture `img/bridge-actions.png`. A release build shows 29.
  `docs/status.md` (dated 2026-10-27) names neither Refresh All nor the
  motion actions.

## 4. Feature ledger (through beta 7 = main; checklist for any change)

Sources: `CHANGELOG.md` "## Unreleased" and 1.0, `docs/status.md`, and the
manuals' chapters 4 to 14 and quick reference
(`src/hue_bridge/www/documentation.html`).

"Gate" is how a capability is started today:

- **click**: only when the owner clicks it. The rule is in
  `docs/import-design.md` §1.
- **auto**: the driver starts it by itself.
- **prop**: a property the owner sets.
- **prog**: Control4 programming.

A change may move a row's path, but every row must keep at least one
documented path. A **click** row becomes auto only through the edge-case
process of `CLAUDE.md`.

| ID | Capability | Reached today by | Gate |
| --- | --- | --- | --- |
| P1 | Pair with the bridge at an address via the link button; fill Bridge Model, Name, Firmware | Pair Bridge + Bridge IP Address | click |
| P2 | Refuse a different bridge until the pairing is forgotten; pair the same bridge again (new key, new address, restored bridge) | Pair Bridge, Forget Pairing | click |
| P3 | Refuse a BSB001 bridge, a device that is not a Hue bridge, or firmware older than CLIP v2, each with its own text | Pair Bridge; the identity check at every start | click + auto |
| P4 | Forget the pairing (key gone, stream stopped, address and devices kept) | Forget Pairing | click |
| P5 | Follow a corrected address (the stream restarts) | Bridge IP Address | prop |
| P6 | Identity check without the key at every start and address change, retried every 30 s | — | auto |
| P7 | TLS self-check and network check with remembered verdicts; nothing keyed is sent after a failure | — (Check CA Pinning, DEV: public pinning) | auto |
| P8 | Key-rejected lock, ended by a re-pair, a new address or a 200 answer | Test Connection, Pair Bridge, Bridge IP Address | click + prop |
| P9 | A one-question health check, reported in Status | Test Connection | click |
| P10 | Event stream at start and pairing, watchdog and reconnects; transport and timeouts adjustable | Stream Timeout (s), Stream Watchdog (s), Event Stream Transport | auto + prop |
| P11 | Stop and restart the feed by hand | Disconnect / Connect Event Stream | click |
| P12 | Resync of everything after every connect; rows looked at again every 5 min (`driver.lua:2293`) | — | auto |
| P13 | Every list read without the stream (#324) | Refresh All | click |
| P14 | Scene list read now | Refresh Scenes | click |
| P15 | Developer diagnostics: stored credentials, connection experiment, public CA pinning | Reload Credentials, Connection Test, Check CA Pinning (dev builds) | click (dev) |
| P16 | Event Stream row (reconnect count), Events Received, Last Event, Stream Address | — | auto |
| R1 | Room Mappings row, every mapping in its drop-down | — | auto |
| R2 | Map one Hue room or zone to a Control4 room, or unmap it | Set Room Mapping | click |
| R3 | Map by exact name, never overriding; done once by itself at the first resync | Map Rooms By Name; automap flag | click + auto (once) |
| R4 | Audit lights and zone lights against their mappings; nothing moved | Room Audit | click |
| R5 | New devices default to "(mapped room)" | the Room picker of every Add action; the imports | click |
| L1 | Add one light, in a chosen or the mapped room | Add Light | click |
| L2 | Import every new light whose Hue room is mapped, and list the skipped ones | Import All New Lights | click |
| L3 | A device deleted in Composer is remembered: Add Light lists it as deleted, imports skip it, Add Light can bring it back | HUE_GOODBYE (auto) + Add Light | auto + click |
| L4 | Point a gone or unbound light device at another light, keeping its name, room and programming | Re-link Device To Light | click |
| L5 | Release a light device (it stays to be deleted; the light can be added again) | Forget Light, Forget This Light | click |
| L6 | Take over bound devices the bridge does not manage: by their own persisted rid (automatic) or by name and identity (click) | hello adoption (`owner.lua:486-557`); Link Devices | auto + click |
| L7 | Lights row and list; Attention names what is new, missing, unbound, conflicting or named differently, with the action that fixes it | — | auto |
| L8 | Light control: on/off, dimming, colour, colour temperature, Online, two-way state | light_v2 proxy | — |
| L9 | Keypad Button Links, holds, LEDs and keypad settings | proxy, connections, proxy settings | prop |
| L10 | Raise Level By, Restore Saved Level | Hue Light `<commands>` | prog |
| Z1 | A Hue zone or room as one Hue Light | Add Zone Light | click |
| Z2 | Point a zone light at another zone or room | Re-link Zone Light | click |
| Z3 | Release a zone light | Forget Light (listed after the lights), Forget This Light | click |
| Z4 | Zone Lights row | — | auto |
| N1 | Rename every differing light, scene, zone light and motion device to its Hue name | Adopt Hue Names | click |
| N2 | Rename one light, zone light or scene device | Adopt Hue Name (Hue Light, Hue Scene) | click |
| N3 | Keep the Composer names; Attention stays quiet until the Hue name changes again (`name_dismissed`) | Accept Names As They Are | click |
| N4 | A Composer rename shows in Attention at once; Hue names cleaned | OnSystemEvent, `util.display_name` | auto |
| S1 | Add one scene, ordinary or time-of-day | Add Scene | click |
| S2 | Add every scene of a room or zone | Add All Scenes Of Room | click |
| S3 | Point a scene device at another scene | Re-link Scene | click |
| S4 | Release a scene device; its hello is refused afterwards (`hue_scene_forgotten`) | Forget Scene, Forget This Scene | click |
| S5 | Scenes row; scene devices deleted in Composer remembered | — | auto |
| S6 | Scene device: recall, OFF, dimmer, Recall As, On State Follows, time-of-day, keypad | proxy, properties | prop |
| M1 | Add one motion sensor | Add Motion Sensor | click |
| M2 | Add every new sensor whose room is mapped; skip likely replacements, unmapped and deleted ones, and list them | Import All New Motion Sensors | click |
| M3 | Add a MotionAware area (Bridge Pro) | Add Motion Area | click |
| M4 | Point a motion device at another sensor or area (missing, unbound, or unreachable for more than an hour) | Re-link Motion Device | click |
| M5 | Release a motion device; its hello is refused afterwards (`hue_motion_forgotten`) | Forget Motion Device | click |
| M6 | Tester diagnostics: the motion resources and ten minutes of reports, redacted | Log Motion Diagnostics | click |
| M7 | Ask the bridge again for one device's details and state | Refresh From Bridge | click |
| M8 | Fake motion or no motion, to test programming | Test: Motion, Test: No Motion | click |
| M9 | Motion device: contact proxy, hold time, events, conditionals, temperature output, light level, battery; "not supported" on a v2 bridge | properties, events | auto + prop + prog |
| M10 | Motion Sensors row; a low battery in Attention | — | auto |
| G1 | Every action's result in Last Action, wrapped onto rows (2) to (6) | every action | — |
| G2 | Debug Mode, Driver Version and the Documentation tab (with the changelog) on every driver | properties | prop |

## 5. Upgrade safety

### 5.1 What each kind of change does on an update in place

| Change | Projects, programming, bindings | Persisted store | Dev loop, regress.sh, SendToDevice | Evidence |
| --- | --- | --- | --- | --- |
| `<name>` changed, `<command>` kept | nothing | nothing | nothing | §2 (ACTION carries the command) |
| `<command>` changed or action removed | nothing; the tab follows the XML | nothing, but what the old action wrote must still be honoured | old string silently ignored (one debug line, `dispatch.lua:22-26`) unless aliased | dev → release removals; #325 |
| Property added | default for existing devices | — | — | beta 4 |
| Property removed | row and value gone | — | `deploy.py` and the issue forms read some names (§7) | dev → release |
| Property renamed | value lost (assumed); it counts as removal plus addition | — | same | composer §H |
| LIST items changed | the old string stays stored and is replayed (assumed); the driver must map it | — | — | not documented |
| Property that acts on a change (a new SETTING, an "accept" list) | the late-init replay calls its handler with the stored value | — | — | `driver.lua:2309` |
| `<commands>`, events, variables, proxies, connections | **breaks programming or the project** | — | — | FUND `14_…/_2` |
| `<capabilities>` | needs a controller reboot from System Manager | — | — | `docs/status.md:346` |
| New persisted fields in a registry with a schema | fine forward; **dropped by a rollback** to beta 7 or 1.0, gone after re-upgrade | lost | — | `registry.lua:37-45` |

### 5.2 Persisted state an action wrote, and must survive

| Key (store) | Written by | Rule |
| --- | --- | --- |
| `hue_app_key` (encrypted), `hue_bridge_id`, `hue_bridge_ip` | Pair Bridge; Forget Pairing deletes; the IP property | never rename; the bridge id outlives the key on purpose (P2) |
| `hue_lights`, `hue_rooms`, `hue_tombstones` | Add/Import/Re-link/Forget Light, Set Room Mapping, Map Rooms By Name, Accept Names (`name_dismissed`), Composer deletes | shape unchanged; `name_dismissed` and `created_room_id` keep their meaning |
| `hue_rooms_automapped` | the one-time Map Rooms By Name | must stay set; a merged "rooms" task must not run the automap again |
| `hue_scenes`, `hue_scene_tombstones`, `hue_scene_forgotten` | the scene actions, Forget This Scene | the forgotten list keeps refusing hellos |
| `hue_zone_lights`, `hue_zone_light_tombstones` | the zone-light actions | — |
| `hue_motion`, `hue_motion_tombstones`, `hue_motion_forgotten` | the motion actions | — |
| `tls_pinned_on`, `netcheck_pinned_on_v2`, `netcheck_next_binding`, `hue_stream_spelling` | automatic checks and the stream | a check that moves into a scheduler reads the same keys |
| Device drivers: `hue_rid`, `hue_name`, `hue_model`, `hue_kind`, `hue_group_type`, `saved_level`, `held_on`, `recall_as`, keypad keys (`preset_level`, `click_rate_*`, `hold_rate_*`, `button_N_*_color`), `motion_shown`, `motion_values` | CONFIGURE messages, the device's own handlers | not touched by an action change; listed so a device-side merge keeps them |

### 5.3 Migration rules (proposed)

- **R1 Rename = new `<name>`, same `<command>`.** The cheapest rename. The
  `<name>X</name><command>X</command>` assertions in
  `tests/spec/light_driver_spec.lua:794-800` and
  `scene_driver_spec.lua:1195-1205` must relax to "command known". One hardware
  check (step 57) confirms name ≠ command on the house.
- **R2 A command that leaves the XML stays as a hidden alias until 2.0.**
  - One table in `driver.lua`: old key → new handler (or the old handler).
    Last Action is prefixed "<old> is now <new>".
  - It keeps the dev loop, `regress.sh`, old briefs and any `SendToDevice`
    caller working. It costs nothing at run time.
  - Composer research suggests one release. Until 2.0 is safer for a 1.x
    whose testers follow notes of older betas.
  - A removed diagnostic goes into the DEV-ONLY block instead, as the three
    already do.
- **R3 Never rename or reshape a persisted key.**
  - New state (task schedules, "offer dismissed", "last automatic run")
    goes into **new keys**, never as new fields in `hue_lights`,
    `hue_zone_lights` or `hue_motion`.
  - Then a desired-state rollback ignores the new keys, and the next
    upgrade finds them again.
  - Use `_v2` only to disown data on purpose, as netcheck did.
- **R4 Migrations at late init are guarded, idempotent and visible.**
  - A persisted flag names the migration (precedent:
    `hue_rooms_automapped`). The migration runs after the registries load
    and before the first automatic task.
  - It logs with `log.always` and writes one Last Action line.
  - Reading the DIT argument (composer §1.8) is optional: the flag is
    enough.
- **R5 What was a click does not start by itself after the update.** If a
  bulk import or a rename becomes automatic or offered, its first run after
  the update only **offers**. It respects tombstones (the house keeps most
  of its Hue lights deleted on purpose), forgotten lists and
  `name_dismissed`. It never runs on the late-init replay.
- **R6 Replay guard.** Any property whose Set does something ignores the
  late-init replay (`state.late_init_done`, as `list_pick` does at
  `driver.lua:1488-1495`), and ignores a value equal to what it last wrote.
- **R7 LIST properties are read tolerantly.**
  - An unknown stored value means the default, written back with
    `UpdateProperty` at late init.
  - An item string is never reused with a new meaning.
  - Today Debug Mode (`== "On"`, `driver.lua:1195`) and Event Stream
    Transport (`~= "Web transfer"`, `driver.lua:300`) already read this way.
- **R8 Mixed versions of the four drivers.**
  - Every `HUE_*` handler stays in the bridge for all of 1.x.
  - Device-driver texts that name bridge actions change in the same
    release as the bridge (Link Devices, Add Light and Add Scene, in
    `hue_light/driver.lua:56,212,216`, `hue_scene/driver.lua:179,193,197`
    and `hue_motion/driver.lua:107`). The brief already installs all four
    at once.
- **R9 Say it once, where people look.** Each release that renames or folds
  an action gets:
  - a "Renamed" or "Moved" line under `## Unreleased` with old → new;
  - the same list in the release notes and in a comment on the tester's
    issue;
  - the manual's quick reference updated in the same PR.

### 5.4 What must be tested before such a release

- **Specs.** The four round trips (`roundtrip`, `scene_roundtrip`,
  `zone_light_roundtrip`, `motion_roundtrip`), the new ledger spec and alias
  spec (§6.2), and an **upgrade spec**:
  - It loads a beta 7 store fixture: every key of §5.2, plus Composer's
    Properties with the list summaries, Last Action rows and LIST values.
  - It starts the new build: `OnDriverInit` and `OnDriverLateInit`, then
    one resync.
  - It asserts that registries, mappings, tombstones, forgotten lists,
    accepted names, the automap flag and the pairing are unchanged.
  - It asserts that no `AddDevice`, `RenameDevice`, `Bind` or unbind
    happened.
- **Composer.**
  - `docs/composer-checklist.md` steps 1-2 (update in place), 16-18
    (properties and the Actions tab, with the new list in order) and one
    click per merged action.
  - `docs/release-checklist.md` §2.1-2.3 (the count).
  - The motion steps 52-54 and 56-57.
  - The tester's steps 61-64, whose wording changes.

## 6. Test impact

### 6.1 What a change touches in `tests/spec`

| Change | Specs that must change | Size |
| --- | --- | --- |
| Shown name only (R1) | the XML assertions: `light_driver_spec:794`, `scene_driver_spec:1195`, `drivers_spec:1613` (motion list), `motion_roundtrip_spec:459` | 1-4 lines per action |
| Command renamed or merged (R2) | the "runs" column of §3 moves to the new command; the old strings become alias tests | 0-13 lines per action |
| Remedy texts reworded (Attention, Last Action, Status) | the "mentions" column of §3: lights (16 lines on Add Light alone), scenes, zone_lights, motion, owner, light_driver, scene_driver | 0-33 lines per action, about 375 in all |
| Action becomes automatic or offered | a scheduler spec (owned by the scheduler research); the module methods and their specs stay as they are | new |
| Action becomes a setting | `drivers_spec` property defaults (pattern: `drivers_spec:101`); a replay-guard test (R6) | new |
| Action removed (RETIRE) | its runs become "answers through the alias" or "absent from the release XML" | small |

The module-level specs (`lights_spec`, `scenes_spec`, `zone_lights_spec`,
`motion_spec`, `owner_spec`, about 440 tests together) call methods like
`add_light`, `relink`, `forget`, `adopt_hue_names` directly. They survive
any regrouping of actions as long as the methods stay. That is the reason
to merge in `driver.lua` and keep the modules' API.

### 6.2 A conformance spec for the ledger (proposed: `tests/spec/ledger_spec.lua`)

The data lives in `tests/fixtures/feature_ledger.lua`, one entry per §4 row:
`{ id, what, paths = { {action=…, driver=…, params={…}} | {property=…} | {command=…} | {event=…} | {task=…, off=…} | {alias=…, until="2.0"} }, gate = "click"|"offered"|"auto"|… }`.
The table in §4 moves there and becomes the one copy; this document then
links to it. Current (2026-11-13, #478): built in 1.2 as
`tests/spec/ledger_spec.lua`, with the data in `tests/fixtures/ledger.lua`
(not `feature_ledger.lua`); §4 stays here as the copy of 2026-11-04.

The spec asserts:

1. **XML ↔ handlers, release build too.**
   - For each driver, parse `driver.xml` and its release form (the
     DEV-ONLY strip of `tools/build.sh:115`, as
     `tests/spec/devloop_spec.lua:2216-2230` already does).
   - Every `<action>` has a dispatch handler under its command.
   - Clicking it on an unpaired fake bridge writes Last Action or Status
     and raises nothing.
   - This extends `drivers_spec:1613` from the motion driver to all four.
2. **No orphans.** Every release action belongs to at least one ledger
   row, and every row has at least one path that resolves:
   - an action: in the release XML, with those parameter names;
   - a property: declared;
   - a command: in `<commands>`;
   - an event: in `<events>`;
   - a task: registered in the scheduler, with its off switch declared;
   - an alias: in the dispatch table and absent from the XML.
3. **Behaviour probes.** Each row names a probe that runs the path in the
   fake harness against `tests/fixtures/hue_resources.lua`. It asserts the
   observable effect: `AddDevice` in the right room, a registry entry, a
   stored mapping, `RenameDevice`, the Last Action pattern. Write the
   probes first for the 9 actions no spec dispatches today.
4. **Gates.** Run the background engine for a simulated week with fake
   timers. The fixture holds new lights, name differences, unmapped rooms,
   gone and unbound devices, tombstones and forgotten devices, and every
   setting is at its default. Assert that no `AddDevice`, `RenameDevice`,
   `Bind`, unbind, relink or forget happened except on rows marked
   automatic. This makes principle 1 a test.
5. **Aliases expire on purpose.**
   - Every alias has a target handler and an `until` version, and is
     absent from the XML.
   - The spec fails once the version in `CHANGELOG.md` reaches `until`, so
     removing the alias is a decision, not an accident.
6. **The manual agrees.** The quick-reference tables of chapter 13
   (`src/hue_bridge/www/documentation.html`) and the device pages list
   exactly the release actions, in `sort_order`. This catches today's
   "22" kind of drift in the manual. The checklists stay prose.

The spec runs in `tools/check.sh` with the rest of `busted tests`, so CI's
required checks enforce it with no new job.

## 7. Do not touch (names baked into other things)

| What | Baked into | Cost of a change |
| --- | --- | --- |
| Driver file names `hue_bridge.c4z`, `hue_light.c4z`, `hue_scene.c4z`, `hue_motion.c4z` | Composer's driver identity; `GetDevicesByC4iName` and `LIGHT_DRIVER` in the modules; `deploy/house.yaml`; release assets | a new driver: every device re-added, pairing lost |
| Proxies, connections, binding ids (1 HUE_BRIDGE, 5001, 6001, Button Links) | every project | project corruption (FUND `14_…/_2`) |
| Hue Light `<commands>` Raise Level By, Restore Saved Level and their parameters Points, Ramp (ms) | the house's motion programming (`docs/status.md:77-82`) and the tester's | programming silently broken |
| Hue Motion `<events>`, conditionals and variables | dealers' programming | same |
| The `HUE_*` messages between drivers | the four drivers across versions | a device stops talking to the bridge during a partial update |
| Persisted keys (§5.2) | the stores on every controller | pairing, devices and choices lost |
| Properties the dealer sets: Bridge IP Address, Debug Mode, Stream Timeout (s), Stream Watchdog (s), Event Stream Transport, Recall As, On State Follows, Occupancy Hold Time (s), the proxy's keypad settings | Composer project values | the value is lost on rename |
| Properties read by tools and forms: Driver Version, Stream Timeout (s), Stream Watchdog (s), Debug Mode (`tools/deploy.py:1020-1032`, `deploy/house.yaml`); Status, Attention, Event Stream, Last Action (2) to (6) (`.github/ISSUE_TEMPLATE/bug_report.yml:68-69`, `beta-feedback.yml:69`) | the deploy flow and bug reports | `deploy.py` and its tests change, and the forms change |
| Test Connection | `bug_report.yml:15` ("Click Test Connection first"), manual chapters 4 and 12, `regress.sh`, 1.0 notes | keep the name or an alias; change the form in the same PR |
| Log Motion Diagnostics, Add Motion Sensor, Add Motion Area, Import All New Motion Sensors, Refresh All | the tester's steps (#305, #309, checklist 61-72), β1-7 notes, manual 14.15 | his next round follows old words. Import All New Motion Sensors was renamed on 2026-10-28 at his request: renaming it again inside 1.1 spends that goodwill |
| Pair Bridge, Forget Pairing | 1.0 notes ×3 each; the refusal text "run Forget Pairing first" (`pairing.lua:105`); manual chapter 4 | small, but these are the most-read words of the manual |
| Connection Test, Reload Credentials, Check CA Pinning | `tools/devctl.py:12,23,444`, `tools/tests/test_devctl.py:145`, `docs/dev-loop.md:345`, `tests/spec/devloop_spec.lua:2286` | dev tooling only; no reason to touch them |
| Adopt Hue Names, Accept Names As They Are, Link Devices, Room Audit, Refresh Scenes, Test Connection | `tools/regress.sh:49-71` runs them **on the house** through the dev loop (Adopt Hue Names renames devices there) | rewrite regress.sh in the same PR as any change to them |

## 8. Verdicts where compatibility alone decides

The family verdicts belong to the import, maintenance and composer research.
Every verdict there carries the compatibility constraints below:

- R1 or R2 for any rename, merge or removal;
- R3 to R7 for any automatic or setting replacement;
- §7 for the names listed there.

| Action | Verdict | Reason |
| --- | --- | --- |
| Connection Test | **MOVE to diagnostics** (already: DEV-ONLY) | Absent from release builds. Only `devctl.py`, its test, `dev-loop.md` and `devloop_spec` use it. Leave it as it is. |
| Reload Credentials | **MOVE to diagnostics** (already: DEV-ONLY) | Same. It does not count towards the 29 a release shows. |
| Check CA Pinning | **MOVE to diagnostics** (already: DEV-ONLY) | Same. `docs/release-checklist.md` §4 uses it in dev builds. |
| Import All New Motion Sensors | **KEEP** (the name, for all of 1.1) | Renamed in beta 7 at the tester's request. Whether it becomes automatic is for the import research. Its command stays either way. |
| Test Connection | **KEEP** (the command; R2 if it moves) | The bug-report form tells users to click it. A move into a Diagnostics action keeps `Test Connection` as the command or an alias, and changes the form in the same PR. |
| All other 34 | no compatibility verdict | Owned by the other research. Each must name its ledger rows (§4) and follow R1-R9. |

## 9. Risks and open questions for the owner

1. **When does this ship?** Recommended: **1.2**, after 1.1 is released.
   1.1 betas are with an outside tester whose steps name eight bridge
   actions, and beta 8 should change nothing he relies on. Answer:
   "1.2" or "beta 8".
2. **How long do aliases live?** Recommended: **until 2.0** (R2). The
   composer research says one release; the cost is one table. Answer:
   "2.0" or "one release".
3. **Ledger spec before any action change?** Recommended: **yes**, as its
   own PR first, with probes for the 9 actions no spec dispatches today.
   Answer: "yes".
4. **Which number to cut?** Recommended: measure on a **release build (29
   today)**, not the dev build's 32. Answer: "29".
5. **The stale "22 actions" pages and picture?** Recommended: fix the three
   checklists now, and retake `bridge-actions.png` once, after the
   simplification. Answer: "after".
6. **`regress.sh` renames devices on the house** (Adopt Hue Names, Accept
   Names). Recommended: make it read-only when those actions change
   (Attention and the counts instead of the clicks). Answer: "read-only".
7. **No "Forget This" on the motion device** while light and scene devices
   have one. Recommended: leave it; Forget Motion Device covers it, and
   adding an action is the opposite of this issue. Answer: "leave".
8. **Hardware check of name ≠ command** (Test: Motion, step 57) before
   relying on R1. Recommended: one click on the house's motion device during
   the next round; it trips the house's motion programming once (two lamps
   rise and come back within a minute), which is harmless. Answer: "yes".
