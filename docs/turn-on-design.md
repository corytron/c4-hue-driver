# Turn-on behaviour, colour presets and rate ranges: the contract

Issues: closes **#429** (brightness On Mode, Preset and Previous, with
preset ids), **#427** (Default On and Dim colours, colour on modes, warm
dim) and **#430** (the ramp and rate ranges Control4 enforces). The owner
decided all three on 2026-11-09: build them together, follow Control4, one
controller reboot. Written 2026-11-09 against `main` at 4910aa3 (release
1.4 "Maarva", build 565). Siblings written at the same time:
`docs/load-groups-design.md` (#435), `docs/offline-design.md` (#428),
`docs/hue-automation-audit-design.md` (#280), `docs/house-checks-plan.md`.

Tags: [verified: …] means read in the SDK reference, the code or a house
record (file and line given); [assumed] means nobody has seen it yet. SDK
short names are those of `docs/c4-lighting-guidelines.md` §2 (LV2 caps,
LV2 cmds, LV2 notif, LV2 vars, LV2 new, BP, API).

## Contents

- [1. Summary](#1-summary)
- [2. Findings](#2-findings)
- [3. Decisions](#3-decisions)
- [4. The rules in one place](#4-the-rules-in-one-place)
- [5. Lifecycle edge cases](#5-lifecycle-edge-cases)
- [6. Control4 guidelines](#6-control4-guidelines)
- [7. Interfaces](#7-interfaces)
- [8. Implementation split](#8-implementation-split)
- [9. Tests and house checks](#9-tests-and-house-checks)
- [10. Reboot, existing devices, changelog](#10-reboot-existing-devices-changelog)
- [11. Open questions for the owner](#11-open-questions-for-the-owner)

## 1. Summary

Today a Hue Light turns on at its Default On Brightness and in whatever
colour it last had. Composer shows a colour on mode and On and Dim colours
that the driver ignores. The rate ranges Control4 enforces are mostly
undeclared.

After this change:

- **Brightness On Mode (#429).** Hue Light devices (single, zone, room)
  declare Control4's On Mode capabilities. Preset (the default, today's
  behaviour) turns the light on at a brightness preset. Previous turns it on
  at the level it had when it went off; on a zone or room light every lamp
  comes back at its own level. Keypad taps, ON, TOGGLE and tiles follow the
  mode. Notifications name presets, so the Daylight Agent can follow.
- **Colour (#427).** Every Control4 turn-on of a colour light carries the
  colour its colour on mode asks for. Preset uses the On colour, blended
  toward the Dim colour at low levels. Fade is Control4's warm dim: colour
  follows brightness from Dim at 1 % to On at 100 %. Previous keeps Hue's
  last colour. A timed turn-off fades toward the Dim colour.
- **Rates (#430).** Every driver declares the ranges it really honours:
  click and hold rates up to 6 000 000 ms (100 minutes), brightness and
  colour rates 0 to 6 000 000 ms, one rate for colour and brightness. The
  proxy's default brightness rate drives ON, OFF and TOGGLE.
- Hue Scene devices get the rate parts and their click rates in Composer,
  but no On Mode (D1).
- All static capability changes land in this release: one reboot.

## 2. Findings

### 2.1 What Control4 documents

| # | Finding | Source |
|---|---|---|
| F1 | `supports_default_on` is deprecated; drivers should use the brightness on mode capabilities, and declaring both confuses Composer. It is static. | [verified: LV2 caps `_32-SUPPORTSDEFAULTON.md`] |
| F2 | `brightness_on_mode_preset` opts in to presets as On Mode. The driver then tracks preset ids in targets and notifies, and handles `UPDATE_BRIGHTNESS_ON_MODE` and `UPDATE_BRIGHTNESS_PRESET` for turn-ons the proxy does not start. Static. | [verified: LV2 caps `_6-brightnessonmodepreset.md`] |
| F3 | `brightness_on_mode_previous` opts in to Previous. The 3.3.2+ proxy remembers the last non-zero level the driver reported before a CHANGED of 0. On a generic on it sends `SET_BRIGHTNESS_TARGET` with that level. A driver-started turn-on can read the Previous preset. Static. | [verified: LV2 caps `_7-brightnessonmodeprevious.md`] |
| F4 | `UPDATE_BRIGHTNESS_ON_MODE` carries the preset id to turn on to and its level (a convenience). Turn-ons through Button Links and other driver-only paths must honour it. | [verified: LV2 cmds `_20.1-UPDATEBRIGHTNESSONMODE.md`] |
| F5 | `UPDATE_BRIGHTNESS_PRESET` carries COMMAND (ADDED, MODIFIED, REMOVED), the preset id (printed as `ID` on one page, `PRESET ID` on another), NAME and LEVEL. A driver may ignore it or use it (keypad firmware, Daylight Agent). | [verified: LV2 cmds `_20.3-UPDATEBRIGHTNESSPREST.md`, `_20.6-UPDATEBRIGHTNESSPRESET.md`] |
| F6 | The "On" brightness preset has id 1. | [verified: LV2 notif `_16-PRESETLEVEL.md`] |
| F7 | `UPDATE_BRIGHTNESS_RATE_DEFAULT {RATE}` tells the driver the default rate used by old generic on/off, Navigators and customer scenes. `UPDATE_COLOR_RATE_DEFAULT` is the colour twin. With linked colour rates, setting the brightness default also sets the colour one. | [verified: LV2 cmds `_20.2-…`, `_20.5-…`, `_21.3-SETBRIGHTNESSRATEDEFAULT.md`] |
| F8 | `LIGHT_BRIGHTNESS_CHANGING` takes optional `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID` and `LIGHT_BRIGHTNESS_TARGET_PRESET_ID`; `LIGHT_BRIGHTNESS_CHANGED` takes `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID`, only when the level equals that preset. With them the proxy can move the light when a preset's level changes (Daylight Agent). | [verified: LV2 notif `_10.2-…`, `_10.3-…`] |
| F9 | `SET_BRIGHTNESS_TARGET` carries `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` for drivers with On Modes. | [verified: LV2 cmds `_1.5-SETBRIGHTNESSTARGET.md`] |
| F10 | `color_on_mode_preset`, `_previous` and `_fade` opt in to colour on modes. The driver then handles `UPDATE_COLOR_ON_MODE` and `UPDATE_COLOR_PRESET`, and preset ids and origins in colour targets and notifies (`LIGHT_COLOR_TARGET_PRESET_ID`, `…_TARGET_PRESET_ORIGIN`, `…_CURRENT_PRESET_ID`, `…_CURRENT_PRESET_ORIGIN`). All static. | [verified: LV2 caps `_7.2-…`, `_7.3-…`, `_7.4-…`] |
| F11 | Previous colour: the proxy remembers the last colour reported before a brightness CHANGED of 0, and sends it as `SET_COLOR_TARGET` on a generic on. | [verified: LV2 caps `_7.4-coloronmode previous.md`] |
| F12 | Fade: the dealer picks a Dim colour (at 1 %) and an On colour (at 100 %). On every `SET_BRIGHTNESS_TARGET` the driver sets the mix for that level, even without a colour command; the proxy sends no colour on a normal turn-on in this mode. An explicit `SET_COLOR_TARGET` is obeyed, and the next brightness target applies the formula again. | [verified: LV2 caps `_7.2-coloronmodefade.md`; LV2 cmds `_20.4-UPDATECOLORONMODE.md`] |
| F13 | `UPDATE_COLOR_ON_MODE` carries the on preset's id, origin (1 device, 2 Color agent) and its x, y and mode as conveniences, and the same four for the fade preset. The origin texts on that page contradict each other. | [verified: LV2 cmds `_20.4-UPDATECOLORONMODE.md`] |
| F14 | Every colour light has mandatory On and Dim colour presets. The On colour is the colour at the Default On Brightness; the Dim colour at 1 %. In between the colour is interpolated: the page's example (On 4000 K, Dim 2000 K, Default On 80 %) gives 3000 K at 40 % and 4000 K at 80 % and above. The formula applies on a turn-on through `SET_BRIGHTNESS_TARGET` without a colour command and on later targets, until a `SET_COLOR_TARGET` after the turn-on; it resumes after the next off and on. Composer's "enable Dim colour" checkbox only copies the On colour into Dim. `UPDATE_COLOR_PRESET` carries COMMAND, ID, NAME, COLOR X, COLOR Y, COLOR MODE. | [verified: LV2 cmds `_21-UPDATECOLORPRESET.md`] |
| F15 | The Default On Colour is set whenever the device turns on (targets, taps, holds). The Dim colour is used while turning off, but not during a hold down, whose end is unknown. A colour sent while off is kept and applied at the next Control4 turn-on. | [verified: BP "Default On and Dim Colors", "Setting Color while the Light is Off"] |
| F16 | Warm dim as Snap One describes it for a Hue driver: colour temperature linear in brightness between a warm value at 1 % and a cool one at 100 %, on brightness changes only; any colour choice ends it until the next off and on. | [verified: BP "Warm Dim"] |
| F17 | `SET_COLOR_TARGET` from a driver with On Modes can name a preset id and origin. | [verified: LV2 cmds `_9.6-SET_COLOR_TARGET.md`] |
| F18 | `GET_SETUP` is a request a UI sends to the proxy; it answers at once with XML that includes `<brightnesses>` with `<level name=… level=…>` entries and `<colors>` with `<color name=… category=… color_x color_y color_mode …>` entries. The sample shows no preset ids. | [verified: LV2 cmds `_16.5-GETSETUP.md`] |
| F19 | `C4:SendUIRequest(proxyId, request, params)` returns the receiver's XML answer; Snap One's own example sends `ADD_DRIVER_COLOR_PRESET` from a light driver to its proxy this way. That `GET_SETUP` answers the same way is [assumed]. | [verified: API `22_miscellaneous/_36-SendUIRequest.md`; LV2 cmds `_.5-ADDDRIVERCOLORPRESET.md`] |
| F20 | The proxy variable 1300 "Color Presets" holds all configured colour presets as XML, for UIs. `C4:GetDeviceVariable(id, var)` reads another device's variable, not during OnDriverInit. Its XML format is not documented [assumed]. | [verified: LV2 vars `_0-HEADER.md`; API `36_variable/_5-GetDeviceVariable.md`] |
| F21 | From OS 3.3.2 Navigators send `DYNAMIC_ON` / `DYNAMIC_OFF`; a driver without dynamic on gets the On brightness preset. The capability pages say the proxy turns a generic on into `SET_BRIGHTNESS_TARGET` (and `SET_COLOR_TARGET`), so whether a driver ever receives `DYNAMIC_ON` is [assumed]. | [verified: LV2 cmds `_1.3-DYNAMICON.md`, `_1.2-DYNAMICOFF.md`; F3, F11] |
| F22 | `click_rate_max` is static, documented default 1 ms; `hold_rate_max` static, default 86 400 000 ms; `click_rate_min` default 0; `hold_rate_min` default 1000. Programming takes its ramp range from these. | [verified: LV2 caps `_12-…`, `_13-…`, `_15-…`, `_16-…`; BP "Enforcing min/max Capabilities"] |
| F23 | `brightness_rate_min` / `_max` are dynamic, for voice, Navigators and customer scenes, and should be set by every colour light. The capability page allows up to 4 294 967 295 (default 65 535); the dynamic-capabilities page prints "0-INT16 MAX". | [verified: LV2 caps `_1-…`, `_1.5-…`; LV2 notif `_8-DYNAMICCAPABILITIESCHANGED.md`] |
| F24 | `color_rate_behavior` (0 unchangeable, 1 one rate for both, 2 separate), `color_rate_min` / `_max`: dynamic, to be set by every colour light. | [verified: LV2 caps `_8.6-…`, `_8.7-…`, `_8.8-…`] |
| F25 | `color_trace_tolerance` is a CIELab delta from 3.3.1 (default 1.0) but an xy distance on 3.3.0. | [verified: LV2 caps `_13.5-COLORTRACETOLERANCE.md`] |
| F26 | 3.3.2 deprecates `num_buttons`, `ramp_level`, `min_max`, `on_off`, `buttons_are_virtual`, `fixed_ramp_rate`, and deprecates the `PRESET_LEVEL` variable in favour of the on mode preset. The current capability list no longer documents those flags at all. | [verified: LV2 new `_10-WHATSNEWIN332.md`; `ls` of LV2 caps] |

### 2.2 What the code does today

- `src/hue_light/driver.xml:143-169` declares `ramp_level`, `on_off`,
  `min_max` False, `click_rate_min` 0, `hold_rate_min` 1000,
  `supports_default_on` (line 153) and `buttons_are_virtual`; no on mode,
  no maxima [verified]. `src/hue_scene/driver.xml:120-144` declares
  `ramp_level`, `on_off`, `min_max`, `click_rates` False, `hold_rate_min`
  1000, `buttons_are_virtual` [verified].
- `TOGGLE` and `ON` go to `setting("preset")` at rate 0; `OFF` at rate 0
  (`src/hue_light/driver.lua:1198-1207`) [verified]. No `DYNAMIC_ON`,
  `DYNAMIC_OFF` or `UPDATE_*` handler exists anywhere under `src/`
  [verified: grep].
- A top tap goes to the preset from off, from below and from above
  (`driver.lua:1244-1266`) [verified].
- `set_brightness` (`driver.lua:613-653`) sends one CHANGING without preset
  ids, then `HUE_SET`; a colour stored while off rides along through
  `state.from_brightness_target` (`src/hue_light/light/state.lua:256-272`)
  [verified].
- `state.from_color_target` (`state.lua:280-307`) stores a colour when the
  cache says off (`:299`). `state.apply_hue` voids a stored colour when a
  report shows the light on (`:170-176`). So a colour target that arrives
  after a turn-on command but before Hue reports on is stored, then voided:
  it is lost [verified by reading; not seen on the house]. Order matters
  today: colour then brightness works (L13), brightness then colour does
  not.
- `HUE_CONFIGURE` sends one `DYNAMIC_CAPABILITIES_CHANGED` from
  `caps.params` with the colour flags and the CCT range
  (`driver.lua:795`, `src/hue_light/light/caps.lua:24-41`) [verified].
- Keypad settings live in `src/common/device.lua:134-145`: preset 1–100
  (default 100), click and hold rates 0–86 400 000 ms. Each is persisted,
  confirmed to the proxy with a bare value, and refused out of range
  [verified]. The scene loads only the hold rates (`hue_scene/driver.lua:136`)
  and taps with the default 3000 ms click rates it cannot show
  (`:1542-1549`) [verified].
- Holds are capped at 6 000 000 ms (`hue_light/driver.lua:1221`,
  `hue_scene/driver.lua:1627`); the bridge clamps scene and group durations
  there (`bridge/scenes.lua:78`, `bridge/zone_lights.lua:66`). A light's
  `HUE_SET` rate is not clamped (`bridge/commands.lua:252-305`) [verified].
- `HUE_SET` with `on=true` and no brightness is a plain Hue on
  (`bridge/commands.lua:213-219`, `body` `:283-289`) [verified]. On a
  grouped_light, that lights every member at its own last level and colour
  [assumed: `docs/zone-light-design.md` §1, check H2].
- The bridge needs no change for anything below: `HUE_SET` already carries
  on, brightness, x+y or mirek and rate in one PUT.

### 2.3 House facts

- Composer accepted click rates of 3.000 s on the four Hue Light devices on
  2026-11-09, so the documented `click_rate_max` default of 1 ms does not
  apply on OS 3.4.2 [verified: `docs/status.md`, the house settings of 1.4].
- The proxy's settings page shows Default On Brightness, the rates, LED
  colours and, on lights, a colour on mode [verified: `docs/design.md`,
  #59 round]. What it shows as On and Dim colours and as the colour on mode
  today has not been read [assumed]; check T0 reads it before the build.
- A static capability change needs a controller reboot from System Manager;
  "Restart Director?" answered Yes does not load it [verified:
  `docs/keypad-design.md` "Install findings"].
- Every bulb in the house has colour and colour temperature [verified:
  `docs/status.md`], so white-only and CCT-only behaviour is code and specs
  only.

### 2.4 Where the documents disagree

- **Two blend formulas.** The `UPDATE_COLOR_PRESET` page anchors the On
  colour at the Default On Brightness (F14). The fade page anchors it at
  100 % (F12). They describe different modes, so D13 uses each for its own.
- **Explicit colour in fade mode.** The fade page resumes the formula at the
  next brightness target (F12). BP "Warm Dim" ends warm dim until the next
  off and on (F16), but describes a Hue driver's own Extras switch, not the
  proxy's fade mode. D14 follows the fade page for fade mode and the
  `UPDATE_COLOR_PRESET` page for preset mode.
- **Rate maximum type** (F23). D20 declares 6 000 000 in its own notify, so
  a proxy that rejects the value cannot take the colour flags down with it.
- **Parameter spellings.** The `UPDATE_*` pages print names with spaces.
  On the house, `SET_COLOR_TARGET`'s spaced names arrived with underscores
  [verified: `docs/c4-lighting-guidelines.md` §6]. The parsers read both.

## 3. Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | **Per driver.** `hue_light` (single lamp, zone light, room light: one driver, one set of static capabilities) gets all three issues. `hue_scene` gets the rate parts of #430 (hold and click maxima, brightness rate range, the default rate), its click rates in Composer (D21) and the dropped deprecated flags (D22), but **no brightness or colour on mode**. `hue_motion` and `hue_bridge` are not lights. | A Hue scene's "on level" is a set of per-lamp levels. A preset below 100 or a Previous level can only be sent as a brightness override, which sets every lamp to one level and loses the scene's look [verified: house, #41, "both lamps at 1.19 %"]. ON already means "the scene as designed". A scene has no colour of its own. The rate parts do make sense: scenes take timed recalls and offs. |
| D2 | **Brightness on mode capabilities.** `hue_light` replaces `supports_default_on` with `brightness_on_mode_preset` True and `brightness_on_mode_previous` True. Never both (F1). | F1, F2, F3. Hue turns on at its last level natively, so Previous costs nothing. |
| D3 | **Default On Mode: Preset, On preset (id 1).** Until the proxy names another mode, a turn-on goes to the On preset at the Default On Brightness, the existing persisted `preset_level`. | Existing devices keep today's behaviour (owner, #429). The proxy's own default is "Default On", the same as Preset On [verified: LV2 new `_10-WHATSNEWIN332.md`]. |
| D4 | **Learning the brightness side.** `UPDATE_BRIGHTNESS_ON_MODE` sets the mode (preset id, its level). `UPDATE_BRIGHTNESS_PRESET` keeps a name → id map for On, Off and Previous and the level of the on mode's preset. For the On preset it also stores the level in the existing `preset` setting, **without** echoing `PRESET_LEVEL` (`dev.take_setting`, §7.5), so the proxy and the driver never ping-pong. `SET_PRESET_LEVEL` keeps working as today. The mode and map persist. | F4, F5, F6. No echo: the proxy told us the value, and an echo could loop if the proxy answers every set. |
| D5 | **Which turn-ons follow the mode.** From off: `ON`, `TOGGLE`, `DYNAMIC_ON`, a top tap and a toggle tap. Commands that name a level (`SET_BRIGHTNESS_TARGET`, Raise Level By, Restore Saved Level, the load group `GROUP_*` level commands) go to that level. A hold from off starts at 1 % as today. **While on**, a top tap and `ON` go to the on mode preset's level in Preset mode, and to the On preset (Default On Brightness) in Previous mode. | F4: driver-started turn-ons honour the mode. A hold from off ramps from the bottom on a Control4 dimmer (L43). While on, a turn-on mode has nothing to restore; Control4 ties the top tap to the Default On preset whatever the level [verified: LV2 vars `_0-HEADER.md`, Default On Preset Brightness]. |
| D6 | **Previous.** Single light: `HUE_SET` with `brightness` = the last non-zero level the driver reported to the proxy (`last_on_level`, in memory). Without one: Hue's remembered level from the bridge (`st.brightness`, which Hue keeps while off), else the On preset level. **Zone or room light:** `HUE_SET {on = "true"}` with no brightness, so Hue brings every lamp back at its own level; CHANGING names `last_on_level` (or the cached group level, else the On preset) as target, and no #308 goal is set. A `SET_BRIGHTNESS_TARGET` from off whose `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` is the Previous preset is treated the same on a zone or room light. | F3: the proxy tracks exactly "last non-zero CHANGED before a 0", which is what `last_on_level` mirrors. A zone's level is its lamps' average; turning them all on at the average would level out the lamps the owner set differently. A Hue group on keeps them [assumed: zone H2]. No goal, because the average after the on is only known from Hue. |
| D7 | **Preset ids in notifies.** CHANGING carries `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` when the target is a preset: the on mode preset at a turn-on, the On preset for a top tap or ON while on, the Off preset (if its id is known) for an off, or the id a `SET_BRIGHTNESS_TARGET` carried. CHANGING and CHANGED carry `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID` while the light sits at the preset last targeted (within 1 point). Any target without a preset, or a report off that preset's level, clears it. Only learned ids and On = 1 are ever sent. | F8, F9; L21. |
| D8 | **Default brightness rate.** `UPDATE_BRIGHTNESS_RATE_DEFAULT` and `UPDATE_COLOR_RATE_DEFAULT` are stored and persisted (0 to 6 000 000) in `common/device.lua` for both drivers. `ON`, `OFF`, `TOGGLE`, `DYNAMIC_ON`, `DYNAMIC_OFF` and a `SET_BRIGHTNESS_TARGET` without `RATE` use the brightness default; a `SET_COLOR_TARGET` without a rate uses the colour default. 0 until the proxy sends one. Keypad taps keep the click rates. | F7; L23. With nothing heard, ON and TOGGLE stay instant as today. |
| D9 | **Colour on mode capabilities.** `hue_light` declares `color_on_mode_preset`, `color_on_mode_previous` and `color_on_mode_fade` True. | F10; owner, #427. Static, so they go into this reboot with D2. |
| D10 | **Default colour mode and an On colour nobody set.** Until the proxy names a colour on mode, the mode is Preset with the proxy's **On** colour preset. The driver learns the On and Dim colours from the persisted copies, from `GET_SETUP` at start (D19) and from `UPDATE_COLOR_PRESET`. A light whose On colour nobody set in Composer turns on in whatever On colour the proxy holds (its default); the driver adds no colour of its own. While **no** On colour is known at all, a turn-on sends no colour, so the lamp keeps Hue's last colour as today. | Owner, #427: follow Control4 from this release; the changelog tells dealers to set the On and Dim colours. The proxy always has an On preset (F14), so "unset" cannot be told from "set". Unknown means unchanged. |
| D11 | **Turn-on colour by mode.** Preset: the on mode preset's colour, blended for the turn-on level (D13). Fade: the fade formula for the turn-on level. Previous: no colour; Hue keeps its last colour (and a zone each lamp's own). A colour set while off that is not the on mode colour wins at the next turn-on, and blending stays off for that time on. | F11, F12, F14, F15. Hue keeps the colour of an off lamp, so Previous is Hue's native turn-on. |
| D12 | **Dim colour on a turn-off.** A Control4 turn-off with a rate above 0 (a target of 0, a bottom or toggle tap, OFF or TOGGLE with a default rate, `DYNAMIC_OFF`) carries the Dim colour in the same `HUE_SET`, in Preset and Fade modes. Not with an instant off, not in Previous mode, never during or after a hold. | F15. Hue keeps an off lamp's colour, so the Dim colour also becomes the colour a later Hue-side turn-on shows. An instant off shows nothing, so it is skipped there to keep that side effect to the fades a dealer sees (guidelines departure D16, §6). In Previous mode it would become the remembered colour (F11) and defeat the mode. |
| D13 | **Blend formulas.** `blend(dim, on, level, top)`: `f = (level − 1) / (top − 1)`, clamped to 0..1 (1 when `top` ≤ 1). Preset mode: `top` = the on mode preset's level, `on` = its colour, `dim` = the Dim colour (F14). Fade mode: `top` = 100, `on` and `dim` from `UPDATE_COLOR_ON_MODE` (F12). When both colours are colour temperatures (mode 1), the blend is linear in Kelvin and the result is mode 1 (its xy from `C4:ColorCCTtoXY`); otherwise linear in x and y, mode 0. When Dim equals On (Composer's Dim checkbox off), the result is the On colour at every level. | F14's own example is linear in Kelvin (3000 K at 40 %); BP "Warm Dim" is linear in CCT; F12 gives the xy form. One function covers both modes. |
| D14 | **When blending applies.** Preset mode: from a Control4 turn-on that carried the on mode colour until an explicit colour (D16, not the on colour), a colour change made outside Control4 (§7.4 `foreign_color`), or the light going off. Fade mode: every Control4 brightness target while on gets the formula; an explicit colour is obeyed until the next brightness target. Previous mode: never. | F12, F14; §2.4. |
| D15 | **Blend paths.** Every Control4 brightness target above 0 while blending carries `blend(target)` in its `HUE_SET`: `SET_BRIGHTNESS_TARGET`, taps, ON while on, Raise and Restore, load group level commands. A tap stop's `HUE_SET` (#421 `stop_ramp`) carries `blend(estimate)`. A hold carries none (Hue's `dimming_delta` has no colour curve, D12 of the guidelines); `HOLD_COLOR_DELAY_MS` (500) after its release the driver sends `blend(final level)` over `HOLD_COLOR_GLIDE_MS` (1000). Any brightness or colour command, or a new press, cancels that pending colour. | BP asks colour to follow brightness. A colour merged onto a pending dim stop is dropped by the bridge queue (`docs/tap-stop-design.md` §8), so the colour waits until the stop has gone out. 1000 ms is the stop glide the owner found smooth (#421 §10). |
| D16 | **`SET_COLOR_TARGET`.** Also read `LIGHT_COLOR_TARGET_PRESET_ID` and `…_PRESET_ORIGIN`. Without x and y, look the preset up (the learned colour presets, §7.4). It is the **on colour** when its preset id (and origin, if given) is the on mode preset's, or its xy is within 0.002 and same mode of the on colour: then blending is untouched. Otherwise it is explicit (D14). CHANGING and CHANGED echo the preset id and origin while the light shows that preset. | F10, F17. The proxy may send the on colour itself around a tile's turn-on (F11, F21); that must not end the blend. |
| D17 | **A colour right after a turn-on is sent, not stored.** `from_color_target` stores a colour only when the light is off **and no Control4 turn-on is pending** (a brightness target from off whose report has not come, or a ramp to a level above 0). Otherwise it goes out; the bridge's 80 ms debounce usually folds it into the turn-on's PUT. | §2.2: today brightness-then-colour loses the colour. The proxy's turn-on and ALS scenes may send either order (BP "Handling Consecutive…", L13). |
| D18 | **Bulb abilities.** The colour a decision produces goes through the existing mapping (`state.color_fields`, from `from_color_target`): mirek for a CCT colour on a CCT bulb or on a CCT-only bulb, xy on a colour bulb. A white-only bulb never gets colour; its colour settings do nothing. A zone or room light sends one colour to its grouped_light; members that cannot show it ignore it [verified for xy and mirek reaching colour lamps; ignoring assumed: `docs/zone-light-design.md` §1]. Previous keeps each lamp's own colour. | The mapping is proven (L29). Hue clamps xy to the gamut (guidelines D8). |
| D19 | **Learning presets at start.** At late init the module loads its persisted copies. `SETUP_READ_MS` (3000) later the driver asks its proxy `C4:SendUIRequest(proxy_id, "GET_SETUP", {})` inside `pcall`. If that yields no colour presets it reads `C4:GetDeviceVariable(proxy_id, 1300)`. Both answers go through one lenient parser (§7.4). The raw text is logged once at debug, cut at 2000 characters. What is learned only fills gaps and maps; it never moves a light. | F18–F20. A timer keeps the call out of late init. Persisted copies cover a proxy that answers neither. |
| D20 | **Rate ranges.** Static: `click_rate_max` 6000000 and `hold_rate_max` 6000000 on light and scene. Dynamic: `brightness_rate_min` 0 and `brightness_rate_max` 6000000 on light and scene; `color_rate_behavior` 1, `color_rate_min` 0, `color_rate_max` 6000000 on the light. They go in a **second** `DYNAMIC_CAPABILITIES_CHANGED` sent right after the colour one. `common/device.lua`'s click and hold maxima become 6 000 000, and the light clamps every `HUE_SET` rate to 0..6 000 000. | F22–F24; L10, L11, L36. 6 000 000 ms is the Hue duration ceiling the repo already uses [assumed for a light; the scene and group paths clamp there]. Hue takes one duration per request (guidelines D9), so behaviour 1. A separate notify isolates F23's doubt. |
| D21 | **Scene click rates.** `hue_scene` declares `click_rates` True, `click_rate_min` 0, `click_rate_max` 6000000, and loads `click_up` / `click_down`. | Scene taps fade over the click rates since 1.4 (#421 S-D1), at defaults nobody can change. Static, so now or another reboot later. |
| D22 | **Deprecated flags go.** Remove `ramp_level`, `on_off`, `min_max` and `buttons_are_virtual` from both driver.xml files. `minimum_os_version` stays 3.3.0. | F26; L85. The flags are gone from the current capability list. The drivers declare `dimmer`, `set_level` and `supports_target`, which carry what they once said [assumed for 3.3.0 and 3.3.1, which nobody here runs]. Raising the minimum OS would block updates on those controllers for no gain. Check T1 confirms programming still offers ramps. |
| D23 | **No Extras warm-dim switch.** | Fade mode is Control4's own warm dim, set where dealers set the other colour settings. An Extras switch would be a second way to do the same; L60 stays Not applicable. |
| D24 | **No `color_trace_tolerance`.** | F25: a value that helps on 3.3.1+ (say 2) would match every colour on 3.3.0, our declared minimum. Hue's rounding is small; gamut clamps are too large for any tolerance. L37 stays with #431. |
| D25 | **`DYNAMIC_ON` / `DYNAMIC_OFF` are handled** in case they reach the driver: on per D5, D6 and D11 at the default rate (on a lit light only a report); off per D12 at the default rate. The scene: `turn_on(rate default)` / `turn_off(rate default)`. | F21: harmless if the proxy keeps them; right if it forwards them. |
| D26 | **The driver never moves a light on its own** because of an `UPDATE_*`, a preset change or anything learned at start. | F8: the proxy moves a light at a changed preset (Daylight Agent); moving it here too would double the command. Owner rule: automation only where decided. |
| D27 | **Rollout: one reboot.** Build the whole feature with its final capabilities. Install it first as a `--dev` build (Restart Director? Yes; the owner reboots from System Manager), run checks T1–T12 with Debug Mode on, fix parsers Lua-only through the dev loop. The release then has the same `<capabilities>`, so it needs no second reboot. | One reboot per release (preamble). The `UPDATE_*` parameter names and the order of the proxy's commands can only be seen once the capabilities are live. |

## 4. The rules in one place

`L_on` is the turn-on level of D5/D6; `C(level)` the colour of D11/D13;
"blend" is D14's state.

| Entry point | Light off | Light on |
|---|---|---|
| `ON`, `DYNAMIC_ON` | `L_on` over the default rate, with `C(L_on)` | ON: the D5 while-on level over the default rate, with blend if active. DYNAMIC_ON: report only |
| `TOGGLE` | as ON from off | off over the default rate; Dim colour if rate > 0 (D12) |
| `OFF`, `DYNAMIC_OFF` | report only (as today) | off over the default rate; Dim colour if rate > 0 |
| top tap, toggle tap | `L_on` over the click rate's share, with `C(L_on)` | top: the D5 while-on level, blend if active; toggle: off over click down with the Dim colour |
| bottom tap | nothing | off over click down's share, with the Dim colour |
| `SET_BRIGHTNESS_TARGET` > 0 | that level (zone + Previous preset id: D6), with `C(level)` | that level, blend if active |
| `SET_BRIGHTNESS_TARGET` 0 | report only | off over its rate; Dim colour if rate > 0 |
| hold (top, from off) | on at 1 % with `C(1)`, then the dim | — |
| hold (either way, on) | — | the dim, no colour; 500 ms after the release, `blend(final)` over 1 s if active |
| tap stop, `SET_BRIGHTNESS_STOP` during a ramp | — | the estimate, with `blend(estimate)` if active |
| `SET_COLOR_TARGET` | stored (D17 if a turn-on is pending: sent) | sent; explicit unless the on colour (D16) |
| Raise Level By, Restore Saved Level | the level, with `C(level)` | the level, blend if active |
| `GROUP_SET_LEVEL`, `GROUP_RAMP_TO_LEVEL` (#435) | as `SET_BRIGHTNESS_TARGET` | as `SET_BRIGHTNESS_TARGET` |
| `GROUP_START_RAMP`, `GROUP_STOP_RAMP` (#435) | as a hold | as a hold |
| change made in Hue (app, switch, automation) | nothing from Control4 | nothing; a colour change ends a Preset blend |

`C(level)` is nil (no colour sent) in Previous mode, for a bulb without
colour or colour temperature, and while no On colour is known (D10).

**For `docs/load-groups-design.md` (#435):** the group commands go through
the light driver's own `set_brightness` (level commands) and its hold path
(start and stop ramp), so they get every rule above with no code of their
own. The brightness On Mode does not apply to them: they name a level.

## 5. Lifecycle edge cases

The feature acts on its own in three places: it applies the On colour at
every Control4 turn-on, it learns presets at start, and it keeps persisted
copies. Nothing here creates, removes or renames devices.

| Case | What happens | Decision |
|---|---|---|
| Driver updated, before the reboot (new Lua, old capabilities) | The proxy still sends `SET_PRESET_LEVEL`; no `UPDATE_*` arrive [assumed]. Defaults apply: Preset On brightness (as today), Preset On colour if `GET_SETUP` gave one | Automatic. Same behaviour as after the reboot with untouched settings |
| Driver updated, after the reboot, settings untouched | Composer shows On Mode and colour on mode; the driver uses D3 and D10 | Automatic. The changelog tells dealers to set On and Dim colours |
| Dealer changes On Mode, Default On Brightness, On or Dim colour, colour on mode, default rate | `UPDATE_*` (and `SET_PRESET_LEVEL`) stored and persisted; used from the next command | Automatic. Never moves the light (D26) |
| Daylight Agent changes a preset's level | Stored; the proxy moves the light itself [assumed] | Driver acting on it: forbidden (D26) |
| Dealer removes the preset the On Mode points to | `UPDATE_BRIGHTNESS_PRESET REMOVED`: the mode falls back to the On preset (id 1) | Automatic |
| Controller reboot, Director restart, driver restart | Persisted copies load at late init; `GET_SETUP` refreshes at +3 s; `last_on_level` starts empty (D6 fallbacks) | Automatic |
| Project restored from a backup | Driver persistence and proxy settings come back together [assumed]; `GET_SETUP` reconciles colours | Automatic |
| Device deleted and added again in Composer | New device: proxy defaults, driver defaults (D3, D10); pairing is lost as always | Automatic (deleting is the dealer's click) |
| Persisted value corrupt or out of range | Dropped with one warning, defaults used (L83) | Automatic |
| Old persisted click or hold rate above 6 000 000 | Dropped at load with one warning, the default reported to the proxy (`device.lua` load path) | Automatic |
| Bulb replaced in Hue by one with fewer abilities | Capabilities follow (existing); colour mapped per D18; white-only gets none | Automatic |
| Zone or room gains or loses members, becomes mixed | One colour to the group; members that cannot show it ignore it; Previous keeps each lamp's own | Automatic |
| Colour changed in the Hue app while a Preset blend runs | Blend ends (§7.4 `foreign_color`); nothing is pushed back | Pushing the On colour back: forbidden |
| Light turned on from the Hue app, a Hue switch or a Hue automation | Hue's own turn-on (last level and colour, possibly the Dim colour after a Control4 fade-out, D12) | Correcting it afterwards: forbidden. Control4 applies its colours to Control4 turn-ons only |
| Hue scene recalled on the lamp in Hue | Hue's colours; a Preset blend ends | Automatic |
| Bridge reboot or bridge offline | Commands are retried and dropped as today (#428 for offline display); modes unchanged | Unchanged |
| On or Dim colour outside the bulb's gamut or CCT range | Hue clamps xy; mirek clamped to the bulb's range (existing) | Automatic (guidelines D8) |
| Colour set while the light is off | Kept; it wins at the next Control4 turn-on (D11) | Automatic (BP) |
| Composer's Dim checkbox unticked | Dim equals On; every blend gives the On colour | Automatic |
| Controller on OS 3.3.0 or 3.3.1 | On mode capabilities ignored [assumed]; defaults; colour presets exist from 3.3.0 | Automatic |
| OS 4.x controller | Same documented API [assumed] | Automatic |

## 6. Control4 guidelines

Rows of `docs/c4-lighting-guidelines.md` this contract touches. Status
after the build; [assumed] parts move to [verified] with checks T1–T12.

| Row | How it is met |
|---|---|
| L10 | Met: `click_rate_min` 0 and `click_rate_max` 6000000, `hold_rate_min` 1000 and `hold_rate_max` 6000000 on light and scene (D20, D21), matching the driver's own ranges. |
| L11 | Met: `brightness_rate_min` 0 and `brightness_rate_max` 6000000 in the configure notify (D20); the scene sends them at late init. |
| L17 | Unchanged in Preset mode; in Previous mode the top tap from off goes to the previous level and, while on, to the On preset (D5). |
| L19 | Met as before: TOGGLE from off follows the On Mode. |
| L20 | Met: on mode capabilities replace `supports_default_on`; `UPDATE_BRIGHTNESS_ON_MODE` and `UPDATE_BRIGHTNESS_PRESET` handled; keypad turn-ons follow (D2–D6). |
| L21 | Met: preset ids in CHANGING and CHANGED (D7). Daylight Agent following is [assumed]: the house has none to test. |
| L22 | Still Partial: `DYNAMIC_ON` / `DYNAMIC_OFF` handled (D25); which command a tile tap arrives as is logged in T3 for #431. |
| L23 | Met: `UPDATE_BRIGHTNESS_RATE_DEFAULT` drives ON, OFF, TOGGLE and rate-less targets (D8). |
| L25 | Met as before; the click and hold maxima now 6 000 000 (D20). |
| L31 | Met, and order-proof (D17). |
| L32 | Met: the On colour on every Control4 turn-on (D10, D11). |
| L33 | Met: the Dim colour on timed turn-offs, not holds; the blend on targets (D12–D15). Guidelines departure D16 below for instant offs. |
| L34 | Met: `color_on_mode_preset`, `_previous`, `_fade` and `UPDATE_COLOR_ON_MODE` (D9, D11). |
| L35 | Met through Fade mode (D13, D14): colour follows brightness on targets; during a hold it follows at the release (guidelines D12). |
| L36 | Met: `color_rate_behavior` 1, `color_rate_min` 0, `color_rate_max` 6000000 (D20). |
| L37 | Unchanged (D24); #431 verifies. |
| L60 | Unchanged, Not applicable (D23). |
| L82 | Met: everything that can be dynamic is (rates); the static changes are planned into one reboot (D27). |
| L84 | Unchanged: minimum OS 3.3.0 (D22); the on modes and `brightness_rate_*` need 3.3.2 and are ignored below it [assumed]. |
| L85 | Met: `ramp_level`, `on_off`, `min_max`, `buttons_are_virtual` removed from light and scene (D22). |

**New departure for section 5 of the guidelines**, numbered D16 there
(the implementing PR adds it; not this contract's D16):

| Id | Departure | Reason (Hue) | Rows |
|---|---|---|---|
| D16 | The Dim colour goes only with a turn-off that has a fade time, not with an instant off. | Hue keeps an off lamp's colour and shows it at the next Hue-side turn-on. An instant off would show nothing and only change what a Hue switch later turns on in. | L33 |

## 7. Interfaces

### 7.1 Capabilities (static; the reboot)

`src/hue_light/driver.xml`, inside `<capabilities>`:

- Remove: `<ramp_level>True</ramp_level>`, `<on_off>True</on_off>`,
  `<min_max>False</min_max>`, `<supports_default_on>True</supports_default_on>`,
  `<buttons_are_virtual>True</buttons_are_virtual>`.
- Add, after `<click_rate_min>0</click_rate_min>`:
  `<click_rate_max>6000000</click_rate_max>`.
- Add, after `<hold_rate_min>1000</hold_rate_min>`:
  `<hold_rate_max>6000000</hold_rate_max>`.
- Add, where `supports_default_on` was:
  `<brightness_on_mode_preset>True</brightness_on_mode_preset>`,
  `<brightness_on_mode_previous>True</brightness_on_mode_previous>`,
  `<color_on_mode_preset>True</color_on_mode_preset>`,
  `<color_on_mode_previous>True</color_on_mode_previous>`,
  `<color_on_mode_fade>True</color_on_mode_fade>`.
- Update the comment above `<capabilities>`: on modes (#429, #427), rate
  maxima (#430), and that colour and rate ranges are dynamic.

`src/hue_scene/driver.xml`, inside `<capabilities>`:

- Remove: `<ramp_level>True</ramp_level>`, `<on_off>True</on_off>`,
  `<min_max>False</min_max>`, `<buttons_are_virtual>True</buttons_are_virtual>`.
- Change `<click_rates>False</click_rates>` to `True`, and add after it
  `<click_rate_min>0</click_rate_min>` and
  `<click_rate_max>6000000</click_rate_max>`.
- Add, after `<hold_rate_min>1000</hold_rate_min>`:
  `<hold_rate_max>6000000</hold_rate_max>`.

`minimum_os_version` stays 3.3.0 in both. `hue_bridge` and `hue_motion`
are unchanged.

### 7.2 Dynamic capabilities

Light, in `HUE_CONFIGURE`, right after today's notify (`driver.lua:795`):
a second `DYNAMIC_CAPABILITIES_CHANGED` with `caps.rate_params()`:

```
brightness_rate_min = 0, brightness_rate_max = 6000000,
color_rate_behavior = 1, color_rate_min = 0, color_rate_max = 6000000
```

Scene, at late init (after `dev.load_settings()`) and in
`HUE_SCENE_CONFIGURE`: one `DYNAMIC_CAPABILITIES_CHANGED` with
`dev.rate_caps()` (`brightness_rate_min = 0, brightness_rate_max = 6000000`).

### 7.3 Proxy messages

From the proxy (`ReceivedFromProxy`). Each name is read with underscores
first, then with spaces; the first arrival of each command per driver start
is logged at debug with every parameter.

| Command | Parameters read | Driver |
|---|---|---|
| `UPDATE_BRIGHTNESS_ON_MODE` | `BRIGHTNESS_PRESET_ID`, `BRIGHTNESS_PRESET_LEVEL` | light |
| `UPDATE_BRIGHTNESS_PRESET` | `COMMAND`, `ID` or `PRESET_ID`, `NAME`, `LEVEL` | light |
| `UPDATE_COLOR_ON_MODE` | `COLOR_PRESET_ID`, `COLOR_PRESET_ORIGIN`, `COLOR_PRESET_COLOR_X`, `_Y`, `_MODE`; `COLOR_FADE_PRESET_ID`, `_ORIGIN`, `COLOR_FADE_PRESET_COLOR_X`, `_Y`, `_MODE` | light |
| `UPDATE_COLOR_PRESET` | `COMMAND`, `ID`, `NAME`, `COLOR_X`, `COLOR_Y`, `COLOR_MODE` | light |
| `UPDATE_BRIGHTNESS_RATE_DEFAULT` | `RATE` | both (`device.lua`) |
| `UPDATE_COLOR_RATE_DEFAULT` | `RATE` | both (`device.lua`; the scene ignores it) |
| `DYNAMIC_ON`, `DYNAMIC_OFF` | none | both (D25) |
| `SET_BRIGHTNESS_TARGET` | adds `LIGHT_BRIGHTNESS_TARGET_PRESET_ID`; `RATE` absent → default rate | light; scene: rate default only |
| `SET_COLOR_TARGET` | adds `LIGHT_COLOR_TARGET_PRESET_ID`, `LIGHT_COLOR_TARGET_PRESET_ORIGIN` | light |
| `SET_PRESET_LEVEL` | unchanged | light |

`UPDATE_COLOR_ON_MODE` kind [assumed until T10]: **fade** when the fade x
and y are present with a fade preset id; else **previous** when
`COLOR_PRESET_ID` is the learned "Previous" colour preset; else **preset**
with the on colour from the x, y, mode given (or looked up by id).

To the proxy, added parameters (names verified in F8 and F10):

| Notify | Added |
|---|---|
| `LIGHT_BRIGHTNESS_CHANGING` | `LIGHT_BRIGHTNESS_TARGET_PRESET_ID`, `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID` (D7) |
| `LIGHT_BRIGHTNESS_CHANGED` | `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID` (D7) |
| `LIGHT_COLOR_CHANGING` | sent now also when a turn-on, turn-off or blend carries a colour; `LIGHT_COLOR_TARGET_PRESET_ID`, `…_TARGET_PRESET_ORIGIN`, `…_CURRENT_PRESET_ID`, `…_CURRENT_PRESET_ORIGIN` when a preset is involved (D16) |
| `LIGHT_COLOR_CHANGED` | `LIGHT_COLOR_CURRENT_PRESET_ID`, `…_CURRENT_PRESET_ORIGIN` while the light shows that preset |
| `PRESET_LEVEL` | unchanged: at late init and after `SET_PRESET_LEVEL`; not after `UPDATE_BRIGHTNESS_PRESET` (D4) |

To the bridge: unchanged. `HUE_SET` gains no fields: a colour rides in
`x`+`y` or `mirek`, a zone Previous turn-on is `{rid, on = "true", rate}`.

### 7.4 The module `src/hue_light/light/turnon.lua` (new, pure Lua)

Pure except `C4:ColorXYtoCCT` / `C4:ColorCCTtoXY` (as `state.lua`) and the
persistence functions it is handed. Colours are tables
`{ x =, y =, mode = 0|1, id = n|nil, origin = n|nil }`.

```lua
local turnon = require("light.turnon")
local t = turnon.new({ get = fn(key), set = fn(key, value), delete = fn(key) })

turnon.load(t)                         -- persisted copies; drops bad ones with a warning
-- From the proxy: each returns true when it changed something.
turnon.update_brightness_on_mode(t, params)
turnon.update_brightness_preset(t, params)   -- also returns on_level when the preset is On
turnon.update_color_on_mode(t, params)
turnon.update_color_preset(t, params)
turnon.take_setup(t, xml)              -- GET_SETUP or variable 1300 text; returns presets found

-- Decisions. ctx = { preset = Default On Brightness, group = bool,
--   last_on = last_on_level or nil, cached = st.brightness or nil }
turnon.turn_on(t, ctx)       --> { level = n, preset_id = n|nil, native = bool }
turnon.while_on(t, ctx)      --> { level = n, preset_id = n|nil }   (D5)
turnon.on_color(t, level, ctx)      --> colour | nil  (D10, D11, D13)
turnon.off_color(t, rate)           --> colour | nil  (D12)
turnon.level_color(t, level, ctx)   --> colour | nil  (D14, D15)
turnon.is_on_color(t, x, y, mode, id, origin) --> bool  (D16)
turnon.color_for_preset(t, id, origin)       --> colour | nil
turnon.is_previous_preset(t, id)             --> bool  (D6)
turnon.off_preset_id(t)                      --> n | nil (D7)
-- Blend state (D14):
turnon.started(t, carried_on_color)  -- a Control4 turn-on went out
turnon.explicit_color(t)             -- an explicit colour went out
turnon.foreign_color(t)              -- a colour change made outside Control4
turnon.ended(t)                      -- the light is off
turnon.blend(dim, on, level, top)    -- D13, exported for the spec
turnon.MODE_PRESET, MODE_PREVIOUS, MODE_FADE = "preset", "previous", "fade"
```

`take_setup` reads every `<level …>` (attributes `name`, `level`, `id` if
present) and every `<color …>` (attributes `name`, `category`, `color_x`,
`color_y`, `color_mode`, `id` if present). Names "On", "Off", "Previous"
(brightness) and "On", "Dim", "Previous" (colour) are matched without case.
Malformed text gives 0 and changes nothing.

`foreign_color` is called by the driver when a `HUE_STATE` reports a colour
while no colour target is pending, and it differs from the colour last
confirmed after a Control4 colour command by more than 0.01 in x or y or 5
mirek.

### 7.5 `src/common/device.lua` additions

- `device.RATE_MAX = 6000000`. `SETTINGS` click and hold `max` = it.
- `dev.take_setting(name, value)`: store and persist a value the proxy
  sent, in range, **without** the confirming notify. Returns true when
  taken.
- `dispatch.proxy["UPDATE_BRIGHTNESS_RATE_DEFAULT"]` and
  `["UPDATE_COLOR_RATE_DEFAULT"]`: `RATE`, 0..`RATE_MAX`, persisted under
  `brightness_rate_default` and `color_rate_default`, loaded in
  `dev.load_settings()`. `dev.rate_default("brightness" | "color")` returns
  it, 0 when never heard. No notify back.
- `dev.rate_caps()` returns `{ brightness_rate_min = 0, brightness_rate_max = RATE_MAX }`.

### 7.6 Persisted keys (per device)

| Key | Owner | Value |
|---|---|---|
| `preset_level` (existing) | device.lua | On preset level, 1–100 |
| `click_rate_up`, `click_rate_down`, `hold_rate_up`, `hold_rate_down` (existing; the scene now also the click ones) | device.lua | 0–6 000 000 |
| `brightness_rate_default`, `color_rate_default` | device.lua | 0–6 000 000 |
| `turnon_brightness` | turnon | `{ id, level }` of the on mode |
| `turnon_color` | turnon | `{ kind, id, origin, x, y, mode, fade_id, fade_origin, fade_x, fade_y, fade_mode }` |
| `turnon_presets` | turnon | `{ on_id, off_id, previous_id, color_on_id, color_dim_id, color_previous_id, on_x, on_y, on_mode, dim_x, dim_y, dim_mode }` |

Flat tables only, as `saved_level` (`driver.lua:973-976`). A "Previous"
brightness level is never persisted (it changes with every off).

### 7.7 Constants (light driver)

`SETUP_READ_MS = 3000`, `HOLD_COLOR_DELAY_MS = 500`,
`HOLD_COLOR_GLIDE_MS = 1000`, `RATE_MAX = device.RATE_MAX`. In turnon:
`MATCH_XY = 0.002`, `FOREIGN_XY = 0.01`, `FOREIGN_MIREK = 5`.

### 7.8 `src/hue_light/light/state.lua` and `caps.lua`

- `state.color_fields(st, x, y, mode)` → `{ mirek = … }` or `{ x =, y = }`
  or nil, plus why: the mapping now inside `from_color_target`.
- `state.from_brightness_target(st, target, rate, opts)`: `opts.color`
  (fields to add when no stored colour wins), `opts.native` (on only, no
  brightness). Returns also which colour went out: `"stored"`, `"given"` or
  nil.
- `state.from_color_target(st, x, y, mode, rate, opts)`: `opts.on_soon`
  sends instead of storing (D17).
- `caps.rate_params()` (§7.2).

## 8. Implementation split

Every part edits only its own files; others edit the rest of the checkout at
the same time; no agent runs git. Every agent reads this file, the
guidelines rows of §6, BP, LV2 caps `_6`, `_7`, `_7.2`–`_7.4`, LV2 cmds
`_20.1`–`_21`, and `docs/tap-stop-design.md`. Lua 5.1, tabs, `.luacheckrc`,
busted with the fake C4 runtime (`tests/helpers/fake_c4.lua`, timers and
`C4:GetTime` included). Comments cite `#429`, `#427`, `#430` with the D
number, and mark DriverWorks claims [verified: …] or [assumed].

| Part | Files it owns | What |
|---|---|---|
| A: turn-on module | `src/hue_light/light/turnon.lua` (new), `tests/spec/light_turnon_spec.lua` (new) | §7.4 complete; D3–D7, D10–D16, D19's parser |
| B: light driver | `src/hue_light/driver.lua`, `src/hue_light/light/state.lua`, `src/hue_light/light/caps.lua`, `tests/spec/light_driver_spec.lua`, `tests/spec/light_state_spec.lua`, `tests/spec/light_caps_spec.lua`, `tests/spec/light_relative_level_spec.lua` (if affected), `tests/spec/zone_light_roundtrip_spec.lua` (if affected) | §4 for the light, built against §7.4's API; §7.2, §7.3, §7.7, §7.8; D17, D19's timer, D20's clamp, D25 |
| C: shared and scene | `src/common/device.lua`, `tests/spec/device_spec.lua`, `src/hue_scene/driver.lua`, `tests/spec/scene_driver_spec.lua` | §7.5; scene: D8, D20 (notify), D21 (`settings` gains `click_up`, `click_down`; the `share` comment), D25 |
| D: documents | `src/hue_light/www/documentation.html`, `src/hue_scene/www/documentation.html`, `src/hue_bridge/www/documentation.html` (only where it describes Default On Brightness, colour on modes or rates), `docs/keypad-design.md`, `docs/lights-design.md`, `docs/zone-light-design.md`, `docs/c4-lighting-guidelines.md`, `docs/composer-checklist.md` | Manuals: On Mode, colours (the light's paragraph on the colour on mode is replaced), rates 0–6 000 000 ms, scene click rates; "Current (date)" notes in the design docs; guidelines rows of §6 and departure D16; the checklist section of §9.2 |
| Coordinator | `src/hue_light/driver.xml`, `src/hue_scene/driver.xml` (§7.1, done first so specs read them), `tests/helpers/fake_c4.lua` (add `SendUIRequest` with a scripted answer and `GetDeviceVariable`, recorded, before agents start), `tests/spec/drivers_spec.lua` if it pins capabilities, `CHANGELOG.md`, `docs/status.md`, `docs/README.md` (index this file), integration, `tools/check.sh`, `tools/build.sh`, commits | |

Part B's specs exercise `turnon.lua` through the driver; until Part A lands
they run against A's file as integrated by the coordinator, so B writes to
the §7.4 API exactly and the coordinator merges A first.

Done for each part: the behaviour of its rows, with specs; `luacheck src
tests tools`, `busted tests` and `python3 tools/lua_limits.py` pass (the
light driver's main chunk has 93 locals today, the scene's 122, limit 180);
Part D also `python3 tools/check_links.py`.

## 9. Tests and house checks

### 9.1 Specs to add

`tests/spec/light_turnon_spec.lua` (A):
- "parses UPDATE_* with underscore and spaced names";
- "an UPDATE_BRIGHTNESS_PRESET for the On preset returns its level";
- "REMOVED of the on mode preset falls back to the On preset";
- "take_setup reads the GET_SETUP sample, with and without ids; junk changes nothing";
- "persists and reloads; a corrupt copy is dropped with a warning";
- "turn_on: Preset at the preset level; unknown id at its level; Previous single from last_on, then cached, then preset; Previous group is native";
- "while_on: Preset gives the mode's level, Previous the On preset";
- "on_color: nil without an On colour, in Previous, without abilities; the On colour at the preset level";
- "blend: the UPDATE_COLOR_PRESET example gives about 3000 K at 40 % (within 20 K)";
- "blend: fade gives Dim at 1, the mix at 50, On at 100; xy for mixed modes; Dim = On gives On";
- "off_color: Dim with a rate, nil at rate 0, nil in Previous";
- "blending: an explicit colour ends Preset, not Fade; the on colour keeps it; foreign ends it; off ends it";
- "color_for_preset finds learned presets by id and origin".

`tests/spec/light_driver_spec.lua` (B), new describes "On Mode (#429)",
"Colour on modes (#427)", "Rate ranges (#430)":
- "ON, TOGGLE, OFF use the default rate after UPDATE_BRIGHTNESS_RATE_DEFAULT; 0 before";
- "a top tap from off in Previous goes to the last reported level";
- "a zone light in Previous sends HUE_SET on without brightness";
- "CHANGING and CHANGED carry preset ids; a slider level clears them";
- "UPDATE_BRIGHTNESS_PRESET for the On preset changes the tap level and sends no PRESET_LEVEL";
- "a turn-on carries the On colour and sends LIGHT_COLOR_CHANGING";
- "a timed off carries the Dim colour; an instant off and a hold do not";
- "a slider move while blending carries the blend; after an explicit colour it does not";
- "a tap stop carries the blend for the estimate";
- "a hold's release sends the blend 500 ms later; a press in between cancels it";
- "SET_COLOR_TARGET with only a preset id uses the learned colour";
- "a colour right after a turn-on goes out (D17)";
- "modes survive a restart (persisted)";
- "GET_SETUP is asked 3 s after late init; a failing call is logged and ignored";
- "rates above 6 000 000 are clamped in HUE_SET";
- "a second DYNAMIC_CAPABILITIES_CHANGED carries the rate ranges";
- "DYNAMIC_ON and DYNAMIC_OFF";
- "a white-only light never sends colour";
- driver.xml: "declares the five on mode capabilities and both maxima; no supports_default_on, ramp_level, on_off, min_max or buttons_are_virtual".

`tests/spec/light_state_spec.lua` and `light_caps_spec.lua` (B):
`color_fields`, `from_brightness_target` with `color` and `native`,
`from_color_target` with `on_soon`, `rate_params`.

`tests/spec/device_spec.lua` (C): "click and hold rates above 6 000 000 are
refused; a persisted 86 400 000 is dropped at load"; "take_setting stores
without a notify"; "rate defaults persist, refuse out of range, default 0".

`tests/spec/scene_driver_spec.lua` (C): "loads and reports the click
rates"; "a tap uses a changed click rate"; "ON, OFF, TOGGLE use the default
rate"; "DYNAMIC_ON recalls, DYNAMIC_OFF turns off"; "sends the rate ranges
at late init and on configure"; driver.xml: "click rates and both maxima,
no deprecated flags".

### 9.2 Text for `docs/composer-checklist.md`

The coordinator pastes this as a new section after M (letter and step
numbers to be set beside the sibling sections; written here as T0–T12).

> ## Turn-on behaviour, colour presets and rate ranges (#429, #427, #430)
>
> From the contract `docs/turn-on-design.md`. This build changes the
> capabilities of `hue_light.c4z` and `hue_scene.c4z`: answer Yes to
> "Restart Director?" for each, then the owner reboots the controller from
> System Manager. The Windows session reads Composer, sets fields and Debug
> Mode and pastes the Lua output (standing approval: no need to ask); the
> owner taps and watches lamps. Each step takes under a minute. Setup: one
> Hue Light device for a single lamp bound to a switch as a 2-button
> keypad, one zone light of two lamps, one Hue Scene device. Debug Mode On
> on the light, the zone light and the scene for these steps, Off at the
> end.
>
> T0. **Before the build (read only).** On the light, the zone light and
> the scene, read the proxy's settings page above "Advanced Properties":
> every field name and value, especially Default On Brightness, any On
> Mode, the colour on mode, the On colour, the Dim colour and its checkbox,
> and any default rate. Paste them.
>
> T1. **Install and reboot.** Install all four files in place; "Restart
> Director?" for the light and the scene drivers: Yes; the owner reboots
> from System Manager. Every Hue device shows the new Driver Version. The
> settings page now shows a brightness On Mode (Preset, Previous) and a
> colour on mode with Preset, Previous and Fade; the scene shows Click Rate
> Up and Down at 3.000. Type 7000 into a hold rate: refused or brought back
> to at most 6000; type 6000: kept. In Programming, the light still offers
> "Ramp to level" with times up to 6000 s. Paste.
>
> T2. **Default On Brightness.** Set it to 60 on the light (Enter). Paste
> the Lua lines (expect `UPDATE_BRIGHTNESS_PRESET` and/or
> `SET_PRESET_LEVEL`). Light off, tap top: 60 %; the CHANGING line shows
> `LIGHT_BRIGHTNESS_TARGET_PRESET_ID=1`. Set it back to 100.
>
> T3. **Previous on a lamp.** Set On Mode to Previous (paste the
> `UPDATE_BRIGHTNESS_ON_MODE` line). Slider to 35 %, tap bottom, tap top:
> back at 35 %. Off again, tap the Navigator tile: 35 %; paste which
> command arrived (`SET_BRIGHTNESS_TARGET` with a preset id, or
> `DYNAMIC_ON`). Light at 35 %, tap top: it goes to the Default On
> Brightness. Set On Mode back to Preset.
>
> T4. **Previous on a zone.** On Mode Previous on the zone light. In the
> Hue app set its lamps to 20 % and 80 %. Turn the zone off from its tile,
> then tap top on its switch: each lamp comes back at its own level (owner
> watching). Set it back to Preset.
>
> T5. **On and Dim colours.** On the light: On colour 2700 K, Dim colour
> 2200 K with its checkbox ticked, colour on mode Preset (paste the
> `UPDATE_COLOR_*` lines). Pick red on the Navigator, turn the light off,
> tap top: it comes on warm white (2700 K) at 100 %. Slider to 50: a little
> warmer. Pick blue: blue; slider to 70: stays blue. Off and on again:
> 2700 K.
>
> T6. **Dim on a fade-out.** Light at 100 %, tap bottom: it fades warmer
> as it goes off over about 3 s; the HUE_SET line carries `mirek`. Paste.
>
> T7. **A hold.** Light at 100 %, hold bottom to about 40 % and let go:
> the colour stays during the hold, then within about 1.5 s glides warmer.
>
> T8. **Fade.** Colour on mode Fade with On 4000 K and Dim 2000 K. Slider
> to 1, 50 and 100: about 2000 K, 3000 K and 4000 K (owner watching; paste
> the HUE_SET lines). Pick red, then slider to 60: back to the fade colour.
>
> T9. **Previous colour.** Colour on mode Previous. Pick red, off, tap top:
> red. Set the colour on mode back to what T0 showed, or to what the owner
> chose (§11 Q1).
>
> T10. **What the driver learned.** After a Director restart, paste the
> light's `GET_SETUP` debug line and the first `UPDATE_COLOR_ON_MODE` line
> seen in T5 or T8.
>
> T11. **Default rate.** If the page shows a brightness default rate, set
> it to 2 s: the tile's turn-on, and "Turn On" in programming, now fade in
> over 2 s. Set it back.
>
> T12. **The scene.** Its tile turns it on as designed (lamps at their
> scene levels). Set its Click Rate Up to 1.000: a top tap fades it in
> over about 1 s. Set it back to 3.000.

## 10. Reboot, existing devices, changelog

**Reboot: yes, one.** The static changes are exactly §7.1: in
`hue_light/driver.xml` five removals and seven additions, in
`hue_scene/driver.xml` four removals, one change and three additions.
Everything else (rate ranges, colour flags, Lua) is dynamic or code.

**An existing device after the update, before the reboot** (new Lua, old
capabilities): Composer shows the old page. Default On Brightness, click
and hold rates and LED colours are the persisted values, as before.
`SET_PRESET_LEVEL` still arrives. With no `UPDATE_*` heard, the light uses
Preset On at its Default On Brightness (unchanged), and the On colour if
`GET_SETUP` gave one. The default rate is 0, so ON and TOGGLE stay instant.

**After the reboot:** Composer shows On Mode and the colour on modes, and
the scene's click rates (3.000, the values used since 1.4). The proxy keeps
its own Default On Brightness; the driver reports its persisted one at late
init as before, so they agree. A persisted click or hold rate above
6 000 000 ms would be dropped to the default with one warning; the house's
are 3000 and 5000. A turn-on now carries the proxy's On colour; until the
dealer sets the On colour, that is the proxy's default (T0 shows it).

**`CHANGELOG.md`, `## Unreleased`:**

```markdown
### Changed
- Hue Light devices (single lights, zone lights and room lights) follow
  Control4's brightness On Mode. Preset, the default, turns the light on at
  its Default On Brightness as before; Previous turns it on at the level it
  had when it went off, and a zone or room light brings every lamp back at
  its own level. Keypad taps, Turn On, Toggle and Navigator tiles all follow
  it, and the Daylight Agent can follow the light's presets (#429).
- Hue Light devices with colour now turn on in Control4's Default On
  Colour, blend toward the Dim colour at low levels, and fade toward the Dim
  colour when they fade off. Colour On Mode Fade gives Control4's warm dim;
  Previous keeps Hue's last colour, as before this release. **Dealers:** set
  each colour light's On and Dim colours and its Colour On Mode in Composer
  after this update; until then a light turns on in the On colour Composer
  shows (#427).
- Ramp times: lights and scenes accept click, hold and ramp rates up to
  6 000 000 ms (100 minutes), the longest Hue takes; Composer and
  programming now offer that range. Turn On, Turn Off and Toggle use the
  proxy's default brightness rate. Hue Scene devices list Click Rate Up and
  Down, the fade time of a keypad tap (#430).
- This update changes the capabilities of the Hue Light and Hue Scene
  drivers: after installing it, reboot the controller from System Manager
  (#429, #427, #430).
```

## 11. Open questions for the owner

Answered by the owner on 2026-11-09: after the reboot the Windows session sets the house's four Hue Light devices to On colour 2700 K, Dim colour off, both On Modes Preset.

1. **Which On and Dim colours, and which modes, for the house's Hue
   lights?** After the reboot every Control4 turn-on of the four Hue Light
   devices uses the On colour, which is the proxy's default until someone
   sets it (T0 shows what that is). Recommended: the Windows session sets,
   right after the reboot, On colour 2700 K with the Dim checkbox off
   (Dim = On), brightness On Mode Preset and colour on mode Preset on each,
   so every turn-on gives the same warm white and nothing else changes.
   Say if you want warm dim (Fade, for example On 2700 K, Dim 2200 K) or
   Previous (today's colour behaviour) on some of them instead.

Decided here without asking, with reasons in §3: Hue Scene devices get no
On Mode (D1); the minimum OS stays 3.3.0 while the deprecated flags go
(D22); fade mode follows its own Control4 page (D14).
