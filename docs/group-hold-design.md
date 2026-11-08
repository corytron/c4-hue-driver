# Holds on scenes, zone lights and room lights (#249)

Contract for issue #249, part of 1.3 "Kerri" (#398). The agents of this
branch build against this text; the coordinator integrates. Owner's
decision, 2026-11-07: **the mix**, option 3 of the issue.

## 1. The problem

A keypad hold on a Hue Scene device, a zone light or a room light sends one
`dimming_delta` (up or down, `brightness_delta` 100, `dynamics.duration` =
the hold rate) to the group's **grouped_light**, and the release sends
`dimming_delta` `stop`. Measured on the house on 2026-10-25 (#249): on a
grouped_light, Hue **ignores `dynamics.duration`**. It covers the whole delta
in about a second, so the stop comes too late, and the lights jump to full or
off. On a single **light**, Hue honours the duration and the stop (a lamp held
for about 3 s of a 10 s ramp ended near 46 %).

## 2. Decisions

- **G1. One switch point.** `scenes:dim` (`bridge/scenes.lua`) and
  `zone_lights:dim` (`bridge/zone_lights.lua`) keep calling
  `ctx.group_dim(grouped_light_rid, body, level)` exactly as today. The
  driver's `group_dim` hook hands every call to a new module,
  `bridge/group_hold.lua`, which decides how the request reaches Hue.
- **G2. What counts as a hold.** A *start* is a `dimming_delta` with action
  `up` or `down` and a `brightness_delta` of 100, or none. A *stop* is the
  action `stop`. Everything else that comes through `group_dim` passes to the
  group queue exactly as today, with the same fields: for example a scene
  slider's relative move, which has a smaller `brightness_delta`.
- **G3. Lit members decide.** At a start, the module reads the grouped_light's
  member lights (a zone's light children; a room's devices' lights, as
  `zone_lights:member_lights` resolves them) and keeps the members that are
  **on**, according to the driver's cached light state. That set is fixed for
  the whole hold: members that change during it are not re-read.
- **G4. Per-light mode: 1 to `PER_LIGHT_MAX` (10) lit members.** The start
  goes to each lit member through the **light** queue, as a single Hue Light's
  hold does: `{ dim = action, delta = 100, rate = duration }`, in member
  order. The stop goes to each light that got a start in this hold:
  `{ dim = "stop" }`. The result is a smooth ramp at the hold rate that keeps
  the lights' relative levels. The light queue does not hold back a hold's
  start or stop (`commands.urgent`). Starts and stops go out in the same
  order, so each lamp ramps for about the same time. A stop that replaces a
  start still waiting in the queue is harmless: Hue stops a ramp that never
  started. No `level` goes with these stops; each light's own refused-stop
  fallback stays as the light queue already does it.
- **G5. Stepped mode: more than `PER_LIGHT_MAX` lit members.** The start
  sends one group `dimming_delta` step at once, then one step every
  `STEP_MS` (1000 ms, Hue's guidance for groups and the group queue's rate)
  while the button is held:
  - each step is `{ dim = action, delta = step }`, with no `rate`;
  - `step = min(100, 100 * STEP_MS / duration)` percent, so the steps cover
    the whole range in about `duration` ms;
  - a `duration` of 0 gives one step of 100;
  - steps stop when they add up to 100 or at the stop, whichever comes first.

  The stop cancels the step timer and sends nothing more. A group stop would
  only cut short the step already in flight, which finishes Hue's short
  default transition. The result moves visibly in steps, softened by Hue's
  default transition, and keeps the lights' relative levels.
- **G6. No lit member** (an `up` from all off, a group the cache does not
  know, or no members): the start and its stop go to the group queue exactly
  as today, including `rate` and `level`. Nothing gets worse.
- **G7. One hold per grouped_light.** A new start on a grouped_light whose
  hold is still running ends that hold first, as its stop would, then begins.
  A stop with no running hold on that grouped_light passes to the group queue
  as today (harmless). Holds on different grouped_lights are independent.
- **G8. Teardown.** A driver teardown, a pairing change or a queue
  replacement that drops the queues also cancels every step timer. The module
  offers `stop_all()` for that, and the coordinator calls it where the queues
  are torn down.
- **G9. Log lines.** Each hold start logs one info line with the mode and the
  count, for example `group hold 1a2b3c4d up: per-light, 6 lights, 5000 ms` or
  `group hold 1a2b3c4d down: stepped, 14 lights, 20 % a step`. A stop logs at
  debug level.
- **G10. Constants.** `PER_LIGHT_MAX = 10` and `STEP_MS = 1000` are module
  fields, so the specs and a later tuning can change them.

## 3. The module's interface (`bridge/group_hold.lua`)

```lua
local group_hold = require("bridge.group_hold")
local gh = group_hold.new({
	members    = function(grouped_light_rid) return { light_rid, ... } end, -- G3; {} when unknown
	is_on      = function(light_rid) return true|false|nil end,            -- cached state
	light_set  = function(light_rid, fields) return true|false end,       -- light queue :set
	group_set  = function(grouped_light_rid, fields) return true|false end, -- group queue :set
	set_timer  = function(delay_ms, fn) return timer end,                  -- C4:SetTimer; timer:Cancel()
	log        = log,                                                      -- common.log
})
gh:dim(grouped_light_rid, body, level)  --> true when something was queued (the group_dim contract)
gh:stop_all()                           -- G8
```

`dim` takes the arguments `group_dim` takes today and returns what
`group_dim` returns, so the hook becomes one line. The `group_set` fields are
the ones today's hook builds (`dim`, `delta`, `rate`, `level`), so G2 and G6
reach the queue unchanged.

## 4. Who owns which file

| Owner | Files |
| --- | --- |
| Agent **G** (code) | new `src/hue_bridge/bridge/group_hold.lua`; new `tests/spec/group_hold_spec.lua`; a read-only helper in `src/hue_bridge/bridge/zone_lights.lua` (member light rids of a grouped_light, for `members`), if none exists, with its cases in `tests/spec/zone_lights_spec.lua` |
| Agent **D** (docs) | `src/hue_scene/www/documentation.html`, `src/hue_bridge/www/documentation.html` (the zone and room light sections), `docs/keypad-design.md`, `docs/zone-light-design.md` (Decision 6), and any other design note describing group holds, except `docs/design.md` |
| Coordinator | this document; `src/hue_bridge/driver.lua` (the `group_dim` hook and the wiring, after #373 lands, because the driver's main chunk has no room for another local until then); `docs/design.md`, `CHANGELOG.md`, `docs/status.md`, git |

## 5. To verify on the house (not by specs)

- A per-light hold on a zone or room of up to 10 lamps ramps at the hold rate
  and stops where released. Measured on one lamp on 2026-10-25; to measure on
  several.
- A group `dimming_delta` leaves lamps that are off alone [assumed: G3 sends
  per-light dims only to lit members on that basis].
- A stepped hold on a large group moves in steps of the expected size, one a
  second.
