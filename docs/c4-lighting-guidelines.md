# Control4 lighting guidelines: the checklist and the audit

Owner, 2026-11-08 (#422): any work on lighting (lights, zone and room
lights, scenes, keypads and their LEDs, tiles) should behave the way
Control4's own dimmers and keypads do. It should also follow Control4's
published guidance for function and UI. This file is the checklist that
rule points to (`CLAUDE.md`, "Control4 lighting guidelines"). Every row
paraphrases one guideline, cites where it comes from, and says how the
four drivers stand against it today (audit of 2026-11-08, `main` at
dd37b15: release 1.3, build 539, plus later tooling and docs).

## Contents

- [1. How to use this file](#1-how-to-use-this-file)
- [2. Sources and short names](#2-sources-and-short-names)
- [3. The checklist](#3-the-checklist)
- [4. Gaps and partials, ranked](#4-gaps-and-partials-ranked)
- [5. Departures forced by Hue](#5-departures-forced-by-hue)
- [6. Where the written docs and the controller disagree](#6-where-the-written-docs-and-the-controller-disagree)
- [7. Open questions for the owner](#7-open-questions-for-the-owner)

## 1. How to use this file

**In a feature contract.** Every lighting contract under `docs/` has a
section headed "Control4 guidelines". It lists the row ids the feature
touches, for example "L44, L15, L16: met as follows …". For each row it
says one of three things:

- how the feature meets the row;
- that the feature leaves the row's status unchanged;
- that the feature departs from the row. A departure is allowed only where
  Hue cannot do what Control4 expects. It names the reason, which is a
  section 5 entry or a new one added there.

A brief for a lighting agent names the rows that apply and tells the agent
to read this file and the sources in section 2.

**Keeping it current.**

- The PR that changes a row's status updates that row's status, evidence and
  note in the same PR.
- New rows take the next free number at the end of their area. Ids are
  never reused or renumbered, so contracts that cite them stay valid. A row
  that no longer applies stays, marked "Not applicable" with the reason.
- When Snap One updates the SDK reference under `~/c4-tools/reference/`
  (for example a new "What's New" entry), re-read the light_v2 sections and
  add rows for new guidance.
- Hardware findings move a row from [assumed] to [verified: …], with the
  date and where they are recorded (`docs/status.md`, `docs/design.md` or
  the issue).

**Status values.**

- **Meets**: the drivers do what the guideline asks.
- **Partial**: they do some of it, or do it in code but it has never been
  exercised on the house.
- **Gap**: they do not do it, and Hue would allow it.
- **Hue cannot**: Hue offers no way to do it; section 5 has the reason.
- **Not applicable**: the guideline does not fit these devices.

**Evidence tags.** [verified: …] means code (`file:line`), a spec, or a
hardware record. [assumed] means neither has shown it yet.
Current (2026-11-13, #478): a `file:line` is the line at the audit's commit
(dd37b15) or at the change that last rewrote the row; the code has moved
since, so look a line up by the function or name the row gives with it.

**Drivers column.**

- `light`: `hue_light` on a single Hue light.
- `zone`: `hue_light` on a Hue zone's or room's grouped_light.
- `scene`: `hue_scene`.
- `bridge`: `hue_bridge`.
- `motion`: `hue_motion`.

## 2. Sources and short names

These are local copies of the Snap One DriverWorks SDK reference, cloned on
2026-10-22. They are for reading only and are never copied into this
repository. Snap One publishes the same pages at
<https://snap-one.github.io/docs-driverworks-proxyprotocol-lightv2/>,
<https://snap-one.github.io/docs-driverworks-fundamentals/> and their
siblings.

| Short name | Path or URL |
|---|---|
| BP | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md` (cited with its section title) |
| EX | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_51-LIGHTV2EXTRAS.md` |
| LV2 | `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/`. Sub-folders: **caps** `5_light_v2_capabilities/`, **cmds** `10_light_v2_commands/`, **notif** `35_Light_v2_protocol_notifications.5_Light_v2_protocol_notifications/`, **vars** `30_Light_v2_variables/`, **events** `25_light_v2_events/`, **cond** `20_light_V2_conditionals.5_light_V2_conditionals/`, **als** `45_Light_V2_advanced_lighting_scene/`, **new** `3_whats_new/` |
| KP | `~/c4-tools/reference/docs-driverworks-proxyprotocol-keypad/source/includes/` |
| UIB | `~/c4-tools/reference/docs-driverworks-proxyprotocol-uibutton/source/includes/` |
| FUND | `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/` |
| XML | `~/c4-tools/reference/docs-driverworks-xml/source/includes/` |
| C4-DIM | <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerhe_userguide/device_settings_for_dimmers.htm> (dimmer settings: click and hold rates, preset, range levels, LEDs, 2-button keypad) |
| C4-LIGHTING | <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/configuring_lighting.htm> (double- and triple-tap events) |
| C4-KEYPAD | <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/device_settings_for_configurable.htm> (keypad LED behaviour) |
| C4-ALS | <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/example_use_the_advanced_lighting.htm> (Advanced Lighting scenes: tracking, toggle scene, rates, hold rates) |
| C4-COLOR | <https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/using_the_color_agent.htm> (colour presets) |
| C4-USER-SW | <https://docs.control4.com/help/c4/user/userguide/content/topics/lighting/switches-keypads.htm> (how a homeowner uses dimmers: tap, hold, tap again to stop) |
| C4-USER-MENU | <https://docs.control4.com/help/c4/user/userguide/content/topics/lighting/lighting_menu.htm> (Lighting menu: Lights and Scenes views) |

The Control4 pages were read on 2026-11-08. None of them states default
click or hold rates. Control4's documentation does not give the
double-tap window more precisely than about half a second (C4-LIGHTING).

## 3. The checklist

### 3.1 Brightness and ramps

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L1 | Use the brightness target API: declare `supports_target` and take `SET_BRIGHTNESS_TARGET` with a target and a rate. Snap One requires it for certification from OS 3.3.0. | BP "Brightness Target API"; LV2 caps `_4-SUPPORTSTARGET`; LV2 cmds `_1.5-SETBRIGHTNESSTARGET` | light, zone, scene | Meets | [verified: `src/hue_light/driver.xml:155`, `src/hue_scene/driver.xml:128`, `src/hue_light/driver.lua:933`; hardware 2026-10-21, a Navigator slider move arrives as `SET_BRIGHTNESS_TARGET`, `docs/design.md` "Lights: verified on hardware"] | |
| L2 | A dimmer reports a transition with `LIGHT_BRIGHTNESS_CHANGING` (current, target, rate) when it starts and `LIGHT_BRIGHTNESS_CHANGED` where it ends. It never sends `LIGHT_LEVEL` or a stream of in-between levels. | BP "Brightness Target API"; LV2 notif `_10.2-LIGHTBRIGHTNESSCHANGED`, `_10.3-LIGHTBRIGHTNESSCHANGING`, `_12-LIGHTLEVEL` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:444`; no `LIGHT_LEVEL` anywhere under `src/`] | |
| L3 | When the end of a ramp is unknown (a held button), CHANGING names the end of the range as the target. When the ramp stops, CHANGED reports where it stopped. | BP "Brightness Target API"; LV2 notif `_10.3-LIGHTBRIGHTNESSCHANGING` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:1048`, `:1105`; `src/hue_scene/driver.lua:1252`, `:1340`; hardware 2026-10-25, a lamp held for about 3 s of a 10 s ramp stopped near 46 % (#249)] | The level after a tap's stop is part of #421. Current (2026-11-13, #478): settled by #421 (`docs/tap-stop-design.md` D10): the stop's estimate goes out as CHANGED at once, and the bridge's next report corrects it. |
| L4 | Every CHANGING is closed by a CHANGED, including when the command cannot be delivered. Otherwise a tile keeps animating. | BP "Brightness Target API" (UIs animate from CHANGING) | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:359` (fallback after the ramp plus 1 s), `:463-467` (send failure)] | The fallback reports the target as reached even when the bridge is away; see L87. Current (2026-11-09, #428): a command the bridge fails to deliver is answered with the bridge's cached state (`reason = "undelivered"`), which closes the CHANGING with that state, or with the CHANGING's start level when the bridge has none (`docs/offline-design.md` D8, D9); an offline device sends no CHANGING (D5); the fallback stays for a bridge that says nothing (D10, departure D17). |
| L5 | Report the real brightness when the driver starts and whenever the device comes online. | LV2 notif `_10.2-LIGHTBRIGHTNESSCHANGED` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:619` (configure: capabilities, colour, brightness, online); the bridge resyncs and sends full state after every stream connect, `docs/design.md` "Lights"] | Current (2026-11-13, #505): a Hue Scene that is on after a reload showed 100 until the bridge reported; it now shows the last level the bridge reported (saved once settled), so the start reports the real brightness as far as the driver knows it (`src/hue_scene/driver.lua` `shown_level`, `save_level`; specs in `tests/spec/scene_driver_spec.lua`, "#505"). |
| L6 | Changes made outside Control4 (Hue app, Hue switches, Hue automations) reach the proxy promptly, so programming and tiles stay true. | LV2 notif `_10.2-LIGHTBRIGHTNESSCHANGED`; LV2 events `_0-HEADER` | light, zone, scene | Meets | [verified: hardware 2026-10-25, a change in Hue reached zone, room and scene devices within a second, `docs/status.md` "Verified on hardware"] | Hue reports no transition target, so only CHANGED (D3). |
| L7 | Do not flood the proxy with intermediate levels during a ramp. Snap One lists the costs: slow UIs, wrong scene tracking, wrong LEDs, programming fired too often. | BP "Brightness Target API"; LV2 notif `_12-LIGHTLEVEL` usage note | light, zone | Meets | [verified: `src/hue_light/light/throttle.lua` passes a light's Hue-side level reports on at most once a second, the first at once and the last one exact (`LEVEL_REPORT_MS` = 1000, #433 D12, D15); `src/hue_light/driver.lua` wires it in at `report_brightness`, `changing()` and `HUE_STATE`: an on or off edge, a report that settles a Control4 target and a `hello`, `resync` or `import` state go out at once, every CHANGING closes the window (D13) and every CHANGED records its level (D14); specs `tests/spec/light_throttle_spec.lua` and `tests/spec/light_driver_spec.lua` ("Hue-side level reports reach the proxy at most once a second, the last one exact", "a zone light's level reports are throttled the same way"); the scene device throttles the same way (`src/hue_scene/driver.lua` `LEVEL_REPORT_MS`)] [assumed until `docs/composer-checklist.md` steps 138 and 139: on the house] | #433, `docs/light-events-design.md` D12 to D16. A Hue dimmer switch held in the Hue system still reaches Control4 as steps, now at most one a second (D14). Colour reports are not throttled (contract D16, owner 2026-11-09). Until #433 (audit of 2026-11-08) this row was Partial: each Hue event became one CHANGED on a light device, up to about two a second. |
| L8 | Send brightness in the proxy's range and resolution. | LV2 cmds `_1.5-SETBRIGHTNESSTARGET` (resolution); LV2 notif `_10.2-LIGHTBRIGHTNESSCHANGED` | light, zone, scene | Meets | [verified: `src/hue_light/light/state.lua:217`; hardware 2026-10-21, a decimal level showed as 0 % on OS 3.4.2, so whole percents are sent] | Departs from the documented double type (section 6). |
| L9 | A light that is on never reads as off: the Light State variable means "not at the Off preset". | LV2 vars `_0-HEADER` (Light State); LV2 cond `_0-HEADER` (`IS_ON`, `IS_OFF`) | light, zone, scene | Meets | [verified: `src/hue_light/light/state.lua:224`, at least 1 while on] | Hue's lowest level reads 1 (D5). Current (2026-11-12, #469): a Hue Scene's "load" is its scene, never its room's lamps: while another scene lights the room this scene's tile reads 0, as an inactive Advanced Lighting scene does (L64), and that is not a departure; while its own scene is on it never reads 0 (`docs/scene-tracking-design.md` D1, D2) [assumed until `docs/composer-checklist.md` steps 142 and 144]. |
| L10 | Declare click and hold rate minimums and maximums correctly. Since OS 3.3.0, Composer, programming, Advanced Lighting Scenes and UIs enforce them, and programming takes its ramp range from them. | BP "Enforcing min/max Capabilities"; LV2 caps `_12-CLICKRATEMIN`, `_13-CLICKRATEMAX`, `_15-HOLDRATEMIN`, `_16-HOLDRATEMAX` | light, zone, scene | Meets | [verified: `src/hue_light/driver.xml:153-157` and `src/hue_scene/driver.xml:123-128` declare `click_rate_min` 0, `click_rate_max` 6000000, `hold_rate_min` 1000 and `hold_rate_max` 6000000; `src/common/device.lua` refuses rates above `device.RATE_MAX` (6 000 000) and drops a persisted 86 400 000 at load, specs in `tests/spec/device_spec.lua` ("rate ranges, default rates and take_setting"); hardware 2026-11-09, Composer accepted 3.000 s click rates on the four Hue Light devices, `docs/status.md`] [assumed until `docs/composer-checklist.md` step 105 (T1): Composer and programming offer exactly this range] | #430, `docs/turn-on-design.md` D20, D21. Static, so the install needs a controller reboot. The scene lists its click rates since the same change. 6 000 000 ms is the Hue duration ceiling the repo already uses for scenes and groups [assumed for a light]. |
| L11 | Declare `brightness_rate_min` and `brightness_rate_max`. Voice, Navigators and customer-made scenes use them; Snap One asks every colour light driver to set them. | LV2 caps `_1-BRIGHTNESSRATEMAX`, `_1.5-BRIGHTNESSRATEMIN` | light, zone | Meets | [verified: `src/hue_light/light/caps.lua` `caps.rate_params()` goes in a second `DYNAMIC_CAPABILITIES_CHANGED` right after the colour one on every `HUE_CONFIGURE`; the scene sends `dev.rate_caps()` at late init and on configure; specs in `tests/spec/light_caps_spec.lua`, `tests/spec/light_driver_spec.lua` ("Rate ranges (#430)") and `tests/spec/scene_driver_spec.lua` ("rates and turn-on (#430)")] [assumed: the proxy takes 6 000 000, above the "0-INT16 MAX" one SDK page prints] | #430 D20. A notify of its own, so a proxy that refused the value would keep the colour flags (F23 of the turn-on contract). |
| L12 | `supports_brightness_stop` means a ramp can be stopped where it is (`SET_BRIGHTNESS_STOP`). This is for scene ramps, the Daylight Agent and the proxy's Brightness Stop link. | LV2 caps `_29-SUPPORTSBRIGHTNESSSTOP`; LV2 cmds `_21.5-SET_BRIGHTNESS_STOP`; LV2 als `_1.3-REDUCEDALSSUPPORT` | light, zone, scene | Meets | [verified: `SET_BRIGHTNESS_STOP` and `STOP_SCENE_RAMP` stop a ramp the driver runs at Hue, as a keypad tap's stop does (#421 D7): a Hue Light writes its estimate with a 1 s glide (`src/hue_light/driver.lua` `stop_ramp`, `STOP_MODE` "level", `STOP_GLIDE_MS`), a Hue Scene sends the grouped_light `dimming_delta` stop (`src/hue_scene/driver.lua` `stop_ramp`, S-D3); with no ramp running the proxy hears the cached level; hardware 2026-11-09, the stops of `docs/tap-stop-design.md` §10 (L2, Z2, S2)] [assumed: the Brightness Stop link sends `SET_BRIGHTNESS_STOP`] | A transition started outside Control4 (the Hue app) keeps running (D4). Until #421 (audit of 2026-11-08) this row was Partial: the proxy heard the cached level, but nothing went to Hue. |
| L13 | Brightness and colour commands sent back to back both take effect. Neither overrides the other; debounce or queue them into one change. | BP "Handling Consecutive Brightness and Color commands" | light, zone | Meets | [verified: the bridge's 80 ms coalescer makes one PUT, `docs/design.md` "Lights"; hardware 2026-10-25, a colour set while off went out as one grouped_light PUT, `docs/status.md`] | |
| L14 | A hold rate is the time for the whole range (off to full, or full to off), at that speed from any level. | LV2 notif `_9-HOLDRATEDOWN`, `_10-HOLDRATEUP`; C4-DIM "Hold Ramp Rates" | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:1048`; hardware on a single light, #249] | Zones and scenes: per lamp or in steps (D1). Lamp tests of 1.3 are pending (`docs/status.md` "Not yet checked on the house"). |
| L15 | A tap moves the light over the click rate. The dealer page says Ramp Up is the time to reach the Preset Level; the protocol says the full range. | C4-DIM "Click Rates"; LV2 notif `_4-CLICKRATEDOWN`, `_5-CLICKRATEUP` | light, zone | Meets | [verified: a click rate is the time of the whole range, and a tap's ramp takes the rate's share of the distance it moves (`src/hue_light/driver.lua` `tap`, `dev.on_click`; `docs/tap-stop-design.md` D3)] | #421 chose the protocol's reading; the dealer page's (the time to reach the preset) is not followed. Until #421 (audit of 2026-11-08) this row was Partial: the click rate was the duration of whatever distance the tap moved. |
| L16 | Default rates feel like a Control4 dimmer: a tap's ramp is slow enough to catch with a second tap. | C4-USER-SW; C4-DIM | light, zone | Meets | [verified: defaults are 3000 ms click and 5000 ms hold, each for the whole range (`src/common/device.lua` `SETTINGS`); hardware 2026-11-09, a keypad test on a zone light passed, `docs/status.md` (1.4)] | Control4's own defaults are not published [assumed]; #421 D3 chose 3 s. Until #421 (audit of 2026-11-08) this row was Partial: the click default was 250 ms. |

### 3.2 On/off and presets

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L17 | The top tap, ON and turn-on from a tile go to the On preset (Default On Brightness), whatever the current level, even from a higher one. | LV2 vars `_0-HEADER` (Default On Preset Brightness); LV2 cmds `_6-SET_PRESET_LEVEL`, `_7-TOGGLE` | light, zone | Meets | [verified: `src/hue_light/driver.lua:987`, `:993`, `:1013`; 1.3, #233] | The tile's path is [assumed] (L22). Since #429 (`docs/turn-on-design.md` D5) this is On Mode Preset, the default; in Previous the top tap from off goes to the previous level, and while on to the On preset. |
| L18 | The bottom tap turns the light off over Click Rate Down. The toggle button's tap goes the other way from the state shown. | C4-DIM "Click Rates"; C4-USER-SW | light, zone | Meets | [verified: `src/hue_light/driver.lua:1013`; hardware 2026-10-22, taps through a light's Button Links, `docs/status.md`] | Scene taps fade over the click rates since 1.4 (#421), listed in Composer since #430 (`docs/turn-on-design.md` D21). With colour, a timed turn-off carries the Dim colour (L33). |
| L19 | TOGGLE from off activates the On preset; from on it turns off. | LV2 cmds `_7-TOGGLE` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:987`; `src/hue_scene/driver.lua:1174` toggles from where a pending recall is heading] | Current (2026-11-12, #469): a scene's TOGGLE follows its tile, the scene alone: on a scene that is not active it plays the scene, also in a room another scene lights; on the active one it turns the room or zone off (`docs/scene-tracking-design.md` D1, D4) [assumed until `docs/composer-checklist.md` step 142]. Until #469, with the default On State Follows, TOGGLE turned a lit room off. |
| L20 | Use the brightness On Mode capabilities (`brightness_on_mode_preset`, `brightness_on_mode_previous`) instead of the deprecated `supports_default_on`, never both. Handle `UPDATE_BRIGHTNESS_ON_MODE` and `UPDATE_BRIGHTNESS_PRESET`, so turn-ons the driver starts itself (keypad links) honour the mode. | LV2 caps `_32-SUPPORTSDEFAULTON`, `_6-brightnessonmodepreset`, `_7-brightnessonmodeprevious`; LV2 cmds `_20.1-UPDATEBRIGHTNESSONMODE`, `_20.3-UPDATEBRIGHTNESSPREST`; LV2 new `_10-WHATSNEWIN332` | light, zone | Meets | [verified: `src/hue_light/driver.xml:158-159` declare `brightness_on_mode_preset` and `brightness_on_mode_previous`, and no `supports_default_on`; `src/hue_light/light/turnon.lua` (`update_brightness_on_mode`, `update_brightness_preset`, `turn_on`, `while_on`) decides ON, TOGGLE, `DYNAMIC_ON` and keypad turn-ons; specs `tests/spec/light_turnon_spec.lua` and "On Mode (#429)" in `tests/spec/light_driver_spec.lua`] [assumed until `docs/composer-checklist.md` steps 106 to 108 (T2 to T4): the `UPDATE_*` parameters as they arrive, and a zone's Previous turn-on bringing each lamp back at its own level] | #429, `docs/turn-on-design.md` D2 to D6. Static: one controller reboot with L34 and L85. `SET_PRESET_LEVEL` is still handled. Hue Scene devices get no On Mode (D1): a scene's on is its own look. |
| L21 | Name presets in CHANGING and CHANGED (`LIGHT_BRIGHTNESS_CURRENT_PRESET_ID`, `..._TARGET_PRESET_ID`), so the proxy can follow a light when a preset's level changes. The Daylight Agent needs this. | LV2 notif `_10.2-LIGHTBRIGHTNESSCHANGED`, `_10.3-LIGHTBRIGHTNESSCHANGING` | light, zone | Meets | [verified: CHANGING carries `LIGHT_BRIGHTNESS_TARGET_PRESET_ID`, CHANGING and CHANGED `LIGHT_BRIGHTNESS_CURRENT_PRESET_ID` while the light sits at the preset (`src/hue_light/driver.lua`, `turnon.off_preset_id`); specs in `tests/spec/light_driver_spec.lua` ("On Mode (#429)")] [assumed: the Daylight Agent following a light; the house has none to test] | #429 D7. Only learned ids and On = 1 are ever sent. |
| L22 | From OS 3.3.2, Navigators turn lights on and off with `DYNAMIC_ON` / `DYNAMIC_OFF`. A driver without dynamic on gets the On brightness preset. | LV2 cmds `_1.3-DYNAMICON`, `_1.2-DYNAMICOFF` | light, zone, scene | Partial | [verified: `DYNAMIC_ON` and `DYNAMIC_OFF` are handled since #429 D25, specs in `tests/spec/light_driver_spec.lua` and `tests/spec/scene_driver_spec.lua` ("rates and turn-on (#430)"); `ON`, `TOGGLE` and `SET_BRIGHTNESS_TARGET` are handled too] [assumed: which command a tile's tap arrives as has not been seen on the house; `docs/composer-checklist.md` step 107 (T3) logs it] | #431 verifies. |
| L23 | The proxy keeps a default brightness rate for generic on/off, Navigators and customer scenes, and tells the driver with `UPDATE_BRIGHTNESS_RATE_DEFAULT`. | LV2 cmds `_21.3-SETBRIGHTNESSRATEDEFAULT`, `_20.2-UPDATEBRIGHTNESSRATEDEFAULT` | light, zone | Meets | [verified: `src/common/device.lua` stores and persists `UPDATE_BRIGHTNESS_RATE_DEFAULT` and `UPDATE_COLOR_RATE_DEFAULT` (`dev.rate_default`), and ON, OFF, TOGGLE, `DYNAMIC_ON`, `DYNAMIC_OFF` and a target without `RATE` use the brightness default on light and scene; specs in `tests/spec/device_spec.lua` ("rate ranges, default rates and take_setting"), `tests/spec/light_driver_spec.lua` ("Rate ranges (#430)") and `tests/spec/scene_driver_spec.lua` ("rates and turn-on (#430)")] [assumed until `docs/composer-checklist.md` step 115 (T11): Composer shows the default rate and the proxy sends it] | #430 D8. 0 until the proxy sends one, so ON and TOGGLE stay instant as before; keypad taps keep the click rates. |
| L24 | After a `SET_PRESET_LEVEL` or a `SET_*_RATE_*`, the driver tells the proxy the value it accepted. Composer then shows the value in use. | LV2 cmds `_22-SETCLICKRATEUP`, `_23-SETCLICKRATEDOWN`; LV2 notif `_16-PRESETLEVEL`, `_4-CLICKRATEDOWN`, `_5-CLICKRATEUP`, `_9-HOLDRATEDOWN`, `_10-HOLDRATEUP` | light, zone, scene | Meets | [verified: `src/common/device.lua:499`; hardware 2026-10-25, Composer rounds 41 and 42, #59] | Sent as a bare value (section 6). |
| L25 | A setting outside its range is refused, never stored: a preset of 0 would make "on" turn the light off. | BP "Enforcing min/max Capabilities" | light, zone, scene | Meets | [verified: `src/common/device.lua` refuses a preset outside 1 to 100 and a rate outside 0 to 6 000 000 ms (`device.RATE_MAX`, #430 D20), and drops a persisted value out of range at load] | |
| L26 | Control4 dimmers offer Min On and Max On trims and cold start. The proxy hears them from hardware that supports them. | C4-DIM "Range Levels"; LV2 notif `_13-MAXON`, `_14-MINON`; LV2 caps `_8-COLDSTART` | light, zone | Hue cannot | [verified: `cold_start` and `min_max` False, `src/hue_light/driver.xml:147`, `:153`] | No trim in CLIP v2; cold start means nothing for LED lamps (D13). Emulating Max On by scaling is possible but not planned. |

### 3.3 Colour and colour temperature

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L27 | Switch `supports_color` and `supports_color_correlated_temperature` on per bulb. Send both in one `DYNAMIC_CAPABILITIES_CHANGED`, then report the current colour straight away. | LV2 caps `_30-SUPPORTSCOLOR`, `_31-SUPPORTSCOLORCORRELATEDTEMPERATURE` (usage notes) | light, zone | Meets | [verified: `src/hue_light/light/caps.lua:24`, `src/hue_light/driver.lua:619-620`] | |
| L28 | The colour temperature range is in Kelvin, in multiples of 10, within 500 to 20 000. A fixed white has min equal to max. | LV2 notif `_8-DYNAMICCAPABILITIESCHANGED` | light, zone | Meets | [verified: `src/hue_light/light/caps.lua:14-39`; a zone uses its lamps' common range (#58)] | |
| L29 | Take `SET_COLOR_TARGET` (xy and a mode; a temperature arrives as its xy with mode 1). Answer with `LIGHT_COLOR_CHANGING`, then `LIGHT_COLOR_CHANGED`. | LV2 cmds `_9.6-SET_COLOR_TARGET`; LV2 notif `_10.5-LIGHTCOLORCHANGED`, `_10.7-LIGHTCOLORCHANGING` | light, zone | Meets | [verified: `src/hue_light/driver.lua:479`; hardware 2026-10-22, Navigator colour and temperature picks, `docs/composer-checklist.md` D.10] | |
| L30 | Report the colour at start and when the device comes online, with mode 1 while the lamp is in colour temperature. | LV2 notif `_10.5-LIGHTCOLORCHANGED` | light, zone | Meets | [verified: `src/hue_light/light/state.lua:237`; `src/hue_light/driver.lua:619`] | |
| L31 | A colour set while the light is off does not turn it on. The driver keeps it and applies it at the next turn-on from Control4. | BP "Setting Color while the Light is Off" | light, zone | Meets | [verified: `src/hue_light/light/state.lua:298`; hardware 2026-10-25 on a zone light, `docs/status.md`] | Order-proof since #427 D17: a colour that follows a Control4 turn-on before Hue reports the light on is sent, not stored (`tests/spec/light_driver_spec.lua`, "Colour on modes (#427)"). A colour set while off wins over the On colour at the next turn-on (D11). |
| L32 | Every colour light has a Default On Colour, applied whenever the light turns on (a target from off, a tap, a hold). Customers then get the same turn-on colour across brands. | BP "Default On and Dim Colors"; LV2 cmds `_21-UPDATECOLORPRESET` | light, zone | Meets | [verified: `src/hue_light/driver.xml:160-162`; `turnon.on_color` puts the On colour, blended for the level (turn-on D13), into every Control4 turn-on's `HUE_SET` with a `LIGHT_COLOR_CHANGING`; the colours are learned from `UPDATE_COLOR_PRESET`, from `GET_SETUP` 3 s after late init and from persisted copies (turn-on D19); specs in `tests/spec/light_turnon_spec.lua` and `tests/spec/light_driver_spec.lua` ("Colour on modes (#427)")] [assumed until `docs/composer-checklist.md` steps 109 and 114 (T5, T10): the parameters as they arrive, and what `GET_SETUP` answers] | #427 D10, D11. Colour on mode Previous, a white-only bulb and an unknown On colour send none. A turn-on from Hue (app, switch, automation) is never corrected. The owner chose On 2700 K, Dim off and both modes Preset for the house (turn-on contract §11). |
| L33 | The Default Dim Colour is used while turning off, but not during an open-ended hold down. Until a colour is chosen after turn-on, the colour blends from Dim at 1 % to On at the Default On Brightness and above. | BP "Default On and Dim Colors"; LV2 cmds `_21-UPDATECOLORPRESET` | light, zone | Meets | [verified: `turnon.off_color`: a turn-off with a rate above 0 carries the Dim colour, an instant off and a hold do not; `turnon.level_color` blends from Dim to On on every Control4 target while blending (turn-on D13 to D15); after a hold the blend follows 500 ms after the release, over 1 s; specs in `tests/spec/light_turnon_spec.lua` (the blend gives about 3000 K at 40 % for the SDK's own example) and `tests/spec/light_driver_spec.lua` ("Colour on modes (#427)")] [assumed until `docs/composer-checklist.md` steps 110 and 111 (T6, T7)] | #427 D12 to D15. Departure D16 (section 5): no Dim colour with an instant off. During a hold the colour follows at the release (D12). |
| L34 | Colour On Modes (preset, previous, fade) come with `color_on_mode_*` and `UPDATE_COLOR_ON_MODE`. Composer shows the setting on every colour light. | LV2 caps `_7.2-coloronmodefade`, `_7.3-coloronmodepreset`, `_7.4-coloronmode previous`; LV2 cmds `_20.4-UPDATECOLORONMODE`, `_9.1-SET_COLOR_ON_MODE` | light, zone | Meets | [verified: `src/hue_light/driver.xml:160-162` declare `color_on_mode_preset`, `color_on_mode_previous` and `color_on_mode_fade`; `turnon.update_color_on_mode` and `turnon.update_color_preset` handle and persist them; specs in `tests/spec/light_turnon_spec.lua` (both spellings of every parameter)] [assumed until `docs/composer-checklist.md` step 114 (T10): how `UPDATE_COLOR_ON_MODE` tells the three modes apart] | #427 D9. Static: the same reboot as L20. The light's manual describes the three modes and asks dealers to set the On and Dim colours. |
| L35 | Warm dim: colour temperature follows brightness in a straight line, from a warm value at 1 % to a cool one at 100 %, and only on brightness changes. Any explicit colour ends it until the next off and on. | BP "Warm Dim" (described for a Philips Hue driver); LV2 caps `_7.2-coloronmodefade` | light, zone (colour temperature bulbs) | Meets | [verified: with colour on mode Fade every Control4 brightness target while on carries `turnon.blend` from Dim at 1 % to On at 100 %, linear in Kelvin between two colour temperatures; an explicit colour holds until the next target; specs in `tests/spec/light_turnon_spec.lua` and `tests/spec/light_driver_spec.lua` ("Colour on modes (#427)")] [assumed until `docs/composer-checklist.md` step 112 (T8)] | #427 D13, D14. Control4's own warm dim is the Fade mode, so there is no Extras switch (D23, L60). During a hold the colour follows at the release (D12). |
| L36 | Declare `color_rate_behavior`, `color_rate_min` and `color_rate_max`. Snap One asks every colour light driver to set them. | LV2 caps `_8.6-COLORRATEBEHAVIOR`, `_8.7-COLORRATEMAX`, `_8.8-COLORRATEMIN` | light, zone | Meets | [verified: `caps.rate_params()` sends `color_rate_behavior` 1, `color_rate_min` 0 and `color_rate_max` 6000000 in the rate notify of L11; specs in `tests/spec/light_caps_spec.lua`] | #430 D20. Hue applies one duration per request (D9), so 1. Dynamic, so no reboot is needed for it. |
| L37 | Set `color_trace_tolerance` to absorb the device's rounding, so `IS_COLOR` and scene tracking match. | LV2 caps `_13.5-COLORTRACETOLERANCE` | light, zone | Partial | [verified: not declared, `docs/design.md` "Color mapping"] | Not declared (#427 D24): a value that helps on 3.3.1 and later would match every colour on 3.3.0, the declared minimum, where the tolerance is an xy distance. Hue rounds temperature to whole mirek and moves xy into the bulb's gamut (D8). #431 verifies scene tracking. |
| L38 | `SET_COLOR_STOP` stops a colour ramp where it is. | LV2 cmds `_9.2-SET_COLOR_STOP`, `_9.4-SET_COLOR_STOP` | light, zone | Partial | [verified: `src/hue_light/driver.lua:966` answers with the cached colour; nothing goes to Hue] | Hue keeps transitioning (D4). |
| L39 | Users are offered only the colour presets the device can show; the Color agent filters by capabilities. | C4-COLOR | light, zone | Meets | [assumed: UI behaviour follows the declared capabilities, L27] | |

### 3.4 Keypad taps, holds and multi-taps

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L40 | Keypad buttons reach the light through Top, Bottom and Toggle Button Links (`DO_PUSH`, `DO_CLICK`, `DO_RELEASE`) and through the proxy's `BUTTON_ACTION`. The proxy route is echoed back. | LV2 cmds `_1-BUTTONACTION`; LV2 notif `_1-BUTTONACTION`; KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` | light, zone, scene | Meets | [verified: `src/common/device.lua:700-722`; hardware 2026-10-22, `docs/keypad-design.md` "Hardware findings"] | The driver declares the links itself (section 6). |
| L41 | Every push the proxy hears is followed by a release; otherwise later presses stop working. | LV2 notif `_1-BUTTONACTION` | light, zone, scene | Meets | [verified: `src/common/device.lua:705` echoes each action as received] | Current (2026-11-10, #432 D4, E9): the proxy now hears Button Link pushes too, and each is followed by exactly one release, also after a lost `DO_RELEASE` and at `OnDriverDestroyed` (`src/common/device.lua` `notify_release`, `cancel_timers`; `tests/spec/device_spec.lua` "a push while the button is still down notifies the missing release first", "cancel_timers drops an open sequence and releases a button still down"). |
| L42 | A hold ramps up (top) or down (bottom) at the hold rate and stops where it is released. | C4-USER-SW; C4-DIM "Hold Ramp Rates" | light, zone, scene | Meets | [verified: a single light, #249; zones and scenes in code, `docs/group-hold-design.md`] | Group holds go per lamp or in steps (D1). |
| L43 | Holding top while off ramps up from off. Holding bottom while off does nothing. | C4-DIM "Hold Ramp Rates"; C4-USER-SW | light, zone, scene | Meets | [verified: `src/common/device.lua:617`; hardware 2026-10-25, a hold from off on a zone light, `docs/status.md`] | Starts at 1 % and dims up 600 ms later. |
| L44 | A tap while the light is ramping stops it at the level it has reached. | C4-USER-SW (stopping a ramp) | light, zone, scene | Meets | [verified: while a ramp runs, a press outside the 600 ms double-tap window on any button stops it on the push and its click is swallowed (`src/common/device.lua` `dev.ramp_active`, `dev.on_ramp_stop`; `src/hue_light/driver.lua` and `src/hue_scene/driver.lua` `stop_ramp`); hardware 2026-11-09, a keypad test on a zone light passed and scene taps work, `docs/status.md` (1.4)] | #421, `docs/tap-stop-design.md` D5, D6, S-D4. A time-based scene's tap stays instant, with nothing to stop (S-D5). Until #421 (audit of 2026-11-08) this row was a Gap: a second tap started the same ramp again. |
| L45 | Double and triple taps are their own events: taps in quick succession, about half a second in all. Press and Release fire during them too. | C4-LIGHTING | light, zone, scene | Partial | [verified: no click counting and no `CLICK_COUNT`; each Button Link click is a tap] | A double tap on a bound button reaches the light as two taps [assumed]. The keypad's own double-tap events stay on the keypad. #421 settles the window. Current (2026-11-10, #432 D6, D8): the light's own Double and Triple Tap events now fire for taps within the 600 ms window, with Press and Release during them (L46); what a tap does to the light is unchanged (tap-stop D4). |
| L46 | The light's own button events (press, release, single, double and triple tap on Top, Bottom and Toggle) appear in programming only if they fire. They depend on `has_button_events`, `multi_click` (OS 3.4.2+) and `CLICK_COUNT`. | LV2 caps `_26-HASBUTTONEVENTS`, `_28.5-multiclick`; LV2 notif `_3-CLICKCOUNT`; LV2 events `_0-HEADER` | light, zone, scene | Partial | [verified: `src/hue_light/driver.xml:167-168` and `src/hue_scene/driver.xml:133-134` declare `has_button_events` and `multi_click` True; `src/common/device.lua` notifies `BUTTON_ACTION` for Button Link presses as the proxy route echoes them (`notify_press`, `notify_release`), counts taps per button in the `DOUBLE_TAP_MS` window (`count_tap`, `uncount_tap`) and sends `CLICK_COUNT` when a sequence closes (`close_taps`, `device.BUTTON_EVENTS_MODE` `"count"`); specs in `tests/spec/device_spec.lua` ("a Button Link press notifies BUTTON_ACTION 1, its click 2, a hold's release 0", "a double tap sends CLICK_COUNT 2 once, and the second tap still changes nothing", "the proxy route echoes as before and sends the same CLICK_COUNT")] [assumed until `docs/composer-checklist.md` steps 133 to 136: Composer lists the 15 events and the proxy fires them; step 134 settles `BUTTON_EVENTS_MODE`] | #432, `docs/light-events-design.md` D2 to D10. Moves to Meets once step 134 shows the events fire; the capabilities ship either way (D10). Presses on Hue's own switches never fire them (departure D19, which retires D15). Until #432 (audit of 2026-11-08) neither capability was declared and `BUTTON_ACTION` was echoed only on the proxy route, never for Button Link presses. Current (2026-11-13, #478): on 2026-11-10 (dev build 604) Programming listed the light's 15 events and the proxy route fired Top Push and Top Release; the owner skipped the tap counting of step 134, so the row stays Partial (`docs/status.md`). |
| L47 | A release can arrive late or not at all, which risks a runaway ramp; act so a lost release does no harm. | KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md` (`DO_RELEASE`) | light, zone, scene | Meets | [verified: a hold asks Hue for at most the rest of the range at the hold rate, `src/hue_light/driver.lua:1048`] | |
| L48 | The toggle button: a tap toggles; a hold ramps toward the other state (up while off, down while on). | LV2 cmds `_1-BUTTONACTION` (button 2, toggle) | light, zone, scene | Meets | [verified: `src/common/device.lua:617`] [assumed: matches a Control4 dimmer's toggle] | |

### 3.5 Keypad LEDs and button colours

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L49 | LEDs of bound buttons follow the device: `MATCH_LED_STATE` on each link and `BUTTON_INFO` with the current colour to the proxy. A newly bound keypad gets the state at once, and `REQUEST_BUTTON_COLORS` is answered. | KP `62_keypad_button_link_bindings/_1-KEYPADBUTTONLINKBINDINGS.md`; LV2 notif `_2-BUTTONINFO`; C4-KEYPAD and C4-DIM "Follow Bound Device" | light, zone, scene | Meets | [verified: `src/common/device.lua:464`, `:476`, `:725`; hardware 2026-10-24 on a scene; binding a link sets the button's LED behaviour to follow the connection (#312)] | On a single light the same code is [assumed]. Current (2026-11-12, #469): on a scene the LEDs follow the keypad's own state, which Keypad Follows chooses, and that state can differ from the tile's (departure D20; `docs/scene-tracking-design.md` D9) [assumed until `docs/composer-checklist.md` steps 144 and 147]. |
| L50 | Default colours are Control4's: top and toggle lit blue while on, bottom lit while off. | LV2 cmds `_16.5-GETSETUP` (sample) | light, zone, scene | Meets | [verified: `src/common/device.lua:79`] | |
| L51 | Declare `has_leds`, so Composer offers LED colours. `SET_BUTTON_COLOR` is stored per button, persisted, and echoed back. | LV2 caps `_28-HASLEDS`; LV2 cmds `_12-SET_BUTTON_COLOR` | light, zone, scene | Meets | [verified: `src/common/device.lua:736`; hardware 2026-10-25, the settings page after the reboot, #59] | |
| L52 | `SET_ALL_LED` sets every button, on and off, to one colour. | LV2 cmds `_13-SET_ALL_LED` | light, zone, scene | Meets | [verified: `src/common/device.lua` `dispatch.proxy["SET_ALL_LED"]` sets the six colours, persists them under `button_<n>_on_color` and `button_<n>_off_color`, and sends `BUTTON_COLORS` on links 200 to 202, `BUTTON_INFO` per button and `MATCH_LED_STATE`; a `COLOR` that is not 6-digit hex changes nothing and resends the colours kept; specs in `tests/spec/device_spec.lua` ("SET_ALL_LED sets every button's on and off colour, persists them and tells the links and the proxy", "SET_ALL_LED with a colour that is not 6-digit hex changes nothing and reports the colours kept", "a later SET_BUTTON_COLOR overrides one colour SET_ALL_LED set")] [assumed until `docs/composer-checklist.md` step 137: on the house] | #432 D11. Lua only, so no reboot. Until #432 (audit of 2026-11-08) this row was a Gap: no handler. |
| L53 | LEDs show the real state, including changes made in the Hue app. | C4-DIM "LEDs Follow Load" | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:286` updates the LEDs with every report] | |
| L54 | Keypad backlight and ambient light profiles. | C4-DIM "Advanced Properties"; C4-KEYPAD | (keypad) | Not applicable | | The keypad's own driver handles these. |

### 3.6 Tiles and Navigator UI

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L55 | A tile's slider animates from CHANGING and settles on CHANGED. Slider moves stick at the level chosen. | BP "Brightness Target API" | light, zone, scene | Meets | [verified: hardware 2026-10-21, once whole percents were sent, slider moves to 25, 60, 100 and off stuck; hardware 2026-10-24, a scene tile's slider in the iPhone app, `docs/design.md`] | |
| L56 | An offline device's tile is disabled. The proxy assumes online at start, so the driver must report. | LV2 notif `_15-ONLINECHANGED` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:241`, `:309`] A bridge outage (#428, `docs/offline-design.md` D1, D4, D5, D12): `src/hue_bridge/bridge/link.lua` sends `HUE_BRIDGE_LINK` offline to every device after `OFFLINE_AFTER_S` = 300 s of bridge trouble, online at the first contact, and first in every hello answer, so the proxy's start-up "online" is corrected; `src/common/device.lua` keeps it and the light and scene drivers' `blocker()` reports `ONLINE_CHANGED` false; specs `tests/spec/link_spec.lua`, `device_spec.lua`, `light_driver_spec.lua`, `scene_driver_spec.lua`, `offline_roundtrip_spec.lua` [assumed until `docs/composer-checklist.md` step 120: the tiles grey on the house] | Current (2026-11-09, #428): a bridge outage counts too; after 5 minutes every Hue device reports offline, and back at the bridge's first answer (L87). Current (2026-11-13, #478): seen on the house on 2026-11-10 with the offline time set to 30 s (dev build 604): all seven Hue devices went offline and came back 3 s after the bridge answered (`docs/status.md`). |
| L57 | The colour wheel and the temperature control match what the bulb can do. | LV2 caps `_30-SUPPORTSCOLOR`, `_31-SUPPORTSCOLORCORRELATEDTEMPERATURE` | light, zone | Meets | [verified: hardware 2026-10-24/25, zone light picks, `docs/status.md`] | A zone shows the union of its lamps. |
| L58 | Lighting lives in the Lighting menu as light_v2 devices. The UI Button proxy is for experience menus (Listen, Watch, Security, Comfort). | UIB `103_ui_button_proxy_overview/_1-UIBUTTONPROXYOVERVIEW.md`; C4-USER-MENU | light, zone, scene | Meets | [verified: every lighting driver uses light_v2, `src/hue_scene/driver.xml:107`] | Current (2026-11-12, #469): the bridge adds or links a scene device only in the Control4 room its Hue room or zone maps to, so the scene's tile sits on the Lighting page of the room whose lamps it moves. A drag in Composer stays free and the device keeps working there, marked on its line; no departure (`docs/scene-tracking-design.md` Part 2, S6) [assumed until `docs/composer-checklist.md` steps 149 to 154]. |
| L59 | Scenes belong in the Lighting menu's Scenes view, which lists Advanced Lighting scenes. | C4-USER-MENU | scene | Partial | [verified: a Hue Scene device is a light_v2 dimmer, so it is listed among Lights with a slider] | No documented DriverWorks API adds a driver's scene to that list [assumed]; no issue is proposed. |
| L60 | Device features that the proxy does not know go on the Extras tab (`has_extras`, `EXTRAS_SETUP_CHANGED`, `EXTRAS_STATE_CHANGED`). Hide items rather than removing them. | EX | light, zone, scene | Not applicable | | Nothing to show today. Warm dim is Control4's colour on mode Fade since #427 (`docs/turn-on-design.md` D23), so it needs no Extras switch. Snap One's Extras library cannot be vendored, so anything here would be our own code. |
| L61 | Device icons are 16 and 32 px at 96 DPI. A light_v2 List View tile is Control4's own. | FUND `19_driver_icon_management/_1-DRIVERICONMANAGEMENT.md` | all | Meets | [verified: the light and scene PNGs are 16/32 px at 96 DPI (checked 2026-11-08); the List View tile is Composer's own, #60] | |

### 3.7 Scenes

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L62 | Join Advanced Lighting Scenes with `reduced_als_support`, not full ALS. Scenes then drive the device with targets and end ramps with the stops. | LV2 caps `22-REDUCEDALSSUPPORT`; LV2 als `_1.3-REDUCEDALSSUPPORT` | light, zone, scene | Meets | [verified: `src/hue_light/driver.xml:164`, `src/hue_scene/driver.xml:137`; handlers at `src/hue_light/driver.lua:933-973`] | |
| L63 | Check that a held scene ramp button works with the device, and that the stops behave. | LV2 caps `22-REDUCEDALSSUPPORT` | light, zone, scene | Partial | [assumed: Advanced Lighting Scenes have never been exercised on the house; no record in `docs/status.md` or `docs/design.md`] | |
| L64 | A scene's on state and LEDs track like an Advanced Lighting scene's: either "any load on" or "this scene active". | C4-ALS "Tracking" | scene | Meets | [verified: hardware 2026-10-24, LEDs follow the scene; On State Follows since build 400, `docs/scene-led-design.md`] Current (2026-11-12, #469): the tile, its level and the proxy's events track "this scene active" always; a bound keypad tracks what Keypad Follows names, "any load on" (`Room/zone lights`) by default or "this scene active" (`This scene`) (`docs/scene-tracking-design.md` O1, D1, D9 to D13) [assumed until `docs/composer-checklist.md` steps 141 to 147] | Each surface meets one of the two tracking modes. One device with two states is departure D20, the owner's exception (2026-11-12); `This scene` gives it one state. Until #469 the tile and the keypad shared one state, by default "any load on". |
| L65 | Holding a scene's button ramps the scene at its hold rates. | C4-ALS "Hold Rates" | scene | Partial | [verified: code since 1.3, #249; the lamp tests are pending, `docs/status.md` "Not yet checked on the house"] | D1. |
| L66 | A scene's toggle activates its toggle scene; by default that turns it off. | C4-ALS "Toggle scene"; LV2 als `_4.5-TOGGLEESCENE` | scene | Meets | [verified: `src/hue_scene/driver.lua:1174`] | It always turns the room off. Current (2026-11-12, #469): as `_4.5-TOGGLEESCENE` describes, an inactive scene's toggle activates it, also while another scene lights the room, and the active scene's toggle turns its room or zone off (`docs/scene-tracking-design.md` D4) [assumed until `docs/composer-checklist.md` step 142]. |
| L67 | Load groups: `load_group_support`, with `JOIN_GROUP`, `LEAVE_GROUP` and the `GROUP_*` commands handled. | LV2 caps `_23-LOADGROUPSUPPORT`; LV2 cmds `_14-JOIN_GROUP` to `_20-GROUP_STOP_RAMP` | light, zone | Partial | [verified: `src/hue_light/driver.xml` declares `load_group_support` True; `src/hue_light/light/load_group.lua` parses `JOIN_GROUP`, `LEAVE_GROUP`, `SET_GROUP_SYNC` and the four `GROUP_*` commands and keeps the memberships, shown in the read-only Load Groups row; `src/hue_bridge/bridge/load_groups.lua` batches a group's requests and sends one grouped_light request per whole Hue room or zone; specs `tests/spec/light_load_group_spec.lua`, `tests/spec/load_groups_spec.lua`, `tests/spec/light_load_group_driver_spec.lua` and `tests/spec/load_group_roundtrip_spec.lua`] [assumed until `docs/composer-checklist.md` steps 124 to 132 (H0 to H8): how Control4's Load Group delivers its commands, `docs/load-groups-design.md` A1 to A10] | #435, `docs/load-groups-design.md` D1 to D18; question 4 answered. Static: one controller reboot, shared with #429 and #427 in 1.5. Hue Scene devices cannot join (contract D2). Brightness only: no group command carries a colour. Lamps move as one only when they make up whole Hue rooms or zones (section 5, D18). Keep loads in sync is recorded, never acted on (contract D13). Meets after H1 to H6. Current (2026-11-13, #478): H1 passed on 2026-11-10 (Composer offers the four Hue Lights to a Dimmer Load Group, and not the scenes, `docs/status.md`); H2 to H6 have not been run. |

### 3.8 Programming events, conditionals and commands

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L68 | The proxy's events (Light On, Light Off, Brightness Changed and Changing, Colour Changed and Changing) are shown and fire for every change, Hue-side changes included. | LV2 events `_0-HEADER`; LV2 caps `_25-HIDEPROXYEVENTS` | light, zone, scene | Meets | [verified: `hide_proxy_events` False, `src/hue_light/driver.xml:163`; Hue-side changes reach the devices, L6] | Current (2026-11-12, #469): a scene device's Light On and Light Off now mean "became the active scene" and "stopped being it", as an Advanced Lighting scene's Scene Activated and Scene DeActivated do (LV2 als `_3.1-SCENEACTIVATED`, `_3.2-SCENEDEACTIVATED`), Hue-side activations and scenes of overlapping groups included (`docs/scene-tracking-design.md` D1, D7). Programming written against the old default, which followed the room's lamps, changes; `CHANGELOG.md` says so [assumed until `docs/composer-checklist.md` steps 142 to 146]. |
| L69 | "Begins to ramp" events and the `IS_BRIGHTNESS_TARGET` and `IS_COLOR_TARGET` conditionals need CHANGING notifies. | BP "Brightness and Color Changing API"; LV2 cond `_0-HEADER` | light, zone, scene | Meets | [verified: every Control4-initiated change sends CHANGING, L2, L29] | Hue-side changes only get CHANGED (D3). |
| L70 | Device-specific commands keep stable names and parameters. They use ranged types and a sort order, and describe themselves with NAME and PARAM placeholders. | FUND `15_composerpro_interface_into_the_sdk/_7-PROGRAMMING.md`; XML `35_commands_xml/` | light, zone | Meets | [verified: `src/hue_light/driver.xml:94-130`] | |
| L71 | Events are sorted with `sort_order` (OS 3.3.0+), and a driver stays well under 1000 events. | FUND `12.5_Events/_10-SORTINGEVENTSINCOMPOSERPRO.md`; FUND `15_composerpro_interface_into_the_sdk/_7-PROGRAMMING.md` | motion | Meets | [verified: the motion driver's 8 events carry `sort_order` since #434, `src/hue_motion/driver.xml`] | The light and scene drivers have no events of their own. |

### 3.9 Composer properties and dealer UX

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L72 | Show the proxy's own settings (preset, rates, LED colours) as a Control4 dimmer does: `hide_proxy_properties` False. | LV2 caps `_38-HIDEPROXYPROPERTIES`; C4-DIM | light, zone, scene | Meets | [verified: hardware 2026-10-25, #59] | |
| L73 | Information rows are read-only, with Driver Version first. Status texts fit Composer's column. | XML `20_properties/_25-readonly.md`, `_10-property.md` | all | Meets | [verified: every `driver.xml`; texts kept under about 75 characters, `docs/status.md` "Composer properties fit the column"] | |
| L74 | Editable properties carry a tooltip. | XML `20_properties/_30-tooltip.md` | scene, motion, light | Meets | [verified: since #434 Recall As, On State Follows, Occupancy Hold Time and every Debug Mode carry a `<tooltip>`] Current (2026-11-12, #469): [verified: `src/hue_scene/driver.xml` gives Keypad Follows its own `<tooltip>`, and the hidden On State Follows one that says it was replaced] | The renamed property keeps a stored `This scene` through a one-time copy at late init (`docs/scene-tracking-design.md` D12). |
| L75 | Every driver has a Documentation tab, with a changelog in it. | FUND `26_markdown_driver_documentation/_0-Header.md`; FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: `<documentation file=…>` in each `driver.xml`; `tools/build.sh:75-139` renders `CHANGELOG.md`; the tab was seen on the house, `docs/status.md`] | |
| L76 | Actions are for installation and setup, not everyday use. | FUND `15_composerpro_interface_into_the_sdk/_6-ACTIONS.md` | all | Meets | [verified: no actions on light and scene devices since 1.2; 9 on the bridge, `CHANGELOG.md` 1.2]; from 1.5, 10 on the bridge: the tenth, Hue Automations, is setup too, deciding once per Hue automation whether it is switched off, restored or kept, and nothing goes on the light or scene devices (#280, [`hue-automation-audit-design.md`](hue-automation-audit-design.md) §5, D20) | |

### 3.10 Driver updates and persistence

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L77 | Never add, remove or change a proxy in an update; that needs a new driver. | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: one proxy per driver since its first release] | |
| L78 | Connections may only be added, never removed or retyped. | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: hardware 2026-10-22, build 146 added the Button Links in place, `docs/keypad-design.md`] | |
| L79 | Never remove or renumber events, commands or variables. Retype properties with care. | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: fixed motion ids, `docs/motion-design.md` §2.3–2.4; removed device actions answer as hidden aliases until 2.0, `CHANGELOG.md` 1.2] | |
| L80 | Raise `<version>` and the modified date with every build, and keep a changelog. | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: `tools/build.sh:151-171`] | |
| L81 | Keep the Lua engine the same across updates: a change between PUC Lua and LuaJIT loses state for a moment. | FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` | all | Meets | [verified: `jit="1"` in all four `driver.xml`] | |
| L82 | Prefer dynamic capabilities. On OS 3.4.2 a static capability change needs a controller reboot before existing devices take it. | LV2 notif `_8-DYNAMICCAPABILITIESCHANGED`; LV2 new `_6-WhatsNewin421` | light, zone, scene | Meets | [verified: hardware 2026-10-23/24, `docs/keypad-design.md` "Install findings"; colour capabilities are dynamic, `src/hue_light/light/caps.lua`] | Plan each static change and say it needs a reboot. |
| L83 | Per-device settings persist and survive updates and restarts. A bad persisted value is dropped. | FUND `24_persisting_driver_data/_1-PERSISTINGDRIVERDATA.md` | light, zone, scene | Meets | [verified: `src/common/device.lua:517`] | |
| L84 | Declare an explicit minimum OS, and know which capabilities are newer than it. | FUND `14_updating_released_drivers/_1-UPDATINGRELEASEDDRIVERS.md` | all | Meets | [verified: 3.3.0 in every `driver.xml`] | `supports_brightness_stop`, the on modes and `brightness_rate_*` are from 3.3.2, `multi_click` from 3.4.2. Older OS versions ignore them [assumed]; a light then uses On Mode Preset. The minimum stays 3.3.0 (`docs/turn-on-design.md` D22). |
| L85 | Drop deprecated capabilities: `num_buttons`, `ramp_level`, `min_max`, `on_off`, `buttons_are_virtual`, `fixed_ramp_rate`. | LV2 new `_10-WHATSNEWIN332` | light, scene | Meets | [verified: neither `src/hue_light/driver.xml` nor `src/hue_scene/driver.xml` declares `num_buttons`, `ramp_level`, `min_max`, `on_off`, `buttons_are_virtual` or `fixed_ramp_rate` since #429 D22; the driver.xml specs in `tests/spec/light_driver_spec.lua` and `tests/spec/scene_driver_spec.lua`] [assumed until `docs/composer-checklist.md` step 105 (T1): programming still offers ramps] | Removed in the same reboot as L20 and L34. |

### 3.11 Errors and offline

| Id | Guideline | Source | Drivers | Status | Evidence | Note |
|---|---|---|---|---|---|---|
| L86 | `ONLINE_CHANGED` is reported at start and on every change of the device's reachability. | LV2 notif `_15-ONLINECHANGED` | light, zone, scene | Meets | [verified: `src/hue_light/driver.lua:241`, `:309`; unbound, gone, forgotten and Zigbee-unreachable all read Offline] | |
| L87 | While the bridge is unreachable or rejects the key, commands must not look delivered, and devices should show offline after a while. | FUND `23_command_handling_and_dropped_connections/_1-COMMANDHANDLINGANDDROPPEDCONNECTIONS.md`; LV2 notif `_15-ONLINECHANGED` | light, zone, scene | Meets | #428 (`docs/offline-design.md` D1, D2, D5, D7 to D9): `src/hue_bridge/bridge/link.lua` takes every Hue device offline after `OFFLINE_AFTER_S` = 300 s of trouble (no answer, key rejected, not paired, blocked, another bridge) and back at the first contact; `src/hue_bridge/bridge/commands.lua` `on_undelivered` answers every failed PUT through `lights:undelivered`, `zone_lights:undelivered` and `scenes:undelivered_group`, and a failed recall gets `HUE_SCENE_STATE` `undelivered`; the light and scene drivers close their targets with the bridge's state; specs `tests/spec/link_spec.lua`, `commands_spec.lua`, `lights_spec.lua`, `zone_lights_spec.lua`, `scenes_spec.lua`, `light_driver_spec.lua`, `scene_driver_spec.lua`, `offline_roundtrip_spec.lua`; the four manuals say so [assumed until `docs/composer-checklist.md` steps 119 to 122: on the house] | Departure D17: a command sent in the first seconds of an outage, before the bridge driver has noticed it, can show its target for 5 to 15 s until its request times out. Until #428 (audit of 2026-11-08) this row was Partial: lights stayed online through an outage and the tile showed the requested level a second after the ramp. |
| L88 | Status rows say what is wrong and what to do. | XML `20_properties/_25-readonly.md` | all | Meets | [verified: Status, Online and Last Action on devices; Attention on the bridge, `docs/status.md`] | |
| L89 | A command sent while the device cannot be reached is retried for a bounded time, then dropped, not queued forever. | FUND `23_command_handling_and_dropped_connections/_1-COMMANDHANDLINGANDDROPPEDCONNECTIONS.md` | light, zone, scene | Meets | [verified: 30 s retry cap, #43, `docs/design.md` "Lights"] | |

**Totals (89 rows):**

| Status | Rows |
|---|---|
| Meets | 77 |
| Partial | 9 |
| Gap | 0 |
| Hue cannot | 1 |
| Not applicable | 2 |

Current (2026-11-09): recounted after the turn-on contract
(`docs/turn-on-design.md`, #429, #427, #430) moved L10, L11, L20, L21,
L23, L32 to L36 and L85 to Meets. The audit's own counts were Meets 57,
Partial 19, Gap 10; the rows changed since (L71 and L74 by #434) count as
they now stand.
Current (2026-11-09, #428): L87 moved to Meets under
`docs/offline-design.md`, with departure D17.
Current (2026-11-09, #435): L67 moved from Gap to Partial under
`docs/load-groups-design.md`, with departure D18.
Current (2026-11-10, #432, #433): L7 and L52 moved to Meets under
`docs/light-events-design.md`; L46 stays Partial until
`docs/composer-checklist.md` step 134 shows the events fire. Departure D14
now says at most one step a second, D15 is retired and D19 joins section 5.
Current (2026-11-12, #469, [`scene-tracking-design.md`](scene-tracking-design.md)):
no row changes status. L9, L19, L49, L58, L64, L66, L68 and L74 carry
notes for the scene tile that follows its own scene, Keypad Follows and
the scenes kept in their mapped room; D11 is updated and D20, the owner's
exception, joins section 5. L59 is unchanged: no documented route puts a
driver's scene in the Scenes view.
Current (2026-11-13, #478): recounted after bringing in #421 (1.4,
[`tap-stop-design.md`](tap-stop-design.md)), which no update had
recorded: L12, L15 and L16 moved from Partial to Meets and L44 from Gap to
Meets, so no Gap is left. Departure D4 and section 4 item 1 say what
changed.

## 4. Gaps and partials, ranked

These are ranked by how much an owner or dealer would notice. Each has its
own issue, filed with this file (2026-11-08); #421 was filed before it.

1. **#421 (filed): "Keypad taps on Hue lights: a second tap stops the
   ramp, as on a Control4 dimmer".** Rows: L44 (tap again stops), L15
   (click rate: distance or full range), L16 (default rates), L45
   (double-tap window), L46 (the light's own button events), L12 and L38
   (stopping a transition), L3 and L4 (the level reported after a stop).
   Hue limits:
   - a `dimming_delta` stop is verified on a light (#249), but stopping a
     `dimming.brightness` transition with a duration is not;
   - a grouped_light ignores the duration (D1), so a zone needs the per-lamp
     path;
   - group requests run at about 1/s (D2).
   Current (2026-11-13, #478): built in 1.4 under `docs/tap-stop-design.md`
   and checked on the house on 2026-11-09: L12, L15, L16 and L44 meet, and
   L3's stop level is settled (that contract's D10). L38 stays Partial
   (`SET_COLOR_STOP` still only answers), and L45 and L46 went on under
   #432.
2. **#427: "Colour lights: Control4's Default On and Dim colours, colour on modes
   and warm dim".** Rows: L32, L33, L34, L35 (and L60 if warm dim gets a
   Navigator switch). This is the biggest visible difference for a dealer:
   Composer shows On and Dim colours and a colour on mode, but the light
   ignores them and turns on in its last colour.
   - Declare `color_on_mode_preset`, `color_on_mode_previous` and
     `color_on_mode_fade`.
   - Handle `UPDATE_COLOR_PRESET` and `UPDATE_COLOR_ON_MODE`, and learn the
     current presets at start [assumed: through `GET_SETUP`].
   - Send the On colour with every turn-on, and the Dim colour with a
     turn-off that is not a hold.
   - Apply the blend formula on brightness targets until an explicit colour
     arrives.
   Hue limits: none for targets, since colour and level go in one PUT. A
   hold cannot carry a colour curve (D12), so the colour follows at release.
   This is a static capability change, so it needs a reboot. See question 1.
   Current (2026-11-09): built with #429 and #430 under
   `docs/turn-on-design.md`; L32 to L36 meet, L60 stays Not applicable
   (warm dim is the Fade mode, no Extras switch), and departure D16 joins
   section 5.
3. **#428: "Bridge unreachable: show Hue devices offline instead of assuming
   commands landed".** Rows: L87, and L56 for a bridge outage. Today the
   tile shows a command as done a second after its ramp, even with the
   bridge gone, and nothing turns the tiles grey.
   - When the bridge has been unreachable, or has rejected the key, for a
     set time, the bridge tells every device it is offline.
   - While a command cannot be delivered, the device reports the level it
     knows, not the target.
   Hue limits: none. A bridge reboot takes minutes, so the threshold must
   ride it out (question 2).
   Current (2026-11-09): built under `docs/offline-design.md`. After 5
   minutes of bridge trouble every Hue device goes offline, motion devices'
   Online included (D1, D14), and a command the bridge does not take is
   answered with the bridge's state, not shown as done (D8, D9). L87 meets
   with departure D17, and L56 covers a bridge outage.
4. **#429: "Turn-on behaviour: Control4's brightness On Mode (Preset and
   Previous) with preset ids".** Rows: L20, L21, L23, and L85 (drop the
   deprecated capabilities in the same reboot).
   - Replace `supports_default_on` with `brightness_on_mode_preset` and
     `brightness_on_mode_previous`.
   - Handle `UPDATE_BRIGHTNESS_ON_MODE`, `UPDATE_BRIGHTNESS_PRESET` and
     `UPDATE_BRIGHTNESS_RATE_DEFAULT`.
   - Send preset ids in CHANGING and CHANGED, for the Daylight Agent.
   - Have keypad turn-ons honour the mode.
   Hue limits: none; Hue turns on at its previous level natively. This is a
   static capability change, so it needs a reboot. See question 3.
   Current (2026-11-09): built under `docs/turn-on-design.md` (D2 to D8,
   D22); L20, L21, L23 and L85 meet, and L22 stays Partial until #431 logs
   what a tile's tap sends.
5. **#430: "Declare the ramp and rate ranges Control4 enforces".** Rows: L10, L11,
   L36.
   - Add `brightness_rate_min/max`, `color_rate_behavior` 1 and
     `color_rate_min/max` to the configure notify. They are dynamic, so no
     reboot.
   - Declare `click_rate_max` and `hold_rate_max` explicitly, matched to
     what the driver does (holds are capped at 6 000 000 ms). These are
     static.
   - Check on the house which click rates Composer accepts today, since the
     documented `click_rate_max` default is 1 ms.
   Hue limits: one duration per request (D9), with a ceiling assumed at
   6 000 000 ms.
   Current (2026-11-09): Composer accepted 3.000 s click rates on the four
   Hue Light devices (`docs/status.md`); built under
   `docs/turn-on-design.md` D20 and D21, so L10, L11 and L36 meet, and the
   Hue Scene lists its click rates too.
6. **#431: "House check: Advanced Lighting Scenes, the tile's turn-on and colour
   tracking".** Rows: L63, L22, L37. This is verification, not code:
   - put a light, a zone light and a scene device in an Advanced Lighting
     scene;
   - ramp it with a held scene button and stop it;
   - check that the scene's tracking holds after a colour scene;
   - log which command a tile tap arrives as.
   Hue limits: gamut and mirek rounding (D8).
   Current (2026-11-13, #478): #431 was closed on 2026-11-10 by the
   owner's decision to skip the manual tests. The held scene ramps, the
   tracking and the command a tile tap arrives as were not seen, so L22,
   L37 and L63 stay Partial (`docs/status.md`).
7. **#432: "Keypad LEDs: SET_ALL_LED, and the light's own button events".** Rows:
   L52, L46.
   - Handle `SET_ALL_LED`.
   - Either fire the light's button events (echo `BUTTON_ACTION` for
     Button Link presses and send `CLICK_COUNT`) or hide them with
     `multi_click` False on OS 3.4.2+. Decide after #421 settles multi-taps.
   Hue limits: none; the buttons are virtual (D15).
   Current (2026-11-10): built under `docs/light-events-design.md` (D1 to
   D11): Hue Light and Hue Scene devices declare `has_button_events` and
   `multi_click`, notify Button Link presses as the proxy route's echo,
   count taps and send `CLICK_COUNT`, and handle `SET_ALL_LED`. L52 meets;
   L46 stays Partial until checklist step 134. D15 is retired; D19 keeps
   Hue's own switches out.
8. **#433: "Throttle Hue-side level reports on light devices as on scene
   devices".** Row: L7. Coalesce `HUE_STATE` level reports to at most one
   a second while Hue ramps, as `src/hue_scene/driver.lua` does. Hue limits:
   no transition target (D3).
   Current (2026-11-10): built under `docs/light-events-design.md` D12 to
   D16 (`src/hue_light/light/throttle.lua`). L7 meets, and D14 now says at
   most one step a second.
9. **#434: "Composer polish: tooltips on editable rows and motion event order".**
   Rows: L74, L71. Add `<tooltip>` to Recall As, On State Follows,
   Occupancy Hold Time and Debug Mode. Give the motion events `sort_order`
   values; this is an XML-only change and their ids stay. Hue limits: none.
   Current (2026-11-13, #478): built in 1.5; L71 and L74 meet.

Partials and gaps with no new issue proposed:

- L59: no documented route puts a driver's scene in the Scenes view.
- L65 and L14 (group holds): these lamp checks are already listed in
  `docs/status.md` "Not yet checked on the house".
- L67 (load groups): question 4 answered (Hue lights join load groups);
  built under #435, `docs/load-groups-design.md`, and Partial until the
  house checks H1 to H6.

## 5. Departures forced by Hue

| Id | Departure | Reason (Hue) | Rows |
|---|---|---|---|
| D1 | Holds on zones, rooms and scenes ramp lamp by lamp (up to 10 lit) or in one-second steps, not as one group ramp. | A grouped_light ignores `dynamics.duration` on `dimming_delta` and covers the whole change in about a second (#249, `docs/group-hold-design.md`). | L14, L42, L65 |
| D2 | Zone and room commands are paced at about one a second, after a burst of three; a fast slider drag goes out as one request a second. | Hue's guidance for grouped_light is about one request a second; lights take about ten (`docs/design.md` "Commands and rate limiting"). | L13, L55 |
| D3 | Changes made in Hue reach Control4 as CHANGED only, so "begins to ramp" events and the target conditionals never fire for them. | Hue's event stream reports where a light is, never where it is going. | L6, L7, L68, L69 |
| D4 | `SET_BRIGHTNESS_STOP` and `SET_COLOR_STOP` answer with the cached value; the lamp finishes its transition. | CLIP v2 has no verified stop for an absolute transition. A `dimming_delta` stop is verified on a light only (#249); #421 is testing more. Current (2026-11-13, #478): since #421 (1.4) `SET_BRIGHTNESS_STOP` stops a ramp the driver runs at Hue (L12, `docs/tap-stop-design.md` §10); a transition started outside Control4, and `SET_COLOR_STOP`, still get the cached value. | L12, L38 |
| D5 | Level 1 means the bulb's lowest level, and a lit lamp never reads 0. | Hue's `min_dim_level` is fixed per bulb, and some bulbs report less than 0.5 %. | L9 |
| D6 | Levels are reported as whole percents. | Hue reports its Zigbee level as a decimal (20 comes back as 20.16), which the OS 3.4.2 proxy showed as off (section 6). | L8 |
| D7 | A zone light's colour on the tile is its first lit lamp's, and its level is the average of the lit lamps. | Hue reports no colour for a grouped_light. | L57 |
| D8 | The colour reported can differ slightly from the colour asked for. | Hue moves xy into the bulb's gamut and stores colour temperature in whole mirek. | L37, L63 |
| D9 | Colour and brightness share one transition time. | A CLIP v2 request has one `dynamics.duration`. | L36 |
| D10 | A bulb without Zigbee connectivity (Matter or Wi-Fi) shows Online as blank, never Offline. | Its reachability is not reported in `zigbee_connectivity` (`docs/edge-cases-hue.md`). | L86 |
| D11 | A Hue scene is recalled whole, optionally at a level. There are no per-step paths, no flash, and an on state of its own. Current (2026-11-12, #469): the on state is the tile's, held from any activation until the room or zone goes off, another scene of it or of a group that shares a lamp becomes active, or the device turns it off; a bound keypad has a state of its own (D20). | Hue scenes are recalled as a unit. Their "active" status ends when any member light changes, so the device follows its on rule and On State Follows (`docs/scene-dimmer-design.md`, `docs/scene-led-design.md`). Current (2026-11-12, #469): the tile follows the on rule alone; On State Follows is now Keypad Follows and chooses only the keypad's state (`docs/scene-tracking-design.md` D1, D2, D7, D9). | L59, L64 |
| D12 | Warm dim (colour on mode Fade) and the Preset blend follow brightness on targets only; during a hold the colour follows 500 ms after the release, over 1 s (#427, `docs/turn-on-design.md` D15). | A `dimming_delta` changes brightness only and carries no colour curve. | L35, L33 |
| D13 | No Min On, Max On or cold start. | CLIP v2 has no trim or warm-up settings, and the lamps are LED. | L26 |
| D14 | A Hue-side ramp (a Hue dimmer switch held) appears in Control4 as steps; since #433 (2026-11-10, `docs/light-events-design.md` D12) at most one a second, the last one exact. | The bridge sends at most about two event containers a second (#65), and Hue reports where a light is, never where it is going (D3), so there is no ramp to report. | L7 |
| D15 | Retired (2026-11-10, #432). Was: the light device's own buttons are virtual; button events belong to the keypad that is pressed. Since #432 a light's and a scene's own button events fire for every press that reaches them, from a bound keypad or the proxy (`docs/light-events-design.md` D3); what stays forced by Hue is D19. | Hue lamps have no buttons. | L46 |
| D16 | The Dim colour goes only with a turn-off that has a fade time, not with an instant off (#427, `docs/turn-on-design.md` D12). | Hue keeps an off lamp's colour and shows it at the next Hue-side turn-on. An instant off would show nothing and only change what a Hue switch later turns on in. | L33 |
| D17 | A command sent in the first seconds of a bridge outage, before the bridge driver has noticed it, can show its target for 5 to 15 s, until its request times out; then the tile goes back to the bridge's state (#428, `docs/offline-design.md` D10). | Hue acknowledges a command only by answering the PUT and by its event, which a dead bridge cannot send. The fallback that closes every CHANGING when Hue sends no event for an unchanged value (L4) cannot tell the two apart until the request fails (5 s connect, 15 s total timeout). | L87, L4 |
| D18 | A Control4 load group moves its loads as one. Hue lamps in a load group move as one only where they make up whole Hue rooms or zones (a zone or room light in the group always moves its lamps as one). Other lamps get one request each, one after another: a ramp hides most of it, and an instant change shows up to about 0.4 s across 10 lamps and about 1.3 s across 20. Holds go lamp by lamp, as in D1. | Director sends one request at a time to the bridge, and CLIP v2 has no request for an arbitrary set of lamps: only a room's or zone's grouped_light moves several lamps in one request (#435, `docs/load-groups-design.md` D8, D9 and §2.4). | L67 |
| D19 | Presses on Hue's own switches (a Hue dimmer switch, a tap dial) never fire a Hue Light's or Hue Scene's button events; what such a switch does reaches Control4 only as on, off and level reports (#432, `docs/light-events-design.md` E16). | A Hue switch acts on the lamps through the Hue bridge's own configuration, and the bridge reports what the lamps do, not which switch moved them. A Hue switch as a Control4 keypad would be a feature of its own. | L46 |
| D20 | A Hue Scene device has two on states. Its tile, level and proxy events track "this scene active"; a keypad bound to it tracks what Keypad Follows names, by default `Room/zone lights` ("any load on": the scene, or any lamp of its room or zone, on). An Advanced Lighting scene has one tracking state for its LEDs and its state (#469, `docs/scene-tracking-design.md` O1, D9 to D12). | Not forced by Hue: Hue could give either. The owner's exception of 2026-11-12 (#469): the tile must show which scene plays, so that several scene devices of one room do not all read on, and a wall switch on a scene keeps showing whether the room is lit, the wish of #310. Keypad Follows = `This scene` gives the device one state again. | L64, L49 |

Current (2026-11-12, #469): D20 is the first departure that Hue does not
force. It is the owner's exception to section 1's rule that a departure
needs a reason in Hue, and it stands here so that every departure stays in
one table.

## 6. Where the written docs and the controller disagree

On the house (OS 3.4.2), the controller's behaviour won over the written
reference in these places. A contract that cites the rows above should not
"fix" them back.

- **Button Links.** The reference has the proxy create the Top, Bottom and
  Toggle links. In practice the driver declares them (ids 200 to 202) and
  receives `DO_PUSH`, `DO_CLICK` and `DO_RELEASE` on them [verified:
  2026-10-22, `docs/keypad-design.md` "Hardware findings"].
- **Setting confirmations.** `PRESET_LEVEL`, `CLICK_RATE_*` and
  `HOLD_RATE_*` are documented with table parameters. The proxy reads a
  table as 0, and takes the bare value [verified: #59, Composer rounds 41
  and 42].
- **Brightness type.** `LIGHT_BRIGHTNESS_CURRENT` is documented as a
  double, but a decimal showed as 0 % [verified: 2026-10-21, `docs/design.md`
  "Lights: verified on hardware"].
- **Colour parameter names.** `SET_COLOR_TARGET` arrives as
  `LIGHT_COLOR_TARGET_X`, `_Y`, `_MODE` and `RATE` [verified: 2026-10-22,
  `docs/composer-checklist.md` D.10].
- **Capability changes.** "Restart Director?" answered Yes does not load
  changed capabilities; a controller reboot does [verified: 2026-10-23/24,
  `docs/keypad-design.md` "Install findings"].

## 7. Open questions for the owner

1. **Default On colour for existing lights (item 2, #427).** Today a light turns
   on in its last colour. Control4's way turns every light on in its
   Default On Colour, which also overrides a colour last set in the Hue
   app. That fits "Control4 is the source of truth". Is that wanted, and
   what should happen to lights whose On colour nobody has set in Composer?
   Recommended: follow Control4 from that release, and say in the changelog
   that dealers should set the On and Dim colours.
   Answered (owner, 2026-11-09, #427): follow Control4, built under
   `docs/turn-on-design.md`; the changelog tells dealers to set the On and
   Dim colours, and after the reboot the house's Hue Light devices get On
   2700 K, Dim off and both On Modes Preset (that contract's §11).
2. **When the bridge is unreachable (item 3, #428), after how long should Hue
   devices go offline?** Offline greys their tiles and stops keypad
   control. Options:
   - at once when the event stream drops;
   - after 5 minutes, when the bridge already starts looking for a moved
     bridge (recommended, because a bridge reboot takes minutes);
   - only after an hour, when Attention reports the bridge missing.
   Answered (owner, 2026-11-09, #428): after 5 minutes, the recommended
   option, and a Hue Motion Sensor's Online with them; built under
   `docs/offline-design.md` (D1, D14).
3. **On Mode Previous (item 4, #429).** Offer Control4's "Previous" (turn on at
   the last level) next to Preset? It needs a controller reboot and
   replaces the deprecated capability. Existing devices would stay on
   Preset, today's behaviour, unless changed.
   Answered (owner, 2026-11-09, #429): yes, with #427 and #430 in one
   reboot (`docs/turn-on-design.md`).
4. **Load groups (L67, #435).** Should Hue lights join Control4 load groups? The
   alternative is pointing dealers to zone and room lights, which drive a
   Hue group with one request. Recommended: zone and room lights only.
   Answered (owner, 2026-11-09, #435): yes, "hue lights should join c4 load
   groups, so they can be used in lighting automation c4". Single lights,
   zone lights and room lights join; Hue Scene devices do not. Built under
   `docs/load-groups-design.md`: one grouped_light request per whole Hue
   room or zone is on by default, and the bridge never passes "keep loads
   in sync" on (its §10); departure D18 joins section 5.
