# Slimming review: the two device drivers (2026-10-24)

Area: `src/hue_light/driver.lua` with `src/hue_light/light/state.lua` and
`caps.lua`, `src/hue_scene/driver.lua`, and `src/common/dispatch.lua` and
`log.lua` as they use them. Safety net: `tests/spec/light_driver_spec.lua`,
`light_state_spec.lua`, `light_caps_spec.lua`, `scene_driver_spec.lua`,
`scene_roundtrip_spec.lua`, `zone_light_roundtrip_spec.lua`,
`dispatch_spec.lua`. Contracts read: `docs/keypad-design.md`,
`docs/scene-dimmer-design.md`, `docs/smart-scenes-design.md`,
`docs/zone-light-design.md`; present state `docs/status.md`; hardening
`docs/code-analysis-2026-10-22.md`. Brief: `docs/reviews/slim-2026-10-24-brief.md`.
Nothing was run against the controller or the bridge; no file but this one
was written.

## 1. Summary

This area is 3,591 lines today (light driver 1,301; `light/state.lua` 313;
`light/caps.lua` 43; scene driver 1,809; `common/dispatch.lua` 76;
`common/log.lua` 49), 2,559 of them code, the rest comments and blank lines.
The two drivers grew in parallel from the same template, and 616 lines of
the light driver (535 non-blank, 51 runs of four lines or more) appear
byte-for-byte in the scene driver; 684 once the driver name and the
`light`/`scene` words are normalised (measured with a longest-common-run
script over the two files, exact match after trailing-whitespace strip).
The proposals below save about 12 lines at low risk (a dead handler, a dead
return value, two guards) and about 415 at medium risk (the dev-only log
forwarding moved into the dev-only module, −80; a shared
`src/common/device.lua` for the keypad, LED, binding, late-init and version
plumbing, −230 for the byte-identical blocks and −105 more for the button
state machine), 425 lines in all, 12 % of the area and 2.5 % of the 17,500
the brief counts. Runtime: the device drivers are not where the controller's
CPU goes (every hot path is on the bridge, and a device does a handful of
table operations per message around one `SendToProxy`), so the wins are
small: (1) `notify()` builds, sorts and concatenates a parameter dump for a
debug line on **every** proxy notification, with Debug Mode Off, the default;
guarding it with `log.enabled("debug")` removes one table, one string per
parameter, a sort and a concat from every `LIGHT_BRIGHTNESS_CHANGED`,
`CHANGING`, `LIGHT_COLOR_*`, `ONLINE_CHANGED` and `BUTTON_ACTION` echo; (2)
about 210 lines of dev-only code (the dev-loop preamble, the log-forwarding
sink, `DEV_RELOAD`, `HUE_DUMP`) are compiled into every release device and
guarded only at run time; moving the sink into `common/devloop.lua`, which
release builds do not ship, and registering `DEV_RELOAD` only when the loop
is present, makes them vanish from the house; (3) nothing else per event is
worth touching (the `apply_hue` before/after comparison in `state.lua` costs
two small tables and up to two `C4:ColorCCTtoXY` calls per `HUE_STATE`, and
a spec pins why it is done that way). Memory in this area is fixed-size state;
nothing grows for the life of a device except the pre-late-init buffer, which
is emptied at late init.

## 2. Proposals, ranked by benefit ÷ risk

