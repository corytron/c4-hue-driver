# Slimming review: scenes, zone lights, model (2026-10-24)

Area: `src/hue_bridge/bridge/scenes.lua` (2976 lines), `src/hue_bridge/bridge/zone_lights.lua` (2237),
`src/hue_bridge/bridge/hue_model.lua` (1048): 6261 lines, 36 % of the driver code. Safety net:
`tests/spec/scenes_spec.lua` (2105), `zone_lights_spec.lua` (1332), `hue_model_spec.lua` (1607),
`scene_roundtrip_spec.lua` (348), `zone_light_roundtrip_spec.lua` (332), plus `drivers_spec.lua:489-504`
for the routing. `src/hue_bridge/driver.lua` read as the caller only; `lights.lua` read as the third copy
of the same code (its rows are for its own reviewer to confirm). Paths below are under `src/hue_bridge/`
and `tests/spec/` unless written in full. Nothing was run, edited or sent anywhere.

## 1. Summary

The three files hold 6261 lines today. Measured function by function (a script normalising the module
word and diffing bodies), **34 functions of `zone_lights.lua` are byte-identical to `scenes.lua` apart from
the module prefix (231 lines in each module), seven more are at least 85 % the same (`entry`,
`accept_names`, `adopt_hue_names`, `on_binding_changed`, `reconcile`, `configure_all`, `forget`: 428/432
lines in all)**, another 371/377 lines are 75–85 % the same (hello, relink, goodbye, attention items, the ctx
defaults), and ~250 more are 65–75 % (link devices, resync, refresh_entry, adopt); `lights.lua` carries the
same code a third time. Dead code in the three files is small: one method nobody calls
(`scenes:registered_rids`, 3 lines) and ~95 lines that only the specs reach (`hue_model.smart_scene_count`,
`hue_model.configure_params`, `zone_lights.join` (driver.lua has its own copy), `zone_lights:limits`, six
registry accessors). The proposals below would remove about **180 lines at low risk without touching a spec**
(helpers module, project-access module, the dead method, two label copies, four micro items; 220–275 when
the spec-pinned dead code of rows 7–9 and 23–24 goes too) and about **470 more at medium risk** (one shared
lifecycle base for the two registry-owning modules: configure/state plumbing, hello/goodbye/binding/reconcile,
busy flags, names, attention items, pickers, creation, room resolution), roughly 110 more at high risk (Link
Devices, relink/forget), for a total near 800 of 5213 lines in scenes.lua + zone_lights.lua (15 %); when
`lights.lua` joins the same base the saving about doubles.
The biggest runtime wins: (1) `zone_lights:refresh_all` recomputes member lists, capabilities, the full
CONFIGURE signature and the derived colour for every registered zone light on **every light event on the
bridge** (zone_lights.lua:1343-1378, 1269-1341), ~15 tables and ~30 strings per entry per event; filtering by
membership makes an unrelated light event free; (2) `scenes:reconcile_scenes` sorts every unimported scene
with a comparator that builds two group labels per comparison, on every stream reconnect, to print a debug
count (scenes.lua:1416-1417, 623-643); (3) the bridge is asked for `/grouped_light` twice per reconnect, once
by the scenes (scenes.lua:712) and once by the zone lights (zone_lights.lua:1172), each keeping its own copy
of the same 23 records.

## 2. Proposals, ranked by benefit ÷ risk

