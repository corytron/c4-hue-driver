# Slimming review: runtime behaviour of the bridge driver (2026-10-24)

Area: not a set of files but what the bridge driver does on the controller
(OS 3.4.2, Lua 5.1) at startup, per event-stream container, in its timers,
in the command queues and in its logging, costed for the house (47 lights,
23 rooms and zones, 126 scenes and 15 time-based ones; a 351 KB scene
catalogue). Brief: `slim-2026-10-24-brief.md`. Line numbers are those of
branch `release-prep` at commit efa57ac. Allocation counts below are read
from the code, not measured on the controller; where a cost depends on
Director's side (an `UpdateProperty`, a `SendToDevice`, a timer) that is
said, since the SDK documents no cost for them.

## 1. Summary

The release code is 16,925 lines (17,553 with `common/devloop.lua`, which
ships only in dev builds). The proposals here save about 10 lines net (a few
remove a copy, most add a guard), because the runtime is the point. Three
wins carry most of it. First, logging arguments are built before the level
is checked: every message to a device pays `params_text()` (a table, one
string per parameter, a sort and a concat) for a debug line that is off
(`src/hue_bridge/driver.lua:219`, `:290`), and every resync sorts all 141
scene records with a comparator that builds two labels per comparison, for
a debug count (`src/hue_bridge/bridge/scenes.lua:1416-1417`); both go away
with an `if log.enabled("debug")`. Second, `zone_lights:refresh_all` re-checks
every registered zone light on every container that carries a light, device,
room, zone or grouped_light item, at about 20 tables, 35 strings and three
walks of the member list per entry (`src/hue_bridge/bridge/zone_lights.lua:1269-1341`);
today that is two entries, but it is the one path whose cost per event grows
with what the owner imports, and it can be limited to the groups the
container touched. Third, Director is called nine times per container (three
`UpdateProperty`, four `SendToDevice` on a typical Master Bedroom event, a
timer `Cancel` and `SetTimer` per chunk); a last-value cache in `prop()` and
a watchdog that is armed once per period instead of once per chunk remove
the avoidable ones without changing a text. Startup memory is dominated by
one transient: the 351 KB catalogue body and its `C4:JsonDecode` tree, both
alive until the callback returns; what the driver keeps afterwards is small
(the order of 200 KB) and only one piece of it is duplicated between modules.

