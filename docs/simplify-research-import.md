# Simplify research: import, linking, names and rooms (#334)

Research file of the `import` agent for [the simplification contract](simplify-actions-design.md)
(§0.5). Read-only research, 2026-11-04, against `main` = beta 7 (build 425).
Scope: the Hue Bridge's 17 actions for lights, zone lights, scenes, names and
rooms; the Hue Light's and Hue Scene's two actions each; the list properties
`Lights`, `Scenes`, `Zone Lights` and `Room Mappings`. Motion actions belong to
the maintenance research; where a merge here would take them in, it says so.

Abbreviations for the sources reused below: **IMP** [import-design.md](import-design.md),
**UX** [edge-cases-ux.md](edge-cases-ux.md), **HUE** [edge-cases-hue.md](edge-cases-hue.md),
**C4** [edge-cases-control4.md](edge-cases-control4.md), **ZL** [zone-light-design.md](zone-light-design.md),
**SC** [scenes-design.md](scenes-design.md), **API**/**FUND**/**XML** the SDK trees under
`~/c4-tools/reference/docs-driverworks-{api,fundamentals,xml}/source/includes/`.

## 1. Findings

1. **21 actions collapse to 5, and no capability is lost.** Add From Hue (one
   dialog for lights, zone/room lights and scenes, single or bulk), Link Device
   (every re-link and Link Devices, with the driver's own suggestion
   pre-chosen), Resolve Names (rename or keep, per device or all), Set Room
   Mapping (kept), Forget Device (all kinds). The two child drivers end with no
   actions at all. Table in §7.
2. **Device creation cannot become a background task.** The SDK says AddDevice
   is to run only on a user's action (E1). "Import" stays a click; what shrinks
   is the number of dialogs: bulk rows ("All 3 new lights", "All 7 scenes of
   Kitchen") sit inside the one picker.
3. **Four things the owner clicks today can run on their own at no bridge
   cost:** room mapping by exact name (today it runs once per install), the
   Room Audit (shown as a marker on the list rows), scene catalogue refresh
   (the event stream already keeps it live; Refresh All covers a down stream),
   and accepting a name difference the owner made himself in Composer
   (Control4 is the source of truth, so his rename is the answer).
4. **Hue renames stay offered by default.** A setting `Names From Hue` = `Ask`
   (today) or `Follow` renames a device in Composer only when its Composer
   name still equals the previous Hue name, so a hand-set name is never
   overwritten.
5. **Re-link becomes mostly one click, but stays a click.** The driver already
   spots a re-added bulb by its radio (MAC) or name (E18); scenes, zones and
   rooms get the same by unique name in the same group. "(every device with a
   suggested match)" re-links a whole factory-reset bridge in one dialog,
   instead of 47 dialogs. Automatic re-linking stays forbidden until the MAC
   assumption (E19) is proved on hardware.
6. **The lists do not carry selections today** (a pick snaps back, E10), and
   should not start to: a pick has no context, no OK and needs Composer's Set
   (E11). They stay the at-a-glance status, plus the audit marker.
7. **The whole proposal leans on one Composer assumption:** CUSTOM_SELECT
   *Folder* trees on Composer 3.4.2 (E4). With it, Add From Hue is one action.
   Without it, the fallback is three Add actions with bulk rows (7 actions in
   total, still a third of today).
8. **Two small data changes protect hand-made choices:** a room mapping
   records how it was made (`hand`, `name`, `none`), and removing a mapping
   records `none` instead of deleting it, so automatic mapping never undoes
   the owner (today a removal is indistinguishable from "never mapped", E15).
9. **Nothing here needs REST over TCP, a capability change or a reboot.**
   Actions live in `<config>` (E9). Every new background task costs zero
   bridge requests; only bulk light import reads the bridge (6 serial GETs,
   as today).

## 2. The actions today

