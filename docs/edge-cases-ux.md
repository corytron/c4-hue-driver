# Edge cases and owner-facing policy: lights, rooms, scenes

> **Historical research (2026-10-21)**, written before the import-ui and scenes features; "today" means that day's code. The decisions are `docs/import-design.md` (§1–§10, which resolves where this document and the other two disagreed) and `docs/scenes-design.md`; the present is in `docs/status.md`.

What the bridge driver does on its own, what it only offers, and what it
never does without a click, for every lifecycle event around lights, rooms
and scenes. Written for one home whose owner drives Composer himself, has
no dealer, and treats the project tree (devices, names, rooms, bindings,
programming) as his: the driver may change its own properties, its registry
and light state freely; anything that changes the project is a click.

Status markers: [verified: ...] = seen in the DriverWorks reference, a cited
page, or on hardware; [assumed] = to confirm on the controller or bridge;
[community] = forum or search-snippet evidence, not confirmed.

## Three rules behind every row

1. **The project is the owner's.** The driver creates a device, renames
   one, binds or unbinds, or re-points a device at a different Hue light
   only from an action the owner clicked. `C4:AddDevice` is documented for
   user-initiated use only [verified: API 9/_0.1], which settles the one
   case where automation would be tempting (a new bulb appearing).
2. **Nothing is ever lost by waiting.** Every detected change is cached,
   counted in a property and logged, so the owner can act on it a week
   later from Composer without a Hue-side event having to recur.
3. **The light device is the backup of the registry.** Each light persists
   its own `hue_rid`; the bridge adopts a bound light that announces a rid
   the registry lacks. That makes "bridge deleted and re-added" and
   "registry lost" survivable without a second import creating 47
   duplicates.

## What the earlier Control4 Hue drivers did

- **Extra Vegetables (2013, the lineage of Control4's own driver
  [community: Control4 acquired Extra Vegetables])**: one light driver per
  bulb added by hand; the installer typed the bulb's numeric Hue address
  into a property and the bulb's name then appeared in a read-only "Lamp
  Name" box as a check ("Check that the name of the lamp is what you
  expect"). A bridge action "Show Lights Available" printed addresses and
  names to the Lua tab. Groups were typed as comma-separated addresses into
  13 group properties. Hue app scenes could not be read from the bridge
  (v1 API), so "Store Preset" captured current levels into one of ten
  presets. Linking "would only need to be repeated if the Bridge is
  changed" [verified: http://res.cloudinary.com/control4/raw/upload/1697/3/Extra%20Vegetables%20Philips%20Hue%20Driver%20V8.pdf].
