# Lights, rooms and scenes: lifecycle contract

The contract for two features: **import-ui** (add lights one at a time or in
bulk into chosen Control4 rooms, with a Hue room → Control4 room mapping and
the lifecycle handling that makes later manual fixes easy) and **scenes**
(one Control4 switch per Hue scene). It condenses the three research
documents written first — `docs/edge-cases-hue.md` (the bridge side),
`docs/edge-cases-control4.md` (Director and Composer), `docs/edge-cases-ux.md`
(what is automatic, offered or forbidden) — into decisions. Where the three
disagreed, the resolution is stated and marked **[resolved]**. Everything
marked **[Q n]** is an open question in §10 with the default the text uses.

Status markers as in the research documents: [verified: …], [assumed],
[community: …]. The research documents hold the evidence; this one holds
the decisions. `docs/lights-design.md` stays the contract for what already
exists (messages, coalescer, light driver mapping); this document extends it.

## 1. Three rules

1. **The project is the owner's.** The driver creates, renames, binds,
   unbinds or re-points a Control4 device only from an action the owner
   clicked. `C4:AddDevice` is documented for user-initiated use only
   [verified: API 9/_0.1]; nothing in an event, a resync or a startup ever
   creates or removes a device, and nothing ever moves one (no API exists
   [verified: sweep of the API docs]).
2. **Nothing is lost by waiting.** Every detected change (new light, gone
   light, rename, room move, deleted device) is cached, counted in a bridge
   property and logged, so the owner can act on it from Composer whenever he
   likes, without the Hue-side event having to recur.
3. **The Control4 device is the identity; the Hue rid is re-pointable.**
   Programming, Advanced Lighting Scenes and Navigators reference the proxy
   id [verified: PP 64/_0]. Replacing a bulb, a bridge or a scene must never
   mean deleting a device: the registry entry keeps the device and swaps the
   rid. Each light also persists its own rid, name and model, so a lost
   bridge registry is rebuilt from the lights instead of a second import
   doubling the project.

## 2. Scope and order

| Feature | Branch | Contents |
| --- | --- | --- |
| **import-ui** | `import-ui` from `main` | Registry v2 and its states (§3); messages (§4); resync growth and reconciliation (§5); bridge properties and actions incl. `Add Light`, `Import All New Lights`, room mapping, Re-link, Forget, Link Devices, Adopt Hue Names (§6); light-side changes (§7); picker mechanics (§8); the ALS flag [Q 13]. |
| **scenes** | `scenes` from `main`, after import-ui merges | `hue_scene.c4z` switch per Hue scene; scene registry; `Add Scene` / `Add All Scenes Of Room`; `status.active` mirroring; recall options (§9). Its contract is §9 here; it reuses everything in §3–§8. |
| Later, not now | — | Bridge replacement adoption (`replacesbridgeid`, Re-link By Name/MAC — detection and a clear message are in import-ui, automation is not); smart scenes (24 h scenes); `Push Names To Hue`; room devices (grouped_light); Composer-tree nesting (3.4.2+ only). |

Both features change `driver.xml` (new properties, actions, a new driver),
so each ends with a Composer "Update Driver" of the bridge and the light,
and scenes adds a new `hue_scene.c4z`. Lua-only steps in between go through
the dev loop as usual.

## 3. Registry v2

Persisted on the bridge under `hue_lights` as today, keyed by rid; existing
v1 entries `{device_id, proxy_id, name, model, caps}` are upgraded in place
at late init (missing fields filled from the next resync; `state = "linked"`).

```
hue_lights[rid] = {
  device_id, proxy_id,            -- today; proxy id from AddDevice's info or
                                  -- GetBoundConsumerDevices(device_id, 5001), never derived
  name, device_name, model, caps, -- today + the Hue device's name (what the Hue app shows)
  device_rid, mac_address,        -- owner device; zigbee_connectivity.mac_address (recovery key)
  service_id, id_v1,              -- multi-light devices; "#12" for list labels
  hue_room_rid,                   -- derived at every resync/room event, cached for display
  state,                          -- "linked" | "gone" | "unbound" | "tombstone"
  gone_since, unbound_since,      -- os.time() when the state was entered
  created_room_id, created_at,    -- where and when AddDevice put it
  name_dismissed,                 -- the Hue name the owner accepted differing from [Q 10]
}
hue_rooms[group_rid] = { c4_room_id, c4_room_name, hue_name, type = "room"|"zone" }
hue_tombstones[rid] = { name, device_name, deleted_at }   -- see "tombstone" below
```

