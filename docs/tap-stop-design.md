# Tap to ramp, tap again to stop (#421)

The contract for issue #421. Every agent builds against this text. The
research behind it:

- [the Control4 side](tap-stop-research-c4.md): how taps and double taps
  arrive, click rates, stops, and a stock Control4 dimmer;
- [the Hue side](tap-stop-research-hue.md): how to stop a ramp at Hue, what
  the bridge reports, groups and queues, and the measurement plan.

Section numbers like "C4 §7.3" and "Hue §9" point into those two notes.

## 1. What the owner asked for

Owner, 2026-11-08: keypad taps on Hue lights should behave like a Control4
dimmer on a regular bulb, in addition to the 1.3 hold ramps (#249).

- A tap starts a ramp from wherever the light is: the top button up to full,
  the bottom button down to off.
- Tapping again while it ramps stops the ramp where it is.
- That second tap has to come after Control4's double-tap window, because a
  double tap is its own event and can trigger programming.
- The default ramp times are slow enough to catch the light on the way up or
  down.

The same day the owner also made Control4's lighting guidelines a standing
rule (#422). Section 9 lists how this design meets them.

## 2. Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Which devices.** Hue Light devices (single lights, zone lights, room lights) get tap ramps and tap stops. Hue Scene devices get only the double-tap window (D4): a scene tap stays a recall or an off. Hue Motion has no buttons. | C4 §6. A scene recall has no level to stop at. |
| D2 | **Where a tap goes.** The top tap goes to the On preset (Default On Brightness, #233). A top tap from above the preset ramps down to it. The bottom tap goes to off. The toggle tap goes by the light's on state. The full rule is section 3. | C4 §4, §7.3. Control4's On preset applies whatever the level. |
| D3 | **Ramp speed.** Click rates are the time of the whole range, as hold rates are. A tap ramp lasts `click rate × distance / 100`. The defaults of Click Rate Up and Click Rate Down go from 250 ms to **3000 ms**. Hold rates stay at 5000 ms. | C4 §2, §5.1. 3 s is slow enough to catch and still quicker than a hold. |
| D4 | **Double-tap window.** A press that comes within `DOUBLE_TAP_MS` = **600 ms** of the previous press on the **same** button is part of a double or triple tap. It starts nothing and stops nothing, and a running ramp keeps going. It is still echoed on the proxy route. Held past `HOLD_AFTER_MS`, it becomes a hold as usual. The window is fixed in the code; no new property. | C4 §1.4, §1.6. Composer puts the window at about half a second. The first tap acts at once, because waiting out the window would delay every tap. |
| D5 | **The stop.** While a ramp runs, the **press** of any button outside the window stops it where it is. That includes the other button, and the toggle; the light does not reverse. The click that follows the stopping press is swallowed. A press held past `HOLD_AFTER_MS` stops the ramp, then holds from the stopped level. | C4 §4, §7.3. Control4's user guide: a tap while the light dims stops it. Stopping on the push is what the keypad link page advises (C4 §8 row 9). |
| D6 | **What a tap stops.** Any brightness ramp the light driver has running with a time above 0: a tap ramp, and a timed target from programming, Navigator or lighting scenes (`SET_BRIGHTNESS_TARGET`, `SET_LEVEL`, `RAMP_TO_LEVEL` with a time). Holds keep their own machine (#249). | Control4's guidance describes a tap stopping a dimming light, not only one a tap started (#422 rule). |
| D7 | **The stop entry points.** `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` stop a running ramp at Hue too, exactly as a tap does. Today they only report the cached level while the lamp keeps going. | C4 §3.1. Both drivers already declare `supports_brightness_stop`. |
| D8 | **How Hue does it (option B).** The ramp's start is today's absolute target with a duration (`HUE_SET` with `brightness` and `rate`). The stop is the existing `HUE_DIM` with `direction = "stop"` and the device's estimate as `level`. The bridge sends `dimming_delta` stop, and writes the level only if Hue refuses the stop. | Hue §4.2, §10. Exact end levels for any preset and for off; the true target in CHANGING. |
| D9 | **The fallback (option C), one constant.** `STOP_MODE` in `src/hue_light/driver.lua` is `"stop"` (D8) or `"level"`. With `"level"`, the stop sends `HUE_SET` with the estimate as the brightness and rate 0, marked urgent. The house measurement (section 7) decides which ships, before the release. No property. | Hue §4.3. If Hue does not stop an absolute transition, the estimate is the only stop. |
| D10 | **Reporting.** `LIGHT_BRIGHTNESS_CHANGING` goes out at the ramp's start, with the current level, the target and the ramp time. `LIGHT_BRIGHTNESS_CHANGED` goes out once, at the stop (the estimate) or at the end. Bridge reports of the level are held back while the ramp runs, because Hue may report the target at once (Hue §5). An off report and a change that clearly did not come from this ramp go through and end the ramp. After a stop, the bridge's next report corrects the estimate. | C4 §3.2, light_v2 best practice. Tiles animate from CHANGING and freeze on CHANGED. |
| D11 | **Other commands during a ramp.** Any brightness command (ON, OFF, TOGGLE, a level, a target, Raise Level By, Restore Saved Level) replaces the ramp, and the driver is idle again. A colour command does not end it. | C4 §7.2, light_v2 best practice on consecutive commands. |
| D12 | **Urgent starts.** A keypad tap's start and a `"level"` stop go out at once, past the request bucket, as a hold's start and stop already do. `HUE_SET` carries `urgent = "true"` for them. | Hue §7. A stop must never sit behind other requests. |
| D13 | **An unsent start.** If a stop reaches the bridge's queue while that light's or group's start is still waiting there, nothing is ramping at Hue yet. The queue replaces both with the stop's `level` as an absolute level, rate 0. | Hue §7. The lamp then matches the level the device has already published. |
| D14 | **Zone and room lights.** The same code path: `HUE_SET` with a rate to the grouped_light, and `HUE_DIM` stop to it, through the existing `zone_lights` and `group_hold` routes (a stop with no running hold goes to the group queue unchanged, group-hold G7). Whether a grouped_light honours the duration and the stop is measured (section 7, Z1 and Z2). If not, the group tap degrades to today's quick change, and a follow-up issue builds group tap ramps from group_hold's per-lamp split. | Hue §6. One mechanism first; the split only if Hue needs it. |
| D15 | **House devices with a stored click rate.** The install brief has the Windows session read every Hue Light device's Click Rate Up and Down and set any that differ to 3000 ms. That also checks that Composer accepts 3000 ms: the reference gives `click_rate_max` a default of 1, and the driver declares no maximum (#430). If Composer refuses, #430's explicit `click_rate_max` comes first. | C4 §5.2. A changed default does not reach a stored value. The house has used a 750 ms click rate on a zone light (`docs/composer-checklist.md` step 42), so larger values have been accepted before. |

## 3. The rule

"Within the window" means a press within `DOUBLE_TAP_MS` of the previous
press on the same button. "Ramping" means a ramp of D6 is running. A level
is "at the preset" within 1 point.

| State | Input | Action |
| --- | --- | --- |
| Idle, off | top tap or toggle tap | Ramp to the preset over `click up × preset / 100` |
| Idle, on below the preset | top tap | Ramp up to the preset over `click up × distance / 100` |
| Idle, on above the preset | top tap | Ramp down to the preset over `click down × distance / 100` |
| Idle, at the preset | top tap | Nothing at Hue; CHANGED with the level |
| Idle, on | bottom tap or toggle tap | Ramp to off over `click down × level / 100` |
| Idle, off | bottom tap | Nothing |
| Any | a press within the window | Ignored (D4); a running ramp goes on; held, it becomes a hold |
| Ramping | a press outside the window, on any button | Stop (D5); the click that follows is swallowed |
| Ramping | that press held past `HOLD_AFTER_MS` | Stop, then hold from the stopped level: top up, bottom down, toggle by the on state |
| Ramping | the ramp's time runs out | Idle; the end level comes from Hue's report, or the target after the fallback time |
| Ramping | `SET_BRIGHTNESS_STOP` or `STOP_SCENE_RAMP` | Stop (D7) |
| Ramping | any brightness command | The command takes over; idle (D11) |
| Ramping | a colour command | The ramp goes on |
| Holding | anything | Unchanged (#249) |
| Idle, within `CLICK_GUARD_MS` after a hold's release, same button | click | Ignored (unchanged) |

A ramp time of 0 (a dealer who sets a click rate of 0) is an instant change
with nothing to stop, as today.

A stop very close to off (estimate below 1) stops at 1 %: the light stays on,
as a dimmer stopped near the bottom does.

## 4. Interfaces

### 4.1 `src/common/device.lua` (the shared button machine)

- `device.DOUBLE_TAP_MS = 600`, exported for the specs.
- The machine keeps, per button, the time of the last press, from the
  controller's clock in milliseconds (`C4:GetTime()` [verified: API 34/_2],
  falling back as the drivers already do).
- Two new hooks, with defaults that keep today's behaviour, so Hue Scene
  devices only get the window:
  - `function dev.ramp_active() return false end`: true while a ramp of D6
    runs;
  - `function dev.on_ramp_stop(button) end`: stop it now (D5, D7).
- On a press:
  - within the window: the press record is marked `multi`;
  - otherwise, if `dev.ramp_active()`: call `dev.on_ramp_stop(button)` and
    mark the press record `stopped`;
  - either way the hold timer starts as today, so a held press becomes a
    hold.
- On a click: a click on a press record marked `multi` or `stopped` is
  swallowed and never reaches `dev.on_click`. A click with no press record
  (a route that sends only the click) applies the same window and stop rules
  at the click itself.
- Click Rate Up and Down defaults: 3000 (D3). Nothing else in `SETTINGS`
  changes.
- `CLICK_GUARD_MS` and the hold machine stay as they are. A stop is not a
  hold release, so it arms no guard.

### 4.2 `src/hue_light/driver.lua` (owns the ramp)

- A ramp record, kept for any brightness change with a time above 0 whose
  send succeeded: `{ from, to, time, started, tap }`. Levels are proxy levels
  0–100, `to` is 0 for off, and `started` is in controller milliseconds.
  - It ends when the time runs out, at a stop, at any other brightness
    command, and at the start of a hold.
  - `dev.ramp_active()` is true while it exists.
- `dev.on_click` follows section 3. Ramp time = rate × distance / 100,
  rounded to whole ms. `set_brightness` gains an `urgent` flag for taps.
- `stop_ramp(why)`:
  - The estimate is `from + (to − from) × elapsed / time`, rounded, and at
    least 1 while the light is on.
  - With `STOP_MODE == "stop"`, send `HUE_DIM` with `direction = "stop"` and
    `level = estimate`. With `"level"`, send `HUE_SET` with on, the estimate
    as brightness, rate 0 and `urgent = "true"`.
  - Apply the estimate to the cache, so a hold or the next tap starts from
    it, and send `LIGHT_BRIGHTNESS_CHANGED` with it at once.
  - The bridge's next report goes through and corrects the estimate.
- `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` call `stop_ramp` when a ramp
  runs. Otherwise they keep today's behaviour.
- While the ramp runs, brightness reports from the bridge are held back
  (D10), in the way `hold_stale` holds them for #308. At the end, the latest
  held report is applied and CHANGED is sent. An off report goes through and
  ends the ramp.
- The #308 turn-on guard still applies to a tap ramp from off. A stop during
  its wait settles it.

### 4.3 The bridge (`src/hue_bridge/`)

- `HUE_SET` gains an optional `urgent = "true"`. The handler in `driver.lua`
  (the coordinator's file) and `zone_lights:set` copy it into the queued
  fields as `urgent = true`.
- `commands.urgent(pending)` is also true for `pending.urgent == true`. The
  merge of pending fields keeps `urgent` while any merged part had it.
- D13 in the light queue and the group queue (both `commands.lua`
  instances): a `dim = "stop"` merged onto unsent absolute fields that carry
  a rate becomes an absolute `brightness = level` with rate 0 (on true when
  level > 0), urgent, and no dimming_delta.
- The bridge's `HUE_DIM` stop path is otherwise unchanged. It already sends
  `dimming_delta` stop and writes `level` when Hue refuses it.

## 5. Files and owners

Agents edit only their own files; others are editing the rest of the checkout
at the same time. No agent runs git.

| Owner | Files |
| --- | --- |
| Agent A | `src/common/device.lua`, `tests/spec/device_spec.lua` |
| Agent B | `src/hue_light/driver.lua`, `src/hue_light/light/state.lua` if needed, `tests/spec/light_driver_spec.lua`, `tests/spec/light_relative_level_spec.lua` if affected |
| Agent C | `src/hue_bridge/bridge/commands.lua`, `src/hue_bridge/bridge/zone_lights.lua`, `tests/spec/commands_spec.lua`, `tests/spec/zone_lights_spec.lua`, `tests/spec/zone_light_roundtrip_spec.lua` if affected |
| Agent D | `src/hue_light/www/documentation.html`, `src/hue_scene/www/documentation.html`, `src/hue_bridge/www/documentation.html` (only where it describes taps or click rates), `docs/keypad-design.md`, `docs/composer-checklist.md` |
| Coordinator | `src/hue_bridge/driver.lua` (the `HUE_SET` handler's `urgent`), `CHANGELOG.md`, `docs/README.md`, `docs/status.md`, this file, integration and commits |

## 6. Done for each agent

- The behaviour in sections 2 to 4 for the agent's files, with busted specs
  for every row of section 3 that the files touch. Use the fake C4 runtime the
  existing specs use, including timers and `C4:GetTime`.
- Lua 5.1 only, tabs, `.luacheckrc` clean.
- `luacheck src tests tools`, `busted tests` and `python3 tools/lua_limits.py`
  pass. `python3 tools/check_links.py` passes for Agent D.
- Comments cite this contract as `#421 D<n>`, and mark DriverWorks or Hue
  claims [verified: …] or [assumed] as the code already does.

## 7. On the house, before the release

1. **Measure (dev loop).** Install a `--dev` build and run Hue §9's steps:
   L1–L11 on one lamp and Z1–Z7 on one zone. The results go into #421 as
   comments.
   - If L2 fails (a stop does not halt an absolute transition), set
     `STOP_MODE = "level"`.
   - If Z1 or Z2 fails, open the follow-up issue of D14.
2. **The C4 checks with the owner at a switch** (C4 §9), each under a
   minute:
   - the order and timing of a tap's and a double tap's commands;
   - the keypad's real double-tap window;
   - whether the Brightness Stop link sends `SET_BRIGHTNESS_STOP`.
3. **Then the release**, its install, and D15's click rate read-back.

## 8. Not in this issue

- Light-side double-tap events: they would need `has_button_events`, a
  capability change and a controller reboot (C4 §1.5).
- A colour command dropped beside a pending dim in the queue (Hue §7). It is
  a light_v2 best-practice gap of its own, for the guidelines audit (#422).
- Group tap ramps built from group_hold's split (D14), only if the
  measurement asks for them.

## 9. Control4 guidelines

The rows of C4 §8, as decided here:

| C4 §8 row | Guideline | How this design meets it |
| --- | --- | --- |
| 1 | A tap ramps to full or off, and a tap while dimming stops it | D2, D5, section 3. Departure only if Z1/Z2 fail for groups (D14). |
| 2 | A hold brightens or dims while held | Unchanged; a hold during a ramp starts from the stop (section 3) |
| 3 | The On preset applies whatever the level | D2 |
| 4 | Click and hold rates are whole-range times | D3 |
| 5 | Click rates for fast changes, hold rates for slow | 3000 ms click under 5000 ms hold (D3) |
| 6 | Rates within the declared min and max | No capability change; 0 still allowed |
| 7 | Double and triple taps within about half a second | D4 |
| 8 | Echo every `BUTTON_ACTION`; a release follows a push | Unchanged echo before the machine |
| 9 | On a link, act on the push where hold versus click does not matter | The stop acts on the push (D5) |
| 10 | CHANGING at the start, CHANGED at the end, no incremental levels | D10 |
| 11 | Tiles animate from CHANGING | D10 |
| 12 | `supports_brightness_stop` means a ramp can be stopped | D7, D8 (or D9) |
| 13 | Ramp events and `IS_BRIGHTNESS_TARGET` fire once per ramp | D10 |
| 14 | Keypad LEDs follow the bound device | Unchanged: LEDs follow the on state |
| 15 | Default On and Dim colours | Unchanged departure: the driver declares no colour on modes |
| 16 | Consecutive brightness and colour commands do not cancel each other | D11 |
| 17 | UI Button and Light Extras | Not used |

The full checklist the project keeps is `docs/c4-lighting-guidelines.md`
(#422). Its rows for #421 are L3, L4, L12, L15, L16, L38, L44, L45 and L46
(its §4, item 1); L46, the light's own button events, stays out of this
issue (section 8) and goes to #432.

## 10. Measured on the house, and scenes (2026-11-09)

Measured through the dev loop on build 552, with the owner watching the
lamps (one single light, one two-lamp zone, one two-lamp room and its
scene). The results are also in #421.

| Step | Result | Status |
| --- | --- | --- |
| L1 | The bridge reports a timed target at once, about 50 ms after the PUT, while the lamp is still fading | [verified] D10's hold-back is needed |
| L2 | `dimming_delta` stop halts a timed absolute fade on a light: the lamp held at about 60 % | [verified: owner watching] |
| L2, bridge | After such a stop the bridge keeps the fade's target as the level, and computes relative commands without a duration from it, until about 10 s after the fade's planned end, when it reads the lamp (57.31 % against an estimate of 57.6) | [verified] |
| D9 instant | Writing the estimate at once (rate 0) showed a small step down: Hue's fade runs slightly behind a linear estimate | [verified: owner watching] |
| D9 glide | Writing the estimate with a 1000 ms transition looked smooth, and the bridge then reports the estimate at once | [verified: owner watching, twice] |
| Z1 | A grouped_light honours an absolute `dynamics.duration`: a zone faded over 20 s | [verified: owner watching] |
| Z2 | The gliding level stop on a grouped_light is smooth on every lamp | [verified: owner watching] |
| S1 | A scene recall with `duration` fades the scene in over that time | [verified: owner watching] |
| S2 | A grouped_light `dimming_delta` stop halts a scene's fade-in partway, each lamp at its own level | [verified: owner watching] |
| S3 | A per-lamp `dimming_delta` with a duration (a hold) right after such a stop rises smoothly from where the lamps stopped, not from the bridge's stale level | [verified: owner watching] |
| S4 | A grouped_light `on: false` with a duration fades out, and a stop leaves the lamps lit at a dimmer level | [verified: owner watching] |

**Decisions from the measurement:**

- D8/D9: `STOP_MODE = "level"` with `STOP_GLIDE_MS = 1000` for Hue Light
  devices, single and zone or room alike (Z1, Z2 passed, so D14's
  follow-up is not needed).
- D1 is changed by the owner (2026-11-09: "Scenes can ramp so tap to stop
  ramp should apply to them too"): **Hue Scene devices get tap ramps and
  tap stops too.**

### 10.1 Scenes

| # | Decision |
| --- | --- |
| S-D1 | A top tap, or a toggle tap while the scene is off, recalls the scene over `click up × (100 − level) / 100`, as the scene's recall with a `duration` (S1). A tap on an ordinary scene that is already on at 100 does nothing at Hue and reports CHANGED. |
| S-D2 | A bottom tap, or a toggle tap while it is on, turns the scene's group off over `click down × level / 100`: the grouped_light `on: false` with a `duration` (S4). |
| S-D3 | The stop is the grouped_light `dimming_delta` stop (S2): **not** a level write, which would bring every lamp to one level and lose the scene's look. It goes out as `HUE_SCENE_DIM` with `direction = "stop"` and the estimate as `level`, which the bridge writes only if Hue refuses the stop. The device reports its estimate as CHANGED at once. The bridge's report of the real level arrives about 10 s after the fade's planned end; it goes through. Holds right after a stop are safe (S3). |
| S-D4 | The same machine as the lights: the double-tap window (D4), the stop on the press (D5), `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` (D7), the reporting (D10), and other commands taking over (D11). The hooks `dev.ramp_active` and `dev.on_ramp_stop` are implemented by the scene driver. |
| S-D5 | Time-based (smart) scenes keep today's taps: activate and deactivate have no duration at Hue, so there is nothing to ramp or stop. Departure from C4 §8 row 1, forced by Hue. The double-tap window still applies. |
| S-D6 | `HUE_SCENE_OFF` gains an optional `duration` (ms, clamped as a recall's); the bridge passes it to the group off as `dynamics.duration`. A keypad tap's recall and off are urgent, as D12. |
