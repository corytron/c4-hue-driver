# One wording for the bridge's actions and list rows

Status: contract, 2026-10-28 (#325). Asked for by the tester in #309. The rows and actions grew one feature at a time, so they now say "imported" in one place and "added" in another, and each row lists different counts in a different order.

## 1. Actions

- A single device is added by **Add …** (Add Light, Add Zone Light, Add Scene, Add Motion Sensor, Add Motion Area). Those names stay.
- A bulk add is **Import All New …**: Import All New Lights already exists, and **Add All New Motion Sensors becomes Import All New Motion Sensors**. The Composer action and its command change; no programming depends on actions.
- Add All Scenes Of Room stays: it is scoped to a room, not "all new".

## 2. The list rows (Lights, Scenes, Zone Lights, Motion Sensors)

Every row's summary reads, with every count always present, even 0, and in this order:

`<what is on the bridge> on bridge, N imported, N new, N missing, N unbound, N deleted`

- **What is on the bridge, by row:**
  - Lights: `47 lights`
  - Scenes: `129 scenes + 15 time-based`
  - Zone Lights: `7 zones + 16 rooms`
  - Motion Sensors: `6 sensors + 1 area`, with singular and plural as the counts say. On a bridge without MotionAware it is `6 sensors` and the row ends with `; MotionAware not supported by this bridge`.
- **imported:** Control4 devices the module holds, the one word everywhere ("added" goes).
- **new:** resources on the bridge that are neither imported nor deleted (tombstoned).
- **missing:** imported devices whose Hue resource is gone from the bridge.
- **unbound:** imported devices no longer bound to the bridge.
- **deleted:** devices deleted in Composer and remembered (tombstones).
- **Before the module has read the bridge:** `N imported` alone, as today.

Last Action texts that quote these summaries (Refresh All, Refresh Scenes, Link Devices, …) follow automatically. Every manual text that quotes a row or the renamed action is updated, and so are the specs.

## 3. Files

All by one agent: the four modules' `summary()` functions (`bridge/lights.lua`, `scenes.lua`, `zone_lights.lua`, `motion.lua`) and their specs; the action rename in `src/hue_bridge/driver.xml` and `driver.lua`; the manual (`src/hue_bridge/www/documentation.html`, `src/hue_motion/www/documentation.html`) and `docs/composer-checklist.md`. The coordinator owns CHANGELOG.md, the docs index and this file.
