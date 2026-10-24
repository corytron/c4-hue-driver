# Code analysis, 2026-10-22: security, leaks, races

Four read-only agents analysed the release code in four slices (bridge
networking and credentials; lights and registry; scenes, groups and model;
light and scene drivers plus common). Their reports, with file:line
evidence, triggers and one-line fixes, are in `docs/reviews/analysis-*.md`.
This page is the coordinator's consolidation and priority.

**Fixed the same day (branch `robustness-fixes`)**: items 1, 2, 3 and 4 in
full (hellos queued before late init and replayed after it, other early
commands dropped; Busy flags expire after 90 s; the HTTP done handler builds
its result under pcall; scene recalls carry a per-scene generation so a
later recall or OFF silences the earlier callback, OFF reports the unchanged
state when nothing could be queued), plus 7 (Stream Timeout clamped to
30–86400 s, watchdog to at least 60 s), 10 (the diagnostic handlers exist
only when the dev loop module is present) and 12 (tombstones written before
lights). Specs cover each. The remaining items stay open below.
(Re-checked 2026-10-24: 7 and 10 are fixed only in part; see the items.)

**Status (2026-10-24, each item checked against the code of build 160):**
fixed 1, 2, 3, 4 and 12; partly fixed 7 and 10; item 18's R7 is defused by
item 1; everything else is open, as marked on each item. Paths below are
under `src/`; line numbers are those of the source on 2026-10-24 (build 160
plus comment edits). Added later and not from this analysis: the light and
scene drivers' binding re-check (an unbound device looks again at 5, 15, 30
and 60 s, `hue_light/driver.lua:1026`, `hue_scene/driver.lua:1324`;
`docs/keypad-design.md`, "Hardware findings").

## Verdict

No secret leaks, no injection of untrusted text into patterns, format
strings or URLs beyond one unvalidated identifier, and the development
loop cannot be enabled in a release build. The real problems are
robustness: guards that never expire, callbacks that can arrive before
late init or after an object was replaced, and a scene-recall callback
that reports state unconditionally. Four items are worth fixing before the
driver is relied on daily (priority 1); the rest are hardening.

## Priority 1: fix first

1. **Messages before late init crash the bridge** (networking H1). Light
   and scene drivers send `HUE_HELLO` / `HUE_SET` at boot; if the bridge's
   late init has not run, handlers index nil `state.lights` / `state.stream`.
   Fix: a `late_init_done` guard in command dispatch that queues hellos and
   drops the rest. **Fixed 2026-10-22**: `hue_bridge/driver.lua:1366-1393`
   (hellos queued, at most 200, replayed after late init).
2. **"Busy" guards with no deadline** (lights R1, scenes F1). A lost
   `AddDevice` or HTTP callback leaves `importing` / `resyncing` / `adding`
   set for ever: every action reads Busy and every resync is parked until
   a reload. Fix: route every fetch failure to `done`, pcall the fetch
   call, and expire the flags on a timer (60 s). **Fixed 2026-10-22** by
   expiry: `importing` / `resyncing` / `adding` clear after 90 s, checked
   whenever the next action or resync asks (no timer;
   `hue_bridge/bridge/lights.lua:1504`, `scenes.lua:1666`).
3. **An error inside `http.request`'s OnDone kills a light's queue**
   (networking H2): the result is built outside any pcall, so a transport
   result without `code` raises before the callback, and `inflight` stays
   set. Fix: build the result in a pcall and always call back. **Fixed
   2026-10-22**: `hue_bridge/bridge/http.lua:157-187` (the stream's done
   handler builds nothing that can raise).
4. **Scene recall callback sets ON unconditionally** (scenes F3, F4): ON
   then OFF within the request time flips the tile back ON until the stream
   corrects it; OFF reports off even when nothing was queued (bridge
   offline, rate limit). Fix: per-rid generation counter, `linked` check,
   report `current_active(rid)`; honour `group_off`'s result. **Fixed
   2026-10-22**: `hue_bridge/bridge/scenes.lua:1426-1546` (generation,
   device and `linked` check, the cached status on failure; OFF reports
   the unchanged state when nothing was queued).

## Priority 2: hardening (release code)

5. Stale `choose_stream_address` / pairing results after an IP change
   (networking M1): capture `state.ip` and a generation, ignore mismatches.
   **Open** (`hue_bridge/driver.lua:400`, `:494`).
6. Unbounded command retries replay minutes-old slider states when the
   bridge returns (networking M2): cap by age (~30 s), treat "not paired"
   as non-retriable. **Open**: every failure without an HTTP code is
   retried, "not paired" included (`hue_bridge/bridge/commands.lua:333`,
   `hue_bridge/driver.lua:158`); no age or count cap.
7. Stream property bounds (networking M3): clamp timeout to [30, 86400],
   watchdog to [60, timeout). **Fixed 2026-10-22 in part**: the timeout is
   clamped (60 s at most in single-queue mode) and the watchdog floored at
   60 s, but not kept below the timeout (`hue_bridge/driver.lua:143-152`,
   `:333`).
8. SSE event accumulation unbounded and quadratic per chunk (networking
   M6): byte cap (~4 MB) and index-walk the buffer. **Open**
   (`hue_bridge/bridge/sse.lua:61-63`, `:75-87`).
9. Bridge identity never verified on the normal path (networking M5): GET
   `/resource/bridge` on connect and compare `bridge_id`; stop on mismatch.
   **Open**: only `Test Connection` compares (`hue_bridge/driver.lua:552`).
