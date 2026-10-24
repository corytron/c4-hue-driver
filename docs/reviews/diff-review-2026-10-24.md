# Diff review of the slimming, 2026-10-24 (`main..release-prep`, `src` and `tools/build.sh`)

Read-only review of the five slim commits (`cdeecbe`, `9cd2841`, `d04ad02`,
`688dcd1`, `98daca6`) and the release-prep commits under them (`7142852`
lists, `eacbfe2` `list_items`, `1a9e407` `util.lua`), against the brief
`docs/reviews/slim-2026-10-24-brief.md` (rule 1: no behaviour visible to the
owner changes), the proposals `docs/reviews/slim-*.md`, the contracts
`docs/*-design.md` and `docs/status.md`. Method: every file of the diff read
hunk by hunk, the new modules (`bridge/util.lua`, `bridge/project.lua`,
`bridge/devtools.lua`, `common/device.lua`) in full, the new bridge driver in
full against `main`'s, the two device drivers' moved blocks against `main`'s,
every deleted function name grepped across `src`, `tools`, `tests` and `docs`,
and the spec diffs read for removed or changed assertions. `busted tests` is
green at 1124, `luacheck src tests tools` clean (run here, read-only).
Nothing was run against the controller or the bridge; line numbers are those
of `release-prep` at `98daca6`.

## 1. Findings, ranked

No must-fix. Nothing in the diff breaks a documented text, message, picker or
action; the five rows below are a hygiene gap in the hot path, two timing
changes the coordinator chose that the owner should see written down, a
default that the house will not pick up, and contract documents a rename pass
mangled.

