# Motion: the occupancy hold across a restart (#371)

Status: contract, 2026-11-07, for issue #371. Read-only research, written
before any code, as CLAUDE.md's "Edge cases before automation" asks. It
amends, for restarts only, D10 and the "Hold time" bullets of §2.7 in
[`motion-design.md`](motion-design.md), and the restart sentence of R11 in
[`edge-cases-motion.md`](edge-cases-motion.md) (EC below). Everything else
there stands. [`motion-hue-research.md`](motion-hue-research.md) is HR below.

The decisions are numbered R1 to R12. Code cites them as "#371 R4", so they
are not confused with EC's R rows.

Markers:
- [verified: API …]: the DriverWorks API reference under
  `~/c4-tools/reference/docs-driverworks-api/source/includes/`, paraphrased.
- [code: …]: this repository at the time of writing.
- [assumed]: not confirmed anywhere.

## 1. What happens today

- **Hold start.** A Hue "no motion" while the proxy shows motion starts a
  `C4:SetTimer` of the full Occupancy Hold Time. `CLOSED` goes out when the
  timer ends [code: `take_motion`, `start_hold` in
  `src/hue_motion/driver.lua`].
- **What survives a restart.** Only what the proxy last got is persisted
  (`motion_shown`). The hold is only a timer, and a restart ends it:
  `OnDriverDestroyed` cancels it, and Director drops a driver's timers at
  an update or a restart [code; #376].
- **After the restart.** The first "no motion" finds the proxy open. It
  sends `STATE_OPENED`, which fires no event (EC R4), and starts the hold
  again in full. EC R11 chose this on purpose: "never shortened by
  comparing clocks".
- **Seen on the house** (#371). A MotionAware area's motion ended about
  35 s before a driver update, with a hold of 300 s. The contact closed
  about 36 s late, and the programming ran once, late. Every hold that a
  restart cuts is lengthened by the part already held, at most one hold
  length, once.

## 2. Facts this rests on

| # | Fact | Source |
| --- | --- | --- |
| F1 | `C4:GetTime()` returns milliseconds since the Unix epoch, from OS 3.2.3 (the unit arguments from 4.0). It is the wall clock, so an NTP step moves it. Every bridge module already times with it. | [verified: API 34_timer/_2-GetTime]; NTP steps [assumed]; [code: `bridge/commands.lua`, `stream.lua`] |
| F2 | `C4:SetTimer(ms, fn)` takes a delay above 0 and gives a one-shot timer with `Cancel()`. It is not to be called in `OnDriverInit`. | [verified: API 34_timer/_1-SetTimer] |
| F3 | Persistence: `PersistSetValue` keeps numbers, strings, booleans and tables of them. Writes go through a database thread, queued until just before late init, so a read right after a write can miss it. An empty value does not delete; `PersistDeleteValue` does. Persisted values survive an update in place and a Director restart. | [verified: API 26.5_persistence/_4-PersistSetValue, _2-PersistDeleteValue]; survival [verified: house, EC §0.2; #371 itself, where `motion_shown` was honoured] |
| F4 | `C4:ParseIso8601DateTime(text)` returns a table, the UTC epoch second and the microseconds, from OS 2.7.0; nothing when it fails. The device already uses it for the Hue Motion row. | [verified: API 22_miscellaneous/_27-ParseIso8601DateTime]; [code: `bridge_time`] |
| F5 | Other clocks. `C4:GetTickCount()` counts ms since the OS started, from 2.4.0; its width and wrap are not documented. `C4:GetUptime()` counts seconds since start, from 3.3.1, above our declared minimum of 3.3.0. `C4:GetBootID()` changes at every boot, from 3.3.0. A reboot resets the first two. | [verified: API 9_helper/_10.5-GetTickCount, 35_url/_5.6-GetUptime, 9_helper/_5.7-GETBOOTID]; the wrap [assumed]; minimum [code: `driver.xml`] |
| F6 | `C4:url` passes each response's headers table to `OnHeaders`, and the same table to `OnDone`. But `http.request` builds its result from the code and the body only, so no bridge module sees a REST response's headers. Whether the Hue bridge sends a `Date` header on CLIP v2 responses is not known here. | [verified: API 35_url/_9-OnHeaders, _8-OnDone]; [code: `bridge/http.lua`]; the header [assumed, not seen on either bridge model] |
| F7 | `motion_report.changed` is the time the motion value last changed: ISO 8601, UTC, with milliseconds. Every `HUE_MOTION_STATE` that carries `motion` also carries `motion_changed`, except on firmware without `motion_report` (only the deprecated value), where the bridge sends none. Two things are not known: whether a repeated report of the same value moves `changed`, and whether `changed` survives a bridge reboot. | [verified: HR §1.3]; [code: `motion_model.reading`, `motion.sensor_state`]; the unknowns [assumed; HR §7.1 asks the first] |
| F8 | An area's `motion_changed` is the newest change among its enabled services: the newest of those reporting motion while any does, else the newest of all. The bridge derives it the same way from an event and from a GET. | [code: `motion_model.area_motion`, #288] |
| F9 | The bridge never sends a device a motion older than the last one it sent. Its full state after a restart (a resync, or the answer to a hello) repeats the current motion and change time. | [code: `motion.send_state`, `diff`; EC rule 5] |
| F10 | Each stream container carries `creationtime`, and each SSE id is `<unix>:<n>`; both are bridge time. They arrive only with events, so none is at hand at a restart. | [verified: [`edge-cases-hue.md`](edge-cases-hue.md) "Event stream", HR §3.1] |
| F11 | Bridge messages that arrive before the device's late init wait, and are applied after it in order. `replay_properties` sets the hold time before that. | [code: `common/device.lua` `after_late_init`; `OnDriverLateInit`] |
| F12 | A dev-loop reload calls `OnDriverDestroyed`, then the new code's `OnDriverInit` and `OnDriverLateInit`. | [code: `common/devloop.lua` `reload`] |

## 3. Measuring "how long ago" without trusting two clocks

The resumed hold needs the time since the hold's end of motion. Three ways
were weighed:

| | A: controller clock against Hue's change time | B: a bridge "now" | C: the device's own record of the hold |
| --- | --- | --- | --- |
| Elapsed time | controller now − `motion_changed` | the bridge's `Date` − `motion_changed`, plus the controller time since that GET | controller now − the controller time the hold began |
| Trusts | that both clocks agree | that the bridge clock is steady between the change and the GET | that the controller clock is steady across the restart |
| Covers | every restart | every restart, and ends nobody saw | holds that were running when the driver stopped (the issue's case) |
| Needs | nothing new | the unverified `Date` header (F6), headers in `http.request`'s result, a time anchor per reading in `bridge/motion.lua`, an RFC 1123 date parser, a new §3 field, specs on both sides | one persisted key on the device |
| Worst case | a skew as long as the hold either closes every held sensor at once at every restart, or never shortens anything | a bridge whose clock is set late after its own reboot gives ages that must be clamped [assumed] | the controller clock steps forward during one hold and a restart follows: that hold ends early by the step, once |
| EC rule 5 and R10 | broken | kept | kept |

**Recommendation: C.**
- No clock is compared with another. A bridge time is compared only with
  a bridge time, and only for equality; a controller time only with a
  controller time. EC rule 5 and R10 keep their wording.
- Every failure leaves the hold at least as long as it should be (today's
  behaviour), with one exception: a forward step of the controller clock
  during one hold, followed by a restart, shortens that hold by the step.
- It needs nothing unverified: no header, no new API.
- It touches the motion driver only: no bridge change and no message
  change, so no regression risk on the bridge.
- What it leaves out is rare and already bounded: an end of motion the
  device never saw needs a failure first, and costs at most one hold
  length, once.

B can follow later if the owner wants those ends covered too (§7 item 2).

## 4. Decisions

- **R1. What resumes.** A hold the device was running when it stopped
  resumes after the restart, for the time it has left, as long as Hue still
  reports the same end of motion. Nothing else about the hold changes: D10
  and EC R11 otherwise stand.
- **R2. The clock.** The elapsed time is `now_ms() − since`. Both values
  come from `C4:GetTime()` on this controller (F1), and `since` is
  persisted when the hold begins (R7). A bridge time is compared only with
  a bridge time, for equality (R3), and never with the controller clock.
- **R3. The same end of motion.** The record qualifies when all three
  hold:
  - `record.rid == st.rid`;
  - the reading carries `motion_changed`;
  - that names the same instant as `record.changed`: the same text, or
    both parse with `C4:ParseIso8601DateTime` (F4) to the same epoch
    second, with microseconds no more than 1000 apart.

  Otherwise this end of motion is another one, or an unknown one.
- **R4. What is left.** `left_ms = hold_s × 1000 − elapsed_ms`, where
  `hold_s` is the setting when the reading is applied (R8).
  - `left_ms ≥ 1000`: a timer of `ceil(left_ms)` ms. The proxy keeps
    motion; as the first state after the start that is `STATE_OPENED`, so
    no event fires.
  - `left_ms < 1000`: the hold ran out while the driver was down. Delete
    the record and report no motion. Because the proxy last got motion,
    that first state goes out as `CLOSED`, and "stops sensing motion" fires
    once (EC R4).
- **R5. A clock not to trust means a full hold.** The record does not
  qualify when:
  - `now_ms() < since` (the clock went back, or is not set yet after a
    boot); or
  - either value is before 2025-01-01T00:00:00Z
    (`CLOCK_FLOOR_MS = 1735689600000`; a clock not set yet).

  The hold then starts in full and the record is rewritten with
  `since = now`. There is no upper bound: a long time since the same change
  time means a long time without motion (L8).
- **R6. Otherwise, exactly today's.** In every other case the device does
  what it does today: a full hold from this reading, or no hold. That
  covers no record, a different change time, no change time, a record of
  another rid, and a proxy that shows no motion.
- **R7. The record.** The persisted key `motion_hold` holds
  `{ rid, changed, since }`.
  - **Written** when a hold starts in full: no hold running, Hue says no
    motion, `hold_s > 0` and the proxy shows motion. It takes this reading's
    `motion_changed` and `st.rid`; when either is missing, nothing is
    written and any record held is deleted.
  - **Updated** while the hold runs: a no motion with another change time
    replaces `changed`, and `since` stays. A later restart then still
    matches what the bridge reports.
  - **Left as it is** when a hold resumes: `since` stays, so a second
    restart resumes again (L27).
  - **Deleted** when the hold ends or is cancelled: the timer ends, motion
    arrives, a deliberate end, an unbind, a re-link, a hold of 0 that closes
    at once, a no motion taken while the proxy shows none, and the run-out
    close of R4.
  - **Kept** at `OnDriverDestroyed`, where only the timer stops (that is
    the point of the record); on a failure (a status with no motion field);
    during a test; and when the hold setting changes.
- **R8. Which hold time.** A resumed hold uses the Occupancy Hold Time set
  when the first reading after the start is applied, not the one the hold
  began with. A change while any hold runs, resumed or not, still applies
  from the next no motion (EC R11). Why the current setting:
  - across a restart the setting changes only through a project load or a
    restore, and the owner's current value is then the one to use;
  - a restart already applies the current value today;
  - nothing more needs persisting.
- **R9. Only after a start.** The record is looked at only when no hold
  runs in this instance.
  - A resync, a reconnect or a stuck-motion check while a hold runs leaves
    the hold alone, as today.
  - An end of motion missed while no hold ran starts one in full, as today
    (§7 item 2).
- **R10. Unchanged, and each deletes the record:**
  - motion opens at once and cancels the hold (EC R4 and R5 decide between
    `STATE_OPENED` and `OPENED`);
  - a deliberate end closes once, at once, and is never held;
  - the first reading ever, when the proxy was never told, is `STATE_*`
    with no hold;
  - a re-link forgets Hue's state;
  - a hold of 0 closes at once.
- **R11. The bridge does not change.** The §3 messages get no new field,
  and `bridge/http.lua`, `bridge/motion.lua` and `bridge/motion_model.lua`
  stay as they are.
- **R12. What the owner sees.**
  - An info line in the log when a hold resumes or turns out to have run
    out.
  - No new row, variable, event or property: released ones can never be
    taken back (EC §0.2).
  - The Hue Motion row keeps showing Hue's own state.
  - The manual's sentence about restarts changes (§9).

## 5. Lifecycle corner cases

"First reading" means the first `HUE_MOTION_STATE` with a `motion` field
after the start. It comes from the resync (`reason` "resync"), or from the
bridge's cached answer to the device's hello when only the motion driver
restarted ("hello").

| # | Case | Hue reports at the first reading | Today | Decision | Why |
| --- | --- | --- | --- | --- | --- |
| L1 | A hold runs during a driver update in place, a Director restart or a dev-loop reload (the issue's case) | no motion, the same change time | `STATE_OPENED`, then the hold again in full, so late by the part already held | Automatic: resume what is left (R1 to R4): `STATE_OPENED`, then `CLOSED` when it ends | R3 proves it is the same end of motion; the controller clock measures the seconds or minutes in between |
| L2 | As L1, but the hold ran out during the downtime | the same | as L1 | Automatic: `CLOSED` at once at the first reading (R4) | the proxy last got motion, so this is a real change (EC R4): the programming runs once, late only by the downtime |
| L3 | The controller is rebooted while a hold runs | the same | as L1 | Automatic: L1 or L2 when the clock checks pass (R5), else the full hold | a clock not set yet reads behind, which gives the full hold [assumed]; RTC drift moves the close by seconds [assumed] |
| L4 | The controller clock steps (NTP, or set by hand) between the hold's start and the restart | the same | as L1 | Accepted. Backward: a longer or full hold. Forward by s: that hold ends s early, once | only a forward step followed by a restart within one hold does harm; a monotonic clock would not survive a reboot either (§7 item 3) |
| L5 | The controller and bridge clocks disagree, by any amount, either way (for example a bridge without internet, which may drift [assumed]) | anything | they are not compared | Forbidden: comparing them (R2) | EC rule 5 and R10; the skew never enters the formula |
| L6 | Hue's change time lies in the controller's future or far in its past | anything | — | Does not arise: change times are only matched for equality. A record whose `since` is ahead of now gives the full hold (R5) | as L5 |
| L7 | An end of motion the device never saw: motion came or went while it was down | no motion, a change time newer than the record's (or no record) | the full hold from the first reading | As today: the full hold, and the record is replaced (R6). Forbidden: resuming from the old record | without a bridge time reference nothing dates an unseen end (§7 item 2), and the old record would close too early |
| L8 | The same end of motion, from before a long outage (the controller off for hours or days, a power cut) | no motion, the record's change time | the full hold, then `CLOSED` | Automatic: `CLOSED` at once (R4) | nobody has moved since; the programming runs once |
| L9 | At the restart the bridge does not answer, the sensor is unreachable or has no reading, or the area is not running | a status, no motion | the contact is untouched and `GET_STATE` is unanswered | As today. The record stays until the first motion reading, which then decides (L1, L2 or L7) | a failure is not an end (D3) |
| L10 | The bridge rebooted during the downtime, and its change time may have moved without new motion [assumed] | no motion, another change time | the full hold | As today (R6) | a mismatch always leans towards the full hold |
| L11 | Motion at the restart | motion | `STATE_OPENED` or `OPENED` (EC R4, R5) | As today; the record is deleted (R10) | new motion ended the hold |
| L12 | The proxy last got "closed", yet a record exists (a test of no motion during the hold, or a delete lost in a power cut) | no motion | `STATE_CLOSED`, no hold | As today; the record is deleted. Forbidden: re-opening the contact because of a record | EC R4: no event for a state that did not change |
| L13 | The proxy last got "open", but there is no record (the hold was 0 then, or motion was showing and ended while the driver was down) | no motion | the full hold, or `CLOSED` with a hold of 0 | As today (R6) | nothing to resume |
| L14 | The Occupancy Hold Time differs at the restart. Only a project load or a restore can do that: Composer cannot change it while the driver is down | no motion, the same change time | the full hold with the new value | Automatic: what is left is counted from the new value (R8), and may close at once | the owner's current value counts; nothing extra is persisted |
| L15 | The Hold Time changes while a resumed hold runs | — | — | As EC R11: the running hold keeps its length, and the next no motion uses the new value | one rule for every running hold |
| L16 | The Hold Time is 0 at the restart and a record exists | no motion | `CLOSED` if the proxy shows motion | As today; the record is deleted | 0 means no hold |
| L17 | A resync, a reconnect or a stuck-motion check while a hold runs, with no restart | no motion, the same or a newer change time | the hold is left alone | As today. A newer change time is copied into the record (R7) | the running hold is already right |
| L18 | A stream outage with no restart, and the end missed while no hold ran (the proxy open) | no motion, an old change time | the full hold from the resync | As today (R9, §7 item 2) | this would need a bridge time reference |
| L19 | A MotionAware area rather than a sensor | the newest change among its enabled services (F8) | as L1 | The same rules as a sensor. A switch of the live service (EC A9), a recalibration or a pause in between gives a mismatch (the full hold) or a deliberate end (`CLOSED`) | the bridge derives an area's change time the same way on both paths |
| L20 | A sensor whose firmware has no `motion_report` | motion without `motion_changed` | as L1 | As today: never a record (R7), always the full hold | no change time to match |
| L21 | At the restart the sensor is switched off, the area paused, either deleted in Hue, the device forgotten or unbound | `ended` | `CLOSED` once, at once | As today; the record is deleted (R10) | a deliberate end, never held |
| L22 | A device just added or re-linked: its first reading ever | no motion | `STATE_CLOSED` with no hold (the proxy was never told), or the full hold after a re-link | As today: no record exists or applies (R3 needs the same rid, and a re-link deletes the record) | no prior state |
| L23 | The project is restored from a backup (persisted values come back with it [assumed]) | no motion; the same change time only if nothing moved since | the full hold | Automatic: `CLOSED` at once on a match (L8), else the full hold | as L8 and L7 |
| L24 | A restart during Test Motion Programming | — | the test is lost, and the persisted state is the test's (EC R12) | L12 or L1, on that persisted state | tests are not persisted |
| L25 | A dev-loop reload (#376); a note only | — | — | `OnDriverDestroyed` runs first (F12): it stops the timer and keeps the record, and the new code resumes. If `OnDriverDestroyed` fails, the old code's timer can still send a `CLOSED` (the #376 class, dev builds only) | — |
| L26 | A build without this feature runs in between (a downgrade, then an upgrade) | — | — | The old build neither uses nor deletes the key. The new one uses it only on a match with the proxy open, and deletes it otherwise | harmless |
| L27 | Two restarts within one hold | the same | the hold again in full, twice | Automatic: `since` never moves while the hold lasts, so each restart resumes from it | as L1 |

## 6. Behaviour

### 6.1 New state in `src/hue_motion/driver.lua`

- `HOLD_KEY = "motion_hold"`, and `hold_record`, the in-memory copy of the
  persisted `{ rid, changed, since }`, or nil.
- `CLOCK_FLOOR_MS = 1735689600000`, which is 2025-01-01T00:00:00Z.
- `now_ms()`: `C4:GetTime()` under `pcall`, else `os.time() * 1000`, as
  in `bridge/commands.lua`.
- `hold` stays `{ timer }`.

### 6.2 Loading

In `OnDriverLateInit`, together with `load_identity()`, before
`dev.late_init()` applies buffered messages (F11):
- read `HOLD_KEY`;
- keep it only when it is a table with:
  - `rid`: a non-empty string;
  - `changed`: a non-empty string of at most 40 characters;
  - `since`: a number;
- otherwise delete the key if it is present.

### 6.3 Helpers

- **`save_record(rec)`** persists a copy. **`drop_record()`** calls
  `PersistDeleteValue` only when a record is held.
- **`stop_hold_timer()`** cancels the timer and sets `hold = nil`. It is
  used by `OnDriverDestroyed` only.
- **`cancel_hold()`** is `stop_hold_timer()` plus `drop_record()`. Every
  caller of today's `cancel_hold` keeps calling it: motion, a deliberate
  end, a re-link, a hold of 0, a no motion while closed.
- **`start_hold(ms)`** works as today, but takes a length in ms. Its timer
  callback drops the record before it reports.
- **`same_change(a, b)`** is R3's instant comparison.
- **`resumable(changed)`** applies R3 and R5. It returns `left_ms`, or nil
  with a reason logged at debug ("another end of motion", "no change time",
  "another rid", "clock").

### 6.4 `take_motion(open, changed)` when `open` is false

Today's condition `hold_s > 0 and (hold or showing == true)` still decides
whether a hold applies. Inside it:

1. **A hold runs** (R9): if `changed` is present, a record is held and
   `same_change(record.changed, changed)` is false, set
   `record.changed = changed` and save it. Then
   `report(true, "no motion, held")`.
2. **No hold runs, and `resumable(changed)` returns nil:** `start_hold(hold_s × 1000)`.
   Then save `{ rid = st.rid, changed = changed, since = now_ms() }` when
   both values are present; otherwise drop the record. Then
   `report(true, "no motion, held")`.
3. **No hold runs, and `left_ms ≥ 1000`:** `start_hold(math.ceil(left_ms))`,
   keep the record as it is, and log at info. Then
   `report(true, "no motion, hold resumed")`.
4. **No hold runs, and `left_ms < 1000`:** drop the record and log at info.
   Then `report(false, "no motion; the hold ran out while the driver was not running")`.

Outside that condition nothing changes: `cancel_hold()` (which now also
drops the record), then `report(false, "no motion")`.

`report` already turns these into `STATE_OPENED` or `CLOSED` for the first
state after a start (EC R4). The only change in `OnDriverDestroyed` is that
`stop_hold_timer()` replaces `cancel_hold()`.

### 6.5 Log lines

- **On resume, info:** "no motion since 14:05 (bridge time); the hold
  resumes: 264 of 300 s left (it began before the restart)".
- **On run-out, info:** "no motion since 14:05 (bridge time): the 300 s
  hold ended 36 s ago". `report` adds its own "CLOSED (…)" line.
- **When a record does not qualify, debug:** the reason, as in 6.3.

### 6.6 The issue's case, worked through

1. The hold is 300 s. At 10:00:00.000 bridge time Hue reports no motion.
2. The device takes it at controller time S, about 0.6 s later. It saves
   `{ changed = "…T10:00:00.000Z", since = S }` and starts a 300 s timer.
3. The driver is updated at S + 35 s.
4. The first reading arrives at S + 36.2 s with the same change time. The
   elapsed time is 36.2 s and 263.8 s are left. `STATE_OPENED` goes out.
5. `CLOSED` goes out at S + 300 s: on time, within the event's delivery of
   about 1 s.

If the controller was instead off from S + 30 s to S + 330 s, nothing is
left: `CLOSED` goes out at the first reading after the resync, and fires
once.

## 7. Not doing

1. **Comparing the controller clock with Hue's change time** (option A).
   Forbidden by EC rule 5, EC R10 and R2.
2. **A bridge time reference** (option B), which would also shorten holds
   whose end of motion the device never saw (L7, L18). It is offered as a
   follow-up issue if the owner wants it. It first needs a dev-loop read of
   a CLIP v2 response's headers on the Bridge Pro and on a square bridge
   (F6), and then the bridge changes listed in §3. Until then such a hold
   is late by at most one hold length, once, and only after a failure.
3. **A monotonic clock** (`GetTickCount`, or `GetUptime` with
   `GetBootID`; F5).
   - Across a reboot neither helps: both restart from zero.
   - `GetUptime` is newer than the declared minimum OS, and
     `GetTickCount`'s wrap is not documented.
   - Within one boot they would only fix L4's forward step.
   - `C4:GetTime` stays: it is the clock the repository uses, and the one
     the fake runtime drives.
4. **Persisting the hold's length** (R8).
5. **Showing the remaining hold** in a row, a variable or an event (R12).
6. **Replaying an episode that was missed** (D8). Unchanged.
7. **Changing the tests** (EC R12) or the deliberate-end rule.
8. **Any bridge or message change** (R11).

## 8. Specs to write

All in `tests/spec/motion_driver_spec.lua`, in a new
`describe("Occupancy hold across a restart (#371)", …)`. Conventions:
- Set `c4.now_ms = NOW` after `load_motion`, with
  `NOW = 1793000000000` (an invented 2026 time). The fake's default of
  1000000 is before the floor, which S13 uses.
- A restart is `load_motion` with
  `persist = { motion_shown = "open", motion_hold = { … } }`.
- The record is read back from `c4.persist.motion_hold`.

The cases:

1. **S1:** a hold that starts writes `{ rid = RID, changed = <the reading's>, since = NOW }`. Nothing is written with a hold of 0, or without `motion_changed`.
2. **S2:** while the hold runs, a no motion with a newer change time replaces `changed`. `since` stays, and the timer is untouched.
3. **S3:** the record is deleted when the hold ends, on motion, on a deliberate end (`ended = "off"`), on an unbind, at a re-link (a configure with `OTHER_RID`), and on a no motion while the proxy shows none.
4. **S4:** `OnDriverDestroyed` cancels the hold timer and keeps the record.
5. **S5 (the issue):** hold 300, record `since = NOW − 36000`, and a reading with the same change time give contact `{ "STATE_OPENED" }` and one timer of 264000 ms. Firing it gives `{ "STATE_OPENED", "CLOSED" }` and deletes the record.
6. **S6:** with `since = NOW − 400000`, the contact is `{ "CLOSED" }` at once, no hold timer is left, and the record is deleted.
7. **S7:** with `since = NOW − 299500`, less than 1 s is left: `{ "CLOSED" }` at once.
8. **S8:** the same instant in two spellings resumes: record `"2026-10-26T07:15:16.502Z"`, reading `"2026-10-26T07:15:16.502+00:00"`.
9. **S9:** a different change time gives the full hold (300000), and the record is rewritten with the new `changed` and `since = NOW`.
10. **S10:** no `motion_changed` gives the full hold, and the record is deleted.
11. **S11:** a record of another rid gives the full hold.
12. **S12:** a record whose `since` is ahead of now (`NOW + 60000`) gives the full hold, and `since` becomes NOW.
13. **S13:** a clock before 2025 gives the full hold. Once with `c4.now_ms` left at the fake's default, once with a record whose `since` is before the floor.
14. **S14:** the current setting counts. Hold 60 with `since = NOW − 36000` gives a 24000 ms timer; hold 30 gives `CLOSED` at once.
15. **S15:** a property change during a resumed hold leaves its timer alone.
16. **S16:** two restarts within one hold: the second resumes from the first `since`, with the clock advanced in between.
17. **S17:** motion at the restart gives `STATE_OPENED` and deletes the record (`OPENED` when the persisted state is closed). The next no motion then holds in full.
18. **S18:** a persisted "closed" with a record gives `STATE_CLOSED`, no hold, and deletes the record.
19. **S19:** a failure at the restart (`online = "false"`, a status, no `motion`) keeps the record and sends nothing to the proxy. A later reading with the same change time then resumes, or closes when the time has run out.
20. **S20:** a deliberate end at the restart gives `CLOSED` once, no timer, and deletes the record.
21. **S21:** a hold of 0 at the restart, with a record and the proxy open, gives `CLOSED` and deletes the record.
22. **S22:** S5 for an area (`AREA`, `AREA_RID`).
23. **S23:** a `reason = "resync"` reading with the same change time while a hold runs starts no second timer and leaves the record's `since` alone.
24. **S24, end to end:** in one runtime, `known()`, then motion, then no motion, then `OnDriverDestroyed()`. Carry `c4.persist` into a second `load_motion` whose `c4.now_ms` is 36 s later. The same reading there gives a 264000 ms timer.

Kept and renamed: "after a restart with motion shown, reports STATE_OPENED
and holds the first no motion in full" becomes "… without a record of the
hold (#371 R6)", unchanged otherwise.

Optional, for the coordinator, in `tests/spec/motion_roundtrip_spec.lua`: a
motion device restarted alone resumes its hold from the bridge's cached
answer to its hello.

## 9. Files

| File | Change | Owner |
| --- | --- | --- |
| `src/hue_motion/driver.lua` | §6: R1 to R12. The header and the hold comments cite this file | implementation agent |
| `tests/spec/motion_driver_spec.lua` | §8 | implementation agent |
| `docs/motion-design.md` | the D10 row and §2.7 "Hold time": "after a restart, see `motion-hold-restart-design.md`" | coordinator |
| `docs/edge-cases-motion.md` | R11: its restart sentence is superseded by this file | coordinator |
| `src/hue_motion/www/documentation.html` | "A hold interrupted by a restart starts again in full at the next end of motion." becomes: "A hold interrupted by a restart (a driver update, a Director restart, a controller reboot) goes on for the time it had left, provided the bridge still reports the same end of motion. If that time ran out meanwhile, the sensor closes as soon as the bridge answers. If motion ended unseen while the driver was not running, the hold starts again in full." | coordinator (docs) |
| `CHANGELOG.md` | an `Unreleased` line with #371 | coordinator |
| `docs/README.md` | an index entry: a design contract belongs there, not on the front page | coordinator |
| `tests/spec/motion_roundtrip_spec.lua`, `docs/composer-checklist.md` | optional (§8, §10) | coordinator |

What stays untouched:
- every `src/hue_bridge/` file, and the §3 messages (R11);
- `src/hue_motion/driver.xml`: no capability or property change, so an
  update in place needs no controller reboot;
- `tests/helpers/fake_c4.lua`, which already has `GetTime` with
  `advance`, `PersistDeleteValue` and `ParseIso8601DateTime`.

## 10. Checking it on the house

This is optional and opportunistic, and no release waits on it.
1. With a `--dev` build installed, the Windows session sets one area
   device's Occupancy Hold Time to 60.
2. When the log shows that device holding (someone left the room),
   `tools/devctl.py reload` within 30 s.
3. Expect the "the hold resumes" line, then `CLOSED` about 60 s after
   Hue's end of motion.

No one has to walk past a sensor and nothing waits more than a minute, but
it depends on natural motion. The specs are the gate.

## 11. For the owner

Nothing here needs an answer before the code is written: the defaults above
stand. Worth a look:

1. **The clock choice and its limit** (§3, R2). A hold resumes only when
   the device itself saw its end of motion. An end that happened while the
   driver was down, or during a stream outage, still gets the full hold, as
   today. Covering those would mean the bridge-time follow-up (§7 item 2).
2. **A hold that ran out closes at the first reading, however long ago**
   (R4, L8). After a long power cut, "stops sensing motion" runs once as
   soon as the bridge answers, instead of a full hold later, as the issue
   proposes.
3. **A resumed hold uses the current setting** (R8), not the one it began
   with.
4. **EC R11's "a hold cut by a restart starts again in full (never
   shortened by comparing clocks)" is reversed for this one case.** It is
   still never shortened by comparing the controller's clock with the
   bridge's.