## 2. Proposals, ranked by benefit ÷ risk

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs | Security |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `src/hue_bridge/driver.lua:217-222` (`send` in `new_lights`), `:289-292` (`device_send`) | Wrap the `log.debug(...)` calls, and with them `params_text(params)` and `tostring(rid):sub(1, 8)`, in `if log.enabled("debug") then … end`. | 0 (+4) | Per message to any device (HUE_STATE, HUE_CONFIGURE, HUE_SCENE_GROUP, HUE_SCENE_STATE…): −1 table, −(n+2) strings for n params, −1 `table.sort`, −1 `table.concat` (`driver.lua:205-212`). Four such messages per typical container today; 47 per resync fan-out once lights are imported again. | Low: debug output only; `log.emit` already skips the format itself (`src/common/log.lua:27-31`). | No spec asserts these lines (grep of `tests/spec` for `params_text`, `-> %d`: none). Messages are pinned by `drivers_spec`, `roundtrip_spec`, `scene_roundtrip_spec`, `zone_light_roundtrip_spec`. | none |
| 2 | `src/hue_bridge/bridge/scenes.lua:1416-1417` | Guard the debug count with `if self.ctx.log.enabled("debug")` before calling `#self:unimported_scenes()`. | 0 (+2) | Per resync: −1 build of a 141-record list and −1 sort whose comparator calls `group_label()` twice per comparison (`scenes.lua:632-641`, `:558-565`: `label_of` concat, `:lower()` twice), roughly 1,000 comparisons and 4,000 short strings on the house bridge, inside the same second as the catalogue decode. | Low: a debug line. The `ctx.log` look-alike in specs must offer `enabled` (`common.log` does; specs pass the real module). | `scenes_spec` resync tests pin the messages; nothing asserts the "not imported" line (grep: none). | none |
| 3 | `src/hue_bridge/bridge/zone_lights.lua:1349-1378` (`on_container`), `:1269-1341` (`refresh_all`) | Collect the groups a container touches: a `grouped_light` item → the entries whose `grouped_light_of(rid)` is that id; a `light` item → `groups.zones_by_light[rid]` plus `groups.room_by_device[models[rid].device_rid]` (indexes already kept by `src/hue_bridge/bridge/groups.lua:506-526`, read directly rather than through the copying `zones_of_light`); a `device`, `room`, `zone` or `bridge_home` item → every entry (membership may have changed). Run the existing per-entry body of `refresh_all` only for touched entries. Match grouped_light items to entries **before** `on_grouped_light_item` applies a `delete` (`:1219-1226` sets `gone_grouped`, after which `grouped_light_of` is nil for that group and the match would miss the entry that must go offline). | 0 (+25) | Per container, per untouched registered zone light: −`refresh_entry` (`member_lights` 2 tables, `member_models` 1, `group_caps` 1, `fields` 1, `delta` 1), −`configure_changed` (`group_configure_params` ≈4 tables and ≈12 `tostring`, `signature` 2 tables, ≈12 strings, 1 sort), −`color_of` (2 walks of the member list, ≈4 tables), −`online_of`, −`fields`: about 20 tables, 35 strings and three member-list walks (47 members for the Whole House zone) per entry, repeated per container. Today 2 entries; with the 23 groups imported about 460 tables and 800 strings per container, at 1–4 containers a second during a drag. Messages sent are unchanged: an untouched entry never had non-empty `fields` (its `on`/`brightness` come only from carried grouped_light items, its colour and online only from member and group changes). | Medium: new index logic on the hot path; a light's `mirek_schema` can arrive in an update (`src/hue_bridge/bridge/hue_model.lua:165-175`) and change a group's caps, which the light → zones/room mapping covers; `bridge_home` children are rooms, never a device of a registered group, so it can take the "every entry" branch. | `zone_lights_spec` "events" (511-737), "resync fan-out" (399-508); `zone_light_roundtrip_spec`. Add one spec: a light event for a light in no registered group sends nothing and leaves `color_sent`/`online_sent` of the other entries untouched; a spy on `refresh_entry` shows it was not called. | none |
| 4 | `src/hue_bridge/driver.lua:58-60` (`prop`) | Keep a `last_prop[name]` of the text last written and return early when it is identical; leave `prop_list` (`:67-71`) as it is. | 0 (+4) | −1 `C4:UpdateProperty` for `Last Event` whenever two containers share a clock second (`:543`); −5 or 6 writes per `refresh_lights_props()` (`:431-449`) when its texts did not change, which is the usual case for the add/delete containers (`:539-541`), every `OnBindingChanged` (twice: `:1645`, `:1651`), every `OnItemNameChanged` (`:1694-1696`) and every `last_action` (`:940`); −1 `Stream Address` write per connect when the spelling repeats. Every text the owner sees is written exactly as today the first time it differs. | Low–medium: the cache is per Lua state, so a reload or a Composer-side edit of a driver-written property still gets the next write (the driver never rewrites the same text to "restore" a property except `Room Mappings`, which goes through `prop_list`). | `drivers_spec` asserts `env.Properties[...]` values, never write counts, so it stays green; add a spec that an identical `prop()` is not recorded twice in `c4.calls` (`tests/helpers/fake_c4.lua:295-298`). | none |
| 5 | `src/hue_bridge/bridge/stream.lua:85-101` (`arm_watchdog`), `:219` | Record `self.last_data = C4:GetTime()` per chunk; arm the watchdog once per connection for the full period, and when it fires compare the clock: enough silence → reconnect as today, else re-arm for the remainder. | 0 (+8) | Per chunk: −1 `C4LuaTimer:Cancel()`, −1 `C4:SetTimer`, −1 closure and timer object (`:86`, `:92`). One timer per 300 s instead of one per container. | Medium: `stream_spec:188-195` ("reconnects when the watchdog fires") feeds a chunk and fires the timer expecting a reconnect; with a clock check the spec must advance `c4.now_ms` (`fake_c4.lua:360-361`) by the watchdog period first. The spec is not wrong; the timer's contract changes from "armed means N s elapsed" to "the clock says N s elapsed", and the spec would then pin the better contract (a re-arm for the remainder when data came in between). A zero-spec-impact alternative with less benefit: skip the re-arm when the last one is under 1 s old (saves the churn only in bursts; the watchdog may fire up to 1 s early). | `stream_spec:83-87` (timer delays after connect) stays true: one watchdog armed. | none |
| 6 | `src/hue_bridge/driver.lua:1396`, `:1419` | Call `state.queue:limits(rid, …)` only when the three numbers differ from `state.queue.lights[rid].limits` (or when no limits are cached), instead of on every HUE_SET and HUE_DIM. | 0 (+6) | Per slider tick per light: −1 table from `lights:limits` (`src/hue_bridge/bridge/lights.lua:534-544`), −2 from `commands:limits` (`src/hue_bridge/bridge/commands.lua:237-241`: `copy(DEFAULT_LIMITS)` then merge). A drag sends about 10 HUE_SET a second per light. | Low: the limits still follow a changed `HUE_CONFIGURE` the next time they differ. | `roundtrip_spec` HUE_SET → PUT clamping; `commands_spec:155-183` (clamping to limits). | none |
| 7 | `src/hue_bridge/bridge/scenes.lua:1591` | In `on_scene_item`, call `configure_changed(rid)` only when `changed` has `name`, `group_rid` or `auto_dynamic`; a status-only item (`active`) cannot change the CONFIGURE, whose inputs are name, id_v1, auto_dynamic, group name/type, state, gone_since, kind and slot (`:879-897`). Group renames reach CONFIGURE through `refresh_group_names` (`:834-849`, `:1711-1713`) and slot renames through `tell_slot_scene` (`:1540-1548`). | 0 (+1) | Per scene status event for a registered scene (every recall, every member light switched off: `docs/design.md:646-649`): −`configure_params` (≈4 tables, ≈8 `tostring`) −`signature` (2 tables, ≈10 strings, 1 sort). | Low–medium: the gate must list every field `update_scene` can report (`hue_model.lua:485`: name, active, auto_dynamic, speed, group_rid; speed is not in the CONFIGURE). | `scenes_spec` events: a rename → CONFIGURE, a status → STATE only. | none |
| 8 | `src/hue_bridge/bridge/lights.lua:312-336` (`skip_set`, `foreign`), `src/hue_bridge/driver.lua:231-235` | Let `foreign(device_id)` test membership without building a set: call `ctx.skip_devices` if it is a function (still "consulted at each use"), then index the result when it is a set or scan it when it is a list; keep `skip_set()` for the callers that need a fresh set (`link_devices`, `reconcile`). `zone_lights:device_ids()` (`zone_lights.lua:358-364`) still allocates one set per call; acceptable, or the driver's closure can return the registry table itself with a `by_device` test. | −5 | Per `tell()` (`lights.lua:340-348`), that is per HUE_STATE/HUE_CONFIGURE to a light: −2 tables (`skip_set` out + `add_ids`) and −1 `pairs` over the zone registry; 47 per resync fan-out, one per light event once lights are imported again. Today, with no light imported, `tell` is never on the event path. | Low: same answers for a set, a list, a function and a failing function. | `lights_spec:1115-1210` ("skip_devices" as set, list, function; the failing function; foreign hello adopts nothing). | none |
| 9 | `src/hue_bridge/bridge/commands.lua:50-56` (`default_now`) | Hoist `function() return C4:GetTime() end` to a module-level local and `pcall` that. | 0 | −1 closure per `now()` call; `take_token` and `flush` call it 2–3 times per PUT. | None. | `commands_spec:231-241` (opts.now); the default path runs under `drivers_spec`/`roundtrip_spec`. | none |
| 10 | `src/hue_bridge/driver.lua:1649-1653` | Keep one pending reconcile timer: cancel the previous one before arming, so N binding changes in a second run one reconcile. | 0 (+4) | Per burst of binding changes (35 deletes in `docs/status.md`-style sessions; a `C4:Bind` per import): −(N−1) × (`GetBoundConsumerDevices` + `GetDevices` + registry pass + `refresh_lights_props`). Idle: nothing. | Low. | `drivers_spec`/`roundtrip_spec` binding tests pin the end state after `fire_timers()`, which fires all armed timers at once (`fake_c4.lua:727-737`), so one or N timers give the same state. | none |
| 11 | `src/hue_bridge/driver.lua:494`, `:505`, `:519` | Refresh the owner-facing properties once at the end of the resync chain (after the zone lights'), not after each of the three modules. Needs the coordinator's nod: the `Lights` text appears up to a second later after a reconnect (the scene GET's time), identical in content. | −3 | Per resync: −2 × (`Lights`/`Attention`/`Room Mappings`/`Scenes`/`Zone Lights` writes, 2 `GetDevicesByC4iName` from `project_rooms()` (`lights.lua:2541`, `:2586`), one `GetDeviceDisplayName` per linked light, scene and zone light from `name_differences()` (`lights.lua:2140-2153`, `scenes.lua:2609-2622`, `zone_lights.lua:1948-1961`), two sorts of the 47 models from `new_models()` (`lights.lua:2463-2470`, `:2477`)). With 47 lights imported that is about 100 fewer project calls per resync, which happens on every reconnect. | Medium: a visible timing change (sub-second), though no text changes; row 4 already removes the duplicate writes, so this row only removes the project lookups. | `drivers_spec`/`roundtrip_spec` assert the properties after the whole chain; none asserts them between modules (to confirm when implementing). | none |
| 12 | `src/hue_bridge/bridge/zone_lights.lua:1164-1200` (`resync`), `src/hue_bridge/driver.lua:497-508` (`zone_resync`) | Let `zone_lights:resync(done, items)` accept the grouped_light items the scenes' resync just fetched (`scenes.lua:712-720`, kept in `res.grouped_light`) and skip its own GET when given. | 0 (+8) | Per resync: −1 `GET /clip/v2/resource/grouped_light` (≈24 items, ≈10 KB, one `C4:JsonDecode`) and the `C4:url` object, options and closures of `http.request` (`http.lua:449-482`). The two caches of the same data (`scenes.group_on`/`group_level`, `zone_lights.group_state`) stay: two modules, two contracts, 24 entries each. | Low–medium: the zone resync is already chained after the scenes' (`driver.lua:520`); the scenes module must hand the raw items out (a return value or a field). | `zone_lights_spec:200-252` (the GET, a failed GET keeps the previous state); add the items path. | none |
| 13 | `src/hue_bridge/driver.lua:221`, `:291`; `src/hue_bridge/bridge/lights.lua:346` (default `ctx.send`), `scenes.lua:107-109`, `zone_lights.lua:85-87` | Pass `false, log.enabled("debug")` as `SendToDevice`'s 4th and 5th arguments: `allowEmptyValues` stays false (the modules rely on empty strings being dropped, `hue_model.lua:343`), `logCommand` false outside Debug Mode. SDK: "logCommand Defaults to True. False prevents this API's content from being logged" (`~/c4-tools/reference/docs-driverworks-api/source/includes/32_serial_network_device/_19-SendToDevice.md`). | 0 (+2) | Director stops logging one line with the full parameter table per message: 4 per typical container today, 47+ per resync fan-out once lights are imported. [assumed: what Director does with `logCommand` at the controller's default log level is not documented beyond that sentence and was not measured.] | Low–medium: a diagnostic surface, not an owner-visible text; Debug Mode brings it back. | The fake ignores extra arguments (`fake_c4.lua:602-605`); no spec change. | improves (less in Director's logs; the params carry no key) |
| 14 | `src/hue_bridge/bridge/registry.lua:302-315` (`rids`), callers on the event path: `scenes.lua:1003` (`send_group_for`, per grouped_light item), `:1101`, `:1542`; `zone_lights.lua:1271` (per container); `lights.lua:1309` (per group item) | Cache the sorted rid list in the registry and drop it on every mutation (`add`, `update` of `name`, `set_state`, `relink`, `forget`, `tombstone`, `reconcile`, `load`), **and** in the three modules' `take_name`, which write `entry.name` directly (`lights.lua:897`, `scenes.lua:791`, `zone_lights.lua:616`). | 0 (+12) | Per `rids()` call: −1 record table per entry, −1 list, −1 sort with two `string.lower` per comparison. Today (2 scenes, 2 zone lights) negligible; with the 126 scenes imported, `send_group_for` sorts 126 records per grouped_light item, 3–5 items per container. | Medium: cache invalidation with one known bypass (`take_name`); a missed invalidation reorders or drops a message. Iterating with `pairs` instead is not an option: specs pin message order (`scenes_spec:980`, `:1738`; `registry_spec:369-383`). | `registry_spec:369-383` (order), the module specs' ordered `commands_sent()` assertions. | none |
| 15 | `src/hue_bridge/bridge/sse.lua:198-219` | Walk the buffer by index and cut once per chunk instead of `self.buffer = self.buffer:sub(nl + 1)` per line (code analysis item 8, with its byte cap). | 0 (+6) | Per chunk: −(lines − 1) copies of the remaining buffer; Hue chunks are one event of three lines and ≤2 KB, so the saving is a few KB of garbage per container; it matters only for a burst or a malformed stream. | Low. | `sse_spec:26-45` (reassembly across chunk boundaries), `:73` (oversized line). | improves (with the cap) |

Rows 1, 2, 6, 7, 8, 9 and 10 touch one file each and can go to one agent
per file; rows 3 and 12 touch `zone_lights.lua` plus `driver.lua`; rows 4,
5, 11 and 13 need the coordinator's decision (visible latency in 5 and 11, a
diagnostic surface in 13).

## 3. Do not touch

- **The resync after every connect and its "changed or not" fan-out.** The
  stream has no resume and no keepalive (`docs/design.md:126-129`, `:137-141`),
  so every reconnect is followed by the six GETs, the catalogue GET and full
  HUE_STATE to every device (`lights.lua:1333-1342`, `scenes.lua:1032-1047`,
  `zone_lights.lua:1105-1119`). The devices wait for echoes: "carried again is
  sent again" (`zone_lights_spec:525-527`), "again at every resync, changed or
  not" (`scenes_spec:939`), and `hue_model.update` reports a carried field as
  changed on purpose (`hue_model.lua:99-100`).
- **The 1 ms deferral of `on_connected`** (`stream.lua:202-214`) and the
  generation checks that deliver a zombie's last chunk (`:169-181`): a
  `C4:url` transfer started inside `OnHeaders` fails with curl error 2, and
  `Cancel()` does not end a streaming transfer (`docs/design.md:152-163`).
- **`PersistSetValue` of the stream spelling on every connect**
  (`driver.lua:125-128`): the rotation must survive a reload
  (`docs/design.md:277-285`), although the SDK warns that spurious persists
  make Director re-save all drivers' data
  (`docs-driverworks-fundamentals/.../24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md:27`).
  One write per connect is the price; see open question 2 for how often that
  is.
- **`prop_list`'s double write** (`driver.lua:62-71`): `UpdatePropertyList`
  alone did not move the row in Composer (build 184, `docs/status.md:47-50`).
- **The trailing 80 ms debounce re-armed on every `set()`**
  (`commands.lua:273-285`): it is what merges a brightness and a colour
  into one PUT and is pinned (`commands_spec:83-93`). A leading-edge window
  would send a different first body. The per-tick timer churn (one `Cancel`
  and one `SetTimer` per HUE_SET during a drag, `:252-266`) could be removed
  with the row-5 technique (re-arm for the remainder on fire), but the fake
  fires timers without a clock, so every debounce spec would need
  `c4.now_ms` arithmetic; not worth it at 10 ticks a second per light.
- **`copy(DEFAULT_LIMITS)` in `commands:limits`** (`commands.lua:237-241`):
  the copy protects the shared default table from a per-rid write.
- **The `signature()` strings kept in `last_configure`** (`lights.lua:411-422`,
  `scenes.lua:295-306`, `zone_lights.lua:223-234`): one string per registered
  device, and the reason a CONFIGURE (and the device's
  `DYNAMIC_CAPABILITIES_CHANGED`) is not re-sent on every event.
- **`lights.models` holding all 47 bridge lights although none is imported**
  (`lights.lua:839-851`): zone lights derive colour and capabilities from
  them (`docs/zone-light-design.md`, Decisions 7 and 8) and Add Light's picker
  lists them.
- **`log.always` in `OnBindingChanged`, `OnBindingValidate` and
  `OnSystemEvent`** (`driver.lua:1635`, `:1661`, `:1691`): owner-facing
  diagnostics; `OnSystemEvent` is code-analysis item 17 L8 and also drives
  the `Attention` refresh on a rename (`:1694-1696`).
- **The early-command queue and the `late_init_done` gate**
  (`driver.lua:1705-1732`): code-analysis item 1.
- **`sse.MAX_LINE`** (`sse.lua:141`, `:213-217`).
- **The two `expire_stale_busy` list literals per call** (`lights.lua:1603`,
  `scenes.lua:2106`, `zone_lights.lua:1500`): one table per resync or action;
  hoisting them saves nothing measurable and the guard is item 2 of the code
  analysis.

## 4. Open questions for the coordinator

1. **Three `C4:UpdateProperty` per container** (`Event Stream` with its
   count and clock, `stream.lua:254-255` → `driver.lua:483`; `Events
   Received` and `Last Event`, `driver.lua:542-543`). Coalescing them into one
   write per second would keep every text byte-for-byte but show it up to a
   second late, and `stream_spec:141` and `drivers_spec:202-203` would have to
   fire a timer first. Is a one-second lag on these three rows acceptable? If
   not, row 4 is the most that can be done without a visible change.
2. **How often does an idle house resync?** The watchdog default is 300 s
   (`stream.lua:33`, floor 60 s at `driver.lua:167`, `:482`), the bridge sends
   no keepalive (`docs/design.md:137-141`), and a watchdog reconnect costs a
   full resync: 10 GETs including the 351 KB catalogue and its decode, three
   `GetBoundConsumerDevices` and three `GetDevices` (`lights.lua:1364`,
   `scenes.lua:1448`, `zone_lights.lua:1123`), three `refresh_lights_props`
   (row 11), a full fan-out, and one `PersistSetValue`. The Bridge Pro's
   `zigbee_connectivity` events reset the watchdog "every so often"
   (`docs/design.md:204-206`), but how often is not recorded. Options with a
   visible side: raise the default in `driver.xml`, or skip the catalogue
   GET after a *watchdog* reconnect (only after an error or the hourly
   timeout). Both are design decisions, not slimming; a day of the stream's
   `reconnects` counter (`stream.lua:281`) from a dev build would settle the
   priority.
3. **`SendToDevice` logging** (row 13): is silencing Director's per-message
   log outside Debug Mode acceptable, given hardware debugging has relied on
   the driver's own log rather than Director's?
4. **Ordered iteration** (row 14): is an order cache in `bridge.registry`
   wanted, or should the event paths stay as they are until the owner
   imports enough scenes for the sort to matter? Today's registries hold two
   and two entries.
5. **Event rate.** `docs/design.md:120-122` records, verified, that the bridge
   sends at most one container per second and groups changes within it; the
   brief and this review's prompt assume several events per second per light
   during a drag. Every per-container cost above scales linearly with the
   real rate, so one measurement on the Bridge Pro (containers per second
   during a 5 s slider drag, from the `Events Received` row) decides whether
   rows 3–5 are worth their risk now.
6. **One refresh per resync chain** (row 11): acceptable to show `Lights` a
   second later after a reconnect?

## Appendix: the paths, costed

### A. Startup and resync

`OnDriverLateInit` (`driver.lua:1749-1800`): `credentials.load`; `lights:load`
(three `PersistGetValue`, one shallow copy per entry, `registry.lua:223-255`);
`lights:configure_all` (one HUE_CONFIGURE with a `signature()` per bound
light, `lights.lua:1006-1020`; 0 today, 47 when imported); the two queues;
`scenes:load` + `configure_all` + **`reconcile`** (`GetBoundConsumerDevices`
+ `GetDevices hue_scene.c4z`, `scenes.lua:1351-1388`); `zone_lights:load` +
`configure_all` + **`reconcile`** (`GetBoundConsumerDevices` + `GetDevices
hue_light.c4z`, `zone_lights.lua:1043-1080`); **`lights:reconcile`** (the same
two calls again, `lights.lua:1215-1268`; the `GetDevices hue_light.c4z` is
identical to the zone lights'); `fill_proxy_ids` (one `GetBoundConsumerDevices`
per entry without a proxy id, `driver.lua:1162-1179`); `refresh_lights_props`;
`replay_properties`; the stream, whose connect runs the self-check GET
(`driver.lua:583`) and then, 1 ms after the headers, `on_connected`
(`driver.lua:484-526`).

The resync chain, per connect:

| Step | GETs | Project calls | Builds and keeps | Transient |
| --- | --- | --- | --- | --- |
| `lights:resync` (`lights.lua:1380-1410`) | 6 serial: light, device, zigbee_connectivity, room, zone, bridge_home (`:53-60`, ≈18 KB for the groups, `docs/design.md:626-633`) | `reconcile`: `GetBoundConsumerDevices`, `GetDevices hue_light.c4z` (`:1216`, `:1221`); `automap_once`: `PersistGetValue` + `project_rooms()` on every resync until the flag exists, then one `PersistGetValue` (`:1347-1358`) | `models` 47 × (≈20 fields + a `gamut` of 3 points) ≈ 60 KB; `devices` ≈50 records; `macs`; a new `groups` cache (`:881`): 24 groups with `children` array + `child_rtypes` map, plus the rebuilt `room_by_device` (46) and `zones_by_light` (80 entries) indexes (`groups.lua:489-543`) ≈ 40 KB | six decoded bodies, dropped after `absorb` |
| `refresh_lights_props` ×1 (`driver.lua:494`) | — | 2 `GetDevicesByC4iName` (`lights.lua:2541`, `:2586`), `GetDeviceDisplayName` per linked entry of all three modules (`lights.lua:2146`, `scenes.lua:2615`, `zone_lights.lua:1954`), two sorts of 47 models (`lights.lua:650-659` via `:2465-2469`, `:2477`) | 5–6 `UpdateProperty`/`UpdatePropertyList` | — |
| `scenes:resync` (`scenes.lua:1461-1491`) | 3 serial: **scene 351 KB**, smart_scene 20 KB, grouped_light ≈10 KB (`:693-727`) | `reconcile`: `GetBoundConsumerDevices`, `GetDevices hue_scene.c4z`; `#unimported_scenes()` for a debug line (row 2) | `catalogue` 126 × ≈9 fields ≈ 50 KB; `smart_catalogue` 15 records whose `slots` each carry their own `days` copy (`hue_model.lua:663-678`) ≈ 30 KB; `group_on`, `group_level`, `level_sent` ≈ 24 entries each | **the 351 KB body string and its `C4:JsonDecode` tree, actions and palettes included, both held in `result` until the callback returns (`http.lua:465-467`, `:481`)**: the single largest allocation the driver makes, on every connect, estimated at several MB of Lua tables for 126 scenes [not measured] |
| `refresh_lights_props` ×2 (`driver.lua:519`) | — | as above | as above | — |
| `zone_lights:resync` (`zone_lights.lua:1164-1200`) | 1: **grouped_light again** (row 12) | `reconcile`: `GetBoundConsumerDevices`, `GetDevices hue_light.c4z` (a third time in the chain) | `group_state` 24 records, `owners` 24 (`:1134-1154`), the same facts as the scenes' `group_on`/`group_level` | one decoded body |
| `refresh_lights_props` ×3 (`driver.lua:505`) | — | as above | as above | — |

What is kept for the life of the driver, estimated: models 60 KB, devices
15 KB, groups 40 KB, catalogue 50 KB, smart catalogue 30 KB, the grouped
caches of two modules ≈10 KB together, registries and tombstones (47
tombstones today) ≈10 KB, `last_configure` one ≈300 B string per registered
device, `offline_since`, `announced`, `conflicts`: the order of 200–250 KB
[estimated from field counts; not measured]. Duplicated between modules:
only the grouped_light on/off and level (scenes vs zone lights). The
registry entries repeat the models' identity fields (name, caps, id_v1,
device_rid, mac, service_id) by design: the entry is persisted and available
before the first GET (`lights.lua:901-928`).