- **Control4 native driver, OS 2.9 (2017)**: the bridge driver's Actions
  gained an add-drivers button that "will bring in all your bulbs"
  (brightness drivers only), and names could only be changed with a paid
  third-party rename driver [verified: https://www.c4forums.com/forums/topic/24476-phillips-hue-bridge-driver-29/].
- **Control4 native driver, OS 3.3 (2022, "Philips Hue Light (OS 3.3.0+)"
  v72, bridge v849)**: a light driver is added, bound to a bridge under
  Connections, then the bulb is chosen from a light dropdown in System
  Design after "Actions > Update Available Lights"; the dropdown shows only
  the bound bridge's lights; polling every 30 s; whether new bulbs were
  picked up automatically went unanswered [verified: https://www.c4forums.com/forums/topic/40329-hue-with-33-best-practices/].
  Advanced Lighting Scene tracking of Hue lights was unreliable in 2019
  ("hue lights stay on, system knows they are on, but lighting scene is
  off") [verified: https://www.c4forums.com/forums/topic/33018-philips-hue-control4/].
  A bridge replacement meant the bridge "had to be readded and lights
  remapped" [community: search snippet of https://www.c4forums.com/forums/topic/33869-transferring-to-a-new-philips-hue-bridge/].
- **Chowmain (current)**: "AutoSetup" action creates everything; manual
  fallback = add the device driver, bind it to the bridge in Connections,
  then "Select Device From List"; the KB says auto setup is "strongly
  recommended" over manual [verified: https://help.chowmain.software/portal/en/kb/articles/control4-philips-hue-manual-setup-of-hue-device].
- **WhistleProjects Hue Lighting Pack (current)**: bulk import by "Rooms",
  "Zones" or "Everything"; "each driver instance renames itself to the name
  assigned in the Hue app"; "scene names must be unique" [verified: https://drivercentral.io/platforms/control4-drivers/lighting/philips-hue-lighting-pack/].
  The self-rename is exactly the surprise this document avoids.
- **Home Assistant** auto-imports every Hue scene as an entity and adds a
  per-room/zone scene dropdown; rooms and zones become grouped lights,
  disabled by default [verified: https://www.home-assistant.io/integrations/hue/].
  **openHAB** gives each room/zone one scene channel whose options are the
  group's scene names [verified: https://community.openhab.org/t/philips-hue-clip-2-api-v2-discussion-thread/142111?page=6].

Takeaways: every driver that automated naming or creation drew complaints
about renames and duplicates; every driver that made the owner pick one
bulb from a list wanted the name shown next to the id as a check. Nobody
had a story for a replaced bulb or a replaced bridge beyond "redo it".

## Facts the policy rests on

- No API deletes a device or moves one between rooms; the reference has
  only `DeleteEvent`, `DeleteVariable`, `FileDelete`, `Persist*`,
  `Registry*`, `RemoveDynamicBinding` [verified: sweep of the API docs].
  So "remove" and "move" can only ever be messages to the owner.
- `C4:RenameDevice(proxyId, name)` renames in Composer and refreshes the
  project; Composer shows the proxy, so the registry's `proxy_id` is the
  one to rename [verified: API 22/_32].
- `C4:GetDevices({DeviceIds=...})` returns `roomId`/`roomName` per device,
  and `{C4iNames="hue_light.c4z"}` lists every Hue Light device in the
  project, linked or not [verified: API 22/_9, 2.10.0+]. `C4:GetRoomID` is
  4.1-only [verified: API 9/_9.5] and is not used.
- Rooms: `C4:GetProjectHierarchy()` returns the location tree with names
  and types [verified: API 22/_15, 2.10.0+]; exact shape to be logged on
  hardware [assumed]. Fallback `GetProjectItems("LOCATIONS")` + ParseXml.
- `OnDriverRemovedFromProject` runs in a driver being deleted [verified:
  API 22/_26]; whether `SendToDevice` works inside it is [assumed].
- `C4:Unbind(consumerId, 1)` exists [verified: API 9/_19].
- Dynamic lists: `DYNAMIC_LIST` property + `C4:UpdatePropertyList(name,
  "a,b,c", default)`; comma-delimited, **not persisted**, rebuilt at init;
  selecting fires `OnPropertyChanged` [verified: Fundamentals 15/_2, API 24/_6].
- Hue: a light has a UUID `id` and a short `id_v1` ("/lights/12"); a
  `room.children` list holds device rids, `zone.children` light rids
  [assumed: CLIP v2 reference; the public schema shows the fields but not
  the rtypes, https://hub.liblab.com/open-hue-io/open-hue-api/2.0.0/typescript/1.0.0/models/RoomGet].
  A scene has `group` (one room or zone), `actions`, `status.active` in
  {`inactive`, `static`, `dynamic_palette`}, `auto_dynamic`, `speed`,
  `palette` [verified: .../models/SceneGet]; recall is `{"recall":
  {"action": "active"|"dynamic_palette"|"static", "duration": ms}}`
  [verified: .../models/SceneRecall]. Whether the stream carries `scene`
  updates when `status.active` changes is [assumed; confirm on hardware].
  A replaced bulb gets new device and light rids; Hue has no "same
  identity" replacement [assumed].

## 1. Decision table

"Owner sees" names the property or list; `Attention` is one new read-only
bridge property holding the current to-do list ("None" when empty), and
`Last Action` holds the result of the last click. Everything is also logged.

| Event | Automatic | Offered (one click) | Forbidden | Owner sees | Why |
| --- | --- | --- | --- | --- | --- |
| New Hue light appears (`add` event or seen at resync/import) | Cache it; add to `Add Light` list; count in `Lights` | `Add Selected Light` into a chosen room; `Import All New Lights` | `AddDevice` from an event, resync or startup | `Attention`: "1 new light on bridge: Porch (Outdoor)"; `Add Light` entry | AddDevice is user-initiated by contract; a bulb paired for a test must not become a device |
| Hue light removed (`delete` event, or absent from a full successful GET) | Mark `missing_since`; `ONLINE_CHANGED` false; count as missing | `Re-link` the device to another light; `Forget` | Deleting/unbinding the device; forgetting the registry entry on its own | Light `Status`: "Gone from the Hue bridge since 2026-10-21; re-link or Forget"; `Attention` | A bulb deleted by mistake in the Hue app is re-added in minutes; its Control4 programming must survive |
| Hue light renamed | Update cached name and the light's `Hue Name` property | `Adopt Hue Name` (one light) / `Adopt Hue Names` (all that differ) | `RenameDevice` without a click | Light `Hue Name` differs from the device name; `Attention` counts "3 Hue names differ" only until dismissed with `Accept Names As They Are` | Composer names are referenced in programming and spoken by family; WhistleProjects' self-rename is the complaint we avoid |
| Bulb physically replaced (same Hue name, new rid) | Old rid → missing; new rid → `Add Light`; detect name match and pre-select both | `Re-link Selected Device To Selected Light` (pre-selected pair) | Re-linking automatically on a name match | `Attention`: "Hallway Lamp gone from bridge; a new light with the same name (#53) appeared. Re-link?" | The device, its room, its name and its programming all survive; a wrong automatic match would silently control the wrong bulb |
| Light moved between Hue rooms (room `children` change) | Update cached Hue room and the light's `Hue Room` property; note if the device's Control4 room differs from the mapping | `Room Audit` action lists mismatches to drag by hand | Nothing is possible: no API moves a device | `Attention`: "Desk Lamp is now in Office in Hue; its device is in Hall (mapped Office → Office)" | The driver cannot move devices; and the owner may want the Control4 room to differ anyway |
| Hue room renamed / deleted / created | Renamed: display name refreshed (mapping is by rid). Deleted: mapping kept, shown "(deleted in Hue)". Created: appears unmapped | `Remove Mapping`; `Set Room Mapping`; `Map Rooms By Name` (exact, case-insensitive matches only) | Mapping to an inexact name match; dropping a mapping on its own | `Room Mappings` text; `Attention`: "Hue room Porch is not mapped" (only shown while unimported lights live there) | A mapping only affects future adds, so a stale one is harmless; a guessed one puts a device in the wrong room |
| Control4 room renamed / deleted | Renamed: display name refreshed from the hierarchy (mapping by id). Deleted: mapping shown "(Control4 room gone)"; adds for that Hue room stop with a message | `Set Room Mapping` again | Falling back to another room silently | `Room Mappings`: "Office → (Control4 room 212 'Den' no longer exists)"; `Last Action`: "Not added: Office is mapped to a room that no longer exists" | A device landing in the bridge's room unannounced is the surprise |
| Control4 device deleted | Light sends `HUE_GOODBYE` from `OnDriverRemovedFromProject` [assumed it can]; bridge forgets the entry, logs, and the light returns to `Add Light`. Startup reconcile: entry whose device `GetDevices` no longer returns → same | — | Treating "unbound" as "deleted" (that is a different state, see §4) | `Attention`: "Deleted in Composer: Desk Lamp; available again under Add Light" | The owner did the deleting; keeping a dead entry would only block re-adding |
| Control4 device moved | Nothing | `Room Audit` | Any move-back | Nothing unless the mapping disagrees, then the audit line | The Control4 room is the owner's choice |
| Control4 device renamed | Nothing | `Adopt Hue Name` remains available | Writing the Composer name back to Hue | `Hue Name` property keeps showing the Hue side | Names diverging is normal, not a fault; no nagging |
| Bridge replaced (new bridge id) | `Pair Bridge` refuses when the probed id differs from the stored one until `Forget Pairing` is run; after re-pairing, every entry is missing and every light is new | `Re-link By Name` (exact unique name matches old entry ↔ new light, reported one per line); the rest by hand with the pre-selected pairs | Silently accepting a different bridge id; creating devices for the "new" lights while matching missing entries exist | `Status`: "This is a different bridge (…B8F8); run Forget Pairing first if you replaced it"; `Lights`: "47 on bridge, 47 imported, 47 missing, 47 new"; `Attention` | A migration keeps names, not ids [assumed]; names are the only bridge-independent key and the owner should see the list once |
| Scene added / edited / deleted / renamed in Hue | Added: cache, list under its room. Edited: nothing (recalled by id). Deleted: scene device marked gone, ON does nothing, state OFF. Renamed: `Hue Scene` property updates | `Add Selected Scene`; `Adopt Hue Name`; `Re-link Scene`; `Forget` | Creating or removing scene devices on their own | Scene device `Status`: "Scene deleted in Hue on …; ON does nothing; re-link or delete this device"; `Attention` | Hue creates 7 default scenes per room; auto-creating them floods the project |
| Scene recalled from the Hue app or a Hue switch | Scene device state ON (`static`/`dynamic_palette`) or OFF (`inactive`) from the `scene` event, or from the resync GET; lights update as today | — | — | Navigator toggle follows | This is the two-way state the owner asked for; only state, never project changes |
| Light unreachable / unpowered for days | `ONLINE_CHANGED` false; `Online` = "Offline since …"; never forgotten | Nothing needed | Forgetting or hiding it | `Attention`: "3 lights offline more than 1 day" | Table lamps on wall switches go dark for weeks; Hue keeps them |
| Two Control4 devices for one light | Prevented: one rid → one device, and an import that finds unlinked `hue_light` devices in the project stops before creating any | `Link Devices` (a bound/unbound device announcing or carrying a rid, or matching by exact name) ; `Forget` + delete the extra one by hand | Creating a device for a rid or a name that an unlinked `hue_light` device already carries | `Lights`: "… 1 unlinked Hue Light device in project"; the extra device's `Status`: "Not linked to a Hue light; use Link Devices on the bridge or delete this device" | The registry-loss case would otherwise double the project |
| Import run twice | Idempotent: adds only rids with no entry; never renames, moves or rebinds existing ones; refreshes caps and state | — | Anything but adding | `Lights`: "47 lights on bridge, 47 imported, 0 new" | Already the contract; room mapping must not change it |
| Owner wants a light in a Control4 room with no Hue counterpart (or a Hue light with no room) | Nothing | `Add Selected Light` with `Into Room` set to any Control4 room; the mapping is only the default | Refusing because the rooms differ | `Into Room` lists every Control4 room; Hue "(no room)" lights appear in `Add Light` as "Lamp (no room)" | Rooms are a convenience, not a constraint |

## 2. Naming policy

- **The Control4 name is set once at creation, from the Hue name, and then
  belongs to the owner.** Imports, resyncs and events never call
  `RenameDevice`. Rationale: Composer names appear in programming,
  Advanced Lighting Scenes and voice; a Hue-side rename from a family
  member's phone must not rewrite them.
- The Hue name is always visible: light property `Hue Name`, scene property
  `Hue Scene`, plus `Hue Room`. A rename is one info log line and refreshes
  the dropdown entries.
- **`Adopt Hue Name`** exists on each light and scene device (renames that
  device's proxy to the current Hue name) and on the bridge as `Adopt Hue
  Names` (every linked device whose Composer name differs; the result lists
  each rename in `Last Action`). `RenameDevice` refreshes the project
  [verified], so it only ever runs from these clicks.
- **Dropdown disambiguation.** Entry text is
  `<Hue name> [<Hue room>] #<id_v1 number>` for lights (room omitted for
  lights in no room, `#` falls back to the first 8 hex of the UUID when
  `id_v1` is absent), `<Scene> [<Room or Zone>]` for scenes, and
  `<Floor> / <Room>` for Control4 rooms (two rooms with one name get the
  room id appended). The model is **not** part of the text (it is long and
  rarely distinguishes two lamps); it stays in the `Model` property. The
  `#` number is the stable key the owner can also see in the Hue app's
  light details [assumed] and in the dev log.
- Commas in Hue names are replaced by spaces in entry text (the list format
  is comma-delimited [verified]); entries map back to ids through an
  in-memory table keyed by the exact entry text, so sanitising is safe.
- Creation name for a light = the Hue name as is. The owner renames in
  Composer afterwards if he wants "Desk Lamp" to become "Cory's Desk Lamp".

## 3. Room policy

- The mapping is **Hue room or zone (rid) → Control4 room (id)**, persisted
  as `hue_rooms = { [group_rid] = { c4_room_id, c4_room_name, hue_name,
  type = "room"|"zone" } }`. Both names are cached for display only and
  refreshed from the bridge and from `GetProjectHierarchy()` whenever a
  list is rebuilt; ids are what the driver acts on.
- **The mapping is a default for creation, nothing else.** `Add Selected
  Light` pre-selects `Into Room` from the mapping (the owner may change
  it); `Import All New Lights` and `Add All Scenes Of Room` use it for every
  item. Nothing already in the project is ever moved because of a mapping,
  and nothing is possible anyway (no move API).
- Unmapped Hue rooms: a single add asks the owner to choose a room (the
  dropdown has no default); a bulk import **skips** lights whose Hue room is
  unmapped and lists them in `Last Action` ("5 skipped: Porch, Garage not
  mapped"). The scaffold behaviour (everything into the bridge's room) is
  available only through the explicit `Into Room` choice.
- `Map Rooms By Name` applies exact, case-insensitive, whitespace-trimmed
  name matches only, reports each one, and never overrides an existing
  mapping. Everything else is set by hand with `Hue Room` + `Maps To
  Control4 Room` + `Set Room Mapping`.
- Mapped Control4 room disappears: the mapping is kept and shown as broken;
  adds for that Hue room stop with a message rather than falling back.
  Hue room deleted: mapping kept, shown "(deleted in Hue)", `Remove
  Mapping` offered; lights that Hue moved elsewhere follow their new room.
- Bulb moved between Hue rooms: cached room and `Hue Room` property update;
  if the device's current Control4 room (from `GetDevices`) is not the one
  the new Hue room maps to, `Attention` says so and `Room Audit` lists every
  such device with "drag it to <room> in Composer if you want it there".
  Never automatic, never nagging beyond the one line: the owner may want a
  lamp that Hue thinks is in the Office to live in Control4's Hall.
- Zones are offered in the same mapping list (they matter for zone scenes
  and, later, grouped control); a zone maps to the one Control4 room its
  scene devices should live in.

## 4. Removal policy and device states

The driver cannot delete a Control4 device. Deleting is always the owner's
Composer action; the driver's job is to make the state obvious and to make
the delete safe (nothing else breaks when he does it).

| State | Registry | On bridge | Device in project | Light `Status` text | Bridge counts it as | Offered |
| --- | --- | --- | --- | --- | --- | --- |
| Linked and live | yes | yes | yes, bound | "Desk Lamp (Hue white and color ambiance)" | imported | `Adopt Hue Name`, `Forget` |
| Linked, gone from bridge | yes, `missing_since` set | no | yes, bound | "Gone from the Hue bridge since 2026-10-21 18:02; re-link or Forget" | missing | `Re-link`, `Forget` |
| On bridge, not imported | no | yes | no | — | new | `Add Selected Light` |
| Linked, device deleted in Composer | yes, device id dead | yes | no | — | (entry forgotten automatically, see §1) | — |
| Device exists, bound, unknown to registry (manual add, registry loss) | no | ? | yes, bound | "Bound; the bridge does not know this device. Use Link Devices on the bridge" | unlinked device | `Link Devices` (auto-adopted when the device carries a rid the bridge has, see below) |
| Device exists, unbound | no or yes | ? | yes, unbound | "Not bound to a Hue Bridge" (existing text) | unlinked device | bind in Connections, then as above |
| Forgotten | removed | any | yes, unbound | "Forgotten by the bridge (was Hue light Desk Lamp #12). Delete this device in Composer, or bind it again and use Link Devices" | unlinked device | — |

- **`Forget`** (light action `Forget This Light`; bridge action `Forget
  Selected Light` over the `Missing Lights` list): removes the registry
  entry, `C4:Unbind(deviceId, 1)` [verified API], sends the light a final
  `HUE_FORGOTTEN` so it shows the text above, and makes the rid (if still on
  the bridge) appear in `Add Light` again. It never touches the device
  itself. Forget is the step before a deliberate delete, or the way to free
  a rid for a different device.
- **Auto-adopt**: when a bound light says `HUE_HELLO` with a rid the
  registry lacks, and no other device holds that rid, the bridge registers
  it (device id from the hello's sender is unavailable, so the light must
  include its own device id in `HUE_HELLO` [new param]) and logs "adopted
  Desk Lamp (device 2043) from its own persisted rid". This is automatic
  because the device itself is the evidence and nothing in the project
  changes. A rid claimed by two devices is a conflict: neither is adopted,
  `Attention` names both.
- **Re-link** (`Re-link Selected Device To Selected Light`): swaps the rid
  in one registry entry for an unimported rid, tells the light its new rid
  (`HUE_CONFIGURE` with the new capabilities), and leaves device id, name,
  room, bindings and programming untouched. Used for a replaced bulb, a
  replaced bridge, or a manual add that was pointed at nothing.
- The bridge never removes an entry because a light is absent, offline, or
  renamed, and never on a stream `delete` event; only `Forget`, a confirmed
  Composer deletion, or a re-link changes the device ↔ rid relationship.
- Startup reconcile (after `GetBoundConsumerDevices` and one `GetDevices`
  call, both cheap): entries whose device no longer exists are forgotten
  (logged, listed in `Attention` once); entries whose device exists but is
  unbound are kept and shown as unbound. A `GetDevices` call that fails or
  returns nothing at all is treated as "unknown", not "deleted" [assumed:
  semantics of a deleted id].

## 5. Scenes policy

- **Which scenes are offered.** Every `scene` on the bridge, listed under
  its `group` (room or zone) in `Add Scene` after the owner picks the group
  in `Hue Room`. Scenes already imported are not listed. `smart_scene`
  (time-based "natural light") is excluded in v1 and noted in the log.
- **Creation is a click**: `Add Selected Scene` (one) or `Add All Scenes Of
  Room` (every unimported scene of the selected room or zone, placed in its
  mapped Control4 room, or in `Into Room` when set). Never created from
  events, imports or resyncs. Hue's seven default scenes per room would
  otherwise turn 12 rooms into 84 devices.
- **Scene device**: `hue_scene.c4z`, a `light_v2` switch (no dimmer)
  [assumed: a non-dimmer light_v2 renders as a toggle; to confirm], bound to
  the bridge's binding 1 like a light, registry `hue_scenes = { [rid] = {
  device_id, proxy_id, name, group_rid, group_name, group_type } }`.
- **Naming**: room scenes are named `<Scene>` and placed in the mapped room
  (Control4 already shows the room; "Living Room Relax" inside Living Room
  reads twice). Zone scenes are named `<Zone> <Scene>` because they live in
  a room that is not the zone. As with lights, the name is the owner's
  afterwards; `Hue Scene` shows the Hue side; `Adopt Hue Name` is offered.
- **ON** = `PUT /clip/v2/resource/scene/<rid> {"recall":{"action":
  "active"}}` (the bridge honours `auto_dynamic` for dynamic scenes). A
  per-device property `Recall As` = "As set in Hue" (default) / "Static" /
  "Dynamic" chooses `active` / `static` / `dynamic_palette`. A `RATE` from
  programming becomes `recall.duration` [assumed field; confirm].
- **OFF** = the scene's group `grouped_light` off, coalesced per group so a
  Control4 "Room Off" that hits seven scene switches sends one PUT (the
  group limit is about 1/s [verified: design.md]). Open question 6 covers
  the alternative (OFF only clears the state).
- **State**: ON while `status.active` is `static` or `dynamic_palette`, OFF
  when `inactive`; refreshed from `scene` stream events [assumed they
  exist] and from a `GET /clip/v2/resource/scene` in every resync. Several
  scene switches of one group are naturally exclusive.
- **Scene deleted in Hue**: the device stays; `Status` = "Scene deleted in
  Hue on …; ON does nothing; re-link or delete this device"; ON logs a
  warning and reports OFF at once so the toggle does not stick; `Re-link
  Scene` (to another scene of any group) and `Forget` are offered. Scene
  devices are never removed automatically, for the same reasons as lights.
- **Scene renamed / edited in Hue**: name cached and shown; edits need
  nothing (recall is by rid). Scene moved to another group in Hue (rare;
  Hue recreates it) is a delete + add and is handled as such.

## 6. Dropdown and property mechanics

All lists are `DYNAMIC_LIST` properties on the bridge, rebuilt with
`C4:UpdatePropertyList` (lists are not persisted [verified]) at
`OnDriverLateInit`, after every successful resync or import, after every
`add`/`delete` container, and after every click. Selecting an entry only
records the selection in memory (and `OnPropertyChanged` replays at
startup are ignored); the matching action does the work and writes its
result to `Last Action`. Selections are blank after a Director restart.

| Property | Type | Contents (in order) | Empty state |
| --- | --- | --- | --- |
| `Attention` | STRING ro | Up to ~6 lines joined with "; ": new lights, missing lights, unlinked devices, name differences, broken mappings, offline > 1 day. Dismissable items (`Accept Names As They Are`) stay dismissed until the fact changes again | "None" |
| `Last Action` | STRING ro | Result of the last click, e.g. "Added Porch to Outdoor (device 2051)", "Not added: pick a light first" | "" |
| `Lights` | STRING ro | "47 on bridge, 47 imported, 0 new, 1 missing, 0 unlinked devices" (existing property, extended) | "0 imported" |
| `Room Mappings` | STRING ro | "Hall → Hall; Kitchen → Kitchen; Office → (Control4 room gone); Porch → (unmapped); Downstairs (zone) → Living Room" | "None; use Map Rooms By Name" |
| `Add Light` | DYNAMIC_LIST | Unimported lights sorted by Hue room then name: "Porch [Outdoor] #53"; the suggested re-link target (same name as a missing light) first and pre-selected; last entry "(refresh)" | one entry "(no unimported lights)" |
| `Into Room` | DYNAMIC_LIST | Control4 rooms as "Floor / Room" from the hierarchy; pre-selected to the mapped room of the selected light's Hue room, else blank; first entry "(mapped room)" meaning "use the mapping" | "(no rooms found; see log)" |
| `Missing Lights` | DYNAMIC_LIST | Registry entries gone from the bridge or whose device is unlinked: "Hallway Lamp (device 2043, gone since 10-21)" | "(none)" |
| `Unlinked Devices` | DYNAMIC_LIST | `hue_light`/`hue_scene` devices in the project not in a registry: "Hue Light 'Desk Lamp' (device 2099, Hall)" | "(none)" |
| `Hue Room` | DYNAMIC_LIST | Hue rooms, then zones ("Downstairs (zone)"), each with its mapping: "Kitchen → Kitchen", "Porch → (unmapped)" | "(no rooms on bridge)" |
| `Maps To Control4 Room` | DYNAMIC_LIST | Same source as `Into Room`, plus "(no mapping)" | as above |
| `Add Scene` | DYNAMIC_LIST | Unimported scenes of the selected `Hue Room`: "Relax [Kitchen]" (dynamic scenes suffixed "(dynamic)"); "(refresh)" last | "(pick a Hue room first)" / "(no unimported scenes)" |

Actions (all plain, no params, OS 3.3-safe): `Add Selected Light`, `Import
All New Lights`, `Re-link Selected Device To Selected Light` (uses `Missing
Lights` or `Unlinked Devices` + `Add Light`), `Link Devices` (adopt by rid or
exact name, report), `Forget Selected Light`, `Adopt Hue Names`, `Accept
Names As They Are`, `Set Room Mapping`, `Remove Mapping`, `Map Rooms By
Name`, `Room Audit`, `Add Selected Scene`, `Add All Scenes Of Room`. The
existing `Import Lights` becomes `Import All New Lights`. Light and scene
devices get `Adopt Hue Name` and `Forget This Light`/`Forget This Scene`.

- "(refresh)": selecting it runs a resync (lights, devices, connectivity,
  rooms, zones, scenes) and re-reads the project hierarchy, rebuilds every
  list, then resets the property to blank. It is the only selection that
  does anything by itself.
- Empty lists hold exactly one explanatory entry; every action rejects it
  with a `Last Action` message rather than failing silently.
- A click while a resync or import is running is refused with "Busy:
  importing; try again in a moment".
- Dynamic action parameters would be neater than property + action pairs
  but are not relied on: the fundamentals mention dynamic lists in Actions
  only via a sample driver [verified: Fundamentals 15/_2], and dynamic
  commands are 4.1+ [verified: design.md].
- Registry additions for lights: `id_v1`, `hue_room_rid`, `hue_room_name`,
  `created_room_id`, `created_at`, `last_seen`, `missing_since`,
  `name_dismissed` (the Hue name the owner accepted differing from).

## 7. Open questions for the owner (with recommended defaults)

1. **Bulk import and unmapped rooms**: skip unmapped lights and list them
   (recommended), or put them in the bridge's room as the scaffold did?
2. **Room scene device names**: `<Scene>` placed in the mapped room
   (recommended) or `<Room> <Scene>` everywhere for programming-list
   clarity? Zone scenes get the zone prefix either way.
3. **Auto-adopt on `HUE_HELLO`**: automatic when a bound device carries a
   rid the bridge lacks (recommended), or always a click via `Link Devices`?
4. **Forgetting registry entries whose device was deleted in Composer**:
   automatic with a log and one `Attention` line (recommended), or keep the
   dead entry until `Forget`?
5. **`Map Rooms By Name`**: run it once automatically at the first resync
   after this build (it only fills exact matches and only affects future
   adds), or require the click (recommended, to stay consistent)?
6. **Scene OFF**: turn the scene's room/zone off through `grouped_light`
   (recommended; what a Control4 user expects of a switch), or only clear
   the toggle state and leave the lights alone?
7. **Dynamic scenes**: default `Recall As` = "As set in Hue" (`active`,
   recommended) or always "Static" so a Control4 ON is predictable?
8. **Offline threshold for `Attention`**: 24 h (recommended), or never nag
   about offline lights at all (they are usually wall-switched lamps)?
9. **`Add Light` with zero mapping and no `Into Room` chosen**: refuse
   (recommended) or default to the bridge's room with a message?
10. **Name-difference nagging**: show the count in `Attention` until
    dismissed (recommended), or never, leaving `Hue Name` as the only hint?
11. **Hue `delete` events for a light**: treat as missing immediately
    (recommended) or wait for the next full GET to confirm?
12. **Import of the 47 existing lights' rooms**: after mapping, do you want
    `Room Audit` to print the drag list for the whole project, or would a
    one-off "Forget all, delete all, import again with mappings" be
    acceptable while nothing references the devices yet? (Recommended:
    audit and drag; deletion loses nothing today, but the audit is the path
    that still works next year.)