| # | Severity | File:line | What changed | Why it is a regression or a risk | How to prove it (spec to add) | Fix |
|---|---|---|---|---|---|---|
| 1 | should-fix | `src/hue_bridge/bridge/lights.lua:330-341` (`foreign`), `:1521-1551` (`on_container`: `skip_cache = false` at 1528, `nil` at 1550) | The zone-light skip set is built once per container (`skip_cache` is `false` on entry, the set after the first `foreign()`, `nil` after the loop) instead of once per message. | The reset to `nil` is the last statement of `on_container` and nothing between `http.lua:205-207` (`OnBodyChunk` → `handlers.on_chunk`, not pcall'd), `stream.lua:286-288` and `driver.lua:516-521` catches an error. An error escaping `on_light_item`, `on_connectivity_item`, `groups:apply` or `flush()` leaves `skip_cache` a table until the next container, and in that window every `foreign()` outside a container (`hello` 1044, `relink` 1856, `forget` 2050, `tell` 347) reads a stale set, contrary to the contract "consulted at each use" (`lights.lua:82-85`, zone-light-design §4/§7 Q 11). The practical window is small (the set only goes stale if Add Zone Light runs meanwhile, and new zone devices hello with `kind=group`), but the brief's rule 2 asks for no new hazard on the event path. | In `lights_spec` "skip_devices": stub `L.on_light_item = function() error("boom") end`, `pcall(L.on_container, L, container(F.events.ct))`, then assert `L.skip_cache == nil`; swap `L.ctx.skip_devices` and assert `L:foreign(ZONE_DEVICE)` follows the new provider. | Run the loop body under `pcall` (the module already has `protect`) and set `self.skip_cache = nil` on both paths before re-raising or logging; three lines. |
| 2 | should-fix | `src/hue_bridge/driver.lua:482-515` (`on_connected`), `:511` (the one `refresh_lights_props()`); was three calls at `main` `driver.lua:490`, `:506`, `:518` | `Lights`, `Attention`, `Room Mappings`, `Scenes` and `Zone Lights` are refreshed once, after the zone lights' resync, instead of after each of the three resyncs. | Two visible effects. (a) After every reconnect the `Lights`/`Attention`/`Room Mappings` rows now wait for the scenes' catalogue GET (351 KB on the house bridge, `docs/status.md`) and the zone lights' settle; `slim-runtime.md` row 11 called this "sub-second", which the catalogue size does not support. (b) The chain's continuation rides on the scenes' `done`; `scenes:resync` keeps one pending `done` and the latest wins (`scenes.lua:1271-1276`), so a connect that arrives while a scenes resync runs, followed by another resync request before it ends (a second reconnect from a zombie transfer, or a Refresh Scenes click), drops that connect's `done`: the zone resync and the row refresh never run for it. The zone resync was lost the same way before; the refresh after the lights' resync was not. The rows then stay stale until the next add/delete container, action or reconnect. Rule 1 (timing counts as behaviour when the owner reads the row after a reconnect). | `drivers_spec`: connect, answer the lights' six GETs, start a `Refresh Scenes` while the scenes' resync is pending, answer everything, assert `Properties["Lights"]` reflects the new models. And one that asserts `Lights` is written before the scene GET is answered (the behaviour `main` had). | Either accept and record it (status.md, manual chapter 4 "within a few seconds"), or keep one cheap refresh after the lights' resync (`show_module_list("Lights", …)` + `Attention` + `Room Mappings` cost two `GetDevicesByC4iName` and one `GetDeviceDisplayName` per linked light) and the full one after the zone lights'. The coordinator chose (a) knowingly (commit `9cd2841`); (b) is the part worth a line of code: run the pending slot as a list, or at least log when a `done` is replaced. |
| 3 | should-fix | `src/hue_bridge/driver.xml:157-161` (`Stream Watchdog (s)` default 300 → 600), `src/hue_bridge/bridge/stream.lua:39`, manual `documentation.html:146`, `:238`, `:682`, `:842` | The watchdog default doubled; the manual's default list, property table, troubleshooting row ("no data for 600 s … ten minutes") and appendix say 600. | A property's value survives an in-place update (edge-cases-control4 §3.4: properties survive [verified: hardware]); only a new install takes the new default. The house keeps `300`, so the owner's bridge will read `Disconnected: watchdog: no data for 300 s` while his manual says 600 and "ten minutes". Not a code regression, a mismatch the release checklist should close. `docs/status.md` does not record the change at all. | None (hardware). Checklist item: after the update read `Stream Watchdog (s)` and set it to 600 if the manual's wording is wanted. | A line in `docs/status.md` ("What runs on the house": watchdog 300 on the house, 600 the new default) and in `docs/release-checklist.md`; or say "the default" instead of a number in the troubleshooting row. |
| 4 | should-fix | `src/hue_bridge/driver.lua:65-105` (`prop_soon`, `flush_prop_soon`), `:475-481` (`on_status`), `:527-528` (`Events Received`, `Last Event`); `stream.lua:97-101`, `:290-291` (`on_status(text, per_event)`) | The three per-container rows are written at most once a second each (first value of a burst at once, the latest when the one-shot timer fires, a direct `prop()` wins over a pending value). | A timing change the brief's open question 1 (`slim-bridge-driver.md` §4, `slim-runtime.md` §4 Q 1) left to the owner, done without a trace in `docs/status.md` or the manual: `Events Received`, `Last Event` and the "N containers, last …" text may lag up to a second during a burst (a dynamic scene playing, `documentation.html:755`). The code is right: a direct write (`Stopped`, `Disconnected`, `Connected since`, Forget Pairing's `0`) clears the pending value for that row (`:76-79`), the last value always lands, `OnDriverDestroyed` cancels the timer (`:1382-1385`), and `drivers_spec` "writes the per-event rows at most once a second" pins all of it. Listed so the owner sees the decision, not because the implementation is wrong. | Already pinned (`drivers_spec.lua:206-256`). Add nothing. | Record it in `docs/status.md` and the manual's `Events Received` row ("updated up to once a second"). |
| 5 | should-fix (docs) | `docs/import-design.md:464`, `docs/scenes-design.md:155`, `docs/zone-light-design.md:190`, `:337`, `docs/smart-scenes-design.md:96`, `docs/design.md:268`, `:931` | A mechanical rename pass over the contracts wrote things like `` `sc:entry(rid).device_id (device_for removed 2026-10-24)(rid)` ``, `` `hue_model.registry_configure_params (configure_params merged into it 2026-10-24)(light, device, extra)` `` and `` `smart_scene_count (removed 2026-10-24, unused)` stays for compatibility ``; `design.md` still names `for_stream(ip)` (gone, `altaddr.lua:46-50`) and puts `Connection_Test` in `driver.lua` (now `bridge/devtools.lua:350`). | These are the contracts the brief names as the behaviour's definition; three of the sentences no longer parse. Not runtime. | None. | Rewrite the five sentences by hand: "`sc:entry(rid).device_id` (the former `device_for`)", "`hue_model.registry_configure_params(rid, entry, extra)` (the live-light variant `configure_params` was removed 2026-10-24)", "`smart_scene_count` was removed 2026-10-24 (no caller)", "`altaddr.padded(ip, 3)`", "`connection_test` in `bridge/devtools.lua`". |
| 6 | nit | `src/hue_bridge/bridge/http.lua:40-53` (`http.options(overrides, tls)`), `:46` | `tls`, when given, replaces the ssl options wholesale. | A caller passing a partial or empty table (`tls = {}`) sends no `ssl_verify_peer` at all and gets `C4:url`'s default. No release code passes `tls` (grep: `conntest.lua:84`, `:97`, `:136`, `pinning.lua:23`, `:30`, all dev builds, all full tables), so this is a seam to guard, not a hole. Security: needs care. | `http_spec`: `tls = {}` → assert `ssl_verify_peer == true` (or an error). | Treat `tls` as overrides on top of `ssl_options()` (`for k, v in pairs(tls or {}) do opts[k] = v end` after the bundle's), or refuse a `tls` without `ssl_verify_peer`. |
| 7 | nit | `src/hue_bridge/bridge/util.lua:71-78` (`has_field`) | The shared copy is the lights' (`ipairs(fields)`); the scenes' copy had `ipairs(fields or {})` (`main` `scenes.lua:321`). `slim-lights.md` row 1 asked for the superset. | Every present caller passes a table (`hue_model.update`, `update_scene`, `update_grouped_light` all return `{}` for junk, `hue_model.lua:101-104`, `:487-490`, `:883-886`), so nothing raises today; a future caller that passes a `nil` "changed" list raises inside the event path. | `util_spec`: `has_field(nil, "x")` is `false`. | `for _, field in ipairs(fields or {})`. |
| 8 | nit | `src/hue_bridge/driver.lua:780-789` (`picker`), `:789` | The "(not available in this build)" picker entry survives as the answer for a `nil` module. | Reachable only before late init (Composer opening a list early); the text now means "not initialised yet", which the words do not say. Not in any manual or spec. | None. | "(not ready yet; open the list again)" or leave; cosmetic. |
| 9 | nit | `src/hue_bridge/bridge/scenes.lua:2543-2544` | Comment says `name_differences()` "is public so the driver can count them together with the lights'". | The driver never calls it (grep); `attention()` is the only caller besides `adopt_hue_names`. Stale comment. | None. | Drop the parenthesis. |
| 10 | nit | `src/hue_bridge/bridge/lights.lua:497-590` (`project_call`, `project_rooms`, `project_bound_set`, `project_lights`, `display_name`), `:378-401` (`copy_caps`, `same_caps`) vs `bridge/project.lua`, `zone_lights.lua:157-180` | `project.lua` was adopted by scenes and zone lights only (its header says so); `copy_caps`/`same_caps` stay duplicated in lights and zone lights (`slim-lights.md` row 8 not done). | Duplication the slimming left; not a behaviour risk. | None. | A later pass; `lights.lua`'s copies are byte-identical to `project.lua` but for the log prefix. |
| 11 | nit | `src/hue_bridge/bridge/http.lua:166`, `bridge/devtools.lua:64` | `Custom(url, method, …)` is gone; an unknown method now raises inside the `start` pcall and the request fails with `unsupported method …`. | Dev-only: `Hue Request` with `Method=PATCH` (not a CLIP v2 verb) now fails where it used to be sent. Release code issues GET, POST, PUT and DELETE only (grep). | None. | Say so in `devtools.lua`'s `hue_request` comment, or leave. |
| 12 | nit | `src/hue_bridge/www/documentation.html:228`, `:232`, `:236` (the `Lights`, `Scenes`, `Zone Lights` rows) | The rows are lists now and the row text passes through `commaless()` (`driver.lua:394-396`), so Composer shows `47 on bridge‚ 46 imported‚ …` (U+201A). | The manual's examples keep ASCII commas; only `docs/status.md:45` says commas read as "‚". Pre-slim (`7142852`), deliberate, but the manual should say it once. | None. | One clause in the `Lights` row: "commas appear as ‚ on the row, since the list is comma-delimited". |

