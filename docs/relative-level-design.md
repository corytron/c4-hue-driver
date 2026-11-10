# Raise Level By and Restore Saved Level

Status: contract, 2026-10-26 (#297). Owner's request: when motion is sensed,
raise two lamps by 30 points over their current level; 5 minutes after motion
stops, return them to their original level. Control4 programming decides
when (the north star of #280); the Hue Light driver supplies two primitives
that stock programming lacks. Owner's choices: +N points (not × 1.N), and
driver commands (not variable arithmetic in Composer).

## 1. The commands (Hue Light devices: lights, zone lights and room lights)

Programming commands in `src/hue_light/driver.xml` `<commands>`, which Composer
lists under the device in Programming. Ids and names never change once
released:

| Command | Params | Does |
| --- | --- | --- |
| `Raise Level By` | `Points`: RANGED_INTEGER 1–100, default 30; `Ramp (ms)`: RANGED_INTEGER 0–60000, default 1000 | If no level is saved: saves the current level (0 when off) and the time. Then sets the level to min(100, saved + Points) with that ramp. A second Raise while a level is saved raises from the **saved** level again (idempotent: the lamp never climbs). If the lamp stands neither at the last Raise's target nor at the saved level (someone changed it since), that level is the new starting point: the old saved level is dropped and the current one saved, so a Raise never lowers a lamp turned up by hand. |
| `Restore Saved Level` | `Ramp (ms)`: as above | If a level is saved and the lamp still stands at the level the last Raise set (within 1 point; the light's reported level): ramps back to the saved level (off when it was 0) and forgets it. If someone changed the lamp since (any other level, or off): leaves the lamp alone and forgets the saved level. With nothing saved: does nothing. |

Every outcome writes one line to `Last Action` (for example "Raised from 40 %
to 70 % (saved 40 %)", "Restored to 40 %", "Not restored: changed to 55 % since
the raise; saved level forgotten", "Nothing to restore").

## 2. Rules

- The saved level and the raised target persist (`PersistSetValue`) across a
  driver restart or update; a Director restart in between keeps them.
- Raise and Restore go through the device's normal command path to the
  bridge (the same messages as the slider), so queueing, coalescing and the
  bridge's rate limits apply unchanged.
- A device the bridge marks gone or unbound refuses both, saying so in
  `Last Action`, and keeps the saved level.
- No change to the light_v2 proxy, its `<capabilities>` or its connections:
  no reboot.
- Never automatic: only programming (or Composer's command list) calls them.

## 3. The house setup (owner, 2026-10-26)

- The motion device (the MotionAware area) gets `Occupancy Hold Time (s)` =
  300, so "stops sensing motion" fires 5 minutes after the last motion.
- When it senses motion: both Foyer lamps `Raise Level By` 30.
- When it stops sensing motion: both `Restore Saved Level`.

## 4. Files

| Files | Owner |
| --- | --- |
| `src/hue_light/driver.lua`, `src/hue_light/driver.xml`, `tests/spec/light_driver_spec.lua` (or a new `tests/spec/light_relative_level_spec.lua`) | agent **light** |
| `src/hue_light/www/documentation.html`, the Hue Light chapter of `src/hue_bridge/www/documentation.html` (a short section and the quick reference), `docs/composer-checklist.md` (a step for the house setup above) | agent **docs** |
| `CHANGELOG.md`, `docs/README.md`, this file | coordinator |
