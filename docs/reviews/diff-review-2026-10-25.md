# Diff and efficiency review, 2026-10-25 (`main..refactor/lifecycle-keypad-56-57`)

Read-only review of branch `refactor/lifecycle-keypad-56-57` at `f96c595`:
PR #214's hardening (`584ec34`..`a29d1c5`, contract
`docs/review-leftovers-design.md`) plus PR #216's refactors (`9a89d41`
contract, `47f83eb` one keypad machine, `a7eadf9` one lifecycle base, then
the keypad settings `5ed3db3` (reverted, reapplied as `16648f8`), `92c5dd2`,
`e3de688`, and `f96c595` the colour probe).
The base is `origin/main` at `52d7039`: the local `main` is one merge behind
it (#215, dev loop only, nothing in a release package). Rules checked against:
`docs/lifecycle-refactor-design.md` (no owner-visible change, message order
identical, divergences kept per module) and the previous reviews
(`diff-review-2026-10-24.md`, `efficiency-2026-10-24.md`).

Method. `bridge/owner.lua` read in full against the pre-refactor copies in
`lights.lua`, `scenes.lua` and `zone_lights.lua` at `a29d1c5`, function by
function; `common/device.lua` and both device drivers against their
`a29d1c5` machines; `commands.lua`, `stream.lua`, `driver.lua`, `project.lua`,
`registry.lua`, `hue_model.lua`, `tlscheck.lua`, `http.lua` hunk by hunk
against `origin/main`. Then three throwaway differential harnesses, kept
outside the repository (same seed, two trees, every observable call
transcribed: messages, log lines at debug, persisted values, requests,
AddDevice calls, action texts, attention, pickers and list rows):

- **bridge modules**, `a29d1c5` vs the branch: lights, scenes and zone lights
  wired as `driver.lua` wires them, an import of lights, scenes and two zone
  lights, then random hellos, goodbyes, binding changes, project changes
  (devices added and removed, the bound lookup answering nil, a failing
  lookup), events from the fixtures and synthesized ones, bridge mutations
  (renames, deletes, re-adds, zone membership, lost `id_v1` / device names),
  every owner action, AddDevice and GET answers (some failing, some
  malformed), timers and restarts. 60 seeds × 600 steps without the mutations
  the intended changes react to, 60 × 600 with them, and 60 × 600 plus
  120 × 1000 with the intended changes switched off in a copy;
- **persistence**: 30 stores written by `origin/main`'s own modules after 400
  random steps each, loaded once by `origin/main` and once by the branch,
  startup plus resync compared;
- **device drivers** through `tests/helpers/fake_c4.lua`: keypad taps, holds,
  Button Link pushes, proxy commands, keypad settings, bridge messages and a
  virtual clock firing timers due at the same moment together, 60 seeds × 500
  steps per driver for `a29d1c5` vs `47f83eb` and 30 for `47f83eb` vs the
  branch.

`luacheck src tests tools`: 0 warnings / 0 errors in 64 files; `busted tests`:
1357 successes, 0 failures (at `e3de688` and again at `f96c595`). Release
packages built with `tools/build.sh` in clones of both commits. Nothing was
run against the controller or the bridge; line numbers are the branch's at
`f96c595`.

## 1. Findings, ranked

No must-fix. The lifecycle base and the keypad machine are behaviour-
preserving wherever the harnesses reach: every difference they found is one
of the contract's four intended changes, the deliberate keypad-settings
commits, or timer creation order. The rows are one gap in the new transfer
guard, one residual startup risk worth a hardware look, a contract that no
longer lists what the branch changes, and small items.

| # | Severity | File:line | What changed | Why it is a regression or a risk | How to prove it (spec to add) | Fix |
|---|---|---|---|---|---|---|
| 1 | should-fix | `src/hue_bridge/bridge/stream.lua:207-215` (the guard), `:226-238` (`drop_transfer`), `:250-257` (`stop`), `:263-271` (`connect`); `src/hue_bridge/driver.lua:628-638` (`restart_stream`), `:1515-1528` (Connect / Disconnect Event Stream), `:837-870` (Bridge IP Address), `:874-880` (stream properties), `:917` (Pair Bridge) | `stream.MAX_ABANDONED = 1` keeps the **watchdog** from opening a transfer while an abandoned one may be open (#46, `003dd90`). | The other ways in do not ask. Every owner-initiated stop and start (Disconnect then Connect Event Stream, an edit of Stream Timeout or Stream Watchdog, a Bridge IP Address change, a successful Pair Bridge) records the live transfer as abandoned and opens a new one at once. In a quiet house (no keepalive, Stream Timeout 3600) each abandoned transfer stays open until the next bridge event or its own timeout, so three such clicks within an hour reach Director's four-transfer limit: the stall of `docs/design.md` "Concurrent transfers", every command timing out until a Hue event (at worst the hourly `geolocation` update, or the Stream Timeout). A throwaway probe on `fake_c4` (stop, rebuild, start, headers 200, with the shared `abandoned` list): 2, 3, 4, 5 stream transfers open after 1, 2, 3, 4 restarts, `open_abandoned()` 1, 2, 3, 4. The list itself stays bounded (row "stream" in section 2); the guard's coverage is the gap. | `stream_spec`: three `stop()` / `stream.new` / `start()` cycles sharing one `abandoned` list, headers answered, a quiet bridge: assert the third `start()` opens no transfer while two may be open, and that an abandoned transfer's callback (or its expiry) lets the next attempt connect. | Apply the guard in `connect()` for every caller with one more slot than the watchdog's: when `open_abandoned() >= stream.MAX_ABANDONED + 1`, open nothing, state `waiting`, status `Waiting: 2 earlier stream transfers may still be open (Director runs at most four at once)`, retry on the existing timer. That caps stream transfers at two on every path, the design's own number, and trades a stale feed (resynced at the connect) for working commands, as the watchdog already does. At least: a warning line at connect naming the count, and a sentence in the manual's Disconnect / Connect and stream property rows. |
| 2 | should-fix (verify on hardware first) | `src/hue_bridge/driver.lua:1554-1568` (`confirm_unbound_later`), `:1728`, `:1599`; `src/hue_bridge/bridge/project.lua:94-120` (`bound_set`) | A nil from `GetBoundConsumerDevices` is unknown, a second nil ≥ 5 s later is "nothing bound", and late init schedules that second look itself (6 s). | After a Director restart the device side has been seen not to see its bridge binding at late init, with no `OnBindingChanged` afterwards (`docs/keypad-design.md`, the reason for the device re-check at 5/15/30/60 s). If the bridge side answers nil for its non-empty binding 1 for six seconds the same way, the 6 s reconcile marks every registered light, scene and zone light **unbound**: warnings, Attention `N unbound devices … (bind it to this bridge in Composer, or Forget Light)` (an invitation to a destructive manual fix), and unbound entries are skipped by the resync fan-out and by every event path (`lights.lua:905`, `:1014`, `scenes.lua:1278`, `:1360`, `:1431`, `zone_lights.lua:851`), so tiles go stale. Recovery needs a reconcile that sees the table: the first resync, seconds after late init, if the binding is visible by then; otherwise the next resync (up to Stream Timeout) or a binding change. Release 1.0 was exposed to a single nil, so this is a residual risk, not a regression; nothing on the house says it happens. | None in the fake (it answers tables). Hardware: after the next reboot from System Manager, the bridge's Lua output right after late init has no `is not bound to this bridge` line and Attention lists no unbound device. | If the line appears: after a reconcile that unbound at least one entry on a confirmed "nothing bound", reconcile once more at 30 s and 60 s (the device side's pattern), or accept the confirming nil only after the first successful resync. Cheap either way; no change while the hardware check is clean. |
| 3 | should-fix (docs) | `docs/lifecycle-refactor-design.md:51`; `docs/keypad-design.md:38-52`; commits `5ed3db3`, `92c5dd2`, `e3de688`, `f96c595` | The branch carries owner-visible changes beyond the contract's four: the keypad settings are answered with their notification at late init and after every `SET_*` (bare value), out-of-range values are refused (preset 1–100, rates 0–86 400 000 ms, also when persisted), and the light's one-time `first SET_COLOR_TARGET params` line is gone. | The contract still says "These four are the only intended behaviour changes in this PR", and the keypad contract still describes the settings as handlers only, `[assumed until changed once on the house]`, with nothing about the answer, its bare form (Composer rounds 41 and 42) or the ranges; only `docs/design.md`'s hardware section mentions it. A reviewer of #216 reading the contract would take these for refactor drift. The changes themselves are sound (section 2, keypad). | None. | One paragraph in the contract ("also on this branch, found on the house: …") and three bullets in `docs/keypad-design.md` (the answer, its bare value, the ranges and what a refused value does). |
| 4 | nit | `src/common/device.lua:515-526` (`dev.load_settings`) | An out-of-range persisted setting reads as the default and is reported to the proxy. | The bad value stays persisted, so the same warning (`preset_level 0 is out of range; using 100`) is logged at every late init of that device, for ever: Composer now shows the default, so the dealer has no reason to edit the field and overwrite it. The house device the commit names will keep warning. | `device_spec`: a persisted `preset_level` 0, two late inits: one warning, and the store holds 100 (or nothing) after the first. | `C4:PersistSetValue(key, default)` (or delete the key) when refusing at load. |
| 5 | nit | `src/common/device.lua:557-562` (comment), `:592-601`, `:614-619`; `src/hue_scene/driver.lua:32` (`LEVEL_FALLBACK_MS = 1000`) | The scene's click guard is now armed before its hold's stop; it used to be armed after it. | The comment says the order "is not observable". The guard (1000 ms) and the scene's level-report window (1000 ms) are armed in the opposite order, so when both fall due together the guard expires first. Observable only if a keypad click lands between two timers due in the same millisecond (the device harness shows a difference only when it interleaves an event between them); harmless. | None. | Say "observable only between two timers due at the same moment"; no code change. |
| 6 | nit | `src/hue_bridge/driver.lua:151-156` (`connection`), `:211-221` (`stream_connection`), `:1515-1524` (Connect Event Stream) | The TLS gate and the key-rejected latch guard `bridge_request`; `restart_stream` checks the latch. | The stream's own `connection()` checks neither `identity_ok`, `tls_verdict` nor `key_rejected`. Today every path that starts a stream first passes `choose_stream_address` (identity, TLS gate), and `stream_ip` is cleared wherever identity is reset, so nothing unverified goes out; the one visible effect is that Connect Event Stream while the key is rejected sends the rejected key once more (the stream stops itself again). Defence in depth for the next path someone adds. | `drivers_spec`: key rejected, Connect Event Stream: no transfer, or the status says why. | `stream_connection()` returns nil (with a status) unless `state.identity_ok == true` and `not state.key_rejected`; or check the latch in the Connect action as `restart_stream` does. |
| 7 | nit | `src/hue_bridge/bridge/owner.lua:1079` | `refresh_fields` walks `clears or {}`. | One empty table per call without `clears` (the lights' refresh after an `add` item). Negligible. | None. | `if clears then … end`. |
| 8 | nit (efficiency) | `src/hue_bridge/driver.lua:1434-1444` (`set_light_limits`), `bridge/lights.lua:362-372`; `driver.lua:376-385` (`group_set`), `bridge/zone_lights.lua:1030-1043` | R4 (#50) and #58. | Per light slider tick 1 table is left (`lights:limits` builds a fresh table only to be compared) where `main` built two; per zone-light tick `zone_lights:limits` scans the zone registry and builds a table, and the scene slider's `group_set` (level unknown) scans it for nothing. Plus one `C4:GetTime` per `commands:set` (#43's `updated_at`). All small at the house's scale (no light imported, 2 zone lights). | None. | Optional: compare the model's three numbers before building; skip the zone scan when no zone light is registered. Not worth a release on its own. |
| 9 | nit | `src/hue_bridge/bridge/stream.lua:402-407` | An oversized line drops the transfer and schedules a reconnect. | `OnBodyChunk` returns nothing there, so the transfer stays open (now counted as abandoned) until its next chunk aborts it; returning true would end it at once. Pathological input only. | `stream_spec` "oversized line": the chunk callback returns true. | Return `true` from the chunk handler after `drop_transfer()`. |
| 10 | nit (docs) | `docs/zone-light-design.md:35` | `lights:add_light → create_lights`. | `create_lights` is gone (`owner:create`, `owner:register_added`). The review pages that name it are historical. | None. | "→ `owner:create`". |

## 2. Checked and fine

The lifecycle base (`bridge/owner.lua`, #56).

- **Hooks.** Every hook the base calls without a default (`entry_label`,
  `creation_name`, `configure_params`, `send_state`, `state_known`,
  `announce_gone`, `record_of`, `fields_of`, `hello_fields`, `fetched`,
  `adopted_label`, `announcement`, `conflict_label`, `device_text`,
  `room_group_of`, `add_label`, `fetch_all`, `absorb`, `settle`,
  `relink_refusal`, `record_label`, `linked_label`, `link_candidates`,
  `unimported_named`) is defined by all three modules; `entry_caps` is
  optional and guarded (`if self.entry_caps`, absent for scenes). Words a
  module lacks are read only where guarded or unreachable: `link_hint`
  (`or ""`), the zone lights' `no_relink` / `no_forget` (the empty arrays the
  driver joins), `requester` (zone lights answer through
  `forget_request_mine_only`), `created_noun` (zone lights never call
  `create`); and `common.log` formats under `pcall` anyway.
- **Options** match each module's pre-refactor behaviour, one by one:
  `push_needs_state` and `gone_at_hello` lights only; `hello_tells_unknown`
  lights and zone lights; `announced_follows_entry` lights and zone lights
  (R5), not scenes; `goodbye_keeps_strangers`, `forget_request_mine_only`,
  `settle_without_fetch` zone lights only; `log_unregistered_bind` lights only;
  `gone_after_add` lights, and zone lights as intended; scenes none. Busy flags
  `importing` / `adding` first, `EARLY_HELLOS_MAX` 200 / nil / 200.
- **Mixin.** No constructor field or `self.<name> =` assignment in the four
  files collides with any of the base's 70 methods; every `self:` call in
  `owner.lua` resolves to a function on each instance (checked by building
  the three modules). Hooks defined with `.` take `_self`. `self.hello` passed
  as a value in `configure_all` resolves to the zone lights' wrapper, and the
  queued `{ rid, params }` replays through it exactly as the old params-only
  queue did. A module's own `hello`, `answer_hello`, `tell`, `foreign`,
  `attention`, `expected_name`, `room_mapping` override the base as designed;
  members `driver.lua` and `devtools.lua` reach (`save`, `entry`,
  `attention_items`, …) all resolve. Removed names (`create_lights`,
  `create_scenes`, `created_rids`, `save_forgotten`) have no caller in `src`,
  `tests` or `tools`.
- **Differential.** Without the mutations the intended changes react to:
  every difference over 60 × 600 steps is the zone lights answering each
  waiting resync caller (intended change 1) and the `pairs()` order of the
  `loaded …` debug lines. With them: every difference over 60 × 600 steps
  disappears when the intended changes are switched off in a copy
  (`REFRESH_CLEARS = {}` in the three modules, zone `gone_after_add` false);
  that copy against `a29d1c5` shows nothing over 60 × 600 and a further
  120 × 1000 steps. Same messages in the same order, same texts, same log
  lines at every level, same persisted values, same views.
- **The four intended changes.** (1) The zone lights' waiting resyncs: one
  more run answers each caller once, in order, each `pcall`ed. (2) A zone
  deleted while its AddDevice was pending: `added()` sees the group cache
  (replaced only by a full lights GET) lack it and marks it gone with the
  lights' R6 text; the add's result text stays "Added …", as the lights' does.
  (3) The zone schema covers every field `origin/main` and the branch write
  (`name`, `group_type`, `light_count`, `no_lights`, `caps`, `id_v1`,
  `name_dismissed` plus the registry's own), and every field the zone code
  reads. (4) Clearing a field that became nil: the lights clear their six
  fields only after a full GET (`absorb` is called from the resync and the
  import only, both with all six GETs); the scenes and zone lights clear
  `id_v1` at every refresh, but their records can only gain it
  (`update_scene` never touches it, `update_group` sets it only when the item
  carries it, an `add` item is whole), so an event that omits a field cannot
  clear it. What remains is a record that truly lost the field (a time-based
  scene re-linked from an ordinary one, a bridge dropping a v1 id); a light
  that loses its `id_v1` then reads `#9a8b7c6d` instead of `#4` in labels,
  which is what the bridge says.
- **Persistence.** Each of 30 stores written by `origin/main`'s modules loads
  into the branch with a startup and resync transcript identical to
  `origin/main`'s own: release 1.0 data needs no migration, and nothing it
  wrote is dropped by a schema.

The keypad machine (`common/device.lua`, #57) and its follow-ups.

- `47f83eb` against `a29d1c5`, both drivers, 60 × 500 steps each: identical
  proxy notifications, bridge messages, properties, persisted values and log
  lines once timers due at the same moment fire together; only the creation
  order of `SetTimer` calls differs (the scene's guard, row 5). The on state a
  hold starts from (`dev.is_on() == true`) equals the scene's old
  `effective_on()`; `on_end_hold` cancels a time-based scene's follow exactly
  where the old `end_hold` did; `dim_after_on` keeps the 600 ms and the
  bridge-and-rid condition.
- **Timers.** No timer is active after `OnDriverDestroyed` in any run, before
  or after; `arm_guard` replaces the previous guard, a new press cancels the
  hold's timer, `dim_after_on` assigns `h.timer` only after the hold timer
  cleared it, `cancel_timers` covers the press, the guard, Driver Version and
  the re-check.
- **Settings** (`47f83eb` → branch): the only differences are additions (five
  notifications for a light, two for a scene, at late init and after each
  `SET_*`) and refusals of out-of-range values, which also stop what `main`
  let through (a preset of 0 turning the top button into Off, a preset of 150
  or a negative rate reaching `HUE_SET` / `HUE_DIM`). `SendToProxy(binding,
  command, strParam)` is a documented form (API 25_proxy/_6-SendToProxy), and
  binding 5001 is ≥ 1000, so it goes as a NOTIFY. Persisting happens before
  the answer; a refused value answers the value kept. `f96c595` removes the
  colour probe deliberately (checklist D.10, #41).

The hardening (#214).

- **`commands.lua`.** "not paired" and "key rejected" end the pending state at
  once with one warning per rid and condition; `bridge_request`'s synchronous
  answers are safe (`inflight` is set before `send`); the 30 s cap counts from
  the last `set()` and covers the group queue; "bridge identity not verified
  yet" stays retriable and capped; the 4xx dim-stop fallback is unchanged.
- **`stream.lua`.** The abandoned list cannot grow without bound and no entry
  counts for ever: an entry leaves at its transfer's next callback (headers,
  chunk or done), or stops counting once that transfer's own Stream Timeout
  has passed and is removed at the next watchdog fire on a silent period;
  growth comes only from restarts (row 1) and dev reloads (documented). A
  key rejection clears `self.transfer` before `stop()`, so no phantom entry.
  An abandoned
  transfer's last chunk is delivered at most once and only while the current
  transfer is not connected; the per-event status is written only while
  connected; the watchdog armed at connect is cancelled by a start that fails
  at once.
- **`driver.lua`.** The TLS gate runs per start and address and answers stale
  generations by silence; `verify_identity`, `choose_stream_address` and every
  pairing callback check `address_gen`; the key-rejected latch clears on Pair
  Bridge, an address change and a driver restart; the limits cache is keyed
  by rid (unique across resource types; the queues are created once); the
  Driver Version, binding-reconcile and nil-confirmation timers are tracked
  and cancelled in `OnDriverDestroyed`; a burst of binding changes runs one
  reconcile.
- **`project.lua`.** `bound_nil_since` lives on the calls table the three
  modules share, so one module's nil starts the clock another's confirms; any
  table answered resets it; `registry:reconcile` changes nothing on a bound
  set that is not a table, and still tombstones only against a non-empty
  device list.

## 3. Efficiency

| What | `origin/main` | #214 (`a29d1c5`) | branch | Note |
| --- | --- | --- | --- | --- |
| Bytes allocated per container, light brightness | 5,252 | 5,252 | 5,252 | GC stopped, after the harness's import (3 lights, 2 scenes, 2 zone lights) |
| … zone level (grouped_light) | 5,796 | 5,412 | 5,412 | R8 (#51) |
| … scene recalled (4 items) | 9,763 | 8,446 | 8,446 | R3, R8 |
| … light off + room | 9,502 | 9,502 | 9,502 | |
| … zone children | 7,641 | 7,641 | 7,641 | the refresh with its clears costs what the old refresh did |
| CPU, 4,000 containers (Lua 5.1 on the VM) | — | 0.349–0.352 s | 0.348–0.353 s | the base's two-level `__index` is not measurable |
| Limits work per light slider tick | 2 tables (`lights:limits` + `commands:limits`) | 1 table, the queue call only on change; + 1 clock read in `commands:set` | same | row 8 |
| Limits work per zone-light slider tick | none | 1 table + a zone-registry scan; + 1 clock read | same | row 8 (#58) |
| `hue_bridge.c4z` | 594,124 B | 615,874 B | 618,205 B (+4.1 %) | 54 files: `owner.lua`, `tlscheck.lua`, `certs/decoy_ca.pem` |
| … Lua source / code lines | 463 KB / 10,122 | 521 KB / 10,871 | 506 KB / 9,725 (−3.9 %) | the refactor takes 1,146 code lines out of #214 |
| `hue_light.c4z` | 38,453 B | 40,644 B | 42,513 B (+10.6 %) | code lines 1,265 → 1,346 → 1,389 |
| `hue_scene.c4z` | 38,954 B | 41,057 B | 43,031 B (+10.5 %) | code lines 1,367 → 1,461 → 1,520 |

The device packages grow because each still carries one copy of the machine,
now in `device.lua` (512 code lines, was 302 on `main`), with the hooks, the
settings answers and ranges, and #49's binding replay; per device Lua state
that is a few KB of bytecode. The bridge's lifecycle code is 6,624 → 5,478
code lines (lights 2,265 → 1,427, scenes 2,539 → 1,821, zone lights
1,820 → 1,139, base 1,091).

Nothing quadratic is new. What there is was there before, once per module:
`registry:by_device` is a scan, called per bound id in `link_candidates`
(bound × entries per Link Devices click) and per hello beside the
`announced` scan (n × n over a startup burst of hellos); at the house's scale
(four bound devices) and even with every light and scene imported (≈190 ×
190) it is milliseconds, on clicks and at startup, never per container. New
timers: none while idle beyond the watchdog (now armed at connect); one
6 s nil-confirmation timer at most; `open_abandoned` allocates one small
table per watchdog fire.

## 4. What this review could not verify

- Anything on the controller: that a stopped or Cancel()ed stream transfer
  stays open after an owner restart as after a watchdog one (row 1 relies on
  the night pass), how `GetBoundConsumerDevices` answers at the bridge's late
  init after a Director restart (row 2), and that the proxy never echoes a
  settings notification back as a `SET_*` (it would loop through
  `save_setting`; the house rounds 41 and 42 saw none).
- The harnesses drive the modules' public functions with the fixture bridge;
  the bridge driver's own wiring is unchanged by the refactor and is covered
  by the specs only.

## Five lines

- Must-fix 0; should-fix 3 (one code: row 1; one hardware check with a cheap fallback: row 2; one docs: row 3); nits 7.
- Most important: the new transfer guard covers the watchdog only, so three owner restarts of the stream within a quiet hour can still reach Director's four-transfer limit and stall every command until a Hue event; apply the guard in `connect()` with one more slot.
- The refactor keeps behaviour: hundreds of differential runs show only the four intended changes, release 1.0 stores load unchanged, and the keypad machine matches both old machines message for message.
- Efficiency: allocations per container identical to #214 (and lower than `main` for scene and zone items), bridge code −3.9 % against `main`, device packages +10 %.
- Would merge: yes, after row 3's paragraph; rows 1 and 2 can follow in the next PR if the owner prefers.
