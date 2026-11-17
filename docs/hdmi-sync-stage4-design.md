# 2.0 beta stage 4: programming, the Watch-menu buttons, periods and offers

The coordinator's contract for the last of the four beta stages of #514
(design [`hdmi-sync-design.md`](hdmi-sync-design.md) §5.3 to §5.7, §6, §7,
§8; contracts [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md) C1.3 to
C1.9, C5), issue #568. Every builder works against this text; a change goes
through the coordinator.

Six agents edit disjoint files at the same time (§9). The coordinator
integrates, runs `tools/check.sh` (with the end-to-end run against the fake
box) and `tools/build.sh`, and commits.

## 1. What stage 4 delivers

1. **Programming** (design 5.5; contracts C1.6 to C1.9, exactly as named
   there): the twelve commands, the twelve events (ids fixed), the seven
   conditionals and the nine variables. Variables are set before the event
   that reports their change; no event fires at start for a value that did
   not change.
2. **The four UI Buttons** (design 5.6, O7, O16): Hue Sync toggles sync,
   Sync Brighter and Sync Dimmer step brightness by 10 points, Sync
   Intensity steps Subtle → Moderate → High → Intense → Subtle. Hue Sync's
   icon shows on or off; Sync Intensity's shows the current intensity. The
   icons need `navigator_display_option` in `<capabilities>`: **this is the
   2.0 frame's last capability change**, so this beta's install needs one
   controller reboot from System Manager (the owner's hands), and the frame
   is final from then.
3. **The periods** (design 5.3): Day, Evening and Night with their
   intensity and brightness; Day and Night start at clock times, Evening at
   an offset from the controller's sunset; applied at sync start and at
   each boundary while syncing; a manual change holds until the source
   changes or sync stops.
4. **The offers** (design 5.4, O4, O18): the box's own input switching and
   CEC power behaviours are shown, put on Attention while Control4 routes
   through the box, and turned off or restored only by a click (Sync Box
   Settings), never by themselves.
5. **The entertainment area** (contracts C1.4, C1.6): an Entertainment
   Area property (the box's areas by name) and Set Entertainment Area; a
   re-created area's same-name successor is offered once, never applied by
   itself (design 8).
6. **Take-over** (O12, contracts C5 `STOP_AREA`): when a sync start is
   refused with code 16, the box asks the bridge to stop that area's stream
   and starts its own, firing Sync Taken Over, **except** when the stream is
   another box device of this project (the research's W10 guard): then
   Last Action says so and nothing is taken.
7. **The box's name, two-way** (O14, design 8): as 1.2 decided for lights
   (`docs/simplify-actions-design.md`, the ledger's D6): renaming the device
   in Composer renames the box, and a rename in the Hue Sync app renames the
   device, with the same loop guards. Input names are only shown.

The box gains writes: `execution` (commands, periods), `behavior` (only on
an offer's click), `device.name` (the two-way name) and `hueTarget`.
Never `hue` bridge changes, device actions, IR or presets (the fakes refuse
them; behaviour SB96, SB111).

## 2. Facts to verify (cite the SDK file; never invent)

- `navigator_display_option` and the UI Button proxy's icon states and
  icon files (UIB proxy protocol, FUND 19 icons): exact XML, sizes, file
  layout, how the driver switches state (`SendToProxy` notify names).
- The Scheduler Agent's daily sunset entry
  (`docs-driverworks-api/…/28_scheduler_agent_add_event/_9-AddDailySunsetOffsetEntry.md`):
  whether a protocol driver hears its own entry fire; else compute the
  sunset from the project's location (latitude/longitude through a
  documented call), else a clock time stands in and the property says so
  (contracts C1.4, the existing plan).
- Programming: `<commands>`, `<events>`, `<conditionals>` XML and
  `C4:AddVariable`/`SetVariable`/`FireEventByID`, `TestCondition`.

## 3. Programming (agent A)

`syncbox/programming.lua`: `programming.new{ queue, model_now, periods,
areas, log, set_variable, fire_event, add_variable }`; `p:init()` adds the
nine variables in C1.9's order; `p:command(name, params)` → queue intents
(Apply Sync Settings: each field optional, one PUT; Adjust Brightness
clamped 0–200; Select HDMI Input with its warning in Last Action);
`p:observe(model, prev, cause)` sets variables then fires events (HDMI Input
Changed from any cause; Sync Taken Over only from §8's take-over); `p:test(
conditional, params)` for `TestCondition`; `p:manual(field)` tells periods a
manual change happened. Spec: `tests/spec/syncbox_programming_spec.lua`.

## 4. The periods (agent B)

`syncbox/periods.lua` as contracts C3 sketches it: `periods.new{ timer,
now, settings, sunset, log }`; `p:current(now)`, `p:next_boundary(now)`,
`p:settings_for(period, mode)`, `p:hold(field)`, `p:release(reason)`; the
sunset source per §2 behind one interface (`sunset.today()` → minutes or
nil, with `sunset.source()` for the property text); boundaries armed with
timers that survive a Director restart (re-armed at start; none fires for a
boundary passed while down). The fake runtime gains whatever the sunset
source needs (agent B owns that addition). Spec:
`tests/spec/syncbox_periods_spec.lua`.

## 5. Offers, area and name (agent C)

- `syncbox/offers.lua`: the Sync Box Settings choices (Let Control4 choose
  inputs; Restore the box's input switching) as reversible `PUT /behavior`
  writes per contracts C2's list, plus `cecPowersave` (O18); the previous
  values recorded so Restore puts back exactly what was there; Attention
  text while the box switches by itself and Control4 routes through it.
- `syncbox/areas.lua`: the Entertainment Area list (names from the box's
  `hue.groups`), the choice stored by id with its name, the same-name
  successor offered once.
- `syncbox/names.lua`: the two-way box name with the 1.2 rules.
- Specs: `tests/spec/syncbox_offers_spec.lua`, `syncbox_areas_spec.lua`,
  `syncbox_names_spec.lua`.

## 6. Bridge and link (agent D)

- C5 `STOP_AREA` both ways (`syncbox/link.lua`, `bridge/syncboxes.lua`):
  the bridge stops an area's stream with its own key only for an area that
  exists, and only when the streamer is not a bound box of this project
  that reports itself syncing (W10).
- `HUE_SYNCBOX_HELLO` (and a new `HUE_SYNCBOX_STATE`, box → bridge, when
  its sync state changes) carries `syncing` (`"true"`/`"false"`) so the
  bridge knows which bound box streams, and the label of contracts C7 names
  it reliably.
- The bridge's `driver.lua` wiring is the coordinator's: give the snippets.
- Specs: `tests/spec/syncbox_link_spec.lua`, `syncboxes_spec.lua` (cases
  added).

## 7. The driver (agent E)

`src/hue_syncbox/driver.lua` and `driver.xml`: the commands, events and
conditionals of C1.6 to C1.8 in the XML (ids fixed); the period properties
of C1.4 (Day Starts, Night Starts, Evening Starts, the six intensity and
brightness rows) and Entertainment Area; the Sync Box Settings action with
its offers; the four UI Buttons wired (SELECT on 5002–5005) with
`navigator_display_option` and their icon states; Input Switching on
Attention; the two-way name; the take-over flow. Spec:
`tests/spec/syncbox_driver_spec.lua`, ledger rows. The icons (agent F) are
referenced from `www/icons/`.

## 8. End to end, icons and docs (agent F)

- The icons: the UI Buttons' state icons (Hue Sync on/off, Sync Intensity's
  four levels, Brighter, Dimmer) drawn by `tools/make_icons.py` in the house
  style, sizes per §2.
- `tests/e2e/syncbox_e2e.lua` gains a programming suite against the Python
  fake (commands, events, variables, buttons, periods with a scaled clock,
  offers and Restore, take-over with a second fake app, the name both ways);
  scenarios added where the fakes need them (both pass every one).
- The manual (programming, buttons, periods, offers, area, name, take-over,
  and the reboot this beta needs), `CHANGELOG.md` Unreleased.

## 9. Writers (one per file)

| Agent | Files |
|---|---|
| **A** | new `src/hue_syncbox/syncbox/programming.lua`, `tests/spec/syncbox_programming_spec.lua` |
| **B** | new `src/hue_syncbox/syncbox/periods.lua`, `tests/spec/syncbox_periods_spec.lua`, `tests/helpers/fake_c4.lua` (the sunset-source additions only) |
| **C** | new `src/hue_syncbox/syncbox/offers.lua`, `areas.lua`, `names.lua` and their specs |
| **D** | `src/hue_syncbox/syncbox/link.lua`, `src/hue_bridge/bridge/syncboxes.lua`, `src/hue_bridge/bridge/entertainment.lua` (if the label needs it), their specs |
| **E** | `src/hue_syncbox/driver.lua`, `driver.xml`, `tests/spec/syncbox_driver_spec.lua`, `tests/fixtures/ledger.lua` |
| **F** | `tools/make_icons.py`, `src/hue_syncbox/www/icons/` (generated), `tests/e2e/syncbox_e2e.lua`, `tools/e2e_syncbox.sh`, `tests/helpers/real_url.lua`, `tests/fixtures/syncbox_scenarios.json`, `docs/syncbox-behaviour.md`, `tests/helpers/fake_syncbox.lua`, `tools/fakebox/model.py` (only for new scenarios), `src/hue_syncbox/www/documentation.html`, `CHANGELOG.md` |
| Coordinator | this file, `src/hue_bridge/driver.lua`, `driver.xml`, `tools/build.sh`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, `docs/hdmi-sync-contracts.md`, integration |

## 10. Done

- `tools/check.sh` passes, e2e included; five packages build.
- The capabilities change is limited to `navigator_display_option` for the
  UI Buttons, and the brief for the house install says the owner must reboot
  the controller from System Manager before the buttons' icons work.
- On the house: a dev build against the fake box, programming and buttons
  driven through the Windows session, once the owner has rebooted.
