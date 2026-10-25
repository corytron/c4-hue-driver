# Efficiency review after the slimming (2026-10-24, evening)

Area: the same five paths `slim-runtime.md` costed this morning (startup and
resync, one event-stream container, timers, the command queues, logging),
re-costed on branch `release-prep` at 7878e02 (its `src/` is that of 98daca6,
the last of the four slimming commits cdeecbe, 9cd2841, d04ad02, 688dcd1;
the coordinator's commits between the morning's efa57ac and the agents' are
counted too and named where they matter). Same method: Director calls, table
and string allocations, loops over registries and timers, read from the code
and not measured on the controller, at the house's scale: 47 lights (none
imported, all tombstoned), 23 rooms and zones (2 imported as zone lights),
141 scenes (126 + 15 time-based; 2 imported), a 351 KB scene catalogue, OS
3.4.2, Lua 5.1. Brief: `slim-2026-10-24-brief.md`. Nothing was run against
the controller or the bridge; no file but this one was written.

## 1. Summary

The release code went from 16,867 to 16,138 lines (code lines without blanks
and comments: bridge package 10,496 → 9,890, light 1,267 → 1,260, scene
1,379 → 1,362; the dev-only handlers now live in `bridge/devtools.lua` and
`common/devloop.lua`, which release builds do not ship, `tools/build.sh:46-59`)
and the specs from 1,060 to 1,124. Of the morning's fifteen costs, nine are
gone (the debug dump per message, the sort for a debug count, the watchdog
re-armed per chunk, the closure per `now()`, the triple property refresh per
resync, the duplicate `grouped_light` GET, the per-line buffer copies in
`sse`, the `rest` table per container, and the three per-event property
writes, now one write per row per second), two are reduced (`refresh_all`
runs only for the zone lights an item can change; the skip set is built once
per container instead of per message) and four are unchanged (the limits
tables per slider tick, the CONFIGURE signature per scene status event, the
reconcile timer per binding change, Director's log line per `SendToDevice`;
plus the sorted `rids()` per call, which the morning left open). For the
house's common container (a light in one of the 21 groups with no zone-light
device) the bridge now allocates about half the tables and a seventh of the
strings and makes 4 Director calls instead of 5; for the morning's reference
container (Master Bedroom, both zone lights touched) the saving is smaller
(≈93 → ≈87 tables, ≈112 → ≈85 strings, 9 → 8 Director calls) because both
entries still have to be refreshed. The slimming added one timer that never
runs while idle (the one-second coalescing of `Events Received`, `Last Event`
and `Event Stream`), one clock read per chunk, and a registry scan per
grouped_light item that allocates nothing; nothing it added grows with time.
The largest cost left is not per event: `driver.xml` declares `Stream
Timeout (s)` with a default of 600 (`src/hue_bridge/driver.xml:149-153`,
unchanged since 5d4c2ab and documented as intended in the manual), so unless
the house's row was changed by hand the idle house reopens the stream and
runs the full resync chain, 351 KB catalogue included, every ten minutes;
the morning's text assumed hourly from `stream.DEFAULT_TIMEOUT`, which is
only the fallback for a missing property.

## 2. The morning's table, re-costed

Line numbers on the right are today's. "Reference container" is the
morning's: one `light` item (a bedside lamp's brightness) and three
`grouped_light` items (its room and two zones), registries 0 lights, 2
scenes and 2 zone lights, all in the Master Bedroom.

