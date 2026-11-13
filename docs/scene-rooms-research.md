# Scene devices and Control4 rooms: lifecycle research (#469)

> Research, read-only, 2026-11-12, for issue #469 (branch
> `feat/scene-tracking-469`). It lists the corner cases of keeping each Hue
> Scene device in the Control4 room that its Hue room or zone maps to, on
> both sides and over the life of the system, and recommends one design.
> Nothing here is built; the feature's contract decides. Evidence tags:
> [verified: …] is code (file and function, line numbers as of `main` at
> ffe8b3e), an SDK file under `~/c4-tools/reference/`, or a hardware
> record; [community: …] is a public source outside Signify's login-walled
> reference; [assumed] is neither. SDK paths are short: "API" is
> `docs-driverworks-api/source/includes/`.
>
> Current (2026-11-13, #478): decided and built in 1.6 by
> `docs/scene-tracking-design.md` Part 2, which differs from §9 and §10 here
> where the owner chose otherwise: an add with an explicit room for a scene
> of an unmapped Hue room or zone is refused (O3, not mapped on the click),
> and there is no escape hatch, "(no mapping)" included (O4).

## Contents

- [1. The request, and the answer in short](#1-the-request-and-the-answer-in-short)
- [2. What exists today](#2-what-exists-today)
- [3. Facts the design rests on](#3-facts-the-design-rests-on)
- [4. The rule, its exemption and its escape hatches](#4-the-rule-its-exemption-and-its-escape-hatches)
- [5. Lifecycle cases](#5-lifecycle-cases)
- [6. What each surface shows](#6-what-each-surface-shows)
- [7. Control4 lighting guidelines](#7-control4-lighting-guidelines)
- [8. What stays as it is](#8-what-stays-as-it-is)
- [9. Recommendations for the contract](#9-recommendations-for-the-contract)
- [10. Open questions for the owner](#10-open-questions-for-the-owner)

## 1. The request, and the answer in short

The owner (#469, 2026-11-12): a Control4 room should only take scene
devices for scenes that Hue defines for the matching room, and where the
1:1 mapping of Hue rooms to Control4 rooms does not hold, the exception
must be handled gracefully and intuitively.

Recommended, in five lines:

1. **The rule lives in the bridge's own setup actions** (Add From Hue, Link
   Device), never in Composer. A scene whose Hue room or zone maps to
   Control4 room M is added or linked only in M. Nothing moves a device, and
   nothing can stop a drag in Composer.
2. **Where there is no matching room** (a group never mapped, one set to
   "(no mapping)" by hand, the whole home), the room picked is used. For a
   group that was never mapped, that click also records the mapping.
3. **Identity is never judged by room.** A device adopted by the scene it
   remembers, or re-linked to the same room's or zone's scene, passes.
4. **Two escape hatches, both existing controls.** "(no mapping)" on a Hue
   room or zone lets its scenes go into any room picked, without marks. A
   drag in Composer after adding keeps one scene elsewhere; its list row is
   marked, and it is never moved back. Split rooms are best made in Hue as
   zones, one per Control4 room.
5. **Lua only.** `bridge/scenes.lua`, `bridge/actions.lua` and texts in
   `bridge/lights.lua`. No `driver.xml` change, no new persisted state, no
   controller reboot.

## 2. What exists today

| # | Piece | What it does today | Evidence |
|---|---|---|---|
| E1 | The mapping store | `hue_rooms`: Hue group rid → `{ c4_room_id, c4_room_name, hue_name, type }`. One Control4 room per group; several groups may share one Control4 room. | [verified: `src/hue_bridge/bridge/registry.lua` `set_room_mapping` l.591, `room_mapping` l.581] |
| E2 | How a mapping was made | `name`, `hand`, `earlier` (before 1.2), `none` (removed by hand), or nil (never mapped), from the rooms book. | [verified: `src/hue_bridge/bridge/lights.lua` `mapping_how` l.1837, `room_book` l.1788] |
| E3 | Mapping by name | When a group first appears: only a unique, exact (trimmed, case-insensitive) Control4 room name; never over `hand`, `earlier` or `none`; nothing used up while the project's rooms are unknown; a seen group is never tried again; a dead mapping made by name is re-pointed to the one room of its name after a full read (CR3). | [verified: `lights.lua` `auto_map_rooms` l.1031] |
| E4 | Set Room Mapping | The one hand choice. "(no mapping)" records `none`. Refuses the whole home ("the whole bridge cannot be mapped to one room"), and its Hue Room picker lists only rooms and zones. | [verified: `lights.lua` `set_room_mapping` l.1889, l.1899-1901; `src/hue_bridge/bridge/groups.lua` `groups:groups` l.163] |
| E5 | Where an add goes | An explicit Room is accepted as it is (only checked to exist); "(mapped room)" takes the mapping of the record's group, or refuses. Shared by lights, zone lights, scenes and motion. | [verified: `src/hue_bridge/bridge/owner.lua` `room_for_add` l.984, `default_room` l.962; callers `lights.lua` l.1440, `zone_lights.lua` l.1326, `scenes.lua` l.2286, `motion.lua` l.2182] |
| E6 | A scene's group for rooms | The scene's room or zone; none for the whole home (bridge_home) or no group. | [verified: `src/hue_bridge/bridge/scenes.lua` `room_group_of` l.568] |
| E7 | All scenes of a group | Only into the mapped room. Any explicit Room is refused, even the mapped room itself. | [verified: `src/hue_bridge/bridge/actions.lua` `run_add` l.845-847; `scenes.lua` `add_all_of_group` l.2319, l.2348] |
| E8 | The scene folders | Add From Hue ▸ Scenes holds one folder per group, "Kitchen: 5 scenes", sorted by the Hue label; the mapping is not shown. Link Device's To reuses them, not selectable. | [verified: `actions.lua` `scene_groups` l.288, `scene_folders` l.318, `target_kinds` l.639] |
| E9 | The Room list | "(mapped room)" first, then every Control4 room as "Floor / Room". | [verified: `lights.lua` `picker_rooms` l.2323; `actions.lua` `room_list` l.476] |
| E10 | Room marks | A linked device of a mapped group that sits in another Control4 room gets " (in Den instead of Kitchen)" on its list row; " (in Den; mapped room gone)" when the mapping is dead. A scene is compared with its own room or zone. One `GetDevices` lookup; an unknown answer marks nothing. Never in Attention. | [verified: `owner.lua` `room_marks` l.1021; `scenes.lua` `mark_group` l.914, `list_items` l.2717; `lights.lua` `attention` l.2136 has only the dead-mapping item] |
| E11 | When rows refresh | Every 5 minutes and after a Composer rename. `OnItemMoved` is registered for the debug log only and has never been seen on hardware. | [verified: `src/hue_bridge/driver.lua` `PROBE_EVENTS` l.2126, rows timer l.2662; [import research](simplify-research-import.md) §3 E13] |
| E12 | Link Device | Device lists gone and unbound devices plus suggested ones. A bare device (bound, never registered) is linked only by its first line: by the rid it announces, or by a unique exact name among **all** unimported scenes. | [verified: `owner.lua` `link_devices` l.1787, l.1843; `scenes.lua` `unimported_named` l.2481] |
| E13 | Re-link | Any scene of any group; no room check. | [verified: `owner.lua` `relink` l.1616] |
| E14 | Suggestions | A gone scene device is suggested the unimported scene of its name in the same group (same rid, or same label after a re-made group). | [verified: `scenes.lua` `name_suggestions` l.732, `in_same_group` l.722; `owner.same_group` l.1929] |
| E15 | Adoption by remembered rid | At hello and in Link Devices; no room check. | [verified: `owner.lua` `hello` l.575, adopt at l.641; l.1831] |
| E16 | A scene's group changing | The catalogue and the entry follow a `group` field if Hue ever sent one. | [verified: `src/hue_bridge/bridge/hue_model.lua` `update_scene` l.540; `scenes.lua` `refresh_entry` l.760] |

Two findings on today's texts:

- **F1.** A whole-home scene added with "(mapped room)" is refused with
  "Not added: Bright: not in a Hue room; pick a room, or Set Room Mapping
  first", but Set Room Mapping cannot map the whole home (E4). The text
  points at a fix that does not exist. [verified: `owner.lua`
  `room_for_add` l.996-998 with `scenes.lua` `room_group_of`]
- **F2.** "All scenes of Kitchen" with Room = the mapped room itself is
  refused (E7). The refusal says "set Room to (mapped room), or pick one",
  and picking one is exactly what was refused. [verified: `actions.lua`
  l.846]

## 3. Facts the design rests on

### 3.1 Control4

- **No DriverWorks API moves a device to another room.** The device and
  room calls are AddDevice (a room at creation, user-initiated only)
  [verified: API `9_helper/_0.1-AddDevice.md`], AddLocation [verified: API
  `9_helper/_0.2-AddLocation.md`], RenameDevice [verified: API
  `22_miscellaneous/_32-RenameDevice.md`], RoomGetId (the driver's own room)
  [verified: API `22_miscellaneous/_33-RoomGetID.md`], GetRoomID (read only,
  4.1.0 and later) [verified: API `9_helper/_9.5-getroomid.md`] and
  GetDevices, which answers each device's `roomId` and `roomName` [verified:
  API `22_miscellaneous/_9-GetDevices.md`]. A search of every
  `docs-driverworks-*` folder for a move or set-room call found none
  [verified: grep, 2026-11-12]. So the driver cannot move a scene device,
  and the only place to enforce a rule is its own actions.
- **Nothing lets a driver refuse a drag in Composer.** No location
  validation callback is documented; OnBindingValidate is about bindings
  only [assumed: absence; verified that the system event list names device
  add, remove and rename only, API `7_event/_1-RegisteringforSystemEvents.md`].
  `OnItemMoved` exists in Control4's own handler list but not in the API
  docs, and its payload is undocumented [verified:
  `~/c4-tools/drivers-common-public/global/handlers.lua` l.83, read only].
- **The two pickers of an action never see each other.** Room cannot be
  filtered by the scene picked under What, nor To by the device picked under
  Device; the runner checks the pair at OK [verified: hardware 2026-11-05,
  build 447, [actions contract](simplify-actions-design.md) §2.3; FUND
  `15_composerpro_interface_into_the_sdk/_4-CUSTOMSELECTPROPERTY.md`].
- **A Control4 room Off reaches every light device in the room**, scene
  devices included, and a scene device's OFF turns its whole Hue room or
  zone off [verified: bridge manual chapter 11 "Whole-room and whole-house
  commands" and 9.4, `src/hue_bridge/www/documentation.html`;
  [scenes contract](scenes-design.md) §1 "OFF"] [assumed: Control4's side of
  the room Off, from the manual's account]. A scene device in Den whose
  scene belongs to Hue's Kitchen turns the Kitchen off at Den's Room Off.
  This is the strongest practical reason for the rule.
- A device shows in the Lighting menu of the room it sits in [assumed:
  C4-USER-MENU in [the guidelines](c4-lighting-guidelines.md) §2]. Whether
  Composer can list a device of one room in another room's Navigator is not
  known [assumed; not checked].
- The room driver's `SET_DEVICE_HIDDEN_STATE` is undocumented and known only
  from Snap One's library [verified: [Control4 edge cases](edge-cases-control4.md)
  §5.7]; it is not a tool for this (and Snap One code is never vendored).

### 3.2 Hue

- **A scene's room or zone is fixed when the scene is made.** The CLIP v2
  create body requires `group`; the update body has no `group`; the same
  holds for time-based scenes [community: openhue-api,
  `src/scene/schemas/ScenePost.yaml`, `ScenePut.yaml`,
  `src/smart_scene/schemas/SmartScenePost.yaml`, `SmartScenePut.yaml`, read
  2026-11-12]. The Hue app's "copy to another room" makes a new scene
  [community: [Hue edge cases](edge-cases-hue.md) §3]. Signify's own
  reference is login-walled and was not read [assumed beyond the community
  spec]. The code follows a group change anyway (E16), so a surprise only
  changes a mark.
- Deleting a room or zone deletes its scenes [assumed: [Hue edge
  cases](edge-cases-hue.md) §2].
- A light belongs to exactly one Hue room; zones may overlap rooms and each
  other; bridge_home holds everything [verified: `groups.lua` header,
  hardware 2026-10-21].
- Hue has no "split" or "merge" of rooms: a split is a new room plus lights
  moved; a merge is lights moved plus a room deleted. A scene keeps its
  group while the bridge rewrites its light list [community: [Hue edge
  cases](edge-cases-hue.md) §2 "Light moved"] [assumed: no merge command].
- Scenes can belong to group types the driver does not cache
  (`service_group`, `private_group`) [community: [Hue edge cases](edge-cases-hue.md)
  §3]; the group cache holds rooms, zones and bridge_home only [verified:
  `groups.lua` `groups.TYPES`].

## 4. The rule, its exemption and its escape hatches

### 4.1 Where a scene may go, by the state of its group's mapping

"R" is the Control4 room picked under Room (Add From Hue) or the room the
device sits in (Link Device).

| Group of the scene | Its room | Add, Room "(mapped room)" | Add, Room R | Link a device in R |
|---|---|---|---|---|
| Mapped to M, M exists | M | into M | R = M: into M. R ≠ M: **refused** | R = M, or the same group as before: linked. Otherwise **refused** |
| Never mapped (`how` nil; includes a name two Control4 rooms share) | none yet | refused | into R, **and the group is mapped to R** (by hand) | linked; nothing mapped; offered on Room Mappings |
| "(no mapping, by hand)" | any | refused: pick a room | into R; nothing mapped | linked |
| Mapped to a deleted Control4 room | none | refused | into R, **and the mapping is re-pointed to R** | linked |
| Whole home, or a group type not cached | any | refused: pick a room | into R | linked |
| Any, while the project's rooms are unknown | M as remembered | into M (as today) | only R = M; never maps | check skipped when the device's room is unknown |

The same table holds for "All scenes of <group>" (E7 changes: an explicit
Room equal to the mapping, or any Room for a group with no room of its own,
is accepted).

### 4.2 The exemption: identity is not placement

The rule applies only when a **new** pairing of a device and a scene is
chosen: an add, a pick under To, or a match by name. It never applies to:

- a device adopted by the scene it remembers (hello, Link Device's first
  line by rid, a project restore, a device bound again) (E15);
- a re-link to a scene of the **same group** as before: the same rid, or
  the same name and type after the group was made again (`owner.same_group`,
  E14). That is a replacement, and the dealer's earlier placement stands.

### 4.3 The escape hatches, and why these

1. **Group level: "(no mapping)".** Set Room Mapping's "(no mapping)" already
   records the owner's wish that a Hue room or zone has no Control4 room
   (`none`, E2). Under the rule it also means "its scenes go into the room I
   pick", and its devices carry no marks (E10 marks only mapped groups). It
   fits a zone that spans rooms, or a Hue room covering several Control4
   rooms. No new state.
2. **Device level: the drag.** Add into the mapped room, then drag the
   device in Composer. It keeps working; its row reads "(in Dining instead
   of Living)"; nothing moves it back and Attention stays quiet (E10).
3. **Split rooms are zones in Hue.** For a Hue "Great Room" covering Control4
   "Living" and "Dining", make the zones "Living area" and "Dining area" in
   the Hue app, map each to its Control4 room, and make the scenes there.
   Zone scenes are named with the zone in front ("Dining area Relax")
   [verified: `scenes.lua` `creation_name` l.499]. Great Room itself maps to
   the room that should hold its whole-room scenes, or to "(no mapping)".

Rejected:

- **A third Add From Hue row, "Outside its room: No / Yes".** Composer
  pre-fills an action with its last choices [verified: manual 6, "The dialog
  remembers"], so a Yes stays armed for every later add.
- **"Click OK again to confirm".** Invisible; nothing on screen says so.
- **A set of extra allowed rooms per group.** It answers split rooms
  exactly, but changes the registry shape, Set Room Mapping and the marks.
  Open question 3.
- **Showing the device in other rooms through the room driver.**
  Undocumented (§3.1).
- **Refusing or undoing a drag.** Impossible, and against the Control4
  guidelines (§7).

Why the click maps a never-mapped group (rows 2 of 4.1): the owner names
both sides in one dialog, it saves an action, Set Room Mapping undoes it,
and Last Action says so. The risk is Composer's remembered Room mapping a
group to a room the dealer did not look at; the text names the mapping so
it is seen at once. The alternative, refusing and pointing at Set Room
Mapping, costs one more action (open question 1).

## 5. Lifecycle cases

Classes: **auto** (the driver does it by itself and says so), **offered**
(shown; done on a click), **click** (happens only on the owner's click; the
rule judges that click), **forbidden** (refused, with the way out), **none**
(nothing to do). Texts are proposed wordings; device numbers and room names
are examples.

### 5.1 Control4 side

| # | Case | Today | Proposed | Class | What the owner sees |
|---|---|---|---|---|---|
| C1 | Add one scene, "(mapped room)", group mapped to M | into M | unchanged | click | "Added Relax to Kitchen (device 1225)" |
| C2 | Add one scene, Room = M | into M | unchanged | click | as C1 |
| C3 | Add one scene, Room R ≠ M | into R; marked later | refused | forbidden | "Not added: Relax is a scene of Kitchen, which maps to Kitchen, not Den. Set Room to (mapped room), or change the mapping with Set Room Mapping" (a zone: "…a scene of Accent (zone), which maps to Living Room…") |
| C4 | Add one scene, "(mapped room)", group never mapped | refused | refused, saying a pick maps it | forbidden | "Not added: Relax: Hue room Garden is not mapped yet; pick its Control4 room under Room (Garden is then mapped to it)" |
| C5 | Add one scene, Room R, group never mapped | into R | into R; Garden → R by hand | click | "Added Relax to Den (device 1225); Garden is now mapped to Den (Set Room Mapping changes it)" |
| C6 | Add one scene, "(mapped room)", group "(no mapping)" | refused, naming Set Room Mapping | refused, accurate | forbidden | "Not added: Nightlight: TV Area (zone) has no Control4 room (no mapping, by hand); pick a room under Room" |
| C7 | Add one scene, Room R, group "(no mapping)" | into R | unchanged | click | "Added Nightlight to Den (device 1225)" |
| C8 | Add a whole-home scene, "(mapped room)" | refused, pointing at Set Room Mapping (F1) | refused, accurate | forbidden | "Not added: Bright plays on the whole home (all lights); pick a room under Room" |
| C9 | Add a whole-home scene, Room R | into R | unchanged | click | "Added Bright to Den (device 1225)" |
| C10 | All scenes of a mapped group, "(mapped room)" | into M | unchanged | click | "Added 6 scenes of Kitchen to Kitchen: …" |
| C11 | All scenes, Room = M | refused (F2) | into M | click | as C10 |
| C12 | All scenes, Room R ≠ M | refused, generic | refused, named | forbidden | "Not added: the scenes of Kitchen go to Kitchen, its mapped room, not Den. Set Room to (mapped room), or change the mapping with Set Room Mapping" |
| C13 | All scenes of a never-mapped group, Room R | refused | Garden → R by hand, then all into R | click | "Garden is now mapped to Den; added 4 scenes of Garden to Den: …" |
| C14 | All scenes of a "(no mapping)" or whole-home group, Room R | refused | all into R | click | "Added 2 scenes of TV Area (zone) to Den: …" |
| C15 | A bare "Hue Scene" dragged into R, renamed, linked by Link Device's first line | unique name among all unimported scenes; "Relax" is in every room, so usually ambiguous | the name match is narrowed to the scenes of groups mapped to R, plus groups with no room of their own; R from `GetDevices`; R unknown → today's rule | click | linked: "Relax (device 1301) to Kitchen: Relax by name"; none for R but one elsewhere: "Relax (device 1301): no scene of that name for Den (Kitchen: Relax goes to Kitchen); drag it there and run Link Device again, or use Add From Hue" |
| C16 | A bare device in R with two matches in R | ambiguous over the house | ambiguous only within R | forbidden | today's text, with the count of R's scenes |
| C17 | Device dragged to another room in Composer | marked at the next refresh | unchanged; never moved back; no Attention | auto (display) | row "Kitchen: Relax → device 1225 (in Den instead of Kitchen)", within 5 minutes (E11) |
| C18 | Device adopted by its remembered scene (rebind, restore, copy) | adopted | unchanged; no room check (4.2) | auto | Status "Hue scene Relax in Kitchen"; a mark if it sits elsewhere |
| C19 | Forgotten device linked again by the scene it remembers | linked | unchanged (4.2) | click | today's text |
| C20 | Control4 room renamed | mapping by id | unchanged | auto | lines and marks show the new name |
| C21 | Mapped Control4 room deleted | by name: re-pointed to a unique same-name room (CR3); by hand: Attention | unchanged; plus an offer when one room has the old name | auto / offered | Attention "1 room mapping points at a Control4 room that no longer exists: Kitchen (Set Room Mapping)"; line "Kitchen → (Control4 room gone; Control4 room Kitchen matches) (by hand)" |
| C22 | Control4 room deleted with scene devices in it | Composer's own question [assumed]; deleted devices become tombstones | unchanged | none | — |
| C23 | Control4 room re-created (new id) | as C21 | as C21 | auto / offered | as C21 |
| C24 | Project restored from a Composer backup | devices with a scene adopted (C18); whether the bridge's store returns is unverified [verified: manual 8.9] | if the mappings were lost: by name by itself (the first-read path, E3); every other group offered from where its scene devices sit | auto / offered | line "Garden → (unmapped; its 3 scene devices are in Den)" |
| C25 | Device deleted in Composer, the scene added again | tombstone; any room | the rule as C1 to C14 | click | as C1 to C9 |
| C26 | One Control4 room with several groups mapped | allowed | allowed; their folders sort together | none | folder "Accent (zone) → Living Room: 3 scenes" |
| C27 | A Control4 room no group maps to | anything | only scenes of never-mapped (mapped on the click), "(no mapping)" and whole-home groups | click / forbidden | C3's text when a mapped group's scene is picked |
| C28 | A Hue zone spanning several Control4 rooms | mapped to one | unchanged; or "(no mapping)" to let its scenes go anywhere | none / click | manual 9.4's OFF caveat stays |
| C29 | Split room: one Hue room covers two Control4 rooms | — | zones per Control4 room (4.3); one-offs by drag | offered (manual) | — |
| C30 | Room list unknown (project not read yet) | explicit Room accepted unchecked; mapping trusted | "(mapped room)" trusted; explicit Room only when it equals the mapping; nothing mapped | forbidden | "Not added: the project's rooms are not read yet; pick (mapped room), or try again in a minute" |

### 5.2 Hue side

| # | Case | Today | Proposed | Class | What the owner sees |
|---|---|---|---|---|---|
| H1 | Room or zone created in the Hue app | mapped by unique name, else unmapped (R1) | unchanged; the first explicit add maps it (C5) | auto / click | "Mapped 1 Hue room or zone by name: Porch → Porch" |
| H2 | Room or zone renamed | mapping by rid; labels follow | unchanged | auto | new names in lines and folders |
| H3 | Room or zone deleted | its scenes deleted [assumed]; devices gone; mapping kept "(deleted in Hue)" | unchanged | auto; Link or Forget offered | Attention "2 scenes missing from the bridge: … (Link or Forget Device)" |
| H4 | Deleted and made again under the same name (new rid) | new group mapped by name only if a Control4 room has its name; gone devices suggested | plus: the deleted group's mapping offered to the new one; the suggested links pass (4.2) | auto / offered | line "Great Room → (unmapped; the deleted Great Room was mapped to Living)"; Link Device "… (suggested: same name in the same group)" |
| H5 | "Split": a new room, lights moved into it | new room as H1; old scenes keep their group | unchanged; existing devices stay right | auto | — |
| H6 | "Merge": lights moved, one room deleted | the deleted room's scenes gone | a re-link to the surviving room's scene passes if it maps to the device's room or is the same group; else refused with the way out | forbidden | "Not linked: device 1241 is in Dining; Living Room: Relax is a scene of Living Room, which maps to Living. Pick a scene mapped to Dining, set Living Room to (no mapping), or drag the device first" |
| H7 | A scene's group changes | Hue does not allow it (§3.2); the entry would follow (E16) | unchanged | auto (mark only) | a mark if the new group maps elsewhere |
| H8 | Scene deleted | gone | unchanged | offered | today's texts |
| H9 | Scene deleted and made again, same name, same group | suggested | passes (4.2) | offered | "(suggested: same name in the same group)" |
| H10 | Scene copied to another room | a new scene | the copy follows the rule | click | as C1 to C5 |
| H11 | Zone with no lights | scenes may stay [assumed]; OFF reports off without a request | unchanged | none | — |
| H12 | Whole-home scenes | refused with F1's text | any room (C8, C9) | click | as C8, C9 |
| H13 | Scenes of an uncached group type | treated as unmapped, label "(no room)", and Set Room Mapping cannot map it | treated as whole-home | click | as C8, C9 |
| H14 | Time-based scenes | the group's mapping | unchanged; the same rule (their group is fixed too, §3.2) | click | as C1 to C14 |
| H15 | Bridge reset, rooms made again | every group new; devices gone | H4 for every group; the first line of Link Device links the suggestions | auto / offered | "Linked …"; lines as H4 |
| H16 | Bridge restored or transferred keeping its ids | nothing | nothing | none | — |

### 5.3 Mapping side

| # | Case | Today | Proposed | Class | What the owner sees |
|---|---|---|---|---|---|
| M1 | Never mapped | adds need a room; "all" refused | the first explicit add maps it (C5, C13) | click | as C5, C13 |
| M2 | Ambiguous by name (two Control4 rooms share it) | unmapped; log only | the line says why; the first explicit add maps it | offered / click | "Garage → (unmapped; 2 Control4 rooms are named Garage)" |
| M3 | Mapped to a deleted Control4 room | Attention; by name re-pointed (CR3) | plus: an explicit add re-points it | auto / click | "Added Relax to Den (device 1225); Kitchen is now mapped to Den (its Control4 room was deleted)" |
| M4 | Re-mapped with Set Room Mapping while devices exist | mapping changes; marks follow at the next refresh | unchanged; the result counts the devices left elsewhere | click / none | "Mapped Kitchen → Den; 5 scene devices and 2 lights of Kitchen stay where they are (marked in their lists; drag them in Composer to move them)" |
| M5 | Set to "(no mapping)" while devices exist | marks vanish | unchanged; the result says what it now means | click | "Removed the mapping for Great Room; it is not mapped by name again, and its scenes go into the room you pick" |
| M6 | First pairing before the Control4 rooms exist | rooms made later are offered, never mapped by themselves | unchanged; the first explicit add maps the group | offered / click | "Porch → (unmapped; Control4 room Porch matches)" |
| M7 | A mapping by name that is wrong | Set Room Mapping | unchanged; a hand choice is never overwritten | click | "Mapped Office → Den" |
| M8 | Update to the release with this rule | — | maps nothing by itself; existing devices outside their mapped room keep their marks (since 1.2); unmapped groups with scene devices are offered from placement | offered | "Garden → (unmapped; its 3 scene devices are in Den)" |

## 6. What each surface shows

### 6.1 Add From Hue ▸ What ▸ Scenes

Each folder names where its scenes go, and the folders sort by that
Control4 room, then by Hue label; groups with no single room come last:

- "Kitchen → Kitchen: 5 scenes"
- "Accent (zone) → Living Room: 3 scenes"
- "Garden → (unmapped): 4 scenes"
- "Kitchen → (Control4 room gone): 5 scenes"
- "TV Area (zone) → (any room): 2 scenes" for "(no mapping)"
- "(all lights) → (any room): 1 scene"

The first row inside a folder says the same: "All 5 scenes of Kitchen into
Kitchen", or "All 4 scenes of Garden (pick their room under Room)". The same
labels serve Link Device's To.

### 6.2 Add From Hue ▸ Room

Unchanged: "(mapped room)" first, then "Floor / Room". It cannot be
filtered by the scene picked (§3.1); the check runs at OK.

### 6.3 Link Device

- **Device**: a scene device's row also names its Control4 room, so the
  dealer can pick a matching folder under To: "Kitchen: Concentrate (device
  1241 in Den, gone since 10-21)". One `GetDevices` lookup when the list
  opens.
- **To**: the labelled folders of 6.1, not selectable.
- **At OK**: §4.1's last column; the refusal of H6.

### 6.4 Room Mappings and Set Room Mapping's Hue Room list

New line endings, all offers (a Set Room Mapping click applies them):

| State | Line |
|---|---|
| Never mapped, its scene devices all in one room | "Garden → (unmapped; its 3 scene devices are in Den)" |
| Never mapped, a deleted group of its name and type was mapped | "Great Room → (unmapped; the deleted Great Room was mapped to Living)" |
| Never mapped, name shared by two Control4 rooms | "Garage → (unmapped; 2 Control4 rooms are named Garage)" |
| Mapped to a deleted room, one room has its old name | "Kitchen → (Control4 room gone; Control4 room Kitchen matches) (by hand)" |
| "(no mapping)" | "TV Area (zone) → (no mapping, by hand; its scenes go where you pick)" |

The existing "(unmapped; Control4 room Porch matches)" stays [verified:
`lights.lua` `mapping_text` l.2239].

### 6.5 Lists, Attention, Status

- Room marks: unchanged (E10).
- Attention: no new item. Marks stay on the rows, as the room policy asks
  ("one line, no nagging") [verified: [UX edge cases](edge-cases-ux.md) §3;
  [import research](simplify-research-import.md) §5.4].
- The Scenes row may add ", 2 in other rooms" when marks exist (cheap: the
  same lookup as the marks). Optional.
- The scene device: unchanged. Its Status "Hue scene Relax in Kitchen" and
  Hue Room already tell a dealer looking at a device in Den where its scene
  belongs. No new configure field, so the scene driver is not touched.

### 6.6 Fewest clicks to fix

| Situation | Fix | Actions |
|---|---|---|
| One scene should live elsewhere | Add with "(mapped room)", then drag | 1 + a drag |
| A mapping is wrong, no devices yet | Set Room Mapping | 1 |
| A mapping is wrong, devices placed by it | Set Room Mapping, then drag each (the marks list them) | 1 + drags |
| An unmapped group's scenes belong in Den | Add From Hue with Room Den (maps it too) | 1 |
| A group's scenes belong in several rooms | Set Room Mapping "(no mapping)", then add with explicit rooms | 1 + adds |
| After a bridge reset | Link Device's first line, then Set Room Mapping where offered | 1 + 1 per group |

## 7. Control4 lighting guidelines

Rows of [the checklist](c4-lighting-guidelines.md) that bear on room
placement, and how the proposal meets them:

- **L58, L59** (lighting lives in the Lighting menu): a scene device is
  listed in the room it sits in, so placing it in its Hue room's Control4
  room puts its tile beside that room's lights.
- **L64, L66** (scene tracking; the toggle turns the scene's room off): with
  On State Follows = "Room/zone lights" a scene's tile follows its Hue
  group, and its toggle and OFF switch that group off. In the matching room
  that is the room's own lights; elsewhere it is another room's (§3.1, room
  Off).
- **L76** (actions are for setup): the rule lives in two existing bridge
  setup actions; the scene device gains no action.
- **L88, L73** (status texts say what is wrong and what to do, and fit the
  column): every refusal and offer in §5 names the way out; the longer
  offers sit on Room Mappings' drop-down lines, which exist because a row
  is clipped at about 75 characters [verified: manual 6, "The Room
  Mappings property"].
- The light_v2 best practice and Extras pages say nothing about rooms
  [verified: neither `_50-LIGHTV2BESTPRACTICE.md` nor `_51-LIGHTV2EXTRAS.md`
  mentions a room].
- **Behaving like Control4's own devices:** a dealer may put a Control4
  dimmer in any room, and Composer never objects [assumed]. So the driver
  never fights Composer's placement: a drag stays free and is only marked.
  The rule constrains only what the bridge's own actions create or link.
  No departure (no section 5 entry of the checklist) is needed.

## 8. What stays as it is

- **Lights, zone lights and motion keep "an explicit room is accepted as it
  is".** The manual tells owners a Kitchen lamp may live in the Den on
  purpose [verified: manual 6, "Why the driver never moves a device"]. The
  check therefore belongs in `scenes.lua` (its own `room_for_add`, or a
  check in `add_scene` and `add_all_of_group`), not in `owner.lua`'s shared
  `room_for_add` (E5).
- Zone and room lights also act on a whole Hue group and could take the same
  rule later; not asked in #469.
- The mapping store, the rooms book, mapping by name and the marks are
  unchanged. No persisted key changes, so the update needs no migration.

## 9. Recommendations for the contract

1. Adopt §4.1 as the rule for scene devices, implemented in `scenes.lua`
   and `actions.lua`, leaving `owner.lua`'s shared room resolution to the
   other kinds.
2. Adopt the exemption of §4.2: adoption by a remembered scene and re-links
   within the same group (`owner.same_group`) are never judged by room.
3. An explicit Room for a scene of a never-mapped group maps that group to
   the room, recorded as a hand choice, named in Last Action (C5, C13).
   Never over a mapping by name, by hand, from before 1.2 or "(no mapping)";
   never while the project's rooms are unknown (C30).
4. An explicit Room for a scene of a group mapped to a deleted Control4 room
   re-points the mapping (M3).
5. "All scenes of" a group accepts Room = its mapped room (F2), and any Room
   for "(no mapping)" and whole-home groups (C14).
6. Whole-home and uncached group types go into any room picked; fix F1's
   text (C8, H13).
7. Link Device checks the pair at OK (§4.1); its Device rows name the
   device's Control4 room (6.3); the refusal names the way out (H6).
8. Link Device's first line narrows a bare device's name match to the
   scenes for its Control4 room (C15, C16); with the room unknown, today's
   rule.
9. Scene folders in Add From Hue and Link Device show their target and sort
   by it (6.1).
10. Room Mappings and Set Room Mapping's Hue Room list carry the offers of
    6.4; "(no mapping)" lines say what they now mean.
11. Set Room Mapping's result counts the devices a new mapping leaves
    elsewhere (M4) and says what "(no mapping)" means (M5).
12. Nothing moves a device, and marks never reach Attention; the Scenes
    row's ", N in other rooms" is optional.
13. The update maps nothing by itself (M8), like 1.2's P1.
14. Lua only: no `driver.xml` change, no new persisted key, no controller
    reboot. Update manual chapters 6, 8.8, 8.9, 9.2, 9.3, 9.7 and 9.9, and
    add a `CHANGELOG.md` line.
15. Specs: one case per row of §5 in `tests/spec/scenes_spec.lua` and
    `tests/spec/actions_spec.lua`, including the two pickers arriving in
    any combination.
16. Hardware checks through the Windows session, none blocking: a drag's
    mark appearing within 5 minutes; `OnItemMoved`'s payload in the debug
    log; a Den Room Off reaching a scene device whose scene belongs to the
    Kitchen; whether Composer can show a device of one room in another
    room's Navigator.

## 10. Open questions for the owner

1. An explicit Room for a scene of a Hue room that was never mapped: map it
   on that click (recommended: one action, undone by Set Room Mapping), or
   refuse and send the owner to Set Room Mapping first?
2. Link Device: refuse a scene from another room's mapping (recommended,
   with the same-group exemption), or link it and only mark it?
3. The group-level escape: "(no mapping)" means "its scenes go into any
   room" (recommended, no new state), or a list of extra allowed rooms per
   Hue room or zone (exact for split rooms; a registry and Set Room Mapping
   change)?
4. A re-made room or zone of the same name and type after a deletion or a
   bridge reset: offer the old mapping (recommended, as name-only matches
   are offered under D7), or carry it over by itself?