### B. One container, end to end

Reference container, the house's common case: `update` with one `light`
item (a bedside lamp's brightness) and three `grouped_light` items (its
room and two zones), as the hardware notes describe (`docs/design.md:646-649`).
Today's registries: 0 lights, 2 scenes (both Master Bedroom), 2 zone lights
(Bedside Lights, Master Bedroom).

1. **`http.stream` OnBodyChunk → `stream:handle_chunk`** (`stream.lua:218-231`):
   `arm_watchdog()` cancels and re-creates the watchdog (`:86`, `:92`: one
   `Cancel`, one `SetTimer`, one closure, one timer object; row 5).
   `sse:feed` (`sse.lua:198-219`): one concat of buffer+chunk, then per line
   one `find`, two `sub` and a copy of the remaining buffer; three lines per
   event, so about seven strings of ≤2 KB (row 15).
2. **`stream:handle_event`** (`:233-256`): `os.date` (one string, `:68-70`,
   `:235`); `C4:JsonDecode` (`http.lua:400-409`; the container tree, ≈20 tables
   for four items, unavoidable); the debug type list is gated (`:243-249`,
   the pattern rows 1 and 2 copy); `on_container`; then `string.format` and
   **`UpdateProperty "Event Stream"`** (`:254-255`, `driver.lua:483`).