Lines saved are estimates after the shared code is counted (a new module's lines are subtracted). "Two"
means scenes.lua + zone_lights.lua; "three" adds lights.lua. Spec references are the describe/it blocks that
pin the behaviour today.

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs | Security |
|---|---|---|---|---|---|---|---|
| 1 | scenes.lua:1416-1417 (`reconcile_scenes`), 623-643 (`unimported_scenes`) | The debug line's argument `#self:unimported_scenes()` runs whether or not debug is on: it builds a list of every unimported scene (~124 on the house) and sorts it with a comparator that calls `self:group_label()` twice per comparison (groups lookup, concat, `:lower()`; 633), about 1,750 label strings per resync. Drop the line, or count with one `pairs` pass over the two catalogues (no sort, no strings). | −2 (or +2 for the cheap count) | CPU per stream reconnect: a 125-element sort with ~3,500 string allocations gone; nothing else | low: a debug line nobody asserts (`saw_log` is used once in scenes_spec, at 530, for another line) | none pin it; scenes_spec 568-647 "resync reconciliation" covers the rest of the function | none |
| 2 | scenes.lua:413-415 `registered_rids` | Delete: no caller in src or tests (the only `registered_rids` call is driver.lua:1273-1274 on the zone lights). | −3 | none | low | none | none |
| 3 | scenes.lua:319-328 `label_of`; hue_model.lua:1002-1014 `group_label`; (groups.lua:228-238 `label`, another copy, for its reviewer) | The same label rule three times ("(all lights)", "(no room)", "<name> (zone)"). scenes.lua uses `hue_model.group_label` (it already requires hue_model). The only difference is `name == ""` → "(no room)" in hue_model; a group never has an empty name (`hue_model.group` gives a fallback, 468-470), and registry `group_name` comes from the cache. | −10 | none | low: the labels are pinned byte for byte by every picker spec | scenes_spec 1424-1485 "pickers", 346, 446, 1595; hue_model_spec 1565-1574 | none |
| 4 | zone_lights.lua:786-807 `send_state`, 730-760 `state_params` | A full HUE_STATE computes the derived colour twice: `state_params` calls `color_of` (753), then `send_state` calls it again for the signature (799). Return the signature from `state_params` (or compute colour once in `send_state`). Each `color_of` walks the group's members and the lights' models (692-705, 510-548). | −3 | one member scan fewer per full STATE: every entry at every resync (`fanout`), every hello, every `push` | low: internal; the message is unchanged | zone_lights_spec 399-422 "sends the full state at every resync", 567-592 "derives the colour", 739-755 hello; zone_light_roundtrip 172-211 | none |
| 5 | scenes.lua:206-315, 2800-2802; zone_lights.lua:177-234, 257-259; (lights.lua:212-218, 351-422, 1422-1429, 2622-2624) | **Shared helpers module** `bridge/text.lua` (new, ~75 lines): `positive`, `norm`, `sanitise`, `date_of`, `short_date_of`, `plural`, `some(names, max)`, `signature`, `has_field`, `empty_list`; also `copy_caps`/`same_caps` (zone_lights.lua:236-255 = lights.lua:426-445) and the constants `MAX_NAMED` (3 ×3), `BUSY_MAX` (90 ×3), `DIM_MAX_DURATION`/`DIM_DEFAULT_DURATION` (scenes.lua:65-66 = zone_lights.lua:60-61). Pure functions, identical bodies (similarity 1.00 in the measurement). Call as `text.plural(...)`; or alias at the top of each module (keeps call sites, costs one line per helper). | two: −65 (aliases) to −90 (direct calls); three: −140 to −160 | none (same code, loaded once instead of three times: a few KB of bytecode) | low: byte-identical bodies; every owner-facing text runs through them, so the whole text spec set pins them | scenes_spec 1424-1485 pickers, 2730 attention via 694/1637, 302-458 texts; zone_lights_spec 1178-1265; both round trips | none; `sanitise`/`norm` keep applying constant patterns to untrusted names (analysis-3 "sound") |
| 6 | scenes.lua:136-159 and 444-507; zone_lights.lua:110-133 and 385-449; (lights.lua:104-127, 550-644 minus `room_floors` 576-598) | **Shared project access** `bridge/project.lua` (new, ~85 lines): `defaults(ctx, binding)` (the seven `ctx.project.*` fallbacks, identical ×3) and a view with `call`, `rooms`, `bound_set`, `devices_of(driver_file)`, `display_name` (identical ×3 except the log prefix and the `C4iNames` file). driver.lua always passes `project_calls` (driver.lua:194-202, 304, 332), so the defaults serve the specs, which build the modules without a project table (scenes_spec 90-98, zone_lights_spec 66-73) and must keep working. | two: −84; three: −174 | none | low: identical code; the "unknown, never deleted" rule of `project_<devices>` (scenes.lua:484-496, zone_lights.lua:425-438) must stay as is | scenes_spec 602-647 (project reconcile), 1320-1381 (link_devices); zone_lights_spec 465-509, 1058-1134; drivers_spec 489-504 | none |
| 7 | zone_lights.lua:2214-2235 `join` vs driver.lua:1060-1075 `join_pickers` | One of the two is dead. driver.lua joins `ForgetDeviceList` with its own `join_pickers` (1085-1087) and never calls `zone_lights.join`, whose only callers are zone_lights_spec 1219-1231. The two agree on every input the driver produces (placeholder lists carry value ""). Either delete `join` and its spec block, or have driver.lua call `zone_lights_mod.join` and drop `join_pickers` (driver.lua is the coordinator's file; needs a fallback while the module is optional, driver.lua:316-320). | −23 (zone_lights) or −14 (driver.lua) | none | low | zone_lights_spec 1219-1231 (would be deleted or kept, by the choice); drivers_spec 489-504 pins `ForgetDeviceList` at the driver level | none |
| 8 | hue_model.lua:871-881 `smart_scene_count` | Dead in src: scenes.lua builds the smart catalogue with `smart_records` (731-743) and counts it (405-411). `docs/smart-scenes-design.md` "Interfaces" says it "stays for compatibility", but the only compatibility left is hue_model_spec 1398-1417 (two cases). Open question 3. | −11 | none | low | hue_model_spec 1398-1417: the two cases go with it (the spec pins an API with no consumer, not a behaviour) | none |
| 9 | hue_model.lua:363-371 `configure_params` | Dead in src: lights.lua builds HUE_CONFIGURE from the registry entry (`registry_configure_params`, lights.lua:935-942); nothing calls the live-light variant. The five hue_model_spec cases at 454-510 that go through it test `registry_configure_params`' behaviour and can be rewritten against it (471 already does). | −9 | none | low | hue_model_spec 446-513 (rewrite five `it`s) | none |
| 10 | scenes.lua:551-554 `group_name`, 645-647 `is_tombstoned`, 2116-2120 `next_recall_gen`; zone_lights.lua:2177-2182 `device_text` | Micro: inline the one-call wrapper `group_name` (used at 882), inline `is_tombstoned` (one use, 2323; `self.reg:tombstones()[rid]` is already fetched one line later), initialise `recall_gen` in `new` (165-189) instead of the lazy `self.recall_gen = self.recall_gen or {}` at 2117. Keep `device_text`. | −8 | none | low | scenes_spec 772-907 (recall), 401-458 (add all) | none |
| 11 | zone_lights.lua:1269-1341 `refresh_all`, 1343-1378 `on_container` | **Top runtime win.** `on_container` sets `touched` for every `light`, `device`, `room`, `zone` and `grouped_light` item (1358-1369), then `refresh_all` visits every registered entry and, per entry: `refresh_entry` → `fields_from_group` → `member_lights` (two tables) + `member_models` + `hue_model.group_caps` + `grouped_light_of` (594-607, 622-646); `configure_changed` → `hue_model.group_configure_params` (params table, caps table, `string.format`, label concat) + `signature` (keys table, sort, parts table, ~12 concatenations) (682-688, 223-234); `color_of` → `member_lights` + `member_models` again + `group_color` + a concat (692-705); `online_of`, `grouped_light_of`. About 15 tables and 30 strings per entry per container, for a light that may not be in the group. Filter by membership before the work: a `light` item touches a zone whose `child_rtypes[rid] == "light"` and the room of `lights.models[rid].device_rid` (`groups:room_of_device`, groups.lua:203-208; the lights' cache is current, the coordinator runs lights first, driver.lua:530-536); a `device` item its room and the zones holding its `light_rids`; a `grouped_light` item its owner (`group_state[g].owner_rid` before a delete, `owners` after, or the cache's `grouped_light_rid`); a `room`/`zone` item that rid. Entries no item names are skipped; the "cache lacks the group → gone" branch (1276-1283) only ever fires for the item's own rid. Optionally compute `configure_changed` only when `refresh_entry` changed something (every CONFIGURE field is an entry field; `set_state` paths call `push`/`announce_gone` themselves). | +15 to +25 | **per event**: an unrelated light event (the most frequent event on a 47-light bridge) costs the zone module nothing instead of O(entries × members) with ~45 allocations per entry; GC pressure on the controller drops accordingly | medium: the filter must reach every entry the specs expect: colour from a member light event (567), colour and level in one STATE (593), members changed → CONFIGURE (607), zone emptied → no_lights and offline, refilled (623), emptied read from the grouped_light delete alone (654), zone deleted → gone, re-added → back (673), rename (722) | zone_lights_spec 510-738 "events" in full; zone_light_roundtrip 236-301 (zone_on 236, zone_off 275, zone_deleted 286); drivers_spec 489 | none (same messages; the risk is a missed refresh, not an exposure) |
| 12 | scenes.lua:2603-2695; zone_lights.lua:1942-2035; (lights.lua:2140-2228) | **Names trio** (`expected_name`, `name_differences`, `adopt_hue_names`, `accept_names`): 93/94/89 lines, similarity 0.95–1.00; the only differences are the words "scene device" / "zone light device" / "device", "Hue scene names" / "Hue zone and room names" / "Hue names", "scene name difference" / "zone light name difference" / "name difference", and the expected name (creation name for scenes and zone lights; `entry.name` for lights). One implementation in the shared base (row 15) with `self.WORDS` and an `expected_name(rid, entry)` hook; lights' `expected_name` returns `entry.name`. | two: −80; three: −160 | none | medium-low: texts parameterised word for word; the proxy-id skip path, `name_dismissed` clearing and `flush` order are identical | scenes_spec 1382-1423 "names", 1637 (base name); zone_lights_spec 1135-1177; scene_roundtrip 280-283; zone_light_roundtrip 312-315; lights_spec (its reviewer) | none |
| 13 | scenes.lua:2730-2795; zone_lights.lua:2066-2131; (lights.lua:2474-2572) | **Attention items** (gone, unbound, two claimants, name differences + `attention()`): 64/64 lines, similarity 0.82; differences are words only ("scene"/"zone light"/"light", "unbound scene device"/"unbound zone light device"/"unbound device", "Re-link Scene or Forget Scene"/"Re-link Zone Light or Forget Light"/"Re-link Device To Light or Forget Light", "Hue scene %s"/"Hue %s %s"/"Hue light %s", "Hue scene name%s"/"zone light name%s"/"Hue name%s") and the claimant label (scenes: `entry_label`/`scene_label`, 2764-2769; zones: type word + name, 2099-2105). Base builder with words and a `conflict_label(rid)` hook; lights appends its own items (new lights, broken mappings, offline) after the shared four. | two: −48; three: −93 | none | medium: five texts × three modules byte for byte | scenes_spec 694-711, 1637-1656, scene_roundtrip 262-283; zone_lights_spec 1244-1265, zone_light_roundtrip 293-315 | none |
| 14 | scenes.lua:2103-2130, 1461-1499; zone_lights.lua:1497-1517, 1164-1208; (lights.lua:1600-1620, 1380-1418) | **Busy and pending flags**: `expire_stale_busy` (identical ×3), `busy_text` (texts differ: "Busy: adding scenes" / "Busy: adding a zone light" / "Busy: importing"; "resyncing scenes" / "resyncing zone lights" / "resyncing"), `resync` skeleton and `run_pending_resync` (identical). Base `resync(done)` with hooks `fetch(cb)`, `absorb`, `settle` and an `on_fetch_failed` policy: scenes and lights abort on a failed GET, zone lights still settle against the group cache and report ok=false with `sent` (1172-1199). The hardening of code-analysis item 2 (expiry, 90 s) stays, once. | two: −47; three: −97 | none | medium-low: three callback shapes to keep (`done(false, err)`, `done(false, err, sent)`, `done(true, nil, sent)`) | scenes_spec 225-301 (resync, pending, busy); zone_lights_spec 200-253; lights_spec resync | none; keep the 90 s expiry (code-analysis 2026-10-22 item 2) |
| 15 | scenes.lua:937-954, 1116-1164, 1167-1174, 1192-1388; zone_lights.lua:671-688, 811-859, 862-867, 872-1080; (lights.lua:946-965, 979-1030, 1034-1268) | **Lifecycle base** `bridge/owner.lua` (new, ~230 lines; the modules set `setmetatable(scenes, { __index = owner })` so missing methods fall through): `send_configure`/`configure_changed` (identical, message name from `self.MESSAGES`), `push`, `configure_all`, `clear_conflicts_for`, `hello`, `goodbye`, `on_binding_changed`, `reconcile` (0.87–1.00), with hooks for what differs: `announce_gone` (scenes sends STATE inactive, zones STATE online=false, lights HUE_STATE online=false), `answer_hello` (scenes adds `send_group_known`, 1178-1186), `adopt`'s "gone" rule (scenes: a GET of the entry's kind succeeded, 1206; zones: `groups_loaded`, 883), hello's kind check and dual signature (zone_lights.lua:898-907, 943), lights' `tell()`/`foreign()` (lights.lua:330-348). Rows 5, 6, 12, 13, 14 and 16–18 would live on the same base. | two: −210; three: −410 | none; Lua 5.1 resolves a two-level `__index` chain in C | medium: the brief's rule 4 case. It is pinned end to end (next column), the texts and message orders are byte-for-byte, and the specs assert message sequences 60 times (`commands_sent()` 36× in scenes_spec, 24× in zone_lights_spec), so a slip fails loudly. Divergences to settle first: `goodbye` clears `announced` before the rid check in scenes (1290-1292) and after it in zones (985-987); the comment-only differences at scenes 1325 / zone 1016 / lights 1183-1185 (lights logs an unregistered bound device). Do it in two commits: text builders (rows 12, 13, 17) then flows (14, 15, 16, 18), `busted` green after each. | scenes_spec 648-771 (hello, goodbye, binding), 568-647 (reconcile), 1486-1533 (load, configure_all), 2070-2104; zone_lights_spec 739-883, 399-509, 1266-1331; both round trips; drivers_spec 479-504 | none: every rid still passes `valid_rid` in registry.lua:131-133 and `entry_for_command` before a URL is built (scenes.lua:1722-1735, 1781, 1854, 1898); the base must not widen that. |
| 16 | scenes.lua:664-683, 2206-2224; zone_lights.lua:1582-1616; (lights.lua:730-748, 1736-1757) | Room resolution (`default_room`, `room_for_add`): 39/33 lines, 0.69–0.81; same mapping rule, same "Not added: … pick a room, or Set Room Mapping first" / "Control4 room %d no longer exists" texts; lights has it inline in `add_light`. Base with a `group_rid_of_record` hook. | two: −20; three: −50 | none | medium-low | scenes_spec 316-375, 402-458; zone_lights_spec 255-335; lights_spec add_light | none |
| 17 | scenes.lua:2943-2974; zone_lights.lua:2179-2212; (lights.lua:2701-2731) | Pickers `picker_relink_devices` / `picker_forget_devices`: same loops; the device text and the empty policy differ (scenes/lights return a placeholder, zone lights an empty array for the driver's join, 2184-2186). Base builder with `device_text(rid, entry, rest)` and `empty_text` (nil = empty array). | two: −9; three: −32 | none | low-medium: small gain; do it only as part of row 15 | scenes_spec 1466-1485, 1948-1956; zone_lights_spec 1200-1218; drivers_spec 489 (`RelinkZoneLightList` empty handling, driver.lua:1078-1084) | none |
| 18 | scenes.lua:2135-2201; zone_lights.lua:1523-1575; (lights.lua:1638-1706) | Device creation: `on_added` is identical modulo the fields function and log words (AddDevice callback shape, `ids_from`, bind before `reg:add`, `save()` after every add, `push(…, "resync", true)`); zones add one device, scenes and lights a chain. One `create(jobs, fields_fn, finish)` in the base. | two: −20; three: −72 | none | medium: the save-after-each-add and bind-before-register invariants must survive (lights.lua:1674, 1656-1662) | scenes_spec 302-400 (AddDevice args, Bind, save, CONFIGURE+STATE, 385 protocol id), zone_lights_spec 283-398; both round trips (`bc4.added`, `bc4.bindings`) | none |
| 19 | scenes.lua:712-721 `fetch_all`; zone_lights.lua:1172-1199 `resync`; driver.lua:484-525 | Two `GET /clip/v2/resource/grouped_light` per stream reconnect: the scenes' third GET and the zone lights' only GET, decoded twice into two caches of the same records (`group_on`/`group_level`/`level_sent`, scenes.lua:174-176; `group_state`/`owners`/`gone_grouped`, zone_lights.lua:143-145). Let `zone_lights:resync(done, items)` take pre-fetched items, which the coordinator hands over from the scenes' result (or the scenes expose the last body). | −10 to −25 | one HTTPS request and one JSON decode (~23 items) fewer per reconnect; the zone resync no longer waits a round trip | medium: changes the resync chain in driver.lua and two spec harnesses that answer the GETs in sequence (scenes_spec 110-129 `answer_gets`, zone_lights_spec 75-82 `answer_get`); the two caches stay separate (the modules are optional and independent, driver.lua:242-246, 316-320) | scenes_spec 226-280; zone_lights_spec 201-230; both round trips answer the GETs explicitly | none |
| 20 | scenes.lua:2873-2933 `picker_groups` | `scenes_of_group(group_rid)` is called twice per group (2897), each a full pass over a catalogue plus a sort, only to find one record for the label fallback: O(groups × catalogue) per picker open (23 × 126 × 2). Remember one record per group in the `tally` loop instead. | −4 | CPU on a Composer click (Add All Scenes Of Room's picker) | low | scenes_spec 1454-1465, 1939-1947 | none |
| 21 | scenes.lua:1680-1717 `on_container` | A `rest` table is allocated for every container to run smart_scene items first (1686-1695); only containers that carry a smart_scene item need the two passes. Check for a smart item first (one loop) and fall back to a single pass otherwise. | −2 | one table per event container | low: the ordering guarantee (Decision 10) must stay for mixed containers | scenes_spec 1756-1778 ("in either order"), 459-567 | none |
| 22 | zone_lights.lua:1442-1444 (`set`), 1483-1484 (`dim`); scenes.lua:2018-2019 (`dim`), 2079-2081, 2085-2086 (`level`) | Info lines whose arguments run whether or not info is enabled (the default threshold is warn, common/log.lua:8; the format itself waits for the level check, common/log.lua:27-36): per slider step `set` builds nine `tostring`s plus `entry_label` (a `gsub`) and a `:sub`; `level` builds three `level_text` (`string.format` + `gsub` each). Guard the hot ones with `self.ctx.log.enabled("info")` (common.log has it, common/log.lua:23-25; specs pass no `log`, so the default applies). | +4 | ~12 string allocations fewer per slider step (a drag is up to ~10 messages a second) | low | scenes_spec 1117-1209, 1061-1116; zone_lights_spec 884-978 (`saw_log` is not used on these lines) | none |
| 23 | scenes.lua:360-385 (`device_for`, `proxy_for`, `rid_for`); zone_lights.lua:312-322, 338-342 | Spec-only accessors (driver.lua uses `is_group` for zone routing, driver.lua:384-386, 1430, and scene commands carry their rid): 16 spec call sites. Delete with the spec edits, or leave. `entry`, `scene`, `smart_scene`, `attention` (scenes.lua:370-381, 417-431, 2788-2795; zone_lights.lua:324-336, 2125-2131) are also src-dead but carry ~140 spec call sites: leave them. | −22 | none | low, but every line needs a spec edit (rule 3: the specs are not wrong, they inspect state) | scenes_spec, zone_lights_spec (16 sites) | none |
| 24 | zone_lights.lua:372-381 `limits` | Src-dead: the group queue is never given limits (driver.lua:1430-1431 routes to `zone_text("set")`, which calls `group_set` → `state.group_queue:set` without `:limits`, driver.lua:280-286), so grouped_light PUTs are clamped to `commands.DEFAULT_LIMITS` (mirek 153–500, commands.lua:46, 216-217), not to the members' intersection (Decision 7). Either wire it (driver.lua, +1 line, a behaviour change: mirek clamped to the intersection) or delete it. Open question 2. | −8 (or +1) | none | low | zone_lights_spec 318, 333 assert `Z:limits(...)` inside two add cases | none |
| 25 | scenes.lua:2430-2545, zone_lights.lua:1804-1937, (lights.lua:1942-2072) `match_unimported_by_name`, `link_devices` | 109/124/122 lines, similarity 0.71: the same algorithm (announced rid → conflict or adopt; shared Composer names refused; unique name match; the four problem texts) with different candidate rules (scenes: hue_scene devices present or announced, 2461-2472; zones: hue_light devices announcing kind group or nothing, outside the skip set, 1836-1865; lights: skip set + in project, 1979-1988) and words ("Forget Scene on one of them", "Hue zones or rooms … (a room's as \"<Room> Lights\")"). Base with `candidates(bound, present)` and `label_for_link` hooks and six word slots. | two: −63; three: −143 | none | **high**: the most text-dense function, three candidate rules, and the adopt-by-name path that the lifecycle contracts call the delicate one (import-design §4) | scenes_spec 1320-1381, 1679-1691; zone_lights_spec 1058-1134; lights_spec link_devices | none; adoption stays bound-only (`project_bound_set` check) |
| 26 | scenes.lua:2382-2426, 2550-2599; zone_lights.lua:1700-1800; (lights.lua:1892-1939, 2077-2136) | `relink`, `forget`, `forget_request`: 0.67–0.86; differences: scenes clear `kind`, zones clear `color_sent`/`online_sent` (1739-1740, 1772), zones refuse a light rid (1724-1726), lights' foreign branch (2099-2104); texts differ ("registered scene"/"registered zone light"/"registered light"; the forget text's tail "the Hue scene is listed under Add Scene again" exists for scenes and lights but not zones, 2576-2577 vs 1782). | two: −45; three: −105 | none | high for the gain: three text shapes and per-module cache clearing | scenes_spec 1248-1319, 2070-2104; zone_lights_spec 979-1057; both round trips (relink and Forget texts) | none |

### Shared-helper candidates in one view

The brief asks, per candidate, where it lives, which modules change, what each loses and which specs pin it.
"Base" is the mixin of row 15 (`bridge/owner.lua`); the module keeps only hooks and word tables.

| Candidate | Lives in | scenes.lua loses | zone_lights.lua loses | lights.lua loses (its reviewer) | New lines | Pinned end to end by |
|---|---|---|---|---|---|---|
| Pure helpers + constants (row 5) | `bridge/text.lua` | 206-315, 2800-2802 (~80) | 177-259 (~82) | 212-218, 351-422, 426-445, 1422-1429, 2622-2624 (~85) | +75 | every text spec; both round trips |
| Project access + ctx defaults (row 6) | `bridge/project.lua` | 136-159, 444-507 (88) | 110-133, 385-449 (89) | 104-127, 550-575, 600-644 (96) | +85 | scenes_spec 602-647, 1320-1381; zone_lights_spec 465-509, 1058-1134 |
| Registry access (`mark`, `flush`, `save`, `count`, accessors) | base | 332-415 minus `load` (~42) | 296-354 minus `load`, `device_ids`, `is_group`, `limits` (~42) | 462-529 (~45) | +45 | scenes_spec 1486-1533; zone_lights_spec 1266-1331 |
| Configure/state plumbing + gone/unbound handling (row 15) | base | 937-954, 1116-1164, 1167-1174, 1192-1388 (~240) | 671-688, 811-859, 862-867, 872-1080 (~250) | 946-965, 979-1030, 1034-1268 (~260) | +230 | scenes_spec 648-771, 568-647; zone_lights_spec 739-883, 399-509; round trips; drivers_spec 479-504 |
| Busy / pending flags (row 14) | base | 1461-1499, 2103-2130 (~64) | 1164-1208, 1497-1517 (~70) | 1380-1418, 1600-1620 (~68) | +60 | scenes_spec 225-301; zone_lights_spec 200-253 |
| Names (row 12) | base | 2603-2695 (93) | 1942-2035 (94) | 2140-2228 (89) | +95 | scenes_spec 1382-1423; zone_lights_spec 1135-1177; round trips 280-283 / 312-315 |
| Attention items (row 13) | base | 2730-2795 (64) | 2066-2131 (64) | 2474-2572 part (~45) | +60 | scenes_spec 694, 1637; zone_lights_spec 1244; round trips |
| Pickers (row 17) | base | 2943-2974 (32) | 2179-2212 (30) | 2701-2731 (31) | +35 | scenes_spec 1466; zone_lights_spec 1200 |
| Creation (row 18) | base | 2135-2201 (67) | 1523-1575 (53) | 1638-1706 (67) | +70 | scenes_spec 302-400; zone_lights_spec 283-398; round trips |
| Room resolution (row 16) | base | 664-683, 2206-2224 (39) | 1582-1616 (33) | 730-748, 1736-1757 (39) | +40 | scenes_spec 316-375; zone_lights_spec 255-335 |
| Link Devices (row 25) | base, hooks | 2430-2545 (109) | 1804-1937 (124) | 1942-2072 (122) | +100 | scenes_spec 1320-1381; zone_lights_spec 1058-1134 |
| Relink / forget (row 26) | base, hooks | 2382-2426, 2550-2599 (92) | 1700-1800 (93) | 1892-1939, 2077-2136 (100) | +75 | scenes_spec 1248-1319; zone_lights_spec 979-1057; round trips |
| Recall generations (`next_recall_gen`, `still_current`) | stays in scenes.lua | 0 (2116-2120, 1741-1746) | has none (commands go through the queue) | has none | 0 | scenes_spec 796-807, 896-907, 1883-1903 |

Totals (two modules): rows 1–6, 10, 20–22 ≈ −180 at low risk with no spec change; rows 7–9 (spec cases
deleted or rewritten) ≈ −40 more and rows 23–24 ≈ −30 more, so −220 to −275 in all at low risk; rows 12–18
plus the registry-access line of the table above ≈ −470 at medium risk; rows 25–26 ≈ −110 at high risk.
lights.lua would lose about as much again from the same base. The implementation split that respects one writer per file: one agent writes
`bridge/text.lua`, `bridge/project.lua` and (later) `bridge/owner.lua` against a contract in `docs/`; then one
agent each adapts scenes.lua and zone_lights.lua (and lights.lua, if its reviewer agrees); the coordinator
keeps driver.lua (rows 7, 19, 24) and runs `luacheck`, `busted` and the build between stages.

## 3. Do not touch

- **Recall generations and `still_current`** (scenes.lua:1737-1746, 2115-2120, used at 1778, 1851, 1888,
  1943): the fix for code-analysis item 4 (a later recall or OFF silences the earlier callback; a re-linked,
  forgotten or gone scene is not reported). Looks like bookkeeping around three PUTs; it is the reason a
  late answer cannot flip a tile back on. Pinned by scenes_spec 796-807, 896-907, 1883-1903.
- **Busy expiry** (scenes.lua:2103-2113, zone_lights.lua:1497-1507): code-analysis item 2. Share it (row 14),
  never drop it.
- **`smart_fresh` / `smart_synced` gating** (scenes.lua:172-173, 761-766, 930-935, 1406-1408, 1429-1432, 1206):
  three branches that look defensive; they are `docs/smart-scenes-design.md` Decision 11 (a failed
  `/smart_scene` GET marks nothing gone and tells no state) and the "no guessed inactive before a GET of the
  kind" rule. Pinned by scenes_spec 255-269, 2031-2069.
- **`state_known` in both modules** (scenes.lua:927-935, zone_lights.lua:762-782): before the first GET a
  guessed "inactive"/off would turn a lit tile off at startup (import-design §4). Pinned by scenes_spec
  663-674, zone_lights_spec 352-367, 756-775.
- **`gone_grouped` / `owners` in `grouped_light_of`** (zone_lights.lua:143-145, 554-570, 1216-1260): the
  grouped_light rid resolved three ways. A zone's event may not carry its services, so an emptied zone is
  read from the grouped_light `delete` alone (zone_lights_spec 654-672); the GET is authoritative again
  (1133-1147). Decision 11 of the zone contract.
- **Smart items before scene items in one container** (scenes.lua:1686-1699, 1672-1679): a slot starting and
  its slot scene's status share a container; `other_active` reads the current slot (smart-scenes Decision 10,
  scenes_spec 1756-1778 "in either order").
- **`load()` coercions** (scenes.lua:335 `auto_dynamic == "true"`, zone_lights.lua:285-287 `copy_caps`,
  `tonumber`, `no_lights == "true"`): persisted booleans and numbers can come back as strings on the
  controller, which is why registry.lua:184-213 and 246 coerce every id and stamp with `tonumber` and
  lights.lua:449-459 re-copies the caps. Hardware quirk.
- **Creation order and save** (scenes.lua:2159-2175, zone_lights.lua:1546-1562): `ids_from` picks the protocol
  id over `deviceId` ("binding protocol id %d rather than deviceId %d", verified on OS 3.4.2, lights.lua:205-209),
  bind before `reg:add`, `save()` after every AddDevice so a failure half-way never leaves a created device
  unregistered (lights.lua:1674). Pinned by scenes_spec 385-400, zone_lights_spec 385-398.
- **`send_group_all` after a resync and the hello's `send_group_known`** (scenes.lua:1030-1047, 1178-1186):
  "changed or not" is deliberate (a device added between resyncs; scene-dimmer contract, "A hello answer also
  sends the group's known on/off and level"). Pinned by scenes_spec 927-957, scene_roundtrip 147-149.
- **`early_hellos` in the modules** (scenes.lua:1225-1229, 1150-1154; zone_lights.lua:913-917, 845-849):
  driver.lua queues hellos before late init too (driver.lua:1756-1783), but the modules are also driven
  standalone by the round trips and `load()` runs before `configure_all()` in `OnDriverLateInit`
  (driver.lua:1810-1821); keep both layers. Pinned by scenes_spec 712-721, zone_lights_spec 821-831.
- **`reg:rids()` (sorted) in the fan-outs** instead of `pairs`: `send_group_for`, `send_other_active`,
  `fanout`, `refresh_all`, `configure_all` (scenes.lua:1003, 1101, 1427, 1144; zone_lights.lua:1271, 1107, 839).
  Replacing the sort with `pairs` would save the per-call list allocation but the specs assert message
  sequences 60 times (`commands_sent()`); the order is part of the pinned behaviour.
- **`hue_model.update_smart_scene`'s deep compare** (hue_model.lua:689-718, 748-806): `same_slots` looks heavy
  but is what reports a re-timed schedule (hue_model_spec 1294-1307) and it runs only on smart_scene events.
- **The `ctx.project` defaults** (scenes.lua:136-159, zone_lights.lua:110-133): they look dead because
  driver.lua always passes `project_calls`; the module specs and both round trips construct the modules
  without a project table and need the defaults to reach the fake C4. Move them (row 6), do not delete them.
- **`zone_lights:hello`'s kind check** (zone_lights.lua:943-945) and driver.lua's routing by kind
  (driver.lua:1571-1583): a light's hello must never be adopted as a group (drivers_spec 489-504,
  zone_lights_spec 799-820).
- **The scenes' third GET and the zone lights' GET as separate transfers today** (row 19): sharing them is a
  medium-risk change to the resync chain; until the coordinator decides, the duplication is correct code, not
  dead code.
- **Catalogue fields `last_recall` and `speed`** (hue_model.lua:513-526, 556-566): nothing reads them
  (grep: only hue_model.lua and the specs), about 10 KB on the house, but they are the contract's record shape
  (`docs/scenes-design.md` §1 Catalogue, §8) and hue_model_spec 522-575 pins "exactly the fields of the
  contract". A contract change, not a slimming (open question 5).

## 4. Open questions for the coordinator

1. **Row 7**: `zone_lights.join` or driver.lua's `join_pickers`? Keeping `join` and dropping `join_pickers`
   needs a fallback while `bridge.zone_lights` is `pcall`-optional (driver.lua:316-320); if the "optional
   module" guards go in the driver review, `zone_lights.join` is the natural survivor and its spec stays.
2. **Row 24**: `zone_lights:limits` is never wired, so group PUTs clamp mirek to 153–500 instead of the
   members' intersection (zone contract Decision 7). Wire it in driver.lua's `group_set` hook (one line, a
   behaviour change the house has not seen) or delete it and the two assertions?
3. **Row 8**: `docs/smart-scenes-design.md` "Interfaces" says `smart_scene_count` "stays for compatibility".
   No caller remains in src. May it go, with a one-line note in the contract?
4. **Row 9**: `hue_model.configure_params(light, device, extra)` has no caller; the five hue_model_spec
   cases can be rewritten against `registry_configure_params`. Is a spec rewrite of that size acceptable for
   nine lines?
5. **Catalogue shape**: drop `last_recall` and `speed` from `hue_model.scene` (~10 KB on the house, −8 lines)?
   Needs `docs/scenes-design.md` §1/§8 and hue_model_spec 522-575 changed; I have not proposed it.
6. **Row 19**: is one `/grouped_light` GET per reconnect worth changing the resync chain in driver.lua
   (484-525) and the two spec harnesses? The payload is small (~23 items); the win is one TLS round trip and
   one decode per reconnect, and the zone resync no longer waiting a transfer.
7. **Mechanism for the shared base** (rows 12–18): a mixin through `setmetatable(module, { __index = owner })`
   with `self.WORDS`/`self.MESSAGES` tables and hook methods, or plain functions taking `self`? The repo has no
   inheritance so far; the mixin saves the most lines, the functions are the most explicit.
8. **Row 23**: delete the six spec-only accessors (22 lines, 16 spec edits) or leave them as the modules'
   inspection API?
9. **driver.lua:289-292 `device_send`** (not my file): `params_text(params)` (a table, a sort and a concat)
   is built for every message to every scene and zone-light device whether or not debug is on; the same
   pattern at driver.lua:217-221 for HUE_STATE. Worth a `log.enabled("debug")` guard in the driver review.
10. **`require("bridge.lights")` in scenes.lua:49 and zone_lights.lua:45** only for `ids_from` and `dump`
    (lights.lua:179-282): moving the two to `bridge/text.lua` (row 5) removes the sibling dependency; it saves
    no lines and touches lights_spec (`lights.ids_from`, `protocol_id_from` at lights_spec), so it is the
    lights reviewer's call.
11. **Divergences a merge must settle** (row 15): `goodbye` clearing `announced` for strangers (scenes yes,
    zones no); whether `zone_lights:hello`'s two-argument form (zone_lights.lua:898-907, pinned by
    zone_lights_spec 750) and `add`'s table form (1625-1633, pinned by 336-351) stay as the module's API or
    become spec-only shims to drop.

## Five lines

- Lines today: scenes.lua 2976 + zone_lights.lua 2237 + hue_model.lua 1048 = 6261.
- Low-risk proposals: about −180 lines with no spec change (rows 1–6, 10, 20–22); −220 to −275 when the
  spec-pinned dead code of rows 7–9 and 23–24 goes too.
- Medium-risk proposals (rows 12–18, the shared base for the two modules): about −470 lines; rows 25–26 at
  high risk about −110 more; lights.lua would lose roughly as much again from the same base.
- Top runtime win: row 11, `zone_lights:refresh_all` runs for every light event on the bridge and rebuilds
  members, caps, the CONFIGURE signature and the colour per registered zone light; a membership filter makes
  unrelated events free (zone_lights.lua:1269-1378).
- Would not touch: the recall generation and `still_current` check in scenes.lua:1737-1746 and 2115-2120 (the
  code-analysis item 4 fix), together with the `smart_fresh`/`state_known` gates it sits beside.
