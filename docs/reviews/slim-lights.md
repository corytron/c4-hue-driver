# Slimming review: lights.lua, registry.lua, groups.lua (2026-10-24)

Area: `src/hue_bridge/bridge/lights.lua` (2761 lines), `registry.lua` (569),
`groups.lua` (249): 3579 lines. Safety net: `tests/spec/lights_spec.lua`
(1902), `registry_spec.lua` (633), `groups_spec.lua` (349). `driver.lua` was
read as the caller only; it was being edited while this review ran (1812 lines
at the start, 1864 at 17:16), so its line numbers below are as of 17:16 and
will drift. The three reviewed files did not change (lights.lua last written
14:20 today, registry.lua 2026-10-22, groups.lua 2026-10-21). Brief:
`slim-2026-10-24-brief.md`; hardening that stays: `docs/code-analysis-2026-10-22.md`.

## 1. Summary

The three modules are 3579 lines today. The low-risk rows below (1–13) take
about 180 lines out of them (lights −122, registry −6, groups −52) and, once
the shared helper module exists, a further ~120 out of `scenes.lua` and
`zone_lights.lua` (the other reviewer's files), for a bridge-wide net of about
−260 after the two new shared pieces (+70 `bridge/util.lua`, +22 in
`hue_model.lua`). The medium-risk rows (14–15) are worth another ~130 in
these files (~210 bridge-wide) but merge lifecycle code across three modules,
which the brief's rule 4 ranks low. The event path itself is lean: no timers
in these modules (the busy guards expire lazily, lights.lua:1600-1620), no
debug `string.format` runs on the event path (`common/log.lua:28-37` formats
after the level check; the only debug lines are at load 453, absorb 884, the
foreign-device branch of `tell` 342 and goodbye 1150), no JSON re-encoding,
one dirty-gated save per container (1591, 466-471). The biggest runtime wins
are (a) in the caller: `refresh_lights_props()` runs three times per stream
reconnect (driver.lua:523, 534, 548, after the lights', zone lights' and
scenes' resyncs) and each run makes one `C4:GetDeviceDisplayName` per linked
light through `attention()` → `name_differences()` (lights.lua:2530,
2140-2153, 635-644) plus two `project_rooms()` (2541, 2586): with 47 lights
imported that is ~150 Director calls per reconnect where one refresh after the
chain would make ~50; (b) per event, `tell()` rebuilds the zone-light skip set
for every HUE_STATE it sends (340-348 → 330-336 → 312-327 → driver.lua:235-239
→ zone_lights.lua:358-365): two tables and a scan of the zone registry per
message, removable with a per-container cache (row 6); (c) per resync and per
group event, `groups:rebuild()` computes two indexes nothing reads
(groups.lua:83-105), and `automap_once()` does a `PersistGetValue` on every
resync (lights.lua:1347-1349) for a flag that is set once (rows 2 and 7).

## 2. Proposals, ranked by benefit ÷ risk

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs | Security |
|---|---|---|---|---|---|---|---|
| 1 | lights.lua:212-218 (`positive`), 360-362 (`norm`), 366-368 (`sanitise`), 370-375 (`date_of`), 377-382 (`short_date_of`), 394-396 (`plural`), 399-408 (`some`), 411-422 (`signature`), 1422-1429 (`has_field`), 2622-2624 (`empty_list`); registry.lua:105-111 (`positive`). Same bodies in scenes.lua:206-212, 257-315, 2800-2802 and zone_lights.lua:177-234, 257-259 | One `src/hue_bridge/bridge/util.lua` holding the ten pure helpers; each module keeps a two-line alias block. Bodies are byte-identical except `has_field` (take scenes' `fields or {}`, a superset) and `some`, which reads the module's `MAX_NAMED` (3 in all three: lights.lua:47, zone_lights.lua:55, scenes') and becomes `some(names, max)`. `by_name` stays per module (scenes' uses `name_of`, scenes.lua:249-255). Optionally move `ids_from` and `dump` (lights.lua:178-282) there too, with `lights.ids_from = util.ids_from` kept as the spec-pinned name, so scenes.lua:49 and zone_lights.lua:45 stop requiring the 2761-line module for two helpers | lights −60, registry −6; scenes ≈ −60, zone_lights ≈ −55 (other reviewer); util +70; net ≈ −110 | None (same code, loaded once) | Low: pure functions moved verbatim; every owner-facing text that uses them is pinned | lights_spec "texts" 1821-1846, "pickers" 1750-1820 (1765 pins the comma rule), "names" 1285-1333, "room mappings" 1334-1486; scenes_spec and zone_lights_spec texts | Needs care: `sanitise` must keep `gsub(",", " ")` exactly (CUSTOM_SELECT lists are comma-delimited, lights.lua:364-365). One writer: util.lua + lights.lua + registry.lua in one agent; scenes/zone_lights adopt it afterwards |
| 2 | groups.lua:32-33 (fields), 83-94 (`zones_by_light` build), 96-105 (`roomless` build), 109-110, 210-216 (`zones_of_light`), 218-224 (`roomless_devices`); header 11-15 | Drop the two membership indexes and their accessors. No production caller: `grep zones_of_light\|roomless_devices src` finds only groups.lua; the zone lights read members from `group.children` directly (zone_lights.lua:510-552 `member_lights`) and the room-less list was for an import-UI feature never built | groups −46 | Per resync and per room/zone/bridge_home event (`groups:apply` rebuilds on name/children changes, 165-176): one pass over all zone children (80 on the house bridge) and the bridge_home children fewer, with their `seen` tables; two index tables fewer held for the driver's life | Low for behaviour (dead API). Needs spec and contract edits: groups_spec 190-194, 196-207 and 333-348 pin the dead accessors (the spec pinned an interface §13 listed, not a flow); docs/import-design.md:454 lists `g:zones_of_light` | groups_spec 175-189 and 209-214 (room_of_device) stay green and cover the index that is used | None |
| 3 | lights.lua:1880-1887 (`lights:import`); caller driver.lua:1162-1167 | Delete the scaffold alias. Its only caller is the unreachable fallback branch of `Import_All_New_Lights` (driver.lua:1162 tests `type(state.lights.import_new) == "function"`, always true since lights.lua:1785). No spec calls `lights:import(` (grep) | lights −8 (driver −6, coordinator) | None | Low | None reference it; import_new is pinned by lights_spec 230-492 | None |
| 4 | lights.lua:526-529 (`registered_rids`) | Delete. No caller: driver.lua:1272 calls the zone module's `registered_rids`; no spec calls it on `L` | lights −4 | None | Low | None | None |
| 5 | lights.lua:284-287 (`protocol_id_from`) | Delete the alias ("the name the import used before ids_from"). Only lights_spec:204, 217, 226 use it; change those three asserts to `lights.ids_from(...).protocol`. The spec pinned the alias, not behaviour | lights −4 | None | Low (three mechanical spec edits) | lights_spec 201-228 (ids_from) keeps pinning the parsing | None |
| 6 | lights.lua:329-348 (`foreign`, `tell`), 1567-1593 (`on_container`) | Compute `self:skip_set()` once at the top of `on_container` into a field (`skip_cache`), let `foreign()` use `self.skip_cache or self:skip_set()`, and clear the field before returning (and at entry, so an error that escaped the previous container cannot leave a stale one) | lights +5 | Per HUE_STATE on the event path (1495, 1520): two tables (`skip_set` 313, `zone_lights:device_ids` 359) and one scan of the zone registry fewer; a 47-item container saves ~94 tables | Low: the cache lives inside one `on_container` call, so the contract "consulted at each use" (lights.lua:75-83) still holds across calls, which lights_spec:1198-1239 relies on (it swaps `L.ctx.skip_devices` between calls); `zone_lights:on_container` runs after this module's (driver.lua:556-565), so the zone registry cannot change inside the cached window | lights_spec 797-989 (events), 1118-1240 (skip set) | Needs care: keep the pcall around a failing `skip_devices` (lights.lua:315-323, spec 1178) |
| 7 | lights.lua:1347-1358 (`automap_once`) | Remember the "done" read in a field (`self.automapped = true` once `persist_get` returned a value or after the run) and skip the `persist_get` on later resyncs | lights +2 | One `C4:PersistGetValue` fewer per resync (every reconnect) | Low: the persisted flag stays the source of truth across reloads; the spec checks `c4.persist.hue_rooms_automapped`, not how often it is read, and its third case builds a new `L` | lights_spec 750-773 | None |
| 8 | lights.lua:426-445 (`copy_caps`, `same_caps`); zone_lights.lua:236-256 (same, with `min_dim ... or 1`) | `hue_model.copy_caps(caps, min_dim_default)` and `hue_model.same_caps(a, b)` next to `hue_model.caps` (hue_model.lua:291-299), which already defines the five fields; both modules alias them | lights −20, zone_lights −21 (other reviewer), hue_model +22; net −19 | None | Low: pure; the only difference between the copies is the default, made a parameter | lights_spec 1847-1886 (string caps "true" → true; `L:entry` copies), 624 (caps refreshed at resync); zone_lights_spec load | None |
| 9 | lights.lua:1289-1297 and 1458-1464 (the same "new light ... re-link?" `log.always`), 2481-2483 and 2639-2642 (the same "(looks like %s, device %d; re-link?)" text) | Two local helpers, `log_new_light(model)` and `hint_text(model)`, each built from `relink_hint` (680-696) once | lights −10 | None | Low: identical format strings folded; the texts are pinned | lights_spec 722 (hint in log), 863 (add event), 1751 (picker_lights), 1832 (attention) | None |
| 10 | groups.lua:228-238 (`groups:label`) | Return `hue_model.group_label(group.name, group.type)` (hue_model.lua:1005-1015 carries the same wording). Difference: hue_model treats `""` as no name; a room or zone never has `""` (hue_model.group falls back to a name, hue_model.lua:468-470) and bridge_home has nil, so the outputs are the same. scenes.lua:319-328 `label_of` is a third copy for the other reviewer | groups −6 | None | Low | groups_spec 216-227; lights_spec texts that carry room labels (1381, 1809) | None |
| 11 | lights.lua:876 (`{ "room", "zone", "bridge_home" }` per absorb: use `groups.TYPES`), 1603 (`{ "importing", "resyncing" }` per `expire_stale_busy`, run on every action and every resync), 2649 and 2703 (per picker); registry.lua:204 (per entry at load) | Hoist the constant lists to module locals | 0 | A handful of tables fewer per action, resync and load | None | None affected | None |
| 12 | lights.lua:2581-2608 (`room_mapping_items`) and 2735-2759 (`picker_hue_rooms`) | One private iterator over "every cached room and zone, then every mapping whose group is gone" (the two walks and the `stale` sort are the same code); the picker sanitises its two halves and carries `value`, the items do not (driver.lua:445-458 replaces commas itself) | lights −15 | None | Low-medium: two owner-facing lists share one walk; both pinned end to end | lights_spec 1381-1440 (room_mappings_text, broken mappings, deleted groups), 1809-1820 (picker_hue_rooms) | None |
| 13 | lights.lua:2140-2153 (`name_differences`) and 2164-2187 (`adopt_hue_names`' own loop) | `name_differences(include_dismissed)`; `adopt_hue_names` iterates it with `true` (it renames dismissed differences too, by contract Q 10) | lights −8 | None | Low-medium: the two loops differ only in the `name_dismissed` test (2145 vs none at 2167); pinned | lights_spec 1298-1333 | None |
| 14 | lights.lua:161-176 (`bridge_id`, `room_id`, `protect`), 462-477 (`mark`, `flush`, `save`), 479-515 (`device_for`, `proxy_for`, `entry`, `rid_for`, `count`), 550-557 (`project_call`), 560-572 (`project_rooms`), 603-615 (`project_bound_set`), 622-632 (`project_lights`), 635-644 (`display_name`), 1024-1030 (`clear_conflicts_for`), 1412-1418 (`run_pending_resync`), 1600-1610 (`BUSY_MAX`, `expire_stale_busy`); the same in scenes.lua:194-204, 344-416, 444-510, 1158-1165, 1493-1500, 2103-2114 and zone_lights.lua:165-175, 296-356, 385-453, 853-860, 1202-1209, 1497-1507 | A `bridge/module_base.lua` mixin installed into each module table, parameterised by the log tag ("lights" / "scenes" / "zone_lights"), the busy flag names (`importing` vs `adding`), the device filter (`hue_light.c4z` vs `hue_scene.c4z`) and an `entry()` copy hook (lights and zone lights normalise `caps`, scenes does not). `busy_text` stays per module (its texts differ) | lights ≈ −120; scenes and zone_lights ≈ −115 each (other reviewer); base +150; net ≈ −200 bridge-wide | None | Medium: this is the lifecycle merge the brief's rule 4 warns about; the behaviour is pinned end to end (busy texts lights_spec:419, 580; protect/project_call failure logs 1178; zone_lights_spec and scenes_spec match their own tags once each), but three spec files must stay green through one change. Do it after rows 1 and 8, one agent for base + lights, then the other two modules | lights_spec throughout; scenes_spec; zone_lights_spec | Needs care: `protect` and `project_call` are the pcall wrappers around every callback body and project call (code analysis "checked and found sound"); they move verbatim |
| 15 | lights.lua:145 (`early_hellos`), 1014-1018 (replay in `configure_all`), 1081-1086 (queue in `hello`) | Delete the pre-`load()` hello queue. Unreachable in production: driver.lua queues every HUE_HELLO until late init (driver.lua:1757-1775, `EARLY_QUEUED`, `EARLY_MAX` 200) and `OnDriverLateInit` runs `load()` and `configure_all()` before `late_init_done` is set (driver.lua:1801-1808, 1835), so `self.loaded` is always true when `hello()` runs | lights −12 | None | Medium for twelve lines: lights_spec:1595-1611 pins it and docs/import-design.md:120-124 describes it ("queued and answered after configure_all"); the guard still protects a `lights.new()` without `load()`, which only specs do. Only if the coordinator wants the contract sentence gone | lights_spec 1595-1611 (delete or rewrite as "a hello before load() is refused") | None |

Not proposed, for the record: caching `registry:rids()` (302-315; five sorts per
`settle`, three per `attention`) because `take_name` writes `entry.name`
directly (lights.lua:891-899) and `on_device_item` writes `device_name`
(1542), so an order cache would need invalidation in places outside the
registry; the per-light `signature()` in `configure_changed` (959-965) for the
same reason (a dirty flag that misses one mutation leaves a light with a stale
configuration); `lights:limits()` returning a fresh table per HUE_SET/HUE_DIM
(534-544, driver.lua calls it per command) because `commands:limits` copies it
anyway (commands.lua:237-240); the three `on_container` walks per container
(lights.lua:1567, scenes.lua:1680, zone_lights.lua:1349), which would need one
dispatcher in driver.lua and three interface changes.

## 3. Do not touch

- **`ids_from`'s `walk_keys` fallback** (lights.lua:259-281, spec 215-220).
  Looks like a shim for a shape nobody saw, but the OS 3.4.2 node-tree shape
  is the only one verified (205-209) and OS 4.x is a target (CLAUDE.md
  "Targets"); the fallback is what binds the right id on a controller that
  reports the flat shape.
- **The first-AddDevice `lights.dump(info)` log and `device_info_logged`**
  (lights.lua:1642-1648, `dump` 178-203, spec 337-346; the same block in
  scenes.lua:2144 and zone_lights.lua:1531). A `log.always` once per run, so
  it costs nothing after the first add, and it is the only way to see the
  callback shape on an unverified OS without a dev build. `dump` is also the
  dev loop's `log_dump` (driver.lua, Hue Request path).
- **Store coercions and old-shape tolerance**: `registry:normalise_entry`'s v1
  upgrade and `tonumber`/`tostring` coercions (registry.lua:184-213),
  `copy_caps` turning `"true"` into `true` (lights.lua:426-437), `in_set`
  accepting string ids (registry.lua:137-145), `on_binding_changed` accepting
  `"true"`/`"false"` (lights.lua:1183-1194). A project restored from an older
  backup brings v1 entries back; Director's id and boolean types are verified
  on one OS only.
- **`registry:save()` order, tombstones first** (registry.lua:260-270): code
  analysis item 12.
- **The lazy busy expiry** (lights.lua:1600-1620) and `resyncing_since` /
  `importing_since` set with `os.time()` (1387, 1759, 1792): code analysis
  item 2. Replacing it with a timer would add a timer; the brief wants fewer.
- **"Empty means unknown"**: `project_lights()` returning nil for an empty
  `GetDevices` (lights.lua:622-632), `registry:reconcile` treating an empty
  `present` as unknown (registry.lua:503-512), `default_room`/`mapping_target`
  trusting the mapping when the room list is empty (730-748, 780-792).
  Contract §5: a wrong tombstone costs the owner far more than a missed one.
- **`lights:absorb` starting a fresh `groups.new()` per resync**
  (lights.lua:872-885). It looks like a needless allocation, but
  `groups:absorb` keeps a type whose list came back empty (groups.lua:118-137,
  "the last zone deleted"); scenes and zone lights read `ctx.lights.groups`
  live for exactly this reason (scenes.lua:512-519, zone_lights.lua:455-466).
  See open question 6 for the alternative.
- **`skip_set()` as a fresh set consulted at each use** beyond one container
  (lights.lua:75-83, 309-327): zone-light-design §4/§7 Q11 and lights_spec:1198
  (the provider is swapped mid-run). Row 6 caches only inside `on_container`.
- **`reconcile()` after every resync and the 1 s re-reconcile after a binding
  change** (lights.lua:1215-1268, 1364; driver.lua:1700-1703): two project
  calls per resync, but §5 step 1 is per resync by contract and the SDK's
  own sample re-enumerates a second later.
- **`lights:entry()`'s copy** (491-503) and `lights:save()` (473-477): the
  specs' main read accessor (93 asserts) and `fill_proxy_ids`' save in release
  builds (driver.lua:1214-1230).
- **`lights:room_mappings_text()`** (2611-2617): release-dead (only the
  dev-only Lights Report calls it, driver.lua:1553) but nine spec asserts read
  the mappings through it; removing it buys 7 lines for a spec rewrite.

## 4. Open questions for the coordinator

1. **Caller-side guards made dead by lights.lua's completeness** (the other
   reviewer's file; listed here because they guard this module): the
   "methods the running lights.lua does not have yet" comment and checks
   (driver.lua:393-399, 466, 469), `can()`'s and `picker()`'s method-type
   checks (996-1030), the `import` fallback (1162-1167), `state.lights.save`
   (1227, 1520), `state.lights.goodbye` (1294), `state.lights.proxy_for`
   (1511), `room_mappings_text` (1553), `on_binding_changed` and `reconcile`
   (1695-1703, 1825). Every method exists (lights.lua defines all of them);
   about 25 lines there.
2. **One property refresh per reconnect instead of three** (driver.lua:523,
   534, 548): the biggest runtime win in this area and entirely in the
   caller. With 47 lights imported each refresh costs ~47
   `GetDeviceDisplayName` + 2 `GetDevicesByC4iName` (+ the scenes' and zone
   lights' own attention items). If wanted, `lights:attention(rooms)` could
   take the rooms table so `refresh_room_mappings` and `attention` share one
   `project_rooms()` (lights.lua:2541, 2586): one more call saved per refresh,
   an interface change of one optional argument.
3. **Who owns `hue_model.lua`** for rows 8 and 10 (and scenes' `label_of`)? It
   is shared by all three modules and not in any reviewer's named area.
4. **Where does `util.lua` live** (row 1): `src/hue_bridge/bridge/` if only
   the bridge needs it, `src/common/` if the device drivers duplicate the same
   helpers (not checked here; the devices reviewer would know).
5. **Rows 2 and 15 edit the contract** (docs/import-design.md:454 and
   120-124). Both are removals of things no flow uses; say whether contract
   edits are in scope for this round.
6. **`groups:absorb(items, types)`**: an optional explicit type list would let
   `lights:absorb` reset room/zone/bridge_home on one long-lived groups object
   instead of replacing it (lights.lua:881). Not a line saver (±0) and the
   live readers already cope; worth it only if a future module wants to hold
   `lights.groups` by reference.
7. **Three container walks per event** (lights.lua:1567-1593, scenes.lua:1680,
   zone_lights.lua:1349): one dispatch by item type in driver.lua would save
   two walks per container, but it is an interface change across three modules
   and the other reviewer's area; flagged, not proposed.
8. **driver.lua moved under this review** (1812 → 1864 lines, last write
   17:12): re-pin its line numbers before handing rows 3 and 6 and question 1
   to an implementation agent.

## Done: row 14 (2026-10-25, issue #56)

Row 14's `module_base` became `src/hue_bridge/bridge/owner.lua`, shared with the scenes and the zone lights and
wider than proposed: besides `bridge_id`, `protect`, `mark` / `flush` / `save`, `entry`, `count`,
`clear_conflicts_for`, `run_pending_resync` and the busy expiry it holds `send_configure`, `push`,
`configure_all`, `hello` / `adopt` / `goodbye` / `on_binding_changed`, the project-side `reconcile`, `resync`,
`default_room` / `room_for_add`, the creation chain (`create`, `register_added`), the names trio, the shared
Attention items, the relink and forget pickers, `relink`, `forget`, `forget_request` and `link_devices`
(docs/reviews/slim-scenes-zones.md, "Done"). `busy_text` is shared too, its texts being words. The lights keep
their own behaviour behind owner options (`push_needs_state`, `gone_at_hello`, `gone_after_add`,
`announced_follows_entry`, `hello_tells_unknown`, `log_unregistered_bind`) and hooks (`tell` / `foreign` for
the skip set, `reconciled` for the foreign-entry warning, `forgot`, `device_text`, `linked_label`, ...).
`ids_from` and `dump` moved into owner.lua for the creation code; `lights.ids_from` and `lights.dump` stay as
the same functions (lights_spec, devtools), and scenes.lua and zone_lights.lua no longer require bridge.lights.
`protect` and the project calls moved verbatim (bridge.project already held the latter).

lights.lua: 2827 → 1905 lines (2265 → 1427 code lines); owner.lua is 1579 lines (1091 code) for the three
modules. One lights behaviour changed on purpose: after a full GET a refresh clears `device_name`, `model`,
`device_rid`, `mac_address`, `service_id` and `id_v1` when the bridge no longer supplies them (analysis R9;
an event's refresh leaves them, since a re-added light's device record may come later). lights_spec is
unchanged and green. Rows 1–13 and 15 are not part of #56.
