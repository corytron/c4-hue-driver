# Scene tracking: which scene is on (research for #469)

Research for issue #469, part 1 of 2 (the other part, which room a scene
device belongs in, is `docs/scene-rooms-research.md`). Read-only: nothing
here has been built. It feeds the contract `docs/scene-tracking-design.md`.

Current (2026-11-13, #478): built in 1.6. The contract's owner's decisions
O1, O2 and O7 answer §9: the tile follows its own scene, a bound keypad keeps
following the room's lights by default, and the property is renamed
**Keypad Follows**.

The owner's report (2026-11-12, house): with several Hue Scene devices in
the Master Bedroom, dimming one of them in the iPhone app makes every scene
device of the room show the same level. That is right for lights and zone
lights, not for scenes: nobody can tell which scene is on, if any. The
owner's rules:

- **R1.** A scene device's slider shows a level only while that scene is
  the active one. When a scene with no Control4 device is active, or no
  scene is, no scene device of the room shows a level.
- **R2.** Moving the slider of a scene device switches to that scene at
  once, even while another scene of the room is on.

Evidence tags: **[verified: …]** names the code (`file:line`), a spec, a
hardware record in this repository, or the SDK page; **[assumed]** means
none of those shows it yet. SDK short names (BP, LV2 and its sub-folders,
KP, FUND, C4-ALS and the other dealer pages) are those of
[the guidelines' sources table](c4-lighting-guidelines.md#2-sources-and-short-names).
The Control4 dealer pages C4-ALS and C4-KEYPAD were reachable and read on
2026-11-12; they are paraphrased, never quoted.

## Contents

- [1. Summary](#1-summary)
- [2. Today: what decides a scene device's state](#2-today-what-decides-a-scene-devices-state)
- [3. What the bridge sends and what Hue reports](#3-what-the-bridge-sends-and-what-hue-reports)
- [4. The wanted behaviour, case by case](#4-the-wanted-behaviour-case-by-case)
- [5. Commands on a scene that is not the active one](#5-commands-on-a-scene-that-is-not-the-active-one)
- [6. Keypad LEDs and the On State Follows property](#6-keypad-leds-and-the-on-state-follows-property)
- [7. Control4 lighting guidelines](#7-control4-lighting-guidelines)
- [8. Recommendations for the contract](#8-recommendations-for-the-contract)
- [9. Open questions for the owner](#9-open-questions-for-the-owner)

## 1. Summary

- The mirroring comes from the default **On State Follows** =
  `Room/zone lights` (#310): every scene device of a room reads on while any
  lamp of the room is on, and every device that reads on shows the room's
  level. The bridge sends the room's level to all of them.
- The other mode, `This scene`, already gives R1 for the owner's case: only
  the scene played last (the "on rule") shows a level. R2 also falls out of
  it: a slider target on a scene that reads off plays that scene at the
  target.
- So the core change is small: the **tile** always follows the scene (the
  on rule), never the room. What stays to decide is the **keypad** (LEDs,
  toggle button, holds), which the owner asked in #310 to follow the room.
- Five gaps in today's "which scene is on" signal make R1 fail in some
  cases even in `This scene` mode (section 3.3): overlapping rooms and
  zones, the resync and the hello, a recall answer without its stream
  event, a scene deleted in Hue, and a device linked to another scene.
- One existing race matters more once the slider switches scenes: a level
  move right after a recall is measured from the previous scene's level
  (section 5.2).

## 2. Today: what decides a scene device's state

### 2.1 The inputs

All in `src/hue_scene/driver.lua` unless named otherwise.

| Input | From | What it changes |
|---|---|---|
| `HUE_SCENE_STATE {active}` | bridge: every scene status event (`src/hue_bridge/bridge/scenes.lua:1509`), the recall answer (`:1929-1938`), each resync and hello answer (`src/hue_bridge/bridge/owner.lua:458`, `push`) | `st.active`. A `static` or `dynamic_palette` status sets `held_on` for an ordinary scene (`take_status`, 349-354); `inactive` never clears it [verified: 1436-1482]. |
| `HUE_SCENE_GROUP {on}` | bridge: the room's grouped_light on/off on change (`scenes.lua:1101-1104`), at resync (`send_group_all`, 1037-1052), in the hello answer (`send_group_known`, 1191-1199) | `group_on`. `on=false` ends `held_on` [verified: 1525-1527, 1548-1554]. |
| `HUE_SCENE_GROUP {level}` | the same routes; the grouped_light's `dimming.brightness`, the average of the lit lamps | `st.level`, one value per room shared by every scene of it [verified: 1521-1524]. |
| `HUE_SCENE_GROUP {other_active}` | bridge: another scene of the same group became active (`send_other_active`, `scenes.lua:1145-1159`) | ends `held_on` of an ordinary scene [verified: 1548-1554]. |
| The device's own commands | OFF, bottom tap, toggle off; a keypad hold; a tap stop | OFF ends `held_on` (1027-1030, or at the ramp's end 667-669); a hold sets it (1906-1909); a stopped recall keeps it (802-804). |
| Restart | PersistData `held_on` | `load_held` (342-344): the tile reads the held state before the bridge answers. |
| Property `On State Follows` | Composer | `follow_lights` (1189-1197). |

A time-based scene ignores `held_on` and `other_active`: it is on exactly
while Hue says it runs (`held`, 310-312; `docs/smart-scenes-design.md`
Decision 2).

### 2.2 The on state and the level, per mode

- **The scene half** (`effective_on`, 316-318): Hue says the scene plays,
  or `held_on`. This is the "on rule" of `docs/scene-dimmer-design.md`.
- **`This scene`**: on = the scene half.
- **`Room/zone lights`** (default): on = the scene half **or** the room is
  on (`shown_on`, 324-326).
- **The level** (`brightness`, 365-373): 0 while off; while on, the room's
  level as a whole percent, or 100 while none is known.
- That one on state drives the tile, the proxy's on and off events, the
  keypad LEDs (`dev.is_on`, 383-391, read by `src/common/device.lua:629`),
  TOGGLE (1694-1706), the slider's choice between a recall and a room move
  (1106), and the hold direction (`src/common/device.lua:1048-1049`).

### 2.3 Trace: the slider of one scene, in the Control4 app

Scenes A and B of the Master Bedroom have devices. A was played; the room
is at 60 %. The owner drags A's slider to 30.

1. The Navigator sends `SET_BRIGHTNESS_TARGET {30, RATE 0}` [verified:
   hardware 2026-10-21, `docs/design.md` "Lights: verified on hardware"].
   A's handler (1662-1669) calls `set_target` (1084-1110).
2. A reads on, so `move_level` (1059-1076) sends `HUE_SCENE_LEVEL {level
   30}` (`send_level`, 860-884).
3. The bridge (`src/hue_bridge/driver.lua:1852`, `scenes:level`,
   `scenes.lua:2172-2243`) queues a relative `dimming_delta` down 30 on the
   room's grouped_light; it goes out through the group queue (one a second
   after a burst of three, `driver.lua:713-725`).
4. Hue moves the lamps and keeps A `static` (a whole-room relative dim
   sends no scene event [verified: `docs/smart-scenes-research.md` §7,
   V11]). It streams a `grouped_light` item with the new brightness.
5. `scenes:on_grouped_light` (`scenes.lua:1090-1126`) sends
   `HUE_SCENE_GROUP {level}` to **every** linked scene of that grouped_light
   (`linked_scenes_on`, 999-1003; `send_group_for`, 1008-1016).
6. Each device caches the level and reports it when it reads on
   (`driver.lua:1574-1575`). In `Room/zone lights` both A and B read on (the
   room is on), so both tiles go to 30. That is the owner's report.

In `This scene`, B reads off (0) and ignores the level: only A moves.

### 2.4 Trace: a dim in the Hue app

The Hue app's room slider changes the room's grouped_light. From step 4
on the path is the same: no scene event (V11 for a relative dim; for an
absolute one, V11 saw a dynamic scene stay `dynamic_palette`, and a static
scene staying `static` is [assumed]), one grouped_light item, the level to
every scene of the room, every tile that reads on mirrors it.

## 3. What the bridge sends and what Hue reports

### 3.1 When `other_active` goes out today

Line numbers are those of `src/hue_bridge/bridge/scenes.lua`.

| Event | `other_active`? | Code |
|---|---|---|
| A scene of the group becomes `static` or `dynamic_palette` in the stream, **with or without a device** (Control4, Hue app, Hue switch, Hue automation) | Yes, to every other linked scene of the **same group** | `scenes.lua:1478-1485`, `1145-1159` [verified: spec "an unimported scene becoming active tells the linked scenes of its group", `tests/spec/scenes_spec.lua`; hardware 2026-10-24 V4, a schedule's start told Shine] |
| A time-based scene becomes active (stream, or the activate answer if it comes first) | Yes, same group; a schedule is not told about its own slot scene | `1542`, `1563`, `1729-1733`; Decision 10 |
| A Control4 recall of an ordinary scene succeeds | No: only Hue's stream event sends it | `1929-1938` |
| Lamps changed by hand, from a Hue Light or Zone Light device, a Hue switch's dim or on/off, a Hue automation that sets lamps without a scene | No. The scenes hear the room's on and level, and a scene whose status changes hears its own `STATE inactive` | `1090-1126`, `1509` |
| A scene of an **overlapping** room or zone becomes active | No: only scenes with the same `group_rid` are told | `1146-1153` |
| Resync after a stream reconnect; the answer to a device's hello | No: STATE, on and level only | `1362-1392`, `1037-1052`, `1180-1199` |

The house has not yet seen another scene played from the Hue app
[verified: `docs/design.md` "Keypad and scene dimmer: verified on
hardware", the "Still not seen" list].

### 3.2 What Hue reports

| What happens | Scene status | Evidence |
|---|---|---|
| A scene is recalled | `static` / `dynamic_palette` about 9 ms after the PUT, in its own container; lamp and grouped_light items within a second | [verified: hardware 2026-10-21, `docs/design.md` "Scenes: verified on hardware"] |
| Recalled with a brightness override | Lamps at the override, in the scene's colours | [verified: #41, both lamps at 1.19 % for 1 %]. That the status becomes `static`: [assumed] (`docs/edge-cases-hue.md` §3 lists it as open); the bridge's own answer says `static` anyway. |
| Another scene of the same group recalled | The previous one goes `inactive` | Time-based: [verified: V10, V11]. Ordinary: [assumed] (community, `docs/edge-cases-hue.md` §3). |
| The whole room dimmed, relative | No scene event; `static` stays | [verified: V11] |
| The whole room set to an absolute level | `dynamic_palette` stays | [verified: V11]; a `static` scene: [assumed] the same |
| One lamp of the scene changed (Hue app, Hue Light device, a Hue switch on one lamp) | `inactive` | [verified: hardware 2026-10-21, `docs/design.md`; V11] |
| A keypad hold since 1.3 (each lit lamp dimmed on its own when 1 to 10 are lit) | `inactive`, as any lamp change | follows from the row above and `docs/group-hold-design.md` G4 |
| The room turned off | `inactive`; a running schedule stops | [verified: V9] |
| A scene of an overlapping zone recalled | The room's scene goes `inactive` | Time-based, room then zone: [verified: V10]. Ordinary: [assumed], by the lamp-change rule. |

So Hue's status alone cannot be the tile: Control4's own keypad holds
make a static scene `inactive` (that is why the on rule exists). And
`other_active` alone is not a complete "another scene took over" signal.

### 3.3 Gaps for R1

1. **Overlapping groups.** A zone scene over the room's lamps (on the
   house the Bedside Lights zone holds the same two lamps as the Master
   Bedroom, `docs/smart-scenes-research.md` §7b) leaves the room scene's
   `held_on` set: no `other_active` crosses groups. Both tiles show a
   level, in either mode.
2. **Resync and hello.** If another scene was played while the stream was
   down or Director restarted, the held scene hears `STATE inactive`
   (ignored by the on rule) and the room still on: it stays lit.
3. **Recall answer.** `other_active` waits for Hue's event. If the event is
   missed, or Hue sends none for an override recall ([assumed] either way),
   the old scene stays lit beside the new one.
4. **A scene deleted in Hue.** The bridge sends CONFIGURE `gone` and STATE
   `inactive` (`announce_gone`, `scenes.lua:1166-1174`) and then no more
   group messages (`send_group` needs a linked entry, 962-973). The device
   keeps `held_on` (the configure does not clear it, `driver.lua:1262-1297`),
   so a held scene that is deleted still reads on until a command reaches it
   (`ready`, 532-547).
5. **A device linked to another scene.** A configure with a new rid clears
   `group_on` only (1264-1268): the old scene's `held_on` and status carry
   over to the new one until the bridge reports.

## 4. The wanted behaviour, case by case

"Tile" is the device's level and on state (the proxy, Navigators,
programming events). "Room" means the scene's Hue room or zone. LED
columns: the keypad following the room's lamps (the #310 wish, section 6)
or following this scene. "New" marks where the recommendation changes
today's code.

| # | Case | This device's tile | Other scene devices of the room | LEDs, keypad follows room | LEDs, keypad follows scene |
|---|---|---|---|---|---|
| T1 | This scene played from Control4 (tile, programming, an Advanced Lighting scene), a keypad tap, or a hold from off | On, the room's level (100 until the first report) | 0 (`other_active`) | On | On |
| T2 | This scene played from the Hue app, a Hue switch or a Hue automation | Same as T1 [assumed for switches and automations: they recall scenes as the app does] | 0 | On | On |
| T3 | This scene dimmed from its own slider | On, new level | Stay 0 (today: mirror) | On | On |
| T4 | Dimmed as a whole from the Hue app or a Zone Light device | On, the level follows | Stay 0 (today: mirror; the report) | On | On |
| T5 | Held from its own keypad (Hue then calls it `inactive`) | On (the on rule) | 0 | On | On |
| T6 | One lamp of it changed from outside (Hue app, Hue Light device, Hue switch) | On, by the on rule (question 2) | 0 | On | On |
| T7 | Another scene of the room that has a device is played (any route) | 0 | That one on, the others 0 | On | Off |
| T8 | A scene with no device is played (any route) | 0 | All 0 | On | Off |
| T9 | Lamps turned on by hand, from a Hue Light device or a Hue switch, with the room off before | 0 (no scene was played; the held state ended with the room off) | All 0 | On | Off |
| T10 | The room turned off from anywhere | 0; the held state ends | All 0 | Off | Off |
| T11 | A scene of an overlapping zone or room, or a whole-home scene, is played | 0 when the groups share a lamp (new: `other_active` across groups) | Those sharing a lamp 0; the scene played on | On | Off |
| T12 | A time-based scene starts (any route) | Its device: on while Hue says it runs, at the room's level | Its current slot scene's device on too (both are active in Hue, question 3); every other scene 0 | On | On for the two |
| T13 | That schedule moves to its next slot | Schedule stays on | The old slot scene 0, the new one on | On | On for the two |
| T14 | Controller or Director restart | At once from the persisted held state and the last status; corrected by the hello answer, which also says when another scene took over meanwhile (new) | The same | The scene's state until the hello answer brings the room's on/off (not persisted) | The scene's state |
| T15 | Bridge offline, then back | Last state kept; the tile greys after 5 minutes (#428); the resync's answer settles it, also telling a scene that another took over (new) | The same | Last state, then the resync's | Last state, then the resync's |
| T16 | This device's scene deleted in Hue | 0 at once (new: the held state ends) and offline (`blocker`, `driver.lua:225-226`) | Unchanged | Off | Off |
| T17 | The device linked to another scene (a new rid) | Unknown (nothing shown) until the bridge reports the new scene (new: held state, status and level cleared) | Unchanged | Unknown until reported | Unknown until reported |
| T18 | The same scene played again while on | Unchanged | Unchanged | Unchanged | Unchanged |
| T19 | The slider of a scene that is not the active one | Plays that scene at the target (section 5), then as T1 | As T1 | As T1 | As T1 |

## 5. Commands on a scene that is not the active one

### 5.1 The mapping

Scene A plays in the room at 60 %; B has a device and is not the active
one, so its tile shows 0 under R1. What each command on **B** does. Hue
bodies are those of `scenes:send_recall` (`scenes.lua:1888-1946`) and
`scenes:off` (`2038-2083`).

| Command on B | Today, `Room/zone lights` | Today, `This scene` | Recommended |
|---|---|---|---|
| `SET_BRIGHTNESS_TARGET` 1 to 99, `RATE` r (the slider) | B reads on (room lit): relative room move, A's look kept, B never plays; every tile mirrors | Recall B at the target | **Recall B**: `PUT /scene/<B> {"recall":{"action":<Recall As>, "dimming":{"brightness":T}, "duration":r}}` (`duration` only when r > 0). Hue sets every lamp to T in B's colours (#41). |
| Target 100 | Room move to 100 | Recall B as designed | Recall B as designed (no override keeps its look; `driver.lua:946-951`) |
| Target 0 | Room off | Room off | Room off, unchanged: an Advanced Lighting deactivate acts whatever the scene's state (LV2 als `_4.4-DEACTIVATESCENE.md`). A Navigator cannot send it from a tile at 0. |
| `SET_LEVEL`, `RAMP_TO_LEVEL` | As the target, `TIME` as the rate (1960-1961) | Same | Same |
| `ON`, `DYNAMIC_ON` | Recall B as designed, default rate | Same | Same |
| `TOGGLE` (proxy) | Room off (B reads on) | Recall B | **Recall B**: TOGGLE follows the tile, as an Advanced Lighting scene's toggle plays an inactive scene (LV2 als `_4.5-TOGGLEESCENE.md`) |
| `OFF`, `DYNAMIC_OFF` | Room off | Room off | Room off, unchanged |
| Keypad tap, top | Recall B over the whole click-up rate (`own` = 0, 1805-1806) | Same | Same |
| Keypad tap, bottom | Room off over the click-down share of the room's level | Room off at once (B's level reads 0, 1797-1800) | Room off over the share of the **room's** level whenever the room is lit, so the fade and its tap stop (#421) work |
| Keypad tap, toggle | Room off | Recall B | Follows the keypad's state (section 6) |
| Keypad hold, top | Room brightens from where it is, and B becomes held: A and B both read on | Recall B at 1 % (a visible dip from 60 %), then brighten | Keypad follows room: the room brightens from where it is, **without** making B active. Keypad follows scene: recall B at the room's current level, not 1 %, then brighten. |
| Keypad hold, bottom | Room dims from where it is | Nothing (B reads off; L43) | Keypad follows room: room dims. Keypad follows scene: nothing (L43). |

Once B's recall is confirmed, B is the active scene: A hears
`other_active` (from Hue's event, and with recommendation 5 also from the
recall answer) and goes to 0, and B's next targets are relative room moves
(`HUE_SCENE_LEVEL`), as for any active scene.

### 5.2 Slider spam, the rate, and a stale level

- **On the device.** While B's recall is unconfirmed, each new target
  recalls again at the new level (`set_target`, 1106: the room's level is
  in flux then). Hue confirms in about 250 ms [verified: hardware
  2026-10-21, the recall's answer after 240 ms]. After that, targets are
  relative moves.
- **On the bridge.** Recalls of one scene within 300 ms of its last recall
  PUT wait and leave as one PUT with the latest parameters; the first goes
  at once (`RECALL_WINDOW_MS`, `scenes.lua:84-91`, `1858-1884`). So a drag
  makes at most about three recalls a second. The relative moves go
  through the group queue: one a second after a burst of three
  (`driver.lua:713-725`; guidelines D2). Whether Hue's guidance of about
  one group request a second also covers scene recalls is [assumed]; no
  429 has been seen. BP "Handling Consecutive Brightness and Color
  commands" asks for exactly this kind of debouncing.
- **The rate.** The target's own `RATE`. The Navigator slider sends 0
  [verified: hardware 2026-10-21], so the switch is immediate (Hue's
  default transition). A timed target from programming fades B in over it
  [verified: #421 S1, a recall with `duration` fades the scene in].
- **A stale level after the switch (exists today, matters more now).** The
  bridge's `group_level` still holds A's 60 until Hue's grouped_light item
  arrives, within about a second. `scenes:level` measures a move from it
  (`scenes.lua:2202-2220`), and a recall changes nothing there
  (`send_recall`). So after "B at 30", a target of 40 that arrives before
  the report goes out as "down 20" and the lamps end at 10. Two fixes:
  - after a recall at T, the bridge assumes `group_level` = T until Hue
    reports (keeping `level_before`, as `scenes:level` does, for an
    undelivered recall) [verified that Hue sets every lamp to T: #41];
  - after a recall as designed, the level is unknown: the device keeps the
    next target until the first level report since the recall (at most
    `FOLLOW_MS`), as a starting time-based scene does (`follow_with_level`,
    `driver.lua:898-904`). An absolute group level instead would flatten
    the scene's look.

## 6. Keypad LEDs and the On State Follows property

### 6.1 How Control4's Advanced Lighting scenes track

Paraphrased from C4-ALS (read 2026-11-12) and the LV2 als pages:

- Each load in a scene has a tracking condition: not tracked, off, on at
  any level, on at a given level, or at the scene's final level.
- The scene combines them in one of two ways: **all** tracked loads must
  match, or **any** one is enough. That gives the scene one current state,
  Active or Inactive.
- The dealer picks keypad LED colours for Active and for Inactive, so a
  keypad button bound to the scene shows that same state.
- Events fire when the scene becomes active and when it becomes inactive
  (LV2 als `_3.1-SCENEACTIVATED.md`, `_3.2-SCENEDEACTIVATED.md`), and
  another when it is invoked, active or not (`_3.5-SCENEINVOKED.md`).
- Toggle plays the scene when it is inactive and its toggle scene when it
  is active (`_4.5-TOGGLEESCENE.md`); deactivate always plays the toggle
  scene (`_4.4-DEACTIVATESCENE.md`). A held button ramps the scene's loads
  at the scene's hold rates (C4-ALS "Hold Rates").
- The page says nothing about overlapping scenes; two scenes over the same
  loads are each tracked on their own.
- C4-KEYPAD: a keypad button's LED either follows the bound device or
  shows the button's own push and release. Binding a button to a link sets
  it to follow (`docs/keypad-design.md`, #312).

Mapping: `Room/zone lights` is "any load, on at any level"; `This scene` is
close to "all loads at the scene's level", loosened by the on rule (a dim
of the scene keeps it active). In Control4 one scene has **one** tracking
state, shared by its Navigator state, its events and its keypad LEDs.

The driver can drive the LEDs apart from the tile: the LEDs follow
`MATCH_LED_STATE` on the Button Links and `BUTTON_INFO`, which the driver
sends with a state of its choosing [verified: LV2 notif `_2-BUTTONINFO.md`,
a driver tells the proxy its button LED state; `src/common/device.lua:617-638`].

### 6.2 The options

| | (a) Tile follows the scene; the property chooses the keypad only | (b) Everything follows the scene; the property goes | (c) One state, the property chooses everything (today), default `This scene` |
|---|---|---|---|
| R1, R2 | Met on every device | Met | Met only on devices set to `This scene`; Golden hours on the house would still mirror |
| #310 (2-button keypad shows the room's lamps) | Kept | Lost: the keypad goes dark when another scene or a hand-set lamp lights the room, the owner's #310 complaint | Kept only where the owner gives up R1 |
| Like Control4 (L64) | Each surface tracks like an Advanced Lighting scene, but the tile and the LEDs can differ; under a strict reading of L64 (one tracking state per scene) a departure that Hue does not force | Exactly "this scene active" | Exactly one of the two |
| Existing devices | No change on the keypads; tiles change | Keypads on `Room/zone lights` change | A new default does not reach a stored value (`docs/tap-stop-design.md` D15); changing it would mean overwriting the dealer's setting |
| Code | Two on states: tile and keypad | One, simpler than today | As today |

### 6.3 Recommendation: (a), with the keypad acting on what it shows

The owner asked for both: #310 (LEDs follow the room) and #469 (sliders
follow the scene). A Control4 keypad on a dimmer lights its top button
while the load is on, its bottom button while it is off, and acts on that
same load (guidelines L50, L53; LV2 cmds `_16.5-GETSETUP.md`, C4-DIM). A
keypad bound to a scene that the owner uses as the room's switch should
do the same. So the property decides everything the keypad does,
not only its LEDs:

- `MATCH_LED_STATE` and `BUTTON_INFO` (`dev.is_on`);
- the toggle button's tap (play, or room off);
- whether a hold dims a lit room or plays the scene from off
  (`src/common/device.lua:1048-1049`);
- the fade time of a bottom tap (the room's level while the room is lit).

The tile, the proxy's commands (`TOGGLE` included) and the proxy's events
follow the scene alone. A hold that dims a room another scene lit does not
make this scene active.

If the owner prefers one state per scene (strict L64), (b) is the clean
alternative: drop the property and serve #310 another way, for example
binding the keypad's bottom button to the room's Zone Light device so its
LED is lit while the room is off.

### 6.4 The property's name and its stored values

Under (a) the name "On State Follows" no longer describes it: the device's
on state follows the scene. Proposed name **Keypad Follows**, same items
(`Room/zone lights`, `This scene`), same default, tooltip "What keypad
buttons bound to this scene treat as on: any light of its room or zone, or
this scene being active".

- **What a rename does in Director.** FUND
  `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md` allows
  adding and removing properties on an update and warns against retyping;
  it says nothing about renaming. A rename is therefore a removal plus an
  addition, and the removed property's value is not carried over
  [assumed: `docs/simplify-research-composer.md` §H,
  `docs/simplify-research-compat.md`]. A device left at the default loses
  nothing; a device set to `This scene` would fall back to `Room/zone
  lights` and its keypad would change.
- **Migration.**
  1. Declare `Keypad Follows` and keep `On State Follows` in `driver.xml`
     until 2.0, hidden after late init with `C4:SetPropertyAttribs(name, 1)`
     [verified: API `24_properties/_4-SetPropertyAttribs.md`; the driver
     already hides Recall As this way, `driver.lua:1207-1225`]. A property
     still declared keeps its value across updates [verified: hardware,
     `docs/simplify-research-compat.md`].
  2. At late init, once: if PersistData has no `keypad_follows_migrated`,
     copy a stored `This scene` into the new property with
     `C4:UpdateProperty` [verified: API `24_properties/_5-UpdateProperty.md`;
     it does not call `OnPropertyChanged`, `_3-OnPropertyChanged.md`, so
     the driver applies the value itself], then set the flag. A dealer's
     later change is never overwritten.
  3. 2.0 removes the hidden row.
  4. `tests/fixtures/ledger.lua` row S6 gains the new property and keeps
     the old one until 2.0; the manual (chapter 9.4 and 9.5, chapter 11)
     and `CHANGELOG.md` explain it.
- **Keeping the name** avoids all of this, at the price of a name that
  misleads. A LIST item must not change meaning (`docs/simplify-research-compat.md`
  R7); here the items keep their meaning and only their scope narrows, so
  either way is allowed.

## 7. Control4 lighting guidelines

Rows of `docs/c4-lighting-guidelines.md` that the change touches.
Everything else marked "scene" keeps its status.

| Row | Guideline (paraphrased there) | With the recommendation |
|---|---|---|
| L64 | A scene's on state and LEDs track like an Advanced Lighting scene: "any load on" or "this scene active" (C4-ALS "Tracking") | The tile tracks "this scene active" always; the keypad tracks whichever the property names. Meets per surface; under a strict reading (one state for both) (a) is an owner's choice, not forced by Hue (question 1). (b) meets it strictly. |
| L9 | A light that is on never reads off | For a scene the "load" is the scene (D11: an on state of its own). A lit room with another scene reads 0 on this device, as an inactive Advanced Lighting scene does. Not a departure; the row's note should say so. |
| L19, L66 | TOGGLE from off plays the On preset; a scene's toggle plays its toggle scene (off) when active | Improved: TOGGLE on an inactive scene in a lit room now plays it (today, by default, it turns the room off), as LV2 als `_4.5-TOGGLEESCENE.md` describes. |
| L68 | The proxy's events fire for every change | Light On and Light Off of a scene device now mean "became active" and "became inactive" (as LV2 als `_3.1`, `_3.2`). Programming written against the room-following events changes behaviour: changelog. |
| L6, L53 | Changes outside Control4 reach the proxy and the LEDs promptly | Improved by `other_active` across overlapping groups, at resync and hello, and from the recall answer. |
| L5 | Report the real state at start and when online | The hello answer also settles "another scene took over" (T14). |
| L55 | A slider move sticks at the level chosen | Met for the switch: B settles at its target. Needs the stale-level fix (5.2) for a second move within a second. |
| L42, L43, L48 | Holds ramp from where they are; bottom held while off does nothing; the toggle button holds toward the other state | Met against the keypad's state (6.3). |
| L49 | Bound buttons' LEDs follow the device | Met with the keypad's state as "the device" for the keypad. |
| L74, L83 | Editable properties have tooltips; settings survive updates | The renamed property gets a tooltip; the migration keeps a stored `This scene`. |
| D11 (section 5) | Departure: a scene has an on state of its own | Its text names "On State Follows"; update to the new rule and name. |

## 8. Recommendations for the contract

1. **The tile follows the scene only.** The scene half (`effective_on`)
   decides the level, the proxy's on and off events, `TOGGLE` and the
   slider's choice. The room's on/off never makes a tile read on (R1).
2. **Keep the on rule** (held from any activation until the room goes
   off, another scene takes over, or the device turns it off). It is what
   keeps a scene lit through Control4's own per-lamp holds, which Hue
   reports as `inactive` (3.2).
3. **End the held state also** when the configure says the scene is gone
   in Hue (T16), and clear the held state, status and level when a
   configure brings a new rid (T17).
4. **`other_active` across overlapping groups.** When a scene or a
   time-based scene becomes active, tell every linked scene whose room or
   zone shares at least one lamp with its group, not only the same group
   (`zone_lights:member_lights`, `src/hue_bridge/bridge/zone_lights.lua:312`;
   a whole-home scene shares every lamp). Keep Decision 10's exception for a
   schedule's own slot scene. Partial overlap counts: the newest scene wins,
   as Hue's own status does.
5. **`other_active` from the recall answer too,** once per activation, as
   the time-based activate already does (`scenes.lua:1729-1733`), so a
   missed event never leaves two tiles lit.
6. **`other_active` at resync and in the hello answer** for a scene whose
   room (or an overlapping one) has another scene `static`,
   `dynamic_palette` or a time-based scene active in the catalogue,
   registered or not (T14, T15). `status.last_recall` could rank the
   scenes of a group [assumed: that it moves on every recall, from any
   source].
7. **The slider on a non-active scene plays it** at the target, over the
   target's rate (5.1); `TOGGLE` plays it too; `OFF` and target 0 still turn
   the room off.
8. **Fix the stale level** (5.2): assume the override's level on the bridge
   after a recall at a level, and hold a target after a recall as designed
   until the first level report (`FOLLOW_MS` at most).
9. **Keypad: option (a)** (6.3). The keypad's own state is the scene half,
   or with `Room/zone lights` also the room on; it drives the LEDs, the
   toggle button's tap, the holds' on/off choice and the bottom tap's fade.
   A hold that dims a room lit by another scene does not hold this scene
   on. With `This scene`, a top hold in a lit room plays the scene at the
   room's current level, not 1 %.
10. **Rename the property to `Keypad Follows`** with the migration of 6.4,
    or keep the name if the owner prefers.
11. **Time-based scenes keep Decision 2:** on exactly while Hue says they
    run; a schedule and its current slot scene can both read on (T12).
12. **Specs.** `tests/spec/scene_driver_spec.lua`: the T table (both
    keypad modes), the slider and TOGGLE switch, the keypad hold that does
    not hold, gone and re-link clearing, the migration (old value, flag,
    later change kept). `tests/spec/scenes_spec.lua`: overlap, recall
    answer, resync and hello `other_active`; the assumed level after an
    override recall.
13. **Docs.** `docs/scene-led-design.md` and `docs/scene-dimmer-design.md`
    get "Superseded" notes; the manual's 9.4, 9.5 and chapter 11;
    `CHANGELOG.md` (the tiles, the events in programming, the renamed
    property); guidelines L64, L9, L19, L66, L68 and D11.
14. **Checks on the house** (each under a minute): another scene played in
    the Hue app (never seen yet); a scene of the Bedside Lights zone over a
    Master Bedroom scene (the room scene's status, and the new
    cross-group `other_active`); an absolute room level on a static scene
    (status kept?); an override recall's status; a slider switch between
    two scene devices; Disconnect and Connect Event Stream with another
    scene played in between (the resync path).

## 9. Open questions for the owner

1. **The keypad.** Keep #310 (a 2-button keypad on a scene shows the
   room's lamps) while the tile follows the scene, option (a)? That gives
   one device two states, which a strict reading of L64 counts as a
   departure Hue does not force, so it needs your say-so. Or have the
   keypad follow the scene too and drop the property, option (b)? With
   (a): rename the property to `Keypad Follows` (with a one-time copy of
   stored values), or keep `On State Follows`?
2. **A lamp changed from outside Control4.** When someone changes one lamp
   of the playing scene in the Hue app or from a Hue Light device, Hue
   says the scene has ended. Keep the scene's tile lit until another scene
   plays or the room goes off (recommended: Hue says the same after
   Control4's own keypad holds, and the device cannot tell the two
   apart), or turn it off?
3. **A schedule and its slot scene.** When a time-based scene plays a
   scene that also has a device (Golden hours playing Shine), both read
   on today, and both are active in Hue. Keep both lit (recommended), or
   light only the schedule?