10. Dev-only handlers (`Hue Request`, `Probe Call`, `Test Connection` with
    Host) registered in release (networking M4): register only when the dev
    loop module is present. **Partly fixed 2026-10-22**: release builds
    drop `Hue Request`, the four `Probe` actions, `Proxy Command` and
    `Lights Report` (`hue_bridge/driver.lua:1397-1402`). Still open in
    release builds: `Test Connection`'s `Host` override
    (`hue_bridge/driver.lua:526-535`); `Connection Test` with Target
    "Diagnostic Server", an unverified TLS connection (`mode = "insecure"`,
    no key) to whatever the `Diagnostic Server` property holds
    (`hue_bridge/driver.lua:1244-1253`; the action is in `driver.xml`); and
    the scene driver's `HUE_DUMP`, which logs its Properties and state and
    is not gated on the dev loop (`hue_scene/driver.lua:926-936`).
11. Scene rid not validated before use in a request path; table-typed ids
    grow the catalogue (scenes F6, F7, F13): `^[%w%-]+$`, `text()` on names.
    **Open** (`hue_bridge/bridge/hue_model.lua:548-551`, `:104-105`;
    `scenes.lua:1406-1420`; `groups.lua:105`).
12. Registry save order lights-before-tombstones can resurrect a deleted
    light after a crash between writes (lights R4): write tombstones first.
    **Fixed 2026-10-22** (`hue_bridge/bridge/registry.lua:260-270`).
13. Post-add reconcile can mislabel the device it just created (lights R2):
    skip entries created in the batch. **Open** (`lights.lua:1667`, `:1778`;
    `scenes.lua:1825`, `:1922`).
14. `project_bound_set` treats a nil bound list as "nothing bound" (lights
    R3): treat nil as unknown; verify on hardware. **Open**
    (`lights.lua:532`, `scenes.lua:396`).
15. `OnBindingChanged` in the light and scene drivers is not gated on late
    init and `*_CHANGING` is notified before an unguarded send (devices
    races, medium): gate and pcall. **Open** (`hue_light/driver.lua:1082`,
    `:400-424`; `hue_scene/driver.lua:1382`, `:583-670`).
16. `off` ignoring `group_off` and `resync_pending` holding one callback
    (scenes F2); Forget Scene undone by a late hello (F8); conflicts never
    pruned (F10); `os.date` on a bad timestamp (F11); unbounded `duration`
    (F12); recalls not coalesced (F9). **Status**: `off` fixed with item 4.
    Open: F2 (`scenes.lua:1258-1262`; `lights.lua:1288` the same), F8
    (`scenes:forget` remembers nothing, `scenes.lua:2099`), F10 (conflicts
    are cleared only for tombstoned rids), F12 for the recall
    (`scenes.lua:1447`; the dim and level durations are clamped), F9 (each
    recall is its own PUT, `scenes.lua:1465`). F11: `date_of` is still
    unguarded (`scenes.lua:218`), but `registry:load` coerces every stamp
    with `tonumber` (`registry.lua:204-206`, `:246`), so no string reaches it.
17. Stream: abandoned-transfer events delivered twice (L1), destroy does not
    fence late callbacks (L2), stuck-connected not restartable (L3), 401/403
    retried as an outage with Status still Paired (L4), pinning false
    positive (L5), key type unvalidated at pairing (L6), `%s` with nil ip
    (L7), every project event logged (L8). **All open** (L1
    `hue_bridge/bridge/stream.lua:169-181`, L2 `driver.lua:1456`, L3
    `stream.lua:118`, `:250`, L4 `stream.lua:191-196`, L5
    `pinning.lua:24-31`, L6 `pairing.lua:57-58`, L7 `driver.lua:406`, L8
    `driver.lua:1352`). L8's registration now also refreshes `Attention`
    when a device is renamed in Composer, so it stays; only the logging is
    at issue.
18. Lights: `announced` not updated on relink/tombstone (R5), light deleted
    mid-AddDevice still registered (R6), `early_hellos` unbounded (R7),
    stale persisted fields (R9), untyped hello name/model (R11). **Status**:
    R7 is defused by item 1 (hellos before the bridge's late init wait in
    the driver's capped queue and reach `lights:hello` after `load()`;
    `lights.lua:1003` itself is still uncapped). Open: R5
    (`lights.lua:1796`), R6 (`lights.lua:1546-1580`), R9
    (`lights.lua:828-850`), R11 (`lights.lua:974-975`).

## Development loop only (not in release builds)

The loop fetches code over plain HTTP without authentication and runs it
with `loadstring`, ships every property to the dev server in clear, and
accepts `DEV_RELOAD` from any device. Acceptable for a LAN dev tool, but
worth: HTTPS or an HMAC on bundles, redacting credentials from the shipped
Properties, and checking the sender of `DEV_RELOAD` (devices analysis).

## Checked and found sound (all four reports)

Secrets encrypted at rest and never logged; no untrusted string used as a
Lua pattern or format string; URLs built from validated addresses; TLS
insecure mode only in the Connection Test's Diagnostic Server target
(which release builds still offer, item 10); stream timers generation-
gated and cancelled; command queue bounded and timer-safe; spelling
rotation persisted; registry invariants prevent double adoption; per-
callback pcall around every project callback; scene catalogue decode linear;
timers in the device drivers cancelled on unbind/forget/destroy; release
build cannot enable the dev loop.
