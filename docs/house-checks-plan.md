# House checks: one round for #431, #65, #40 and #238

Status: plan, 2026-11-09. Written against `main` at release 1.4 build 565
(`docs/status.md`). The owner said yes to all four issues on 2026-11-09. This
is not a feature contract: it plans verification. It has findings with
citations, decisions, the checks, one ordered house round and the owner
questions. No driver code is needed for the round itself (section 7).

Current (2026-11-13, #478): the round ran in part on 2026-11-10, after the
owner's reboot, on dev build 604 with no owner hands: #238 held, and #65
read 82 reconnects in 24 h. The owner skipped the bedroom visit (B1 to B3)
and #40's (a) and (b) ("assume they pass"), and all four issues were closed
that day (`docs/status.md`).

## Contents

- [Summary](#summary)
- [1. Findings](#1-findings)
- [2. Decisions](#2-decisions)
- [3. The checks, issue by issue](#3-the-checks-issue-by-issue)
- [4. The house round](#4-the-house-round)
- [5. Control4 guidelines](#5-control4-guidelines)
- [6. Lifecycle edge cases](#6-lifecycle-edge-cases)
- [7. Code work](#7-code-work)
- [8. Composer checklist text](#8-composer-checklist-text)
- [9. Reboot and changelog](#9-reboot-and-changelog)
- [10. Open questions for the owner](#10-open-questions-for-the-owner)

## Summary

Four open hardware checks go into one house round around the 1.5 install
and the controller reboot it needs. The 1.5 contracts are being written now
(`docs/turn-on-design.md` and its siblings); their own house checks slot
into the same round (section 4).

- **#238** (no device marked unbound after a reboot) is read from the dev
  loop's shipped log and property snapshots right after the reboot. No owner
  step beyond the reboot itself.
- **#65** (reconnect rate, event rate, catalogue skip): the reconnect count
  is read off 1.4's `Event Stream` row before anything restarts the bridge.
  It is days of data at no wait. The event rate is already measured. The
  catalogue skip after a watchdog reconnect **already shipped in 1.2**
  (#334). Recommendation: keep it, record the numbers, close the issue.
- **#431** (Advanced Lighting Scenes, tile taps, colour tracking): two
  temporary lighting scenes built by the Windows session, one bedroom visit
  by the owner (keypad holds and tile taps), every device's commands
  captured in one log by the dev loop.
- **#40** (time-of-day scenes), re-checked against today's code: the keypad
  pass (a) and Recall As after a cross-kind re-link (b) still make sense. A
  dim before a slot boundary (c) is opportunistic. API-made schedules (d)
  and V8 (e) are obsolete for the driver and are dropped (section 3.4).

Closes, when the round is written up: #238, #65, #431, #40. Any deviation
becomes its own issue.

Owner moments: **two**. A reboot from System Manager, and one bedroom visit
of about six minutes in three short blocks (section 4.3).

## 1. Findings

Claims are marked [verified] (read in the code or the docs, with the place)
or [assumed].

### 1.1 Tools and limits that shape the round

- **Startup logs cannot be read from Composer.** The Lua Output pane shows
  only lines that arrive while that device's Lua tab is open
  [verified: `docs/composer-remote.md` rule 13]. A reboot's first minute is
  therefore invisible from Composer.
- **The dev loop captures the log from the end of the bridge's late init.**
  `devloop.start` is called at the end of `OnDriverLateInit` and wraps
  `print` there [verified: `docs/dev-loop.md` "Bridge", first bullet;
  `src/common/devloop.lua:1316`]. Lines logged earlier in late init are not
  shipped. The light and scene devices forward their lines to the bridge
  (`HUE_LOG`) and keep the newest 30 until the bridge is known [verified:
  `src/common/devloop.lua:89`, `:1460`]. So one shipped log holds every
  device's commands, which one Composer Lua pane cannot.
- **Proxy commands are logged with Debug Mode On.** Every proxy command a
  device receives is logged as `ReceivedFromProxy <binding> <command>` at
  debug level, and one with no handler as `no proxy handler for <command>`
  [verified: `src/common/dispatch.lua:24`, `:54`]. Debug Mode On lowers the
  threshold to debug; Off keeps warnings and errors [verified:
  `src/common/log.lua:19-21`]. The light and scene drivers both have the
  property [verified: `src/hue_light/driver.xml:28`,
  `src/hue_scene/driver.xml:28`].
- **The dev loop can drive any device's proxy.** `Proxy Command` sends a
  light_v2 command to a light, zone light or scene device as a Navigator
  would [verified: `src/hue_bridge/bridge/devtools.lua:425-446`].
  `ON`, `OFF`, `SET_LEVEL` and `RAMP_TO_LEVEL` work that way. A colour
  temperature cannot be injected, since the proxy forwards
  `SET_COLOR_TARGET` with mode 0 [verified: `docs/design.md`, "Hardware
  pass of 2026-10-25 night"].
- **Capability changes need the owner's reboot.** Composer's "Restart
  Director?" Yes does not load the new capabilities or code. The devices
  keep the old ones until the owner reboots the controller from System
  Manager, which the Windows session cannot operate [verified:
  `docs/composer-remote.md` rules 9 and 10]. A reboot takes Composer about
  eight minutes to see Director again (19:12:58 to 19:20:35 on 2026-10-22)
  [verified: `docs/composer-checklist.md` step 13].
- **Going back to a release over a newer dev build is handled.** The install
  brief tells the Windows session to answer "Overwrite Driver or Agent?"
  ("Current version is newer") with Yes [verified: `tools/deploy.py:1011`,
  #365].
- **Connections can be changed by the Windows session** with synthetic drags
  and read back [verified: `docs/composer-remote.md` rule 18 and "Learned
  2026-10-27"].
- **The bedroom keypad.** The "Bedside Lights Switch" is a Control4 switch
  run as a two-button keypad. Its top and bottom buttons are bound to
  Golden hours' Top and Bottom Button Links (read 2026-10-27). The LED pass
  for that binding is still the owner's [verified: `docs/status.md`,
  "Devices" and "Keypads"].
- **Every bedroom device covers the same two lamps.** The Master Bedroom
  holds just the two bedside lamps; the Bedside Lights zone light, the
  Master Bedroom room light, Shine and Golden hours all act on them. The two
  single-light Hue Light devices are the motion programming's lamps
  [verified: `docs/status.md`, "Devices"; `docs/smart-scenes-research.md`
  §7b, first line].
- **Controller OS.** The diagnostics of 2026-10-26 report OS 3.4.3; earlier
  notes say 3.4.2 [verified: `docs/status.md`, "Controller OS"]. Both are
  past 3.3.2, so the newer Navigator turn-on applies (section 1.4).

### 1.2 #238: the unbound-at-startup risk

- At late init the bridge reconciles its registries against
  `GetBoundConsumerDevices`, then calls `confirm_unbound_later`
  [verified: `src/hue_bridge/driver.lua:2333-2338`]. A nil answer is read as
  "unknown". A second nil at least `NIL_CONFIRM_S` (5 s) later is read as
  "nothing bound" [verified: `src/hue_bridge/bridge/project.lua:92-120`].
  `confirm_unbound_later` re-runs every module's reconcile 6 s later when
  the lookup answered nil [verified: `src/hue_bridge/driver.lua:1911-1926`].
- A reconcile that marks an entry unbound logs
  `<module>: <name> (device N) is not bound to this bridge` at warn level
  [verified: `src/hue_bridge/bridge/owner.lua:840-842`] and stamps
  `unbound_since` [verified: `src/hue_bridge/bridge/registry.lua:36-47`].
  The next reconcile that sees the binding relinks it
  [verified: `registry.lua:530-533`]. So a short false mark can heal by
  itself and leave no trace in the properties; only the log shows it.
- The 6 s reconcile runs after the dev loop has started, so its warnings
  would be shipped. The startup reconcile's own info line
  (`startup reconcile: …`) comes before the loop starts and is not
  [verified: the order in `driver.lua:2333-2338` and `docs/dev-loop.md`
  "Bridge"].
- Earlier reboots: 2026-10-22 and 2026-10-24 (release builds, device side
  only) and 2026-10-25 night (dev build 284): every device was bound within
  seconds and none logged "still not bound" [verified: `docs/composer-checklist.md`
  step 13; `docs/design.md`, "Hardware pass of 2026-10-25 night", item
  "Issue #41"]. Whether build 284 already carried the two-step nil
  confirmation is not recorded [assumed: no reboot since has been checked
  for it]. No release since 1.0 changed capabilities, so no reboot has
  happened since 2026-10-25 [verified: `docs/status.md`, beta 3 and beta 4
  entries: "no capability change since 1.0"].

### 1.3 #65: what the code does today

- **The transport.** The event stream runs on a network connection by
  default (`Event Stream Transport` "Network connection") [verified:
  `src/hue_bridge/driver.xml:259-265`; `src/hue_bridge/driver.lua:282-285`].
  On that transport the `Stream Timeout (s)` is ignored: the connection
  lives until it drops, the watchdog fires or the owner stops it
  [verified: `src/hue_bridge/bridge/netstream.lua:61-62`]. The issue's
  premise "the idle chain is hourly at most" (the 3600 s timeout) belongs to
  the old `C4:url` transport.
- **The watchdog.** 600 s of silence (no event, no keepalive) ends the
  connection with the reason `watchdog: no data for 600 s`
  [verified: `netstream.lua:129`, `:518-538`]. The bridge sends no keepalive
  [verified: `docs/design.md`, "The bridge sends no keepalive on the
  stream"]. So a quiet house reconnects at most every ten minutes, at most
  144 times a day.
- **The measured rate.** On 2026-11-05 the row read 664 reconnects in about
  8 days on the network-connection transport: about 83 a day, one every
  17 minutes on average (issue #65, comment of 2026-11-05). That fits
  watchdog reconnects in quiet hours.
- **The split resync shipped in 1.2.** A connect's resync is **full** at the
  first connect of the run, after an error reconnect and after an outage of
  600 s or more; it is **quick** (no `/scene` and `/smart_scene`) after a
  silence reconnect [verified: `src/hue_bridge/bridge/away.lua:238-253`,
  `RESYNC_FULL_OUTAGE_S` at `:81`; `src/hue_bridge/driver.lua:702-741`, the
  quick tier skips `scenes:resync`]. Contract text:
  `docs/simplify-actions-design.md` §3.1 ("This is the #65 split"). Specs:
  `tests/spec/away_spec.lua:307-319`. A full read also runs when none ran
  for 24 h, a quick one when none ran for 6 h [verified:
  `src/hue_bridge/bridge/tasks.lua:157-165`]. A full chain is 17 GETs on a
  Bridge Pro, the quick one 2 fewer [verified: `tasks.lua:59-61`].
- **The issue comment of 2026-10-25 declined the skip.** It assumed the
  hourly timeout capped resyncs. 1.2 then took the scheduler research's
  tiering instead. So the decision the issue asks for has been made and
  built, with contract text and a spec; the issue was not updated.
- **The counter.** The `Event Stream` row counts reconnects since the driver
  started: `Connected since 23:11:46 (2 reconnects since 10-25 23:11)` after
  a connect, `Connected since …, 120 containers, last …; 2 reconnects` after
  events [verified: `src/hue_bridge/driver.lua:800-830`]. A driver start
  (install, reboot) resets it. Nothing records the reasons or the tiers
  across a run; with Debug Mode On they are logged
  (`event stream ended: <reason>` at info, `scene resync skipped (quick
  resync)` at info) [verified: `netstream.lua:998`, `driver.lua:716`].
- **The event rate** is measured and recorded: during a 5 s slider drag on a
  zone light the Bridge Pro sent 10 containers in about 7 s, at most 2 a
  second (dev build 284) [verified: `docs/design.md` "Hardware pass of
  2026-10-25 night", item "Issue #65"; `docs/status.md`, "On 2026-10-25"].

### 1.4 #431: what the drivers and docs say

- **Reduced ALS.** All three device kinds declare `reduced_als_support`
  [verified: `docs/c4-lighting-guidelines.md` row L62]. With it, a scene
  activation reaches each member as its own `SET_BRIGHTNESS_TARGET` and
  `SET_COLOR_TARGET`, and a driver must support `SET_BRIGHTNESS_TARGET`,
  `RAMP_SCENE_UP`, `RAMP_SCENE_DOWN` and `STOP_SCENE_RAMP` [verified:
  `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/45_Light_V2_advanced_lighting_scene/_1.3-REDUCEDALSSUPPORT.md`].
- **The drivers handle `STOP_SCENE_RAMP` but not `RAMP_SCENE_UP` or
  `RAMP_SCENE_DOWN`.** `STOP_SCENE_RAMP` is an alias of
  `SET_BRIGHTNESS_STOP` [verified: `src/hue_light/driver.lua:1184`,
  `src/hue_scene/driver.lua:1507`]. No handler exists for the two ramps
  [verified: grep of `src/`]. Whether the agent sends them to a reduced-ALS
  member, or sends a timed `SET_BRIGHTNESS_TARGET` instead, is not
  documented [assumed]. The held-button check answers it.
- **A brightness stop stops at Hue** on lights and zone lights since 1.4
  (#421 D7) [verified: `src/hue_light/driver.lua:1160-1174`]. A grouped_light
  honours an absolute duration (Z1) and the gliding stop (Z2) [verified:
  `docs/tap-stop-design.md` §10].
- **A timed level move on a scene device is probably not a ramp.** The scene
  driver turns `SET_BRIGHTNESS_TARGET` / `RAMP_TO_LEVEL` with a time into
  `HUE_SCENE_LEVEL` [verified: `src/hue_scene/driver.lua:1486`, `:1752`],
  which the bridge sends as a grouped_light `dimming_delta` with the rate as
  duration [verified: `src/hue_bridge/bridge/scenes.lua:2104-2160`]. A
  grouped_light ignores the duration of a `dimming_delta` and covers the
  change in about a second (departure D1, #249) [verified:
  `docs/c4-lighting-guidelines.md` §5 D1]. `docs/group-hold-design.md` §5
  lists this path as not measured. So an ALS ramp on a scene device is
  expected to jump [assumed until measured; check T1 below].
- **Tile taps.** From OS 3.3.2 Navigators turn lights on and off with
  `DYNAMIC_ON` / `DYNAMIC_OFF` [verified: `.../10_light_v2_commands/_1.3-DYNAMICON.md`].
  With `brightness_on_mode_previous`, the proxy answers a generic on by
  sending the driver a `SET_BRIGHTNESS_TARGET` at the last non-zero level
  [verified: `.../5_light_v2_capabilities/_7-brightnessonmodeprevious.md`].
  1.5 replaces `supports_default_on` with the On Mode capabilities (#429).
  So the command a tap arrives as changes with 1.5, which is why the owner
  put #431 after it. What arrives under Preset mode, and whether a colour
  target comes with it (#427), is [assumed] until seen.
- **Colour tracking.** `color_trace_tolerance` sets the colour difference
  under which two colours count as the same for Advanced Lighting Scenes
  and programming. The default is a CIELab delta of 1.0. It is a dynamic
  capability [verified: `.../5_light_v2_capabilities/_13.5-COLORTRACETOLERANCE.md`].
  The drivers do not declare it [verified: row L37]. Hue moves xy into the
  bulb's gamut and stores temperature in whole mirek (departure D8)
  [verified: `docs/c4-lighting-guidelines.md` §5]. Whether a delta of 1.0
  absorbs that is the question.

### 1.5 #40: today's scene driver against each point

- **(a) The keypad on a time-of-day scene.** Every step a1–a8 was run through
  the devices' Lua windows on 2026-10-25 and did what the plan expected;
  the LEDs were left for the owner [verified: `docs/smart-scenes-research.md`
  §7b, "(a)"]. Since then: 1.3 makes a hold on a room with a running
  time-based scene use timed group steps so the schedule keeps running
  (G6a), not yet seen on the house [verified: `docs/smart-scenes-design.md`
  Decision 6, "Current (1.3, #249)"; `docs/status.md` "Before 1.4", list of
  unchecked lamp behaviour]. 1.4 keeps time-based taps instant (S-D5) and
  adds the double-tap window [verified: `docs/tap-stop-design.md` S-D5;
  `docs/composer-checklist.md` step 98, open]. The Bedside Lights Switch is
  already bound to Golden hours (1.1). **Still makes sense**, and now covers
  more.
- **(b) Recall As after a cross-kind re-link.** The code is unchanged: a
  configure that changes the kind calls `apply_recall_as`, which shows the
  row with `C4:SetPropertyAttribs("Recall As", 0)` [verified:
  `src/hue_scene/driver.lua:1164-1182`, `:1233-1244`]. That call follows
  three `UpdateProperty` calls in the same burst. Composer has dropped a
  show and a hide that arrived in the same burst as text updates (builds
  243, 245), which is why the bridge's own rows send visibility 400 ms and
  1.5 s after their texts [verified: `src/hue_bridge/bridge/rows.lua:35-42`].
  So "0 shows" works on this Composer, but the scene's show may be dropped.
  **Still makes sense.** Two things changed the method: Re-link Scene is now
  an alias of Link Device [verified: `src/hue_bridge/bridge/actions.lua:1200`],
  and a re-link renames the Hue target to the device's Composer name
  [verified: `src/hue_bridge/bridge/names.lua:1056-1090`, Q6 of
  `docs/simplify-actions-design.md` §3.1]. Re-linking the real Golden hours
  device to Arise, as §8(b) planned, would rename Hue's "Arise" scene. The
  check therefore uses throwaway probe resources (section 3.4).
- **(c) A dim before a slot boundary, then the advance.** The driver does
  not depend on the answer: it follows Hue's state, and a whole-room dim
  keeps a schedule active (V11) [verified: `docs/smart-scenes-design.md`
  Decisions 2 and 6]. The answer is a Hue fact for the manual (whether the
  next slot's look replaces the dimmed level). It needs a real app-made
  boundary (16:00 Shine, 07:00 Arise, or a sunset slot) inside the round.
  **Makes sense only opportunistically.**
- **(d) Do API-made schedules advance?** Three API-made schedules never
  advanced; the remaining run needs a 30-minute slot, which the owner
  stopped because no test may wait that long [verified:
  `docs/smart-scenes-research.md` §7b "(d)"]. The driver never creates
  schedules; it plays the ones made in the Hue app, so nothing in it
  changes either way [verified: §8(d) step 3]. **Obsolete for the driver.**
- **(e) V8, the whole-house dynamic scene.** §8(e) already recommends not
  running it on Whole House: deactivating leaves every light where the slot
  put it (V7). Its question (does a schedule play an `auto_dynamic` slot
  dynamically) leaves the contract unchanged either way: Recall As stays
  hidden on time-based devices and their on state is Hue's `active`
  [verified: `docs/smart-scenes-research.md` §8(e) "Reading";
  `docs/smart-scenes-design.md` Decisions 2 and 12]. **Obsolete for the
  driver.** V8 itself runs only if the owner asks, at a time he picks, with
  his yes then.

## 2. Decisions

- **D1. One round, one dev install, one reboot.** The dev build of the 1.5
  candidate (`main` with every 1.5 PR merged, built with `tools/build.sh
  --dev`) is installed once, before the reboot. The reboot then loads 1.5's
  capabilities and code with the dev loop in it. The checks run. The 1.5
  release is cut afterwards from `main` (it then also carries the round's
  doc commits and any Lua-only fix) and installed over the dev build: same
  capabilities, so no second reboot [assumed: Composer asks "Restart
  Director?" only when capabilities differ, as rule 10 describes]. This
  runs #431 on 1.5's code, as the owner asked, and gives #238 its strongest
  evidence. It departs from the owner's wording "after 1.5 is installed",
  so it is question Q1; the alternative order is in section 4.4.
  Reason: two installs instead of three; the reboot's first minute is in
  the shipped log; Lua fixes found in the round can still ride 1.5.
- **D2. #238 is read on the VM.** From the shipped log and the property
  snapshots the dev loop sends, not from Composer's Lua pane (rule 13). The
  Windows session reads `Attention` and the summary rows as a second source.
- **D3. #65's reconnect count comes from 1.4's row**, read by the Windows
  session as the first step of the round, before the dev install restarts
  the bridge. It holds every day 1.4 has run. The reason and tier mix comes
  from the dev window's shipped log, as a bonus. The event rate is not
  measured again.
- **D4. The watchdog catalogue skip stays as 1.2 built it** (section 3.2,
  recommendation). #65 closes with the numbers.
- **D5. #431 uses two temporary lighting scenes.** Scene A: one
  single-light Hue Light in a colour and the Bedside Lights zone light at a
  colour temperature. Scene B: Shine alone. Reason: every bedroom device
  covers the same two lamps, and a scene with both the zone light and Shine
  would set those lamps twice, so tracking would depend on which command
  landed last. The Windows session builds them, assigns them to the
  bedroom switch for the visit, and removes them afterwards.
- **D6. A tool-only pre-check of timed moves (T1)** runs before the owner's
  visit: `RAMP_TO_LEVEL` with a 10 s time on Shine, the zone light and the
  single light, through `Proxy Command`, with the bridge's level reports in
  the log. It shows in advance whether the scene device jumps (D1 of the
  guidelines), so the owner's hold confirms rather than discovers.
- **D7. Tracking is judged twice.** The owner glances at the scene button's
  LED. The VM computes the colour difference between the target the agent
  sent (`SET_COLOR_TARGET` in the log) and the colour the driver reported
  (`LIGHT_COLOR_CHANGED`, from Hue's report). A difference above 1.0 with
  the LED dark is a finding for `color_trace_tolerance`.
- **D8. #40:** (a) runs in the owner's visit; (b) runs tool-only with probe
  resources; (c) runs only if an app-made slot boundary of Golden hours
  falls inside the dev window, otherwise it is written down as parked with
  no driver consequence; (d) and (e) are dropped with their reasons in
  `docs/smart-scenes-research.md` §7. #40 then closes.
- **D9. The owner's hands only where needed.** Two moments (section 4.3).
  Installs, properties, Debug Mode, Connections, lighting scenes, the probe
  and every reading are the Windows session's or the VM's. Tile taps are
  the owner's because Composer has no Navigator [assumed: no Control4 app
  on the Windows VM; if there is one, the Windows session taps instead].
- **D10. No step waits more than about a minute for the owner.** The
  Windows session's rebinding runs while the owner taps tiles. Long
  horizons are counters read later (#65) or skipped (#40 d).
- **D11. Debug Mode goes back Off** on the bridge and the three devices
  before the release install (`deploy/house.yaml` wants the bridge Off;
  `docs/dev-loop.md` "Leaving the loop").
- **D12. Results.** Each issue gets a comment with the hardware facts and is
  closed with a line naming the PR and the build. The round is posted to
  Discussions (Show and tell) with placeholders for private data. Any
  deviation becomes its own issue, labelled and on board 1, before the
  round's write-up is merged.

## 3. The checks, issue by issue

Names by role: **L** = the single-light Hue Light chosen for the check (one
of the two motion programming lamps), **Z** = the Bedside Lights zone
light, **S** = the Shine scene device, **G** = the Golden hours scene
device. Device ids and rids are read at run time and never written into the
repo.

### 3.1 #238: no device marked unbound after the reboot

| | |
|---|---|
| What | After the reboot from System Manager, no registered light, scene, zone light or motion device is marked unbound. |
| Who | VM (`tools/devctl.py`), Windows session as a second source. |
| When | Phase 4 of the round, from the moment the dev loop reports in after the reboot. |

Steps:

1. Before the reboot (phase 2): the Windows session sets the bridge's
   `Debug Mode` On and reads `Attention`, `Lights`, `Scenes` and `Zone
   Lights` as the baseline (no "unbound" anywhere).
2. After the reboot: `tools/devctl.py status` until `last_seen` is fresh
   and the versions match local.
3. At about 1 minute and again at about 5 minutes after the loop's
   `startup` report: search the shipped log (`build/dev/driver.log`) for
   `is not bound to this bridge`, `still not bound`, `unbound` and
   `[ERROR]`. Read the property snapshot (`devctl.py status` or a `wait`)
   for `Attention` and the three summary rows.
4. When Composer has Director again (rule 15): the Windows session reads the
   same rows and every device's `Status`.

Expected: no such line in the log; `Attention` has no unbound item; the
summaries carry no "unbound" count; every device shows its Hue state.

Deviation: any `is not bound to this bridge` line for a device that is
bound, even if it heals within a minute. New issue: after a reconcile that
unbinds at least one entry on a confirmed "nothing bound", reconcile again
at 30 s and 60 s, as the device side does (the fix the issue names). The
fact goes into `docs/design.md` "Project APIs".

Written: issue #238 comment and close; `docs/design.md` (binding at startup,
one line with the build and OS); `docs/status.md` "Open".

### 3.2 #65: reconnect rate, event rate, catalogue skip

| | |
|---|---|
| What | Reconnects per day on 1.4; the share of watchdog (quick) and other (full) reconnects; the event rate (already known). |
| Who | Windows session (one read), VM (log analysis). |
| When | Phase 1 (the read) and phase 7 (the log). |

Steps:

1. Phase 1, first step of the round, before any install: the Windows session
   reads the bridge's `Event Stream` row verbatim and the bridge's `Driver
   Version` (565). If the row shows the per-event form without a date, the
   start is 1.4's install time from the deployment record
   (`python3 tools/deploy.py status`).
2. Phase 7: count in the shipped log of the whole dev window
   `event stream ended: <reason>` by reason, `scene resync skipped (quick
   resync)`, and the housekeeping lines of `safety_quick` and `safety_full`.
   This is whatever the window happened to contain; nobody waits for it.

Expected: a rate at or below 144 a day (the watchdog's ceiling at 600 s),
near the 83 a day seen on 2026-11-05; the reconnects in the log end with
`watchdog: no data for 600 s` and are followed by a quick resync.

Deviation: more than 144 a day, or reasons other than the watchdog
(`connection closed`, `server closed the stream`) for most reconnects. Each
of those runs the full chain with the 351 KB catalogue. New issue: why the
network connection drops, with the log lines.

Written: `docs/design.md`, event stream section (beside the "at most one
container per second" bullet): reconnects per day on 1.4 and the tier mix;
`docs/status.md` "Open"; issue #65 comment and close.

**Recommendation on the watchdog catalogue skip: keep it as built.**

- It is already done: `away:connect_tier` returns "quick" for a silence
  reconnect after less than 600 s down, and `resync_all` then leaves out the
  scene catalogue (section 1.3). Contract text and specs exist.
- The visible cost the 2026-10-25 comment feared is close to nil. A watchdog
  fires only after 600 s with no event at all. A scene edited in Hue during
  that silence would have sent an update event and reset the watchdog
  [verified: scene edits arrive as update events, `docs/smart-scenes-research.md`
  §7 V13; containers carry every resource type, `docs/design.md` event
  stream section]. Only an edit in the few seconds of the reconnect itself
  can be missed, and the daily full read catches it.
- The gain is real on this transport: about 83 reconnects a day each avoid a
  351 KB GET and its decode tree (`docs/reviews/efficiency-2026-10-24.md`
  "Five lines": several MB transient).
- A further step, skipping even the quick read after a silence, is not
  proposed: the reconnect gap can still miss a light change, and the quick
  read is what covers it.

### 3.3 #431: Advanced Lighting Scenes, tile taps, colour tracking

| | |
|---|---|
| What | L63: a held scene button ramps L, Z and S and the release stops them. L37: scene A still tracks as active after it set a colour and a temperature. L22: the command a tile tap arrives as on 1.5. |
| Who | Windows session (scenes, bindings, Debug Mode), VM (log, T1, colour maths), owner (keypad holds, tile taps, watching the bedside lamps and the LEDs). |
| When | Phases 5 and 6, on 1.5's code. |

Preparation, tool-only (phase 5):

1. Debug Mode On on L, Z, S and G (Windows session, `Set-ComposerProperty`
   with Set, rule 7). The bridge's is On since phase 2.
2. **T1, timed moves.** With the bedroom off: `devctl.py run "Proxy
   Command" Light=<S> Command=ON`, then `Command=RAMP_TO_LEVEL LEVEL=20
   TIME=10000` from a higher level; the same for Z and for L at low levels
   (lamps at 1–20 %). Read the bridge's level reports for 12 s in the log.
   Expected: L and Z move over about 10 s (Z1). S: predicted to reach the
   level in about a second (section 1.4). Then OFF each.
3. The Windows session records the Bedside Lights Switch's Connections
   (both buttons to G's Button Links) for the restore.
4. It builds two lighting scenes in Composer's Advanced Lighting agent:
   - "Hue check A": L at 40 % in a saturated colour picked on the wheel
     (for example a deep blue); Z at 60 % at 2700 K.
   - "Hue check B": S at 50 %.
   The exact dialog fields, rates and button options are read in Composer
   first [assumed: the agent offers per-scene tracking, toggle and hold
   ramp options].
5. It removes the switch's two Button Link connections to G and assigns the
   top button to "Hue check A" and the bottom one to "Hue check B" in the
   agent's keypad settings, as a toggle with ramp on hold [assumed: the
   option names]. It reads both back.

Owner block B1, at the bedside switch (about 90 s; nobody on the stairs):

| Step | Owner does | Expected | Deviation means |
|---|---|---|---|
| A1 | Tap top | L at 40 % in the colour, the bedside lamps at 60 % warm white within a few seconds; the top LED lights and stays lit for 10 s | LED dark or blinking off: tracking fails (see D7) |
| A2 | Hold top about 2 s, release | the bedside lamps ramp smoothly, then stop where released | no movement: the agent sent `RAMP_SCENE_UP`/`DOWN`, which no driver handles; a jump: a ramp path that ignores the rate |
| A3 | Hold top again about 2 s, release | the same, in whatever direction the agent picks | as A2 |
| B1 | Tap bottom | Shine plays at about 50 %; the bottom LED lights; the top LED goes dark (the lamps changed) | bottom LED dark: tracking of a scene device fails |
| B2 | Hold bottom about 2 s, release | a ramp that stops at release; T1 predicts a jump instead | a jump confirms the scene device's departure (new issue below) |
| B3 | Tap bottom | the room turns off (L66: the toggle scene is off by default) | the room stays on |

VM reading of B1 (phase 7): for each step, the commands each device
received (`ReceivedFromProxy …`, `no proxy handler for …`), the CHANGING
and CHANGED each sent, the stop path taken, and Hue's reported levels. For
A1: the target xy the agent sent to L, the xy L reported, and the
temperature Z reported (mirek); compute the CIELab difference at equal
luminance [assumed: Control4 compares chromaticity; the doc does not say
which luminance], reporting both the 1976 and the 2000 formula, since the
doc names neither [verified: `_13.5-COLORTRACETOLERANCE.md` says only
"CIELab"].

Owner block B2, on the phone, while the Windows session restores the
switch (about 2 minutes):

| Step | Owner does | Expected (log) |
|---|---|---|
| T-L | L's tile: tap on, then off | what arrives is recorded; per the docs and 1.5 (#429), a `SET_BRIGHTNESS_TARGET` from the proxy at the On preset or the previous level; possibly a `SET_COLOR_TARGET` (#427) |
| T-Z | Z's tile: tap on, then off | the same |
| T-S | S's tile: tap on, then off | recorded; the scene driver's handling of what arrives |

Plus the tile checks the 1.5 contracts list, if any. Deviation: a `no proxy
handler for DYNAMIC_ON` (or `_OFF`) line, or a tap that does nothing. New
issue: handle `DYNAMIC_ON` / `DYNAMIC_OFF`. Any handled command with the
right result meets L22; the row's evidence then names it.

Meanwhile the Windows session removes the two lighting-scene assignments,
deletes "Hue check A" and "Hue check B", restores the switch's two Button
Link connections to G and reads them back (rule 18).

Possible new issues from #431 (only when seen):

- `RAMP_SCENE_UP` / `RAMP_SCENE_DOWN` arrive unhandled: handle them as a
  hold at the hold rate, through the shared keypad machine
  (`src/common/device.lua`). Lua only, no reboot.
- A scene device's timed level move jumps (T1, B2): route it through
  group_hold's per-lamp or stepped path, as holds do since 1.3
  (`docs/group-hold-design.md`). Lua only.
- Tracking fails with a measured difference above 1.0: declare
  `color_trace_tolerance` in the dynamic capabilities, sized from the
  measurement. Dynamic, so no reboot
  [verified: `_13.5-COLORTRACETOLERANCE.md`, "Dynamic Capability: Yes"].

Written: `docs/c4-lighting-guidelines.md` rows L22, L37, L63 (status,
evidence, note) and L65 if B2 says more; `docs/design.md`, a "House round
of <date>" section; `docs/status.md`; issue #431 comment and close;
`docs/composer-checklist.md` steps (section 8).

### 3.4 #40: time-of-day scenes

| Point | Verdict | Where answered or why |
|---|---|---|
| (a) The keypad on a time-based scene | Still makes sense; run in owner block B3 | Lua-window run passed on 2026-10-25 (§7b); the owner's LEDs, 1.3's G6a and 1.4's S-D5 are unseen |
| (b) Recall As after a cross-kind re-link | Still makes sense; tool-only | the show follows text updates in one burst, which Composer has dropped before (`rows.lua:35-42`) |
| (c) A dim before a slot boundary | Opportunistic | no driver consequence (Decisions 2 and 6); needs an app-made boundary inside the dev window |
| (d) API-made schedules | Obsolete; dropped | the driver never creates schedules (§8(d) step 3); the remaining run needs a 30-minute wait |
| (e) V8 | Obsolete; dropped | the contract stays either way (§8(e)); whole house switched; only on the owner's own request and yes |

**(a), owner block B3** (about 90 s, the switch bound to G again):

| Step | Owner does | Expected |
|---|---|---|
| G1 | Tap top | the schedule starts at once, no 3 s fade (S-D5); the top LED lights; G's Status "…; now <slot> (from <start>)" |
| G2 | Hold bottom about 1.5 s, release | the room dims in steps and stops at release; the schedule keeps running: G's Status unchanged, Hue `active` in the log (G6a) |
| G3 | Tap bottom | the schedule stops and the room turns off at once; LEDs follow (On State Follows default: the room's lights) |
| G4 | Hold top about 3 s from off | the schedule starts, then the room brightens until release (Decision 4) |
| G5 | Double tap bottom | off once; the second tap changes nothing (D4) |

This also covers `docs/composer-checklist.md` step 98 and the scene part of
the 1.3 lamp list (`docs/status.md`, "Before 1.4"). Deviation in any row:
new issue with the log lines.

**(b), tool-only** (phase 7, after the owner's visit, the bedroom off):

1. `python3 tools/smart_scene_probe.py create --room <bedroom> --light
   <one bedside lamp> --brightness 1` makes probe scenes A and B and the
   smart scene "c4-hue probe" (created active, V12; lamps at 1 %).
2. `devctl.py run "Add From Hue" What=scene:<probe smart rid>` creates a
   time-based scene device [assumed: a smart scene is offered under the
   `scene:` prefix, `src/hue_bridge/bridge/actions.lua:135`]. The Windows
   session reads its properties: no `Recall As` row.
3. `devctl.py run "Link Device" Device=dev:<id> To=scene:<probe A rid>`.
   Link Device takes a bound device through the dev loop: its kind is
   found through the Forget Device list when it is neither gone nor
   unbound [verified: `actions.lua:965-969`]. Hue's probe scene A is renamed
   to the device's name (harmless: deleted in step 6).
4. The Windows session reads the `Recall As` row at once, then after
   selecting another device and coming back.
5. Link it back to the probe smart scene: the row is hidden again.
6. `devctl.py run "Forget Device" Device=dev:<id> Confirm=…`, the Windows
   session deletes the Composer device, and `smart_scene_probe.py cleanup`
   deletes the probe resources (404 confirmed) and turns the lamp off.

Expected: shown at once (Decision 12 verified). Shown only after
re-selecting: a Composer refresh, noted in `docs/design.md`. Never shown, or
not until the next driver start: new issue, send the visibility again 400 ms
and 1.5 s after the configure, as `rows.lua` does for the bridge's rows
(the same applies to `src/hue_motion/driver.lua:417-433`).

**(c), only if a boundary falls in the window.** At the start of phase 5,
`devctl.py run "Hue Request" Method=GET Path=/clip/v2/resource/smart_scene/<G's rid>`
gives today's slot start times. If one falls inside the window and no
owner block is due within 20 minutes of it: §8(c) steps 1–5 as written
(start G about 10 minutes before, dim it from Control4 to about half 7
minutes before, read slot, Status and lamp level after the boundary, then
OFF). Otherwise §7 records (c) as parked: no driver consequence, the manual
keeps describing Hue's behaviour as assumed.

Written: `docs/smart-scenes-research.md` a new §7c (the round's results,
and (d) and (e) dropped with their reasons); `docs/smart-scenes-design.md`
Decision 12's "Not yet seen" line; `docs/status.md` "Open"; issue #40
comment and close.

## 4. The house round

### 4.1 Order

Phases in order. "Window" is the time the dev build runs on the house.

| Phase | Who | What | Issues |
|---|---|---|---|
| 0 | VM | 1.5's PRs merged on `main`; `tools/check.sh`; `tools/devserver.py` running; `tools/build.sh --dev`; the four `.c4z` served from `build/release/` on port 8090 for the download only; briefs written | all |
| 1 | Windows | Read-only: the bridge's `Event Stream`, `Driver Version`, `Attention`, `Lights`, `Scenes`, `Zone Lights`; the switch's Connections | #65, #238 baseline |
| 2 | Windows | Install the four dev `.c4z` in place ("Restart Director?" Yes, once per driver; standing approval); `Dev Server` holds the server's `host:port`; `Debug Mode` On on the bridge; L, Z, S and G Debug Mode On. VM: `deploy.py record --no-manifest` | D1 |
| 3 | **Owner** | Reboot the controller from System Manager | #238, 1.5 |
| 4 | VM, then Windows | Loop back; #238 log and rows at about 1 and 5 minutes; the Windows session's read when Composer is back (about 8 minutes) | #238 |
| 5 | VM, Windows | (c)'s slot times; T1; the 1.5 contracts' tool-only checks; Windows builds scenes A and B and reassigns the switch | #431, #40 c, 1.5 |
| 6 | **Owner** | Bedroom visit: B1 (switch on A and B), B2 (tiles, while Windows restores the switch), B3 (switch on G); plus the 1.5 contracts' keypad and tile checks | #431, #40 a, 1.5 |
| 7 | VM, Windows | #40 (b); (c) if due; #431 and #65 log analysis; Windows confirms the scenes are gone and the bindings back | #40, #431, #65 |
| 8 | VM, Windows | Debug Mode Off (bridge with `devctl.py set`, devices by Windows); round docs merged; Release workflow cuts 1.5 from `main`; desired-state PR; `deploy.py start`; Windows installs; `deploy.py done`; devserver and HTTP server stopped | D11 |
| 9 | VM | Issue comments and closes; new issues; Discussion post; `docs/status.md` | D12 |

Every dev-loop step sits in phases 4 to 7, inside one window. Nothing in
phases 4 to 7 changes `<capabilities>`. A Lua fix found there can be pinned
and tried in the window (`devctl.py pin`) before it goes into 1.5.

### 4.2 Brief notes for the Windows session

Every brief says that the owner's standing approval covers the hard-to-undo
steps it names (install, "Restart Director?", Connections, lighting scene
changes, the probe device's delete), so the session does not ask him again
(rule 8). It names those steps (rule 2), reads before it clicks (rule 1),
stops on surprises (rule 3), and reads back every binding change (rule 18).
The phase 2 brief tells it that the new code runs only after the owner's
reboot (rule 10).

### 4.3 The owner's moments

1. **Reboot** (phase 3): reboot the controller from System Manager when the
   coordinator says the install is done. About a minute of his time. The
   coordinator tells him then when to go to the bedroom (about 20 minutes
   later: 8 minutes for the controller, then phases 4 and 5).
2. **Bedroom visit** (phase 6), about six minutes, phone in hand, watching
   the bedside lamps and the switch's LEDs:
   - B1, about 90 s: six presses on the switch (section 3.3).
   - B2, about 2 minutes: six tile taps on the phone, plus 1.5's own tile
     checks. The Windows session rebinds the switch meanwhile, so he does
     not wait.
   - B3, about 90 s: five presses on the switch (section 3.4 (a)), plus
     1.5's own keypad checks.

No whole-house step is planned. V8 runs only if the owner asks for it, at a
time he picks.

### 4.4 If the owner prefers the release first (Q1, the other answer)

1. Phase 1 as above.
2. Install the 1.5 release with `deploy.py start` and its brief ("Restart
   Director?" Yes). `deploy.py done` after the reboot.
3. Owner reboots. #238 is read by the Windows session from `Attention`, the
   summary rows and every device's `Status`, as soon as Composer is back
   and again 5 minutes later. A short false mark that healed by itself would
   not be seen this way (section 1.2); a lasting one would.
4. Install the dev build (no reboot: same capabilities); `deploy.py record
   --no-manifest`.
5. Phases 5 to 7 as above.
6. Install the 1.5 release again with `deploy.py start`; the brief already
   answers "Current version is newer" with Yes (#365).

Three installs instead of two; the owner's moments are the same.

## 5. Control4 guidelines

This plan checks rows; it changes none by itself. The round updates these
rows of `docs/c4-lighting-guidelines.md` with what it sees:

- **L63** (held scene ramp and stops): from Partial to Meets when A2, A3 and
  B2 ramp and stop; otherwise Partial with the new issue named.
- **L22** (tile on and off): the command seen in B2 goes into the evidence;
  Meets when it is handled and behaves per the On Mode.
- **L37** (colour trace tolerance): Meets when A1 tracks; otherwise Gap with
  the measured difference and the new issue.
- **L65** (scene hold at its hold rates) and **L14** (group holds): B2 and G2
  add hardware evidence.
- **L64** (scene LEDs track): B1 and G1–G3 add the owner's LED reading.
- **L66** (toggle scene): B3 confirms.

Departures: D1 (a grouped_light ignores a `dimming_delta` duration) and D8
(gamut and mirek rounding) are what the checks measure. No new departure is
proposed.

## 6. Lifecycle edge cases

Not applicable. Nothing in this plan acts on its own over the life of the
system. The temporary lighting scenes, the probe resources and the probe
device are made and removed inside the round, and the switch's bindings are
restored and read back.

## 7. Code work

None is needed for the round. Optional, VM tooling only:

- `tools/deploy.py`: have the install brief read the bridge's `Event Stream`
  row verbatim **before** installing (and say why: the install resets the
  count), and print it into the report. Every release then records the
  outgoing build's reconnect count for free. Owner files:
  `tools/deploy.py` and `tools/tests/test_deploy.py`. Not a driver feature.

Code work that only a deviation triggers is listed in sections 3.1 to 3.4,
each as a new issue. None of it needs a reboot: handlers are Lua, and
`color_trace_tolerance` is a dynamic capability.

## 8. Composer checklist text

For the coordinator to paste after step 98 of `docs/composer-checklist.md`
(a new section "N. Advanced Lighting Scenes and tile taps (#431)"):

```
99. **A lighting scene with Hue devices tracks after colour** (#431, L37).
    Scene "Hue check A": a Hue Light in a saturated colour at 40 % and a
    zone light at 2700 K at 60 %, on a keypad button with tracking. Tap the
    button: both reach their levels and colours within a few seconds, and
    the button's LED lights and stays lit. Paste both devices' Lua lines
    (SET_BRIGHTNESS_TARGET, SET_COLOR_TARGET, LIGHT_COLOR_CHANGED).
    - **Done:** open.
100. **A held scene button ramps and stops** (#431, L63). Hold the button of
    step 99 about 2 s and let go: the lamps ramp smoothly and stop where
    released. Repeat with a scene holding only a Hue Scene device. Paste
    every command the devices receive, including any "no proxy handler"
    line.
    - **Done:** open.
101. **What a tile tap sends** (#431, L22). With Debug Mode On, tap a Hue
    Light's, a zone light's and a Hue Scene's tile on and off in the
    Control4 app. Paste the `ReceivedFromProxy` lines of each.
    - **Done:** open.
```

## 9. Reboot and changelog

- **Reboot:** the round rides the reboot 1.5 needs anyway; it adds no
  capability change. Under D1 the reboot happens with the dev build of 1.5
  installed; the release install afterwards needs none.
- **CHANGELOG:** no line for the round. The checks change neither what the
  drivers do nor their Documentation tab. A fix that a deviation triggers
  brings its own `## Unreleased` line with its issue number.

## 10. Open questions for the owner

Coordinator, 2026-11-09: D1 is adopted (a dev build of the 1.5 candidate before the reboot, then the release over it), the same order `docs/turn-on-design.md` D27 needs; the owner may still ask for the release-first order of §4.4.

- **Q1. Dev build of 1.5 before the reboot, or the 1.5 release first?**
  You said #431 runs after 1.5 is installed. D1 runs the same 1.5 code as a
  dev build first, reboots once, checks, then installs the release cut
  afterwards. Two installs instead of three, the reboot's first minute
  lands in the shipped log (#238), and a Lua fix found in the round can
  still go into 1.5. **Recommended: the dev build first (D1).** The other
  order is in section 4.4.
