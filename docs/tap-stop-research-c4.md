# Tap to ramp, tap again to stop: the Control4 side (#421)

Research note for issue #421, written 2026-11-08 by a read-only research
agent. It covers the Control4 side only. A separate note covers the Hue
side: whether and how a lamp, a zone or a room can ramp and be stopped.
Nothing here is built yet.

The owner's request, in short:

- A keypad tap ramps the light from wherever it is to the top (On preset)
  or to off.
- A second tap while it ramps stops it where it is.
- That second tap only counts once Control4's double-tap window has
  passed, because a double tap can trigger programming.
- The default click rates are slow enough to catch the ramp, both up and
  down.

Today a tap sends one absolute brightness target over the click rate (250 ms
by default), and a second tap starts the same ramp again
(`src/hue_light/driver.lua:1013`, `dev.on_click`;
`src/common/device.lua:110`, `SETTINGS`).

## Sources and how claims are marked

Every API claim is marked **[verified: source]** or **[assumed]**. Code
facts are marked **[code: path:line]**. Short names for the sources:

| Short name | Where |
| --- | --- |
| LV2 | `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/` |
| KP | `~/c4-tools/reference/docs-driverworks-proxyprotocol-keypad/source/includes/` |
| UIB | `~/c4-tools/reference/docs-driverworks-proxyprotocol-uibutton/source/includes/` |
| FUND | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/` |
| API | `~/c4-tools/reference/docs-driverworks-api/source/includes/` |
| C4-USER | Control4 user guide, switches, dimmers and keypads: <https://docs.control4.com/help/c4/user/userguide/content/topics/lighting/switches-keypads.htm> |
| C4-LIGHTING | Composer Pro help, configuring lighting: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/configuring_lighting.htm> |
| C4-DIMMER | Composer help, device settings for dimmers: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> |
| C4-DIMPROPS | Composer Pro help, dimmable light properties: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/set_dimmable_light_properties.htm> |
| C4-KEYPAD | Composer Pro help, keypad properties: <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/keypad_properties.htm> |

The c4forums.com threads that come up in searches refused automated
fetches (HTTP 403). Nothing here rests on them.

## 1. How taps and double taps reach a light_v2 driver

### 1.1 Two routes into the driver

| Route | What arrives | Status |
| --- | --- | --- |
| A keypad button bound to the driver's own Top, Bottom or Toggle Button Link (connections 200 to 202) | `DO_PUSH`, then `DO_CLICK` for a tap or `DO_RELEASE` after a hold, on the binding id | [verified: KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; on the house, `docs/keypad-design.md` "Hardware findings"] |
| The proxy's `BUTTON_ACTION` on binding 5001 | `BUTTON_ID` 0 top, 1 bottom, 2 toggle; `ACTION` 1 press, 2 release as a click, 0 release after a hold | [verified: LV2 `10_light_v2_commands/_1-BUTTONACTION.md`] |

Both routes end in one state machine, `dev.button_action`
[code: `src/common/device.lua:650`]. The house's keypads use the first
route [verified: `docs/keypad-design.md` "Hardware findings"].

On a link, the documented commands are only push, click and release. The
keypad link page says some newer devices have "specific double and triple
click support", and that older drivers never adopted those multi-press
calls. It does not name them [verified: KP `62.../_1`]. Every proxy command
is logged at debug level with its binding [code:
`src/common/dispatch.lua:54`]. So with `Debug Mode` On, a real double tap
would show any such command.

### 1.2 Who counts clicks

The light driver never counts double taps for the keypad's programming.
A keypad's own protocol driver reports multi-taps to the **keypad** proxy:

- `CLICK_COUNT` lets the proxy fire the single, double or triple event
  [verified: KP `61_keypad_protocol_notifications/_2-CLICKCOUNT.md`];
- `KEYPAD_BUTTON_ACTION` carries 3 for a double click and 4 for a triple
  [verified: KP `61.../_4-KEYPAD_BUTTON_ACTION.md`].

That a stock Control4 keypad does this itself, whatever its buttons are
bound to, is **[assumed]**. It follows from these notifications belonging
to the keypad's protocol driver.

A light_v2 driver has its own, separate button events: Release, Push,
Single, Double and Triple Click for each of Top, Bottom and Toggle. Their
event id is 5001 + action + 5 × button [verified: LV2
`25_light_v2_events/_0-HEADER.md`]. Here the **protocol driver** counts and
tells the proxy:

- the proxy's `BUTTON_ACTION` notification takes 2 single, 3 double and
  4 triple tap [verified: LV2
  `35_Light_v2_protocol_notifications.../_1-BUTTONACTION.md`];
- `CLICK_COUNT` also tells the proxy about multiple clicks [verified: LV2
  `35.../_3-CLICKCOUNT.md`].

Composer lists these events only when the driver declares
`has_button_events` [verified: LV2
`5_light_v2_capabilities/_26-HASBUTTONEVENTS.md`]. The Hue drivers do not
declare it [code: `src/hue_light/driver.xml`, `src/hue_scene/driver.xml`].

`multi_click`, available from OS 3.4.2 and true by default, lets a light
driver remove press, release, single, double and triple click programming
from Composer [verified: LV2 `5.../_28.5-multiclick.md`;
`~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/3_whats_new/_7-WHATSNEWIN342.md`]. The Hue drivers
do not declare it.

So the double tap the owner means is the **keypad's** event: "when the switch's top button is double tapped". The light sees two taps.

### 1.3 Is the first tap held back?

There is no evidence that it is, for the light.

- Composer's lighting help says that Press and Release events fire as well
  when double and triple taps happen, and advises against programming both
  on one button [verified: C4-LIGHTING]. So each tap's press and release go
  out as they happen.
- The keypad link page tells drivers that do not care about hold versus
  click to act on the push [verified: KP `62.../_1`]. A keypad that delayed
  its pushes would make that advice pointless.
- Whether a keypad with double-tap programming delays the `DO_CLICK` it
  sends over a link is not documented **[assumed: not delayed]**. It needs
  one look on the house (§9).

Only the keypad's own single-tap **event** has to wait to know whether a
second tap follows. Dealer forum posts describe that delay, but those
pages could not be read here.

### 1.4 The double-tap window

- Length: Composer Pro's help says the double and triple tap events fire
  when the taps come within "about one-half of one second" [verified:
  C4-LIGHTING].
- Configurable: none of the following offers a setting for it:
  - the light_v2 capabilities [verified: LV2 `5_light_v2_capabilities/`,
    the whole list];
  - the keypad proxy's only capability [verified: KP
    `61.1_keypad_capabilities/_1-clearledcurrentcolorsupport.md`];
  - Composer's keypad properties page [verified: C4-KEYPAD].

  It is therefore the keypad firmware's own, fixed value **[assumed]**.
- What "within" is measured from (press to press, or release to press) is
  not stated **[assumed: press to press]**.

### 1.5 What the driver must send back

- Proxy route: echo every `BUTTON_ACTION` with the same button and action.
  Without the echo of a press, the proxy invents a second press when it
  sees the click [verified: LV2 `10.../_1-BUTTONACTION.md`].
- After any push, the proxy expects a release. Without one, later pushes
  fail [verified: LV2 `35.../_1-BUTTONACTION.md`].
- The driver echoes before the machine runs [code:
  `src/common/device.lua:700`]. So a tap the machine later ignores is still
  echoed, as it must be.
- Link route: nothing goes back for a push, click or release. The links
  carry only LED state and colours back (`MATCH_LED_STATE`,
  `BUTTON_COLORS`) [verified: KP `62.../_1`].
- Keypad double-tap events need nothing from the light driver (§1.2).
- Light-side double-tap events would need `has_button_events` (a
  capability change, so a controller reboot) and a `BUTTON_ACTION` 3 or
  `CLICK_COUNT` notification. They are out of scope for #421.

### 1.6 Can the driver tell a coming double tap from a single tap?

- At the first tap: no. The only way would be to wait out the window
  before acting, and that adds about half a second to every tap. The owner's
  rule ("a tap starts a ramp") rules that out.
- At the second tap: yes, by time alone. If its press comes within the
  window of the previous press **on the same button**, it is the second tap
  of a double tap.
- What to do with it: nothing. The first tap's ramp keeps going, the
  keypad's programming does whatever it does, and a third tap within the
  window is treated the same way. A double tap on toggle then means "on"
  (the ramp continues), not "on, then off again".

## 2. Click rate semantics

The proxy reference defines a click rate as the time of the **whole
range**:

- `CLICK_RATE_UP` is the time from "all the way off to all the way on";
- `CLICK_RATE_DOWN` is the same from on to off [verified: LV2
  `35.../_5-CLICKRATEUP.md`, `_4-CLICKRATEDOWN.md`].

The hold rates are defined the same way [verified: LV2 `35.../_10-HOLDRATEUP.md`,
`_9-HOLDRATEDOWN.md`]. The Hue Light already treats its hold rates that way
[code: `src/hue_light/driver.lua:1048`, `start_ramp`].

Composer's own pages are vaguer:

- one calls the click rate the rate the light ramps from off to on when the
  button is clicked [verified: C4-DIMPROPS];
- another calls it how long the dimmer takes to fade up to the On preset
  [verified: C4-DIMMER].

Neither says what happens for a shorter distance.

**Finding: the protocol text confirms whole-range semantics for click rates,
as for hold rates.** Today a tap uses the click rate as the transition time
whatever the distance [code: `src/hue_light/driver.lua:1013`]. For tap-stop,
a constant speed matters: the person catching the light must see the same
pace from any level. Recommendation: a tap ramp takes
`click rate × distance / 100`, as a hold does.

## 3. supports_brightness_stop and reporting

### 3.1 What it enables, and whether the proxy has a stop of its own

- `supports_brightness_stop` says a brightness transition can be stopped
  during a ramp. The reference names the Daylight Agent and reduced
  Advanced Lighting Scenes ramps as its users [verified: LV2
  `5.../_29-SUPPORTSBRIGHTNESSSTOP.md`].
- The stop itself is `SET_BRIGHTNESS_STOP`, with no parameters, which stops
  a ramp in progress [verified: LV2 `10.../_21.5-SET_BRIGHTNESS_STOP.md`].
- With the capability, the proxy creates a **Brightness Stop** Button Link,
  and a Color Stop one for colour [verified: on the house,
  `docs/keypad-design.md` "Hardware findings"].
- A keypad button bound to that link is meant to stop the ramp. OS 3.3.2 had
  a defect that broke this, fixed in 3.3.3 [verified: LV2 `5.../_29`; LV2
  `3_whats_new/_10-WHATSNEWIN332.md`, Known Issues]. That the link reaches
  the driver as `SET_BRIGHTNESS_STOP` is **[assumed]**.
- `STOP_RAMP_SCENE` ends a ramping Advanced Lighting Scene [verified: LV2
  `45_Light_V2_advanced_lighting_scene/_4.2-STOPRAMPSCENE.md`].

**There is no built-in "tap again to stop".** The proxy forwards the button
actions to the driver and documents no click counting, toggling or stopping
of its own [verified: LV2 `10.../_1-BUTTONACTION.md`]. Navigator sends targets
(`SET_BRIGHTNESS_TARGET`) [verified: on the house, `docs/design.md`
"Navigator slider"]. Whether it ever sends a stop is undocumented
**[assumed: it does not]**. So the tap-stop logic is the driver's to build.

Control4 does have a stop **entry point**: the Brightness Stop link and
`SET_BRIGHTNESS_STOP`. Today the Hue Light answers that command with its
cached level only, and the lamp keeps ramping ("Hue has no stop primitive")
[code: `src/hue_light/driver.lua:420`, `:962`]. With tap-stop, the driver
gets a real stop. `SET_BRIGHTNESS_STOP` should use it too, which finally
honours the capability both drivers already declare.

### 3.2 What the driver reports during and after a ramp and a stop

| Moment | Notify | Source |
| --- | --- | --- |
| The ramp starts | `LIGHT_BRIGHTNESS_CHANGING` with `LIGHT_BRIGHTNESS_CURRENT` (where it is), `LIGHT_BRIGHTNESS_TARGET` (the preset, or 0) and `RATE` (ms to reach it) | [verified: LV2 `35.../_10.3-LIGHTBRIGHTNESSCHANGING.md`] |
| The ramp is stopped | `LIGHT_BRIGHTNESS_CHANGED` with where it stopped | [verified: FUND `27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`, which gives a hold released at 30 % as the example] |
| The ramp ends by itself | `LIGHT_BRIGHTNESS_CHANGED` with the end level | [verified: LV2 `35.../_10.2-LIGHTBRIGHTNESSCHANGED.md`] |
| In between | nothing: no periodic level notifies | [verified: LV2 `35.../_12-LIGHTLEVEL.md` usage note; FUND `27.../_50`] |

- **Tiles:** Customer Interfaces watch `LIGHT_BRIGHTNESS_CHANGING` and
  animate the change from its current level, target and rate [verified:
  FUND `27.../_50`].
- **Navigator:** for UIs that ask in mid-ramp, the proxy keeps the ramp
  rate and the time remaining (variables 1120 and 1121), updated each
  second [verified: LV2 `30_Light_v2_variables/_0-HEADER.md`]. That it
  derives them from the CHANGING notify is **[assumed]**.
- **Programming:** CHANGING drives the "Brightness Begins to ramp" event
  (4000) and the `IS_BRIGHTNESS_TARGET` conditional [verified: LV2
  `25.../_0-HEADER.md`, `20_light_V2_conditionals.../_0-HEADER.md`;
  FUND `27.../_50`]. CHANGED drives event 4001.

The light driver already follows this pattern for holds: CHANGING toward
the end of the range, then the stop's estimate as CHANGED after a fallback
time, or the bridge's next report [code: `src/hue_light/driver.lua:1048`,
`:1105`]. A tap ramp reuses it with a known target.

### 3.3 What the Hue drivers declare today

| Capability | `hue_light` | `hue_scene` | Note |
| --- | --- | --- | --- |
| `click_rates` | True | False | Click rate rows appear only with it [verified: LV2 `5.../_11-CLICKRATES.md`] |
| `click_rate_min` / `_max` | 0 / not declared | — | The reference says the max defaults to 1 ms [verified: LV2 `5.../_13-CLICKRATEMAX.md`]. The variables example shows 86 400 000 [verified: LV2 `30.../_0-HEADER.md`]. The house has run click rates of 250 and 750 ms [verified: `docs/composer-checklist.md` step 42]. So the effective max is not 1 ms **[assumed: 86 400 000]**. |
| `hold_rates`, `hold_rate_min` | True, 1000 | True, 1000 | |
| `supports_default_on` | True | — | `SET_PRESET_LEVEL` brings the On preset [verified: LV2 `5.../_32-SUPPORTSDEFAULTON.md`] |
| `supports_target` | True | True | |
| `supports_brightness_stop` | True | True | |
| `has_leds` | True | True | |
| `has_button_events`, `multi_click` | not declared | not declared | Defaults false and true |

[code: `src/hue_light/driver.xml`, `src/hue_scene/driver.xml`]

**The tap-stop design needs no capability change, so no controller
reboot.** The rates, the stop and the targets are all declared already.

## 4. A stock Control4 dimmer

| Question | Answer | Status |
| --- | --- | --- |
| Tap top, tap bottom | Top ramps up to full brightness, bottom ramps down until off | [verified: C4-USER] |
| A tap while it ramps | While the light is dimming, a tap stops it at that point | [verified: C4-USER] |
| The same while brightening | Not stated. The guide's "at any time" suggests yes | **[assumed]** |
| A tap on the other half mid-ramp | Not stated. The guide's wording ("tap the dimmer") reads as any tap | **[assumed: stop]** |
| A second tap on the toggle mid-ramp: stop or reverse | Not documented anywhere found | **[assumed: stop]** |
| A top tap when the light is already at the target | The On preset is where a top tap goes whatever the level, even from a higher one, so a light at it stays | [verified: LV2 `30.../_0-HEADER.md`, Default On Preset Brightness, id 1006] |
| A bottom tap when the light is off | Nothing to do | **[assumed]** |
| Default click and hold rates | No public Control4 page gives them | [verified absent: C4-DIMMER, C4-DIMPROPS]; unknown |

The two light_v2 devices on the house are hints, not proof. A zone light ran
its bottom tap over a click rate of 0.75 s [verified:
`docs/composer-checklist.md` step 42], and a Navigator ON on a scene device
arrived with a 750 ms rate [verified: `docs/design.md`, first scene device].
That 750 ms is the proxy's own default is **[assumed]**.

A hold brightens or dims while held [verified: C4-USER]. The hold rates are
the time from off to full while held, and from on to off [verified:
C4-DIMMER].

## 5. Defaults, and the devices already in the house

### 5.1 Recommended click rates

The second tap can only stop the ramp once the window of about 0.5 s has
passed, and in practice a person takes 0.8 to 1 s to decide. A ramp
therefore has to last well beyond a second to be caught.

- At today's 250 ms the ramp is over before the window ends.
- At the 750 ms the house has seen, it is over before a person can react.

**Recommendation: Click Rate Up 3000 ms and Click Rate Down 3000 ms**, each
for the whole range (§2). With that:

- from off, at the end of the window the light is at about 20 %;
- reaching 50 % takes 1.5 s;
- a tap from 70 % to 100 % takes 0.9 s.

Keep the click rates below the hold rates (5000 ms). The click rates also
drive the proxy's "Fast On" and "Fast Off" presets, and the hold rates its
"Slow On" and "Slow Off" [verified: LV2 `5.../_11-CLICKRATES.md`;
`35.../_10-HOLDRATEUP.md`, `_9-HOLDRATEDOWN.md`]. "Fast" should stay faster
than "Slow".

### 5.2 Which devices a new default reaches

- The defaults live in Lua (`SETTINGS` in `src/common/device.lua:110`), not
  in `driver.xml`. The XML declares only `click_rates` and `click_rate_min`
  [code].
- A device stores a rate only when the proxy sent `SET_CLICK_RATE_*`, that
  is, when someone edited the row in Composer [code:
  `src/common/device.lua:537`, `save_setting`].
- At late init each device reads its stored value, or the default when
  there is none, and reports the value in use to the proxy [code:
  `src/common/device.lua:517`, `load_settings`].

So:

| Device | After installing a build with the new default |
| --- | --- |
| Never had its rate edited | Uses the new default at once, and Composer shows it after the device's late init. Lua only: no reboot. |
| Rate edited in Composer | Keeps its stored value. The default does not touch it. |

Changing the default does **not** need `SET_CLICK_RATE_*` for each device.
A stored value is changed only by editing the row in Composer, which sends
`SET_CLICK_RATE_*` [verified: LV2 `10.../_22-SETCLICKRATEUP.md`,
`_23-SETCLICKRATEDOWN.md`].

Whether the proxy ever pushes its stored value to the driver unasked (for
example at Director start) is unknown [verified: open in
`docs/keypad-design.md`, "What the proxy does"]. The zone light's 0.75 s
suggests that some value was stored on at least one house device. A
Windows-session read of every Hue Light's Click Rate rows after the install
settles it (§9).

No automatic migration of stored values: it would overwrite a dealer's
choice, which the project's edge-case rule forbids without a click.

The meaning of a stored rate changes too, from "a tap's time" to "the
whole range's time". A tap from off to 100 % is unchanged, and a shorter
tap gets shorter. The changelog should say so.

## 6. Which devices

| Driver | Kinds | Tap-stop? | Why |
| --- | --- | --- | --- |
| `hue_light.c4z` | single lights | **Yes** | The request's subject |
| `hue_light.c4z` | zone lights and room lights | **Yes**, with a Hue-side caveat | Same driver, `kind` "group" [code: `src/hue_bridge/bridge/zone_lights.lua:2`, `:58`; `docs/zone-light-design.md` §2], so they get the same machine. Their ramp reaches Hue through the grouped_light. Hue ignores the duration of a grouped_light `dimming_delta` (#249), so a tap ramp needs the group-hold modes of `docs/group-hold-design.md`: per lamp for 1 to 10 lit, stepped above that or while a scene runs. Today `group_hold.lua` treats only a whole-range delta as a hold (G2), so a tap ramp to the preset needs its own handling there. That is the Hue note's and the coordinator's part. |
| `hue_scene.c4z` | scenes | **No ramp, no stop** | A scene tap is a recall (top), the group off (bottom) or a toggle, not a ramp to a level [code: `src/hue_scene/driver.lua:1202`, `dev.on_click`; `:1174`, `TOGGLE`]. It declares `click_rates` False, so it has no click rate to ramp over. Adding one is a capability change, so a reboot. |
| `hue_motion.c4z` | motion | Not applicable | Its proxy is the contact proxy for motion sensors, with no keypad buttons [code: `src/hue_motion/driver.xml`] |

The scene driver's tap code is `dev.on_click` at
`src/hue_scene/driver.lua:1202`. The double-tap window of §7 sits in the
shared machine, so scenes would get it too: the second tap of a double tap
would do nothing. Today a double tap on toggle turns the scene on and then
off again. That is a real choice (open question 5).

## 7. Where the logic belongs

### 7.1 The split

**Shared machine (`src/common/device.lua`)** owns keypad timing, as it does
for holds and the click guard:

- **The double-tap window.** A per-button record of the last press time and
  a constant `DOUBLE_TAP_MS`, a module field like `HOLD_AFTER_MS`. Start
  with 600 ms: a little above Control4's "about one-half of one second",
  and tunable once measured (§9).
  - A press within the window of the previous press on the same button is
    marked `multi`.
  - Its click never reaches `dev.on_click`.
  - Its hold, if it becomes one, still starts.
- **The stop on press.** Two new hooks: `dev.tap_ramping()`, true while the
  driver's tap ramp runs, and `dev.on_tap_stop()`.
  - A press that is not `multi`, while `dev.tap_ramping()` is true, calls
    `dev.on_tap_stop()` at once and marks the press `stopped`.
  - Its click is then swallowed.
  - If the press is held past `HOLD_AFTER_MS`, the hold starts as usual,
    from the stopped level.

  Stopping on the press, not the click, catches the light where the person
  pressed. It also follows the keypad link page's advice to act on the push
  when hold versus click does not matter [verified: KP `62.../_1`].
- **Keypads that send no push.** A click with no press on record is treated
  as a press and a click together, as the machine already does.

**The Hue Light driver (`src/hue_light/driver.lua`)** owns the ramp:

- its record: direction, start level, target, start time, duration and end
  timer;
- the CHANGING at the start;
- the estimate at any moment, from the elapsed time. `C4:GetTime` gives
  milliseconds [verified: API `34_timer/_2-GetTime.md`];
- the stop: the Hue request per the Hue note, CHANGED with the estimate,
  and the fallback as in `dev.on_finish`;
- the end: back to idle at the planned end, with Hue's report settling the
  tile;
- clearing the record when any other brightness command arrives.

The scene driver answers `dev.tap_ramping()` with false.

Why split it this way: the window and press handling are about keypad input
and would otherwise be copied into each driver, which is what #57 removed.
The level, the target and how to stop at Hue are the light's own business.

### 7.2 Interactions to settle

| Interaction | Rule |
| --- | --- |
| Hold machine | A hold that begins during a tap ramp first stops it, then holds from the **stop's estimate**, not from `st`'s level, which Hue has not corrected yet. Down from off still does nothing. |
| `CLICK_GUARD_MS` (1 s after a hold's release, same button) | Unchanged. A tap stop is not a hold release, so it arms no guard. A swallowed click (`multi` or `stopped`) never reaches `on_click`. |
| #233, ON and Toggle to Default On Brightness | A top tap, or a toggle tap from off, ramps to the **On preset**, not literally "full". At the default preset of 100 these are the same. Above the preset, a top tap ramps **down** to it, because the On preset applies whatever the level [verified: LV2 `30.../_0-HEADER.md`, id 1006]. Programming ON and TOGGLE keep rate 0 [code: `src/hue_light/driver.lua:987`, `:993`] and are not taps. |
| #308 turn-on guard | A tap ramp from off still waits for its level when it is sent as a target from off. A stop during that wait settles it, as `stop()` already does [code: `src/hue_light/driver.lua:381`, `:420`]. If the Hue note picks "on at 1 %, then a timed dim" as for holds, the guard's goal is 1 %, and the 600 ms `DIM_AFTER_ON_MS` pause falls inside the double-tap window. |
| Raise Level By and Restore Saved Level | Programming commands replace a tap ramp and are never stopped by a tap. A tap during a Raise ramp is a fresh tap. Restore then finds the level changed and forgets the saved one, as `docs/relative-level-design.md` §1 already says. |
| `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` | Stop a tap ramp exactly as a tap does. For other ramps, keep today's report, plus the real stop if the Hue note provides one. |
| Navigator, ALS and programming targets during a tap ramp | `SET_BRIGHTNESS_TARGET`, `SET_LEVEL`, `RAMP_TO_LEVEL`, ON, OFF and TOGGLE replace the tap ramp, and the driver is idle again. A colour command does not end it (§8, consecutive commands). |

### 7.3 The rule

"Within the window" means a press within `DOUBLE_TAP_MS` of the previous
press on the **same** button. "Ramping" means a tap ramp is running.

| State | Input | Action |
| --- | --- | --- |
| Idle, light off | top tap, or toggle tap | Ramp to the On preset over `click up × preset / 100` |
| Idle, on below the preset | top tap | Ramp up to the preset over `click up × distance / 100` |
| Idle, on above the preset | top tap | Ramp down to the preset over `click down × distance / 100` |
| Idle, at the preset (within 1 point) | top tap | Nothing; report CHANGED with the level |
| Idle, light on | bottom tap, or toggle tap | Ramp to off over `click down × level / 100` |
| Idle, light off | bottom tap | Nothing |
| Any state | press within the window | Ignored: part of a double or triple tap. The echo still goes out on the proxy route. A ramp keeps going. If held, it becomes a hold. |
| Ramping | press on any button outside the window, including the other button within it | **Stop** where it is: CHANGED with the estimate. The click is swallowed. |
| Ramping | that press held past `HOLD_AFTER_MS` | Stop, then hold from the stopped level: top up, bottom down, toggle by the on state |
| Ramping | the ramp reaches its end | Idle; the end level comes from Hue's report |
| Ramping | `SET_BRIGHTNESS_STOP` (Brightness Stop link, ALS, Daylight Agent) | Stop, as above |
| Ramping | a programming or Navigator brightness command | The command takes over; idle |
| Holding | any | Unchanged (#249) |
| Idle, within 1 s after a hold's release, same button | click | Ignored (unchanged) |

The other button mid-ramp stops rather than reverses, as the user guide's
"tap ... at any time to stop" reads [verified: C4-USER]. Reversing is the
alternative (open question 2). After a stop, the next tap outside the
window acts from the stopped level as an idle tap. Toggle by the on state
then means off.

## 8. Control4 guidelines that apply

Added at the owner's request (2026-11-08): every lighting change follows
Control4's own lighting behaviour and published guidance. The last column
flags where Hue may force a departure. The Hue note decides those.

| # | Guideline | Source | How the design meets it | Hue may force a departure |
| --- | --- | --- | --- | --- |
| 1 | A dimmer tap ramps to full (top) or off (bottom); a tap while dimming stops it there | [verified: C4-USER] | §7.3: tap ramps to the On preset or off, and a later tap stops it | **Zone and room lights in stepped mode** (more than 10 lamps lit, or a scene running) move in whole steps once a second (`docs/group-hold-design.md` G5). A stop lands on a step boundary. **Ending at off:** Hue's `dimming_delta` down stops at the lamp's minimum, not at off (holds never reach off, `docs/keypad-design.md`). A tap down must end off, so the end may need an explicit off. |
| 2 | Holding brightens or dims while held | [verified: C4-USER, C4-DIMMER] | Unchanged. A hold during a tap ramp starts from the stopped level | — |
| 3 | The On preset is where a top tap goes whatever the level, even from a higher one | [verified: LV2 `30.../_0-HEADER.md` id 1006; `10.../_6-SET_PRESET_LEVEL.md`] | The top tap's target is the preset, so it ramps down from above it (§7.3) | — |
| 4 | Click and hold rates are the time of the whole range | [verified: LV2 `35.../_4`, `_5`, `_9`, `_10`] | Tap ramps run at `rate × distance / 100` (§2), and CHANGING carries that time | If Hue's real pace differs from the asked duration, the tile and lamp drift apart until Hue's report after the stop |
| 5 | Click rates drive "Fast On" and "Fast Off", hold rates "Slow On" and "Slow Off" | [verified: LV2 `5.../_11-CLICKRATES.md`; `35.../_9`, `_10`] | Default click 3000 ms stays below hold 5000 ms (§5.1) | — |
| 6 | Rates stay within `click_rate_min` and `_max`, enforced since OS 3.3.0 | [verified: FUND `27.../_50`, "Enforcing min/max"; LV2 `5.../_12`, `_13`] | No capability change. `click_rate_min` 0 stays, so a dealer can still set 0 (an instant tap with nothing to catch) | — |
| 7 | Double and triple tap events fire for taps within about half a second; press and release fire too | [verified: C4-LIGHTING] | The first tap acts at once. A tap within `DOUBLE_TAP_MS` (600 ms) of the previous one on the same button starts and stops nothing (§1.6) | — |
| 8 | Echo every `BUTTON_ACTION`; a push must be followed by a release | [verified: LV2 `10.../_1`, `35.../_1`] | The echo happens before the machine, so ignored and swallowed taps are echoed too [code: `src/common/device.lua:700`] | — |
| 9 | On a Button Link, act on the push when hold versus click does not matter; Director can delay the release and cause "runaway" ramps | [verified: KP `62.../_1`] | The stop acts on the push. A tap ramp has a planned end, so a late or lost release cannot make it run away. Starting stays on the click, because hold versus tap matters there. | — |
| 10 | Report ramps with CHANGING (current, target, rate) and the end with CHANGED; no incremental level notifies | [verified: LV2 `35.../_10.2`, `_10.3`, `_12`; FUND `27.../_50`] | CHANGING at the ramp's start, CHANGED at the stop (the estimate) and at the end, then Hue's report (§3.2) | Hue reports the level about a second after a change, so the tile may correct itself slightly after a stop |
| 11 | Tiles animate from CHANGING; Navigator reads ramp rate and remaining time (variables 1120, 1121) | [verified: FUND `27.../_50`; LV2 `30.../_0-HEADER.md`] | Same notifies: the tile animates toward the target and freezes on the stop's CHANGED | — |
| 12 | A brightness ramp is stoppable when `supports_brightness_stop` is declared; `SET_BRIGHTNESS_STOP` stops a ramp in progress; a Brightness Stop link exists for keypads | [verified: LV2 `5.../_29`, `10.../_21.5`; on the house, `docs/keypad-design.md`] | `SET_BRIGHTNESS_STOP` stops a tap ramp exactly as a tap does (§7.2), so a dealer can also bind a dedicated stop button | **Whether a timed absolute target can be stopped at Hue at all** is the Hue note's question. If not, tap ramps must be built from the stoppable relative dim the holds use. |
| 13 | Programming sees "Brightness Begins to ramp" (4000), "Brightness Changed" (4001) and `IS_BRIGHTNESS_TARGET` | [verified: LV2 `25.../_0-HEADER.md`, `20.../_0-HEADER.md`; FUND `27.../_50`] | One CHANGING per tap ramp and one CHANGED per stop or end, so each event fires once. The target reads true until the stop. | — |
| 14 | The keypad LED, with "Follow Bound Device", shows the bound device's state | [verified: C4-KEYPAD; on the house, binding sets "Follow Connection", `docs/keypad-design.md` "Keypad LEDs"] | LEDs keep following the on state (`dev.update_leds`). They flip at the start of a ramp up from off, and at the end of a ramp down when off is reported. A stop leaves the light on, so the LEDs stay. | The LED flips when Hue reports the change, usually within a second, not on the press |
| 15 | Default On colour on any turn-on, including button clicks and holds; no Dim colour while dimming with an unknown end, such as a hold | [verified: FUND `27.../_50`, "Default On and Dim Colors"] | The Hue Light declares no colour on-mode capabilities, so it uses neither colour preset (`docs/keypad-design.md`, "What the proxy does", colour on mode). Departure today, unchanged by #421. If adopted later: a stoppable tap down has an unknown end like a hold, so no Dim colour on it. | — |
| 16 | Consecutive brightness and colour commands must not cancel each other | [verified: FUND `27.../_50`, "Handling Consecutive Brightness and Color commands"] | Only brightness commands end a tap ramp. A colour pick during it leaves the ramp state alone. | Whether a colour PUT interrupts a running Hue dim is the Hue note's question |
| 17 | The UI Button proxy and Light Extras | [verified: UIB `107_ui_button_proxy_commands/_1-SELECT.md`; FUND `27.../_51-LIGHTV2EXTRAS.md`] | Do not bear on taps: a UI Button only has `SELECT`, and Extras is for unique hardware settings on Navigator. Nothing in #421 uses them. | — |

## 9. To verify on the house

These need the owner's hands at a switch, as hardware findings in #421. Each
takes a minute or less.

1. With `Debug Mode` On on a Hue Light bound to a keypad, tap once, then
   double tap. Read the `ReceivedFromProxy` lines [code:
   `src/common/dispatch.lua:54`]:
   - the order of `DO_PUSH`, `DO_RELEASE` and `DO_CLICK`;
   - the gap between the two pushes of a double tap;
   - any undocumented multi-press command;
   - whether `DO_CLICK` is delayed when the keypad button has double-tap
     programming (§1.3).
2. The keypad's real double-tap window: the longest gap between two taps
   that still fires a keypad double-tap event. This tunes `DOUBLE_TAP_MS`.
3. A button bound to the light's **Brightness Stop** link sends
   `SET_BRIGHTNESS_STOP` (§3.1).
4. After the install, the Windows session reads every Hue Light's Click Rate
   Up and Down rows. Any that differ from the new default had a stored value
   (§5.2).

## Open questions for the owner

1. **Default click rates.** 3000 ms up and 3000 ms down for the whole range
   is recommended. Something between 2 and 5 s is possible.
2. **The other button mid-ramp.** Stop (recommended; Control4's guide says a
   tap stops a dimming light), or reverse direction.
3. **The double-tap window.** A fixed 600 ms in the driver (recommended), or
   a Composer property, for example "Double Tap Window (ms)". A property
   needs no reboot, but it is one more row.
4. **What a tap stops.** Only ramps a tap started (recommended), or any ramp,
   including a programming or ALS ramp such as a slow wake-up. A tap during
   those would then freeze them instead of going to the preset.
5. **Scenes and the window.** Apply the double-tap window to Hue Scene
   devices too (recommended; it lives in the shared machine): the second
   tap of a double tap does nothing, so a double tap on toggle stays on.
   The alternative is to keep scenes exactly as they are.
6. **Click rate meaning.** Adopt the proxy reference's whole-range meaning
   (recommended), or keep "a tap's time whatever the distance".
7. **House devices with a stored rate.** Set them to the new default through
   Composer, by the Windows session (recommended), or leave them as stored.
   There is no automatic migration in either case.

## Recommendation

- **Hue Light devices only** (single lights, zone lights, room lights) get
  tap-to-ramp and tap-to-stop. Hue Scene taps stay recalls and offs. Motion
  has no buttons.
- **Shared machine (`src/common/device.lua`):**
  - a per-button double-tap window, `DOUBLE_TAP_MS` = 600 ms, in which a
    second or third tap does nothing;
  - a stop **on the press** of any later tap, through two new hooks
    (`tap_ramping`, `on_tap_stop`), with the click swallowed and a hold still
    possible from the stopped level.
- **Hue Light driver:**
  - owns the ramp record;
  - sends `LIGHT_BRIGHTNESS_CHANGING` at the start, toward the On preset or
    0, over `click rate × distance / 100`;
  - sends `LIGHT_BRIGHTNESS_CHANGED` at the stop and at the end;
  - routes `SET_BRIGHTNESS_STOP` into the same stop, so the Brightness Stop
    link and ALS stops really stop the lamp.
- **Defaults:** Click Rate Up and Down 3000 ms for the whole range. Lua
  only: devices without a stored rate take it at once, and stored ones are
  changed in Composer.
- **No capability change**, so no controller reboot. No light-side
  double-tap events.
- The parts Hue decides are for the Hue note and the coordinator:
  - which request makes a stoppable ramp on a lamp;
  - how a ramp down ends at off;
  - how zone and room lights ramp through `group_hold.lua`.

  §8 flags rows 1, 12 and 16 as possible departures from Control4's
  guidance.
