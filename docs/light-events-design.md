# The light's own button events, SET_ALL_LED, and throttled Hue-side level reports (#432, #433)

The contract for issues #432 and #433. Implementation agents build against
this text, cold. It closes both issues and ships in release 1.5, whose one
controller reboot carries every static capability change (the siblings'
contracts: `docs/turn-on-design.md`, `docs/load-groups-design.md`).

## Contents

- [1. Summary](#1-summary)
- [2. Findings](#2-findings)
- [3. Decisions](#3-decisions)
- [4. Lifecycle edge cases](#4-lifecycle-edge-cases)
- [5. Control4 guidelines](#5-control4-guidelines)
- [6. Interfaces](#6-interfaces)
- [7. Implementation split](#7-implementation-split)
- [8. Tests and house checks](#8-tests-and-house-checks)
- [9. Reboot and changelog](#9-reboot-and-changelog)
- [10. Open questions for the owner](#10-open-questions-for-the-owner)

## 1. Summary

The owner decided on 2026-11-09 to do both issues (comments on #432 and
#433).

**#432** (checklist rows L46 and L52, `docs/c4-lighting-guidelines.md`):

- Hue Light devices (single lamp, zone light, room light) and Hue Scene
  devices fire their own button events in Composer programming, as a
  Control4 dimmer does. These are Press, Release, Single Tap, Double Tap
  and Triple Tap on Top, Bottom and Toggle.
- Hue lamps have no buttons. The presses come from keypads bound to the
  device's Button Links and from the proxy's own `BUTTON_ACTION` route.
- What a press does to the light does not change. The 1.4 tap ramps, tap
  stops and the double-tap window (`docs/tap-stop-design.md`) stay exactly
  as they are.
- The proxy's `SET_ALL_LED` command sets every button's LED colour, on and
  off, to one colour.

**#433** (row L7):

- On Hue Light devices, level reports that come from Hue (the Hue app's
  slider, a Hue dimmer switch, a Hue automation) reach the proxy at most
  once a second, as the Hue Scene device already does.
- The last level is exact, and arrives within a second.
- Turning on or off still shows at once.

Static changes: two capabilities in each of `hue_light` and `hue_scene`
(D2). Everything else is Lua and works at once on install.

## 2. Findings

Each claim is marked [verified: where] or [assumed]. "LV2" is
`~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/`;
"KP" is `~/c4-tools/reference/docs-driverworks-proxyprotocol-keypad/source/includes/`;
"PP" is `~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/`;
"API" is `~/c4-tools/reference/docs-driverworks-api/source/includes/`.
Nothing here quotes those pages; they are paraphrased.

### 2.1 Button events: what makes them fire

| # | Finding | Evidence |
|---|---|---|
| F1 | `has_button_events` is a Composer capability. True puts the driver's button events into programming. It defaults to false and is not dynamic. | [verified: LV2 `5_light_v2_capabilities/_26-HASBUTTONEVENTS.md`] |
| F2 | `multi_click` defaults to true and is not dynamic. False removes press, release, single, double and triple click programming from Composer. It exists from OS 3.4.2. | [verified: LV2 `5_light_v2_capabilities/_28.5-multiclick.md`; PP `3_whats_new/_7-WHATSNEWIN342.md`] |
| F3 | The light_v2 keypad events are numbered 5001 + action + 5 × button. The actions are 0 release, 1 push, 2 single, 3 double, 4 triple. The buttons are 0 top, 1 bottom, 2 toggle. So Top is 5001 to 5005, Bottom 5006 to 5010, Toggle 5011 to 5015. The proxy provides and manages these events. | [verified: LV2 `25_light_v2_events/_0-HEADER.md`] |
| F4 | The `BUTTON_ACTION` notification tells the proxy a button changed state. Its action values are 0 release, 1 push, 2 single tap, 3 double tap, 4 triple tap: the same numbers as the events in F3. After a push the proxy expects a release; without one, later pushes fail. The page prints the parameter name as `ACTIO` (a typo; the drivers send `ACTION`, and the proxy-route echo works with it). | [verified: LV2 `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/_1-BUTTONACTION.md`; echo in `src/common/device.lua:800-807`] |
| F5 | The `BUTTON_ACTION` command (proxy route) uses 0 for a release after a hold, 1 for a press and 2 for a release as a click. The driver must echo each one with the same values. Without the echo of a press, the proxy invents a second press when it sees the click. | [verified: LV2 `10_light_v2_commands/_1-BUTTONACTION.md`] |
| F6 | The `CLICK_COUNT` notification (`BUTTON_ID`, `COUNT`) tells the light_v2 proxy that a button was clicked several times. The keypad proxy's notification of the same name is what it uses to fire its single, double and triple click events. | [verified: LV2 `35_…/_3-CLICKCOUNT.md`; KP `61_keypad_protocol_notifications/_2-CLICKCOUNT.md`] |
| F7 | Snap One's public keypad template reports each tap of a multi-tap as a push and a click notification, then one `CLICK_COUNT` with the number of taps, also for a single tap. Its light_v2 template sends neither echo nor `CLICK_COUNT` and handles no `SET_ALL_LED`. | [verified: GitHub `snap-one/drivers-template-code-public`, `c4hooks/c4hook_keypad.lua` (`ClickTimerExpired`) and `c4hooks/c4hook_light_v2.lua`, read 2026-11-09; nothing copied] |
| F8 | Which notification the light_v2 proxy fires Single, Double and Triple from is not documented: `CLICK_COUNT` (F6, F7) or `BUTTON_ACTION` 2, 3 and 4 (F4). Whether a `BUTTON_ACTION` 2 (the click echo) already fires Single Tap is not documented either. | [assumed: settled by house check P3, D7] |
| F9 | The keypad link page lists only push, click and release over a Button Link, and nothing goes back over the link for them. It says newer devices have double and triple click calls that older drivers never adopted, without naming them. | [verified: KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`] |
| F10 | On the house, keypads reach the light through Button Link connections the driver declares itself (ids 200 to 202), as `DO_PUSH`, `DO_RELEASE` and `DO_CLICK`. The proxy never sees those presses. Today the driver notifies nothing for them, so the proxy has nothing to fire events from. | [verified: hardware 2026-10-22, `docs/keypad-design.md` "Hardware findings"; `src/common/device.lua:809-827`] |
| F11 | `C4:SendToProxy` sends a NOTIFY when the binding id is 1000 or more, so `notify()` on 5001 sends notifications. | [verified: API `25_proxy/_6-SendToProxy.md`; `src/common/device.lua:228-236`] |
| F12 | A driver can listen to another device's events with `C4:RegisterDeviceEvent(deviceId, eventId)` and the `OnDeviceEvent(firingDeviceId, eventId)` callback (OS 2.9.0). This lets a dev build see which of F3's events fire. That it works on a proxy's events is [assumed]. | [verified: API `7_event/_5-RegisterDeviceEvent.md`, `7_event/_4.1-OnDeviceEvent.md`] |
| F13 | The light_v2 What's New pages list no change to button events or LEDs after 3.3.2, including 3.4.2 and 4.2.1. | [verified: LV2 `3_whats_new/`, grep for button, LED, click] |
| F14 | Composer's help: double and triple tap events fire for taps about half a second apart, and Press and Release fire during them too. | [verified: C4-LIGHTING, as cited in `docs/tap-stop-research-c4.md` §1.3, §1.4] |
| F15 | The dev loop's `Proxy Command` sends any light_v2 command to a light, zone light or scene device's proxy, as programming would. So `BUTTON_ACTION` and `SET_ALL_LED` can be sent without anyone's hands. | [verified: `src/hue_bridge/bridge/devtools.lua:424-479`] |

### 2.2 The shipped button machine (1.4)

- One machine in `src/common/device.lua` serves both drivers and both
  routes. A press is judged when it arrives, by `judge()`
  (`src/common/device.lua:680`). Within `DOUBLE_TAP_MS` = 600 ms of the
  previous press on the same button it is `multi`, and its click is
  swallowed. Outside the window, while a ramp runs, it stops the ramp, and
  its click is swallowed [verified: `src/common/device.lua:102`, `:680-693`;
  `docs/tap-stop-design.md` D4, D5].
- A press still down after `HOLD_AFTER_MS` = 400 ms becomes a hold. A hold
  clears the button's window [verified: `src/common/device.lua:92`, `:696-706`].
- After a hold's release, a click on that button within `CLICK_GUARD_MS` =
  1000 ms is ignored (some keypads send one) [verified: `:94`, `:741-745`].
- Because 400 < 600, every press has become either a tap or a hold by the
  time its window ends [verified: the constants above].
- The proxy route echoes every action before the machine runs, a swallowed
  one too [verified: `src/common/device.lua:800-807`].

### 2.3 LEDs today

- Per-button on and off colours are persisted under
  `button_<n>_on_color` and `button_<n>_off_color` (`n` = 0, 1, 2), with
  Control4's defaults when unset [verified: `src/common/device.lua:79-83`,
  `:183`, `:462-468`].
- `SET_BUTTON_COLOR` stores one button's colours, then sends `BUTTON_COLORS`
  on that button's link and `BUTTON_INFO` to the proxy [verified:
  `:836-856`].
- The LEDs follow `dev.is_on()`: `MATCH_LED_STATE` on each link and
  `BUTTON_INFO` per button, resent when the on state changes or a keypad is
  bound [verified: `:470-512`].
- There is no `SET_ALL_LED` handler [verified: grep of `src/`]. The command
  takes one parameter, `COLOR`, a 6-digit hex RGB string, and returns
  nothing [verified: LV2 `10_light_v2_commands/_13-SET_ALL_LED.md`].
- On a Hue Scene device the LED colours are handled by the same code, and
  On State Follows decides only what "on" means
  (`docs/scene-led-design.md`).

### 2.4 Level reports today

- Light device: every `HUE_STATE` that changes the cached level becomes one
  `LIGHT_BRIGHTNESS_CHANGED`, with nothing in between [verified:
  `src/hue_light/driver.lua:802-827`, `:298-306`].
- The bridge sends at most about two event containers a second [verified:
  `docs/design.md`, issue #65 line: 10 containers in about 7 s].
- A zone or room light gets the grouped_light's level in the same
  `HUE_STATE` path [verified: `src/hue_bridge/bridge/zone_lights.lua:528-609`].
- `HUE_STATE` carries `reason`: `event` for stream changes, `hello`,
  `resync` or `import` for full states [verified:
  `src/hue_bridge/bridge/owner.lua:503`, `:911`, `:1218`;
  `src/hue_bridge/bridge/lights.lua:1145`, `:1232`].
- The Hue Scene device throttles its level reports
  [verified: `src/hue_scene/driver.lua:36-38`, `:401-434`]:
  - with no window open, a report goes out at once and opens a window of
    `LEVEL_REPORT_MS` = 1000 ms;
  - a report inside the window only marks it;
  - at the window's end, the level now goes out if it differs from the last
    one sent, and a new window opens.
- In the scene, on/off edges and reports that settle a pending command go
  out directly [verified: `src/hue_scene/driver.lua:1371-1403`].
- During a Control4 ramp (tap-stop D10), the light holds the bridge's
  reports back, out of the cache and away from the proxy. It releases them
  as the ramp's one CHANGED at its end. A report the ramp cannot explain
  ends the ramp and goes through [verified: `src/hue_light/driver.lua:464-524`].
- The light sends `LIGHT_BRIGHTNESS_CHANGING` at two sites (`:626`
  `set_brightness`, `:1321` the hold's `start_ramp`) and
  `LIGHT_BRIGHTNESS_CHANGED` at three (`:303` `report_brightness`, `:638`
  and `:1332`, the unsent-command paths) [verified: grep].

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Which devices.** Hue Light (single, zone, room) and Hue Scene devices get button events and `SET_ALL_LED`. The code goes in `src/common/device.lua`, so both drivers get it from one place. Only `hue_light` gets the throttle (D12), because `hue_scene` has one already. Hue Motion has no light_v2 proxy. | Owner, 2026-11-09: "every device type where it applies". One shared button machine since #57. |
| D2 | **Capabilities.** In `src/hue_light/driver.xml` and `src/hue_scene/driver.xml`, directly after the line `<has_leds>True</has_leds>` (today line 155 and line 130), add exactly two lines: `<has_button_events>True</has_button_events>` and `<multi_click>True</multi_click>`. `multi_click` is the default, but it is declared to record the choice. OS versions before 3.4.2 ignore it [assumed, as L84 notes for other newer capabilities]. Both are static and ride the 1.5 reboot. | F1, F2. These two lines are the only xml change in this contract. They sit apart from turn-on's capability edits. |
| D3 | **Which presses fire events.** Every press that reaches the device fires its events, by either route. That is the case whatever the device then does: a tap, a stop, a swallowed press within the window, or a press dropped because the device is unbound, offline or forgotten. The events describe the buttons, not the light. | A Control4 dimmer's buttons fire their events whatever the load does [assumed]. The tap-stop "swallow" is about the light's action only. |
| D4 | **Link route notifications.** A Button Link press notifies the proxy as the proxy route would echo it: `BUTTON_ACTION` 1 at `DO_PUSH`; 2 when the press ends as a click (`DO_CLICK`, or `DO_RELEASE` before the hold time); 0 when it ends after a hold (`DO_RELEASE`, or `DO_CLICK` on a held press). Exactly one release follows each notified push. A `DO_PUSH` on a button still marked down first notifies the missing release (0). The click that follows a hold's release, which the guard ignores, notifies nothing. | F4, F10, L41. The proxy hears the same sequence from both routes. A lost `DO_RELEASE` (L47) must not leave the proxy refusing later pushes. |
| D5 | **Proxy route.** The echo stays exactly as today: every action, as received, before the machine runs (F5). The echo also keeps the button's down mark, so mixed sequences stay consistent. | F5 makes the echo mandatory. |
| D6 | **Counting taps.** Per button, aligned with the shipped window. Each press that `judge()` sees (a press, or a click with no press on record) counts one. A press outside the window first closes any open sequence on that button, then starts a new one at 1. A press inside the window adds one, up to 3; later presses in the window add nothing. A press that becomes a hold takes back its count and closes the sequence at once. The window's end (`DOUBLE_TAP_MS` after the sequence's last press) closes it. A sequence that closes with a count of 1 or more notifies the count (D7). `cancel_timers()` drops open sequences without notifying. Sequences on different buttons are independent. | F6, F7, F14. Counting presses rather than clicks avoids the PUSH, RELEASE, CLICK ordering. Because 400 < 600 (§2.2), a sequence never closes while its last press is undecided. |
| D7 | **How the count reaches the proxy: one constant, settled on the house.** `device.BUTTON_EVENTS_MODE` is `"count"` (the default) or `"action"`. **"count":** releases as in D4 and D5; the sequence's close sends `CLICK_COUNT {BUTTON_ID, COUNT}`. **"action":** a link press's release notifies 0 whether click or hold; the close sends `BUTTON_ACTION {BUTTON_ID, ACTION = 1 + COUNT}` (2, 3 or 4); no `CLICK_COUNT`; the proxy route's echo is unchanged. House check P3 picks the mode before the release. Changing it is Lua-only. | F8. "count" follows the documented keypad pattern (F6, F7) and keeps the link route identical to the proxy route. "action" follows the numbering of F3 and F4. Only the proxy can tell which it uses. |
| D8 | **Tap-stop is unchanged.** The window, the stop on the press, the swallowed clicks, the click guard and the holds act exactly as in 1.4. The new notifications are sent beside the machine, never in place of a decision. A double tap fires Double Tap while the first tap's ramp keeps going. A tap that stops a ramp counts as a tap, so it fires Single Tap. | The owner's 1.4 behaviour stays. The events report presses. |
| D9 | **No double firing within a device; two devices, two sets of events.** A keypad button bound to a light's link fires the keypad's own events (on the keypad) and the light's events (on the light). That matches a Control4 keypad bound to a Control4 dimmer [assumed]. The manuals tell dealers to program one of the two for a given press, and warn that programming on a light's button event that presses the same light's button repeats itself. | F10. Each set belongs to the device that owns it. |
| D10 | **The capabilities ship whatever P3 finds.** The mode (D7) is Lua and can be fixed later without a reboot. If neither mode fires the tap events, the release still declares D2. Push and Release, which F4 documents, are expected to work either way. The coordinator records the departure in `docs/c4-lighting-guidelines.md` §5 and opens an issue. | A second reboot to take the capability back would cost more than a Lua fix. |
| D11 | **SET_ALL_LED.** `COLOR` must be a 6-digit hex string (read the same way as `SET_BUTTON_COLOR`'s colours, lower-cased). It sets all six colours (on and off of buttons 0, 1 and 2) and persists them under the existing keys. Then it sends `BUTTON_COLORS` on each link (200, 201, 202), `BUTTON_INFO` for each button, and, when `dev.is_on()` is known, `MATCH_LED_STATE` on each link. A later `SET_BUTTON_COLOR` changes single colours again. A bad or missing `COLOR` changes nothing, logs a warning, and resends the colours kept (`BUTTON_INFO` per button), so Composer shows the truth. It works whatever the device's state (unbound, offline). | LV2 `_13-SET_ALL_LED.md`. Persisting matches `SET_BUTTON_COLOR` (L51), so a Director restart does not undo a colour that Composer's settings page shows. |
| D12 | **The throttle, on Hue Light devices.** `LEVEL_REPORT_MS` = 1000, with the scene's leading-and-trailing pattern (§2.4). It applies only to a `HUE_STATE` with `reason` `event` (or no reason) whose only brightness change is a level. These go out at once instead: an on/off edge (the proxy level crosses 0, or the first report); a report that settles a pending Control4 target, including one that ends a ramp as "foreign"; any `hello`, `resync` or `import` state; and every report outside `HUE_STATE`. After a report sent at once from `HUE_STATE`, the window restarts. The cache is updated at once in every case. Only the notification waits, so the LEDs, `level_now()` (Raise and Restore), the tap rule and `CHANGING`'s current level all read the exact level. | L7, L2. On and off stay prompt (L53, L6). The final level is exact and at most 1 s late. |
| D13 | **Every LIGHT_BRIGHTNESS_CHANGING closes the window**, dropping a pending trailing report, through one helper that every CHANGING site uses. That covers `set_brightness`, the hold's `start_ramp`, and any CHANGING a sibling feature adds (turn-on, load groups). Otherwise a trailing report could send a stale CHANGED while the tile animates the Control4 ramp. During the ramp, D10 of tap-stop already keeps the bridge's reports out. | Tap-stop D10; best practice: one CHANGING, then one CHANGED. |
| D14 | **Every LIGHT_BRIGHTNESS_CHANGED records its level** (`levels:sent(level)`), at all three sites. A trailing report goes out only when the cache differs from the last level sent, so a stop's estimate or an unsent command's CHANGED is never repeated. | The scene's `last_reported` pattern. |
| D15 | **Where the throttle lives.** A small new module, `src/hue_light/light/throttle.lua`, with its own spec. `hue_light/driver.lua` only wires it in, which keeps that diff small and apart from the turn-on changes to the same file. The scene's own throttle stays as it is. | Locals budget (#373). Disjoint parts. A scene refactor without lamp tests is risk for no gain. |
| D16 | **Colour reports are not throttled.** Row L7 is about levels. The bridge's own pace (at most about 2 containers a second) bounds colour changes too. | Scope; see question 1. |
| D17 | **Dev-only probe.** A signed dev-loop command, `Watch Events`, in `src/hue_bridge/bridge/devtools.lua` (stripped from release builds). It registers a device's proxy for a list of event ids (F12) and logs each one that fires, with the controller's clock. House check P3 uses it. | No shipped one-off tooling (owner rule). The proxy route can be driven without hands (F15). |

### 3.1 The event rule (mode "count")

"Down" is a per-button mark: set by a notified push, cleared by a notified
release.

| Input on button b | Notified now | Counting (D6) |
|---|---|---|
| Proxy `BUTTON_ACTION` a | `BUTTON_ACTION {b, a}` (echo, unchanged) | press: counts; release: nothing |
| `DO_PUSH`, b not down | `BUTTON_ACTION {b, 1}` | counts |
| `DO_PUSH`, b down (release lost) | `BUTTON_ACTION {b, 0}`, then `{b, 1}` | counts |
| `DO_RELEASE` before the hold time, b down | `BUTTON_ACTION {b, 2}` | nothing |
| `DO_RELEASE` after a hold, b down | `BUTTON_ACTION {b, 0}` | nothing (the hold closed the sequence) |
| `DO_CLICK`, b down, not held | `BUTTON_ACTION {b, 2}` | nothing, or counts when no press is on record (§2.2) |
| `DO_CLICK`, b down, held | `BUTTON_ACTION {b, 0}` | nothing |
| `DO_CLICK` or `DO_RELEASE`, b not down (the guard's click; a click after PUSH, RELEASE) | nothing | nothing |
| Hold starts on b | nothing | the press's count is taken back; the sequence closes |
| Sequence closes with count n ≥ 1 | `CLICK_COUNT {b, n}` | ends |
| `cancel_timers()` (OnDriverDestroyed) | `BUTTON_ACTION {b, 0}` for each b still down | open sequences dropped |

Mode "action" differs only in two places. A link release notifies 0 in
every case. The close notifies `BUTTON_ACTION {b, 1 + n}` instead of
`CLICK_COUNT`.

Examples (Top, "count"):

- Tap: `{0,1}` `{0,2}` … 600 ms after the press … `CLICK_COUNT {0,1}`.
- Double tap: `{0,1}` `{0,2}` `{0,1}` `{0,2}` … `CLICK_COUNT {0,2}`. The
  light: the first tap's ramp keeps going (tap-stop D4).
- Hold: `{0,1}` … `{0,0}`; no count.
- Tap, then hold within 600 ms: `{0,1}` `{0,2}` `{0,1}`, then at the hold
  `CLICK_COUNT {0,1}`, later `{0,0}`.

## 4. Lifecycle edge cases

The feature does three things on its own: it fires events, it keeps LED
colours, and it holds back reports. It creates, renames, binds and removes
nothing. Cases on both sides:

| # | Case | What happens | Decision |
|---|---|---|---|
| E1 | Keypad bound to a Button Link | Its presses fire the light's events from the first press; LEDs as today | Automatic |
| E2 | Keypad unbound or replaced | No presses, no events. Colours stay with the light device, and a new keypad gets them on its `REQUEST_BUTTON_COLORS` | Automatic |
| E3 | Hue lamp replaced, or the device linked to another Hue resource | Button events and colours belong to the Control4 device and are unaffected. The throttle keeps no Hue identity, only the last level sent | Automatic |
| E4 | Hue room or zone renamed, members added or removed | Nothing in this feature changes. The zone's level reports are throttled the same way | Automatic |
| E5 | Light removed in Hue (gone, forgotten) | Presses still fire events (D3). The light does nothing, as today. `SET_ALL_LED` still applies | Automatic |
| E6 | Bridge offline or rebooting | Events and LEDs unaffected. Level reports stop; the `resync` after the bridge returns goes out at once (D12) | Automatic |
| E7 | Driver updated, before the controller reboot | New Lua, old capabilities. Notifications go out, but Composer lists no events yet [assumed: the proxy ignores them]. `SET_ALL_LED` and the throttle work at once | Automatic; the reboot is the owner's |
| E8 | After the reboot | Composer lists the 15 events per device (D2, F3) | Automatic |
| E9 | Driver updated in the middle of a press | `OnDriverDestroyed` notifies the release for each button still down (§3.1), so the proxy is not left refusing pushes. The new code starts with nothing down | Automatic |
| E10 | Controller reboot or Director restart mid-sequence | Timers die; no count is sent for that sequence. The proxy restarts too | Automatic |
| E11 | Rolled back to 1.4 | After a reboot the events are gone from the device. Programming written on them may stay in the project and never fire [assumed]. Colours persist under the same keys, and 1.4 reads them | Nothing to do; the changelog notes it |
| E12 | Project restored from a backup | Colours come back as persisted in that backup [assumed: persisted data is part of the project] | Automatic |
| E13 | Device deleted and added again in Composer | A new device: default colours, no programming. Never advised: it loses the pairing (`CLAUDE.md`) | Forbidden without a click (Composer's own) |
| E14 | Programming on a light's button event presses the same light's button | Repeats itself until the dealer stops it | Forbidden by documentation (D9). The driver cannot see programming |
| E15 | `SET_ALL_LED` from programming at times of day | Each call overwrites the six colours and persists them | Automatic; it is what the command means |
| E16 | Hue switches (Hue dimmer, tap dial) pressed | They never reach the light's button events: Hue reports what lamps do, not which switch moved them. Their level changes reach the light as throttled reports (D12) | Automatic; a Hue switch as a Control4 keypad is a later feature |
| E17 | A Hue automation or the Hue app fades a light | Reports at most 1/s, last one exact; on/off at once | Automatic |
| E18 | A Control4 ramp while Hue also moves the light | Tap-stop D10 rules: a foreign report ends the ramp and goes out at once (D12). The window is closed by the ramp's CHANGING (D13) | Automatic |

## 5. Control4 guidelines

Rows of `docs/c4-lighting-guidelines.md` this feature touches. Implementers
read that file, the light_v2 best practice and extras pages, and the
light_v2 and keypad proxy protocol pages cited in §2.

| Row | How it is met |
|---|---|
| L46 | Met by D2 to D7: the capabilities, both routes notified, taps counted. It moves from Partial to Meets once P3 confirms the events fire. |
| L52 | Met by D11. It moves from Gap to Meets at merge, and is verified by P5. |
| L7 | Met by D12 to D14 for light, zone and room devices; the scene already met it. It moves from Partial to Meets at merge. D14 of §5 (a Hue-side hold appears as steps) stays a departure, now at most one step a second. |
| L45 | Unchanged for the light's action (tap-stop D4). Now also the light's own Double and Triple Tap events fire for taps within the window, and Press and Release fire during them (F14). |
| L40, L41 | Both routes end in the same machine as before. Each notified push gets exactly one release (D4), including after a lost `DO_RELEASE`, and at destroy (E9). |
| L47 | Unchanged for the light. The proxy is protected from a lost release (D4). |
| L44, L48, L42, L43 | Unchanged (D8). |
| L49, L50, L51, L53 | Unchanged except that `SET_ALL_LED` writes the same per-button colours `SET_BUTTON_COLOR` writes, through the same sends (D11). |
| L2, L3, L4, L55 | Every CHANGING is still closed by one CHANGED. The throttle never sends a CHANGED inside a Control4 ramp (D13). |
| L5, L6 | The real level is reported at start and on reconnect at once (D12). Hue-side changes still reach the proxy, at most a second late. |
| L68, L69 | Brightness Changed fires at most once a second for a Hue-side ramp, with the exact final level. Hue still reports no target (§5 D3). |
| L71 | The 15 button events are the proxy's, not the drivers'. The drivers still have no events of their own. |
| L77, L78, L79 | Nothing is removed or renumbered. Two capabilities are added. |
| L82 | Both new capabilities are static. They go into 1.5's one reboot. |
| L84 | `multi_click` is from 3.4.2 (F2). Older OS versions ignore it [assumed] and keep all button events, which is the same as True. |

Section 5 of the guidelines changes:

- **D15** ("the light device's own buttons are virtual; button events belong
  to the keypad that is pressed") is retired. The light's events now fire
  for the presses that reach it.
- What stays forced by Hue: presses on Hue's own switches never become
  Control4 button events (E16).
- **D14** gains: "at most one step a second (#433)".

## 6. Interfaces

### 6.1 Capabilities (static)

`src/hue_light/driver.xml` and `src/hue_scene/driver.xml`, inside
`<capabilities>`, directly after `<has_leds>True</has_leds>`:

```xml
		<has_button_events>True</has_button_events>
		<multi_click>True</multi_click>
```

Nothing else in either xml changes for this feature. No event, command,
property, variable or connection is added.

### 6.2 Proxy messages

| Direction | Message | Parameters | When |
|---|---|---|---|
| proxy → driver | `SET_ALL_LED` (new handler) | `COLOR`: 6-digit hex | Programming or Composer |
| driver → proxy (5001) | `BUTTON_ACTION` (now also for the link route) | `BUTTON_ID` 0/1/2, `ACTION` 0/1/2 (numbers) | §3.1 |
| driver → proxy (5001) | `CLICK_COUNT` (new; mode "count") | `BUTTON_ID` 0/1/2, `COUNT` 1–3 (numbers) | sequence close |
| driver → proxy (5001) | `BUTTON_ACTION` 2/3/4 (mode "action" only) | as above | sequence close |
| driver → link 200/201/202 | `BUTTON_COLORS`, `MATCH_LED_STATE` | as today | also after `SET_ALL_LED` |
| driver → proxy (5001) | `BUTTON_INFO` | as today | also after `SET_ALL_LED` |
| driver → proxy (5001) | `LIGHT_BRIGHTNESS_CHANGED` | as today | throttled per D12 |

All notifications go through `dev.notify()` (binding 5001, NOTIFY by
default, F11). `BUTTON_INFO` and `BUTTON_COLORS` keep their explicit
`"NOTIFY"`.

### 6.3 `src/common/device.lua`

- `device.BUTTON_EVENTS_MODE = "count"`, exported; the specs set it per
  test. A comment cites this contract (#432 D7) and P3.
- New per-instance state: `down = {}` (button → true) and
  `taps = {}` (button → `{ count, timer }`).
- New local functions:
  - `close_taps(button)`: cancels the timer, sends the count by mode when
    it is 1 or more, and clears the sequence;
  - `count_tap(h)`: called from `judge()` after the window verdict;
  - `uncount_tap(button)`: called from `start_hold()`;
  - `notify_press(button)` and `notify_release(button, held)`: keep `down`
    and send per mode.
- The link handlers `DO_PUSH`, `DO_RELEASE` and `DO_CLICK` notify per §3.1
  before calling `dev.button_action`. For a held press, the "held" test is
  `hold and hold.button == button and hold.held`.
- `BUTTON_ACTION` (the proxy route) keeps its echo. It sets or clears
  `down` from the echoed action.
- `dispatch.proxy["SET_ALL_LED"]` per D11. It reuses `valid_color`,
  `color_key`, `send_button_colors`, `send_button_info` and `BUTTON_LINK`.
- `dev.cancel_timers()` also drops open sequences without sending, and
  notifies a release (0) for each button still down.
- The header comment's list of registered proxy commands gains
  `SET_ALL_LED`.
- Not touched by this contract: the `SETTINGS` table (turn-on edits its
  maxima), the hold, guard and stop logic, and the LED following.

### 6.4 `src/hue_light/light/throttle.lua` (new)

```lua
local throttle = require("light.throttle")
local levels = throttle.new({
	ms = 1000,                                              -- LEVEL_REPORT_MS
	current = function() return state.to_proxy_brightness(st) end,
	send = function() report_brightness() end,             -- must call levels:sent()
})
levels:sent(level)   -- an immediate LIGHT_BRIGHTNESS_CHANGED went out with `level`
levels:edge(level)   -- true when nothing was sent yet, or `level` and the last sent differ in being 0
levels:report()      -- throttled: send now and open the window, or mark the open window
levels:open()        -- (re)start the window after an immediate report
levels:close()       -- drop the window and any pending trailing report
levels.last          -- the last level sent, nil before the first
```

- Window end: if marked and `current()` differs from `last`, call `send()`
  and open a new window; otherwise end.
- `report()` with no window open: send only if `current()` differs from
  `last`; either way open the window when it sent.
- Timers come from `C4:SetTimer`, looked up at call time. The module holds
  no state outside the object it returns.

### 6.5 `src/hue_light/driver.lua`

- `local LEVEL_REPORT_MS = 1000`, and one `levels` object (§6.4) created
  after `report_brightness`.
- `report_brightness()` calls `levels:sent(brightness)` after its notify.
  The two other CHANGED sites (`set_brightness`'s unsent path and
  `start_ramp`'s unsent path) call `levels:sent(level)` too.
- A helper `changing(params)` sends `LIGHT_BRIGHTNESS_CHANGING` and calls
  `levels:close()`. Both CHANGING sites use it, and so does any CHANGING a
  sibling feature adds.
- `HUE_STATE`:
  - note whether this report settled a pending brightness target;
  - when `changed.brightness`, take the proxy level now. Report at once
    (`report_brightness()` then `levels:open()`) when the report settled a
    target, when `levels:edge(level)`, or when `params.reason` is present
    and not `"event"`;
  - otherwise call `levels:report()`.
- `HUE_FORGOTTEN`, the bridge unbind in `OnBindingChanged`, and
  `OnDriverDestroyed` call `levels:close()`.
- Comments cite #433 D12 to D14.
- Not touched by this contract: the turn-on path, `hold_back`, `stop_ramp`
  (it reports through `report_brightness`, which records the level), and
  the colour reports.

### 6.6 `src/hue_bridge/bridge/devtools.lua` (dev builds only)

- A signed command `Watch_Events`, with params `Light` (as `Proxy Command`:
  rid, Hue name or device id) and `Events` (default `5001-5015`; a range or
  a comma list).
- It finds the proxy as `proxy_command` does and calls
  `C4:RegisterDeviceEvent(proxy, id)` for each id.
- It defines the global `OnDeviceEvent(device, event)` (chaining any
  earlier one), which logs with `log.always`:
  `event <id> (<name>) from device <device> at <C4:GetTime()>`. The names
  come from F3: `Top Release`, …, `Toggle Triple`.
- A second call adds ids; `Events=none` unregisters with
  `C4:UnRegisterAllDeviceEvents()` [verified:
  API `7_event/_6-UnRegisterAllDeviceEvents.md`].

### 6.7 Persisted keys

There are no new keys. `SET_ALL_LED` writes `button_0_on_color`,
`button_0_off_color`, `button_1_on_color`, `button_1_off_color`,
`button_2_on_color` and `button_2_off_color`.

## 7. Implementation split

Parts with disjoint files, buildable in parallel. Others are editing the
rest of the checkout at the same time. No agent runs git. Conventions: Lua
5.1, tabs, `.luacheckrc`, busted with the fake C4 runtime
(`tests/helpers/fake_c4.lua`: `c4.advance`, `c4.fire_timers`,
`c4:GetTime`), comments citing `#432 D<n>` or `#433 D<n>` and marking
DriverWorks claims [verified: …] or [assumed]. Every brief tells its agent
to read `docs/c4-lighting-guidelines.md`, the light_v2 best practice
(`~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`,
`_51-LIGHTV2EXTRAS.md`), and the protocol pages of §2. Done means:
`luacheck src tests tools`, `busted tests` and `python3 tools/lua_limits.py`
pass (except what §7's notes say another part fixes).

| Part | Files it owns | What |
|---|---|---|
| A | `src/common/device.lua`, `tests/spec/device_spec.lua`, `tests/spec/scene_driver_spec.lua` (only expectations its change breaks), `tests/fixtures/ledger.lua` | §3.1, §6.3, D11. Ledger: add `{ proxy_command = "SET_ALL_LED", driver = "hue_light" }` to row L9, and an `auto` path "the light's own button events" proved by the device_spec test "a double tap sends CLICK_COUNT 2 once, and the second tap still changes nothing", and an `auto` path "Hue-side level reports throttled" proved by the light_driver_spec test "Hue-side level reports reach the proxy at most once a second, the last one exact" (Part C writes it under exactly that title) |
| B | `src/hue_light/light/throttle.lua` (new), `tests/spec/light_throttle_spec.lua` (new) | §6.4 |
| C | `src/hue_light/driver.lua`, `tests/spec/light_driver_spec.lua` | §6.5, against §6.4's interface. Also: the test "a click on binding 200 turns on to the preset, on 201 off, with no proxy echo" (around line 2482) becomes "… with the link notifies". It expects `BUTTON_ACTION {0,1}`, `{0,2}` per Part A, so it fails until Part A lands |
| D | `src/hue_bridge/bridge/devtools.lua`, `tests/spec/devtools_events_spec.lua` (new; stubs `C4.RegisterDeviceEvent` in the spec) | §6.6 |
| E | `src/hue_light/www/documentation.html`, `src/hue_scene/www/documentation.html`, `docs/keypad-design.md` (a new section "The light's own button events and Set All LEDs (#432)" at the end, with "Current (…)" notes where earlier text says the light notifies nothing for link presses) | The manuals: the 15 events, when they fire (D3), the keypad's own events beside them and the loop warning (D9), Set All LEDs (D11), and the once-a-second Hue-side reports (D12) |

**Coordinator** (integration; not given to agents):

- `src/hue_light/driver.xml`, `src/hue_scene/driver.xml` (§6.1), done first
  so specs read them;
- `tests/spec/drivers_spec.lua` if a test pins the capability list;
- `CHANGELOG.md`, `docs/c4-lighting-guidelines.md` (L7, L46, L52 and §5
  D14, D15);
- `docs/composer-checklist.md` (paste §8.2), `docs/status.md`,
  `docs/README.md` (index this file);
- `tools/check.sh`, `tools/build.sh`, commits.

**Shared with siblings.**

- `src/common/device.lua`: turn-on edits the `SETTINGS` maxima there.
- `src/hue_light/driver.lua` and `tests/spec/light_driver_spec.lua`:
  turn-on and load groups edit the turn-on path and add commands there.
- `src/hue_light/www/documentation.html`: turn-on edits it as well.
- The edits are textually apart. The coordinator either runs these parts
  one after the other on the same file, or gives a file's work for both
  contracts to one agent. Any CHANGING a sibling adds must use §6.5's
  `changing()`.

## 8. Tests and house checks

### 8.1 Specs

`tests/spec/device_spec.lua` (Part A), each test named as here:

- "SET_ALL_LED sets every button's on and off colour, persists them and tells the links and the proxy"
- "SET_ALL_LED with a colour that is not 6-digit hex changes nothing and reports the colours kept"
- "a later SET_BUTTON_COLOR overrides one colour SET_ALL_LED set"
- "a Button Link press notifies BUTTON_ACTION 1, its click 2, a hold's release 0"
- "PUSH, RELEASE, CLICK on a link notifies one release"
- "a push while the button is still down notifies the missing release first"
- "the keypad's click after a hold's release notifies nothing"
- "a single tap sends CLICK_COUNT 1 DOUBLE_TAP_MS after its press"
- "a double tap sends CLICK_COUNT 2 once, and the second tap still changes nothing"
- "a triple tap sends CLICK_COUNT 3, and a fourth tap in the window adds nothing"
- "a press that becomes a hold closes the sequence with the taps before it and counts none for itself"
- "a tap that stops a ramp counts as a tap"
- "taps on different buttons are counted apart"
- "the proxy route echoes as before and sends the same CLICK_COUNT"
- "in mode action the close sends BUTTON_ACTION 2, 3 or 4, link releases notify 0, and no CLICK_COUNT goes out"
- "cancel_timers drops an open sequence and releases a button still down"

`tests/spec/light_throttle_spec.lua` (Part B):

- "report sends at once when no window is open, and opens one"
- "reports within the window go out once, at its end, with the latest level"
- "the window's end sends nothing when the level is back to the last one sent"
- "a trailing report opens a new window"
- "sent records an immediate report, so the window's end does not repeat it"
- "close drops the window and its trailing report"
- "edge is true for the first report and for crossings of 0"

`tests/spec/light_driver_spec.lua` (Part C):

- "Hue-side level reports reach the proxy at most once a second, the last one exact"
- "an off or an on from Hue goes to the proxy at once, inside a window"
- "a report that settles a Control4 target goes out at once"
- "a resync or hello state is not throttled"
- "a brightness command closes the window: no stale CHANGED during its ramp"
- "a hold's CHANGING closes the window"
- "the LEDs follow an on or off from Hue at once"
- "Raise Level By reads the exact level while a report waits in the window"
- "a zone light's level reports are throttled the same way"
- the renamed link test (§7, Part C).

`tests/spec/devtools_events_spec.lua` (Part D):

- "Watch Events registers the proxy for the listed events and logs each one that fires"
- "Watch Events with Events=none unregisters them"

### 8.2 For `docs/composer-checklist.md` (coordinator pastes as section N)

> ## N. The light's own button events, Set All LEDs, Hue-side reports (#432, #433)
>
> Run on the 1.5 dev build with its capabilities live (after the owner's
> System Manager reboot, `docs/turn-on-design.md` D27), Debug Mode On on the
> devices named. The owner's standing approval covers every step.
>
> 99. **The events are listed** (#432 D2). In Programming, select a Hue
>     Light, a zone light and a Hue Scene device. Each lists Top, Bottom and
>     Toggle with Press, Release, Single Tap, Double Tap and Triple Tap
>     (paste the list for one device). Before the reboot they are absent.
>     - **Done:** open.
> 100. **Proxy route, no hands** (D5, D7, P3). `tools/devctl.py run "Watch
>     Events" Light=<zone light> Events=5001-5015`. Then, through `Proxy
>     Command` with `Command=BUTTON_ACTION`: Top press (`BUTTON_ID=0
>     ACTION=1`), then click (`ACTION=2`). Then the same twice within
>     0.3 s. Then a press, a 1.5 s wait, and a release (`ACTION=0`). Paste
>     the `event …` lines. Expected in mode "count": the tap gives Top Push
>     and Top Single (Single about 0.6 s after the press), and perhaps Top
>     Release. The double gives two Pushes and one Top Double, no Single.
>     The hold gives Push and Release, no tap event. If Single fires at the
>     click, or twice, or with the Double, or if no tap event fires at all,
>     the coordinator sets `BUTTON_EVENTS_MODE = "action"` (Lua only),
>     reloads through the dev loop and repeats. Record which mode passed in
>     #432.
>     - **Done:** open.
> 101. **Link route, the owner's hands, under a minute** (D4, D6). With
>     Watch Events on the device a keypad is bound to (the bedroom switch
>     and Golden hours, or a zone light bound for the test as in step 95):
>     tap top once, double tap top, triple tap top, hold top about 2 s.
>     Same expectations as step 100 (Triple instead of Double for the
>     triple). The light: the first tap ramps; the second and third taps of
>     a multi-tap change nothing (tap-stop D4). No `ReceivedFromProxy 5001
>     BUTTON_ACTION` appears after a link press, so the proxy sends nothing
>     back (paste the Lua lines). The keypad's own double-tap programming,
>     if any, still fires.
>     - **Done:** open.
> 102. **A tap that stops still counts** (D8). Tap top from off, and about
>     1.5 s later tap top again: the ramp stops as in 1.4, and the events
>     show two separate Single taps.
>     - **Done:** open.
> 103. **Set All LEDs** (#432 D11). Read and paste the device's six LED
>     colours first. `Proxy Command` `Command=SET_ALL_LED COLOR=ff0000` on
>     the device bound to the keypad. Composer's LED colour rows read
>     ff0000 for all six, and the keypad's bound buttons show red lit and
>     unlit (owner glance, optional). Then set the six colours back as
>     read, in Composer.
>     - **Done:** open.
> 104. **Hue-side reports, once a second** (#433 D12). On a single Hue
>     Light: drag its slider in the Hue app slowly for about 5 s, then let
>     go. The Lua tab shows at most one `LIGHT_BRIGHTNESS_CHANGED` per
>     second during the drag, and the last one equals the Hue app's final
>     level within a point, at most about 1 s after letting go. Turn it off
>     in the Hue app: the tile and LEDs go off within about a second. Paste
>     the timestamps.
>     - **Done:** open.
> 105. **A Control4 ramp after a Hue drag** (#433 D13). Drag in the Hue app,
>     and within a second start a timed level from the Navigator (or `Proxy
>     Command SET_BRIGHTNESS_TARGET LIGHT_BRIGHTNESS_TARGET=80 RATE=3000`).
>     The tile animates to 80 without jumping back to the Hue level partway.
>     - **Done:** open.

### 8.3 The order on the house

1. The 1.5 dev build with every 1.5 capability (one reboot, turn-on D27).
2. Steps 99 to 105, with `BUTTON_EVENTS_MODE` set by step 100.
3. The release, built from `main` with the mode that passed.

## 9. Reboot and changelog

**Reboot: yes**, for D2 only (`has_button_events` and `multi_click` in
`hue_light.c4z` and `hue_scene.c4z`). Composer asks "Restart Director?";
Yes does not load them; the owner reboots the controller from System
Manager. This rides the same reboot as the other 1.5 capability changes.
`SET_ALL_LED`, the link notifications and the throttle are Lua and work at
once on install.

`CHANGELOG.md`, under `## Unreleased`, `### Changed`:

```markdown
- Hue Light and Hue Scene devices now fire their own button events in
  Programming, as a Control4 dimmer does: Press, Release, Single Tap,
  Double Tap and Triple Tap on the Top, Bottom and Toggle buttons, for
  presses from keypads bound to their Button Links. The keypad's own button
  events still fire on the keypad; program one or the other for a press.
  The events appear after the controller is rebooted from System Manager
  following the update (#432).
- The light's Set All LEDs command now sets every button's LED colour, lit
  and unlit, on Hue Light and Hue Scene devices, and the colours are kept
  (#432).
- A level change made in the Hue app, on a Hue dimmer switch or by a Hue
  automation now reaches Control4 at most once a second while it moves, and
  ends on the exact level, so programming on Brightness Changed fires less
  often. Turning a light on or off in Hue still shows at once (#433).
```

## 10. Open questions for the owner

Coordinator, 2026-11-09: as recommended, colour reports are not throttled in 1.5 (the owner's standing approval; revisit if the house shows colour floods).

Everything else is settled above, or by house step 100's rule (D7).

1. **Throttle colour reports too?** Row L7 and #433 are about levels
   (D16). A colour drag in the Hue app reaches Control4 at the bridge's pace
   of up to about two a second, and each one fires Color Changed.
   Recommended: not now. Revisit only if colour programming fires too
   often in practice.