3. **`driver.lua on_container`** (`:527-544`): the three modules; on
   `add`/`delete` a full `refresh_lights_props` (`:539-541`); **`UpdateProperty
   "Events Received"`** (one `tostring` of a number) and **`"Last Event"`**
   (`:542-543`).
4. **`lights:on_container`** (`lights.lua:1567-1593`): the light item →
   `on_light_item` (`:1432-1499`) → `hue_model.update` (two tables: `touched`,
   `changed`, `hue_model.lua:102`, `:184`); no entry → returns 0 (today). With
   the light imported: `state_params` (one table, one `tostring` per carried
   field, `hue_model.lua:304-312`) → `tell` → `foreign` → `skip_set` (two
   tables, row 8) → `ctx.send` → `params_text` (row 1) → `SendToDevice`. The
   grouped_light items are not its business (`:1575-1585`). `flush()` is a
   flag test. **Today ≈2 tables, 0 messages.**
5. **`scenes:on_container`** (`scenes.lua:1680-1717`): a `rest` table
   (`:1686`); per grouped_light item `on_grouped_light` (`:1053-1075`): a
   `fields` table, `level_text` always (a `string.format` and a `gsub`,
   `:214-226`, `:1058`) whether or not any scene is registered for the group;
   when the level text differs from the last sent, `send_group_for`
   (`:1001-1011`) → **`reg:rids()`** (one record per entry, a list, a sort,
   `registry.lua:302-315`; row 14) and per rid `record_of` + `group_rid_of` +
   `grouped_light_of`; a match → `send_group` (one params copy, `:986-997`)
   → `device_send` → `params_text` (row 1) → `SendToDevice`. The Master
   Bedroom grouped_light matches both scenes. **Today ≈ 1 + 3 + 3×3 + 2×5 ≈
   25 tables and strings, 2 messages.** The scene's own `update` item, when a
   recall happens: `update_scene` (two tables), five `has_field` scans,
   `configure_changed` (row 7), `send_state`.