| # | Morning's cost | Status | Where now | Effect at the house's scale |
| --- | --- | --- | --- | --- |
| 1 | `params_text()` per message to a device | **gone** (9cd2841) | `src/hue_bridge/driver.lua:247-265`: built under `if log.enabled("debug")`; both module contexts use `device_send` (`:270`, `:331`) | −1 table, −(n+2) strings, −1 sort, −1 concat per message: 4 per reference container, 4 per resync fan-out today, 47 more once lights are imported |
| 2 | `#self:unimported_scenes()` for a debug line per resync | **gone** (d04ad02) | `src/hue_bridge/bridge/scenes.lua:1221-1224` | −1 list of 141 records, −1 sort with two labels per comparison (≈1,000 comparisons, ≈4,000 short strings) per connect |
| 3 | `zone_lights:refresh_all` for every entry on every container | **reduced** (d04ad02) | `src/hue_bridge/bridge/zone_lights.lua:1231-1274` collects `touched` (grouped_light → owner through `touch_owner` `:1180-1190`, light/device → member groups through `touch_members` `:1199-1220`, room/zone → itself); `refresh_all(carried, touched)` `:1100-1175` runs the per-entry body only for those | A container about a light in any of the 21 unregistered groups: the per-entry work (≈20 tables, ≈35 strings, three member-list walks per entry) → 0, and `reg:rids()` is not called. The reference container still touches both entries, so it costs what it did (≈40 tables, ≈70 strings) plus the scans of row N3. The morning's scaling case (23 zone lights imported) drops from ≈460 tables/≈800 strings per container to the ≤4 groups a light is in (≈80/≈140). Pinned: `tests/spec/zone_lights_spec.lua:741-776` (a spy on `refresh_entry`: outsiders' events refresh nothing; "in name order" `:762`) |
| 4 | Last-value cache in `prop()` | **partly, in another form** | The three per-event rows are coalesced (`driver.lua:65-105`, `:475-481`, `:527-528`; 9cd2841); the four list rows are sent only when the joined list changed (`show_list`, `:398-414`; 7142852, the coordinator, before the agents); `Attention` (`:435`), `Status` and `Bridge ID` (`:122-131`) are still written every time | `refresh_lights_props` writes 5–6 rows → 1 (`Attention`) plus whichever list changed, usually none; `Last Event`'s same-second rewrite is gone with the coalescing. One unconditional write per refresh remains (row R2 below) |
| 5 | Watchdog `Cancel` + `SetTimer` per chunk | **gone** (9cd2841) | `src/hue_bridge/bridge/stream.lua:112-136` arms once per connection (`:235`); `:253-255` notes the clock per chunk; a firing watchdog that saw data re-arms for the remainder | Per chunk: −1 `Cancel`, −1 `SetTimer`, −1 closure, −1 timer object; +1 `C4:GetTime` (pcall'd, `:85-95`). The timer is touched once per period: 1 `SetTimer` per 600 s while events flow. Default raised 300 → 600 s in the same commit (`stream.lua:39`, `driver.xml:161`). Pinned: `tests/spec/stream_spec.lua:201-228` (advances `c4.now_ms`), `:124-142` |
| 6 | `queue:limits(rid, lights:limits(rid))` per HUE_SET / HUE_DIM | **unchanged** | `driver.lua:1131`, `:1157`; `src/hue_bridge/bridge/lights.lua:481-491` (1 table), `src/hue_bridge/bridge/commands.lua:243-247` (2 tables) | 3 tables per slider tick per light (≈10 a second per light during a drag); 0 today (no light imported; zone lights route to `zone_lights:set`, which never calls `limits`) |
| 7 | `configure_changed(rid)` on every scene status event | **unchanged** | `scenes.lua:1402`; the field gate at `:1393-1394` covers `refresh_entry` only; inputs of the signature `:682-702` | Per status event of a registered scene (every recall, every member light switched off, `docs/design.md:646-649`): `configure_params` (≈4 tables, ≈8 `tostring`) + `util.signature` (2 tables, ≈10 strings, 1 sort, `src/hue_bridge/bridge/util.lua:58-69`) for a message that cannot change |
| 8 | `skip_set()` per `tell()` | **reduced** (cdeecbe) | `lights.lua:330-343` (`skip_cache`), set `false` at `on_container` entry `:1528` and `nil` at exit `:1550`; built at the first `tell` of a container | Per message → per container that sends at least one: 2 tables + 1 `pairs` over the zone registry. 0 on today's event path (no light imported). Pinned: `tests/spec/lights_spec.lua:1160-1176` (shapes), `:1198-1239` (the provider swapped between calls) |
| 9 | A closure per `now()` | **gone** (9cd2841) | `commands.lua:50-62` (`c4_time` hoisted); `stream.lua:85-95` the same pattern | −2–3 closures per PUT |
| 10 | One reconcile timer per `OnBindingChanged`, never deduplicated | **unchanged** | `driver.lua:1226-1229` | Per burst of N binding changes: N × (`GetBoundConsumerDevices` + `GetDevices` + registry pass + a refresh, now with the three lists of row N9) |
| 11 | `refresh_lights_props` three times per resync chain | **gone** (9cd2841) | `driver.lua:491-514`: once, after the zone lights' resync | −2 × (2 `GetDevicesByC4iName` + 1 `GetDeviceDisplayName` per linked device: 4 today, 47 more once lights are imported, + two sorts of 47 models) per connect; the `Lights` row appears after the scene GET (≈1 s later), as the morning's row 11 said it would |
| 12 | `GET /grouped_light` twice per connect | **gone** (d04ad02) | `scenes.lua:1266-1301` hands `res.grouped_light` to `done`; `zone_lights.lua:988-1030` takes `items` and skips its GET; chained at `driver.lua:499-512` | −1 GET (≈24 items, ≈10 KB), −1 `C4:JsonDecode`, −1 `C4:url` with options and closures per connect. The two caches of the same facts stay (`scenes.group_on/group_level`, `zone_lights.group_state/owners`). Pinned: `tests/spec/zone_lights_spec.lua:243` |
| 13 | Director logs every `SendToDevice` | **unchanged** | `driver.lua:264` (three arguments) | One Director log line per message: 4 per reference container, 4 per resync fan-out, 47 more with lights. The morning's open question 3 is still open |
| 14 | `registry:rids()` builds and sorts per call | **unchanged** | `src/hue_bridge/bridge/registry.lua:300-313`; event-path callers: `scenes.lua:808` (`send_group_for`: per grouped_light item whose on/off or level text changed, for every group on the bridge, registered or not), `:906`, `:1352`; `zone_lights.lua:1105` (now only when an entry is touched); `lights.lua:872`, `:1272` | 2 and 2 entries today: ≈3 tables + 2 `:lower()` strings per call, 3–5 calls per container. With 141 scenes imported it becomes the largest term that scales with imports (section 4B) |
| 15 | `sse:feed` copies the remaining buffer per line | **gone** (9cd2841) | `src/hue_bridge/bridge/sse.lua:75-98`: walked by position, cut once | Per chunk (three lines): −2 copies of up to 2 KB; `MAX_LINE` kept (`:92-96`). Pinned: `tests/spec/sse_spec.lua:17-77` |

The morning's open questions: **1** (three `UpdateProperty` per container)
was answered with the coalescing: a row's first value of a second lands at
once, later values a second later, a direct `prop()` always wins
(`tests/spec/drivers_spec.lua:206-256`). **2** (how often an idle house
resyncs) is still unmeasured, and the premise needs correcting: the default
is 600 s, not 3600 (section 4A). **3** (Director's per-message log) open.
**4** (an order cache) open; the registries still hold 2 and 2. **5** (the
event rate during a drag) unmeasured; `Events Received` still shows the
count, now up to a second late. **6** (one refresh per chain) done.

## 3. What the slimming added

Costs the morning's code did not have, each judged on its own.

| # | Addition | Where | Costs | Verdict |
| --- | --- | --- | --- | --- |
| N1 | The coalescing timer for the three per-event rows | `driver.lua:65-105`; `OnDriverDestroyed` cancels it `:1378-1381` | 1 `SetTimer` per second in which an event arrived (the first event of a second writes its rows at once and arms it; the timer fires a second later, writes what is waiting and re-arms only if something was waiting, so a burst ends with one empty fire); 2 small tables per fire; the `tostring` of each row moves from per container to per write. Nothing while idle. Against: for containers ≥1 s apart (the documented rate, `docs/design.md:120-122`) the Director calls on this account go 5 → 4 (3 `UpdateProperty` + the watchdog's `Cancel` + `SetTimer` before; 3 + 1 `SetTimer` after); in a burst of N a second, 5N → 4 | keep |
| N2 | A clock read per chunk | `stream.lua:85-95`, `:254` | 1 `pcall` + 1 `C4:GetTime` per chunk, no allocation; on a watchdog fire that saw data, 1 `SetTimer` for the remainder (once per 600 s while events flow) | keep: it replaced two Director timer calls and a timer object per chunk |
| N3 | The per-container membership scans of the zone lights | `zone_lights.lua:1180-1190` (`touch_owner`, called before **and** after each grouped_light item is applied, `:1241-1243`), `:1199-1220` (`touch_members`), `:1236` (`touched`) | Per grouped_light item 2 × |zone registry| × (`grouped_light_of` ≈ 6 table lookups) + 1 lookup; per light or device item |zone registry| × (`group_of` + 1–2 lookups); one more table (`touched`) per container. Zero allocation. Today (2 entries, 3–5 items): ≈70 lookups per container; with 23 zone lights ≈1,400 lookups, still well under 0.1 ms in Lua 5.1 [estimate] | keep; an index (grouped_light rid → entry) would make it O(1) but needs invalidation on every add, relink, forget, tombstone, reconcile and `absorb`, the row-14 risk class |
| N4 | The skip-set cache's bookkeeping | `lights.lua:1528`, `:1550`, `:338-341` | Two field writes per container; one fresh set per container that sends a message (where it was one per message) | keep |
| N5 | The filter's own checks in `refresh_all` | `zone_lights.lua:1102-1104`, `:1107` | `next(touched)` once, `touched[rid]` per entry; `reg:rids()` is still sorted once per container that touches an entry (the order is pinned, `zone_lights_spec:762`) | keep |
| N6 | `util.*` through the module table | `scenes.lua` (`util.has_field` ≤5 per scene update item `:1384-1394`, `util.signature` 1–2 per configure check `:748`, `:758`), `zone_lights.lua` (`util.signature` `:497`, `:507`); `lights.lua:41-43` binds locals | One `GETFIELD` on an interned key per call instead of a `GETUPVAL`: nanoseconds, no allocation | keep (aliasing the four hot ones is cosmetic) |
| N7 | `project.lua`'s view | `src/hue_bridge/bridge/project.lua:47-59`; two instances at startup (`scenes.lua:147`, `zone_lights.lua:121`) | One metatable `__index` hop per project call; the calls happen at resync, reconcile and action time (`bound_set`, `devices_of`, `rooms`, `display_name`), never per container | keep |
| N8 | `device.lua`'s hooks and instance | `src/common/device.lua:110-484`; the drivers re-bind the hot functions as locals (`src/hue_light/driver.lua:67-69`, `src/hue_scene/driver.lua:118-120`) | `dev.is_on()` one field lookup per LED update (`device.lua:321`, `:338`, `:397`, `:420`); `dev.button_action` one per button action (`:372-387`); `dev.on_bridge_found` once. One `dev` table of ≈20 closures per device Lua state, the same closures that were locals (≈1–2 KB more per device [estimate]). Code loaded per device state: light 1,267 → 1,260 code lines, scene 1,379 → 1,362 (the dev-only log forwarding moved to `devloop.lua`, not shipped; the source grew ≈5 KB each in comments, which compile to nothing) | keep; per proxy notification it also removed the parameter dump (`device.lua:155-163`; `tests/spec/device_spec.lua:124`): −1 table, −n strings, −1 sort, −1 concat per `LIGHT_*_CHANGED`, `ONLINE_CHANGED`, `BUTTON_ACTION` echo |
| N9 | The list rows (the coordinator's 7142852 and eacbfe2, after the morning's costing, before the agents) | `driver.lua:398-439`; `lights.lua:2721-2760`, `scenes.lua:2812-2861`, `zone_lights.lua:2157-2196` | Per `refresh_lights_props` ≈210 rows are rebuilt to compare one joined string per list: ≈250 tables and ≈2,000 short strings, of which the lights alone ≈2,200: `lights:list_items`' comparator calls `:lower()` four times per comparison (`:2744-2754`, ≈280 comparisons for 47 rows) and `summary()` and `attention()` each sort all 47 models through `new_models()` → `unimported_models()` (`:597-622`, `:2414-2415`, `:2423`; two `:lower()` per comparison) only to count. Kept for the life of the driver: the joined lists in `list_rows_sent` (≈10 KB: Scenes ≈6 KB, Lights ≈2 KB, Zone Lights and Room Mappings ≈1 KB each [estimate]). Director: `UpdatePropertyList` + `UpdateProperty` only when a list changed. Runs once per resync (where the morning's code ran its cheaper refresh three times), and on every add/delete container, binding change (twice), goodbye, Composer rename and action | keep the rows; the sorts are row R6 below |
| N10 | Three more modules to `require` at load | `bridge/util.lua`, `bridge/project.lua`, `common/device.lua` | Startup only | keep |

Not a cost but a change of defaults by the slimming: `Stream Watchdog (s)`
300 → 600 s (`driver.xml:161`, `stream.lua:39`, manual `documentation.html:238`).
On the house it changes nothing visible, because the stream's total timeout
(600 s) ends the transfer first (section 4A).

## 4. The five paths, costed again

### A. Startup and resync

`OnDriverLateInit` (`driver.lua:1333-1375`) is the morning's sequence with
one refresh instead of three and the lists of N9 inside it: 3 ×
(`GetBoundConsumerDevices` + `GetDevices`) for the three reconciles, one
`GetBoundConsumerDevices` per lights entry without a proxy id (0 today), and
the refresh's 2 `GetDevicesByC4iName` + 4 `GetDeviceDisplayName`.

Per connect, before → after:

| Step | Before | After |
| --- | --- | --- |
| GETs | 10 serial (6 lights', 3 scenes', 1 zone lights') | **9** (`zone_lights:resync` takes the scenes' grouped_light items) |
| Project calls | 3 reconciles (6) + 3 refreshes (6 `GetDevicesByC4iName`, 12 `GetDeviceDisplayName` at 4 linked devices) + `PersistGetValue` for the automap flag | 3 reconciles (6) + **1 refresh** (2 + 4) + the automap flag read **once per run** (`lights.lua:1310-1313`) |
| CPU | the 141-record sort for a debug count; `groups:rebuild` also built `zones_by_light` (80 children) and the room-less list | neither (`scenes.lua:1221`, `src/hue_bridge/bridge/groups.lua:55-83`); the refresh now builds three lists (N9: ≈250 tables, ≈2,000 strings) |
| Director writes | 3 × (5–6 `UpdateProperty`/`UpdatePropertyList`) | `Attention` + the lists that changed (usually none) |
| Transient | the 351 KB body and its `C4:JsonDecode` tree in `result` until the callback returns (`src/hue_bridge/bridge/http.lua:137-139`, `:153`): several MB [not measured] | **unchanged**; the ≈10 KB grouped_light tree lives a little longer (until the zone lights' synchronous `finish` returns) |
| Kept for the driver's life | ≈200–250 KB [estimated]: models 60 KB, devices 15 KB, groups 40 KB, catalogue 50 KB, smart catalogue 30 KB, grouped caches ≈10 KB, registries and tombstones ≈10 KB, signatures | **≈ the same**: groups ≈ −4 KB (no `zones_by_light`), + ≈10 KB `list_rows_sent` (N9), + the coalescing tables and `prop_soon` state (tiny); the two grouped caches stay. Compiled bridge code: −606 code lines of 10,496 (−5.8 %, ≈18 KB less source) [estimate for the bytecode] |

How often: every `Stream Timeout (s)` seconds. The row's default is **600**
(`driver.xml:149-153`, set in 5d4c2ab and documented in the manual,
`src/hue_bridge/www/documentation.html:237`: "default 600 … Each reopening
is harmless"; `:227` "A reconnection every few minutes in a quiet house is
normal"), on purpose: `C4:url`'s `Cancel()` does not end an abandoned
transfer, which lives until its total timeout, so the design asked for
"minutes, not an hour" (`docs/design.md:224-228`, `:257-262`). That
argument predates the address rotation (`docs/design.md:255-290`), which
puts each new transfer on a spelling the abandoned one does not hold. So
unless the house's row was changed by hand, the idle house runs the chain
above about **144 times a day**, each with the several-MB transient, 15
project calls and a fan-out to the four devices. The morning's "every hour
at the latest" read `stream.DEFAULT_TIMEOUT` (3600, `stream.lua:38`), which
only applies when the property is missing. This is the one cost in this
review that dwarfs every per-event item, and it is a property value; see R1.

### B. One container, end to end

Reference container (Master Bedroom), before → after, counted the same way
(the morning rounded its total to "about 80 tables and 100 strings"; with the
per-step figures it wrote down the same count comes to ≈93 and ≈112, which
is the baseline used here):

1. `OnBodyChunk` → `handle_chunk` (`stream.lua:253-267`): `Cancel` + `SetTimer`
   + closure + timer object → **1 `C4:GetTime`**. `sse:feed`: 1 concat + 3
   line `sub`s + 1 tail cut (was + 2 copies of the remaining buffer, up to
   2 KB each).
2. `handle_event` (`:269-292`): `os.date` 1 string, `C4:JsonDecode` ≈20
   tables (unavoidable), the status `string.format` 1 string → `prop_soon`
   (a table write; an `UpdateProperty` at once only if the row was not
   written this second). Unchanged otherwise.
3. `driver.lua on_container` (`:516-529`): the three modules, then two
   `prop_soon`. On `add`/`delete` the refresh of N9 (≈250 tables, ≈2,000
   strings, 2 + 4 project calls, 1–6 Director writes).
4. `lights:on_container` (`lights.lua:1521-1552`): `skip_cache` false/nil;
   the light item → `hue_model.update` 2 tables; no entry → 0. **≈2 tables,
   0 messages** (unchanged).
5. `scenes:on_container` (`scenes.lua:1491-1525`): no `rest` table (−1); per
   grouped_light item 1 `fields` table + `level_text` (2 strings, `:193-199`);
   a changed level → `send_group_for` → `reg:rids()` (3 tables, 2 strings)
   → per match `send_group` (1 table) → `device_send` (no dump: −1 table, −≈4
   strings, −sort, −concat each). **≈8 tables, ≈8 strings, 2 messages** (was
   ≈11 tables, ≈17 strings).
6. `zone_lights:on_container` (`zone_lights.lua:1231-1274`): `touched` +
   `carried` (2 tables); per grouped_light item `touch_owner` twice (≈12
   lookups) + `update_grouped_light` (2 tables) + `fields` (1); the light
   item → `touch_members` (≈6 lookups); both entries touched → `refresh_all`:
   `rids()` (3 tables, 2 strings) + 2 × (`refresh_entry` ≈6 tables,
   `configure_changed` ≈6 tables and ≈22 strings, `color_of` ≈4 tables and 1
   string, `online_of`, `fields`, `send_state` 1 table). **≈54 tables, ≈72
   strings, 2 messages** (was ≈55 tables, ≈86 strings with the dumps).

Totals, reference container: **≈93 → ≈87 tables, ≈112 → ≈85 strings; Director
calls 9 → 8** when containers are a second or more apart (3 `UpdateProperty`
+ 1 `SetTimer` + 4 `SendToDevice`; before 3 + `Cancel` + `SetTimer` + 4), or
4 `SendToDevice` + (3 + 1)/N each in a burst of N a second; plus 1
`C4:JsonDecode` and now 1 `C4:GetTime`.

The common container, a light in any of the 21 groups with no zone-light
device (most light events on the house): before ≈93 tables and ≈112 strings
too, since `refresh_all` ran for both entries whatever the item; **after ≈48
tables and ≈17 strings** (the JSON tree, the sse pieces, `hue_model.update`,
3 `fields` tables with 6 `level_text` strings, 3 × `rids()` for groups no
scene is registered on, `touched`/`carried`, the grouped_light cache
updates), 0 messages, **Director calls 5 → 4**.

Messages sent when nothing changed: none, as before (`refresh_all` sends
`on`/`brightness` whenever the item carried them, by contract,
`zone_lights_spec:530-546`; `on_grouped_light` sends `on` only on change and
`level` only when its text differs from the last sent). Per resync: full
state to every device, by contract (the morning's do-not-touch list).

Scaling with imports (the morning's case: 23 zone lights, 126 scenes): the
zone side is now the ≤4 groups a light belongs to (≈80 tables, ≈140 strings)
plus the N3 scans (≈1,400 lookups, no allocation) instead of ≈460/≈800; the
scene side is unchanged and becomes the largest term: `send_group_for` sorts
all 141 registry records per grouped_light item with a changed level, 3–5
per container (≈450–700 record tables, 3–5 sorts, ≈3,000–5,000 `:lower()`
strings per container; row R8).

### C. Timers

| Where | Before | After |
| --- | --- | --- |
| `stream.lua` watchdog | one-shot, re-armed on every chunk (`Cancel` + `SetTimer`), default 300 s, floor 60 | **one per connection** (`:112-136`, `:235`), re-armed only when it fires with data seen (1 `SetTimer` per 600 s while events flow); default 600 s; still cancelled by `drop_transfer`, `handle_done`, `stop` |
| `driver.lua` coalescing (new) | — | one-shot 1 s (`:71`, `:92`, `:103`), armed by the first event of a second, re-armed while values keep coming, dropped after one empty fire; **never while idle** |
| `stream.lua` connected deferral 1 ms, retry 1 → 60 s | same | same (`:242`, `:322`) |
| `commands.lua` per-rid timer: 80 ms debounce re-armed per `set()`, token waits, retries | same | same (`:258-272`, `:290`; the morning's do-not-touch) |
| `driver.lua` Driver Version re-read 5 s, 10 s | same | same (`:605`) |
| `driver.lua` reconcile after a binding change 1 s, one per callback, never cancelled | same | **same** (`:1226-1229`; row R5) |
| `conntest.lua` 1 ms | dev action | not in release builds |
| Device drivers (fallbacks, click guard, hold start, ramp-after-on, the 100 ms hold tick while a button is held, the scene's level-report window, follow, pending, the binding re-check at 5/10/15/30 s, Driver Version) | same | same (`src/common/device.lua:69`, `:440-459`; `src/hue_light/driver.lua:305-313`, `:720-746`; `src/hue_scene/driver.lua:357-371`, `:414-424`, `:492-501`) |

While idle: **one armed timer (the watchdog) before and after**, none
firing. While events flow: 2 Director timer calls per chunk before → 0 per
chunk after (a clock read instead), plus the coalescing's 1 `SetTimer` per
second with events and the watchdog's 1 per 600 s. Outside Lua, curl's total
timeout (`Stream Timeout (s)`) ends the transfer every 600 s by default →
retry timer (1 s), deferral (1 ms), watchdog arm, and the chain of 4A.

### D. Command queues (`bridge/commands.lua`)

Per `set()` (`:279-291`): `light()` (a table on first use), `merge` (1
table, 5 `tonumber`), `arm` (`Cancel` + `SetTimer` + closure) — unchanged, the
morning's do-not-touch. Before it, the driver's handler builds its `fields`
table and, now gated (`driver.lua:1126-1130`, `:1153-1156`), no longer the
eight `tostring` and the `sub` of an info line that is off; the limits still
cost 3 tables per tick (row R4). Per `flush()` (`:317-364`): `now()` without a
closure (−2–3 per PUT); `commands.body` 2–5 tables; the `send` closure;
`http.request` with `http.options` (3 tables, `http.lua:40-53`), `headers_for`
(1), `C4:JsonEncode`, `C4:url()`, two closures — unchanged. The group path:
`zone_lights:set`'s info line gated (`zone_lights.lua:1338-1343`, −9
`tostring` per group slider tick), `scenes:level`'s two gated
(`scenes.lua:1887`, `:1895`, −3 `level_text`); `zone_lights:dim` (`:1382`) and
`scenes:dim` (`:1826`) still build an info line per hold start and stop (two
per hold: fine).

### E. Logging

Every hot-path argument list the morning named is gated now: the message
dump (`driver.lua:261`), the device-side dump (`device.lua:156`), HUE_SET and
HUE_DIM (`driver.lua:1126`, `:1153`), `zone_lights:set` (`:1338`),
`scenes:level` (`:1887`, `:1895`), the unimported count (`scenes.lua:1221`),
`OnBindingChanged` (`driver.lua:1211`) and `OnSystemEvent` (`:1267-1269`: the
600-character `sub` and the print per project event were `log.always`, now
debug). `log.always` remains for owner diagnostics (actions' results, adopted
/ back / deleted lines, Test Connection) and the AddDevice shape dump once
per run. `dispatch.lua`'s `tostring` per command stays (cheap; it protects
the format). Director's own log line per `SendToDevice` is the one
per-message log cost left (row R7).

## 5. Still worth doing, ranked by benefit ÷ risk

"Release" says whether the row is safe for this release (**now**: small,
pinned by existing specs or one added spec, no owner-visible change) or
should wait (**wait**: an owner decision, a contract change, or a gain that
exists only once the owner imports more).

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs | Security | Release |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | `src/hue_bridge/driver.xml:149-153` (`Stream Timeout (s)` default 600); manual `documentation.html:227`, `:237-238`; rationale `docs/design.md:224-228`, `:257-290` | First have the Windows session read the house's row. Then decide the default: the "minutes, not an hour" argument (an abandoned transfer blocks the next connect until its total timeout) predates the address rotation, under which each connect takes a spelling the abandoned one does not hold (7 for the house's address); 1800–3600 s would cut the idle chain of 4A to a third or a sixth. The watchdog (600 s) then becomes the usual reconnect on a quiet bridge, and its zombie lives until this timeout: with 3600 s, six zombies would have to pile up before a collision | 0 (+1 xml, +2 manual) | Per idle hour: 6 → 1–2 full resyncs, each 9 GETs (351 KB + its decode tree, several MB), 6 reconcile project calls, 1 `PersistSetValue`, a fan-out to every device, one refresh (≈2,000 strings, 2 + 4 project calls). By far the largest cost left | **Medium**: a design decision with hardware history (`docs/design.md` "Stream address rotation"); the watchdog/zombie interplay was measured with 600 s only. A property change needs no build; the default needs a manual edit | None pins the default (`stream_spec:61` pins "a long timeout" from `stream.DEFAULT_TIMEOUT`; `drivers_spec:119-120` a property change, `:259-270` the single-queue cap). The Composer checklist gains "a day of `Event Stream`'s Connected since times" | none | **wait** (owner's call; the row's value can be read today). **Settled** in release 1.0: default 3600, the house's row 3600 |
| R2 | `driver.lua:435` (`prop("Attention", …)` in `refresh_lights_props`) | Remember the last `Attention` text and skip an identical write, as `show_list` does for the lists (`:409-413`) | 0 (+3) | −1 `UpdateProperty` per refresh: per resync (every 600 s by default), every add/delete container, binding change (twice), goodbye, Composer rename and action | Low: the same last-value idea already runs for four rows; `Attention` is read-only and never restored on purpose | `drivers_spec` asserts `env.Properties["Attention"]` values only; add one: two refreshes with the same text record one `UpdateProperty` (`tests/helpers/fake_c4.lua:292-298`, `calls_to` `:710`) | none | **now**; **done 2026-10-25** (#50) |
| R3 | `scenes.lua:1402` (`on_scene_item`), inputs `:682-702` | Compute `configure_changed(rid)` only when `changed` has `name`, `group_rid` or `auto_dynamic`; `update_scene` can report name, active, auto_dynamic, speed, group_rid (`src/hue_bridge/bridge/hue_model.lua:475`), and neither `active` nor `speed` is a CONFIGURE input; group renames reach CONFIGURE through `refresh_group_names` (`:637-652`, `:1519-1522`), slot renames through `tell_slot_scene` (`:1350-1358`) | 0 (+2) | Per status event of a registered scene (every recall, every member light switched off): −≈6 tables, −≈20 strings, −1 sort | Low–medium: the gate must list every CONFIGURE input a scene item can carry; today's list is three fields | `scenes_spec:472-486` (status → GROUP + STATE, no CONFIGURE), `:488-497` (rename → CONFIGURE), `:2022` (time-based rename and re-time); add one: a status-only item for a registered scene calls `configure_params` not at all (a spy, as `zone_lights_spec:746-749` does) | none | **now**; **done 2026-10-25** (#50) |
| R4 | `driver.lua:1131`, `:1157` | Call `state.queue:limits(rid, …)` only when the three numbers differ from the queue's cached `lights[rid].limits` (or none is cached) | 0 (+6) | −3 tables per slider tick per light (≈10 a second per light during a drag); 0 today, 47 lights' worth once they are imported again | Low: the limits still follow a changed HUE_CONFIGURE the next time they differ | `commands_spec:170-182` (the `limits()` seam), `:43-58` (clamping), `roundtrip_spec` HUE_SET → PUT | none | **now** (pays only once lights are imported); **done 2026-10-25** (#50) |
| R5 | `driver.lua:1226-1229` | Keep one pending reconcile timer: cancel the previous before arming | 0 (+4) | Per burst of N binding changes: −(N−1) × (`GetBoundConsumerDevices` + `GetDevices` + registry pass + a refresh with its three lists) | Low | `drivers_spec`/`roundtrip_spec` binding tests fire every armed timer (`fake_c4.lua:727`), so one or N give the same end state | none | **now**; **done 2026-10-25** (#50) |
| R6 | `lights.lua:2744-2754` (`list_items`' comparator), `:597-622` + `:2414-2415` + `:2423` (`new_models()` sorted twice per refresh to count) | Precompute `room:lower()` and `name:lower()` in the row, as `scenes:list_items` does (`scenes.lua:2824`); count new models without sorting (or compute `new_models()` once per refresh and pass it to `summary()` and `attention()`) | 0 (+6/−2) | Per refresh ≈ −2,000 short strings and −2 sorts of 47 (of N9's ≈2,000 strings); pure CPU, no Director calls | Low: texts and orders pinned | `lights_spec:1821-1846` (texts), `:1903-` (`list_items`), `:1750-1820` (pickers, which keep `unimported_models`' order) | none | **now** (optional: CPU only); **done 2026-10-25** (#50) |
| R7 | `driver.lua:264` | `C4:SendToDevice(id, command, params, false, log.enabled("debug"))`: `allowEmptyValues` stays false (the modules rely on empty strings being dropped, `hue_model.lua:334`), `logCommand` false outside Debug Mode (the SDK's `SendToDevice` page: the flag defaults to true, and false keeps the call's content out of the log; `~/c4-tools/reference/docs-driverworks-api/source/includes/32_serial_network_device/_19-SendToDevice.md`) | 0 (+1) | Director stops logging one line with the full parameter table per message: 4 per reference container, 4+ per resync fan-out, 47 more with lights [assumed: what Director does with `logCommand` at its default log level is not documented beyond that sentence] | Low–medium: a diagnostic surface the hardware debugging has used; Debug Mode brings it back | The fake ignores extra arguments; no spec change | improves (less in Director's logs; the params carry no key) | **wait** (the morning's open question 3); **decided 2026-10-25** (#51): `logCommand = log.enabled("debug")`, so Director logs each message only while `Debug Mode` is On |
| R8 | `scenes.lua:806-816` (`send_group_for`), `:899-915` (`send_other_active`), `:1350-1358` (`tell_slot_scene`); optionally `registry.lua` (a `rids_of(set)` or an exported comparator) | Filter with `pairs(self.registry)` first and sort only the matches with the registry's `by_name` rule (`registry.lua:152-160`); a subset sorted by the same comparator keeps the order `rids()` gave. In `on_grouped_light` (`:858-880`) skip `level_text` when no linked scene is on the group | 0 (+12) | Per grouped_light item with a changed level (3–5 per container, for every group on the bridge): 141-record sort → k ≤ 7 (0 for the 21 groups with no registered scene). Today (2 entries) nothing measurable; with the scenes imported it is the largest per-container term (section 4B) | Low–medium: no cache to invalidate (unlike the morning's row 14), but it touches the registry's API and the one function whose message order 36 `commands_sent()` assertions pin | `scenes_spec:920-1072` (HUE_SCENE_GROUP), `:989`, `:1722-1757`; `registry_spec:369-383`, `:462` (order) | none | **wait** (no gain until scenes are imported in numbers); **done 2026-10-25** (#51) |
| R9 | `zone_lights.lua:1180-1190`, `:1199-1220` | A grouped_light rid → registered rid index and a light rid → zone set, maintained from `absorb`, `apply`, add, relink, forget, tombstone, reconcile and `goodbye` | 0 (+25) | N3's ≈1,400 lookups per container at 23 zone lights → ≈20; zero allocation either way | Medium: the invalidation class the morning's row 14 described; today's scans allocate nothing | `zone_lights_spec:529-793` ("events") in full | none | **wait** (likely never); **declined 2026-10-25** (#51): zero allocation today, and an index brings the invalidation risk |
| R10 | `src/hue_light/light/state.lua:155-158`, `:230-239` (`proxy_view` twice, `C4:ColorCCTtoXY` up to three times per ct-mode HUE_STATE with `report_color`, `src/hue_light/driver.lua:274-285`) | A one-entry memo of mirek → xy in `to_proxy_color` | 0 (+4) | −2 C calls per ct-mode HUE_STATE to a light or zone light | Low, but `light_state_spec:249` pins the comparison through the conversion (the morning's device review: "not worth it") | `light_state_spec`, `light_driver_spec:639-690` | none | **wait**; **done 2026-10-25** (#51) |

**Status (2026-10-25)**, branch `fix/review-leftovers-43-65`, contract
`docs/review-leftovers-design.md`: R2–R6 (#50), R8 and R10 (#51) are done.
R7 is decided by the coordinator under the owner's instruction of
2026-10-25 to settle what was still in his bucket: `C4:SendToDevice` passes
`logCommand = log.enabled("debug")`, so Director logs each message only
while `Debug Mode` is On (the setting brings the diagnostic surface back
when it is needed). R9 is declined: the scans allocate nothing today, and
an index would bring back the invalidation risk of the morning's row 14 for
a gain that exists only with many zone lights. R1 was settled in release
1.0: `Stream Timeout (s)` defaults to 3600, and the house's row reads 3600.

Not proposed, with the reason: the resync transient (the 351 KB body and its
tree) cannot be shortened from Lua, since both live in Director's `responses`
until `OnDone` returns (`http.lua:123-154`); the only lever is frequency (R1).
The lists of N9 could be rebuilt only when a module's data changed, but the
dirty flags that exist are for persistence, and comparing one joined string
per list is already what keeps the Director calls down. The morning's row 14
as written (an order cache with invalidation in the registry and in the
three modules' `take_name`) stays declined; R8 gets most of the effect
without a cache.

## 6. Do not touch

Additions to the morning's list, which stands (the resync after every connect
and its "changed or not" fan-out; the 1 ms deferral; the `PersistSetValue`
per connect; `prop_list`'s double write; the debounce re-armed per `set()`;
`copy(DEFAULT_LIMITS)`; the signatures in `last_configure`; `lights.models`
holding all 47 lights; the early-command queue; `sse.MAX_LINE`).

- **`prop()` clearing a value still waiting** (`driver.lua:76-79`) and the
  state texts going through `prop`, not `prop_soon` (`:479`, `:1179`,
  `:1200-1201`): a waiting count never overwrites "Stopped" or Forget
  Pairing's 0 (`drivers_spec:248-256`).
- **`touch_owner` before and after `on_grouped_light_item`**
  (`zone_lights.lua:1241-1243`): a `delete` item clears the owner link, so
  the call before it is what finds the entry that must go offline; the call
  after it picks up an `add` item's new owner.
- **`all = true` for a light or device item the lights' cache lacks**
  (`:1251-1264`): every entry is checked, as every container was before the
  filter; it covers an event that races the first resync.
- **`self.skip_cache = false` at `on_container` entry and `nil` at exit**
  (`lights.lua:1528`, `:1550`): the contract "consulted at each use" holds
  across containers (`lights_spec:1198-1239` swaps the provider between
  calls), and the reset at entry means an error that escaped the previous
  container cannot leave a stale set.
- **`reg:rids()` in `refresh_all` rather than iterating `touched`**
  (`zone_lights.lua:1105`): the message order is pinned ("in name order",
  `zone_lights_spec:762`).
- **`now_ms()`'s `pcall`** (`stream.lua:85-95`, `commands.lua:50-62`):
  `C4:GetTime` is documented from OS 3.2.3; the fallback keeps the watchdog
  and the token bucket alive on a runtime without it.
- **`list_rows_sent` and the double write in `prop_list`** (`driver.lua:112-116`,
  `:398-414`): build 184 (`docs/status.md`, "the list needs `UpdateProperty`
  beside `UpdatePropertyList` to move the row").
- **The two grouped_light caches** (`scenes.group_on/group_level`,
  `zone_lights.group_state/owners`): the GET is shared now, the caches are
  two contracts' (`docs/scene-dimmer-design.md`, `docs/zone-light-design.md`
  Decision 11); merging them is the lifecycle-merge class the brief's rule 4
  ranks last.
- **`device.lua`'s hooks read at call time** (`device.lua:321`, `:372`, `:454`):
  the drivers assign `dev.is_on`, `dev.button_action` and
  `dev.on_bridge_found` after the functions they call exist
  (`hue_light/driver.lua:257`, `:832`, `:851`); binding them earlier would
  capture nil.
- **The watchdog's `fed_since_arm` and `last_data` pair** (`stream.lua:118`,
  `:125-129`, `:254-255`): the remainder is computed from the clock, so a
  chunk that arrives just before the fire does not reconnect
  (`stream_spec:201-228`).

## 7. Open questions for the coordinator

1. **The house's `Stream Timeout (s)` row.** 600 (the default) or changed by
   hand? One read by the Windows session decides whether R1 is the top item
   or already settled; a day of the `Event Stream` row's "Connected since"
   times (or `stats.reconnects` from a dev build) gives the real resync
   rate, which the morning's question 2 asked for and this review still
   cannot answer from the code.
2. **Director's per-message log** (R7): still the owner's call.
3. **The lists per refresh** (N9): acceptable as they are (≈2,000 strings per
   refresh, Director told only on change), with R6 trimming the lights'
   half, or should a refresh after an `add`/`delete` container rebuild only
   the module's list that container concerns? The second needs the three
   `on_container`s to report what changed; not proposed.
4. **Event rate** (the morning's question 5): unmeasured; with the filter of
   row 3 in place the per-container cost no longer grows with the zone
   lights imported, so the measurement matters less than it did.
5. **R8 timing**: now, while the registries are small and a slip would be
   obvious in the specs, or when the owner imports scenes in numbers?

Answers (2026-10-25): 1. 3600 since release 1.0 (the house's row reads
3600); the real reconnect rate is part of #65's hardware pass, and the
`Event Stream` row now counts the reconnections since the driver started,
so it can be read off Composer. 2. Decided: R7 (§5, status). 4. #65's
hardware pass. 5. Now: R8 is done (#51).

## Five lines

- **Per container**: reference container (both zone lights touched) 9 → 8 Director calls when containers are ≥1 s apart (3 `UpdateProperty` + 1 `SetTimer` + 4 `SendToDevice`; in a burst of N a second, 4 each + (3 + 1)/N), ≈93 → ≈87 tables, ≈112 → ≈85 strings, plus one `C4:GetTime`; the common container (a light outside the two registered groups) 5 → 4 Director calls, ≈93 → ≈48 tables, ≈112 → ≈17 strings, no message.
- **Startup memory**: kept data ≈ unchanged at ≈220–260 KB [estimated] (−4 KB groups index, +≈10 KB list memories); bridge code −606 code lines (−5.8 %); the resync transient (351 KB body + its decode tree, several MB) unchanged and, by the `Stream Timeout (s)` default of 600, every ten minutes.
- **Timers while idle**: one armed (the watchdog) before and after, none firing; while events flow 2 Director timer calls per chunk → 0 (a clock read instead) plus one 1 s coalescing timer per second with events.
- **Fix now**: read the house's `Stream Timeout (s)` row (R1: a 600 s value means a full resync every ten minutes, the largest cost left), and take R2 and R3 (the unconditional `Attention` write per refresh; the CONFIGURE signature per scene status event): tiny, pinned.
- **Leave**: the sorted `rids()` per grouped_light item (the morning's row 14, here R8/R9): two records today, and any cache or index adds invalidation to the one path whose message order 36 assertions pin.