## 2. Behaviours checked and found intact

Bridge driver (`src/hue_bridge/driver.lua`, 1864 → 1389 lines).

- Every message to a device: `device_send` (`:260-265`) sends the same
  `command, params` as `main`'s three senders; only the debug text is gated
  on `log.enabled("debug")`. Pinned by `roundtrip_spec`, `scene_roundtrip_spec`,
  `zone_light_roundtrip_spec`, `drivers_spec.lua:489-504`, all unchanged but
  for the list texts (below).
- Container order lights → scenes → zone lights (`:519-521`); `add`/`delete`
  still refresh the rows (`:524-526`); the three modules are no longer
  optional (`:15-17`), and `zone_lights:device_ids()` returns a set as the
  driver assumes (`zone_lights.lua:260-270`).
- Before late init: the early-command queue (HUE_HELLO / HUE_SCENE_HELLO
  queued, up to 200, anything else dropped, `:1283-1302`) is `main`'s
  verbatim; `refresh_lights_props` returns before the modules exist (`:431`);
  `list_pick` acts only after late init (`:739`); the pickers answer a
  placeholder for a `nil` module (`:789`) as before.
- `OnDriverLateInit` order (`:1333-1375`) is `main`'s: credentials, lights
  load/configure, queues, scenes, zone lights, reconcile, `fill_proxy_ids`,
  rows, property replay, Driver Version (`show_driver_version(1)` replaces the
  deleted `Driver_Version` handler, which the replay wrote one line earlier),
  stream, `late_init_done`, replay of early commands, probe events, status,
  stream start, then the dev loop last (`devtools.late_init()`).
