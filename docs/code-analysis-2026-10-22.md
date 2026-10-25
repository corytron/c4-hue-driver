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

**Status (2026-10-25):** items 8, 9 and 10 were completed on `release-prep`
before release 1.0 (commit 8e23172 and the slimming, checked in
`docs/reviews/security-2026-10-24.md`), and every item still open is fixed on
branch `fix/review-leftovers-43-65` (issues #43–#49, contract
`docs/review-leftovers-design.md`), each marked below with its issue. What is
left: the hardware check of item 14 (what `GetBoundConsumerDevices` returns
for a bridge with no bindings) and item 17's L2, which the security review
found narrowed.

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
   **Fixed 2026-10-25** (#46): the driver records an address generation
   (`state.address_gen`) when `Bridge IP Address` changes, and
   `choose_stream_address` and the pairing callbacks ignore a stale result.
6. Unbounded command retries replay minutes-old slider states when the
   bridge returns (networking M2): cap by age (~30 s), treat "not paired"
   as non-retriable. **Fixed 2026-10-25** (#43): "not paired" and "key
   rejected" are not retried; any other failure is retried for at most 30 s
   from the pending state's last update (`commands.MAX_AGE_S`), then
   dropped with one warning; the grouped_light queue follows the same rules.
7. Stream property bounds (networking M3): clamp timeout to [30, 86400],
   watchdog to [60, timeout). **Fixed 2026-10-22 in part**: the timeout is
   clamped (60 s at most in single-queue mode) and the watchdog floored at
   60 s, but not kept below the timeout (`hue_bridge/driver.lua:143-152`,
   `:333`). The second half is moot (security review 2026-10-24: the
   transfer's own timeout ends the connection first); since 2026-10-25
   (#54) `driver.xml` declares the watchdog's minimum of 60 too.
8. SSE event accumulation unbounded and quadratic per chunk (networking
   M6): byte cap (~4 MB) and index-walk the buffer. **Fixed 2026-10-24**
   on `release-prep`: the walk is linear, and one line and one event's data
   are capped at 1 MB each (`sse.MAX_LINE`, `sse.MAX_EVENT`).
9. Bridge identity never verified on the normal path (networking M5): GET
   `/resource/bridge` on connect and compare `bridge_id`; stop on mismatch.
   **Fixed 2026-10-24** on `release-prep` (security review finding 1): the
   bridge id is read from `/api/0/config`, without the key, after start and
   after an address change, before any keyed request; a different bridge
   gets nothing.
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
    the scene driver's `HUE_DUMP` (removed 2026-10-24), which logged its Properties and state and
    is not gated on the dev loop (`hue_scene/driver.lua:926-936`).
    **Fixed in full 2026-10-24** on `release-prep`: every development
    handler lives in `bridge/devtools.lua`, which only dev builds carry, and
    `HUE_DUMP` is gone (security review, "Earlier hardening").
11. Scene rid not validated before use in a request path; table-typed ids
    grow the catalogue (scenes F6, F7, F13): `^[%w%-]+$`, `text()` on names.
    **Fixed 2026-10-25** (#45): `hue_model.light`, `group`, `scene` and
    `devices` keep an item only when its id is a string matching
    `^[%w%-]+$`, as `smart_scene` and `grouped_light` do (others are dropped
    with one debug line); `util.sanitise` and the driver's `commaless` strip
    control characters.
12. Registry save order lights-before-tombstones can resurrect a deleted
    light after a crash between writes (lights R4): write tombstones first.
    **Fixed 2026-10-22** (`hue_bridge/bridge/registry.lua:260-270`).
13. Post-add reconcile can mislabel the device it just created (lights R2):
    skip entries created in the batch. **Fixed 2026-10-25** (#48): the
    post-add reconcile skips entries created in the same batch (lights,
    scenes and zone lights).
14. `project_bound_set` treats a nil bound list as "nothing bound" (lights
    R3): treat nil as unknown; verify on hardware. **Fixed 2026-10-25**
    (#48): `nil` means unknown, so no reconcile step that unbinds, relabels
    or reports "unbound" runs on it (an empty table still means nothing
    bound); the hardware check of what the API returns for a bridge with no
    bindings comes later.
15. `OnBindingChanged` in the light and scene drivers is not gated on late
    init and `*_CHANGING` is notified before an unguarded send (devices
    races, medium): gate and pcall. **Fixed 2026-10-25** (#49): both
    device drivers act on `OnBindingChanged` only after late init (an
    earlier call is replayed once), through `common/device.lua`; the send
    after a `*_CHANGING` notification is pcall'd, and on failure the driver
    reports the unchanged state (`LIGHT_BRIGHTNESS_CHANGED` with the old
    level, and `LIGHT_COLOR_CHANGED` with the light's colour when one is
    known) and logs the error. The `show_driver_version` retry timers are
    tracked and killed in `OnDriverDestroyed`, in both device drivers and
    the bridge.
16. `off` ignoring `group_off` and `resync_pending` holding one callback
    (scenes F2); Forget Scene undone by a late hello (F8); conflicts never
    pruned (F10); `os.date` on a bad timestamp (F11); unbounded `duration`
    (F12); recalls not coalesced (F9). **Status**: `off` fixed with item 4.
    **Fixed 2026-10-25** (#47): F2 in the scenes module (every pending
    resync callback is kept in a list and called once), F8 (`Forget Scene`
    persists the forgotten device under `hue_scene_forgotten`; its hello is
    answered with `HUE_SCENE_FORGOTTEN` again, never adopted, until Link
    Devices links it), F10 (a conflict is pruned when fewer than two of its
    claimants are still in the project), F12 (the recall `duration` is
    clamped like the dim and level durations), F9 (the first recall of a
    scene goes at once; a recall of the same scene within 300 ms waits and
    the latest wins, so a burst makes two PUTs).
    F11: fixed 2026-10-24 on `release-prep` (security review finding 6):
    `date_of` and `short_date_of` read "?" for a stamp outside this century.
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
    at issue. **Status 2026-10-25**: **fixed** (#46) L1 (an abandoned
    transfer's final chunk is delivered at most once), L3 (the watchdog is
    armed at connect, so a connected stream that receives nothing, headers
    or not, is restarted after the watchdog interval), L5 (dev builds:
    `Check CA Pinning` answers `inconclusive` when its second request fails
    for a reason other than certificate verification) and L6 (pairing
    requires the key to be a non-empty string); **fixed** (#44) L4 (a 401 or
    403 stops the stream, and `Status` and `Event Stream` say the key was
    rejected). Per the security review of 2026-10-24: L2 narrowed, L7 moot,
    L8 fixed (logged at debug only).
18. Lights: `announced` not updated on relink/tombstone (R5), light deleted
    mid-AddDevice still registered (R6), `early_hellos` unbounded (R7),
    stale persisted fields (R9), untyped hello name/model (R11). **Status**:
    R7 is defused by item 1 (hellos before the bridge's late init wait in
    the driver's capped queue and reach `lights:hello` after `load()`;
    `lights.lua:1003` itself is still uncapped). **Fixed 2026-10-25**
    (#48): R5 (`announced` is cleared on relink and tombstone), R6 (a light
    deleted in Hue while its `AddDevice` is pending is tombstoned when the
    device's hello arrives), R9 (persisted fields the current schema no
    longer has are dropped at load), R11 (a hello's `name` and `model` are
    used only when they are strings), and `lights.lua`'s own early-hello
    list is capped at 200, as the driver's is.

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
