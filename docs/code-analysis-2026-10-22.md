# Code analysis, 2026-10-22: security, leaks, races

Four read-only agents analysed the release code in four slices (bridge
networking and credentials; lights and registry; scenes, groups and model;
light and scene drivers plus common). Their reports, with file:line
evidence, triggers and one-line fixes, are in `docs/reviews/analysis-*.md`.
This page is the coordinator's consolidation and priority. Nothing has been
fixed yet; every item below is a proposal for the next session.

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
   drops the rest.
2. **"Busy" guards with no deadline** (lights R1, scenes F1). A lost
   `AddDevice` or HTTP callback leaves `importing` / `resyncing` / `adding`
   set for ever: every action reads Busy and every resync is parked until
   a reload. Fix: route every fetch failure to `done`, pcall the fetch
   call, and expire the flags on a timer (60 s).
3. **An error inside `http.request`'s OnDone kills a light's queue**
   (networking H2): the result is built outside any pcall, so a transport
   result without `code` raises before the callback, and `inflight` stays
   set. Fix: build the result in a pcall and always call back.
4. **Scene recall callback sets ON unconditionally** (scenes F3, F4): ON
   then OFF within the request time flips the tile back ON until the stream
   corrects it; OFF reports off even when nothing was queued (bridge
   offline, rate limit). Fix: per-rid generation counter, `linked` check,
   report `current_active(rid)`; honour `group_off`'s result.

## Priority 2: hardening (release code)

5. Stale `choose_stream_address` / pairing results after an IP change
   (networking M1): capture `state.ip` and a generation, ignore mismatches.
6. Unbounded command retries replay minutes-old slider states when the
   bridge returns (networking M2): cap by age (~30 s), treat "not paired"
   as non-retriable.
7. Stream property bounds (networking M3): clamp timeout to [30, 86400],
   watchdog to [60, timeout).
8. SSE event accumulation unbounded and quadratic per chunk (networking
   M6): byte cap (~4 MB) and index-walk the buffer.
9. Bridge identity never verified on the normal path (networking M5): GET
   `/resource/bridge` on connect and compare `bridge_id`; stop on mismatch.
10. Dev-only handlers (`Hue Request`, `Probe Call`, `Test Connection` with
    Host) registered in release (networking M4): register only when the dev
    loop module is present.
11. Scene rid not validated before use in a request path; table-typed ids
    grow the catalogue (scenes F6, F7, F13): `^[%w%-]+$`, `text()` on names.
12. Registry save order lights-before-tombstones can resurrect a deleted
    light after a crash between writes (lights R4): write tombstones first.
13. Post-add reconcile can mislabel the device it just created (lights R2):
    skip entries created in the batch.
14. `project_bound_set` treats a nil bound list as "nothing bound" (lights
    R3): treat nil as unknown; verify on hardware.
15. `OnBindingChanged` in the light and scene drivers is not gated on late
    init and `*_CHANGING` is notified before an unguarded send (devices
    races, medium): gate and pcall.
16. `off` ignoring `group_off` and `resync_pending` holding one callback
    (scenes F2); Forget Scene undone by a late hello (F8); conflicts never
    pruned (F10); `os.date` on a bad timestamp (F11); unbounded `duration`
    (F12); recalls not coalesced (F9).
17. Stream: abandoned-transfer events delivered twice (L1), destroy does not
    fence late callbacks (L2), stuck-connected not restartable (L3), 401/403
    retried as an outage with Status still Paired (L4), pinning false
    positive (L5), key type unvalidated at pairing (L6), `%s` with nil ip
    (L7), every project event logged (L8).
18. Lights: `announced` not updated on relink/tombstone (R5), light deleted
    mid-AddDevice still registered (R6), `early_hellos` unbounded (R7),
    stale persisted fields (R9), untyped hello name/model (R11).

## Development loop only (not in release builds)

The loop fetches code over plain HTTP without authentication and runs it
with `loadstring`, ships every property to the dev server in clear, and
accepts `DEV_RELOAD` from any device. Acceptable for a LAN dev tool, but
worth: HTTPS or an HMAC on bundles, redacting credentials from the shipped
Properties, and checking the sender of `DEV_RELOAD` (devices analysis).

## Checked and found sound (all four reports)

Secrets encrypted at rest and never logged; no untrusted string used as a
Lua pattern or format string; URLs built from validated addresses; TLS
insecure mode only in the dev Connection Test; stream timers generation-
gated and cancelled; command queue bounded and timer-safe; spelling
rotation persisted; registry invariants prevent double adoption; per-
callback pcall around every project callback; scene catalogue decode linear;
timers in the device drivers cancelled on unbind/forget/destroy; release
build cannot enable the dev loop.
