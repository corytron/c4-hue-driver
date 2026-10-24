# Slimming review: bridge driver, transport and common (2026-10-24)

Area: `src/hue_bridge/driver.lua`, `src/hue_bridge/bridge/{commands,stream,http,sse,altaddr,conntest,pinning,pairing,credentials,config}.lua`,
`src/common/{dispatch,log}.lua`; safety net `tests/spec/{drivers,roundtrip,commands,stream,sse,http,altaddr,conntest,pairing,pinning,config,dispatch}_spec.lua`.
Read-only review against the brief `docs/reviews/slim-2026-10-24-brief.md`; nothing was run against the controller or the bridge.

**Line numbers.** `driver.lua` grew from 1812 to 1864 lines while this review ran (the coordinator added the
list rows `show_list` / `list_pick`, the `devloop and require(...)` gating of `conntest` / `pinning`, the `devloop`
gate on Test Connection's `Host`, and the release unregistration of `Connection_Test` / `Reload_Credentials` /
`Check_CA_Pinning`). Every `driver.lua` number below is from the **1864-line** file; each claim also names the
identifier, so a grep finds it after further edits. The other files did not change.

## 1. Summary

The area is **3,613 lines** today (`driver.lua` 1864, `commands.lua` 432, `stream.lua` 294, `http.lua` 260,
`sse.lua` 96, `altaddr.lua` 129, `conntest.lua` 166, `pinning.lua` 36, `pairing.lua` 107, `credentials.lua` 57,
`config.lua` 47, `dispatch.lua` 76, `log.lua` 49), plus `common/devloop.lua` (686, dev builds only). The
removal the coordinator is doing (section 5) takes about **635 lines out of these files** (≈390 of `driver.lua`,
all 202 of `conntest.lua` + `pinning.lua`, ≈40 of `http.lua`, 3 of `altaddr.lua`) and, with `devloop.lua`, about
1,320 lines of shipped-or-staged code; the specs that go with it are listed per file. On top of that the
proposals below save about **30 lines at low risk** (rows 1–9) and about **135 at medium risk** (rows 10–12,
nearly all of it the "module not available in this build" scaffolding of `driver.lua`). The biggest runtime
wins are per message and per event, not per line: (1) every `HUE_STATE` / `HUE_CONFIGURE` / `HUE_SCENE_*`
message the bridge sends builds a sorted `k=v` debug string that production throws away
(`driver.lua:208-216`, `:221-226`, `:293-296`); (2) every stream chunk cancels and re-creates the watchdog
timer, two Director calls per event that a "remaining time" check replaces (`stream.lua:85-101`, `:218-219`);
(3) `sse:feed` re-slices its buffer once per line, so a chunk is copied about as many times as it has lines
(`sse.lua:73-94`). The three documented property writes per event (`Events Received`, `Last Event`,
`Event Stream`) are the largest fixed per-event cost and are contract-bound (section 6, open question 1).

