# Lifecycle and keypad refactors (contract)

Issues #56 (one lifecycle base for the three registry-owning bridge modules)
and #57 (`common/device.lua` Stage B: one keypad state machine for both device
drivers). Branch `refactor/lifecycle-keypad-56-57`, stacked on
`fix/review-leftovers-43-65` (PR #214) because it refactors the code that PR
hardened; it is rebased on `main` once #214 merges. One PR.

## Rules (both)

1. **No owner-visible change.** No property text, Last Action or Attention
   text, log line meant for the owner, message name, message parameter or
   message order changes. The specs assert message sequences: every existing
   spec stays green **without edits**. If a spec must change, it is because
   it reached into a private function that moved; say which and why, and
   prefer a thin compatibility shim over a spec edit.
   Current (2026-10-25, build 316): #217, after this refactor, changed the
   names on purpose: every Hue name handed to Control4 is a
   `util.display_name`, and the comparisons and name matches run both sides
   through it (`bridge/owner.lua:new_device_name`, `name_differences`,
   `match_unimported_by_name`).
2. **Divergences settled first.** Where the copies differ today, list each
   difference before merging them, decide (keep the behaviour each module
   has now, behind a hook or an option), and say so in a comment.
3. **Step by step, green after each step.** Text builders first, then flows
   (#56); the hooks first, then the machine (#57). Run `busted tests` after
   every step; report the step list with the spec count after each.
4. `registry.valid_rid` and `entry_for_command` are not widened. Lua 5.1,
   tabs, `.luacheckrc`, the fake C4 runtime; no new `require` outside
   `src/`; placeholders only.

## #56: `bridge/owner.lua`

`scenes.lua`, `zone_lights.lua` and `lights.lua` share one lifecycle module,
`src/hue_bridge/bridge/owner.lua`, as plain functions taking `self` or a
mixin (`docs/reviews/slim-scenes-zones.md` §4 Q7: either; pick one and say
why). In scope: `send_configure` / `configure_changed`, `push`,
`configure_all`, `clear_conflicts_for`, `hello`, `goodbye`,
`on_binding_changed`, `reconcile` (row 15); the names trio `expected_name`,
`name_differences`, `adopt_hue_names`, `accept_names` (row 12); Attention
items (13); busy and pending flags with the 90 s expiry (14); room
resolution (16); the relink/forget pickers (17); device creation (18); and,
at high risk, `link_devices` / `match_unimported_by_name` (25) and `relink`
/ `forget` (26). What differs between modules becomes `self.WORDS`,
`self.MESSAGES` and hooks (`announce_gone`, `answer_hello`, the "gone" rule,
lights' `tell()` / `foreign()`). Rows 25–26 are done last and only if rows
12–18 are green; if a high-risk row cannot be merged without a behaviour
change, leave it per module and say why.

Current (2026-10-25, build 316): a mixin (each module sets
`setmetatable(module, { __index = owner })`; the reason, and every
divergence with the option, word or hook it became, are in the header of
`bridge/owner.lua`); `self.OPTIONS` holds the divergences that are a yes or
a no; rows 25 and 26 were merged as well (`owner:link_devices`,
`match_unimported_by_name`, `relink`, `forget`).

Also (found while hardening, `docs/review-leftovers-design.md` §5), so the
three modules behave alike once they share the base: zone lights answer
every waiting resync caller once (as lights and scenes now do); a zone
deleted in Hue while its AddDevice is pending is marked gone (as lights
now do); zone lights pass a field schema to the registry (as lights now
do); and `refresh_registry` can clear a field whose value became nil
(analysis R9; a spec shows a stale field cleared). These four are the only
intended behaviour changes of the refactor; each gets a spec.

Current (2026-10-25, build 316): all four are in (`bridge/owner.lua:resync`,
`run_pending_resync`; `added` with `zone_lights.OPTIONS.gone_after_add`;
`zone_lights.ENTRY_FIELDS`; `refresh_fields` with each module's
`REFRESH_CLEARS`). Left per module on purpose: the scenes keep no
early-hello cap, no R5, no R11 for hellos and no field schema, and the zone
lights mark a deleted zone gone at the AddDevice answer but not at a later
hello.

Also on this branch, found on the house and not part of the refactor
(Composer rounds 41 and 42, `docs/keypad-design.md`): the keypad settings
are answered with the notification the proxy stores, as a bare value, at
late init and after every `SET_*`; a value out of range is refused, from
the proxy and when persisted (a persisted one is deleted and the default
used); and the light's one-time colour-parameter log line is gone (D.10
answered).

Done: the three modules on the base, every existing spec green unchanged
(or a shim and a reason), the line counts before and after recorded in
`docs/reviews/slim-scenes-zones.md`.

## #57: one keypad state machine

`src/common/device.lua` takes the press/click/release state machine
(`settings`, `hold`, `guard`, `button_action`, `BUTTON_ACTION`,
`link_button`, `DO_PUSH` / `DO_RELEASE` / `DO_CLICK`, `SET_*_RATE`) with
hooks `on_click`, `on_hold`, `on_finish`, `on_end_hold`; the four places the
two drivers' machines differ become those hooks (the scene's `end_hold` also
cancels a time-based scene's `follow`). The one log line that drifts
(`docs/reviews/slim-device-drivers.md` Q7) keeps each driver's current text.
The keypad behaviour verified on the house (`docs/keypad-design.md`) is the
reference: taps, holds, LEDs on a light and on a scene.

Done: one machine in `device.lua`, `light_driver_spec`,
`scene_driver_spec`, `scene_roundtrip_spec`, `zone_light_roundtrip_spec`
green unchanged; line counts recorded in `docs/reviews/slim-device-drivers.md`.

## Files and owners

| Owner | Files |
| --- | --- |
| **lifecycle** (#56) | `src/hue_bridge/bridge/owner.lua` (new), `lights.lua`, `scenes.lua`, `zone_lights.lua`, `registry.lua`; `tests/spec/owner_spec.lua` (new), the specs of those modules only if rule 1 allows; `docs/reviews/slim-scenes-zones.md`, `docs/reviews/slim-lights.md` |
| **keypad** (#57) | `src/common/device.lua`, `src/hue_light/driver.lua`, `src/hue_scene/driver.lua`; `tests/spec/device_spec.lua` (new specs for the shared machine); `docs/reviews/slim-device-drivers.md` |
| **coordinator** | everything else, this file, integration, commits |

Verification before merge: `tools/check.sh --strict`, `tools/build.sh`, and a
dev-build regression pass on the house (`tools/regress.sh`, plus keypad taps
and holds through the dev loop's Proxy Command) before the release install.