- `OnBindingChanged` (`:1210-1231`): same three module calls, the same 1 s
  reconcile timer, `log.always` → `log.debug` (Lua output, not an owner text).
  `OnBindingValidate` unchanged. `OnSystemEvent` still refreshes the rows on
  `OnItemNameChanged`; all six probe events still registered (`:1246-1264`).
- Actions: every `dispatch.commands[...]` of `main` that an owner can reach is
  present with the same texts (`Not paired`, `Not added: pick a light first`,
  `Not re-linked: …`, `Not forgotten: …`, `Not mapped: …`, `Scenes refreshed:
  …`, `Scene refresh failed: …`); `Import_Lights` (no `driver.xml` entry) and
  the `lights:import` fallback are gone with no caller.
- `Test Connection` in a release build takes the dotted address and keeps its
  Status texts (`:678-712`); the dev variant with `Host` replaces the handler
  only when `common.devloop` loads (`:1318-1328`, `devtools.lua:419`), proven
  by `drivers_spec` "a release build (no common.devloop) carries none of the
  development handlers".
- `Forget_Pairing`, `Connect_Event_Stream`, `Disconnect_Event_Stream`: same
  writes; the direct `prop()` of `Events Received` 0 and `Last Event` ""
  clears any pending coalesced value (`:76-79`).
