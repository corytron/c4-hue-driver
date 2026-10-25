# Review leftovers of 2026-10-24 (contract)

Owner, 2026-10-25: "Whatever is still an outstanding issue in github or you
are tracking as still in my bucket to do, figure out how to do yourself and
do it." This contract covers the code and document issues the reviews of
2026-10-22 and 2026-10-24 left open: #43, #44, #45, #46, #47, #48, #49, #50,
#51, #53, #54, #55, #58, #59, #64 and the counter part of #65. Branch
`fix/review-leftovers-43-65`, one PR. Dev-loop security (#52) is its own
branch and PR (`docs/dev-loop.md`); the lifecycle and keypad refactors
(#56, #57) follow this PR on their own branch; the hardware checks (#38–#41,
the hardware halves of #44, #48, #59, #60, #65) run on a dev build once #52
has landed.

Where this text and the code disagree after the merge, fix one of them in a
PR that says which.

## 1. Decisions

| Issue | Decision |
| --- | --- |
| #43 | `err == "not paired"` and `err == "key rejected"` are not retried; any other failure is retried with the existing backoff for at most **30 s from the pending state's last update** (`commands.MAX_AGE_S = 30`), then the pending state is dropped with one `log.warn` line naming its age and the last error. The group queue (grouped_light) follows the same rules. |
| #44 | A 401 or 403 on the event stream stops the stream (no reconnect). The bridge driver sets `Status` to `Key rejected by the bridge (HTTP <code>): re-pair with Pair Bridge` and `Event Stream` to `Stopped: key rejected (HTTP <code>)`, and `bridge_request` answers `{ ok = false, err = "key rejected", code = <code> }` at once for keyed requests until `Pair Bridge` succeeds or `Bridge IP Address` changes. A keyed REST request answered 401/403 sets the same state. **Hardware fact (verified 2026-10-25 on the house Bridge Pro, software 2071524040):** an unknown application key gets **HTTP 403** on `GET /clip/v2/resource/bridge` and on `/eventstream/clip/v2` (an HTML body, not JSON); a revoked key is an unknown key to the bridge [assumed: same code]. |
| #45 | `hue_model.light`, `group`, `scene` and `devices` keep an item only when `item.id` is a string matching `^[%w%-]+$` (as `smart_scene` and `grouped_light` do); others are dropped with one debug line. `util.sanitise` and the driver's `commaless` strip control characters (`%c`). |
| #46 | Item 5: the driver records a generation (`state.address_gen`) when `Bridge IP Address` changes; `choose_stream_address` and the pairing callbacks ignore a result whose generation is stale. L1: an abandoned transfer's final chunk is delivered at most once. L3: a connected stream that receives nothing (no event and no keepalive) for the watchdog interval is restarted even when headers arrived (the watchdog is armed at connect, not only after data). L6: pairing requires `username` to be a non-empty string. L5: `Check CA Pinning` (dev builds) answers `inconclusive` instead of `pinned` when the second request fails for a reason that is not certificate verification (timeout, DNS, connection refused). |
| #47 | F2: the scenes module keeps every pending resync callback (a list) and calls each once. F8: `Forget Scene` remembers the forgotten device id in persisted data; a hello from it is answered with goodbye and never re-adopted. F10: a conflict entry is pruned when fewer than two of its claimants are still in the project. F12: the recall `duration` is clamped like the dim and level durations. F9: recalls of the same scene within 300 ms coalesce into one PUT (the latest parameters win). |
| #48 | 13: the post-add reconcile skips entries created in the same batch (lights, scenes and zone lights). 14: `nil` from `GetBoundConsumerDevices` means **unknown**: no reconcile step that unbinds, relabels or reports "unbound" runs on it (an empty table still means nothing bound); the hardware check of what the API returns for a bridge with no bindings comes later. R5: `announced` is cleared on relink and tombstone. R6: a light deleted in Hue while its `AddDevice` is pending is tombstoned when the device's hello arrives. R9: persisted fields that the current schema no longer has are dropped at load. R11: a hello's `name` and `model` are used only when they are strings. `lights.lua`'s own early-hello list is capped at 200, as the driver's is. |
| #49 | `OnBindingChanged` in both device drivers acts only after late init (an earlier call is replayed once late init has run), through `common/device.lua`. The `*_CHANGING` notification is followed by a `pcall`ed send; on failure the driver reports the unchanged state (`LIGHT_BRIGHTNESS_CHANGED` with the old level; `LIGHT_COLOR_CHANGED` with the light's colour when one is known) and logs the error. A binding change before late init is replayed after it: only the latest call per binding is kept, and a bridge binding to the bridge late init already greeted is dropped as a duplicate hello. The `show_driver_version` retry timers are tracked and killed in `OnDriverDestroyed`. |
| #50 | R2–R6 as written in the issue. |
| #51 | R7 (decided by the coordinator under the owner's 2026-10-25 instruction): `C4:SendToDevice` passes `logCommand = log.enabled("debug")`, so Director logs each message only while `Debug Mode` is On [to verify in the SDK reference before use]. R8: done now. R9: declined (zero allocation today, invalidation risk); recorded in `docs/reviews/efficiency-2026-10-24.md`. R10: done. |
| #53 | A release check that does not depend on the OS: after the identity check succeeds (once per start and per address change) the bridge driver requests `GET /api/0/config` from the bridge with `ssl_cabundle` set to a **decoy bundle** (`certs/decoy_ca.pem`: a self-signed CA made for this purpose, its private key discarded), `ssl_verify_peer` on. That request must fail certificate verification. If it succeeds, the controller is not using the configured bundle (pinning is not in effect): keyed requests stop, `Attention` reads `TLS check failed: the controller accepted the bridge without its Signify roots; keyed requests stopped (see the manual)`, `Status` reads `TLS check failed: nothing is sent (see Attention)`, and the check runs again at the next start. The check runs before the first keyed request of each start and address (the identity check waits for its verdict). A timeout or connection error is `inconclusive`: logged, retried at the next identity check, nothing blocked. Module `bridge/tlscheck.lua`, spec `tests/spec/tlscheck_spec.lua`. On OS 4.x this check reports by itself. |
| #54 | `Stream Watchdog (s)` declares `<minimum>60</minimum>`; the code keeps its floor. |
| #55 | Row 4 and 12: manual. Row 6: `http.options(overrides, tls)` applies `tls` on top of `ssl_options()`, so `ssl_verify_peer` stays true unless `tls` says otherwise explicitly. Row 7: `util.has_field(nil, x)` is false. Row 8: the picker placeholder reads `(not ready yet; open the list again)`. Row 9: the stale comment goes. Row 10: `copy_caps` / `same_caps` move to `bridge/util.lua` (one copy), and `lights.lua` uses `bridge/project.lua`. Row 11: with #52. |
| #58 | The bridge clamps too: `zone_lights:limits(rid)` returns the zone's intersected `{ mirek_min, mirek_max }` (and `min_dim` 1), and the driver gives it to the group queue (`state.group_queue:limits(grouped_light_rid, …)`) before each `group_set`. Decision 7 in `docs/zone-light-design.md` says so. |
| #59 | The light_v2 reference documents switching `hide_proxy_properties` at run time only from OS 4.2.1 (`3_whats_new/_6-WhatsNewin421`; the older capability page says not dynamic), and the house runs OS 3.4.2. Decided: the XML route. Both device drivers declare `<hide_proxy_properties>False</hide_proxy_properties>`; it is a `<capabilities>` change, so the devices show the proxy's settings only after the owner reboots the controller from System Manager once after the install. |
| #64 | RFC 5737 examples (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) replace `192.168.x.x`, `10.10.10.10`, `172.16.0.9`, `1.2.3.4` and `10.10.0.5` under `src`, `tests`, `docs`, `README.md`, `CONTRIBUTING.md`; the `altaddr` specs keep addresses whose octets pad differently; relative paths replace `/home/<user>/…` in the docs. `.gitleaks.toml` keeps its allowlist entries (the history still has them). |
| #65 | The `Event Stream` row adds the reconnect count since the driver started once there is one: `Connected since 23:11:46 (2 reconnects since 10-25 23:11)` at connect, and `Connected since 23:11:46, 120 containers, last 23:40:02; 2 reconnects` on the per-event rewrite (both within 75 characters). The measurements and the catalogue decision come with the hardware pass. |

## 2. Files and owners

Everything else in the checkout is being edited by others at the same
time. No agent runs `git`; the coordinator integrates and commits.

| Owner | Files (create or edit only these) | Issues |
| --- | --- | --- |
| **networking** | `src/hue_bridge/bridge/commands.lua`, `stream.lua`, `pairing.lua`, `http.lua`, `pinning.lua`, new `tlscheck.lua`, new `src/hue_bridge/certs/decoy_ca.pem`; `tests/spec/commands_spec.lua`, `stream_spec.lua`, `pairing_spec.lua`, `http_spec.lua`, `pinning_spec.lua`, new `tlscheck_spec.lua` | #43, #44 (stream), #46 L1 L3 L5 L6, #53, #55 row 6, #65 (stats) |
| **scenes** | `src/hue_bridge/bridge/scenes.lua`; `tests/spec/scenes_spec.lua`, `scene_roundtrip_spec.lua` | #47, #48 item 13 (scenes), #50 R3, #51 R8, #55 row 9 |
| **lights** | `src/hue_bridge/bridge/lights.lua`, `registry.lua`, `zone_lights.lua`, `hue_model.lua`, `util.lua`, `project.lua`, `groups.lua`; `tests/spec/lights_spec.lua`, `registry_spec.lua`, `zone_lights_spec.lua`, `hue_model_spec.lua`, `util_spec.lua`, `project_spec.lua`, `groups_spec.lua`, `roundtrip_spec.lua`, `zone_light_roundtrip_spec.lua` | #45 (ids, sanitise), #48, #50 R6, #55 rows 7 10, #58 (`limits`) |
| **devices** | `src/common/device.lua`, `src/hue_light/driver.lua`, `src/hue_light/light/*.lua`, `src/hue_scene/driver.lua`; `tests/spec/device_spec.lua`, `light_driver_spec.lua`, `light_state_spec.lua`, `light_caps_spec.lua`, `scene_driver_spec.lua`; `tests/helpers/fake_c4.lua` (only additions the device specs need) | #49, #51 R10, #59 |
| **docs** | `src/*/www/*.html` (manual text only, no images), `docs/**` except this file, `docs/status.md` and `docs/cicd-gitops-design.md`, `README.md`, `CONTRIBUTING.md`, `tests/spec/altaddr_spec.lua` | #64, #55 rows 4 12, manual rows for #43 #44 #53 #54 #59 #65, `docs/design.md` hardware fact of #44, `docs/zone-light-design.md` Decision 7 (#58), review pages marked |
| **coordinator** | `src/hue_bridge/driver.lua`, `src/*/driver.xml`, `tests/spec/drivers_spec.lua`, `tools/build.sh`, `CLAUDE.md`, `docs/status.md`, this file | wiring of #44 #46 item 5 #50 R2 R4 R5 #51 R7 #53 #54 #55 row 8 #58 #65; #45 `commaless` |

If a fix needs a line in a file another owner holds, say so in the report
with the exact change; do not edit it.

## 3. Interfaces the coordinator wires

- `commands.new(opts)` keeps its signature; `commands.MAX_AGE_S` (30) is
  exported; a non-retriable error ends the pending state at once.
- `stream.new(opts)`: a new option `on_key_rejected(code)` is called once
  when the stream gets 401 or 403, after the stream has stopped itself.
  `stream.stats.reconnects` and a new `stream.stats.started` (the
  `clock()` text of the first connect) exist in release builds.
- `tlscheck.run(ip, callback)` calls `callback(verdict, detail)` with
  `"pinned"`, `"not_pinned"` or `"inconclusive"`; it uses `bridge.http`
  and the relative path `certs/decoy_ca.pem`, never the key.
- `zone_lights:limits(grouped_light_rid)` returns
  `{ min_dim = 1, mirek_min = n, mirek_max = m }` or `nil` when the zone's
  members are unknown.
- `util.copy_caps`, `util.same_caps` (moved from lights and zone lights).

## 4. Conventions

Lua 5.1 (the controller runs LuaJIT with 5.1 semantics), tabs, the rules in
`.luacheckrc`; busted specs with the fake C4 runtime in
`tests/helpers/fake_c4.lua`; no new `require` of anything outside `src/`;
never vendor Snap One code; DriverWorks API claims checked in
`~/c4-tools/reference/` and named in comments as verified or assumed.
Placeholders only (`10.0.2.143` bridge, `192.0.2.7` VM, `001788fffe123abc`
bridge id). Owner-visible texts exactly as section 1 gives them.

Done for each agent: its issues fixed with specs, `luacheck src tests tools`
clean and `busted tests` green for its specs (other owners' specs may be red
while they work; report which), and a report listing every change, every
spec added, and anything left for the coordinator.