| # | File and lines | What to change | Lines saved | Runtime effect | Risk | Specs | Security |
|---|---|---|---|---|---|---|---|
| 1 | `src/hue_scene/driver.lua:1270-1281` | Delete the `HUE_DUMP` handler. No code sends it: `grep HUE_DUMP` over `src/`, `tools/` and `tests/` finds only this handler; the docs mention it (`docs/scenes-design.md:64-65` lists it under dev builds, `docs/design.md:697-704` records its single use, ad-hoc Lua through the dev loop while settling Composer's Set button, a closed question). A release bridge has no Lua window (`tools/build.sh:21-23`, `--allowexecute` only with `--dev`) and drops `Proxy Command` (`src/hue_bridge/driver.lua:1785-1792`), so in release nothing can reach it; it exists only as surface. Alternative if the dev diagnostic is wanted: register it inside `if devloop then … end`, the bridge's own pattern at `driver.lua:1785`, net +1 line. | −12 | none (one closure fewer) | **low**: unreachable in release, no caller in dev tooling either | none reference it (grep of `tests/`); nothing to add | **improves**: closes the open item in `docs/status.md:175-178` and `docs/code-analysis-2026-10-22.md:100-102` (item 10); the dump writes every Property and the device's state to the log at `log.always` level whatever Debug Mode says |
| 2 | `src/hue_light/driver.lua:145-151`, `src/hue_scene/driver.lua:198-204` | In `notify()`, build the sorted `k=v` dump only when `log.enabled("debug")` (`src/common/log.lua:99-101`): wrap lines 146-149 (light) / 199-202 (scene) in that test. The debug line's text is unchanged when Debug Mode is On. | 0 (+2 each) | **per proxy notification**: with Debug Mode Off (default, `hue_light/driver.xml:34`, `hue_scene/driver.xml:34`) saves one table, `#params` strings (`k .. "=" .. tostring(v)`, two concats and a `tostring` each), `table.sort` and `table.concat` on every `LIGHT_BRIGHTNESS_CHANGED`/`CHANGING`, `LIGHT_COLOR_CHANGED`/`CHANGING`, `ONLINE_CHANGED`, `DYNAMIC_CAPABILITIES_CHANGED` and `BUTTON_ACTION` echo; for a lit light this is once per bridge event that reaches the device, for a scene once per group level report (already throttled to 1/s, `hue_scene/driver.lua:530-564`) | **low**: no behaviour, only when the work is done; no spec asserts the `-> proxy` line (grep of `tests/` for `-> proxy`: none) | every proxy notification spec (light 639-690, 713-869, 1221-1291; scene 396-438, 439-604, 1419-1517, 1518-1827) runs through `notify()` and pins its output unchanged | none |
| 3 | `src/hue_light/driver.lua:77-139` and `784-802`; `src/hue_scene/driver.lua:130-192` and `1283-1302`; `src/common/devloop.lua` | (a) Register `DEV_RELOAD` only `if devloop then` and drop the `not (devloop and devloop.apply_forwarded)` guard (light 785-787, scene 1285-1287): release builds then have no `DEV_RELOAD` command (dispatch logs "no command handler" at debug, `common/dispatch.lua:23-25`, instead of today's warning). (b) Move the log-forwarding sink, 63 identical lines in each driver (the only difference is the local's name, `pending` at light 89 vs `waiting` at scene 142), into `common/devloop.lua` as `devloop.forward_logs(prefix, get_bridge, get_rid)` returning the `flush` function; the drivers keep `local flush_log = devloop and devloop.forward_logs(LOG_PREFIX, function() return bridge end, function() return st.rid end) or function() end`. `tools/build.sh:46-49` deletes `common/devloop.lua` from release stages, so the moved code is no longer compiled on the house. | (a) −2 (b) −126 in the drivers, +~45 in `devloop.lua` (dev builds only): **−80 net**, about 120 lines fewer compiled per release device | per startup only: a release device compiles ~60 lines less; no per-event change | (a) **low**. (b) **medium**: 126 lines move between modules and two upvalues become getters; the hook must capture `print` when installed, not when `devloop.lua` loads (the light spec at 1001-1021 replaces `_G.print` before loading the driver and expects the failure line through it, as `original_print` at light 88 does today) | the specs load the **real** `common.devloop` (light spec 126-137, 931-934; scene 186-196) and pin the whole behaviour end to end: buffer of 30 newest lines, debug lines never forwarded, `allow_empty`/`log_command` false, `log.always` forwarded, the one-time failure print, the release build leaving `log.sink` alone (light 936-1037, scene 1059-1152); `DEV_RELOAD` (light 900-931, scene 1013-1055). Nothing to add; (a) changes a release-only warning no spec reads | **improves** slightly: release devices stop answering `DEV_RELOAD` at all (today it only warns, `light 786`) |
| 4 | `src/hue_light/driver.lua:455-458`, `src/hue_scene/driver.lua:566-569` | `report_online()` returns `true` for nobody: `stop()` takes only `report_brightness`/`report_color` (light 489-495, 893-899; scene 891-898). Drop the `return true` and the comment that promises it. | −2 | none | **low** | SYNCHRONIZE and ONLINE specs (light 667-676, 691-712; scene 687-705) | none |
| 5 | new `src/common/device.lua`; `src/hue_light/driver.lua`; `src/hue_scene/driver.lua`; optionally `tools/build.sh` | One shared module for the plumbing both drivers carry twice, in two stages (detail below). **Stage A**, byte-identical blocks parameterised by two callbacks (`is_on()` → nil/true/false, `on_found()` for the re-check): the dev-loop preamble, `prop`/`notify`/`device_id`/`result`, the keypad LEDs and button colours with `REQUEST_BUTTON_COLORS` and `SET_BUTTON_COLOR`, `bound_bridge`/`proxy_id`, `driver_version`/`show_driver_version`/`Driver_Version`/`Debug_Mode`, `after_late_init`/`drain_early`, the binding re-check, `text`/`to_bool`. **Stage B**: the press/click/release state machine (`settings`, `hold`, `guard`, `button_action`, `BUTTON_ACTION`, `link_button`, `DO_PUSH`/`DO_RELEASE`/`DO_CLICK`, `SET_*_RATE`) with hooks `on_click`, `on_hold`, `on_finish`, `on_end_hold`. The module must be a constructor (`device.new{…}` returning an instance), not module-level state. | **A ≈ −230** (2×266 removed, ~300 added); **B ≈ −105** (2×130 removed, ~155 added) | **none**: each device is its own Lua state and `require`s the module into it, so the code loaded per device is the same size plus a few closures; the bridge's `.c4z` gains an unused file unless `tools/build.sh:46-49` drops it as it drops `devloop.lua` | A **medium** (identical code, the hooks are the only semantic points; a dozen upvalues become closures). B **medium–high** (the two machines differ in exactly four places, each a hook; the scene's `end_hold` also cancels a time-based scene's `follow`, 1437-1440). Rule 4 of the brief says a merge is only worth it when pinned end to end: here it is, see the spec map below | light 142-253, 419-507, 1039-1372; scene 201-290, 774-862, 1154-1335, 1419-1517, 1828-1859; `scene_roundtrip_spec.lua:121-348`, `zone_light_roundtrip_spec.lua:159-331`; the fake's Composer-delete path (light 481-489, scene 836-844). No spec changes expected; one log line drifts (below) | **needs care**: a shared file means a change for one driver lands in both `.c4z` (and in the bridge's package); no new surface |

Lines saved: low risk (#1, #3a, #4 minus #2's four lines) **−12**; medium
(#3b, #5A, #5B) **−415**; together about **−425**.

### Detail for #5: would `src/common/device.lua` pay for itself?

**What is duplicated** (light → scene, line ranges; "=" byte-identical,
"≈" identical but for the named difference):

| Block | Light | Scene | Lines | Difference |
|---|---|---|---|---|
| dev-loop preamble | 17-31 | 19-33 | 15 | = (the prefix in one `print`) |
| log-forwarding sink | 77-139 | 130-192 | 63 | ≈ one local's name |
| `prop`, `notify`, `device_id` | 141-158 | 194-204, 233-235 | 14 | = |
| `text`/`to_bool` | `light/state.lua:110-121, 151-156` | 210-228 | 19 | = |
| keypad LEDs and colours | 340-427 | 422-509 | 88 | ≈ on-state source: `st.on == true` (403) vs `effective_on()` (485); `st.on == nil` (420) vs `brightness() == nil` (502) |
| `report_online` | 455-458 | 566-569 | 4 | = |
| `bound_bridge`, `proxy_id` | 582-603 | 904-926 | 22 | = (the scene's has one more comment) |
| `hello`, `load_identity`, `save_identity` | 621-647 | 941-966 | 27 | ≈ message name; the light warns on an unknown persisted kind (636), the scene drops it silently (955-957) |
| driver version, Debug Mode | 651-681 | 970-1000 | 31 | = |
| `after_late_init`, `drain_early` | 689-709 | 1051-1071 | 21 | = |
| `DEV_RELOAD` | 784-802 | 1283-1302 | 19 | ≈ tree filter wording |
| `result` | 807-810 | 1307-1310 | 4 | = |
| button constants, settings, `end_hold`, guard | 923-990 | 1403-1460 | 68 | ≈ settings tables (light: preset + click + hold rates, 929-931; scene: hold rates, 1408-1409); the scene's `end_hold` cancels `follow` (1437-1440) |
| `button_action`, `BUTTON_ACTION`, `link_button`, `DO_*` | 1074-1142 | 1579-1644 | 69 | ≈ the click hook (`click` 1093 vs `button_click` 1598) |
| `SET_*_RATE` | 1144-1148 | 1646-1647 | 5 / 2 | the light has three more |
| `REQUEST_BUTTON_COLORS`, `SET_BUTTON_COLOR` | 1150-1181 | 1649-1680 | 32 | ≈ on-state source (1157/1656, 1180/1679) |
| re-check | 1191-1227 | 1694-1730 | 37 | = |
| `OnBindingChanged` | 1254-1274 | 1761-1781 | 21 | ≈ what is settled on unbind (1269-1270 vs 1776-1777) |
| `OnDriverRemovedFromProject` | 1280-1293 | 1787-1800 | 14 | ≈ message name |

Not shared and not shareable: identity and Status texts (light 153-338,
scene 230-362), targets and fallbacks (light 460-574, one timer per field;
scene 582-898, one `pending` plus `follow`), the hold itself (light
`start_ramp`/`start_hold`/`finish_hold` 997-1072 with the 100 ms estimate;
scene 1472-1577 with `send_dim`, `hold_changing` and the smart-scene start),
`HUE_*` handlers, `OnDriverLateInit`.

**Which specs pin each block end to end** (both drivers run through the fake
runtime, `tests/helpers/fake_c4.lua`, so a refactor that keeps behaviour
passes them unchanged):

| Block | `light_driver_spec.lua` | `scene_driver_spec.lua` | Round trips |
|---|---|---|---|
| startup, hello, `bound_bridge` (table / number / 0), binding hint | 143-253 | 202-290 | `zone_light_roundtrip_spec.lua:159` (hello → configure), `scene_roundtrip_spec.lua:121` |
| Driver Version and the build stamp, Debug Mode | 149, 152-183 | 209, 1034 | — |
| before-late-init buffer | 419-464 | 774-818 | — |
| goodbye and destroy (timers killed) | 465-507, 1211-1219 | 819-862, 1328-1334, 1697-1704 | both round trips end with a Composer delete |
| LEDs, `BUTTON_INFO`, `REQUEST_BUTTON_COLORS`, `SET_BUTTON_COLOR`, persisted colours | 1221-1291 | 1419-1517 | — |
| buttons on the proxy route and on 200-202, holds, click guard, rates persisted | 1039-1220, 1292-1337 | 1154-1335, 1784-1827, 2222-2302 | `zone_light_roundtrip_spec.lua` (hold → `dimming_delta`, release → `stop`) |
| binding re-check | 1338-1372 | 1828-1859 | — |
| dev log forwarding, `DEV_RELOAD` | 900-1037 | 1013-1152 | — |
| `dispatch` | — | — | `dispatch_spec.lua:15-43` |

**Which files change**: `src/common/device.lua` (new), `src/hue_light/driver.lua`,
`src/hue_scene/driver.lua`; `tools/build.sh` only if the bridge's stage
should not carry the unused file (`tools/build.sh:45` copies all of
`src/common` into every stage); nothing in `.luacheckrc` (`src/common/*.lua`
lints under the default std with the `C4` read-global, `.luacheckrc:2-9`),
nothing in `.busted` (`lpath` has `src/?.lua`, so `require("common.device")`
resolves, `.busted:3`), nothing in the fake (`fake_c4.lua:754-763` already
resets `common.*` per `load_driver`). The dev loop keeps working:
`tools/devserver.py:18, 112-116` serves `src/common/*.lua` in both trees and
`src/common/devloop.lua:266-270` clears `common.*` on reload.

**Verdict**: in lines, yes (−330, the largest saving in this area); in
runtime, no (zero, see the table); in maintenance, yes: `docs/keypad-design.md`
("Light parity") has every keypad and LED change made twice, four times with
the specs, and the two drivers have already drifted in one place (the
light's warning at 636 that the scene lacks at 955-957). Against it: the
brief's rule 4 (risk first), about 600 lines moving before a release, and
the coupling that puts every device-side change into all three packages. My
recommendation: Stage A before the release (the code is identical, the two
hooks are mechanical), Stage B afterwards or never; and #3b first, since it
is the same move for the one block whose code leaves release builds
altogether.

### Considered and not proposed

- Startup writes the same properties twice: `Hue Light ID` at
  `hue_light/driver.lua:1236` and again from the answered configure (725);
  `refresh_status()` from `hello()` (627) and from the configure (741);
  `ONLINE_CHANGED` at 1243 and 740 (the scene the same, 1741-1750 and
  1128-1130). Three or four IPCs per device per start; a `prop()` cache would
  save them but risk a stale row after the empty-property-table case of
  `docs/status.md:150-154`. Not worth it.
- `light/state.lua:212-215, 222, 258`: `apply_hue` builds two `proxy_view`
  tables and, in ct mode, calls `C4:ColorCCTtoXY` twice per `HUE_STATE`
  (and `report_color` a third time, `hue_light/driver.lua:443`). Comparing
  raw fields instead would break `light_state_spec.lua:249` (a ct-mode
  report with a slightly different xy must not flag colour). A one-entry
  memo of mirek → xy (4 lines in `to_proxy_color`, 287-296) would save the
  C calls; the benefit is too small to list.
- The light hold's 100 ms tick (`hue_light/driver.lua:1003-1012`) could be
  an elapsed-time estimate at release with `C4:GetTime`, saving a repeating
  timer that runs only while a button is held; the specs at 1080-1131 pin
  the estimate through fake timer ticks and would change. Not worth it.
- `common/dispatch.lua:54` wraps `binding` and `command` in `tostring` before
  the level check: one short string per proxy command. The wrappers also
  protect `string.format` from a nil; keep.

## 3. Do not touch

- `src/hue_light/light/state.lua:166-179` (the kind sticks when a configure
  names none) and `src/hue_scene/driver.lua:1077-1095` (`take_kind` defaults
  to an ordinary scene): not shims for old bridges only; the bridge's lights
  module sends no kind at all (`src/hue_bridge/bridge/lights.lua:932-953`),
  and Re-link across scene kinds relies on the change path
  (`docs/smart-scenes-design.md` Decision 12; specs light 1504, scene 1922,
  1996).
- `hue_light/driver.lua:582-592`, `hue_scene/driver.lua:904-915`:
  `bound_bridge` accepting a table or a number and treating 0 as unbound. OS
  3.4.2 answers 0 with nothing bound (`docs/design.md:609`; specs light 200,
  207; scene 226, 233).
- `hue_light/driver.lua:621-628` (`hello(hint)`): Director's lookup lags the
  binding event (spec light 239, scene 275).
- `hue_light/driver.lua:1191-1227`, `hue_scene/driver.lua:1694-1730`: the
  binding re-check at 5, 15, 30 and 60 s. A Director restart quirk seen on
  the house (`docs/keypad-design.md`, "Hardware findings"); the path itself
  is still unverified on hardware (`docs/status.md:169-171`), which is a
  reason to keep it exactly as specified (light 1338-1372, scene 1828-1859).
- `hue_light/driver.lua:48-56, 73, 864-885`: the alternative `SET_COLOR_TARGET`
  key spellings, `pick()` and the one-time `first SET_COLOR_TARGET params`
  line. The names are still **[assumed]** (`docs/lights-design.md:188-191`),
  the Composer checklist item that reads that line is **Open**
  (`docs/composer-checklist.md:125-131`), and specs 825 and 832 pin both.
  Build 199's colour picks reaching the lamps (`docs/status.md:141-144`)
  show one spelling in each list matches, not which. Once D.10 records the
  line, −22 lines become a low-risk cleanup (with the two specs changed).
- `hue_light/driver.lua:689-709`, `hue_scene/driver.lua:1051-1071`: the
  pre-late-init buffer. `UpdateProperty`/`SendToProxy` are unsafe before
  `OnDriverLateInit` [API 22/_25.2]; `docs/code-analysis-2026-10-22.md:40-46`.
- `hue_light/driver.lua:667-677`, `hue_scene/driver.lua:986-996`: the Driver
  Version retries at 5 and 15 s. Hardware 2026-10-24 (`docs/status.md:150-154`;
  spec light 166-183).
- `hue_light/driver.lua:737`: `DYNAMIC_CAPABILITIES_CHANGED` on every
  configure. The bridge already sends a configure only on change or hello
  (`src/hue_bridge/bridge/lights.lua:140, 410, 977`), and whether the proxy
  remembers dynamic capabilities across a Director restart is not verified
  (`docs/zone-light-design.md` §1 facts: the colour controls appeared "that
  way"). Spec light 1657.
- `hue_light/driver.lua:407-415`, `hue_scene/driver.lua:489-497`: three
  `MATCH_LED_STATE` plus three `BUTTON_INFO` per on/off flip. Snap One's
  template does the same (`docs/keypad-design.md`, "Keypad LEDs" [verified]);
  specs light 1222, scene 1420 pin the six messages.
- `hue_scene/driver.lua:1433-1442` (`end_hold` cancelling `follow`): a
  time-based scene's dim follows only while the button is held
  (`docs/smart-scenes-design.md` Decision 4; spec 2261). Any shared button
  machine must keep this hook.
- `hue_scene/driver.lua:380-391` (`set_held` writing only on change, the
  persisted `held_on`): the on rule (`docs/scene-dimmer-design.md`,
  Behaviour; specs 1706-1783).
- `hue_scene/driver.lua:1025-1043` (`apply_recall_as`'s existence check and
  pcall): the harness has no `SetPropertyAttribs`; spec 2331.
- `hue_light/driver.lua:904`, `hue_scene/driver.lua:1374` (`STOP_SCENE_RAMP`
  alias): unverified name, one line, specs light 599, scene 678.
- `hue_light/driver.lua:1188-1189`, `hue_scene/driver.lua:1691-1692`: the
  empty `OnDriverInit`. Four lines; the SDK describes the entry point as
  "provided for the driver developer" without calling it optional
  (`~/c4-tools/reference/docs-driverworks-api/source/includes/22_miscellaneous/_25-OnDriverInit.md`),
  the dev loop treats it as optional (`src/common/devloop.lua:303-305`).
  Not worth a hardware surprise.
- `hue_light/driver.lua:790-792`, `hue_scene/driver.lua:1290-1292`: the
  `DEV_RELOAD` tree filter. The bridge forwards every non-bridge tree to
  everything on binding 1 (`docs/scenes-design.md` §6; spec scene 1023).

## 4. Open questions for the coordinator

1. #5: Stage A alone before the release, as recommended, or both stages?
   Stage B is where the two drivers genuinely differ (four hooks) and where
   the keypad behaviour verified on the house lives.
2. #5: ship `common/device.lua` unused in `hue_bridge.c4z`, or extend
   `tools/build.sh:46-49` to drop it from the bridge's stage as it drops
   `devloop.lua` from release stages?
3. #1: delete `HUE_DUMP` (recommended; the question it answered is closed,
   `docs/design.md:697-704`) or gate it on `devloop` to keep a dev
   diagnostic? Either way `docs/status.md:175-178`, `docs/scenes-design.md:65`
   and `docs/code-analysis-2026-10-22.md:100-102` need a line.
4. Composer checklist D.10 (`docs/composer-checklist.md:125-131`) needs the
   owner's Lua tab once; it unlocks −22 lines in the light driver (above).
5. Not slimming, noticed on the way: the `show_driver_version` timers
   (`hue_light/driver.lua:675`, `hue_scene/driver.lua:994`) are the only
   timers `OnDriverDestroyed` does not track; harmless on the controller (the
   Lua state goes with the device) and at most a stray `UpdateProperty` after
   a dev-loop reload. Track them (3 lines each) or leave? **Done
   2026-10-25** (#49): the Driver Version timers are tracked and killed in
   `OnDriverDestroyed` in both device drivers and the bridge.
6. Not slimming: the device-side pre-late-init buffer (`hue_light/driver.lua:694`,
   `hue_scene/driver.lua:1056`) has no cap, where the bridge's hello queue
   keeps 200 (`docs/code-analysis-2026-10-22.md:40-46`). The window is one
   startup, the senders are the bridge's own configure/state per device; a
   cap of 50 would be three lines. For the hardening list, not this pass.
   **Done 2026-10-24** on `release-prep` (security review finding 4): the
   buffer is capped at 200 messages (`common/device.lua`).
7. #5 drifts one log line: a shared `load_identity` gives the scene the
   light's "persisted kind %q is not one this build knows" warning
   (`hue_light/driver.lua:636`) where the scene is silent (955-957). Not an
   owner-visible text under the brief's rule 1 (no property, action, picker,
   Status, Last Action, notification or message changes), but say so in the
   implementation brief.