- Stream address rotation, `TIMEOUT_MIN/MAX`, `WATCHDOG_MIN` 60, the
  single-queue cap, `fill_proxy_ids`, `prop_list`'s double write, the
  `Stream Address` texts: untouched (`:57-218`, `:107-116`, `:902-919`).
- The `Lights`, `Scenes`, `Zone Lights`, `Last Action` list rows and the
  module `list_items()` (commits `7142852`, `eacbfe2`, in this diff but before
  the slimming): the row shows the summary, items one per line, a pick snaps
  back without looping (`list_rows` / `list_rows_sent`, `:392-414`,
  `:737-754`), a long `Last Action` split at "; " (`:720-733`); documented in
  `docs/status.md:39-49` and the manual's property table; pinned by
  `roundtrip_spec.lua:120-160` and the three `list_items` spec blocks. The
  "‚" in those rows is the deliberate consequence (row 12).

Transport (`bridge/stream.lua`, `sse.lua`, `http.lua`, `commands.lua`).

- Watchdog: one timer per connection, armed in `handle_headers` (`:235`);
  chunks record the clock (`:254-255`); on firing it reconnects when the last
  chunk is a whole period old, else re-arms for the remainder (`:112-136`), so
  reconnect-on-silence is exact to the second as before. A zombie's late
  chunks (`:204-216`) do not feed it. `drop_transfer` (`:141-149`),
  `handle_done` (`:296`) and `stop` cancel it; the firing timer nils itself
  before re-arming, so no `Cancel()` on a fired timer. The pre-existing spec
  "reconnects when the watchdog fires" (no chunk) still holds; the new
  "re-arms … for the rest of the period" pins the new path with
  `c4.now_ms`. `now_ms()` falls back to `os.time()` where `C4:GetTime` is
  missing (`:84-94`; SDK says 3.2.3+).
- `sse:feed` (`:72-97`): same events for the same bytes (the spec cuts the
  sample at every 7th byte, CRLF, partial lines); one tail copy per chunk;
  `MAX_LINE` and `overflowed` kept.
- `http`: the bundle is the only TLS configuration (`ssl_verify_peer = true`,
  `ssl_verify_host = false`, `ssl_cabundle = certs/hue_ca_bundle.pem`,
  `:34-36`); `http.ca == nil` still fails fast in `request` and `stream`
  (`:105-109`, `:185-188`); the `start` pcall and the pcall'd `OnDone` (H2)
  stay; `JsonEncode(body, false, true)` stays; `req.tls` is passed only by the
  dev modules (grep of `src`); `set_ca`, `set_ca_bundle`, `describe_ca`,
  `ssl_options`'s public form have no caller left in `src`, `tools` or `tests`
  (two spec lines assert they are nil). `conntest_spec` now asserts the bridge
  target runs on the bundle with `ssl_verify_peer` true.
- `commands`: `default_now` hoists the pcall'd function; nothing else changed.
  Limits, debounce, token bucket, generations, `stats()` untouched.

Lights, registry, groups (`cdeecbe`).

- `util.lua` holds byte-identical copies of `positive`, `norm`, `sanitise`
  (the `gsub(",", " ")` comma rule kept), `date_of`, `short_date_of`,
  `plural`, `some(names, max)` (every caller passes its module's `MAX_NAMED`,
  all 3), `signature`, `has_field` (row 7), `empty_list`; `registry.lua`
  aliases `positive`.
- `foreign()` keeps the contract across containers (`skip_cache` is `nil`
  outside `on_container`; `lights_spec.lua:1115-1240` swaps the provider
  between calls and passes); within a container the zone registry cannot
  change, since `zone_lights:on_container` runs after (`driver.lua:519-521`).
  Row 1 is the error path only.
