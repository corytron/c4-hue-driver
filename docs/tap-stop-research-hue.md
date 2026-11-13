# Tap-stop on Hue lights: the Hue side (#421)

Research for issue #421, written 2026-11-08 by a read-only research agent.
A separate note covers the Control4 side: double-tap window, click-rate
meaning, stock dimmer behaviour, defaults. This note answers how a tap's
ramp can be stopped at Hue, on a light and on a zone or room light, and
what the driver can report while it does. The owner's addition of
2026-11-08 applies throughout: every lighting change follows Control4's own
lighting behaviour and its published light_v2 guidance (§3).

Current (2026-11-13, #478): built in 1.4. The measurement of §9 ran on the
house on 2026-11-09 (`docs/tap-stop-design.md` §10): a `dimming_delta` stop
halts an absolute fade (L2, S2), a grouped_light honours an absolute
duration (Z1), and the stop that shipped is option C, the estimate written
with a one-second glide (`STOP_MODE = "level"`), on lights and on zone and
room lights alike.

Markers: **[verified: …]** names a repo file and line, an issue, a Snap One
reference file (paraphrased, never copied) or a public URL. **[assumed]**
means nobody has measured it on the house bridge, a Hue Bridge Pro. Claims
from community code or forum posts carry both: the URL shows what someone
else does or saw, and whether the house bridge does the same is
[assumed].

## 1. Summary

- **Today.** A tap sends an absolute target over the click rate, so Hue
  gets `{"on":{"on":true},"dimming":{"brightness":P},"dynamics":{"duration":R}}`
  for top and `{"on":{"on":false},"dynamics":{"duration":R}}` for bottom
  [verified: `src/hue_light/driver.lua:1013-1023`,
  `src/hue_light/light/state.lua:256-272`,
  `src/hue_bridge/bridge/commands.lua:225-245`]. A zone or room light sends
  the same fields to its grouped_light [verified:
  `src/hue_bridge/bridge/zone_lights.lua:1112-1147`].
- **Stopping on a light.** Three mechanisms are compared (§4). Only the
  relative dim plus stop is measured (#249). An absolute transition plus a
  stop is what public community code does on lights and grouped_lights
  (§2), but the house has not measured it. That is the key unknown, and §9
  measures it.
- **Reporting.** Repo evidence and community reports agree on two points.
  During a transition the bridge reports the end level at once, not
  intermediate levels. After a stop it reports the real level only about
  10 s later. Both points are [assumed] for the house (§5). So the driver
  must keep its own ramp record and publish an estimate at the stop.
- **Groups.** #249 measured that a grouped_light ignores the duration of a
  `dimming_delta`. Nobody has measured an absolute grouped_light transition
  with a duration. Community code relies on it, together with a
  grouped_light stop (§6). If it holds, a group tap needs no lamp-by-lamp
  split. If it fails, group_hold's split applies, with absolute starts.
- **Recommendation (§10).** For lights, option B: today's tap body as the
  start, and `dimming_delta` stop with the device's estimate as the second
  tap. Option C is the fallback. For groups, the same on the grouped_light
  if Z1 and Z2 in §9 pass; otherwise group_hold's split.

## 2. Evidence already in hand

| # | Fact | Source |
| --- | --- | --- |
| E1 | On a **light**, `dimming_delta` down 100 with a 10 000 ms duration, stopped after about 3 s, took a lamp from 80 % to about 46 %. Read afterwards with a GET and a 10 % nudge, which read 56.5 %. Hue honours the duration and the stop there. | [verified: #249 table; `docs/group-hold-design.md` §1] |
| E2 | On a **grouped_light**, the same body ran from 80 % to 0 % although the stop came about 6 s into a 10 s ramp. Keypad holds of 1.5 s ran to the end in about a second. Hue ignores `dynamics.duration` for a grouped_light `dimming_delta`. | [verified: #249 table; `src/hue_bridge/bridge/group_hold.lua:7-14`] |
| E3 | An absolute grouped_light `dimming.brightness` keeps a dynamic palette playing and a time-based scene active; a change to one light ends them. | [verified: `docs/smart-scenes-research.md:246-252` (V11); `docs/zone-light-design.md:33`] |
| E4 | A turn-on from off to 30 % with a 1000 ms ramp: each lamp's proxy showed 70 % (its old level) for about 16 ms, then 30 %. The fallback fires only at rate + 1 s, so both values came from bridge reports. When they came relative to the 1 s ramp is not recorded. | [verified: #308; #297 hardware comment; `src/hue_light/driver.lua:25`, `:359-374`] |
| E5 | The event stream sends at most about one container a second (two a second seen). A value that changed twice within it reports only its last value. | [verified: `docs/design.md:290-295`] |
| E6 | A grouped_light reports `on` (any member lit) and `dimming.brightness`, the average of the lit members. | [verified: `docs/zone-light-design.md:29`] |
| E7 | Public Home Assistant code (MIT) ramps with an absolute brightness and `dynamics.duration` on a light **or a grouped_light**. It stops with `dimming_delta` stop on the same resource. A ramp to 0 sends `on:false` with the duration. The README recommends groups for even multi-lamp dimming. | [verified: https://github.com/jasonmx/philips-hue-smooth-dimmer, `custom_components/hue_dimmer/transitions.py` `_start_transition`, `_stop_transition`; README] |
| E8 | The same code says the bridge reports a transition as if it had happened at once (the target). It says the bridge takes about 10 s to correct its report after a mid-flight stop. It distrusts reports for 15 s after a stop and uses its own linear estimate meanwhile. | [verified: same repo, `transitions.py` `resolve_brightness` comment, `const.py` `API_SETTLE_SECONDS = 15`] |
| E9 | Forum posts: during dimming the bridge reports the target (100 % or 0 %); a switch indicator stayed at 100 or 0 for about 10 s before it corrected. A second thread: a refresh during a transition returned the maximum. | [verified: https://community.home-assistant.io/t/philips-hue-smooth-dimming-and-set-color-ct-brightness-while-off/985343 (2026-05 and 2026-09 posts); https://community.home-assistant.io/t/hue-lights-brightness-during-transition/1005905 (2026-04-20)] |
| E10 | aiohue, Home Assistant's Hue library, documents the stop action as ending any dimming transition at once, for lights and grouped_lights alike. | [verified: https://github.com/home-assistant-libs/aiohue, `aiohue/v2/controllers/lights.py` and `groups.py`, `set_dimming_delta`] |

The public Hue developer pages could not be read: Core Concepts redirects
to the login page. So nothing here relies on Signify's text beyond the
repo's earlier citations of Core Concepts for rate limits [verified: fetch
of https://developers.meethue.com/develop/hue-api-v2/core-concepts/ on
2026-11-08 returned the login page].

## 3. What the light_v2 guidance expects

Paraphrased from Snap One's light_v2 best practice and proxy reference:

- **B1. The target at the start.** When a transition begins, the driver
  sends `LIGHT_BRIGHTNESS_CHANGING` with the current level, the target and
  the rate. Navigators animate from it, so this suits devices that send no
  intermediate status. Periodic level notifies to imitate a slider are
  discouraged. When the end is unknown, as in a hold, the target is where
  the light would end without further input [verified: FUND
  `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`, "Brightness Target
  API"; light_v2 `LIGHT_BRIGHTNESS_CHANGING` usage].
- **B2. The real level after a stop.** When the ramp stops, the driver
  sends `LIGHT_BRIGHTNESS_CHANGED` with where it stopped. The parameter is
  described as the raw value where the brightness stopped [verified: same
  section, the hold example; light_v2 `LIGHT_BRIGHTNESS_CHANGED`].
  `SET_BRIGHTNESS_STOP` asks the driver to stop a ramp in progress. Drivers
  with `supports_brightness_stop`, which reduced-ALS drivers should
  declare, are expected to honour it during scene ramps [verified: light_v2
  `SET_BRIGHTNESS_STOP`, `supports_brightness_stop`,
  `reduced_als_support`]. hue_light.c4z declares both [verified:
  `src/hue_light/driver.xml:156`, `:164`]. Today the stop only closes the
  proxy's transition, and the lamp keeps ramping [verified:
  `src/hue_light/driver.lua:957-963`].
- **B3. New commands during a ramp.** Consecutive brightness and colour
  commands must not override each other; debounce or queue so they combine
  [verified: FUND `_50`, "Handling Consecutive Brightness and Color
  commands"]. The colour must not change during a hold-down whose end is
  unknown [verified: FUND `_50`, "Default On and Dim Colors"].
- `_51-LIGHTV2EXTRAS.md` covers the Extras tab, custom UI objects, which a
  tap does not touch [verified: FUND `_51-LIGHTV2EXTRAS.md`].

## 4. Stopping a ramp on a single light

Notation:
- L is the level the driver believes the lamp is at.
- P is the On preset ("Default On Brightness", 100 unless set) [verified:
  `src/common/device.lua:107-113`].
- R is the click rate.
- t is the time since the start.

### 4.1 Option A: relative dim, then stop

Start: `{"dimming_delta":{"action":"up"|"down","brightness_delta":d},"dynamics":{"duration":D}}`.
Second tap: `{"dimming_delta":{"action":"stop"}}`. Hue honours both on a
light [verified: E1].

- **To a preset of 60.** d = |60 − L|, direction from the sign. The end
  level is L ± d, so a stale L leaves the lamp off-target, and the error
  persists [assumed]. L is often stale here, because after a stop the
  bridge corrects its report only about 10 s later [assumed: E8, E9]. #249
  is open on speed: with d = 100, does Hue move at 100 % per D and stop at
  the end of the range? Or does it spread what is left of the range over D?
  E1's 46 % fits the first; the 56.5 % nudge read is close to the second
  [verified: #249 table; the reading of it is assumed]. §9 L5 settles it.
- **Down to off.** A delta down ends at the minimum, not off. The keypad
  design assumes this [assumed: `docs/keypad-design.md:97`, the tile goes
  to 1; #249 records "0 %" without saying whether that meant off]. Ending
  off needs a driver timer that sends `{"on":{"on":false}}` when the ramp
  is due to end. A second tap cancels the timer and sends the stop. If the
  timer and Hue disagree, the lamp waits at the minimum or cuts from a low
  level to off [assumed].
- **From off.** The hold path's two steps: on at 1 %, then the delta about
  600 ms later (`dev.dim_after_on`) [verified:
  `src/common/device.lua:637-648`, `src/hue_light/driver.lua:1084-1097`].
  That is two requests, and the ramp starts late.
- **Speed.** See §4.5.

### 4.2 Option B: absolute target with a duration, then stop

Start: today's tap body, unchanged [verified: §1]. Second tap:
`{"dimming_delta":{"action":"stop"}}`, sent with the device's estimate as
`level` for the queue's refused-stop fallback [verified:
`src/hue_bridge/bridge/commands.lua:386-398`, `:456-463`].

- **Does the stop halt an absolute transition?** Not measured on the house
  [assumed]. In favour:
  - community code relies on it on lights and grouped_lights [verified:
    E7, E10];
  - Zigbee's Level Control stop ends any level transition in progress, not
    only a move or step [assumed: Zigbee Cluster Library, not checked
    against a Hue lamp];
  - Hue's v1 API documented a zero `bri_inc` as stopping any running
    transition; v1 is out of scope here (CLIP v2 only) [assumed: the
    author's recollection of the public v1 reference, not re-checked].

  §9 L2 settles it.
- **To a preset of 60.** Exact: the body names 60. An error in L changes
  only the speed, if speed depends on distance (§4.5), never the end level
  [verified: the body carries the target, `commands.lua:228-233`].
- **Down to off.** Either of two bodies:
  - B-off-1: `{"on":{"on":false},"dynamics":{"duration":D}}`, today's
    bottom tap. One request; whether a stop leaves the lamp lit at the
    stopped level is [assumed] (§9 L3). Community code sends the same
    shape for a ramp to 0 and stops it the same way [verified: E7].
  - B-off-2: `{"dimming":{"brightness":<min>},"dynamics":{"duration":D}}`,
    then `on:false` from a driver timer at the end, as in option A [assumed
    to work, since it uses only measured parts plus a timer].
- **From off.** One request,
  `{"on":{"on":true},"dimming":{"brightness":P},"dynamics":{"duration":D}}`.
  The #297 walk did exactly this to 30 % over 1000 ms. The owner saw no
  flash, and the only oddity was the reported 70 % (E4) [verified: #297
  comment]. Whether the lamp fades up from off or starts at its old level
  over a multi-second ramp is [assumed] (§9 L6).
- **Speed.** See §4.5.

### 4.3 Option C: absolute target, then an absolute estimate

Start: as option B. Second tap: `{"dimming":{"brightness":E}}`, with no
duration, where E is the driver's linear estimate:
L + (target − L) · t / D.

- **What the eye sees.**
  - The lamp ramps on until the request lands: an 80 ms debounce, plus
    the PUT, plus Zigbee delivery [verified: `commands.lua:46`, `:307`;
    delivery time assumed]. Then it steps back to E.
  - Any estimate error shows as a jump. At a 3 s whole-range speed,
    100 ms is about 3 points [assumed: arithmetic].
  - #249's single-lamp result fits a linear ramp within its timing slack:
    80 % to about 46 % after about 3 s, where linear gives 50 % [verified:
    #249 table; "fits" is assumed]. Whether Hue moves linearly in its own
    percent during an absolute transition is [assumed] (§9 L2 with two
    stop points).
- **To a preset, to off, from off.** As option B for the start. A
  fade-to-off is stopped by `{"on":{"on":true},"dimming":{"brightness":E}}`
  [assumed: a new command replaces a running transition, §9 L8].
- **Needs no stop primitive.** It works wherever an absolute duration
  works, and the queue's refused-stop fallback is this option already
  [verified: `commands.lua:456-463`].

### 4.4 Other mechanisms

- **Option D, driver-stepped absolute targets.** A timer sends absolute
  steps toward the target, for example every 200 ms on a light or every
  1 s on a group. The second tap cancels the timer.
  - It is always stoppable, and each step is a target the bridge reports
    straight back [assumed].
  - On lights it uses the request budget (about 10/s for all lights); on
    groups it gives visible one-second steps, like group_hold's stepped
    mode [verified: `commands.lua:9-17`; `group-hold-design.md` G5].
  - Worth it only for groups that cannot ramp (§6).
- **Precise option A.** d = the distance to the target. This is option A
  above with the same stale-L weakness.
- **Out of scope:** the v1 `bri_inc` stop (the project is CLIP v2 only)
  and the Entertainment streaming API (DTLS, entertainment areas; "later,
  not v1" in `CLAUDE.md`).

### 4.5 Speed: whole-range time or transition time

The Control4-side note settles which reading Control4 uses. Both, per
option:

| Reading | Option A | Option B or C |
| --- | --- | --- |
| R is the time of this tap's transition, whatever the distance | d = \|target − L\|, D = R | D = R; L is used only for the proxy's CHANGING |
| R is the time for the whole range (a tap from 40 to 100 takes 0.6 · R) | d = \|target − L\|, D = R · d / 100 | D = R · \|target − L\| / 100; a wrong L changes the speed, not the end |

For a group with lamps at different levels (§6), the transition-time
reading brings every lamp to the target at the same moment. The
whole-range reading gives each lamp its own D [assumed: arithmetic].

### 4.6 Against the light_v2 guidance

| | B1: target at the start | B2: real level after a stop | B3: a new command during the ramp |
| --- | --- | --- | --- |
| A | CHANGING carries the intended target, but the lamp ends at L ± d, which differs when L is stale [assumed]. | The estimate first; the bridge corrects about 10 s later [assumed: E8]. A second CHANGED may move the tile a few points. | Hue replaces the dim with the new command [assumed, §9 L8]. Queue gap: a colour pending beside a dim is dropped (§7). **Departure** until fixed. |
| B | Exact target and rate [verified: the body names them]. | As A: estimate, then a late correction [assumed]. Also fills the gap of B2: the proxy's `SET_BRIGHTNESS_STOP` can stop the lamp. | Brightness and colour already merge into one body [verified: `commands.lua:141-195`]. Hue replaces the transition [assumed]. |
| C | Exact, as B. | The published level is the commanded one, and the bridge reports it straight back [assumed]. The most accurate report; the cost is a visible jump. Works for `SET_BRIGHTNESS_STOP` on any resource. | As B. |
| D | Exact, as B. | Accurate: the last step's target. | As B; cancelling the timer is the stop. |

Where Hue forces a departure:
- **The report lag after a stop** (E8, E9) means the first CHANGED after a
  stop is an estimate for options A and B. Option C avoids that at the
  price of a jump.
- **No group ramp.** If the grouped_light ignores an absolute duration
  (§6), a smooth group ramp needs per-light commands. Those end Hue scenes
  (E3), so the driver falls back to steps.
- **Not forced by Hue.** The bridge reporting the target at once is not a
  departure in itself: CHANGING exists for devices without intermediate
  status (B1). But today's driver treats any report as the end of the
  ramp: one report settles the pending target and sends CHANGED at once
  [verified: `src/hue_light/driver.lua:626-648`]. With multi-second taps
  the tile would jump to the end while the lamp still moves. That is a
  driver change to make, not a Hue limit (§5).

## 5. What the bridge reports

- **During a transition.** Probably the target at once, for absolute
  transitions [assumed: consistent with E4; asserted by E8 and E9].
  - No repo evidence shows intermediate levels.
  - The stream would carry at most about one value a second anyway (E5).
  - For a relative dim, the report is presumably the dim's end (100 % or
    the minimum) at once [assumed: E9's "100 % or 0 %"; not measured for
    `dimming_delta`].
- **After a stop.** The repo has no record of when the bridge reported a
  stopped level.
  - #249 read the levels "afterwards" with a GET and a 10 % nudge. Its
    timing is not recorded, nor whether the nudge was needed because the
    GET was stale [verified: #249 body].
  - Community code waits about 10 s for the correction [verified: E8].
    Whether the Bridge Pro does the same is [assumed].
  - The hold path already relies on a report or the fallback: it publishes
    its estimate after 1 s without a report [verified:
    `src/hue_light/driver.lua:1105-1116`].
- **#308.** The first report after a turn-on carried the old level for
  about 16 ms (E4). The device now holds back an "on at another level"
  while a turn-on waits for its target [verified:
  `src/hue_light/driver.lua:314-331`, `:381-414`]. The guard lets an
  **off** through always (`:392`).
- **What the driver should do** (input to the contract):
  - keep a tap-ramp record (from, to, start time, duration), as a hold
    keeps one [verified: the hold's record, `src/hue_light/driver.lua:1048-1079`];
  - send CHANGING at the start;
  - take a report that matches the ramp's target into the cache, but send
    no CHANGED before the ramp's time is up;
  - at a stop, send the estimate as CHANGED and write it into the cache;
  - accept the bridge's later correction as a normal report;
  - a report that matches neither the target nor (if one is ever seen)
    the path is someone else's change: it ends the record and goes out at
    once [assumed design].
- **Still to measure:**
  - target, intermediate or end, for absolute transitions and deltas
    (L1, L5);
  - when and whether the stopped level is reported (L2, L5, L7);
  - what `on` the stream shows during a fade to off (L3).

## 6. Groups: zone and room lights

- **An absolute grouped_light transition with a duration.** Unknown on the
  house [assumed].
  - The repo verified that the body is accepted, and that duration is
    ignored for deltas [verified: E2; `docs/scene-dimmer-design.md:148-151`
    lists the slider's group duration as unmeasured].
  - Community code ramps grouped_lights this way and recommends groups
    [verified: E7]. A plausible reason: Zigbee group messages carry a
    move-to-level with a transition time natively, while a relative dim
    may not be sent that way [assumed].
  - §9 Z1 settles it.
- **A grouped_light stop.** It did not stop a delta, which had already
  finished (E2). Whether it stops an absolute group transition is
  [assumed] (§9 Z2).
  - The path already exists: a zone light's `HUE_DIM stop` with no
    running hold passes to the group queue unchanged, with its `level`
    [verified: `src/hue_bridge/bridge/zone_lights.lua:1155-1186`,
    `group_hold.lua:188-193` (G7)].
  - So if Z1 and Z2 pass, a group tap needs no new bridge path. The
    device sends today's `HUE_SET`, and on the second tap `HUE_DIM stop`
    with its estimate.
  - Scenes keep running: whole-group bodies keep them (E3). Whether a
    group **stop** does too is [assumed] (§9 Z5).
- **If the grouped_light cannot ramp**, reuse group_hold's split
  [verified: `group_hold.lua:224-285`], with these changes for a tap:
  - **Starts are absolute**, `{ on, brightness = P, rate = D }` per lamp
    through the light queue, not `{ dim, delta = 100 }`. G2 today passes
    an absolute `HUE_SET` straight to the group queue
    (`zone_lights:set`), so taps need a new entry point beside `gh:dim`
    [verified: `group_hold.lua:194-196`; `zone_lights.lua:1141`].
  - **The set:**
    - a top tap or a tap from off takes **every** member, because today's
      absolute group tap turns every member on [verified: Decision 5,
      `docs/zone-light-design.md:99-103`];
    - a bottom tap takes the lit members;
    - 1 to `PER_LIGHT_MAX` (10) lamps and no scene running: per-light;
    - more than 10, or `keep_group` true: stepped (G5, G6a).
  - **Per-light stops:**
    - `{ dim = "stop", level = that lamp's estimate }` to each lamp that
      took a start;
    - if L2 shows the stop does not halt absolute transitions, an
      absolute estimate to each lamp instead (option C);
    - unlike holds, send a `level` with each stop, so a refused stop has a
      fallback [verified: holds send none, `group_hold.lua:337-341`].
  - **Stepped mode:** absolute group targets, one a second, from the
    grouped_light's average toward P. The last step of a bottom tap is
    `on:false`, and the second tap cancels the timer. The relative steps
    holds use would keep lamp differences but never land on P (last bullet of this section).
    Which steps to use is an owner question (§11).
  - **From off:** every member, one absolute start each; no 1 % step if
    L6 shows a fade from off.
- **What a tap to the preset means on a group.**
  - The device's level is the average of the lit members (E6).
  - An absolute target sets every lamp to P, so the average lands on P,
    which is the promise of Decision 5 [verified:
    `docs/zone-light-design.md:99-103`].
  - A relative move keeps lamp differences but cannot land the average on
    P without saturating [verified: same lines].
  - With every lamp on the same D (transition-time reading), the group's
    estimate after a stop is from_avg + (P − from_avg) · t / D. It equals
    the average of the lamps' own linear estimates [assumed: arithmetic].
    With per-lamp durations (whole-range reading), average the per-lamp
    estimates instead.

## 7. Queues and ordering

How `bridge/commands.lua` treats a tap start followed by a stop:

| Case | Today | Verdict |
| --- | --- | --- |
| Stop arrives while the start is still pending (80 ms debounce) | `merge` turns the pending state into the stop and drops brightness and `on` [verified: `commands.lua:160-164`]. The start is never sent. | Harmless: nothing was ramping. That Hue answers a lone stop on a still lamp with success is [assumed] (§9 L10). |
| Stop arrives while the start is in flight | One PUT in flight per resource; the stop waits for `done()` [verified: `commands.lua:334-337`, `:465-467`]. | Fine: the double-tap window means the start's answer is long back. |
| Stop with an empty bucket | A stop is urgent and takes no token [verified: `commands.lua:131-139`, `:315-330`]. | Fine. |
| Debounce | Every state, urgent or not, waits 80 ms [verified: `commands.lua:46`, `:307`]. | Optional change: flush an urgent state at once (about 3 points saved at a 3 s whole-range speed). |
| A new command replaces a pending stop | `merge` clears the dim for a brightness or `on` [verified: `commands.lua:165-167`]. | Harmless if a new command replaces a running transition [assumed, §9 L8]. |
| A colour pending beside a dim or stop | `body()` returns the `dimming_delta` alone, and the colour is lost with the pending state [verified: `commands.lua:206-224`]. | **Change needed.** It breaks B3. Keep the colour pending for the next PUT, or add it to the body if Hue takes both [assumed]. |
| Stop refused (4xx) | Writes `level`, else the dim start's estimate [verified: `commands.lua:386-398`, `:456-463`]. `dim_start` is set only by dims (`:352-355`), and the light queue has no `level_of` [verified: `src/hue_bridge/driver.lua:659-664`]. | Send `level` with every tap stop. Clear `dim_start` on non-dim sends, or a stale hold start feeds a wrong fallback [assumed]. |
| Stop fails with 429, 5xx or no answer | Retried from 500 ms, doubling, for up to 30 s [verified: `commands.lua:432-451`]. | A late stop overshoots, and one after the ramp's end does nothing. Suggest: retry a stop once as an absolute `level` (option C). |
| Tap start on the group queue | An absolute body is not urgent, and the group bucket is 1/s with a burst of 3 [verified: `commands.lua:131-139`; `src/hue_bridge/driver.lua:672-687`]. After a slider drag, a tap can wait up to about 1 s. | **Change needed** for group taps: mark a keypad tap's start urgent, for example an `urgent` field that `merge` keeps until replaced. |

Per-light group taps keep group_hold's order: starts in member order,
stops in the same order [verified: `group_hold.lua:247-267`, `:327-344`].
Ten starts fit the light queue's burst of 10 [verified: `commands.lua:47-48`].

## 8. Interactions

- **#308 turn-on guard** [verified: `src/hue_light/driver.lua:381-414`]:
  - it holds back on-reports away from the goal for rate + 1 s, so slow
    taps widen the window; a foreign change during it shows up late by up
    to rate + 1 s;
  - a stop must end the wait, by settling it, so the bridge's late
    correction goes through [assumed design];
  - the guard always passes an **off**, so a fade-to-off tap whose
    `on:false` is reported at once would turn the tile and the LEDs off at
    the start of the ramp. The tap-ramp record (§5) must cover that case
    [assumed: depends on L3].
- **Default On Brightness (#233).** A top tap goes to P even from above P
  [verified: `src/hue_light/driver.lua:975-987`]. Option B or C needs no
  direction. Option A must pick up or down from L.
- **Raise Level By and Restore Saved Level (#297).** Both read the cached
  level [verified: `src/hue_light/driver.lua:854`, `:906`].
  - During a tap ramp the cache would hold the target (§5), so a Raise
    would start from the end level. Use the ramp estimate while a record
    runs [assumed design].
  - A tap stop leaves the lamp off the Raise's target, so the next Restore
    forgets the saved level. The contract wants exactly that for a manual
    change [verified: `docs/relative-level-design.md` §1].
  - Should a tap stop a Raise's own ramp? That is an owner question (§11).
- **Holds.**
  - A hold during a tap ramp starts its estimate from the cached level,
    which would be the target [verified: `src/hue_light/driver.lua:1089`].
    It should start from the tap estimate and end the record. Hue's delta
    acts from the lamp's real level [assumed]. That it replaces the
    absolute transition is [assumed] (§9 L9).
  - A tap on the held button finishes the hold [verified:
    `src/common/device.lua:662-663`].
  - A tap on the toggle decides from `st.on`
    [verified: `src/hue_light/driver.lua:1018-1022`], which a reported
    target can flip early. The second-tap decision must read the record,
    not `st.on` [assumed design].
- **A Hue app change during a ramp.** The new command replaces the ramp at
  Hue [assumed], and the bridge reports its level. A report that differs
  from the ramp's target ends the record and goes out as CHANGED at once
  [assumed design]. An app change to exactly the target looks the same,
  and is harmless.
- **Hue scenes on the group.**
  - Per-light commands end a time-based scene and a dynamic palette, and
    whole-group bodies keep them [verified: E3].
  - Grouped_light taps (Z1, Z2 pass) keep them, if the group stop does
    too [assumed, Z5].
  - The split forces stepped mode when `keep_group` is true [verified:
    G6a, `group_hold.lua:240-242`].

## 9. Measurement plan for the house

**Preparation:**
- **Dev build.** The house runs release builds, and `Hue Request` exists
  only in dev builds. Install one through the Windows session and end with
  a release install [verified: `docs/dev-loop.md`, "Development commands";
  `docs/smart-scenes-research.md:147`].
- **Debug Mode.** Start `tools/devctl.py log -f`. Set the bridge's Debug
  Mode On (`devctl.py set "Debug Mode" On`).
- **Lamp and zone.** The owner names a lamp that has a Hue Light device
  (`<light-rid>`) and a zone of two or three lamps that has a zone light
  device (`<grouped-light-rid>`, members `<m1-rid>` and `<m2-rid>`). For
  Z5, a scene of that zone that plays dynamically (`<scene-rid>`).
- **What the stream reports.** The bridge logs only item types per
  container [verified: `src/hue_bridge/bridge/stream.lua:579-587`]. Set
  Debug Mode On on the two devices, through the Windows session. Each
  report the bridge passes on then logs as `-> proxy
  LIGHT_BRIGHTNESS_CHANGED …` with millisecond timestamps [verified:
  `src/common/device.lua:207-213`; `tools/devserver.py:94-96`]. Direct
  requests arm no device fallback, so every such line is a bridge report.
  Optional: a temporary, uncommitted dev-loop log line in
  `lights:on_light_item` (`src/hue_bridge/bridge/lights.lua:1164`)
  printing `on.on` and `dimming.brightness` with decimals.
- **Timing.** A queued command runs at the bridge's next poll, every
  3 s [verified: `src/common/devloop.lua:85`]. Queue each follow-up
  request after the previous answer shows in the log. Take elapsed times
  from the log timestamps of the `Hue Request PUT … HTTP 200` lines, not
  from the request's own "in N s", which counts whole seconds [verified:
  `src/hue_bridge/bridge/devtools.lua:162`, `:187`].
- **Form.** Every request below is
  `tools/devctl.py run "Hue Request" Method=<M> Path=<path> Body='<json>'`.
  A GET of one light logs `on=` and `brightness=` [verified:
  `devtools.lua:167-175`]. Every step takes under a minute. "Visible"
  means people in the room see the lamps change.

### 9.1 Single light

| Step | Requests | Read-back | What each outcome means | Visible |
| --- | --- | --- | --- | --- |
| L0 | PUT `/clip/v2/resource/light/<light-rid>` `{"on":{"on":true},"dimming":{"brightness":80}}`; GET the same path | `on=true brightness=80` | Baseline for L1 to L9. | yes |
| L1 | PUT `{"dimming":{"brightness":20},"dynamics":{"duration":20000}}` | GET as soon as the answer shows, and about 10 s later; the device's CHANGED lines | 20 at once: **target at once** (§5). Values between 80 and 20: intermediate levels. 80 until the end, then 20: end level only. The lamp ramping slowly for 20 s confirms the absolute duration on a light. | yes |
| L2 | L0; L1's PUT; after its answer, PUT `{"dimming_delta":{"action":"stop"}}` | Time from start to stop; GET right away, about 10 s and 20 s later; then PUT `{"dimming_delta":{"action":"up","brightness_delta":10}}` and GET (the #249 nudge) | Lamp stops near 80 − 60·t/20: **option B works on a light**. Lamp runs on to 20: the stop ignores absolute transitions, so use C or A. Non-200 answer: the refused-stop fallback covers it. The GETs show when the bridge corrects its view. Run twice with different t to check linearity (§4.3). | yes |
| L3 | L0; PUT `{"on":{"on":false},"dynamics":{"duration":20000}}`; after the answer, the stop | CHANGED lines at the start (`on` false at once?); GET right away and about 10 s later | Lamp stays lit near 80·(1 − t/20): **a bottom tap is one stoppable request** (B-off-1). Lamp goes off anyway: use B-off-2. An `on:false` reported at the start: the record must hold it back (§8). | yes |
| L4 | PUT `{"dimming":{"brightness":10}}`; then `{"dimming_delta":{"action":"down","brightness_delta":100},"dynamics":{"duration":3000}}` | GET about 5 s later | `on=true` at the minimum: a delta down stops at the minimum (the hold's assumption). `on=false`: it turns the lamp off. | yes |
| L5 | L0; PUT `{"dimming_delta":{"action":"down","brightness_delta":100},"dynamics":{"duration":20000}}`; after the answer, the stop | As L2 | Reports for option A and for holds after a stop. Level ≈ 80 − 100·t/20: Hue keeps the whole-range speed (#232's assumption). ≈ 80 − 80·t/20: it spreads the remaining range over the duration. | yes |
| L6 | PUT `{"on":{"on":false}}`; about 2 s later, PUT `{"on":{"on":true},"dimming":{"brightness":60},"dynamics":{"duration":10000}}` | People watch the lamp; CHANGED lines | Fades up from off: a tap from off needs no 1 % step. Flashes its old level first: keep the 1 % step for taps too. The lines show whether #308's old-level report recurs. | yes |
| L7 | As L6; after the turn-on's answer, the stop | GET right away and about 10 s later | Lamp holds near 60·t/10: a turn-on ramp is stoppable. Also when the bridge reports the stopped level. | yes |
| L8 | L0; L1's PUT; after the answer, PUT `{"dimming":{"brightness":70}}` | GET; CHANGED lines | Lamp goes to 70 at once and stays: a new command replaces a transition, which **option C** and B3 rely on. The report of 70 confirms that C's published level is the bridge's own. | yes |
| L9 | L0; L1's PUT; after the answer, PUT `{"dimming_delta":{"action":"up","brightness_delta":100},"dynamics":{"duration":20000}}`; about 3 s later, the stop | GET | Lamp turns round and rises from where it was: a hold replaces a tap ramp (§8). | yes |
| L10 | On a still lamp: PUT `{"dimming_delta":{"action":"stop"}}` | Answer; GET | HTTP 200 with no change: a lone or early stop is harmless (§7; group_hold G4's assumption). | no |

### 9.2 Zone (grouped_light)

| Step | Requests | Read-back | What each outcome means | Visible |
| --- | --- | --- | --- | --- |
| Z0 | PUT `/clip/v2/resource/grouped_light/<grouped-light-rid>` `{"on":{"on":true},"dimming":{"brightness":80}}` | GET the grouped_light and `/clip/v2/resource/light/<m1-rid>` | Baseline. | yes |
| Z1 | PUT the grouped_light `{"dimming":{"brightness":20},"dynamics":{"duration":20000}}` | GETs of both paths right away and about 10 s later; the zone device's CHANGED lines | A slow 20 s ramp: **absolute group durations are honoured**. About 1 s: ignored, as for deltas (E2), so use the split (§6). | yes |
| Z2 | Z0; Z1's PUT; after the answer, PUT the grouped_light `{"dimming_delta":{"action":"stop"}}` | GET `<m1-rid>` and `<m2-rid>` right away and about 10 s later; nudge each if the GETs look stale | Lamps stop together near 80 − 60·t/20: **one-request group taps are stoppable**. They run on: per-light stops, or option C on the group. | yes |
| Z3 | Z0; PUT the grouped_light `{"on":{"on":false},"dynamics":{"duration":20000}}`; after the answer, the group stop | As Z2 | As L3, for a zone light's bottom tap. | yes |
| Z4 | PUT the grouped_light `{"on":{"on":false}}`; about 2 s later `{"on":{"on":true},"dimming":{"brightness":60},"dynamics":{"duration":10000}}` | People watch; GETs | As L6, for a zone light's tap from off. | yes |
| Z5 | PUT `/clip/v2/resource/scene/<scene-rid>` `{"recall":{"action":"dynamic_palette"}}`; then Z1's PUT; after the answer, the group stop | GET `/clip/v2/resource/scene/<scene-rid>` (`status.active`) | Still `dynamic_palette`: grouped_light taps and stops keep scenes running. Static or inactive: group taps must step while a scene runs. Only if Z1 and Z2 pass. | yes |
| Z6 | Only if Z1 or Z2 fails: L1's PUT to `<m1-rid>` and `<m2-rid>`; after both answers, the stop to each | GET both | Both stop near their own estimates: the per-light split (§6) works for taps. | yes |

That is 18 steps (11 on one lamp, 7 on the zone), about 15 to 20 minutes
of requests plus the dev build install and the release install back.

## 10. Recommendation

- **Lights: option B**, with option C as the fallback.
  - The start is today's tap body, so nothing new goes to Hue until the
    second tap [verified: §1].
  - The end level is exact for any preset and for off, whatever the
    driver's idea of L [verified: the body carries it].
  - CHANGING can carry the true target and rate (B1).
  - The same stop serves the proxy's `SET_BRIGHTNESS_STOP`, which the
    driver declares but cannot honour today (B2).
  - The bottom tap stays one request if L3 passes; otherwise B-off-2.
  - If L2 shows the stop does not halt absolute transitions, the second
    tap sends the estimate (option C). C's published level is the most
    accurate, at the cost of a small jump.
  - Option A stays the third choice. It is the only one measured, but its
    end level depends on a cached level that is stale for about 10 s after
    any stop, and ending off needs a timer.
- **Groups: the grouped_light itself if Z1 and Z2 pass.**
  - One start and one stop per tap, through the existing paths.
  - Hue scenes keep running (E3, Z5).
  - Every lamp lands on P, as Decision 5 promises.
  - Mark the start urgent (§7).
  - If Z1 or Z2 fails: group_hold's split with absolute starts and
    per-light stops carrying `level` for 1 to 10 lamps, and timed absolute
    steps above 10 or while a scene runs (§6).
- **Either way, the device keeps a tap-ramp record.** It sends CHANGING at
  once, holds CHANGED until the ramp ends or stops, publishes its estimate
  at a stop, and takes the bridge's late correction. It answers the second
  tap from the record, not from `st.on`. Today's "any report settles the
  target" must change for tap ramps (§5).
- **Queue changes** (§7):
  - keep a colour pending beside a dim;
  - make a keypad tap's start urgent;
  - send `level` with every tap stop;
  - retry a failed stop as an absolute level;
  - optional: no debounce for urgent states.

## 11. Open questions for the owner

1. **A stop that is smooth or a stop that is exact?** Only if L2 passes.
   - Option B stops the lamp where it is. The tile shows the driver's
     estimate and may move a few points when the bridge corrects about
     10 s later.
   - Option C makes the tile exact, but the lamp steps back a little at
     the stop.
2. **What should a tap stop?** Only ramps a tap started, or any running
   ramp: a Raise Level By, programming's long `SET_BRIGHTNESS_TARGET`, an
   Advanced Lighting Scene? The Control4-side note may settle how a stock
   dimmer behaves.
3. **Groups that cannot ramp** (only if Z1 or Z2 fails, with more than 10
   lamps or a scene running). Which steps should a tap use?
   - Absolute steps land on the preset but bring every lamp to one level
     at the first step.
   - Relative steps keep the lamps' differences but do not land on the
     preset.
