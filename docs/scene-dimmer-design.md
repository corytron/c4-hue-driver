# Hue Scene as a dimmer, kept in sync: the contract

Owner-approved 2026-10-23 ("Approved as proposed, including the new on
rule"). Builds on `docs/keypad-design.md` (scene hold-to-dim, keypad LEDs,
`HUE_SCENE_GROUP`, the queue's `dim` field). Problem: the Shine scene
device shows only an on/off toggle in the iPhone app; the owner wants a
slider with the current percentage, and the app, the keypad LEDs and the
Hue app all in sync.

## Behaviour

- **Dimmer.** `hue_scene/driver.xml` declares `dimmer` True and `set_level`
  True (with `supports_target` True as now), so Navigators show a slider.
- **The level shown** is the scene's room/zone brightness as Hue reports it
  for its grouped_light (`dimming.brightness`, the average of the lights
  that are on), rounded and clamped to 1–100 while the scene is on; 0 while
  off; 100 while on but no level is known yet.
- **The on rule (new).** The scene is on from the moment it becomes active
  (recalled from Control4, from a keypad, or from the Hue app: any
  `HUE_SCENE_STATE` static / dynamic_palette) until its group turns off
  (`HUE_SCENE_GROUP on=false`, from anywhere), another scene of the same
  group becomes active (`other_active`), or this device turns it off. Hue
  calling the scene inactive afterwards (because something dimmed or
  changed its lights) does **not** turn it off. This generalises the
  keypad contract's `dimmed_on`; the flag is renamed `held_on`, persisted
  (`PersistSetValue("held_on")`) so it survives a restart, and dropped at
  the first `HUE_SCENE_GROUP on=false` after a restart.
- **Slider / SET_BRIGHTNESS_TARGET {LIGHT_BRIGHTNESS_TARGET, RATE}:**
  target 0 → off (as OFF, with the rate); target > 0 while off → recall
  with `brightness = target` and `duration = RATE`; target > 0 while on →
  `HUE_SCENE_LEVEL {rid, device_id, level = target, rate = RATE}`. The
  proxy gets `LIGHT_BRIGHTNESS_CHANGING {current, target, RATE}` at once
  and `LIGHT_BRIGHTNESS_CHANGED` when the bridge's level report arrives,
  or the target after RATE + 1 s (the existing fallback pattern).
  SET_LEVEL / RAMP_TO_LEVEL map to the same path.
- **Keypad holds** report `LIGHT_BRIGHTNESS_CHANGING {current, target 100
  or 1, RATE = duration}` at the start and settle on the level reports.
- **Level reports to the proxy are throttled on the device** to one
  `LIGHT_BRIGHTNESS_CHANGED` per second, the latest value sent when the
  second ends, so a ramp does not flood Navigators.
- **LEDs** follow the on state (unchanged mechanism from the keypad
  contract).
- **Hue Light devices** already follow Hue-app changes (`HUE_STATE`), and
  their LEDs follow on/off; a spec pins the LED update on a Hue-side change.

## Messages

| Message | Direction | Params (strings) | Meaning |
|---|---|---|---|
| `HUE_SCENE_GROUP` | bridge → scene | adds `level` (number 0–100, may carry decimals) | The group's `dimming.brightness`, sent with `on` at every resync and whenever an event changes it. Every key optional; a device uses what is there. |
| `HUE_SCENE_LEVEL` | scene → bridge | `rid`, `device_id`, `level` (1–100), `rate` (ms) | Move the scene's group to `level` while keeping its lights' differences: `dimming_delta` up/down with `brightness_delta = |level − current|` and `dynamics.duration = rate`, where current is the bridge's last known group level; nothing if the difference is under 0.5; when no level is known, an absolute grouped_light `dimming.brightness = level` with the rate instead. |
| `HUE_SCENE_RECALL` | scene → bridge | `brightness`, `duration` (existing) | Used by the slider from off. |

## Bridge (`src/hue_bridge/bridge/scenes.lua`, bridge agent)

- `group_level` is already kept (resync GET and grouped_light events).
  Send `HUE_SCENE_GROUP {rid, level}` to the group's linked scene devices
  when an event changes it (skip when equal to the last sent), and include
  `level` with `on` in the post-resync send.
- `scenes:level(params)`: resolve like `dim`; compute as in the table;
  call `ctx.group_dim(grouped, { dimming_delta = { action = "up"|"down",
  brightness_delta = d }, dynamics = { duration = rate } })` or
  `ctx.group_set(grouped, { brightness = level, rate = rate })`; return
  true when queued.

## Coordinator

- `commands.lua`: the `dim` field takes an optional `delta` (1–100,
  default 100) for `brightness_delta`.
- `driver.lua`: `group_dim` passes `brightness_delta` as `delta`;
  new `ctx.group_set(rid, fields)` → `state.group_queue:set(rid, fields)`;
  `dispatch.commands["HUE_SCENE_LEVEL"]` → `state.scenes:level(params)`.
- `hue_scene/driver.xml`: `dimmer`, `set_level` True. Capability change:
  the install needs a controller reboot (Composer's "Restart Director?"
  does not restart Director; `docs/keypad-design.md`).

## Scene device (`src/hue_scene/driver.lua`, device agent)

Everything under Behaviour above, plus specs: slider while on sends
`HUE_SCENE_LEVEL`; from off recalls with brightness; to 0 turns off; level
reports update the tile and are throttled; Hue reporting inactive after a
Hue-app dim keeps the tile on at the new level; group off and other scene
active turn it off; `held_on` survives a restart and is dropped by a group
off; hold reports CHANGING. Light: a spec that a Hue-side `HUE_STATE` off
sends `MATCH_LED_STATE` false on the three links.