- `automap_once`: the persisted flag stays the source of truth; the in-memory
  `automapped` only skips the re-read (`:1310-1324`; `lights_spec` 750-773
  green, its third case builds a new instance).
- `announce_new` and `hint_text` reproduce the two `log.always` texts and the
  " (looks like %s, device %d; re-link?)" text byte for byte (`:647-666`,
  `:2427`, `:2590-2592`); `name_differences(true)` is the old `adopt_hue_names`
  loop (`:2089-2131`); `each_mapping_row` yields the same rows in the same
  order (rooms then zones by name, then stale mappings by name) for both
  `room_mapping_items` and `picker_hue_rooms` (`:2525-2698`); hoisted
  constants (`groups.TYPES`, `BUSY_FLAGS`, `RELINK_STATES`, `NUMERIC_FIELDS`)
  are read-only.
- `groups:label` → `hue_model.group_label` differs only for a group named `""`
  ("(no room)" instead of ""), which `hue_model.group`'s name fallback never
  produces; `zones_by_light`/`roomless` had no caller in `src`
  (`import-design.md:454` updated).

Scenes, zone lights, model (`d04ad02`).

- `project.lua`: `defaults` is the seven-fallback block both modules had;
  `call` warns with the module's own prefix ("scenes: project.%s failed",
  "zone_lights: project.%s failed") as before; `rooms`, `bound_set`,
  `devices_of` ("unknown, never deleted", `nil` for an empty table) and
  `display_name` are the old bodies. `project_spec` covers them.
- `scenes:on_container` two passes over `items` ≡ the old `rest` table (smart
  items first, Decision 10; `scenes_spec` "in either order" unchanged).
  `configure_params`' `group_name` is `group_info`'s first value, as
  `group_name()` returned. `picker_groups` takes any record of the group as
  the label fallback; records of one group share their type. `add_all_of_group`
  reads the tombstones once. `recall_gen` initialised in `new`.
- `scenes:resync` hands `res.grouped_light` (the `/grouped_light` data array,
  `nil` when that GET failed, `scenes.lua:496-530`) as its fourth result
  (`:1297`); `zone_lights:resync(done, items)` skips its GET only for a table
  (`:1017-1019`), otherwise GETs as before; a busy zone module stores the
  pending `done` and GETs itself later (`:991-995`); `Refresh_Scenes` ignores
  the fourth value. Specs: "hands the grouped_light items to its done callback,
  nil when that GET failed", "takes the grouped_light items another module
  fetched and skips its own GET"; `roundtrip_spec` counts 9 GETs (6 + 3).
- `zone_lights:on_container` / `refresh_all(carried, touched)`: the filter was
  traced route by route. A `grouped_light` item touches its owner before the
  item is applied (a `delete` forgets the link, `:1221-1226` → `gone_grouped`)
  and after (an `add` brings the owner); a `light` item touches the zones
  holding it (`child_rtypes[rid] == "light"`) and the room holding its device
  (`child_rtypes[device_rid] == "device"`); a `device` item its room and the
  zones holding its `light_rids`; a `room`/`zone` item itself when registered
  (a `delete` → gone, an `add` of a gone rid → back); a light or device the
  lights' cache lacks (deleted, or never fetched) → every entry, as before.
  `bridge_home` and `zigbee_connectivity` items touched nothing before either.
  Messages are unchanged: an untouched entry had empty `fields`. Pinned by the
  unchanged "events" block (`zone_lights_spec.lua:510-737`) plus the new "an
  outsider's event costs nothing" (spied `refresh_entry`), and both round
  trips.
- `state_params` returns the colour signature it computed (`:551-581`);
  `color_of` returns `nil, ""` for no colour (`:512-527`), so `color_sent[rid]`
  is `""` exactly where the old `(not gone and online) and sig or ""` put it;
  `send_state` is the only caller (`:620`).