6. **`zone_lights:on_container`** (`zone_lights.lua:1349-1378`): a `carried`
   table; per grouped_light item `on_grouped_light_item` (`:1216-1260`):
   `update_grouped_light` (two tables, `hue_model.lua:905-929`) and a `fields`
   table; the light item sets `touched` (`:1367-1368`); then **`refresh_all`**
   (`:1269-1341`): `reg:rids()` (row 14), and per registered entry:
   `group_of`; `refresh_entry` (`:622-646`: `fields_from_group` → `member_lights`
   two tables (`:510-537`; a room walks its devices' `light_rids`),
   `grouped_light_of`, `member_models` one table, `group_caps` one table,
   `fields`, `delta`); `configure_changed` (`:682-688` → `group_configure_params`
   `hue_model.lua:1025-1046`: `caps`, `params`, `extra`, ≈12 `tostring`;
   `signature` `:223-234`: `keys`, `parts`, ≈12 "k=v" strings, a sort, a
   concat); `color_of` (`:692-705`: `member_lights` and `member_models` again,
   `group_color` over the members `hue_model.lua:987-1000`, a signature
   string); `online_of` (`:709-724`); `fields`; `send_state` (`:786-807`, one
   params table) → `device_send` → `params_text` (row 1) → `SendToDevice`.
   **Per entry ≈ 20 tables and ≈ 35 strings plus three member walks; today
   ×2 ≈ 40 tables, 70 strings, 2 messages** (both groups' levels changed).
   With the Whole House zone registered its 47 members are walked three times
   per container (row 3).

Totals for the reference container today: about 80 tables and 100 short
strings in Lua, one `JsonDecode`, and nine Director calls: three
`UpdateProperty`, four `SendToDevice` (each logged by Director unless row 13),
one timer `Cancel`, one `SetTimer`. In Lua 5.1 terms that is well under a
millisecond of work per container; the Director calls and the garbage are
the real cost. At the documented one container per second
(`docs/design.md:120`) it is nothing; at the four a second the brief assumes
for a drag it is 36 Director calls and ≈700 short-lived objects a second,
plus whatever the registries grow to (rows 3 and 14 are the terms that scale
with imports: with 23 zone lights and 126 scenes the same container costs
≈850 tables and ≈1,500 strings, most of them in `refresh_all` and the sorts).

Messages sent when nothing changed, per container: none today. `refresh_all`
sends `on`/`brightness` whenever the item carried them, changed or not
(`zone_lights.lua:1307-1312`), by contract (`zone_lights_spec:525-527`);
`on_grouped_light` sends `on` only on change and `level` only when its text
differs from the last sent (`scenes.lua:1059-1066`). Per resync: full state
to every device, by contract (do-not-touch list).

### C. Timers

Bridge (`src/hue_bridge`):

| Where | Period | Kind | Cancelled by | Fires while idle |
| --- | --- | --- | --- | --- |
| `stream.lua:92` watchdog | `Stream Watchdog (s)` × 1000, default 300 s, floor 60 (`driver.lua:167`, `:482`) | one-shot, **re-armed on every chunk** (`:219`; row 5) | `drop_transfer` (`:106-114`), `handle_done` (`:260`), `stop` | yes: after that much silence it reconnects and triggers the whole resync chain of §A (open question 2) |
| `stream.lua:207` connected deferral | 1 ms | one-shot | `drop_transfer`, `handle_done`, itself | no |
| `stream.lua:286` retry | backoff 1 → 60 s (`:34-35`, `:282-283`) | one-shot | `start`, `stop`, `schedule_reconnect` | only while disconnected |
| `commands.lua:256` per-rid queue timer | 80 ms debounce (`:41`), token wait (`:306`), retry 500 ms → 8 s (`:44-45`) | one-shot, one per rid, **re-armed on every `set()`** (`:284`) | `cancel_timer` on re-arm, `stop()` (`:414-420`), itself on fire | no |
| `driver.lua:623` Driver Version re-read | 5 s, then 10 s | one-shot, at most two | — (self-limiting) | startup only |
| `driver.lua:1649` reconcile after a binding change | 1 s | one-shot, **one per `OnBindingChanged`, never cancelled or deduplicated** (row 10) | — | no |
| `conntest.lua:137` | 1 ms | one-shot | — | only during the Connection Test action |

The stream's total transfer timeout (`Stream Timeout (s)`, default 3600,
`stream.lua:32`, clamp `driver.lua:167-176`) is curl's, not a Lua timer, but
it ends the transfer and so forces a reconnect and a resync every hour at
the latest. Nothing else fires in an idle bridge.

Device drivers (`src/hue_light/driver.lua`, `src/hue_scene/driver.lua`), all
one-shot unless said, each with a cancel path, none firing while idle:

- Light: target fallback `rate + 1000 ms` (`:474-482`, cancelled by `settle`
  `:465-470`); click guard 1000 ms (`:981-990`); hold start 400 ms
  (`:1078-1083`); ramp-after-on 600 ms (`:1042-1050`); **hold tick 100 ms,
  repeating** (`:1003-1012`, `end, true`), cancelled when the estimate
  reaches its end (`:1010`) or by `end_hold`; Driver Version re-read
  (`:671-677`); binding re-check at 5, 10, 15, 30 s gaps (`:1197`,
  `:1207-1227`), cancelled when bound.
- Scene: level-report window 1000 ms (`:541-555`, re-opened while reports
  keep coming: a throttle, not a repeating timer); pending fallback 2000 ms
  for a recall/off, 1000 ms for a level (`:46`, `:51`, `:599-609`); follow
  1500 ms (`:677-686`); click guard (`:1452-1461`); recall-then-dim 600 ms
  (`:1549-1558`); hold start 400 ms (`:1584-1589`); Driver Version re-read
  (`:990-996`); binding re-check (`:1706`, `:1716-1736`).

The one timer-related runtime finding is therefore the two per-chunk
Director calls of the watchdog (row 5) and, during a drag, the per-tick
re-arm of the debounce (do-not-touch, with the reason).

### D. Command queues (`bridge/commands.lua`)

Per `set()` (`:273-285`), once per HUE_SET or HUE_DIM: `self:light(rid)` (a
table on first use); `merge` (`:126-175`): one `f` table and five `tonumber`
(`:127-130`); `arm` (`:252-266`): `Cancel`, `SetTimer`, a closure. Before it,
the driver's handler builds a `fields` table (`driver.lua:1386-1393`), eight
`tostring` for an info line that is off (`:1394-1395`; `log.info` is below the
production threshold, `log.lua:8`), and refreshes the limits with three
tables (`:1396`; row 6). Per `flush()` (`:311-358`): `take_token` with
`now()` (a closure per call, row 9); `commands.body` (2–5 tables, needed);
the `send` closure (needed for correlation); `http.request`: `http.options`
three tables (`http.lua:369-382`), `headers_for` one (`:388-397`),
`C4:JsonEncode`, `C4:url()`, two closures (`:449-482`). Per `on_done`: on a
retriable failure `copy(sent)` + `merge` (`:390`). The token bucket is two
arithmetic lines per flush (`:292-307`), no allocation. Stop fallback
(`:363-375`) allocates nothing. The queue is bounded by rids, holds one
pending and one in-flight table per rid, and is the least wasteful module
on the hot path; its only avoidable costs are rows 6 and 9 and the timer
churn discussed above.

### E. Logging (`src/common/log.lua`)

`emit` checks the level before formatting (`:27-31`), so with Debug Mode off
(threshold `warn`, `:8`) no `string.format` runs for `info` or `debug` lines;
an enabled line costs a `pcall`, a `string.format`, `level:upper()` and a
second `string.format` (`:31-35`). `log.always` always formats (`:39-42`).
What the level check cannot stop is the **argument list**, evaluated by the
caller first. On the hot path:

- `driver.lua:219`, `:290`: `params_text(params)` on every message to a
  device (row 1): a table, one string per parameter, a sort, a concat.
- `scenes.lua:1416-1417`: `#self:unimported_scenes()` on every resync (row
  2): the biggest single avoidable CPU item in the chain.
- `driver.lua:1394-1395` (HUE_SET), `:1418` (HUE_DIM): `rid:sub(1, 8)` and
  up to seven `tostring` per slider tick for an `info` line.
- `zone_lights.lua:1442-1444` (`set`), `:1483-1484` (`dim`): `entry_label`
  (`label_of` → `sanitise` gsub, `:271-278`) plus seven `tostring` and a
  `sub` per command.
- `scenes.lua:2073-2074`, `:2079-2081`, `:2085-2086` (`level`): two or three
  `level_text` (each a `format` and a `gsub`), an `entry_label`, a `sub`.
- `dispatch.lua:92`, `:98`, `:103`: one to three `tostring` per dispatched
  command or proxy message (cheap; `key()`'s gsub at `:67-69` is needed).

Already right: `stream.lua:243-249` and `commands.lua:335-337` gate their
debug work on `log.enabled("debug")`; `hue_model` and the registry log only
on change. `log.always` runs for every `OnSystemEvent` with a 600-character
`sub` (`driver.lua:1691`; code-analysis L8) and for every `OnBindingChanged`
and `OnBindingValidate` (`:1635`, `:1661`): owner diagnostics, left alone.
Director's own logging of every `SendToDevice` (row 13) is the other
per-message log cost, outside Lua.