States and what moves an entry between them:

| State | Meaning | Entered by | Shown as |
| --- | --- | --- | --- |
| `linked` | device exists, bound, rid on the bridge | import, `Add Light`, Re-link, Link Devices, auto-adopt | light `Status`: "Desk Lamp (Hue white and color ambiance)" |
| `gone` | device exists, rid no longer on the bridge | a light `delete` event [Q 11] or a full successful GET without the rid | light `Status`: "Gone from the Hue bridge since <date>; re-link or Forget"; `ONLINE_CHANGED false`; bridge `Lights` counts it as missing |
| `unbound` | device exists but is not bound to this bridge | startup reconcile (`GetBoundConsumerDevices` lacks the id while `GetDevices` still returns it) or `OnBindingChanged(false)` | bridge `Lights`: "1 unbound device"; the light shows its existing "Not bound to a Hue Bridge" |
| `tombstone` | the device was deleted in Composer | `HUE_GOODBYE`, or reconcile finds the id in neither the bound set nor `GetDevices` | moved to `hue_tombstones`; the rid is listed in `Add Light` as "Desk Lamp #12 (deleted from Composer <date>)" |

**[resolved]** The UX document auto-forgets a deleted device's entry; the
Control4 document keeps a tombstone so an import never silently re-creates
what the owner deleted; the Hue document calls it `unbound`. The contract
does all three in order: the entry leaves `hue_lights` (so Re-link and
Forget targets stay clean), a tombstone remembers it, **`Import All New
Lights` skips tombstoned rids** and lists them, and only `Add Light` (a
deliberate single add) re-creates such a light, which clears the tombstone
[Q 4].

A `gone` entry is never dropped on its own: a bulb deleted by mistake in the
Hue app is re-added in minutes with a new rid [assumed: UUIDs are minted per
device record], and its programming must survive. `Re-link` (swap the rid,
keep everything else) and `Forget` are the exits.

## 4. Messages (additions to `docs/lights-design.md`)