- Spec-only accessors removed (`device_for`, `proxy_for`, `rid_for`,
  `registered_rids` of scenes, `zone_lights:limits`, `zone_lights.join`,
  `hue_model.configure_params`, `smart_scene_count`): no caller in `src`;
  `driver.lua:1114`, `:1144` use `lights:device_for`, which stays;
  `driver.lua:961` uses `zone_lights:registered_rids`, which stays. The spec
  edits replace the accessor with the registry read (`reg:by_device`,
  `entry(rid).device_id`), the contract edits are row 5.
- `zone_lights:limits` was never wired (`group_set` queues without limits,
  `driver.lua:317-323`), so deleting it changes no PUT; the mirek clamp of a
  grouped_light stays `commands.DEFAULT_LIMITS` as on the house.

Device drivers and `common/device.lua` (`688dcd1`).

- The moved blocks were compared with `main`'s light (`141-158`, `340-427`,
  `582-603`, `651-709`, `805-810`, `1150-1181`, `1186-1301`) and scene
  (`480-509`, `941-966`, `1649-1680`, `1710-1800`) drivers: `prop`, `notify`
  (debug dump now gated), `device_id`, `result`, `bound_bridge` (table or
  number, 0 unbound), `proxy_id`, `Driver_Version` + `show_driver_version`
  retries at 5 and 15 s, `Debug_Mode`, `after_late_init` + the pcall'd drain,
  LEDs and button colours (same `COLOR_DEFAULTS`, `LINK_BINDINGS`,
  `BUTTON_LINK`, persisted keys), `BUTTON_ACTION` echo, `DO_PUSH/RELEASE/CLICK`,
  `REQUEST_BUTTON_COLORS`, `SET_BUTTON_COLOR` (both spellings), the re-check at
  5/15/30/60 s with its two info lines, the goodbye with its pcall and two log
  lines: byte-equivalent.
- The one semantic seam, the on state: `dev.is_on()` is `st.on` for the light
  (`hue_light/driver.lua:257-259`) and, for the scene, `nil` while
  `brightness() == nil` else `effective_on()` (`hue_scene/driver.lua:320-325`);
  `update_leds` coerces with `== true`. `effective_on()` is a boolean
  (`is_on() or held()`), and is `false` exactly when `brightness()` is `nil`,
  so `(dev.is_on() == true)` ≡ the old `effective_on()` in `send_button_colors`,
  `REQUEST_BUTTON_COLORS`'s `MATCH_LED_STATE` and `SET_BUTTON_COLOR`'s
  `send_button_info`, and `update_leds`'s early return ≡ the old
  `brightness() == nil` test.
- `late_init_done` is now set by `dev.late_init()` after `bridge =
  bound_bridge()` rather than at the top of `OnDriverLateInit`; nothing can
  arrive inside the callback, and the only wrapped handlers are the three
  bridge messages, so no observable change.
- Not merged, and unchanged: the hold machines, `end_hold` cancelling a
  time-based scene's `follow` (`hue_scene/driver.lua:1135-1143`), `take_kind`,
  `load_identity` (light warns on an unknown kind, scene silent: the drift the
  review noted stays as it was), targets and fallbacks, identity texts,
  `apply_recall_as`, `STOP_SCENE_RAMP`, the `SET_COLOR_TARGET` key lists.
- Dev-only: log forwarding moved to `devloop.forward_logs` (same 30-line
  buffer, own-line filter, one-time failure print through the captured
  `print`, `allow_empty`/`log_command` false), `DEV_RELOAD` through
  `devloop.reload_handler` (tree filter, the two log lines) and registered only
  when the loop loads; a release device answers `DEV_RELOAD` with dispatch's
  debug "no command handler" instead of a warning (dev-only message). The
  release path is pinned by `light_driver_spec` / `scene_driver_spec` (both
  files unchanged, both green) and `device_spec` "in a release build (no dev
  loop module) leaves log.sink alone and registers no DEV_RELOAD".