## 2. Proposals, ranked by benefit ÷ risk

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs that pin it / to add | Security |
|---|---|---|---|---|---|---|---|
| 1 | `driver.lua:208-216` (`params_text`), `:221-226` (`new_lights().send`), `:293-296` (`device_send`); `http.lua:153`, `:229` | One `device_send` for all three modules, with the debug text built only under `if log.enabled("debug")`. In `http.request`/`http.stream` wrap the `" " .. data` / `tostring(req.timeout)` the same way. Lua evaluates arguments before the call, so today `params_text` (a table, a `pairs` loop, `table.sort`, `table.concat`) and `tostring(params.rid):sub(1, 8)` run for every message even with Debug Mode Off. | ≈6 | Per device message (per event × devices told; per hello; per resync message): one table, one sort, one concat and two `tostring` fewer. Per request: one string concat fewer. | Low: debug output only; the messages themselves are unchanged. No spec references `params_text` or these lines (grep of `tests/` empty). | Messages pinned by `roundtrip_spec.lua:147`, `:226-230`, `drivers_spec.lua:499-502`, `scene_roundtrip_spec`, `zone_light_roundtrip_spec`. Nothing to add. | none |
| 2 | `driver.lua:1158-1169` (`Import_All_New_Lights`, `Import_Lights`) | Drop the "until lights.lua's integration lands" fallback to `state.lights:import` (`lights.import_new` exists, `lights.lua:1785`) and the `Import_Lights` alias (the action is in no `driver.xml` and no manual; `devloop_spec.lua:538` names it in a comment only). Tell the lights reviewer `lights:import` (`lights.lua:1880-1888`) is then dead. | 6 (+10 in `lights.lua`) | none | Low: unreachable branch and an alias with no caller. | `roundtrip_spec.lua:131-147` pins Import All New Lights. Nothing to add. | none |
| 3 | `driver.lua:1686-1688` (`OnBindingChanged`), `:1711-1715` (`OnBindingValidate`), `:1717-1723` (`PROBE_EVENTS`), `:1742-1749` (`OnSystemEvent`) | The three `log.always` lines are probe-era ("Logged in full while docs/import-design.md §11 probe 1 is open", `:1684`): make them `log.debug`. Register only `OnItemNameChanged` (`:1722-1723`): it is the only event `OnSystemEvent` acts on (`:1746`); the other five produce a log line each and nothing else. Code analysis L8. | ≈1 | Per binding change: five `tostring` and a `print` fewer. Per Composer edit: no `tostring(data):sub(1, 600)` + `print`; and five system-event callbacks per project edit no longer reach the driver at all. | Low for the log level (Lua output is not in rule 1's list). Low–medium for the registration list: the fake has no `RegisterSystemEvent` (`register_probe_events` logs "unavailable", `:1726-1727`), so only hardware shows renames still refresh Attention. | `roundtrip_spec.lua:160-165` calls `OnSystemEvent` directly and checks Attention; still passes. Add to `docs/composer-checklist.md`: rename a device in Composer, Attention follows. | improves slightly (no project payloads in the log) |
| 4 | `sse.lua:73-94` (`sse:feed`) | Walk the buffer with a position: `local buf = self.buffer .. chunk; local pos = 1; while true do local nl = buf:find("\n", pos, true) ... pos = nl + 1 end; self.buffer = buf:sub(pos)`. Same lines, one copy of the tail per chunk instead of one per line (`:81-82` today). The `MAX_LINE` check (`:88-92`) stays. Half of code analysis M6 (the quadratic walk); the byte cap on `self.data` is hardening, not slimming, and stays open. | 0 | Per chunk with k lines (a Hue event is three: `id:`, `data:`, blank): k−1 fewer copies of the remaining buffer; the `data` line is the whole JSON payload, 0.2–2 KB per event today, larger for scene and smart_scene updates. | Low: pure function, exhaustively covered. | `sse_spec.lua:26-36` cuts the sample at every 7th byte; `:38-55` partial, multi-line and CRLF; `:73-78` overflow. Nothing to add. | none (cap kept) |
| 5 | `driver.lua:640-642` (`dispatch.properties["Driver_Version"]`) | Delete the handler: the replay at `:1832` triggers it and `show_driver_version(1)` (`:648-654`, `:1833`) writes the same value one line later, with the retries the AddDevice case needs. | 3 | One `UpdateProperty` fewer at every start. | Low: a read-only property Composer never changes; the retry path is untouched. | `drivers_spec.lua:56` asserts `"1"` after late init (still written by `show_driver_version`). Nothing to add. | none |
| 6 | `driver.lua:1446-1447` (`HUE_SET` `log.info`), `:1470` (`HUE_DIM` `log.info`); `commands.lua:50-56` (`default_now`) | `log.info` prints only in Debug Mode (`log.lua:19-21`), but its seven `tostring` calls and `rid:sub(1, 8)` run per command: guard with `if log.enabled("info")`. `default_now` builds a closure per call for `pcall(function() return C4:GetTime() end)`: `pcall(C4.GetTime, C4)` allocates nothing. | 0 | Per slider step and per hold: eight string allocations fewer; per flush/dim: one closure fewer. | Low. | `commands_spec.lua:231-242` pins `opts.now`; `drivers_spec`/`roundtrip_spec` pin the PUTs. Nothing to add. | none |
| 7 | `driver.lua:731-736` (`on_paired` read-back) | Drop the "is the store readable yet" log check after pairing; it is a diagnostic of the same family as Reload Credentials (`credentials.summary` stays for the startup line at `:1803`). | 6 | Three `PersistGetValue` fewer after pairing. | Low. | `drivers_spec.lua:177-189` pins the in-memory behaviour (`state.creds = creds`, `:728`), unchanged. | none |
| 8 | `driver.lua:115-135` (`next_stream_address`), `:140-152` (`stream_address_text`) | Both loop the family for the index of a spelling: one `family_index(spelling)` helper. | ≈6 | none (per connect) | Low. | `drivers_spec.lua:106`, `:125`, `:144`, `:170` pin the texts and the rotation. | none |
| 9 | `altaddr.lua:47-49` (`altaddr.for_stream`) | Dead in `src/` (the driver uses `for_check`, `driver.lua:599`, and `stream_family`, `:600`); `stream_family`'s first entry is the 3-digit spelling by construction (`altaddr.lua:87-90`). Remove it and write `altaddr.padded(ip, 3)` in the two spec lines. | 3 | none | Low. The spec is not wrong, it names a function the driver stopped using; the property it checks (family[1] is the all-3-digit spelling) is kept via `padded(ip, 3)`. | `altaddr_spec.lua:17-22`, `:42-51` edit as said. | none |
| 10 | `stream.lua:85-101` (`arm_watchdog`), `:218-219` (`handle_chunk`) | Arm the watchdog once per connection and record `self.last_data = os.time()` per chunk. When it fires: `idle = os.time() - last_data`; `idle >= seconds` → reconnect as today; else re-arm for `seconds - idle`. Reconnect-on-silence stays exact to the second; `os.time()` is enough for a ≥ 60 s watchdog (`driver.lua:171`). | −3 (adds three) | Per event: one `Cancel()` and one `SetTimer()` (plus the timer closure) fewer; the timer is touched once per watchdog period instead of once per chunk. | Medium: timer logic in the hot path; the generation check (`:91-95`) and `drop_transfer`'s cancel (`:108`) must stay. | `stream_spec.lua:124-142` (one active timer after connect), `:188-199` (fires with no data → reconnects), `:97-113` (cancelled with the transfer), `:280-311`. Add: a chunk inside the window makes the firing watchdog re-arm for the remainder, not reconnect. | none |
| 11 | `driver.lua:243-250`, `:298-301`, `:318-329` (pcall requires), `:235-239`, `:347-370` (`zone_text`, `zone_light_ids`), `:392-394`, `:396-413`, `:461-478`, `:526-553`, `:556-565`, `:995-1006` / `:1038-1048` / `:1088-1098` (`can*`), `:1017-1027` / `:1050-1060` / `:1100-1110` (`*_picker`), `:1067-1073` (`scene_text`), `:1141-1147` (`scene_message`), `:1270-1282`, `:1289-1300`, `:1388-1397`, `:1689-1706`, `:1811-1829` | The "optional while the feature lands in pieces" scaffolding: both modules always load (`tools/build.sh:44-45` stages the whole tree; `bridge.scenes` and `bridge.zone_lights` define every method the driver tests for, see the method lists in `scenes.lua`/`zone_lights.lua`), and `zone_lights:device_ids()` returns a set (`zone_lights.lua:358-365`), so the list/set dual shape at `:361-366` is dead. Plain `require`; drop the `type(x[method]) == "function"` tests and the "Not available in this build" paths; one `can(module, method)` keeping only the `connection()` check; one `picker(module, method, ...)` keeping the `pcall` and the "(error building the list; see Lua output)" entry; direct `state.scenes:recall(params or {})` etc. Keep `if state.X then` nil-guards where a Director callback can run before late init (pickers, `OnBindingChanged`). **Exclude `show_module_list` (`:454-459`)**: no module defines `list_items` yet (grep), so that guard is load-bearing while the list rows land. | ≈120 | Per event: two `type()` tests fewer (`:560`, `:563`). Per command: the `zone_text` indirection fewer (`:1431-1432`, `:1458-1459`). | Medium: many call sites; a slip would raise inside a pcall'd handler (`dispatch.lua:22-33`) and be caught by the specs, but it is the largest edit proposed. The "Not available in this build" texts are documented nowhere (grep of `docs/` and the manual empty) and reachable in no build. | Every action and picker runs through the real modules in `drivers_spec.lua:489-504`, `roundtrip_spec.lua`, `scene_roundtrip_spec.lua`, `zone_light_roundtrip_spec.lua`; messages before late init in `drivers_spec.lua:478-488`. Nothing to add. | none |
| 12 | `driver.lua:298-316`, `:326-345` (`new_scenes`, `new_zone_lights`) | One `module_ctx(extra)` builder for the two identical contexts (`http`, `send`, `bridge_id`, `log`, `now`, `project`, `lights`, the three `group_*` hooks, `persist_get/set`); the zone one adds `groups`. Part of row 11. | ≈10 | none | Medium (with 11). | As row 11. | none |
| 13 | `driver.lua:62-64` (`prop`) | Optional: remember the last text written per property and skip an identical write. The hot path gains nothing (`Events Received`, `Last Event`, `Event Stream` change every event); startup and actions write `Status`/`Bridge ID` twice (`:667` via the replay, `:1838`) and `Attention` "None" on every add/delete container, goodbye and binding change (`:467`). `prop_list` (`:71-75`) must stay outside the cache: a pick in Composer changes the row and the driver must write the summary back (`:974-993`). | 0 (+3) | Fewer `UpdateProperty` calls at start and per action; none per event. | Medium: a hidden coupling if any path relies on re-writing an unchanged value (Director reload keeps the project value and the cache starts empty, so the first write always goes through). | The specs compare final values, so none notices. Add: an identical write is not repeated (count `UpdateProperty` calls). | none |
| 14 | `driver.lua:1448`, `:1471` (`queue:limits(rid, state.lights:limits(rid))`); `commands.lua:237-241`, `:99` | Optional: per command the driver builds a limits table (`lights.lua:534-544`) and the queue copies `DEFAULT_LIMITS` and merges it (`commands.lua:238-239`). A `limits_of(rid)` option read at flush (like `level_of`, `:86-87`, `:330-331`) reads once per PUT and drops the per-rid cache. | ≈5 | Per slider step: two tables fewer. | Medium, and it needs a spec change that is not "the spec was wrong": `commands_spec.lua:170-182` pins the `q:limits(...)` seam. Low priority. | `commands_spec.lua:170-182` rewritten against `limits_of`; clamping itself stays pinned by `:42-58`. | none |

## 3. Do not touch

- `stream.lua:165-188`: the generation check at the top of every transfer callback, and `on_chunk` delivering an abandoned transfer's last events before returning `true` (`:169-181`). It looks like a duplicate of `handle_chunk`; it is the only thing that ends a zombie transfer on OS 3.4.2 (`Cancel()` does not, `docs/design.md` "Event stream", rule 2 in the file header) and the events in that chunk would otherwise be lost (`stream_spec.lua:257-268`).
- `stream.lua:204-214`: the 1 ms `connected_timer` deferral of `on_connected`. A transfer started inside `OnHeaders` fails with curl error 2 (`docs/design.md`, "C4:url transfer scheduling"); `stream_spec.lua:78-122`.
- `stream.lua:111` (`self.transfer:Cancel()`) and `:106-114`: kept although `Cancel()` is unreliable on this OS; it is cheap and is the documented API on others.
- `driver.lua:110-166` (`next_stream_address`, `stream_address_text`, `stream_connection`) and the persisted `hue_stream_spelling` (`:60`, `:120`, `:131`): the spelling rotation reads like over-engineering; it is the measured fix for reconnects queuing behind their own zombie (`docs/design.md`, "Stream address rotation"; `drivers_spec.lua:110-159`).
- `driver.lua:168-180` (`TIMEOUT_MIN/MAX`, `WATCHDOG_MIN`, `SINGLE_QUEUE_TIMEOUT`, `stream_timeout`): code analysis M3/7 hardening; `drivers_spec.lua:206-231`.
- `driver.lua:1753-1784`: the early-command queue (H1 fix); `drivers_spec.lua:478-488`.
- `driver.lua:1211-1231` (`fill_proxy_ids`): looks like a one-time migration, but `lights.lua:1665` is the only other source of `proxy_id` (the AddDevice callback), the fake's AddDevice reports none (`roundtrip_spec.lua:152-153`), an adopted or re-linked entry can lack it, and Adopt Hue Names needs it (`lights.lua:2168-2173`).
- `driver.lua:1698-1705`: the 1 s `reconcile` timer after `OnBindingChanged` (the SDK's `idc_controller` re-enumerates a second later).
- `driver.lua:648-654` (`show_driver_version` retries): the AddDevice first-init blank (`docs/status.md`, "Open"). Only the duplicate handler (row 5) is proposed.
- `driver.lua:71-75` (`prop_list`): the `UpdateProperty` beside `UpdatePropertyList` is the build-184 finding (the list's default alone did not move the row).
- `driver.lua:454-459` (`show_module_list`): the `list_items` guard is load-bearing today (no module defines `list_items`), the coordinator's in-flight list rows.
- `driver.lua:1798-1799` (empty `OnDriverInit`): `drivers_spec.lua:53` calls it.
- `http.lua:117-125` (`start` pcall; a CA file Director cannot open raises at `Get()`), `:157-188` (the pcall'd done handler, H2 fix), `:148-150` (`JsonEncode(body, false, true)`: Director encodes Lua arrays as objects otherwise), `:27-28` (timeouts), the `ssl_verify_peer = true` / `ssl_cabundle` / `ssl_verify_host = false` triple (`:65-67`; `http_spec.lua:14-22`, `drivers_spec.lua:103-104`, `ca_bundle_spec.lua`).
- `commands.lua`: the generation counters and `pcall` around `flush`, `send` and `done` (`:252-266`, `:339-348`, `:414-420`), the `urgent` path (`:107-119`, `:292-307`), `copy()` in `pending()`/`stats()` (`:423-430`; the specs assert copies, `commands_spec.lua:344-346`, `:411-417`). `stats()` loses its last production caller with Lights Report but stays as the spec seam (fifteen assertions); it costs one small table per call and nothing at runtime.
- `stream.lua:62-64` (`stats.events`, `keepalives`, `reconnects`, `address`): surfaced nowhere but pinned by `stream_spec.lua:147`, `:248`, `:290-316`; two additions per chunk.
- `stream.lua:254-255`: the per-event `Event Stream` rewrite is documented text (manual `documentation.html:186`, `:227`; `stream_spec.lua:141`); see open question 1.
- `sse.lua:16`, `:88-92` (`MAX_LINE`, `overflowed`) and `stream.lua:225-230`: the only bound on the parser.
- `log.lua:31-33` and `:40-41`: `pcall(string.format, ...)` so a bad format never kills a handler.
- `dispatch.lua`: nothing to trim; `proxy` / `received_from_proxy` serve the light and scene drivers, `install` wiring them for the bridge too is harmless.
- `driver.lua:62-64` (`prop` → `tostring`): Director wants strings; the fake records whatever it gets, so a spec would not catch a number slipping through.

## 4. Open questions for the coordinator

1. **Per-event property writes.** `Events Received` and `Last Event` (`driver.lua:571-572`) and the `Event Stream` text "Connected since …, N containers, last …" (`stream.lua:254-255`) are three `UpdateProperty` calls per event carrying two facts. Dropping the per-event `Event Stream` rewrite (leaving "Connected since …") would save a third of the per-event Director calls but changes documented text (`documentation.html:186`, `:227`) and `stream_spec.lua:141`. Hue sends at most one container a second, so a 1 s coalescing timer would save nothing; only a text change does. The owner's call; not proposed.
2. **Row 3's event trimming is untestable in the fake** (no `RegisterSystemEvent`). Either accept a hardware check (rename in Composer → Attention follows) or keep the six registrations and take only the log-level change.
3. **Dev commands in dev builds.** The gating at `driver.lua:1786-1793` keeps `Hue_Request`, the probes, `Proxy_Command`, `Lights_Report`, `Connection_Test`, `Reload_Credentials`, `Check_CA_Pinning` in dev builds. Once the dev loop itself goes they have no caller (they were reached through `tools/devctl.py run`), so section 5 assumes outright deletion; say so if dev builds are to keep them.
4. **Test Connection stays** as an owner action (manual `documentation.html:197-198`, `:775`, `:825`); only the `Host` override goes (section 5 E). Confirm, since the brief lists "the `Test Connection` Host override" and not the action.
5. **Spec count.** The brief says `busted tests` green at 1060 specs; the removal deletes `conntest_spec` (5), `pinning_spec` (3), `devloop_spec` (whole file), `drivers_spec` blocks (`:233-267`, `:269-284`, `:298-309`, `:321-331`, `:333-375`, `:377-398`, `:400-446`) and `http_spec.lua:34-73` (the modes that go) — the count necessarily drops; the two "no CA configuration" specs (`http_spec.lua:24-32`, `:183-190`) should stay, setting `http.ca = nil` directly once `set_ca`/`set_ca_bundle` go.
6. **For the other reviewers** (not my files): `lights.dump` (`lights.lua:179-211`), `lights:import` (`:1880-1888`) and `lights:room_mappings_text` (`:2610-2618`) have no caller after section 5 and row 2; `scenes:on_container` builds a `rest` table per container (`scenes.lua:1686-1695`); `zone_lights:on_container` calls `refresh_all` for any `light`, `device`, `grouped_light`, `room` or `zone` item (`zone_lights.lua:1349-1378`, `:1269`), which recomputes every registered zone light per container — the one step in the chain whose cost grows with what is imported (section 6).
7. **`credentials.summary`** (`credentials.lua:46-55`) keeps one production caller, the startup line at `driver.lua:1803`; if that line goes too, `summary` is spec-only (`pairing_spec.lua:104-109`).

## 5. Inventory for the removal (asked by the coordinator)

Every line in these files that exists only for the dev loop (`Dev Server`, `common/devloop.lua`), the
`Diagnostic Server` property, the `Connection Test`, `Check CA Pinning` and `Reload Credentials` actions, and the
`Test Connection` `Host` override. Release builds already strip `common/devloop.lua`, `bridge/conntest.lua`,
`bridge/pinning.lua` and the `DEV-ONLY` blocks of `driver.xml` (`tools/build.sh:46-52`) and unregister the
handlers (`driver.lua:1786-1793`), but the handler bodies below are still shipped, parsed and compiled in
every release build, and `http.lua` still carries the CA modes only those handlers used.

**A. Dev loop** (`Dev Server`, `common/devloop.lua`, and the actions reachable only through `tools/devctl.py`)

- `driver.lua:18-32` the `pcall(require, "common.devloop")` block; `:34-38` the `devloop and require(...)` of `conntest` / `pinning` (B, C).
- `driver.lua:683-698` `dispatch.properties["Dev_Server"]`.
- `driver.lua:786-843` `Hue_Request`; `:845-853` `log_dump`; `:855-862` `probe`; `:864-879` `Probe_Project`; `:881-884` `Probe_Errors`; `:886-931` `Probe_Scenes`; `:933-951` `Probe_Call`.
- `driver.lua:1475-1485` `HUE_LOG`: sent only by dev builds of the device drivers (`hue_light/driver.lua:86-106` and `hue_scene/driver.lua:139-159`, both inside `if devloop then` blocks).
- `driver.lua:1487-1498` `find_light` (only caller `Proxy_Command`); `:1500-1534` `Proxy_Command`; `:1536-1568` `Lights_Report`.
- `driver.lua:1786-1793` the release unregistration loop (moot once the handlers are gone); `:1844-1851` the dev-loop start at late init; the comments `:1-5` need no change.
- `http.lua:199-200` the `Custom` fallback and `:197-198` `Delete`: after `Hue_Request` goes, `src/` issues only GET, POST and PUT (grep: no `DELETE` caller); `:128` comment.
- `commands.lua:428-430` `stats()`: last production caller is `Lights_Report`; keep as the spec seam (section 3).
- Not my files, dead after this: `lights.dump` (`lights.lua:179-211`), `lights:room_mappings_text` (`:2610-2618`), the comment at `lights.lua:473`.
- Specs: `drivers_spec.lua:233-267` (dev loop ×2), `:377-398` (Hue Request), `:400-446` (HUE_LOG, Proxy Command ×2, Lights Report); `devloop_spec.lua` whole (1090). Not mine: the `HUE_LOG` / `DEV_RELOAD` blocks of `light_driver_spec.lua` (~`:900-1032`) and `scene_driver_spec.lua` (~`:1030-1147`).
- Note: these specs pass today only because `src/common/devloop.lua` is on the test path, so `devloop` is non-nil under busted; deleting the module deletes them.
- Outside my scope, for completeness: `tools/devserver.py`, `tools/devctl.py` (`:8`, `:16`, `:288` name Connection Test), `docs/dev-loop.md`, `docs/composer-checklist.md:60-61`, `:207`, manual `documentation.html:161`, `:238`, `:780`.

**B. `Diagnostic Server` + `Connection Test`** (`bridge/conntest.lua`)

- `driver.lua:37` require; `:1630-1666` `Connection_Test` (the only reader of `Properties["Diagnostic Server"]`, `:1635`, and the only use of `ca = { mode = "insecure" }`, `:1641`); the name at `:1790`.
- `conntest.lua` whole (166); `conntest_spec.lua` whole (116).
- `driver.xml:133-147` the DEV-ONLY property block (Diagnostic Server, Dev Server); the `Connection Test` action at `driver.xml:379-393`, inside the DEV-ONLY action block `driver.xml:377-406`.
- `http.lua`: `insecure` mode (`:20`, `:54-55`, `:62-64`), `system` mode (`:18-19`, `:52-53`, `:65`; callers `conntest.lua:85`, `pinning.lua:17`), the `req.ca` override (`:130`, `:140`, `:219`; callers `conntest.lua:72`, `:124`, `pinning.lua:17`, `:23`), the `ca` argument of `http.options` (`:74-75`, `:81`, `:156`, `:232`), `describe_ca` (`:44-58`; caller `pinning.lua:26`, `:30`), `set_ca` / `set_ca_bundle` (`:35-42`; callers `http_spec.lua:25`, `:71`, `:184` only), the never-used `cacerts` mode (`:15-17`, `:51`, `:68-69`; no caller in `src/`), the `verify_host` flag (`:21`, `:65`; caller `pinning.lua:22`), the modes comment `:12-21`. With those gone `ssl_options` is one branch and `http.options(overrides)` has one argument: ≈40 lines.
- Specs: `drivers_spec.lua:333-361`, `:363-375`; `http_spec.lua:34-47`, `:49-56`, `:58-64`, `:66-73` (the two "no CA configuration" specs `:24-32`, `:183-190` stay, with `http.ca = nil`).
- Manual: `documentation.html:237`, `:686`, `:692` (mentions Connection Test), `:777`, `:828`.

**C. `Check CA Pinning`** (`bridge/pinning.lua`)

- `driver.lua:38` require; `:1618-1628` `Check_CA_Pinning`; the name at `:1790`.
- `pinning.lua` whole (36); `pinning_spec.lua` whole (48); `driver.xml:400-405` action (DEV-ONLY block).
- `http.lua` items shared with B (`describe_ca`, `system`, `verify_host`, `req.ca`).
- Specs: `drivers_spec.lua:321-331`. Manual: `documentation.html:685`, `:779`, `:830`.

**D. `Reload Credentials`**

- `driver.lua:1601-1616` `Reload_Credentials`; the name at `:1790`; `driver.xml:394-399` action (DEV-ONLY block).
- `credentials.summary` (`credentials.lua:46-55`) stays (startup line `driver.lua:1803`; open question 7).
- Specs: `drivers_spec.lua:269-284`. Manual: `documentation.html:684`, `:778`, `:829`.

**E. `Test Connection` `Host` override**

- `driver.lua:745-748` the comment; `:755-758` the `if devloop and params and params.Host ...` block; `local host = state.ip` (`:754`) can become `state.ip` at `:759`, `:761`, `:763`, `:781` (the Status texts keep "via <address>").
- Specs: `drivers_spec.lua:298-309`. Docs: `docs/dev-loop.md:300`.

**F. Also diagnostic-only, not in the owner's list:** `driver.lua:731-736` (row 7) and `altaddr.for_stream` (row 9).

## 6. Per-container cost of the stream path (asked by the coordinator)

Counted from the code; this review ran nothing on the controller, so these are call and allocation counts, not
timings. One bridge event = one SSE message (`id:` line, `data:` line, blank line) whose `data` is a JSON array,
normally one container.

1. `http.lua:239-243` `OnBodyChunk` → `handlers.on_chunk(chunk)` → `stream.lua:169-183`: generation check, then `handle_chunk` (`:218-231`).
2. `stream.lua:219` `arm_watchdog()`: **`Cancel()` + `SetTimer()` + one closure per chunk** (`:85-101`). Row 10 removes both Director calls.
3. `stream.lua:221` → `sse:feed` (`sse.lua:73-94`): one concat of buffer + chunk (`:75`), then per line one `find`, one `sub` for the line and **one `sub` copying the rest of the buffer** (`:81-82`), a `match` per field line (`:57`), one `data` table and one event table per event (`:40-45`). Row 4 cuts the per-line copies to one per chunk. Comments add to `stats.keepalives` (`:224`).
4. `stream.lua:233-256` `handle_event`: `os.date` (`:235`, `:68-70`), **`C4:JsonDecode` of the payload** (`:236` → `http.lua:110`; unavoidable), the debug `types` table only under `log.enabled("debug")` (`:243-249`), then per container `opts.on_container` (`:251`) and after the loop **`string.format` + `UpdateProperty("Event Stream")`** (`:254-255` → `driver.lua:512`, `:62-64`).
5. `driver.lua:556-573` `on_container`: `lights:on_container` (`lights.lua:1567-1593`: a `pairs`-free `ipairs` over the items; `hue_model.update` per light item; `HUE_STATE` via `ctx.send` → **`params_text` + `tostring` per message, thrown away in production** (`driver.lua:221-226`), row 1; `flush()` saves the registry only when dirty, `lights.lua:466-471`), `scenes:on_container` (`scenes.lua:1680-1717`: one `rest` table per container), `zone_lights:on_container` (`zone_lights.lua:1349-1378`: `refresh_all` on any light/device/grouped_light/room/zone item, i.e. **every registered zone light is recomputed per container**, `:1269`) — the last two are the other reviewers' files, open question 6. Each `HUE_STATE` is one **`SendToDevice`** (`driver.lua:225`, `:295`).
6. `driver.lua:568-570`: for `add`/`delete` containers only, `refresh_lights_props()` rebuilds the four list rows (now deduplicated by `show_list`, `:436-442`) and `Attention` (`:467`, written even when unchanged): several registry walks and up to five Director calls; rare.
7. `driver.lua:571-572`: **`UpdateProperty("Events Received")` and `UpdateProperty("Last Event")`**, `tostring` each (`:62-64`).

Director calls per event today: `JsonDecode` 1 + timer `Cancel` 1 + `SetTimer` 1 + `UpdateProperty` 3 + `SendToDevice` × devices told. After rows 10 and 1: `JsonDecode` 1 + `UpdateProperty` 3 + `SendToDevice` × devices told, and no debug-string allocation per message. The three property writes are contract-bound (open question 1). Allocation per event today, from this area alone: ≈ (lines + 1) buffer copies, 2 tables and ≈ 4 strings in `sse`, 1 decoded JSON tree, 1 `os.date` string, 1 status string, 1 timer closure, 2 `tostring` strings for the properties, plus per message 1 table + 1 sorted string in `params_text`.