| Command | Direction | Params | When |
| --- | --- | --- | --- |
| `HUE_HELLO` | light → bridge | `rid`, **`device_id`** (new), `name`, `model` (the light's persisted copies) | as today; `device_id` lets the bridge adopt a bound light whose rid the registry lacks |
| `HUE_GOODBYE` | light → bridge | `rid`, `device_id` | from the light's `OnDriverRemovedFromProject` [verified: API 22/_26; assumed `SendToDevice` works there — probe 2] |
| `HUE_FORGET` | light → bridge | `rid`, `device_id` | from the light's `Forget This Light` action; the bridge runs Forget for that entry and answers `HUE_FORGOTTEN` |
| `HUE_FORGOTTEN` | bridge → light | `rid`, `name` | after `Forget`; the light shows "Forgotten by the bridge (was Hue light Desk Lamp #12). Delete this device in Composer, or bind it again and use Link Devices" and drops proxy commands |
| `HUE_CONFIGURE` | bridge → light | as today **plus `hue_room`** (Hue room name or ""), **`id_v1`**, **`state`** ("linked"/"gone") | as today, and after every room or state change |
| `HUE_STATE`, `HUE_SET`, `DEV_RELOAD` | — | unchanged | — |

Early messages: a `HUE_HELLO` that reaches the bridge before its registry is
loaded is queued and answered after `configure_all` (today it is lost and
only `configure_all` saves it) [verified: hardware log "HUE_HELLO from
unregistered light" × 47 after every bridge reload]. A `HUE_CONFIGURE` or
`HUE_STATE` that reaches a light before its `OnDriverLateInit` is buffered
and applied after it (`UpdateProperty`/`SendToProxy` are unsafe before late
init [verified: API 22/_25.2]).

Auto-adopt **[resolved, Q 3]**: on `HUE_HELLO` with a rid the registry
lacks, a `device_id`, and no other entry holding that rid: register
`{device_id, name, model, state="linked"}` and complete it from the model at
the next resync; log "adopted Desk Lamp (device 2043) from its own
persisted rid". Two devices claiming one rid: neither is adopted and
`Attention` names both. All three documents agree this is automatic: the
device itself is the evidence and nothing in the project changes.

## 5. Resync and reconciliation

The resync after every stream (re)connect grows from `/light`, `/device`,
`/zigbee_connectivity` to also `/room`, `/zone`, `/bridge_home` and (for
scenes) `/scene`. Probe 8 measures the single `GET /clip/v2/resource`
[verified: CLIP API list] against seven serial GETs; the coordinator picks
whichever stays under about two seconds on the house bridge.

Reconciliation runs after every resync, before the per-light `HUE_STATE`
fan-out, in this order:

1. **Project side** (cheap, two calls): `GetBoundConsumerDevices(bridge, 1)`
   and `GetDevices({C4iNames="hue_light.c4z"})` [verified: API 32/_3, 22/_9].
   Entry id bound → fine; present but not bound → `unbound`; absent from both
   → tombstone. A failed or empty `GetDevices` means "unknown", never
   "deleted" [assumed: semantics of a deleted id — probe 2].
2. **Lights**: registry rid absent from `/light` → `gone` (+ `ONLINE_CHANGED
   false`); back again → `linked`; rid on the bridge with no entry and no
   tombstone → the `Add Light` list, with a hint when a `gone` entry has the
   same `mac_address` or the same name ("looks like Hallway Lamp; re-link?").
3. **Rooms**: device → room from `room.children` (devices), light → zones
   from `zone.children` (lights) [verified: Core Concepts]; refresh
   `hue_room_rid`, every mapping's `hue_name`, and each light's `Hue Room`
   through `HUE_CONFIGURE`. Compare each linked device's Control4 room
   (`GetDevices` → `roomId`) with the room its Hue room maps to; mismatches
   feed `Room Audit`, nothing else.
4. **Scenes** (feature scenes): §9.
5. Rebuild `Attention`, `Lights`, `Room Mappings` and every picker list; then
   the `HUE_STATE` fan-out as today.

Stream events keep doing what they do today (per-light state, names), plus:
`add` of a light → cache + `Add Light` list + `Attention`; `delete` of a
light → `gone` [Q 11]; room/zone `update` → step 3 for the affected rooms.
Every handler is idempotent and resolves owners through the cache, because
`delete` items carry only id and type [community: aiohue] and item order
within a container is undocumented.

The bridge also gets `OnBindingChanged` (log all five params; a `false` for
binding 1 marks the entry `unbound` and re-enumerates one second later, as
the SDK sample does [verified: sample idc_controller]) and
`OnBindingValidate` accepting only `HUE_BRIDGE` [verified: API 32/_26].

## 6. Bridge properties and actions

Read-only properties:

| Property | Contents | Empty |
| --- | --- | --- |
| `Lights` (exists) | "47 on bridge, 47 imported, 2 new, 1 missing, 0 unbound, 1 deleted" | "0 imported" |
| `Attention` (new) | up to six items joined with "; ": new lights, missing lights, unbound devices, name differences [Q 10], broken mappings, offline > 24 h [Q 8] | "None" |
| `Last Action` (new) | result of the last click: "Added Porch to Outdoor (device 2051)", "Not added: pick a light first" | "" |
| `Room Mappings` (new) | "Hall → Hall; Kitchen → Kitchen; Office → (Control4 room gone); Porch → (unmapped); Downstairs (zone) → Living Room" | "None; use Map Rooms By Name" |

Actions (all plain `LUA_ACTION`s; the two with pickers carry
`CUSTOM_SELECT` params, §8):

| Action | Params | Does |
| --- | --- | --- |
| `Add Light` | `Light` (unimported + tombstoned rids), `Room` (Control4 rooms, default "(mapped room)") | one `AddDevice` into the chosen room; mapping only pre-selects [Q 9]; clears a tombstone |
| `Import All New Lights` (renames `Import Lights`) | — | every unimported, non-tombstoned rid into its mapped room; **skips** lights whose Hue room is unmapped and lists them in `Last Action` [Q 1]; idempotent by rid; never renames, moves or rebinds |
| `Re-link Device To Light` | `Device` (gone + unbound entries), `Light` (unimported rids) | swaps the rid in the entry; `HUE_CONFIGURE` with the new caps; device, name, room, bindings, programming untouched |
| `Link Devices` | — | adopts bound `hue_light` devices the registry lacks: by the rid they announce, else by exact unique name; reports each |
| `Forget Light` | `Device` (any entry) | removes the entry, `C4:Unbind(device, 1)` [verified: API 9/_19], sends `HUE_FORGOTTEN`; the device stays for the owner to delete; the rid returns to `Add Light` |
| `Adopt Hue Names` | — | `C4:RenameDevice(proxy_id, hue name)` for every linked device whose Composer name differs [verified: API 22/_32]; lists the renames |
| `Accept Names As They Are` | — | records `name_dismissed` for every current difference [Q 10] |
| `Set Room Mapping` | `Hue Room` (rooms, then zones), `Room` (Control4 rooms + "(no mapping)") | writes `hue_rooms` |
| `Map Rooms By Name` | — | exact, case-insensitive, trimmed matches only; never overrides; reports [Q 5] |
| `Room Audit` | — | lists every linked device whose Control4 room differs from its Hue room's mapping: "Desk Lamp is in Hall; Hue says Office → drag it to Office in Composer if you want it there" [Q 12] |
| `Lights Report` (exists) | — | now also prints state, Hue room, MAC and tombstones |

Everything a click does is also a log line; a click during an import or a
resync is refused with "Busy: importing; try again in a moment"; empty
pickers hold one explanatory entry that the action rejects into `Last
Action`.

Rooms come from `C4:GetDevicesByC4iName("roomdevice.c4i")` → `{[roomId] =
name}` [verified: Control4's own `lib.lua` uses it; undocumented in the API]
with floor names from `C4:GetProjectHierarchy()` [verified: API 22/_15;
its `type` strings are undocumented — probe 4]. Labels: "Floor / Room",
room id appended when two rooms share a name.

## 7. Light-side changes

- Persist `hue_name` and `hue_model` next to `hue_rid`; send them in
  `HUE_HELLO` with `device_id = C4:GetDeviceID()`.
- `OnDriverRemovedFromProject` → `HUE_GOODBYE`.
- Buffer `HUE_CONFIGURE`/`HUE_STATE` until late init.
- New read-only property `Hue Room`; `Status` texts for `gone` and
  forgotten; `Hue Light ID` shows "#12 (rid…)" when `id_v1` is known.
- Actions `Adopt Hue Name` (rename this device's proxy to the Hue name) and
  `Forget This Light` (asks the bridge to Forget it).
- **ALS** [Q 13]: `reduced_als_support = True` in `driver.xml` plus
  `SET_BRIGHTNESS_STOP` / `SET_COLOR_STOP` handlers (stop = settle the pending
  target at the light's current reported value) [verified: PP 63/22]. Both
  flags are False today, which keeps every Hue light out of Advanced Lighting
  Scenes.
- Names: the Control4 name is set once at creation and then belongs to the
  owner; no rename ever happens from an event. The creation name is the Hue
  **device** name for single-light devices (the Hue app shows the device
  name; `light.metadata` is deprecated in the reference [community:
  openhue]) and the light's own name for multi-light devices.

## 8. Picker mechanics

**[resolved]** The UX document proposed `DYNAMIC_LIST` properties plus
plain actions (comma-delimited, not persisted, three clicks per add); the
Control4 document proposed `CUSTOM_SELECT` action parameters. The
Fundamentals say `CUSTOM_SELECT` "is available for both actions and
commands", that the List type works on operating systems before 4.0.0 and
that only Search and Filter are "inconsistent" there [verified: FUND 12.3
Overview]. The contract therefore uses **`CUSTOM_SELECT` List params** on
`Add Light`, `Re-link Device To Light`, `Forget Light` and `Set Room
Mapping`: one click opens a dialog with the dropdowns, which is the
behaviour the owner described from the original Hue driver. Each list is
built on demand by the named Lua function from the last resync (no
persistence problem, no comma problem); entries are `{text, value}` pairs
where `value` is the rid or room id and `text` is "Porch [Outdoor] #53" /
"Ground / Kitchen". Composer 3.x rendering is confirmed once on the first
dev build with the new `driver.xml` (probe 7); the fallback, if it renders
badly, is the `DYNAMIC_LIST` scheme from `docs/edge-cases-ux.md` §6, which
the same list-building functions can feed.

## 9. Scenes (feature `scenes`, contract to be finalised after import-ui)

- One **`hue_scene.c4z`** per scene: a `light_v2` switch (`<dimmer>False`),
  consumer binding 1 `HUE_BRIDGE` like a light, never a flipped `hue_light`
  (a driver must not change its proxy type across updates [verified: FUND
  14/_2]). Registry `hue_scenes[rid] = {device_id, proxy_id, name,
  group_rid, group_name, group_type, recall_as, state, …}` with the same
  states as lights.
- Created only by `Add Scene` (`Hue Room` picker then `Scene` picker) or
  `Add All Scenes Of Room`; placed in the mapped room unless `Room` is
  chosen. Hue creates about seven default scenes per room, so nothing is
  auto-created. Room scene device name `<Scene>` [Q 2]; zone scenes
  `<Zone> <Scene>`.
- ON = `PUT /clip/v2/resource/scene/<rid> {"recall":{"action":"active"}}`
  (`active` honours `auto_dynamic`; per-device `Recall As` chooses
  `active`/`static`/`dynamic_palette`) [community: openhue/aiohue; PUT exists
  verified: CLIP API list] [Q 7]. OFF = the scene's group `grouped_light`
  off, coalesced per group (1/s limit) [Q 6].
- State: ON while `status.active` is `static`/`dynamic_palette`, OFF when
  `inactive`, from `scene` stream items (seen on hardware inside a
  grouped_light container [verified: hardware 2026-10-21]) and from `/scene`
  in every resync; one forum post claims no event for app recalls, so probe 10
  tests app, Hue-dimmer and API triggers.
- A scene deleted in Hue keeps its device: `Status` explains, ON logs and
  reports OFF at once, `Re-link Scene` and `Forget` are offered. Smart scenes
  are not in v1 (listed in the log only).

## 10. Open questions for the owner

Defaults in **bold** are what the text above assumes.

1. Bulk import, unmapped Hue rooms: **skip and list them** (never a
   surprise) or put them in the bridge's room as the scaffold did?
2. Room scene device names: **`<Scene>`** in the mapped room, or `<Room>
   <Scene>` everywhere for programming-list clarity?
3. Auto-adopt on `HUE_HELLO`: **automatic** when exactly one bound device
   carries a rid the bridge lacks, or always a click (`Link Devices`)?
4. A light deleted in Composer: **tombstone, skipped by bulk import,
   re-creatable only by `Add Light`**, or forget it entirely so bulk import
   brings it back?
5. `Map Rooms By Name`: **run once automatically** at the first resync of
   the new build (exact matches only, affects only future adds) or require
   the click? (The UX document recommends the click; the default here is
   the one-time run because all 47 lights already exist and it makes
   `Room Audit` useful immediately.)
6. Scene OFF: **turn the scene's room/zone off** (what a switch suggests) or
   only clear the toggle?
7. Dynamic scenes: **`Recall As` = "As set in Hue"** (`active`) or always
   static for a predictable Control4 ON?
8. `Attention` nag for offline lights: **24 h**, or never (most of the
   house's lamps are on wall switches)?
9. `Add Light` with no mapping and no room chosen: **refuse with a message**
   or default to the bridge's room?
10. Hue-name differences: **count them in `Attention` until dismissed**, or
    never, leaving `Hue Name` as the only hint?
11. A Hue `delete` event for a light: **mark `gone` immediately** or wait for
    the next full GET?
12. The 47 lights already in the bridge's room: **`Room Audit` prints the
    drag list** and you drag them, or a one-off "Forget all, delete all,
    import again with mappings" while nothing references them yet? (Audit is
    the path that still works next year; deletion costs nothing today.)
13. **Enable Advanced Lighting Scene membership** (`reduced_als_support`,
    needs the light `driver.xml` update) now, or leave Hue lights out of ALS?

## 11. Hardware probes (dev loop unless marked Composer)

Run before or alongside the build; results go into `docs/design.md`.

1. Log all five `OnBindingChanged` params in both drivers across a Director
   restart and a bind/unbind in Composer (Composer for the bind).
2. Delete one unpowered test light in Composer (Composer): what the bridge
   sees (`OnBindingChanged`, `HUE_GOODBYE`, system events), what
   `GetDevices` returns for the dead id, whether `SendToDevice` to it errors.
3. Register `OnItemAdded/NameChanged/Removed/Moved`, `OnDeviceUserInitiatedRemove`
   and `OnPIP`; dump their XML while renaming, moving and deleting a light
   and a room (Composer).
4. Dump `GetProjectHierarchy()` and `GetDevicesByC4iName("roomdevice.c4i")`;
   record the `type` strings and whether floors appear.
5. `UpdateProperty("Nonexistent", "x")` and `SendToDevice(99999, …)`: error or
   silence.
6. Add a bare `hue_light` by hand (Composer): Status, tile, the rid-less
   `HUE_HELLO`; bind it; confirm auto-adopt refuses (no rid) and `Link
   Devices` by name works.
7. First dev build with the new `driver.xml`: how Composer 3.x renders the
   `CUSTOM_SELECT` dialogs (Composer).
8. `GET /clip/v2/resource` size and time on the house bridge; `/room`,
   `/zone`, `/scene` sizes.
9. Rename a light via PUT `/device/<id>` and via PUT `/light/<id>`: which
   resources emit updates, in which order.
10. Scenes: recall from the app, from a Hue dimmer and via API; confirm the
    `scene` status items; create and delete a throwaway zone with a scene and
    log the delete cascade.
11. Spare bulb (when one is available): add, delete, re-add in the Hue app;
    compare rids and `mac_address`.

## 12. Build split for import-ui (one writer per file)

| Agent | Owns | Done when |
| --- | --- | --- |
| Registry & reconcile | `src/hue_bridge/bridge/registry.lua` (new: v2 records, states, tombstones, migration, reconcile against bound/present sets), `tests/spec/registry_spec.lua` | specs cover every state transition in §3 and the v1 upgrade |
| Groups model | `src/hue_bridge/bridge/groups.lua` (new: rooms, zones, bridge_home → device/light membership; labels), `hue_model.lua` additions for `/room`, `/zone`, `/device` MAC, `id_v1`, `service_id`; `tests/spec/groups_spec.lua`, `hue_model_spec.lua` | fixtures from the house bridge parse; room moves update membership |
| Lights integration | `src/hue_bridge/bridge/lights.lua` (resync growth, reconciliation order, `add`/`delete` events, auto-adopt, re-link/forget/link, early-HELLO queue), `tests/spec/lights_spec.lua`, `roundtrip_spec.lua` | the §5 order is observable in specs; import skips tombstones and unmapped rooms |
| Light driver | `src/hue_light/driver.lua`, `light/state.lua`, `driver.xml`, `tests/spec/light_driver_spec.lua` | §7 complete, incl. buffering and ALS stops |
| Fake runtime | `tests/helpers/fake_c4.lua` (`GetDevices`, `GetDevicesByC4iName`, `GetProjectHierarchy`, `Unbind`, `RenameDevice`, `OnBindingChanged` delivery, CUSTOM_SELECT param plumbing), `fake_harness_spec.lua` | the other agents' specs run against it |
| Coordinator | `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml` (properties, actions, CUSTOM_SELECT params), `docs/`, `CLAUDE.md`, probes through the dev loop, integration, Composer instructions | lint, tests, `tools/build.sh`, hardware probes 1–9 recorded |

Dependencies: the registry and groups modules are pure Lua and need nothing
from the others; the light driver and the fake runtime are independent of
them; the lights integration consumes registry, groups and the fake's new
calls, so it starts once those three have landed. The coordinator does the
bridge `driver.lua`/`driver.xml` work and the probes in the meantime. The
interfaces every agent builds against are §13.

## 13. Module interfaces

Signatures are the contract; bodies are the agent's. Every module stays
pure Lua 5.1 (no C4 calls) except where a C4 call is the module's purpose.

### `bridge/registry.lua`

Persistence through injected functions, as `lights.lua` does today
(`persist_get(name)`, `persist_set(name, value)`); `now` injected for tests.

```lua
local registry = require("bridge.registry")
local reg = registry.new({ persist_get = fn, persist_set = fn, now = os.time, log = log })
reg:load() -> counts            -- reads "hue_lights", "hue_rooms", "hue_tombstones";
                                -- upgrades v1 entries in place (state = "linked", other new fields nil)
reg:save()                      -- writes the three keys; callers save after a batch of changes
reg:get(rid) -> entry | nil
reg:by_device(device_id) -> rid, entry | nil
reg:add(rid, fields) -> entry   -- new "linked" entry, created_at = now(); clears a tombstone for rid;
                                -- returns nil, "exists" when rid already has an entry
reg:update(rid, fields) -> entry | nil        -- shallow merge; nil for an unknown rid
reg:set_state(rid, state) -> changed          -- stamps gone_since / unbound_since when entering, clears when leaving
reg:relink(old_rid, new_rid) -> entry | nil, err   -- moves the entry under new_rid, state "linked"; refuses when
                                                   -- new_rid has an entry; clears a tombstone for new_rid
reg:forget(rid) -> entry | nil                -- removes the entry, no tombstone
reg:tombstone(rid) -> tomb | nil              -- removes the entry; hue_tombstones[rid] = { name, device_name, deleted_at }
reg:tombstones() -> table rid -> tomb
reg:clear_tombstone(rid)
reg:rids(state?) -> array of rids sorted by name (every state when nil)
reg:entries() -> the table rid -> entry (read-only use)
reg:counts() -> { linked = n, gone = n, unbound = n, tombstones = n }
reg:reconcile({ bound = { [device_id] = true }, present = { [device_id] = true } | nil })
    -> { unbound = { rid... }, relinked = { rid... }, tombstoned = { rid... } }
    -- bound: devices bound to the bridge now; present: hue_light devices in the project, nil = unknown.
    -- linked and not bound but present → "unbound"; unbound and bound again → "linked" (relinked);
    -- not bound and not present (present known) → tombstone. With present nil nothing is tombstoned.
reg:room_mapping(group_rid) -> mapping | nil
reg:set_room_mapping(group_rid, { c4_room_id, c4_room_name, hue_name, type })
reg:remove_room_mapping(group_rid)
reg:room_mappings() -> table group_rid -> mapping
```

Entry fields are §3's. `state` is one of `"linked"`, `"gone"`, `"unbound"`;
tombstones live in their own table.

### `bridge/groups.lua` and `hue_model.lua` additions

```lua
local groups = require("bridge.groups")
local g = groups.new()
g:absorb(items)          -- array of raw CLIP items of type room / zone / bridge_home (a full GET);
                         -- replaces every cached group of each type that appears in items
g:apply(item, kind)      -- one stream item, kind "update" | "add" | "delete"; returns true when something changed
g:group(rid) -> { rid, type = "room"|"zone"|"bridge_home", name, children = { rid... },
                  child_rtype = "device"|"light"|"room", grouped_light_rid, id_v1 } | nil
g:groups(type?) -> array sorted by name; nil = rooms then zones
g:room_of_device(device_rid) -> group_rid | nil
g:zones_of_light(light_rid) -> array of zone rids (sorted by name)
g:label(rid) -> "Kitchen" | "Downstairs (zone)" | "(no room)" for nil or unknown
```

`hue_model.group(item)` parses one raw room/zone/bridge_home item into the
shape above (children as `{ rid, rtype }` pairs reduced to rids plus one
`child_rtype`; `services` give `grouped_light_rid`); `hue_model.update_group(group,
item)` merges a partial update (a `children` array replaces the whole list).
`hue_model.light(item)` gains `id_v1` and `service_id`;
`hue_model.connectivity(item)` gains `mac_address`;
`hue_model.configure_params(light, device, extra)` and
`hue_model.registry_configure_params(rid, entry, extra)` merge the string
fields of `extra` (`hue_room`, `id_v1`, `state`) into the result.

### `tests/helpers/fake_c4.lua` additions

A project model shared by every env of one harness run:
`fake.project = { rooms = { [id] = { name, floor_id, floor_name } }, devices = { [id] = { name, room_id, c4i, proxy_id } } }`,
with `fake.add_room(id, name, floor_id, floor_name)`, `fake.move_device(id, room_id)`,
`fake.rename_room(id, name)`, `fake.delete_room(id)` and
`fake.delete_device(id)` (runs that driver env's `OnDriverRemovedFromProject`
then `OnDriverDestroyed("DIT_LOADED")`, removes its bindings and delivers
`OnBindingChanged(…, false, …)` to the other side, removes it from the
project). `C4:AddDevice` registers the new device (and its proxy) in the
project under the room it was given.

New C4 methods, shapes from the API docs named in `docs/edge-cases-control4.md` §0:
`C4:GetDevices(filter, locationFilter)` (filter `{ DeviceIds = {…} }` or
`{ C4iNames = "hue_light.c4z" }`; returns `{ [id] = { deviceName, roomId,
roomName, driverFileName, proxies, protocol } }`), `C4:GetDevicesByC4iName(c4i)`
(`{ [id] = name }`; `"roomdevice.c4i"` lists the rooms),
`C4:GetProjectHierarchy(location?)`, `C4:Unbind(consumerId, consumerBinding)`
(delivers `OnBindingChanged(…, false, …)` to both envs of a pair, as `C4:Bind`
delivers `true`), `C4:RenameDevice(id, name)` (recorded in `c4.renamed`,
project updated), `C4:GetDeviceDisplayName(id)`. `fake.custom_select(env,
fn_name, ...)` calls the named global list function of a driver env and
returns its list, for CUSTOM_SELECT specs.

### Light driver (`src/hue_light/*`)

`HUE_HELLO` carries `rid`, `device_id` (`C4:GetDeviceID()`), `name`, `model`
(persisted as `hue_name`, `hue_model` next to `hue_rid`, refreshed from each
`HUE_CONFIGURE`). `OnDriverRemovedFromProject` sends `HUE_GOODBYE { rid,
device_id }`. `HUE_FORGOTTEN` sets the forgotten `Status` text, `Online`
"Offline", `ONLINE_CHANGED false`, and drops proxy commands with that
reason. `HUE_CONFIGURE`/`HUE_STATE` received before `OnDriverLateInit` are
buffered and applied after it. New property `Hue Room` (read-only); `Hue
Light ID` shows "#12 (e0e51794…)" when `id_v1` is known. `Status` for state
"gone": "Gone from the Hue bridge since <date>; re-link or Forget". Actions:
`Adopt Hue Name` (`C4:RenameDevice(proxy_id, hue name)`; the proxy id is the
first key of `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 5001)` [verified:
hardware]) and `Forget This Light` (sends `HUE_FORGET`). `driver.xml`:
`reduced_als_support` True; `SET_BRIGHTNESS_STOP` and `SET_COLOR_STOP` settle
the pending target by reporting the cached value as CHANGED.
