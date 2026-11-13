# Simplify research: one engine for the driver's background tasks (#334)

Status: research by the scheduler agent, 2026-11-04. Read-only study of
`main` (beta 7, build 425) against the contract in
[simplify-actions-design.md](simplify-actions-design.md) §0. Nothing here is
built. The owner's correction of 2026-11-04 applies throughout: Director's
four-transfer limit sizes nothing below (principle 4); what still holds is
Director's one `C4:url` transfer per host at a time.

Current (2026-11-13, #478): built in 1.2 as `bridge/housekeeping.lua`
([simplify-actions-design.md](simplify-actions-design.md) §2.1), with three
amendments: the background tasks are always on (the owner's answer D4), the
engine only reads, and the tasks themselves live in `bridge/tasks.lua`
(since #373).

## 1. Findings

1. **Today there is no engine, only three de-facto schedulers.** The
   per-module resync coalescing (`src/hue_bridge/bridge/owner.lua:801-851`),
   the stream's watchdog and capped backoff (`stream.lua`, `netstream.lua`)
   and the command queues' debounce, token bucket and capped retry
   (`commands.lua`). Everything else is ad hoc: a fixed 30 s identity retry
   with no backoff, a 5-minute repeating rows timer, and a resync that runs
   only after a stream connect or a click. There is no safety net behind the
   stream, no request budget, no "user first" rule, and a connect resync that
   fails is never retried until the next connect.
2. **Proposal: `bridge/housekeeping.lua`**, one module with one one-shot
   "alarm" timer re-armed for the earliest due task (never more than 1 h
   ahead), a task table, one job at a time, and a gate in front of every
   request it makes. It only **reads** from the bridge and only writes to
   Control4 what the edge-case rules already call automatic: it never
   creates, renames, moves, binds or deletes a device.
3. **User commands win without a new transport.** Director serialises
   `C4:url` per host, so a user PUT waits at most for the one housekeeping
   GET in flight if the engine keeps at most one in flight and starts none
   while a command queue is busy or within 1.5 s of the last user write. The
   worst case is the 351 KB scene catalogue and its ~1 s decode, which is why
   it becomes the rare part. REST over a network connection is not needed
   (§3.6).
4. **Tier the resync (#65).** After a silence-watchdog reconnect read
   everything but `/scene` ("quick": ~14-16 small GETs, ~240 KB); read
   `/scene` too ("full": 15-17 GETs, ~600 KB) at the first connect of a run,
   after an error reconnect, daily, and on Refresh All.
5. **Periodic means a freshness deadline, not a clock.** A task is due when
   its last success is older than its interval: a quiet house whose stream
   reconnects anyway never pays twice; a busy house gets a quick resync every
   6 h and a full one every 24 h. After a Director restart (`DIT_STARTUP`)
   no optional task runs for 5 min plus jitter; overdue ones then go one at a
   time, 30 s apart.
6. **Two classes.** *Essential* (the resync after a connect, clicks) is never
   switched off and is outside the hourly budget, but still coalesced and
   locked. *Optional* (periodic, event-triggered, re-checks) obeys a budget of
   60 bridge requests per rolling hour and the one setting.
7. **One control: `Automatic Housekeeping` (On/Off, default On).** Off is
   beta 7's behaviour: essential tasks only. Per-task settings fail the Apple
   test. Results go to one read-only `Housekeeping` row whose drop-down lists
   each task; problems go to `Attention`; `Last Action` stays the result of
   the last click.
8. **New tasks it makes cheap:** a key re-check while the bridge refuses the
   key (makes Test Connection's lock-clearing automatic), a daily unkeyed
   identity and bridge-info check, a quick resync when an event names a rid
   the caches lack, and `Attention` when the bridge or the stream has been
   away an hour. No pin re-check is needed, and nothing phones home.
9. **Testable with one fake extension:** an ordered virtual clock
   (`c4.advance(ms)`) that fires timers by due time. The engine takes its
   clock, timers and HTTP through `ctx`, as `commands.lua` and `motion.lua`
   already do.

## 2. Evidence

### 2.1 Today's timers and background jobs

Paths are under `src/hue_bridge/` unless they start with `src/` or `tests/`.

| Job | Owner | Cadence | Trigger | Guard | Backoff | On failure | Kind |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Resync after connect (`resync_all`) | `driver.lua:716-743`, `781-791` | every connect | `on_connected`, deferred 1 ms (`netstream.lua:806-818`) | module busy flags, pending callers coalesced (`bridge/owner.lua:801-851`) | none | logged; `done` is ignored at `driver.lua:791`, so nothing retries until the next connect | de-facto scheduler |
| Refresh All, Refresh Scenes | `driver.lua:1917-1939` | click | owner | `can()`: paired only | none | Last Action | manual |
| Stream watchdog | `bridge/stream.lua:64`, `209-244`; `bridge/netstream.lua:119`, `503-524` | 600 s of silence (`Stream Watchdog (s)` 60-3600, `driver.xml:226-232`) | no event or keepalive | none | reconnect | reconnect + full resync | de-facto scheduler |
| Stream reconnect | `bridge/stream.lua:65-66`; `bridge/netstream.lua:120-121`, `942-979` | 1 s doubling to 60 s | end, error, connect timeout (10 s, `netstream.lua:118`) | stops for good on 401/403 | yes, cap 60 s | `Event Stream` row | de-facto scheduler |
| Web transfer lifetime | `bridge/stream.lua:63` | 3600 s | Web transfer only | | | reconnect | transport |
| Identity retry | `driver.lua:845`, `958-966`, `1009-1015` | fixed 30 s | `/api/0/config` unreachable, TLS check inconclusive | never for a different bridge | **none** | Status text; ~2,880 unkeyed GETs a day while away | ad hoc |
| Network TLS check retry | `driver.lua:1076-1090`; `bridge/netcheck.lua:153-154`, `224-227` | 30 s doubling to 1 h | inconclusive verdict | 900 probe binding ids | yes, cap 1 h | `Event Stream` row | ad hoc, well-behaved |
| Key confirm | `driver.lua:371-396` | on a 401/403 | event | one at a time | none | locks keyed traffic | event |
| Rows refresh | `driver.lua:2293` | 300 s, repeating | none | none | none | none | ad hoc; not cancelled in `OnDriverDestroyed` (`driver.lua:2331-2363`) |
| Time-based Attention | `bridge/lights.lua:61` (24 h offline), `bridge/motion.lua:157` (1 h) | via the rows refresh | | | | | evaluated lazily |
| Per-event rows | `driver.lua:92-133` | ≤ 1 write/s per row | events | | | | display |
| Last Action rows | `driver.lua:1443-1460` | 400 ms, then 1.5 s | click | | | | display |
| Binding reconcile | `driver.lua:2149-2160`, `2110-2125` | 1 s after the last change; 6 s nil confirm | `OnBindingChanged` | | | | project-only debounce |
| Driver Version | `driver.lua:1180-1192` | 5 s, 10 s | empty version | | | | display |
| Command queues | `bridge/commands.lua:46-51`; `driver.lua:678-698` | debounce 80 ms; lights 10/s burst 10, groups 1/s burst 3 | user command | final errors drop | 500 ms doubling to 8 s, dropped after 30 s | warn | de-facto scheduler for writes |
| Scene recall window | `bridge/scenes.lua:88` | 300 ms | recall | | | | user |
| Motion away grace | `bridge/motion.lua:156`, `1241` | 60 s | stream down | | | | display |
| Motion stuck check | `bridge/motion.lua:157-159`, `1636-1735` | 30 s tick while any device shows motion; GETs after 300 s without news | self-arming | skips while resyncing or checking | none | sets "away" | ad hoc, bridge GETs |
| Busy expiry | `bridge/owner.lua:767-777` | 90 s, lazy | | | | clears a stuck flag | guard |
| Motion diagnostics | `bridge/motion_diag.lua:124-125` | 20 s wait, 10 min capture | click | | | | diagnostic |
| Child devices | `src/common/device.lua:121`, `762-790`; `src/hue_light`, `src/hue_scene`, `src/hue_motion` | binding re-check 5/10/15/30 s; keypad, hold, follow timers | per device | | | | not bridge housekeeping |
| Dev loop | `src/common/devloop.lua:75`, `1126` | 3 s repeating, one chain in flight, abandoned after ten skipped ticks | dev builds only | | | | the nearest thing to an engine today |

### 2.2 Facts the design rests on

- `C4:SetTimer(ms, fn, repeat)`: delay must be above 0; one-shot callbacks
  get the timer, repeating ones also a skip count, because Director skips
  ticks it cannot serve in time; returns an object with `Cancel()`; not to be
  called in `OnDriverInit` **[verified: SDK API `34_timer/_1-SetTimer.md`,
  `22_miscellaneous/_25.2-SafeUsageTable.md`]**. Whether Director keeps a
  one-shot of several hours exactly is not documented **[assumed]**; the
  driver's 5-minute repeating timer runs in production **[verified:
  `driver.lua:2293`]**.
- `C4:GetTime()` is milliseconds since the epoch from OS 3.2.3 **[verified:
  `34_timer/_2-GetTime.md`]**; the driver requires 3.3.0 (`driver.xml:16`).
  Being wall-clock based, it can jump when the controller sets its clock
  after boot **[assumed]**.
- Director kills all of a driver's timers in `OnDriverDestroyed`, which runs
  on update and at shutdown **[verified: `22_miscellaneous/_24-OnDriverDestroyed.md`]**:
  no timer outlives a restart, so last-run times must be persisted.
- `OnDriverLateInit` gets `DIT_ADDING`, `DIT_STARTUP` or `DIT_UPDATING` from
  OS 3.2.0 **[verified: `22_miscellaneous/_25.1-OnDriverLateInit.md`]**;
  `driver.lua:2265` ignores it today; the values on OS 3.4.x **[assumed
  until logged]**.
- `PersistSetValue` accepts tables and writes on its own thread, so an
  immediate read may miss the value **[verified:
  `26.5_persistence/_4-PersistSetValue.md`; [design.md](design.md) "Storage"]**.
- One active `C4:url` transfer per host text, strictly serialised; small
  GETs took 27 and 38 ms **[verified: hardware, design.md "C4:url transfer
  scheduling on OS 3.4.2"]**. Since #317 the event stream holds a network
  connection, not a transfer **[verified: [raw-stream-design.md](raw-stream-design.md) §0.2]**.
- Hue's guidance: about 10 requests/s to lights, 1/s to grouped_light
  **[verified: design.md "Commands and rate limiting"]**; for GETs the same
  general guidance **[assumed]**.
- A full resync is 6 light GETs (`bridge/lights.lua:121-132`), 3 scene GETs
  (`bridge/scenes.lua:580-610`), 0 zone-light GETs (handed the scenes'
  `/grouped_light`, `driver.lua:729-740`, `bridge/zone_lights.lua:767-774`)
  and 5 motion GETs plus 3 area types (`bridge/motion.lua:132-147`): 17 on a
  Bridge Pro, 15 on a Bridge v2, whose first area GET fails and stops the
  rest (`bridge/motion.lua:1322-1335`) **[verified: code]**. `/scene` is
  351 KB and decodes in about a second; the whole `/clip/v2/resource` is
  588 KB in 1 s **[verified: design.md "Project APIs" and "Scenes"]**.
- The bridge sends no keepalive on the stream **[verified: design.md "Event
  stream"]**, so a quiet house may reconnect and fully resync every
  watchdog period; the real rate is unmeasured (#65, open).
- `add` and `delete` containers update caches, counts and Attention without
  a request (`driver.lua:806-812`, `bridge/lights.lua:966-1011`); an update
  for a rid the cache lacks is dropped (`bridge/lights.lua:1013-1014`)
  **[verified: code]**.
- Identity is checked once per start and address (`driver.lua:1117-1123`,
  `262-268`); a stream reconnect does not repeat it **[verified: code]**.
- The edge-case rules forbid `AddDevice` from an event, a resync or startup,
  `RenameDevice` without a click, and deleting or unbinding on the driver's
  own **[verified: [edge-cases-ux.md](edge-cases-ux.md) §1]**.
- The fake runtime records a timer's delay but not its due time;
  `fire_timers` fires every active timer, `fire_timers_of(ms)` those of one
  delay, and specs move `c4.now_ms` by hand
  (`tests/helpers/fake_c4.lua:369-377`, `419-421`, `980-1017`) **[verified]**.

## 3. The engine

### 3.1 Shape: one module, one alarm

```lua
local hk = housekeeping.new(ctx)  -- now_ms, wall, set_timer, persist_get/set, log,
                                  -- http (bridge_request), user_active(), state(), on_status
hk:define({ name = "resync", class = "essential", run = function(job, done) ... end, ... })
hk:start(dit)        -- late init: quiet period by DIT, load persisted last runs
hk:poke(name, why)   -- a trigger: "connect", "event", "error", "setting", "click"
hk:enable(on)        -- the Automatic Housekeeping setting
hk:reset(gen)        -- address change or Forget Pairing: drop late results
hk:stop()            -- OnDriverDestroyed
-- inside run: job.http(req, cb) is the gated, counted request; job.note(text)
```

Why one re-armed one-shot timer rather than a repeating tick or a timer per
task: it wakes Lua only when something is due (a tick of 30 s would wake it
2,880 times a day for nothing); there is one timer to cancel at destroy,
address change and Off; and the job lock, budget and gaps live in one place,
which per-task timers would need anyway. Each arm is capped at 1 h so a
clock jump or a timer Director never fires costs at most an hour. The
5-minute rows refresh becomes the task "rows" with a computed due time (the
next 24 h offline nag or 1 h motion item), at no request cost.

### 3.2 The task table

| Field | Meaning |
| --- | --- |
| `name`, `class` | stable id; `essential` (always on, outside the budget) or `optional` |
| `triggers` | any of `startup`, `connect`, `event`, `timer`, `error`, `setting`, `click` |
| `interval_s` | freshness deadline: due when the last success is older (nil: trigger-only) |
| `jitter` | fraction of the interval (default 0.1), deterministic per installation |
| `debounce_s`, `min_gap_s` | quiet time after the last trigger; least time between two runs |
| `budget` | most bridge requests one run may make; `job.http` refuses beyond it |
| `timeout_s` | a run whose `done` never comes is ended (as `owner.lua:767-777`) |
| `guards` | `paired`, `identity_ok`, `key_ok`, `stream_up`, `not_pairing`, `modules_idle` |
| `persist` | keep last run and result across restarts (only for intervals ≥ 1 h) |
| `run(job, done)` | does the work, then `done(ok, text)` |

### 3.3 Scheduling rules

- **Due time**: `max(last_ok + interval + jitter, last_run + min_gap,
  quiet_until, trigger_at + debounce)`. After a failure: `last_run +
  min(cap, 60 s × 2^(fails-1))`, cap = the smaller of the interval and 1 h;
  one success resets it. Today's connect resync gets this retry too.
- **Boot**: `DIT_STARTUP` (whole project starting, every child device saying
  hello) sets `quiet_until = now + 300 s + jitter(0-60 s)`; `DIT_UPDATING`
  60 s; `DIT_ADDING` none; a missing value counts as `DIT_STARTUP`. The
  resync after the first connect is essential and runs as today: it *is*
  the startup resync, and marks the resync tasks fresh. Overdue optional
  tasks then run one at a time, 30 s apart, oldest deadline first.
- **Jitter**: a hash of the device id and the task name, so the same house
  always gets the same offset, specs can predict it, and nothing lines up
  with the bridge's own top-of-the-hour updates (design.md "Concurrent
  transfers" saw one at 01:00:00). No `math.random`, no seeding question.
- **Coalescing**: a trigger while the task waits moves its debounce; a
  trigger while it runs sets `again`, which makes exactly one more run after
  it, answering every caller (the `owner.lua:801-851` pattern). Forty events
  in a burst give one run.
- **One job at a time**: a global lock; other due tasks wait their turn.
  Clicks join the queue at the front.

### 3.4 User commands first

- Every engine request goes through `job.http`, which counts it against the
  run's budget and the rolling hour (optional class: 60 requests/h) and
  waits while `ctx.user_active()` is true: either command queue holds work
  (a new `commands:busy()`, about ten lines next to `commands:pending`,
  `bridge/commands.lua:479`), or `bridge_request` sent a non-GET (light,
  group or scene-recall PUT) in the last 1.5 s. It looks again every
  250 ms and goes after 10 s regardless, so a long slider session cannot
  starve the resync after a reconnect.
- The engine never writes to the bridge, so every user request is a PUT and
  every engine request a GET; the gate needs no tagging beyond the method.
- With one engine GET in flight and Director's FIFO per host, a user PUT
  waits for at most that GET: tens of ms for most, about 0.6 s plus a ~1 s
  decode that blocks Lua for `/scene`. The engine therefore never starts the
  `/scene` GET within 5 s of a user write, and runs it daily (§5).
- Imports and Refresh All are clicks: they skip the user gate but still
  take the lock and coalesce through the modules' busy flags.

### 3.5 Offline, key refused, address change, bridge swap

| State (from the driver) | What runs | What the owner sees |
| --- | --- | --- |
| Online (identity passed, key accepted) | everything due | `Housekeeping`: "On; all current …" |
| Away (identity retry pending, or the stream down and the last engine GET failed in transport) | only the identity retry, now 30 s doubling to 5 min (today a fixed 30 s), and the stream's own backoff; optional tasks pause | after 1 h, `Attention`: "Bridge not answering at 10.0.2.143 for 1 h: if its address changed, enter it in Bridge IP Address" |
| Stream down, bridge answering | quick resync every 30 min (a slow poll that keeps state from rotting) | after 1 h, `Attention`: "Event stream down for 1 h; lists are read every 30 min instead" |
| Key refused (`state.key_rejected`, `driver.lua:356-371`) | only the key re-check (§5); everything keyed is refused already | Status as today, plus "checked again at 14:35" |
| Different bridge at the address | nothing (today's rule: it does not become ours by waiting, `driver.lua:840-845`) | Status as today |
| Address change (`state.address_gen` bump) | `hk:reset`: alarm cancelled, late answers ignored by generation as everywhere in `driver.lua`; backoffs cleared, last runs kept | |
| Forget Pairing, or a bridge with another id paired | persisted last runs cleared | |
| Pair Bridge running, or an import adding devices | engine waits (guards `not_pairing`, `modules_idle`) | |

No address discovery: the cloud endpoint is phoning home and mDNS is not
built (design.md "Discovery"); the `Attention` line is the whole answer.

### 3.6 REST over a network connection (the owner's question)

The engine does not depend on it. What it would cost: an HTTP/1.1 client on
`C4:CreateNetworkConnection` with keep-alive (request writer; status line,
headers, `Content-Length` and chunked bodies, of which `netstream.lua`
already parses the last three; per-request timeouts; reconnects; the result
shape of `http.request`), a never-used binding id (#329: a reused id
misbehaves), certificate failures that are silent instead of curl 60
(`netcheck.lua:14-25`), and its own fake and hardware round; an estimate of
400-600 Lua lines plus specs **[assumed]**. What it would remove: Director's
FIFO, so the driver orders every request itself (strict priority) and
perhaps a TLS handshake per request **[assumed: whether `C4:url` reuses
connections is unmeasured]**. What it would not remove: one request at a
time per connection, and the Lua decode of `/scene`. Cheaper if ever needed:
send engine GETs on a padded spelling of the address, which gets its own
Director queue **[verified on OS 3.4.2: design.md "Two ways to keep
commands flowing"]**, about 20 lines with the existing `altaddr.lua`, but
it leans on an undocumented scheduler detail. Recommendation: neither now;
revisit if §8 Q-M2 shows a user command waiting over 250 ms.

### 3.7 Persistence

One key, `hue_housekeeping` = `{ v = 1, bridge_id, tasks = { [name] = { at,
ok, text, runs, fails } } }`, wall-clock seconds, written once per finished
run of a persisted task only (a few writes a day, not one per reconnect).
Read at late init; a value from the future (clock jump) counts as now; a
`bridge_id` other than the paired one discards the table.

## 4. Observability and the one control

- **One status row, `Housekeeping`** (read-only; the list-row mechanism of
  `show_list`, `driver.lua:630-644`). Summary: "On; all current (full 06:12,
  quick 14:05); next check about 20:05" / "On; paused: bridge not answering
  since 13:40" / "Off: only the resync after each stream connect runs".
  Drop-down, one line per task: last run, result, requests, runs and
  failures today; plus "Requests this hour: 18 of 60" and "Stream reconnects
  today: 7" (the #65 number, read off the row). It can absorb `Events
  Received` and `Last Event`, so the count of rows need not grow.
- **Attention** only when the owner can act (the lines in §3.5, and "Lists
  could not be read for 6 h: <error>"). Offers (new lights, names, rooms)
  stay the modules' own Attention items, worded as today.
- **Last Action** is not written by background tasks: it is "the result of
  the last click" ([edge-cases-ux.md](edge-cases-ux.md) §1), and a resync
  writing it would erase the click's answer. Clicks that run a task (Refresh
  All) keep writing it, with the list summaries of
  [list-rows-design.md](list-rows-design.md) §2.
- **Log**: one info line per run ("housekeeping: quick resync after
  watchdog reconnect: 15 requests, 0.8 s"); request lines in Debug Mode.
- **The control.** Compared on the Apple test (nothing to learn):

| | One `Automatic Housekeeping` On/Off | One setting per task |
| --- | --- | --- |
| What the installer must understand | "the driver looks after itself" | resync tiers, cadences, key checks |
| Principle 3 (stoppable by one setting) | yes | yes, but ten of them |
| Support | Off reproduces beta 7 exactly; one question to ask | many combinations to reproduce |
| Tuning | constants in code, changed by release with a spec | owner-side tuning nobody asked for |

Recommendation: **one setting, default On.** Off keeps the essential class
(the resync after each connect, the identity, TLS and stream retries,
clicks), so Off is beta 7 and the setting is also the rollback switch.

## 5. Task catalogue

Requests are GETs to the bridge per run. "Automatic" and "offered" follow
the edge-case rules; the per-family decisions belong to
`docs/simplify-research-import.md` and `docs/simplify-research-maintenance.md`
(not yet written when this was).

| Task | Purpose | Trigger | Cadence, jitter | Requests | Guards | Automatic / offered | Status text | Failure |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `resync` (essential) | state truth after missed events | `connect` (debounce 2 s), `click` (Refresh All) | after every connect; full at the first of a run, after an error reconnect or an outage over 10 min, quick after a silence reconnect | 15-17 full, 14-16 quick | paired, identity, key | caches, state fan-out, gone/back marks, counts (as beta 7) | "quick resync after watchdog reconnect 14:05: OK" | backoff 60 s → 15 min while the stream stays up (today: none) |
| `safety_resync` | net under the stream | `timer` | quick if none for 6 h, full if none for 24 h; ±10 % | 15-17 | + stream up | as `resync` | "full 06:12" | backoff, cap 1 h; Attention after 6 h of failures |
| scene list refresh | the 351 KB catalogue, scene names | inside full tier; `event` for an unknown scene rid | daily via full | 3 of the full | not within 5 s of a user write | catalogue, Hue Scene names; Adopt Hue Name stays offered | "scenes: 129 on bridge …" | as above |
| `stale_cache` | an update for a rid the caches lack (`bridge/lights.lua:1013-1014` and peers) or an `error` container | `event` | debounce 10 s, gap 10 min | one quick resync | stream up | caches | "quick resync: event for an unknown light" | backoff |
| new lights, scenes, sensors | notice and offer | already event-driven (`driver.lua:806-812`) and every resync | none extra | 0 | | **offered only**: Attention and Import All New …; AddDevice from an event, resync or startup is forbidden | module Attention, as today | n/a |
| name and room drift | notice | events, resyncs | none extra | 0 | | **offered**: Adopt Hue Names, Room Audit; no RenameDevice without a click | as today | n/a |
| removed on the Hue side | mark gone | `delete` events (`bridge/lights.lua:996-1006`), full GET absence | via `resync` | 0 extra | a *successful* full GET only | gone mark automatic; Re-link and Forget offered; never delete or unbind | Light Status, Attention | a failed GET marks nothing (`bridge/motion.lua:1286-1300`) |
| `identity` | bridge id, model, name, firmware rows; a different bridge at the address before the key goes out again | `timer`, `connect` after an error | daily ±10 %; after error reconnects | 1 unkeyed | address set | rows; stopping keyed traffic on a mismatch (safe) | "bridge checked 03:10" | Away state (§3.5) |
| `key_recheck` | lift a false key lock | while `key_rejected` | 5 min doubling to 1 h | 1 keyed, only after identity passed | identity | clears the lock and restarts the stream (Test Connection's path, `driver.lua:1374-1382`) | "key refused; checked again 14:35" | stays locked; Pair Bridge offered |
| identity retry | reach the bridge again | Away | 30 s doubling to 5 min (today fixed 30 s) | 1 unkeyed | | | Status as today | Attention after 1 h |
| stream health | watch, do not duplicate, the stream's own retries | stream status | event | 0 | | restart a wanted stream once the key re-check passes; reconnects counted | "stream: 7 reconnects today" | Attention after 1 h down |
| stream-down poll | keep state current without a stream | stream down 5 min, bridge answering | 30 min | 14-16 | identity, key | as `resync` | "stream down; lists read 14:05" | backoff |
| `rows` | time-based Attention (24 h offline, 1 h motion) | `timer` | at the next item's due time, at least hourly | 0 | | display | | |
| motion stuck check | stays in `motion.lua` (real time) | its own tick | unchanged | 1-3 | its GETs pass the user gate | as today | | as today |
| pin re-check | not needed: TLS checks run per start and address, the network one per Director version, and a Director update restarts the driver (`bridge/netcheck.lua:39-47`) | | | | | | | |
| update available, address discovery | **out**: no phoning home | | | | | | | |

**Daily cost**, on top of what the stream's reconnects already cause: at
most 3 quick + 1 full safety resync (≈65 GETs, ~1.3 MB) when the stream
never reconnects, plus 1 identity GET; 0 when it reconnects at least every
6 h. Against beta 7, tiering saves ~350 KB of transfer and a 1 s decode per
silence reconnect.

## 6. Test strategy

**Fake runtime** (`tests/helpers/fake_c4.lua`), backward compatible:
- `SetTimer` records `armed_at = c4.now_ms`; new `c4.advance(ms)` moves the
  clock in steps and fires, in due order, each active timer whose
  `armed_at + delay` has passed (one-shots retired, repeating ones re-armed
  with their skip count). `fire_timers` stays as it is.
- `c4.in_flight()` counts started transfers without `done`, so specs can
  assert one engine request at a time.
- `fake.load_driver(..., { persist = previous.C4.persist })` for restarts;
  specs call `OnDriverLateInit("DIT_STARTUP")` or `("DIT_UPDATING")`.
- A shared `answer_bridge(env, bodies)` lifted from
  `tests/spec/roundtrip_spec.lua:36-58`, answering resource GETs by path.

**Module spec** (`tests/spec/housekeeping_spec.lua`), with an injected clock,
timer and HTTP, no driver:
- `define` validates fields; the alarm is armed for the earliest due task
  and never more than 1 h ahead.
- Budget: 48 simulated hours of random triggers (fixed seed table) never
  exceed a run's budget or 60 optional requests in any rolling hour.
- One job: `in_flight` never exceeds 1; a second due task waits.
- No storm at boot: all tasks persisted as two days old, `DIT_STARTUP`: no
  optional request before 300 s plus jitter, then ≥ 30 s between runs.
- Backoff: failures give 60, 120, 240 … s up to the cap; a success resets.
- Coalescing: 40 pokes in 5 s give one run; a poke during a run gives one
  more, and every waiting caller is answered once.
- Persistence: a finished run survives a restart and is not repeated
  before its interval; a future timestamp counts as now; another bridge id
  discards the table.
- User first: with `user_active()` true no request starts; it starts 250 ms
  after it turns false; after 10 s it starts anyway; no `/scene` GET within
  5 s of a user write.
- Pause and resume: Away pauses optional tasks; reset by generation drops a
  late answer; key refused runs only `key_recheck`.
- Off: only essential tasks run; On runs due ones after a short delay.

**Driver spec** (`tests/spec/housekeeping_driver_spec.lua`): with the
bridge loaded and paired, a connect gives one quick or full resync as the
tiers say; 40 `add` events give one resync at most; a slider drag during a
safety resync sends its PUT before the next engine GET; Off reproduces beta
7's request sequence (a golden list from today's `drivers_spec.lua` flow);
the `Housekeeping` row and Attention lines read as §4.

## 7. Verdicts

Actions the engine replaces or feeds. The other families (Add, Import,
Re-link, Forget, Adopt, Map, Room Audit, motion) are the import and
maintenance files'; the engine only notices and offers for them.

| Action | Verdict | Reason |
| --- | --- | --- |
| Refresh All | **KEEP** | The one "do it now" click, rerouted through the engine as a full resync that takes the lock; when the key is refused it runs the key re-check first, which is how Test Connection's role folds in. |
| Refresh Scenes | **MERGE into Refresh All** | A subset of Refresh All (#324); the daily full tier keeps the catalogue fresh. |
| Test Connection | **MERGE into Refresh All** | Its jobs (identity, key check, lifting a false lock, restarting the stream; `driver.lua:1331-1384`) become the `identity` and `key_recheck` tasks plus Refresh All's first step; its answer moves to Status and the `Housekeeping` row. |
| Connect Event Stream | **AUTOMATIC** | Trigger: stream health, whenever the stream is wanted and allowed (paired, identity passed, key accepted, transport not Off); Status and `Event Stream` say why when it is not. |
| Disconnect Event Stream | **SETTING** | `Event Stream Transport` gains `Off` (default stays Network connection); unlike the action it survives a restart (`driver.lua:2321-2323` starts the stream at every late init). |
| Refresh From Bridge (Hue Motion) | **AUTOMATIC** | The device's hello at late init and every resync push its state already; the maintenance file has the final word. |
| Connection Test, Reload Credentials, Check CA Pinning (dev builds) | **KEEP** | Dev-only already (`driver.xml:523-552`); no engine task replaces a pin check (§5). |

## 8. Risks and open questions for the owner

**Questions** (each answer one word; the recommended one first):

- **Q1.** One `Automatic Housekeeping` setting, default On, Off = beta 7?
  **Yes.** Per-task settings would be the opposite of the goal.
- **Q2.** Tier the resync (#65): no `/scene` after a silence reconnect, full
  daily and after errors? **Yes.** Side effect: a scene edited in the Hue app
  during a quiet stretch shows up at the next full resync (its `add`,
  `update` and `delete` events still arrive live).
- **Q3.** Re-check a refused key by itself (5 min doubling to 1 h, only to
  the verified bridge)? **Yes.**
- **Q4.** Background results in a new `Housekeeping` row, never in Last
  Action? **Yes.**
- **Q5.** No address discovery (no phoning home); Attention after 1 h
  instead? **Yes.**
- **Q6.** REST over a network connection now? **No**, revisit on evidence
  (Q-M2).

**Measurements** (each under a minute, read by the Windows session, no
hands needed; anything longer is parked for 1.2):

- **Q-M1** (#65): read the bridge's `Event Stream` row now and once more
  later the same day; the "(N reconnects since …)" text gives the silence
  reconnect rate, which sizes Q2's saving.
- **Q-M2**: on the next dev-loop round, click Refresh All and move one
  slider within a second; the Debug Mode log gives how long the PUT waited.
  Over 250 ms reopens §3.6.
- **Q-M3**: the first build that logs the DIT value at late init answers
  what OS 3.4.x passes; no extra step.
- Parked: whether a one-shot timer of an hour fires on time (capped at 1 h
  anyway); clock jumps at boot (guarded); OS 4.x decode time of `/scene`.

**Risks:**

- Routing the connect resync through the engine touches the most-used path;
  mitigated by keeping it essential, immediate (2 s debounce) and covered
  by the golden "Off = beta 7" spec.
- The 10 s starvation cap lets an engine GET overtake a long slider drag
  once; acceptable, since it is one GET.
- A deterministic jitter makes every installation's own pattern repeat; with
  one bridge per controller that is a feature for support.
- `Attention` lines for "away an hour" could nag in houses that switch the
  bridge off at night; they clear themselves on the next answer.
- The rows timer is not cancelled in `OnDriverDestroyed` today; harmless on
  an update (Director kills timers, SDK `22/_24`) but a dev reload leaves the
  old one firing **[assumed]**; the engine's `stop()` ends that.