| Action | Does | Reads → writes | Bridge requests |
| --- | --- | --- | --- |
| Add Light | One AddDevice for the picked light, into the picked room or its Hue room's mapping; refuses with neither; clears a tombstone (`lights.lua:1170`) | light catalogue, mappings, rooms → registry, project | 0 |
| Import All New Lights | The six GETs, reconcile, then AddDevice for every new light that is not tombstoned and has a mapped room; lists the rest (`lights.lua:1226-1323`) | as above | 6, serial |
| Add Zone Light | One AddDevice of a Hue Light of kind group for a zone or room (`zone_lights.lua:1221`) | group cache → zone registry, project | 0 |
| Re-link Device To Light | Swaps the rid of a gone or unbound light entry; CONFIGURE and STATE (`owner.lua:1446`) | registry → registry, device | 0 |
| Re-link Zone Light | The same for zone-light devices, cross-kind refused (ZL §8.6) | zone registry | 0 |
| Link Devices | Adopts bound devices the registries lack, by announced rid, else exact unique name, in all four modules (`driver.lua:1621-1628`, `owner.lua:1613`) | bound list, project → registries | 0 |
| Forget Light | Drops a light or zone-light entry, `C4:Unbind`, HUE_FORGOTTEN (`driver.lua:1630`, `owner.lua:1506`) | registry → registry, binding | 0 |
| Adopt Hue Names | RenameDevice to the expected name for every difference, accepted ones included, four modules (`owner.lua:1239`) | registries, Composer names → project names | 0 |
| Accept Names As They Are | Records `name_dismissed` for every current difference (`owner.lua:1284`) | → registries | 0 |
| Set Room Mapping | Writes, or with "(no mapping)" deletes, a Hue group → Control4 room mapping (`lights.lua:1422-1475`) | → `hue_rooms` | 0 |
| Map Rooms By Name | Exact, case-insensitive, trimmed, unique matches for unmapped groups; never overrides (`lights.lua:1480`) | groups, rooms → `hue_rooms` | 0 |
| Room Audit | One `GetDevices` call; lists devices whose room differs from their group's mapping (`lights.lua:1560`) | project → Last Action | 0 |
| Add Scene | One AddDevice of a Hue Scene (`scenes.lua:2005`) | catalogue → scene registry, project | 0 |
| Add All Scenes Of Room | AddDevice for every scene of one group that is not imported or tombstoned, into its mapping (`scenes.lua:2061`) | as above | 0 |
| Re-link Scene | Swaps a scene entry's rid (`owner.lua:1446`) | scene registry | 0 |
| Forget Scene | Drops, unbinds, remembers the forgotten device (SC §4, #47 F8) | scene registry | 0 |
| Refresh Scenes | GET `/scene`, `/smart_scene`, `/grouped_light`, then reconcile (`driver.lua:1930`, `scenes.lua:580`) | → scene catalogue | 3, serial |
| Hue Light / Hue Scene: Adopt Hue Name | Renames its own proxy to the expected name; needs no pairing (`hue_light/driver.lua:590`, `hue_scene/driver.lua:1091`) | own state → project name | 0 |
| Hue Light / Hue Scene: Forget This … | Sends HUE_FORGET to its bridge; refused while unbound (`hue_light/driver.lua:607`, `hue_scene/driver.lua:1114`) | → bridge's Forget | 0 |
| `Lights`, `Scenes`, `Zone Lights` (lists) | Summary row plus one line per item; refreshed after every action, resync, event, Composer rename and every 5 min (`driver.lua:1489-1504`, `2293`) | registries, catalogues | 0 |
| `Room Mappings` (list) | "N Hue rooms and zones; N unmapped" plus "Hue → Control4" lines | `hue_rooms`, groups | 0 |

## 3. Evidence

Each claim: **V** verified (code, docs, spec or hardware report), **A** assumed.

- **E1 V** AddDevice and AddLocation should run only on a dealer's or user's action, or drivers may add themselves recursively: `API 9_helper/_0.1-AddDevice.md:3`.
- **E2 V** `C4:RenameDevice` takes the proxy id; a rename refreshes the project and does not work in OnDriverInit: `API 22_miscellaneous/_32-RenameDevice.md`.
- **E3 V** No API moves a device between rooms or deletes one (IMP §1, from a sweep of the API docs).
- **E4 V/A** CUSTOM_SELECT offers List, Search, Filter, **Folder** (tree view; entries `{text, value, folder = true}`; the function gets the folder name and returns the list and a "back" folder), Async: `FUND 12.3_custom_select_implementation/_1-Overview.md` (types; entry shape line 258) and `_5-CUSTOMSELECTFOLDER.md`. Only Search and Filter are called inconsistent before OS 4.0 there (V). **A:** Folder renders and returns a leaf's value in Composer Pro 3.4.2's action dialog; never tried on the house.
- **E5 V** CUSTOM_SELECT List params on actions render on Composer 3.4.2, and a sentinel value resolved at OK works: "(mapped room)" has value `mapped` because an empty value disables OK (IMP §8, §13 note; `lights.lua:1807` comment; hardware 2026-10-22).
- **E6 A** A picker function cannot see what another param of the same dialog holds (the docs pass only the folder name, E4). Hence the "(suggested match)" sentinel in §5.2.
- **E7 V/A** A static `LIST` action param exists (`XML 30_actions/_40-paramtype.md`); the drivers use one only in the dev-build Connection Test (`driver.xml:525-537`). **A:** renders on 3.4.2. The proposal avoids needing it.
- **E8 A** The XML docs' CUSTOM_SELECT example says several items can be selected (`_40-paramtype.md`); the value format of a multi-pick is undocumented. Not relied on.
- **E9 V** Actions sit in `<config>`, not `<capabilities>` (`src/hue_light/driver.xml:17,80-93,152`; `src/hue_bridge/driver.xml:234-559`); only a capability change needs the controller reboot (`docs/status.md`, "How builds reach the house").
- **E10 V** The four lists and Room Mappings carry no selection: "a pick changes nothing" (`driver.xml:81-82`); `list_pick` puts the row back (`driver.lua:1489-1504`).
- **E11 V** A property edit commits only through the row's Set button (hardware, `docs/design.md:1163`).
- **E12 V** A Composer rename fires `OnItemNameChanged` with the **proxy** id, the new name and the room (hardware 2026-10-21, `docs/design.md:1134-1142`); the bridge refreshes its rows on it (`driver.lua:2197-2206`).
- **E13 A** `OnItemMoved` is registered (`driver.lua:2177`) but was never seen on hardware (C4 1.4). The 5-minute row timer (E14) is the fallback.
- **E14 V** The rows refresh every 5 minutes, sent only when changed (`driver.lua:2286-2293`).
- **E15 V** Map Rooms By Name runs once per install at the first resync, behind the persisted key `hue_rooms_automapped` (`lights.lua:57`, `922-951`); Set Room Mapping "(no mapping)" deletes the record (`lights.lua:1440-1450`).
- **E16 V** Map Rooms By Name: exact, case-insensitive, trimmed; a Control4 name two rooms share is skipped; never overrides (`lights.lua:1480-1556`).
- **E17 V** Room Audit costs one local `GetDevices({DeviceIds})` and no bridge request (`lights.lua:1560-1635`).
- **E18 V** A new light gets a re-link hint from a gone entry with the same MAC, else the same name, **first match wins** (`lights.lua:467-482`); the hint shows in Attention and first in Add Light's list (`lights.lua:1659-1670`, `1771-1800`). Scenes and zone lights have no hint (no such function in `scenes.lua`, `zone_lights.lua`).
- **E19 A** A bulb deleted and re-added in Hue keeps its `zigbee_connectivity.mac_address` but gets new rids (HUE §1 row 4; spare-bulb probe 11 of IMP §11 never run).
- **E20 V** The scene catalogue follows `scene` add, delete and update items live (`scenes.lua:1322-1377`); every stream connect resyncs; Refresh All runs all four resyncs (`driver.lua:716-742`, `1917-1928`). GETs: lights 6 (`lights.lua:126-133`), scenes 3 (`scenes.lua:580-616`), zone lights reuse the scenes' `/grouped_light` (`zone_lights.lua:771-775`).
- **E21 V** A bound device announcing a rid the registry lacks is adopted at its hello (automatic), a tombstone for that rid is cleared, two claimants adopt nothing and go to Attention (`owner.lua:486-591`; IMP §4).
- **E22 V** Name differences compare display names; Adopt renames accepted ones too and clears the acceptance; Accept records the Hue name accepted (`owner.lua:1212-1308`).
- **E23 V** The bridge's actions all start with `can()` (paired), the child Adopt Hue Name does not (`driver.lua:1506-1512`; `hue_light/driver.lua:590-602`).
- **E24 V** REST requests use `C4:url`, one transfer per host at a time, serialized (`docs/design.md:351-362`, `commands.lua:5-6`). Nothing proposed here depends on moving REST to the TCP module; bulk import's 6 GETs would only finish sooner.
- **E25 V** No programming depends on action names (owner-approved, [list-rows-design.md](list-rows-design.md) §1, #325).
- **E26 V** Gone entries are never dropped by the driver; tombstones are skipped by bulk adds and re-created only by a single add (IMP §3).
- **E27 V** There is deliberately no "Add All Zones" (ZL §8.1, Q3: 23 devices in one click).
- **E28 V** A forgotten scene device is remembered; its hello is refused and Link Devices links it to the scene it remembers (SC §4, #47 F8). Forgotten light devices are adopted again when reconnected.

## 4. Lifecycle edge cases

Columns as the contract asks. "Today" cites where the case is already
decided; **new** marks a case the earlier documents miss. Classes: **auto**
(automatic), **offered** (the driver proposes, one click accepts), **click**
(forbidden without a click).

| # | Case | Side | Detected by | Today | Proposed | Why |
| --- | --- | --- | --- | --- | --- | --- |
| H1 | Light paired in the Hue app | Hue | `add` items; resync | Cached, counted new, Attention names it (UX §1, `lights.lua:1659`) | **click**: Add From Hue ▸ Lights (single or "All new") | E1; a test bulb must not become a device |
| H2 | Light in no Hue room | Hue | resync (no room child) | Listed "(no room)"; bulk import skips it (`lights.lua:1257-1275`) | **click**: single add with a room picked | no mapping to apply |
| H3 | Light renamed in Hue | Hue | `device` update; resync | Hue Name refreshed; Attention difference (`owner.lua:1212`) | **offered** (`Ask`); **auto** in `Follow` only if the Composer name equals the old Hue name | principle 1: a hand-set name is never overwritten |
| H4 | Default name renamed in Hue soon after import (common) | Hue | as H3 | Attention difference | as H3; this is what `Follow` is for | **new** |
| H5 | Light moved between Hue rooms | Hue | `room` updates | `Hue Room` updated; mismatch only on a Room Audit click (UX §3) | **auto** display: marker on the list row; device never moved | E3, no move API |
| H6 | Light deleted in Hue | Hue | `delete`; a full GET lacks it | `gone`, offline, Attention (IMP §3) | **auto** as today; Link or Forget **offered** | programming survives (E26) |
| H7 | Same rid back (Hue backup restored) | Hue | resync | gone → linked by itself (manual 8.3) | **auto** (unchanged) | same identity |
| H8 | Same bulb re-added: new rid, same radio | Hue | `add` + MAC | Hint; one Re-link dialog per light (E18) | **offered**: Link Device "(suggested)" or "(every device with a suggested match)" | E19 still assumed |
| H9 | Different bulb, same name | Hue | `add`; name | Hint by name, first match wins (E18) | **offered**, suggested only when the name match is unique | duplicate names are normal (HUE §6) |
| H10 | Different bulb, different name | Hue | — | Re-link by hand | **click**: Link Device, pick the light | no evidence to suggest |
| H11 | Multi-light device re-added (two lights, one MAC) | Hue | MAC shared | Hint takes the first gone entry with the MAC (`lights.lua:470-478`) | suggest only when `service_id` matches too | **new**; a wrong pair would swap front and back lights |
| H12 | Two Hue lights with one name | Hue | names | Labels carry `#id_v1`; name links need a unique match (UX §2) | unchanged; no suggestion from a shared name | never key on names |
| H13 | Light unreachable for days | Hue | `zigbee_connectivity` | Offline; Attention after 24 h (`lights.lua:61`) | unchanged | wall-switched lamps |
| R1 | Hue room or zone created | Hue | `add`; resync | Unmapped until a click (E15) | **auto**: mapped by exact unique name when a Control4 room matches | affects only future adds and the marker |
| R2 | Hue room renamed | Hue | `update` | Labels refresh; mapping kept by rid (UX §3) | as today; a still-unmapped group may now match → **auto**; "<Room> Lights" device name → names policy | |
| R3 | Hue room or zone deleted | Hue | `delete` | Mapping kept "(deleted in Hue)"; its scenes and zone light gone (UX §3, ZL §4) | unchanged; Link or Forget **offered** | |
| R4 | Room deleted and re-created with the same name | Hue | `delete` + `add` | Old mapping orphaned, new group unmapped; devices gone with no hint | new group **auto**-mapped by name; zone light and scenes get a "(suggested)" link by unique name and kind (**offered**) | **new** |
| R5 | Zone membership changes, emptied, refilled | Hue | `zone` update | Capabilities recomputed; empty = offline (ZL Decisions 7, 11) | unchanged **auto** | no project change |
| R6 | Two Control4 rooms carry the Hue room's name | both | name match | Skipped as ambiguous (E16) | skipped; Room Mappings line says "2 Control4 rooms match" (**offered** via Set Room Mapping) | a guess puts devices in the wrong room |
| S1 | Scene created in Hue | Hue | `add` | Listed in Add Scene; no Attention (`scenes.lua:1325-1335`) | **click**: Add From Hue ▸ Scenes; still no Attention | Hue makes ~7 per room (SC §1) |
| S2 | Scene or time-based scene renamed | Hue | `update` | Difference listed | names policy (as H3) | |
| S3 | Scene deleted | Hue | `delete` | `gone`; ON reports off; Attention (SC §1) | unchanged; Link or Forget **offered** | |
| S4 | Scene deleted and re-made with the same name in the same group | Hue | `delete` + `add` | Re-link Scene by hand, no hint | **offered**: "(suggested)" by unique name in the same group | **new** |
| S5 | Scene copied to another room | Hue | `add` | A new scene | unchanged; no suggestion across groups | not a replacement |
| S6 | Scenes changed while the stream was down | Hue | reconnect resync; Refresh All | Refresh Scenes or Refresh All (#324) | **auto** at reconnect; Refresh All (or the maintenance research's periodic resync) | E20 |
| B1 | Bridge factory reset, re-paired | Hue | 403, then every rid missing | All gone; hints; one dialog per device (HUE §4) | **offered**: one "(every device with a suggested match)" click | 47 dialogs today |
| B2 | Bridge replaced by Hue's transfer | Hue | identity check | Pair refuses until Forget Pairing (#236); then as B1, or rids kept → auto | unchanged (maintenance scope) | |
| B3 | Bridge restored to an older Hue backup | Hue | resync | Newer lights gone, older back | unchanged | |
| C1 | Device deleted in Composer | C4 | HUE_GOODBYE; reconcile | Tombstone; bulk adds skip it (IMP §3) | **auto** (unchanged); a single add re-creates it | the owner deleted it |
| C2 | Device renamed in Composer | C4 | `OnItemNameChanged` (E12) | Attention lists it until Adopt or Accept | **auto**: recorded as accepted | **new**; principle 1, his rename is the answer |
| C3 | Device moved to another Control4 room | C4 | `OnItemMoved` (E13, A); 5-min refresh | Nothing until Room Audit | **auto** display marker; never moved back | the Control4 room is his |
| C4 | Bare Hue Light added by hand and bound | C4 | rid-less hello; reconcile | Link Devices by exact unique name (IMP §6) | **offered**: Link Device "(suggested)" | name alone is weak evidence |
| C5 | Device unbound in Connections | C4 | `OnBindingChanged` | `unbound`; Attention (IMP §3) | unchanged; rebind or Forget | |
| C6 | Two devices claim one rid | C4 | hello conflict | Attention; Forget on one (E21) | unchanged | |
| C7 | Forgotten scene device reconnected | C4 | refused hello | Link Devices links it (E28) | **offered**: its remembered scene is the "(suggested)" target | |
| C8 | AddDevice returns 0 | C4 | callback | Listed, chain continues (C4 1.10) | unchanged | |
| CR1 | Control4 room created | C4 | `OnItemAdded` for a room (A: seen only for devices, `docs/design.md:1154-1162`); 5-min refresh | Appears in pickers | **auto**: maps groups first seen after the update; older unmapped ones **offered** | see §5.4 baseline |
| CR2 | Control4 room renamed | C4 | `OnItemNameChanged` | Mapping by id; label refresh | as CR1 for unmapped groups | |
| CR3 | Mapped Control4 room deleted | C4 | room id missing | Attention "points at a Control4 room that no longer exists" (`lights.lua:1677-1690`) | mapping made by name: **auto** re-map to a unique match; made by hand: **offered** | never replace his choice |
| CR4 | Mapping removed by hand | C4 | action | The record is deleted (E15) | record `none`; never re-mapped automatically | **new**; else automation undoes him |
| P1 | Bridge driver updated in place | C4 | DIT_UPDATING | Everything persists (C4 3.4) | unchanged; new settings default to today's behaviour; baseline of §5.4 | principle 5 |
| P2 | Bridge driver deleted and re-added | C4 | empty store | Re-pair; bind the devices; auto-adopt by rid (C4 1.8) | plus **auto** name mapping refills `hue_rooms`; lost acceptances listed again (**offered**) | recovery gets easier |
| P3 | Project restored from a backup | C4 | DIT_STARTUP | Devices with a rid adopted; a restored device's tombstone cleared (E21) | unchanged | |
| P4 | Project copied to a second controller on the same bridge | C4 | — | not covered | each copy keeps its own registry and automation; no Hue writes, so nothing collides | **new** |
| P5 | Two projects paired to one bridge | both | — | not covered | independent; their request budgets add up at the bridge | **new** |
| P6 | Driver renames while Composer is open (`Follow`) | C4 | — | — | one RenameDevice at a time, paced, never in OnDriverInit (E2) | **new**; each rename refreshes the project |

## 5. Proposal

### 5.1 Add From Hue (replaces five actions)

Params `What` (CUSTOM_SELECT Folder, E4) and `Room` (today's `RoomList`,
"(mapped room)" first). The tree, built from the catalogues in memory:

- `Lights (3 new)` ▸ first row "All 3 new lights → their mapped rooms"
  (today's Import All New Lights, same skips and texts), then a folder per Hue
  room ("Office (2 new)") whose first row adds that room's new lights, then
  each light as today's `picker_lights` writes it (hinted first, tombstoned
  last).
- `Zones and rooms (23)` ▸ today's `picker_groups` rows (no bulk row, E27).
- `Scenes (129 + 15 time-based)` ▸ a folder per group as `picker_groups`
  labels it ▸ "All 5 scenes of Kitchen not imported yet", then each scene.
- If the maintenance research merges motion, `Motion sensors and areas` fits
  the same tree.

Values carry the kind: `light:<rid>`, `lights:new`, `lights:new:<group>`,
`group:<rid>`, `scene:<rid>`, `scenes:<group>`; the handler routes to the
module that owns it today, so every text, refusal and guard stays. A bulk row
uses the mappings, as today, and says so; `Room` applies to single rows.
Requests: bulk lights 6 serial GETs, everything else 0.

**Fallback** if Folder misbehaves on Composer 3.4.2: keep `Add Light` with an
"All N new lights" row first (absorbs Import All New Lights), `Add Zone Light`
unchanged, `Add Scene` with an "All scenes of <group>" row heading each group
(absorbs Add All Scenes Of Room).

### 5.2 Link Device (replaces four bridge actions)

Params `Device` and `To` (both CUSTOM_SELECT). `Device` lists, first, "(every
device with a suggested match: N)", then every gone, unbound, unlinked (bound,
no entry) and forgotten-but-bound device of the lights, zone lights and scenes
(and motion if the maintenance research agrees), each with its suggestion in
the text: "Lamp 5 (device 1213, gone since 10-22) → Lamp 5 [Bedroom] #9, same
radio". `To` starts with "(the suggested match)" (a sentinel resolved at OK,
the "(mapped room)" pattern, E5, E6), then the resources with no device, by
kind.

A suggestion is made only when all hold (so it is evidence, not a guess):
same kind; for a light the same MAC and `service_id` (H11), else a unique
exact display name; for a scene a unique name in the same group; for a zone
or room a unique name; for a forgotten scene device the scene it remembers;
the target has no device and no tombstone; and no other device gets the same
target. Kind mismatch is refused, as today (ZL §8.6). The bulk row applies
only suggestions and reports each line. Requests: 0. Attention's hints change
to "(Link Device or Forget Device)".

### 5.3 Names: one automatic rule, one setting, one action

- **Automatic:** a Composer rename (`OnItemNameChanged`, proxy id of a
  registered device, E12) records the current Hue name as accepted for that
  device, exactly what Accept does today for one device. The driver's own
  renames end equal to the expected name, so they record nothing.
- **Setting `Names From Hue`:** `Ask` (default, today's behaviour) or
  `Follow`: when the bridge learns a new Hue name for a linked device (event or
  resync) and its Composer name still equals the display name of the
  previous expected name, the driver renames it (one RenameDevice at a time,
  at most one every 2 s, logged, never in OnDriverInit, E2); anything else is
  listed as today. Stoppable by setting `Ask`.
- **Action `Resolve Names`**, one param `Answer`: "Rename all N to their Hue
  names" (today's Adopt Hue Names, accepted ones included, E22), "Keep all N
  Composer names" (Accept), then a pair of rows per device ("Rename Reading
  Lamp → Lamp 1", "Keep Reading Lamp"), accepted ones with only the rename row.
  It runs while unpaired, as the child action does (E23). Requests: 0.

### 5.4 Rooms: name mapping and the audit run on their own

- **Automatic mapping by name**, at every resync settle (where
  `automap_once` runs today), on a Hue group's add or rename, on a Control4
  room's add or rename, and at the 5-minute row tick. Rules of E16, plus: only
  groups with no mapping record; never over `hand` or `none`; a dead `name`
  mapping is re-mapped to a unique match (CR3). Each mapping records `how` =
  `hand` | `name` | `none`; "(no mapping)" writes `none` (CR4). Cost: one
  local `GetDevicesByC4iName`, no bridge request. Shown as "Office → Office
  (by name)" in Room Mappings and in the log.
- **Upgrade baseline:** at the first settle of the new build every group
  that is cached and unmapped is recorded `none (as found)`, because a removal
  made under the old build looks the same as "never mapped". Those are
  **offered** instead: "Porch → (unmapped; Control4 room Porch matches)", the
  match first in Set Room Mapping's Room list.
- **Audit as a display:** a device whose Control4 room differs from its
  group's mapping gets " (in Hall)" on its `Lights` or `Zone Lights` line, and
  Room Mappings' summary adds "; 2 devices elsewhere". No Attention item
  (UX §3: one line, no nagging). Cost: one local `GetDevices` per refresh,
  only while a mapping exists.
- **Set Room Mapping** stays the one place a hand choice is made.

### 5.5 Forget Device and Refresh Scenes

`Forget Device` joins today's two Forget pickers (lights, zone lights,
scenes; motion if agreed), gone, unbound and conflicting devices first, and
takes over the children's Forget This …, which cannot work while unbound
anyway (E23). `Refresh Scenes` goes: events keep the catalogue live and
Refresh All covers a dead stream (E20).

### 5.6 Background tasks of this family

| Task | Trigger | Guard | Shows in | Bridge requests |
| --- | --- | --- | --- | --- |
| Map rooms by name | resync settle, group add/rename, room add/rename, 5-min tick | §5.4 rules, `how`, baseline | Room Mappings, log | 0 |
| Room audit marker | row refresh (actions, events, 5-min tick) | only with mappings | Lights, Zone Lights, Room Mappings | 0 |
| Accept a Composer rename | `OnItemNameChanged` | registered proxy, linked entry | Attention shrinks, log | 0 |
| Follow Hue names | Hue name change seen | `Follow` set; Composer name = old Hue name | log "Renamed … to follow Hue"; the device's own name | 0 |
| Suggest links | every reconcile (exists) | §5.2 rules | Attention, Link Device lists | 0 |
| Scene catalogue | stream events, reconnect | — | Scenes row | 3 per resync (exists) |

Stopping them (principle 3): `Follow` ends with `Names From Hue` = `Ask`; the
name mapping, the audit marker and the rename acceptance end with the master
switch the scheduler research proposes, or, without one, a `Map Rooms By
Name` On/Off that covers all three. The link suggestions and the scene
catalogue only read and change nothing in the project; they exist today.

### 5.7 The lists

`Lights`, `Scenes`, `Zone Lights`, `Room Mappings` stay drop-down lists for
reading only (E10), with the marker and provenance above. List-as-trigger is
not proposed: a pick needs the row's Set (E11), shows no context and asks no
confirmation, and here every action creates, re-points or renames.

### 5.8 Upgrade path

No `<capabilities>` change, no reboot (E9). Persisted keys stay; new: `how`
on mappings, the baseline flag, the setting. No programming refers to actions
(E25). Retired commands should be kept as hidden handlers for one release, so
a Windows-session brief or tool still works (the compat research owns the
list). The manuals' chapters 6 to 9, the composer checklist and the specs
change with it.

## 6. Verdicts

| Action / property | Verdict | Reason |
| --- | --- | --- |
| Add Light | **MERGE into Add From Hue** | a leaf of the Lights folder; same refusals and texts |
| Import All New Lights | **MERGE into Add From Hue** | its "All N new lights" row; cannot be automatic (E1) |
| Add Zone Light | **MERGE into Add From Hue** | the Zones and rooms folder; no bulk row (E27) |
| Re-link Device To Light | **MERGE into Link Device** | one picker over every kind, with suggestions |
| Re-link Zone Light | **MERGE into Link Device** | the cross-kind refusal stays |
| Link Devices | **MERGE into Link Device** | its name and rid matches become suggestions, applied by the bulk row |
| Forget Light | **MERGE into Forget Device** | one picker over every kind |
| Adopt Hue Names | **MERGE into Resolve Names** | its "Rename all" row; `Follow` covers the common case |
| Accept Names As They Are | **MERGE into Resolve Names** + **AUTOMATIC** for Composer renames | his own rename is the answer (C2) |
| Set Room Mapping | **KEEP** | the one hand choice; gains `none` and the name-match hint |
| Map Rooms By Name | **AUTOMATIC** | resync, group and room events, 5-min tick; never overrides; 0 requests |
| Room Audit | **AUTOMATIC** | a marker on the list rows; one local call per refresh |
| Add Scene | **MERGE into Add From Hue** | a leaf of the Scenes folder |
| Add All Scenes Of Room | **MERGE into Add From Hue** | the first row of each group folder |
| Re-link Scene | **MERGE into Link Device** | gains a same-group name suggestion (S4) |
| Forget Scene | **MERGE into Forget Device** | the forgotten-device memory stays |
| Refresh Scenes | **RETIRE** | events keep scenes live; Refresh All covers a dead stream (E20) |
| Hue Light: Adopt Hue Name | **MERGE into Resolve Names** | a per-device row there; runs unpaired too |
| Hue Light: Forget This Light | **MERGE into Forget Device** | it already only asks the bridge |
| Hue Scene: Adopt Hue Name | **MERGE into Resolve Names** | as for the light |
| Hue Scene: Forget This Scene | **MERGE into Forget Device** | as for the light |
| `Lights`, `Scenes`, `Zone Lights` | **KEEP** | the at-a-glance status, plus the audit marker |
| `Room Mappings` | **KEEP** | plus "(by name)" and the hint for unmapped groups |
| new `Names From Hue` | **SETTING** | `Ask` (default) / `Follow` |

## 7. Target list and where everything went

| # | Action (Hue Bridge) | One line |
| --- | --- | --- |
| 1 | Add From Hue | Pick a light, zone or room, or scene (or "all new" of a kind or group) and a room |
| 2 | Link Device | Point a gone, unbound or unlinked device at a Hue resource; the driver's suggestion pre-chosen; all suggestions in one click |
| 3 | Resolve Names | Rename to Hue names or keep Composer names, all or one device |
| 4 | Set Room Mapping | Choose the Control4 room for a Hue room or zone, or none |
| 5 | Forget Device | Release a device from the bridge, leaving it in the project |

| Old | New home |
| --- | --- |
| Add Light, Add Zone Light, Add Scene | Add From Hue, a leaf of the matching folder |
| Import All New Lights, Add All Scenes Of Room | Add From Hue, the "All …" row of a folder |
| Re-link Device To Light, Re-link Zone Light, Re-link Scene | Link Device, by kind |
| Link Devices | Link Device, suggestions plus the "(every device …)" row |
| Forget Light, Forget Scene, Forget This Light, Forget This Scene | Forget Device |
| Adopt Hue Names, Adopt Hue Name (both children) | Resolve Names, "Rename …" rows |
| Accept Names As They Are | Resolve Names, "Keep …" rows; automatic after a Composer rename |
| Map Rooms By Name | automatic (§5.4) |
| Room Audit | list markers (§5.4) |
| Refresh Scenes | events, reconnect resync, Refresh All |

21 actions become 5 (7 with the fallback of §5.1); the children have none.

## 8. Risks and open questions for the owner

Each with a recommended answer first.

1. **Accept a Composer rename automatically?** **Yes.** Attention then lists
   only Hue-side renames. Risk: someone else's rename goes unmentioned; the
   device's `Hue Name` row still shows the Hue side.
2. **Default of `Names From Hue`?** **`Ask`**, as today, so the update renames
   nothing; `Follow` for whoever names in the Hue app first.
3. **Re-link by MAC without a click?** **No**, offered with the bulk row,
   until a spare bulb proves E19; a wrong pair would silently drive the wrong
   lamp (UX §1).
4. **One Add From Hue with a folder tree?** **Yes, if the Windows session
   shows the Folder type working in Composer 3.4.2** (one dev-build dialog,
   E4); otherwise the three-Add fallback.
5. **Room mismatches in Attention?** **No**, only as list markers; a lamp may
   live in another Control4 room on purpose.
6. **Baseline the groups unmapped at the update (§5.4)?** **Yes**; offering
   those matches costs a click, mapping them could undo a removal.
7. **Child devices with no actions?** **Yes**; their Status texts already
   send the owner to the bridge ("re-link or Forget").
8. **Fold Forget into Link Device as a "(release it)" target?** **No**: an
   unbinding hidden in a re-link list is too easy to pick.
9. **A bulk row for zones and rooms?** **No**, ZL §8.1 stands.
10. **Keep the old command names working for one release?** **Yes**, as
    hidden handlers, so the Windows-session briefs and tools keep working.

Risks without a question: Composer picker length (about 144 scenes in one
flat list on the house today; a folder per group shortens it); `Follow` renames refresh the project each
time (E2), hence the pacing; `OnItemMoved` is unproven (E13), the 5-minute
tick covers it; merging Link Devices and Forget across modules touches the
motion family, to agree with the maintenance research.
