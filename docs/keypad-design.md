# Keypad buttons on Hue Light and Hue Scene devices: the contract

Owner's request (2026-10-22): a Control4 Switch V2 or Essential Switch run
as a 2-button keypad with "Buttons Control Load" off (the switch's own load
programmed to 100 %) must drive a Hue Light through the light's Button Link
inputs: tap top = on, tap bottom = off, hold = dim up or down, like a
Control4 dimmer, and the stock Philips driver did this. Source for every
proxy claim: `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2`
(cloned from Snap One's repository on 2026-10-22).

**Current (2026-10-24):** built in both drivers; the Button Links on a
light, and the holds and LEDs on a scene, are verified on the house
(`docs/status.md`). Later sections correct earlier ones, so read in this
order: keypads reach the driver through its own Button Link connections
("Hardware findings"); the light's hold is Hue's relative dim ("Light
parity"); a scene device is a dimmer whose on state follows the on rule
(`held_on`) of `docs/scene-dimmer-design.md`. Both drivers declare
`hide_proxy_properties`, so Composer shows none of the proxy's preset,
rate or button colour settings and the defaults below apply. Superseded
(2026-10-25, #59): both declare it False now, so Composer lists those
settings once the controller has been rebooted after the install.
Corrected (2026-10-25, #249): the scene holds "verified" above only
stopped; they never ramped. From 1.3 a hold on a scene, zone light or
room light no longer reaches Hue as one grouped_light dim: see "Group
holds (1.3, #249)" at the end and `docs/group-hold-design.md`.
Current (2026-11-08, #421): a tap on a Hue Light starts a ramp over the
click rate, now the time of the whole range (3000 ms by default), and a
later tap on any of its buttons stops it where it is; a second press within
600 ms of the previous one on the same button is part of a double tap and
does nothing, on lights and scenes alike. See "Tap ramps and tap stops
(#421)" at the end and [the contract](tap-stop-design.md).
Current (2026-11-09, #421 contract section 10): measured on the house, a
light's stop writes its estimate with a 1 s glide, zone and room lights
ramp and stop as one group, and Hue Scene devices get tap fades and tap
stops too (time-based scenes keep instant taps).
Current (2026-11-09, #429, #427, #430, [the turn-on contract](turn-on-design.md)):
a Hue Light's turn-ons, its taps included, follow Control4's brightness On
Mode (Preset, the default, or Previous) and carry the colour its colour on
mode asks for; the light declares the on mode capabilities instead of
`supports_default_on`; click and hold rates go up to 6 000 000 ms on light
and scene; and the Hue Scene lists its click rates. A static change: the
install needs the owner's reboot from System Manager.

## What the proxy does [verified: BUTTON_ACTION command and notification]

Superseded in part (2026-10-22, hardware): the Top, Bottom and Toggle
links are connections the driver declares, and a bound keypad button
delivers `DO_PUSH` / `DO_RELEASE` / `DO_CLICK` on them; see "Hardware
findings".

- The light_v2 proxy creates the Top, Bottom and Toggle Button Link consumer
  connections itself and forwards every `BUTTON_ACTION` it receives on them
  to the protocol driver: `BUTTON_ID` 0 top, 1 bottom, 2 toggle; `ACTION`
  1 press, 2 release as a click, 0 release after a hold.
- The driver must send a `BUTTON_ACTION` notification back with the same
  values for every press and release; without a press notification the
  proxy generates a second press when it sees a click, and without a
  release later presses stop working.
- "On" preset: `SET_PRESET_LEVEL {LEVEL}` arrives when the proxy's On
  preset changes, for drivers declaring `supports_default_on` (deprecated
  in favour of the on-mode preset capability, but the documented path for
  this command; the two must not be combined) **[assumed until seen on
  hardware]**. Current (2026-11-09, #429 D2 to D4): the light declares
  `brightness_on_mode_preset` and `brightness_on_mode_previous` instead of
  `supports_default_on`, and handles `UPDATE_BRIGHTNESS_ON_MODE` and
  `UPDATE_BRIGHTNESS_PRESET` (`src/hue_light/light/turnon.lua`). An
  `UPDATE_BRIGHTNESS_PRESET` for the On preset stores its level in the
  `preset` setting without a `PRESET_LEVEL` echo (`dev.take_setting`);
  `SET_PRESET_LEVEL` is still handled as before [assumed until check T2 of
  the turn-on contract: which of the two arrives once the on modes are
  declared].
- Rates: `SET_CLICK_RATE_UP/DOWN` and `SET_HOLD_RATE_UP/DOWN {RATE ms}`
  arrive when the dealer edits them in Composer; the properties appear only
  for drivers declaring `click_rates` and `hold_rates`.
- Current (2026-10-24): `hide_proxy_properties` True hides the preset and
  the rates in Composer, so nobody can change them there and the defaults
  apply (whether the proxy sends values of its own has not been checked);
  the handlers stay, and exposing the settings is open (`docs/status.md`).
  Superseded (2026-10-25, #59): `hide_proxy_properties` False, so the
  preset and the rates are shown after the controller reboot and reach these
  handlers (verified on the house, Composer rounds 41 and 42).
- The answer: after each `SET_*`, and for every declared setting at late
  init, the driver sends the matching notification (`PRESET_LEVEL`,
  `CLICK_RATE_UP`/`DOWN`, `HOLD_RATE_UP`/`DOWN`) so Composer shows the value
  in use.
- Its form: the bare value as a string. The proxy reads the documented
  `{RATE = …}` table as 0 (verified on the house, 2026-10-25: a table zeroed
  the settings until the bare form replaced it).
- Ranges: preset 1 to 100, rates 0 to 86 400 000 ms. A value outside them is
  refused: from the proxy, the value kept is reported back; persisted, it is
  deleted, warned about once, and the default used. Current (2026-10-25,
  #234): a value from the proxy that is not a number is refused the same
  way, with the value kept reported back. Current (2026-11-09, #430 D20):
  rates 0 to 6 000 000 ms (`device.RATE_MAX`), the `click_rate_max` and
  `hold_rate_max` both `driver.xml` declare; a persisted rate above it is
  dropped at load the same way. The proxy's default rates
  (`UPDATE_BRIGHTNESS_RATE_DEFAULT`, `UPDATE_COLOR_RATE_DEFAULT`) are kept
  in the same range and persisted, with no notify back (D8).
- Colour on mode (#234): `SET_COLOR_ON_MODE {PRESET ID}` sets the proxy's
  own setting; a driver takes part only by declaring `color_on_mode_preset`,
  `_previous` or `_fade` (static capabilities) and then handling
  `UPDATE_COLOR_ON_MODE` and `UPDATE_COLOR_PRESET`, and no notification
  confirms it [verified: proxy reference, What's New in 3.3.2 and those
  commands]. The Hue Light declares none, so it neither handles nor uses it;
  its manual says so. Current (2026-11-09, #427 D9 to D16): the Hue Light
  declares all three and handles `UPDATE_COLOR_ON_MODE` and
  `UPDATE_COLOR_PRESET` (`src/hue_light/light/turnon.lua`): the On colour
  on every Control4 turn-on, blended toward the Dim colour at low levels,
  the Dim colour on a timed turn-off, and Fade as Control4's warm dim. Its
  manual describes the modes.

## Driver behaviour

Current (2026-10-25, build 316, #57): the press / click / release machine
with its timers (400 ms hold, 600 ms dim after the turn-on at 1 %, 1 s
click guard), the keypad settings and their notifications, the LEDs and
the button colours are one module shared by both drivers,
`src/common/device.lua` (`device.new`: `button_action`, `dim_after_on`,
`load_settings`, `update_leds`). Each driver keeps what a tap and a hold
do, through the hooks `dev.on_click`, `dev.on_hold` and `dev.on_finish`.
The light takes the preset, click and hold settings, the scene the hold
rates only. Current (2026-11-08, #421): the machine also keeps the time of
each button's last press for a 600 ms double-tap window (`DOUBLE_TAP_MS`)
and has two more hooks, `dev.ramp_active` and `dev.on_ramp_stop`, which
only the light fills in ("Tap ramps and tap stops (#421)"). Superseded
(2026-11-09, #421 S-D4): the scene fills them in too, and takes the click
rates as well as the hold rates.

Hue Light (`src/hue_light/driver.lua`):

| Input | Behaviour |
|---|---|
| press (any button) | echo the notification; start a 400 ms hold timer |
| click top | brightness target = On preset over click rate up |
| click bottom | target 0 over click rate down |
| click toggle | off → preset over click up; on → 0 over click down |
| hold (timer fired before the release) | Current (since 2026-10-23, "Light parity"): `HUE_DIM up` (top, or toggle while off) or `down` (bottom, or toggle while on) with the hold rate scaled by the distance (since 2026-10-25, #232: the proxy's ramp only, `HUE_DIM` carries the whole rate; "Light parity"); a 100 ms tick keeps an estimate of the level. Held top/toggle while off: on at 1 % first, `HUE_DIM up` 600 ms later; held bottom while off: nothing. Originally (2026-10-22): a timed brightness target to the end of the range, and held bottom while off turned the light on dimmed |
| release after hold | Current: `HUE_DIM stop` with the estimate as `level` (written only if the bridge refuses the stop). Originally: the estimate written as the brightness |
| release-as-click after a ramp started | same as stop; a click on the same button within 1 s after a hold's release is ignored |

Superseded (2026-11-08, #421): the three click rows. A click starts a ramp
the light driver keeps, to the preset (from below or from above) or to 0,
over `click rate × distance / 100`; a press outside the double-tap window
while it runs stops it, and a press inside the window does nothing. The
rule table is in "Tap ramps and tap stops (#421)".

Settings persist per device (`preset_level`, `click_rate_up`,
`click_rate_down`, `hold_rate_up`, `hold_rate_down`); defaults 100 %,
250 ms, 250 ms, 5000 ms, 5000 ms. Superseded (2026-11-08, #421 D3): the
click rates default to 3000 ms each and are the time of the whole range,
as the hold rates are; a stored click rate keeps its number and takes the
new meaning (D15). `ON` and `TOGGLE` from programming keep
going to 100 % (unchanged; the preset is a keypad matter until the on-mode
preset API is adopted). Superseded (2026-11-08, #233, owner's Option 1):
`ON` and `TOGGLE` from off go to the On preset too, at rate 0 (the click
rates stay with taps), and `ON` on a lit light sets it to the preset as a
top tap does; the on-mode preset API is still not adopted
(`docs/lights-design.md`, light_v2 proxy commands). Current (2026-11-09,
#429 D5, D6; #430 D8): the on-mode preset API is adopted. `ON`, `TOGGLE`
from off, `DYNAMIC_ON` and a top or toggle tap from off follow the On
Mode: Preset goes to the on mode preset's level (the On preset unless the
proxy names another), Previous to the last level reported (a zone or room
light: a group on with no brightness, each lamp at its own level). While
on, a top tap and `ON` go to the on mode preset's level in Preset and to
the On preset in Previous. `ON`, `OFF`, `TOGGLE` and a target without a
rate use the proxy's default brightness rate, 0 until it sends one; taps
keep the click rates.

Hue Scene (`src/hue_scene/driver.lua`): echo every action; click or release
of top = recall (ON), bottom = OFF, toggle = toggle; holds do nothing.
Superseded (2026-10-23): holds dim the scene's room or zone, see "Scene
hold-to-dim and keypad LEDs" below.

`driver.xml` (light): `click_rates`, `hold_rates`, `supports_default_on`
true; `click_rate_min` 0, `hold_rate_min` 1000. Scene: unchanged.
Superseded (2026-10-23): the scene declares `hold_rates` (min 1000) and
`has_leds` (below) and, since build 160, `dimmer`, `set_level` and
`ramp_level` (`docs/scene-dimmer-design.md`). Current (2026-11-09, turn-on
contract §7.1): the light declares `click_rate_max` and `hold_rate_max`
6000000 and the five on mode capabilities instead of `supports_default_on`;
the scene declares `click_rates` True with `click_rate_min` 0 and
`click_rate_max` 6000000, and `hold_rate_max` 6000000; both dropped
`ramp_level`, `on_off`, `min_max` and `buttons_are_virtual` (D22).

## Verification

Specs in `tests/spec/light_driver_spec.lua` and `scene_driver_spec.lua`
(tap, preset, hold and release, echo notifications, persisted rates).
Current (2026-10-25, build 316): the shared machine has its own spec,
`tests/spec/device_spec.lua`.
Hardware: bind a switch's buttons to a light's Button Links in Composer's
Connections (a drag; by hand), tap and hold; the manual's chapter "Using
the lights from Control4" describes the setup. Superseded (2026-10-27,
#312): the Windows session can make the binding by a synthesized drag
from the keypad's own row (`docs/composer-remote.md`, "Learned
2026-10-27").

## Hardware findings (2026-10-22, builds 144 and 146 installed)

The proxy creates only the "Brightness Stop" and "Color Stop" Button Links
from the capabilities (current, 2026-11-08, #421 D7: the light's
`SET_BRIGHTNESS_STOP` now stops a running ramp at Hue; that the Brightness
Stop link sends it is **[assumed]** until the house check of the contract's
section 7); the Top, Bottom and Toggle Button Links are
connections the **protocol driver declares itself** (ids 200, 201, 202,
class BUTTON_LINK, provider side, shown under the light's Control Outputs
in Composer), and a bound keypad button delivers `DO_PUSH`, `DO_RELEASE`
and `DO_CLICK` on that binding id rather than `BUTTON_ACTION` [verified:
public light_v2 drivers on GitHub; the SDK's jumpstart template calls the
base id "ButtonLinkBindingIDBase"]. Both drivers now declare the three
connections and route the binding commands into the same button logic;
`BUTTON_ACTION` on the proxy binding stays as the proxy's own route.

Install behaviour seen on the house (build 141 → 144 → 146):

- 144 changed the light's **capabilities** (`click_rates`, `hold_rates`,
  `supports_default_on`): Composer asked "Restart Director?" for
  `hue_light.c4z`. After the restart the bridge ran 144, but the existing
  light device still reported 141 and read "Not bound to a Hue Bridge"
  although Composer showed it bound; a right-click Update Driver ("Versions
  are equal", overwrite) did not change it. A device re-created under 144
  reported a blank Driver Version until a second per-device overwrite
  brought it to 144. (Explained since: "Restart Director?" does not restart
  Director; see "Install findings" below.)
- 146 added the three Button Link **connections**: no restart prompt; the
  existing device showed Top, Bottom and Toggle Button Link under Control
  Outputs at once and read 146. **Existing devices pick up new connections
  on an ordinary "Add or Update Driver or Agent…"; nothing has to be
  re-created.**
- The links are outputs of the light (provider side); a keypad button's
  output is bound to them in Connections by hand.

Open: the light reading "Not bound" while bound after a Director restart
suggests the binding is not yet visible to `GetBoundProviderDevice` at late
init after a restart, and the light never looks again until a binding
event. Fixed (branch `binding-recheck`, merged; in every build since):
when unbound at late init, the
light and scene drivers look again at 5, 15, 30 and 60 s, greet the bridge
as soon as the binding is visible, and stop on a binding event, on destroy,
or after the last check.

Tested on the house with build 150 (2026-10-22 19:12–19:23): Composer has
no Director restart command and System Manager runs elevated, out of the
Windows session's reach, so the owner rebooted the controller by hand from
System Manager. Composer lost Director at 19:12:58 and was idle again at
19:20:35; the bridge's event feed was back at 19:19:28. The light read
"Right Bedside Light (Hue color lamp)", Online, version 150 at all 19 reads
between 19:21:03 and 19:22:33 and never "Not bound". Whether the re-check
ran or the binding was visible at late init cannot be told from Composer
(its Lua pane does not replay startup lines). Note the original failure
followed a Director restart forced by a driver update, not a reboot; the
outcome after a reboot is verified, the re-check path itself is not.

## Scene hold-to-dim and keypad LEDs (owner-approved 2026-10-23)

The owner's use case is a Hue **scene** on two Control4 switches run as
2-button keypads (top button → the scene device's Top Button Link, bottom →
Bottom Button Link). Taps work; this section adds holding to dim and LEDs
that follow the scene. Approved as proposed, including "the scene stays on
through dims from its own buttons".

### Messages (new or extended)

| Message | Direction | Params (all strings) | Meaning |
|---|---|---|---|
| `HUE_SCENE_DIM` | scene → bridge | `rid`, `device_id`, `direction` (`up` / `down` / `stop`), `duration` (ms, up/down only) | Dim the scene's group: one grouped_light PUT `{"dimming_delta":{"action":"up"/"down","brightness_delta":100},"dynamics":{"duration":<ms>}}` to start, `{"dimming_delta":{"action":"stop"}}` to stop. Relative, so the scene's colours and per-light differences are kept. `stop` and `dynamics` on a grouped_light were assumed; **verified on the house with build 154 (2026-10-23)**. Corrected (2026-10-25, #249): build 154 showed that Hue accepts the body (HTTP 200), not that it ramps. Measured, Hue ignores `dynamics.duration` for a grouped_light `dimming_delta` and covers the whole delta in about a second, so the `stop` comes too late and the lights end at full or off. From 1.3 the bridge turns this message into per-light dims or timed group steps ("Group holds (1.3, #249)"). |
| `HUE_SCENE_RECALL` | scene → bridge | adds optional `brightness` (1–100) | Recall with `recall.dimming.brightness` override (used for "hold top while off": recall at 1 %; since the dimmer also for a slider target from off). |
| `HUE_SCENE_GROUP` | bridge → scene | `rid`, and `on` (`true`/`false`) and/or `other_active` (`true`) | The scene's room/zone grouped_light turned on/off (from the event feed or the resync), or another scene of the same group became active. Sent at resync (current `on`) and on change. Since 2026-10-23 also `level`, the group's brightness, and sent in a hello answer (`docs/scene-dimmer-design.md`). |

### Bridge (`src/hue_bridge/bridge/scenes.lua`)

- `scenes:dim(params)` resolves the device's entry like recall/off
  (`entry_for_command`), finds the scene's group's `grouped_light_rid`
  and calls `ctx.group_dim(grouped_rid, body)`; returns true when queued.
  `duration` is clamped to 0–6 000 000. Gone scene or no grouped_light:
  log and return false.
- `scenes:recall` passes a valid `brightness` param as
  `body.recall.dimming = { brightness = n }`.
- Group on/off: the module keeps `group_on[grouped_rid]` from the resync
  (one extra GET `/clip/v2/resource/grouped_light` in `fetch_all`) and from
  `grouped_light` items in `on_container` (`item.on.on`). On a change it
  sends `HUE_SCENE_GROUP {rid, on}` to every linked scene device whose
  group owns that grouped_light; after each resync it sends the current
  value to every linked device.
- Other scene active: when a scene status event makes scene B `static` or
  `dynamic_palette`, every other linked scene device of B's group gets
  `HUE_SCENE_GROUP {rid, other_active = "true"}`.

### Coordinator (`src/hue_bridge/driver.lua`)

`ctx.group_dim(rid, body)` → `state.group_queue:set(rid, body)` (returns
true when queued); `dispatch.commands["HUE_SCENE_DIM"]` →
`state.scenes:dim(params)`.
Current (2026-10-25, build 316): `group_dim` hands the queue the fields
`{ dim, delta, rate, level }` taken from the body, and the queue builds
the PUT ("Queue support" below); the group queue sends one request a
second with a burst of 3, and a hold's start and stop skip that bucket
(`src/hue_bridge/driver.lua:new_group_queue`,
`src/hue_bridge/bridge/commands.lua:urgent`; `docs/zone-light-design.md`
Decision 9).
Current (1.3, #249): `group_dim` hands every call to
`bridge/group_hold.lua` (`gh:dim(grouped_light_rid, body, level)`), which
sends a hold's start and stop to the lit member lights through the light
queue (1 to 10 lit; every member for a hold up from off), or timed group
steps (more than 10, or while a smart scene runs or a scene plays
dynamically there), and passes everything else to the group queue with
the same fields (`docs/group-hold-design.md` G1 to G6a).

### Scene device (`src/hue_scene/driver.lua`)

- **On state**: `effective_on = is_on() or dimmed_on`. `dimmed_on` is set
  when a hold-dim starts from this device's own buttons (or a hold-recall
  from off); it keeps the tile and LEDs on when Hue then reports the scene
  inactive. Cleared by `HUE_SCENE_GROUP on=false`, by `other_active`, by
  this device's OFF / bottom tap / toggle-off, and replaced by a normal
  recall. `LIGHT_BRIGHTNESS_CHANGED` is 100/0 from `effective_on`.
  Superseded (2026-10-23): `dimmed_on` became `held_on`, set by any
  activation (Control4, keypad or Hue app), persisted, and ended only by
  the group going off, another scene of the group, or this device's OFF;
  the level reported is the group's brightness. See
  `docs/scene-dimmer-design.md`, Behaviour.
- **Hold** (DO_PUSH on 200/201/202 or BUTTON_ACTION press, still down after
  400 ms): top (or toggle while off) → if on, `HUE_SCENE_DIM up` with the
  hold-up rate; if off, `HUE_SCENE_RECALL {brightness=1}` then
  `HUE_SCENE_DIM up` 600 ms later. Bottom (or toggle while on) → if on,
  `HUE_SCENE_DIM down` with the hold-down rate; if off, nothing. Release
  after a hold → `HUE_SCENE_DIM stop`. Hold rates persist
  (`SET_HOLD_RATE_UP/DOWN`), default 5000 ms; `driver.xml` declares
  `hold_rates` True, `hold_rate_min` 1000. Since the dimmer a hold also
  sends the proxy `LIGHT_BRIGHTNESS_CHANGING` toward 100 or 1 at its start
  and settles on the group's level reports after the release; since 1.3
  (#243) its `RATE` covers only the distance left, so the tile keeps pace
  with the lamps.
  Current (2026-10-25, build 316): a time-based scene held from off is
  started instead, and the dim up follows once the bridge reports its
  group on with a level (1.5 s at the latest) while the button is still
  down (`docs/smart-scenes-design.md` Decision 4;
  `src/hue_scene/driver.lua:start_smart_hold`).
- A click arriving within 1 s after a hold's release on the same button is
  ignored (some keypads may send it).
  Current (2026-11-08, #421 D1, D4): a press within 600 ms of the previous
  press on the same button is part of a double tap and its click is
  swallowed, so a double tap on toggle leaves the scene on; held, it is a
  hold as usual. Scene taps stay a recall or an off, with no ramp to
  stop. Superseded (2026-11-09, owner, #421 S-D1 to S-D6): a top tap (or
  toggle while off) recalls the scene with a duration of
  `click up × (100 − level) / 100`, a bottom tap (or toggle while on)
  turns the group off with a duration of `click down × level / 100`, and
  a press outside the window while that fade runs stops it with the
  grouped_light `dimming_delta` stop, so each lamp keeps its own level.
  Time-based scenes keep instant taps. See "Tap ramps and tap stops
  (#421)", "Scenes (2026-11-09)".

### Keypad LEDs (both device drivers) [verified: Snap One's
`drivers-template-code-public` `c4hook_light_v2.lua`]

- On every on/off change, at late init, and when a keypad binds to a link:
  `C4:SendToProxy(b, "MATCH_LED_STATE", { STATE = <boolean on> }, "COMMAND")`
  for b = 200, 201, 202, and `BUTTON_INFO {BUTTON_ID, ON_COLOR, OFF_COLOR,
  CURRENT_COLOR}` to the proxy binding 5001 as a NOTIFY.
- Button colours persist per button; defaults top `0000ff`/`000000`, bottom
  `000000`/`0000ff` (lit when off), toggle `0000ff`/`000000`.
  `SET_BUTTON_COLOR {BUTTON_ID, ON_COLOR | OFF_COLOR}` from the proxy stores
  one, then sends `BUTTON_COLORS` on that link and `BUTTON_INFO` to 5001.
  `REQUEST_BUTTON_COLORS` arriving on a link answers `BUTTON_COLORS` on that
  link, then `MATCH_LED_STATE`.
- The light driver gets the same LED and colour handling (on = `st.on`) and
  the same 1 s click suppression after a hold.

The switch's own "LED Behavior" may need its option that follows the bound
device instead of "Push/Release" (owner checks on the switch). Answered
(2026-10-27, #312): binding a keypad button's link sets its LED Behavior
to "Follow Connection" by itself; disconnecting does not set it back.

Both `driver.xml` declare `has_leds` True so Composer offers the button LED
colour settings (which arrive as `SET_BUTTON_COLOR`); the scene's also
declares `hold_rates` True with `hold_rate_min` 1000. Both are capability
changes, so installing this build is expected to ask for a Director
restart, as build 144 did.

Current (2026-10-24): `hide_proxy_properties` True hides the colour
settings too, so they cannot be changed in Composer and the default
colours apply. Superseded (2026-10-25, #59): shown since then, after the
controller reboot the capability change needs.

Install findings (2026-10-23/24): the capability changes of this section
and of the scene dimmer made Composer ask "Restart Director?"; Yes did
**not** restart Director, and the devices kept the old capabilities until
the owner rebooted the controller from System Manager (the Windows session
cannot operate it); Composer has no Director restart command of its own.
Builds that change only Lua or connections take effect at once, as build
146 showed (`docs/status.md`, "How builds reach the house";
`docs/composer-remote.md` rule 10). With the reboot, the scene holds, the
LEDs following Shine and the dimmer were verified
(`docs/scene-dimmer-design.md`, "Verified on hardware").
Corrected (2026-10-25, #249): the holds only in that they stopped at the
release; the ramp was not measured then, and it runs in about a second.

### Light parity (owner, 2026-10-23: "whatever capabilities we implement for scenes get intelligently carried over to the individual light driver as well")

- Holds on a Hue Light use the same native relative dim as the scene:
  `HUE_DIM {rid, direction up|down|stop, duration, level}` → the light's
  queue sends `dimming_delta` up/down with `dynamics.duration`, then a bare
  `stop`. The device keeps its 100 ms estimate and sends it as `level` with
  the stop; the proxy's tile settles on the bridge's next report, or on the
  estimate after the fallback time.
- Hold top (or toggle) while the light is off: on at 1 %, then dim up
  600 ms later. Hold bottom while off: nothing (it used to turn the light
  on dimmed).
- LED state, button colours, `has_leds`, hold rates and the 1 s click
  suppression after a hold are the same in both drivers.
- Not verified on hardware: the light's `HUE_DIM` hold and LEDs (the house
  has no Hue Light device now, and `docs/status.md` lists holds and LEDs as
  verified on a scene only).
  2026-10-25 (dev build 284, `docs/design.md` "Hardware pass of 2026-10-25
  night"): the light driver's hold path ran on a zone light, a Hue Light
  device whose `HUE_DIM` the bridge sends to its room or zone: a top hold
  from off released at 800 ms turned it on at 1 % and sent no dim, and a
  hold down followed by a click 100 ms after the release sent dim down and
  stop and ignored the click. A single light's `HUE_DIM` is still not
  seen.
- Current (2026-10-25, #232, #234): `HUE_DIM` up or down carries the whole
  hold rate, at most 6 000 000 ms (the bound the bridge holds zone and scene
  holds to), and the bridge asks for the whole range, so Hue dims at 100 %
  per hold rate from any level; the proxy's CHANGING and the 100 ms
  estimate keep the share of the rate the distance takes, the same speed.
  Until then `HUE_DIM` carried that share with the whole range, so a hold
  from 50 % ran Hue at twice the tile's speed. The whole range rather than
  the distance left: a zone light's lamps below its average still reach the
  end while the button is held, and the start still skips the bridge's
  request bucket (`commands.urgent`). That Hue keeps the speed and stops at
  the end of the range is assumed until the hold on the house that #232
  asks for.
  Measured 2026-10-25 (#249): on a single **light** Hue honours the
  duration and the stop (a lamp held for about 3 s of a 10 s ramp ended
  near 46 %); on a **grouped_light** it ignores the duration and covers the
  whole delta in about a second, so a zone light's hold ran to the end.
  Current (1.3, #249): a zone or room light's `HUE_DIM` reaches each lit
  lamp with the whole rate, each ramping from its own level (1 to 10 lit),
  or becomes timed group steps (more than 10 lit, or a smart or dynamic
  scene playing on the zone); "Group holds (1.3, #249)" below. A single
  Hue Light's hold is unchanged.

### Queue support (`src/hue_bridge/bridge/commands.lua`)

A `dim` field (`up`/`down`/`stop`) builds the `dimming_delta` body (with an
optional `delta` for `brightness_delta`, default 100, added for the scene
slider in `docs/scene-dimmer-design.md`); a dim
replaces a pending brightness or on/off and vice versa. If the bridge
refuses a stop with a non-retriable error, the queue writes a fallback
brightness: the stop's `level` (lights), else the group level recorded at
the ramp's start (`scenes.group_level`, from grouped_light reports) moved by
the elapsed share of the ramp (scenes). Without either the ramp runs to its
end and a warning is logged.
Current (1.3, #249): the group fallback now serves only the holds that
still go to the grouped_light (no lit member, `docs/group-hold-design.md`
G6). A per-light group hold's stops carry no `level` and the light queue
has no `level_of`, so a lamp whose stop is refused runs to the end of its
ramp, with the warning; a stepped hold sends no stop (G4, G5).

### Group holds (1.3, #249)

Measured on the house on 2026-10-25 (rounds 47b and 47c, and direct
requests through the dev loop; issue #249): every keypad hold on a Hue
Scene device or a zone light jumped to full or off. A grouped_light
`dimming_delta` down with `brightness_delta` 100 and `dynamics.duration`
10 000 ms, stopped about 6 s later, left the zone's lamps at 0 % from 80 %
(an honoured ramp would have left about 20 %), and keypad holds of 1.5 s
(1.1 s to the stop) took the room or zone from 100 % or 50 % to 0 %. The
same request on one lamp's **light** resource, stopped after about 3 s,
left it near 46 % from 80 %. Hue therefore ignores `dynamics.duration`
on a grouped_light dim and honours it on a light.

Owner's choice (2026-11-07): the mix, option 3 of the issue. The contract
is `docs/group-hold-design.md`; in short:

- The devices are unchanged: the scene still sends `HUE_SCENE_DIM` and a
  zone or room light `HUE_DIM`, with the hold rate, the proxy's
  `LIGHT_BRIGHTNESS_CHANGING` and the 100 ms estimate as before. The
  bridge's `group_dim` hook hands every call to `bridge/group_hold.lua`,
  which looks at the grouped_light's member lights that are **on** in the
  bridge's cache when the hold starts (G3) and fixes that set for the hold.
  A hold **up with none lit** takes every member, and the mode follows the
  member count (A1): a hold from off dims up 600 ms after the 1 % start
  (`DIM_AFTER_ON_MS`), before the event stream has reported the lamps on,
  so without A1 every hold from off would take the old path.
- **1 to 10 lit (`PER_LIGHT_MAX`)**: each lit member gets the hold as a
  single Hue Light's hold, `{ dim = up|down, delta = 100, rate = hold rate }`
  through the light queue, and the release a `stop` to each (G4). Smooth,
  relative levels kept, stops where released; two requests per lamp per
  hold, which the light queue sends at once (`commands.urgent`).
- **More than 10 lit**: one group `dimming_delta` step at once and one
  every `STEP_MS` (1000 ms) while held, each `min(100, 100 × 1000 / rate)`
  percent without a duration (20 % at the default 5000 ms), until they add
  up to 100 or the release, which only cancels the timer (G5). Visible
  steps, softened by Hue's default transition; relative levels kept.
- **A smart scene running, or a scene playing dynamically**, on the
  grouped_light's room or zone (`keep_group`): stepped whatever the count,
  and the log line adds `(scene running)` (G6a, A2). A change to a single
  light ends a scene's active status and a dynamic palette (V11), and a
  time-based scene device follows Hue's state
  (`docs/smart-scenes-design.md` Decision 2), so a per-light hold there
  would end the schedule and turn the device off; a whole-group step
  leaves both running (V11's relative group dim did).
- **Members unknown, or a hold down with none lit**: the start and its
  stop go to the group queue as before, `rate` and `level` included (G6),
  which still runs to the end in about a second.
- One hold per grouped_light (G7); teardown cancels the step timers (G8).

To verify on the house (contract §5): a per-light hold on several lamps,
the stepped hold's step size and pace, that a group `dimming_delta` leaves
lamps that are off alone **[assumed]**, that a hold from off ramps
smoothly from 1 % (A1), and that a hold on a room whose time-based scene
runs leaves the schedule running (G6a). A per-light hold on an ordinary,
static scene may still end Hue's "active" for it, as any change to one
light does; the scene device's on rule keeps its tile on.

## Tap ramps and tap stops (#421)

Owner's request (2026-11-08): a keypad tap on a Hue light behaves like a
Control4 dimmer on a regular bulb, beside the 1.3 holds. A tap ramps from
wherever the light is, the top button to the On preset and the bottom to
off; a later tap stops the ramp where it is; that later tap has to come
after Control4's double-tap window, because a double tap is its own event
and can trigger programming; and the default click rates are slow enough
to catch the light on the way. The same day the owner made Control4's
lighting guidance a standing rule (#422), which this design follows row by
row (contract section 9).

The contract is [`tap-stop-design.md`](tap-stop-design.md); the research
behind it is [the Control4 side](tap-stop-research-c4.md) and
[the Hue side](tap-stop-research-hue.md). Written 2026-11-08, before the
build. Current (2026-11-09): the dev-loop measurement on build 552 (the
contract's section 10, also in #421) settled the stop at Hue and the
zone and room lights, and the owner extended tap ramps and tap stops to
Hue Scene devices; the bullets below carry dated notes where it changed
them, and "Scenes (2026-11-09)" at the end has the scene rules. The keypad
checks at a switch (contract section 7 item 2) had not been done as this
is written.

Decisions, in short (D numbers are the contract's):

- **Devices (D1).** Hue Light devices (single, zone and room lights) get
  tap ramps and tap stops. Hue Scene devices get only the double-tap
  window; a scene tap stays a recall or an off. Hue Motion has no buttons.
  Superseded (2026-11-09, owner: "Scenes can ramp so tap to stop ramp
  should apply to them too"): Hue Scene devices get tap fades and tap
  stops as well ("Scenes (2026-11-09)" below).
- **Where a tap goes (D2).** Top to the On preset (Default On Brightness,
  #233), down to it from above; bottom to off; toggle by the on state.
  Current (2026-11-09, #429 D5): with On Mode Previous a top or toggle tap
  from off goes to the previous level; while on, the top tap still goes to
  the On preset. A tap also carries the colour of the colour on mode (#427
  D11 to D15).
- **Speed (D3).** Click rates are the time of the whole range, as hold
  rates are: a tap ramp lasts `click rate × distance / 100`. Click Rate Up
  and Down default to 3000 ms (were 250 ms); hold rates stay 5000 ms, so
  Control4's "Fast" presets stay faster than its "Slow" ones.
- **Double-tap window (D4).** A press within `DOUBLE_TAP_MS` = 600 ms of the
  previous press on the same button is part of a double or triple tap: it
  starts and stops nothing, a running ramp goes on, it is still echoed, and
  held past `HOLD_AFTER_MS` it is a hold. Fixed in the code, no property.
  The first tap acts at once; waiting out the window would delay every tap.
- **The stop (D5).** While a ramp runs, the **press** of any button outside
  the window stops it where it is, the other button and the toggle
  included: the light never turns round. The click after that press is
  swallowed. Held past `HOLD_AFTER_MS`, the press stops the ramp and then
  holds from the stopped level.
- **What a tap stops (D6).** Any brightness ramp the light driver runs with
  a time above 0: a tap ramp, and a timed target from programming,
  Navigator or lighting scenes. Holds keep their own machine (#249).
- **Stop entry points (D7).** `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP`
  stop a running ramp at Hue as a tap does. Until #421 they only reported
  the cached level while the lamp went on to the end, because the light
  driver had no way to stop a ramp at Hue.
- **At Hue (D8, D9).** The start is the absolute target with a duration
  (`HUE_SET` with `brightness` and `rate`, as a tap sent before); the stop
  is `HUE_DIM` with `direction = "stop"` and the device's estimate as
  `level`, which the bridge sends as `dimming_delta` stop and writes as a
  level only if Hue refuses the stop. If the house measurement shows that
  Hue does not stop an absolute transition, `STOP_MODE = "level"` in
  `src/hue_light/driver.lua` sends the estimate as an absolute level
  instead (option C). One constant, no property.
  Current (2026-11-09, measured, contract section 10): `STOP_MODE =
  "level"` with `STOP_GLIDE_MS = 1000`, for single, zone and room lights
  alike. The `dimming_delta` stop did halt a light's timed fade (L2), but
  the bridge then kept the fade's target as the level until it read the
  lamp about 10 s after the fade's planned end. Writing the estimate at
  once (rate 0) showed a small step, because Hue's fade runs slightly
  behind a linear estimate; writing it with a 1000 ms transition looked
  smooth, and the bridge reports the estimate at once, so the bridge, the
  Hue app and Control4 agree straight away. The lamp halts where it is
  and settles within a second; the stop is not claimed to be exact.
- **Reporting (D10).** `LIGHT_BRIGHTNESS_CHANGING` at the start (current,
  target, ramp time), one `LIGHT_BRIGHTNESS_CHANGED` at the stop (the
  estimate) or at the end; bridge level reports are held back while the
  ramp runs, because Hue may report the target at once. An off report or a
  change from elsewhere goes through and ends the ramp; after a stop, the
  bridge's next report corrects the estimate.
- **Other commands (D11).** Any brightness command replaces the ramp; a
  colour command does not end it.
- **Queues (D12, D13).** A tap's start and a `"level"` stop go out at once,
  past the request bucket (`HUE_SET` with `urgent = "true"`), as a hold's
  start and stop do. A stop that finds its start still unsent in the
  bridge's queue replaces both with the stop's level, rate 0.
- **Zone and room lights (D14).** The same path to the grouped_light,
  through `zone_lights` and `group_hold`. Whether a grouped_light keeps an
  absolute duration and honours the stop is measured first (Hue §9, Z1 and
  Z2); if not, a group tap stays a quick change and a follow-up issue
  builds group tap ramps from group_hold's per-lamp split.
  Current (2026-11-09, measured): Z1 and Z2 passed. A grouped_light keeps
  an absolute `dynamics.duration` (a zone faded over 20 s), and the
  gliding level stop is smooth on every lamp, so zone and room lights
  ramp and stop as one group and the follow-up is not needed.
- **Stored click rates (D15).** A changed default does not reach a stored
  value, so the install brief has the Windows session read every Hue Light
  device's Click Rate Up and Down and set any that differ to 3000 ms; that
  also shows whether Composer accepts 3000 ms (#430).

The rule ("within the window": a press within 600 ms of the previous press
on the same button; "ramping": a ramp of D6 runs; "at the preset": within
1 point):

| State | Input | Action |
|---|---|---|
| idle, off | top tap or toggle tap | ramp to the preset over `click up × preset / 100` |
| idle, on below the preset | top tap | ramp up to the preset over `click up × distance / 100` |
| idle, on above the preset | top tap | ramp down to the preset over `click down × distance / 100` |
| idle, at the preset | top tap | nothing at Hue; CHANGED with the level |
| idle, on | bottom tap or toggle tap | ramp to off over `click down × level / 100` |
| idle, off | bottom tap | nothing |
| any | a press within the window | ignored; a running ramp goes on; held, a hold |
| ramping | a press outside the window, any button | stop; the following click is swallowed |
| ramping | that press held past `HOLD_AFTER_MS` | stop, then hold from the stopped level (top up, bottom down, toggle by the on state) |
| ramping | the ramp's time runs out | idle; the end level from Hue's report, or the target after the fallback time |
| ramping | `SET_BRIGHTNESS_STOP` or `STOP_SCENE_RAMP` | stop |
| ramping | any brightness command | the command takes over; idle |
| ramping | a colour command | the ramp goes on |
| holding | anything | unchanged (#249) |
| idle, within 1 s after a hold's release, same button | click | ignored (unchanged) |

Current (2026-11-09, #429, #427; `docs/turn-on-design.md` §4): "the
preset" in the rows above is, from off, the On Mode's level (the previous
level in Previous) and, while on, the on mode preset's level (the On
preset in Previous). A tap's `HUE_SET` also carries the colour of the
colour on mode: the On colour blended for the level on a turn-on and on
taps while the blend runs, the Dim colour on a tap to off, nothing in
colour on mode Previous. A tap stop carries the blend for the estimate; a
hold carries no colour, and the blend follows 500 ms after its release.

A click rate of 0 is an instant change with nothing to stop, as before. A
stop very close to off (an estimate below 1) stops at 1 %: the light stays
on, as a dimmer stopped near the bottom does.

The split in the code (contract section 4): `src/common/device.lua` keeps
the window and calls the two new hooks, whose defaults (`ramp_active`
false, `on_ramp_stop` empty) leave a scene with the window alone;
`src/hue_light/driver.lua` keeps the ramp record (`from`, `to`, `time`,
`started`, `tap`), the estimate and `stop_ramp`; the bridge's queues carry
`urgent` and D13. No `<capabilities>` change: `click_rates`,
`supports_target` and `supports_brightness_stop` were declared already, so
the install needs no controller reboot. Superseded in part (2026-11-09,
#421 S-D4): the scene driver fills in the two hooks too. Hue Light
devices still need no capability change, but Composer lists a scene's
click rates only if `src/hue_scene/driver.xml` declares `click_rates` True
(it declared False through 1.3) [verified: `docs/tap-stop-research-c4.md`
§3.3, LV2 `_11-CLICKRATES`]: a capability change, so the install that
brings it needs a controller reboot from System Manager. Without it a
scene uses the 3000 ms defaults. Current (2026-11-09, #430 D21):
`src/hue_scene/driver.xml` declares `click_rates` True with
`click_rate_min` 0 and `click_rate_max` 6000000, and the scene loads and
reports `click_up` and `click_down`; the reboot of the turn-on contract
brings them to Composer.

### Scenes (2026-11-09, contract section 10.1)

The owner extended tap ramps and tap stops to Hue Scene devices on
2026-11-09, after the measurement showed that Hue fades a scene recall
over a `duration` (S1), stops such a fade with a grouped_light
`dimming_delta` stop, each lamp at its own level (S2), lets a hold start
smoothly right after that stop (S3), and fades a grouped_light
`on: false` with a duration, which the same stop interrupts with the
lamps still lit (S4).

- **Fade in (S-D1).** A top tap, or a toggle tap while the scene is off,
  recalls the scene over `click up × (100 − level) / 100` (3 s from off at
  the default rate). An ordinary scene already on at 100 does nothing at
  Hue and reports CHANGED.
- **Fade out (S-D2).** A bottom tap, or a toggle tap while it is on,
  turns the scene's group off over `click down × level / 100`: the
  grouped_light `on: false` with a duration (`HUE_SCENE_OFF` gains an
  optional `duration`, S-D6).
- **The stop (S-D3).** The grouped_light `dimming_delta` stop, sent as
  `HUE_SCENE_DIM` with `direction = "stop"` and the estimate as `level`,
  which the bridge writes only if Hue refuses the stop. Not a level
  write: that would bring every lamp to one level and lose the scene's
  look. The device reports its estimate as CHANGED at once; the bridge's
  report of the real level arrives about 10 s after the fade's planned
  end and goes through.
- **The same machine (S-D4).** The double-tap window (D4), the stop on
  the press (D5), `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` (D7), the
  reporting (D10) and other commands taking over (D11) work as on a
  light; the scene driver implements `dev.ramp_active` and
  `dev.on_ramp_stop`. A press held past `HOLD_AFTER_MS` during a fade
  stops it, then holds from there (safe right after the stop, S3).
- **Time-based scenes (S-D5).** Activate and deactivate take no duration
  at Hue, so their taps stay instant, with nothing to ramp or stop: a
  departure from Control4's guideline (contract section 9, row 1) forced
  by Hue. The double-tap window still applies.
- **Urgent (S-D6).** A keypad tap's recall and off go out at once, as a
  light's tap start does (D12).

The scene's click rates default to 3000 ms each and are the time of the
whole range, as the light's are; a rate of 0 is an instant recall or off
with nothing to stop. The scene rows of the rule ("level" is the scene's
reported level):

| State | Input | Action |
|---|---|---|
| idle, off | top tap or toggle tap | recall over `click up` (the whole range) |
| idle, on below 100 | top tap | recall over `click up × (100 − level) / 100` |
| idle, on at 100 | top tap | nothing at Hue; CHANGED with the level |
| idle, on | bottom tap or toggle tap | group off over `click down × level / 100` |
| idle, off | bottom tap | nothing |
| any | a press within the window | ignored; a running fade goes on; held, a hold |
| fading | a press outside the window, any button | grouped_light `dimming_delta` stop; the following click is swallowed |
| fading | that press held past `HOLD_AFTER_MS` | stop, then hold from there |
| fading | `SET_BRIGHTNESS_STOP` or `STOP_SCENE_RAMP` | stop |
| fading | any brightness command | the command takes over; idle |
| any, time-based scene | a tap | as before #421: start or stop the schedule at once |

This section supersedes, above: the click rows of the Hue Light table and
the 250 ms click rate defaults ("Driver behaviour"), and the light's
`SET_BRIGHTNESS_STOP` reporting only the cached level ("Hardware
findings"). Holds, the 1 s click guard after a hold, the LEDs and the
button colours are unchanged.

To verify on the house (contract section 7): first the dev-loop
measurement (Hue §9, L1 to L11 on one lamp, Z1 to Z7 on one zone), which
decides `STOP_MODE` and whether zone and room lights ramp as one; then, at a
switch with the owner, the order and timing of a tap's and a double tap's
commands, the keypad's real double-tap window, and whether the Brightness
Stop link sends `SET_BRIGHTNESS_STOP`; then the release and D15's click
rate read-back. The Composer steps are `docs/composer-checklist.md`
section M (steps 88 to 95). Current (2026-11-09): the measurement is done
(contract section 10: `"level"` with a 1 s glide, Z1 and Z2 passed, and
the scene steps S1 to S4); the switch checks and the release remain, and
section M now runs to step 98, with the scene steps 96 to 98.