- `HUE_DUMP` removed: nothing sent it (grep of `src`, `tools`, `tests`);
  `docs/scenes-design.md:65`, `status.md`, `code-analysis` updated.
- `light/state.lua` takes `text`/`to_bool` from `common.device` (same bodies);
  `common.device` has no side effect at `require` beyond defining functions.

Build and packaging.

- `tools/build.sh:44-58`: release stages drop `common/devloop.lua`,
  `bridge/devtools.lua`, `bridge/conntest.lua`, `bridge/pinning.lua` and the
  DEV-ONLY blocks of `driver.xml` (whole `<property>`/`<action>` elements,
  `driver.xml:133-147`, `:377-406`); the bridge stage drops
  `common/device.lua`, which nothing in `src/hue_bridge` requires (grep); the
  device stages keep it. `tools/devserver.py:112-116` serves every
  `src/common/*.lua`, so a dev `DEV_RELOAD` bundle carries `device.lua`.
- `driver.lua:40` loads `bridge.devtools` only when `common.devloop` loaded;
  `devtools.lua` requires `conntest`, `pinning`, `devloop` unguarded, which is
  right since it exists only where they do.
- Pairing `devicetype` is now `c4-hue-driver#bridge` (`pairing.lua:26`): new
  pairings only, the house's key keeps its name; deliberate
  (`docs/licensing-research.md` §2, `pairing_spec`), and the Hue app's
  connected-apps list will show the new name after a re-pair.

Lua 5.1 and hygiene.

- No new `#` on a table with holes: the three `list_items` build arrays
  sequentially and sort them; `touch_*` and `prop_soon_*` are sets or maps
  read with `pairs`/`next` only; every owner-facing list still comes from
  `reg:rids()` or a sort. `string.format("%d", …)` gets registry fields the
  registry requires numeric (`device_id`) or numeric strings Lua 5.1 accepts
  (`light_count`). No closure captures a loop variable that outlives the loop.
  `luacheck` reports no globals.
- Deleted names grepped across `src`, `tools`, `tests`, `docs`: no live
  caller; the only mentions are the contract sentences of row 5 and
  `docs/design.md:268`, `:931`.
- `fake_c4.lua`, `.busted`, `.luacheckrc` unchanged.

## 3. What this review could not verify

- Anything on the controller: that Director keeps `Stream Watchdog (s)` at
  300 through the in-place update (inferred from "properties survive",
  edge-cases-control4 §3.4), what Director does with a streaming transfer
  after a Lua error in `OnBodyChunk` (the window of row 1), the real latency
  of the 351 KB scene GET (the visibility of row 2), and that
  `C4:UpdateProperty` on a DYNAMIC_LIST does not echo `OnPropertyChanged`
  (the lists' snap-back relies on it; verified for `Room Mappings` at build
  185, not yet seen for the four new rows or the `Last Action` split per
  `docs/status.md`).
- Nothing was run against the bridge; the resync chain and the grouped_light
  hand-over are proven in the fake only.

## Five lines

- Must-fix: 0. Should-fix: 5 (one code hygiene gap, `lights.lua:1521-1551`; one timing decision to confirm or soften, `driver.lua:482-515`; three documentation/ops items). Nits: 7.
- Most important: the skip-set cache (`lights.lua:330-341`, `:1528`, `:1550`) is cleared by the last line of `on_container` with no pcall anywhere up the chain, so an error escaping a container leaves a stale set for every `foreign()` until the next container; three lines fix it.
- Could not verify: anything on hardware (the watchdog property staying at 300 after the update, Director's reaction to an error in `OnBodyChunk`, the lists' snap-back for the four new rows, the scene GET's latency).
- The coalesced rows (≤ 1 s), the one refresh per resync chain and the watchdog default are the three owner-adjacent changes; the first two are pinned by specs but recorded nowhere the owner reads.
- Would ship: yes, after rows 3–5 (a few lines of docs and a checklist item) and, ideally, row 1's pcall; nothing found breaks a documented text, message or action.
