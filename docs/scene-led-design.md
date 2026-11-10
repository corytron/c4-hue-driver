# A scene device that follows its room or zone's lights: the contract

Issue #310. The owner's report (2026-10-27, house): a Control4 switch runs as
a 2-button keypad, linked to a Hue Scene device's Top and Bottom Button
Links. Recalled from the switch, the scene lights the LEDs. Changed in the
Hue app to another scene, set by hand, or set from a Hue Light device in
Control4, the room's lights are on but the switch shows off. The wish: the
LEDs track the base on/off state of the lights behind the scene, whatever
turned them on.

Today a scene device is on while its scene is active, or held on since it
was (`docs/scene-dimmer-design.md`, the on rule). That rule stays. It
becomes one of two modes.

## Owner's decisions (2026-10-27)

1. A new property on each Hue Scene device, **On State Follows**, chooses
   the mode: `Room/zone lights` (the default, also for existing devices
   after the update) or `This scene` (the on rule as before).
2. In the lights mode, the Navigator tile and slider follow too, not only
   the keypad LEDs: the device has one on state.

## Behaviour

- **The lights mode.** The device is on while its scene is on by the on
  rule, **or** while its Hue room or zone is on: the group's grouped_light
  `on.on`, which Hue sets while any light of the group is on. It is off
  only when both are off. The group's on/off comes from the bridge as
  `HUE_SCENE_GROUP on`. The bridge already sends it after every resync, in
  the answer to the device's hello, and on every change
  (`src/hue_bridge/bridge/scenes.lua`: `send_group_all`, `answer_hello`,
  `on_grouped_light`), so the bridge does not change.
  - The union, rather than the group alone: a recall reports the scene's
    status and the group's on in two messages. With the group alone, the
    tile and the LEDs could blink off between them.
- **The scene mode** is today's behaviour, unchanged.
- **One on state** (decision 2) drives everything the device reports:
  - the tile's level (0 while off, the group's level while on);
  - the keypad LEDs (`MATCH_LED_STATE`, `BUTTON_INFO`);
  - the proxy's on and off events;
  - and the choices the device makes from its own state:
    - TOGGLE turns the room or zone off while it shows on;
    - the slider moves the group's level while it shows on, and plays the
      scene at that level while it shows off;
    - a keypad hold dims the group up or down while it shows on, and from
      off the top button plays the scene at 1 % and brightens.
  - What the commands do is unchanged: ON and a tap on top play the scene;
    OFF and a tap on bottom turn the room or zone off.
- **Not persisted.** The group's on/off is not kept across a restart: the
  bridge sends it again with its answer to the device's hello. Until then
  the on rule's persisted `held_on` and the scene's status decide, as
  today.

## Lifecycle cases

| Case | In the lights mode |
| --- | --- |
| The scene recalled from Control4, a keypad or the Hue app | On (as today). |
| Another scene of the same room or zone recalled (Control4, Hue app, Hue switch) | Stays on: the room's lights are on. Today: off. |
| A light of the room turned on by hand, from the Hue app, a Hue switch, a Hue automation or a Hue Light device in Control4 | On. |
| The room or zone turned off from anywhere | Off. Hue reports the group off. The held state ends as today. |
| Some lights of the room off, others on | On, while any is on. |
| A zone overlapping a room | Each scene follows its own group. A zone scene is on while any light of the zone is on. |
| Two scene devices of the same room on one keypad | Both show on together. Pick `This scene` on those devices to show which scene plays. |
| A time-based scene | The same union, with its own rule (on while Hue runs it) as the scene half. |
| A whole-home scene (no room) | No group on/off arrives, so the scene half alone decides, as today. |
| An empty zone (no grouped_light) | The same: no group on/off arrives. |
| The bridge offline, the stream down | The last known state stays. The resync after reconnecting sends the group's on/off. |
| Controller or Director restart | The scene half from `held_on` at once, then the group half from the bridge's hello answer. |
| The scene forgotten or deleted in Hue | No more group messages. The last state stays until the device is linked again or deleted (as today for the scene half). |
| The device re-linked to another scene (a new rid by configure) | The group half is cleared, then refilled by the next group message for the new scene. |
| The property changed in Composer | Applied at once: the tile and the LEDs report the new state when it differs. |
| Updating from a build without the property | Director has no value, and the driver's default `Room/zone lights` applies. This changes existing scene keypads, so it goes in the changelog and the release notes. |

Nothing here acts on the system by itself: the mode changes only what the
device shows and which way a toggle or hold goes. So there is no automatic,
offered or forbidden split to make.

## Code

- `src/hue_scene/driver.xml`: the property `On State Follows`, a LIST with
  the items `Room/zone lights` and `This scene`, default `Room/zone lights`.
- `src/hue_scene/driver.lua`:
  - `group_on` (nil, true, false) is taken from `HUE_SCENE_GROUP on`, and
    cleared when a configure changes the rid.
  - `follow_lights` is set from the property.
  - `shown_on()` is `effective_on() or (follow_lights and group_on == true)`.
    `brightness()`, `dev.is_on()`, TOGGLE, the slider's off/on choice and
    the level reports use it. `effective_on()` stays the scene half: the
    held state, the recalled level and the time-based scene's follow.
  - A group message, or a property change, that changes what the tile shows
    reports it.
- `tests/spec/scene_driver_spec.lua`:
  - the existing cases load with `This scene`, the behaviour they pin;
  - new cases pin the lights mode (the table above) and the switch between
    modes.
- Manual (`src/hue_bridge/www/documentation.html`): 9.4 "When the tile
  reads on", 9.5 the new row, and chapter 11's scene keypad paragraph.
