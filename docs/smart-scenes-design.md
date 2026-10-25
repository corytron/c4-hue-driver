# Time-of-day ("smart") scenes as Hue Scene devices: the contract

Owner-approved 2026-10-24 (seven answers in `docs/smart-scenes-research.md`
§6; checks on the house bridge in §7; the research draft §2–§3 is the
background and holds unless this page says otherwise). Hue's time-based
scenes ("Golden hours", "Natural light"; CLIP v2 `smart_scene`) become
ordinary Hue Scene devices with a kind, listed in Add Scene and Add All
Scenes Of Room, playable from tiles, keypads, programming and the slider.

## Decisions

1. **Same driver, a kind.** `hue_scene.c4z` serves both; the registry entry
   carries `kind` (`"smart_scene"`; absent = ordinary scene); the device
   persists `hue_kind` beside `hue_rid` and sends it in its hello. No
   `driver.xml` change (no reboot on install).
2. **On state of a smart device = Hue's state.** `state` "active" is on,
   "inactive" off. Verified: a whole-room dim (relative or absolute) leaves
   it active (V11); group off, deactivate, another smart scene over the same
   lights and an ordinary scene of the group all make it inactive, each with
   an event (V7, V9, V10, V11). So smart devices do **not** use `held_on`
   (that rule stays for ordinary scenes).
3. **ON** (tile, keypad tap top, programming, SET_BRIGHTNESS_TARGET 100 from
   off): `HUE_SCENE_RECALL`; the bridge sends `{"recall":{"action":
   "activate"}}` for a smart entry whatever the action, and ignores
   `duration` and `brightness` (debug line). Fallback after 2 s assumes on.
4. **Slider from off to a level below 100** and **hold top while off**:
   activate first, then move the room relative to where the slot puts it —
   the slider sends `HUE_SCENE_LEVEL {level}` and a hold sends
   `HUE_SCENE_DIM up` (while still held) once the bridge reports the group
   on with a level, or after 1.5 s at the latest (owner's answer 5: start,
   then brighten; the schedule keeps running through a dim, V11).
5. **OFF** (tile, tap bottom, slider 0, programming): the bridge PUTs
   `{"recall":{"action":"deactivate"}}`, then turns the group off through
   the existing group queue (owner's answer 3; deactivate alone leaves the
   lights on, V7). STATE inactive follows from the events.
   Current (2026-10-25, build 316): the bridge also sends STATE inactive
   (reason `recall`) itself once the deactivate or the group off has gone
   through, the cached state when neither did
   (`src/hue_bridge/bridge/scenes.lua:deactivate`).
6. **Dims and the slider while running**: unchanged (`HUE_SCENE_DIM`,
   `HUE_SCENE_LEVEL` on the group). The next time slot's look replaces the
   dimmed level when it starts (Hue's behaviour; whether a slot advances
   after a dim is checked at 16:00 on 2026-10-24, research §7).
   Checked (2026-10-24 16:00, build 199, research §7): a running app-made
   schedule advanced to its 16:00 slot and the device showed it within
   two minutes; whether the room had been dimmed before is not known, so
   a dim before a boundary stays open (#40).
7. **Names drop the app's number** (owner's answer 4): base name =
   `metadata.name` without a trailing " <digits>" ("Golden hours 4" →
   "Golden hours"). Device name at creation: room → base name; zone →
   "<Zone> <base name>" (as ordinary zone scenes). `Adopt Hue Name`,
   Attention's name differences and the expected name use the same rule.
8. **Picker** (`SceneList` of Add Scene, and Re-link Scene): a smart scene is
   "<group label>: <base name> (time-based)", listed before the ordinary
   scenes of the same group; an ordinary scene that a smart scene's slot
   targets is marked "<group label>: <name> (in <base name>[, <base
   name>…])" (owner's answer 6). `SceneGroupList` counts both:
   "Downstairs (zone) → (unmapped) (16 scenes, 2 time-based)".
9. **Add All Scenes Of Room includes** the group's smart scenes (owner's
   answer 2), created after its ordinary scenes, each with its kind.
10. **`other_active`**: when a smart scene becomes active, every other linked
    device of its group gets `HUE_SCENE_GROUP other_active` (ordinary ones
    end their `held_on`). When an ordinary scene becomes static or dynamic,
    the existing rule applies, except that a smart device whose current
    slot targets that scene is not told (the slot scene starting is the
    schedule itself).
11. **Lifecycle**: a smart scene deleted in Hue (also what Hue does when one
    of its slot scenes is deleted, V14) → entry `gone`, same texts and
    actions as ordinary scenes; created in the app → listed (it arrives
    already active, V12); renamed or re-timed (V13) → registry name, slots
    and Status refreshed, Attention name difference as for scenes. A failed
    `/smart_scene` GET keeps the previous catalogue and marks nothing gone.
12. **Recall As** is hidden on smart devices with
    `C4:SetPropertyAttribs("Recall As", 1)` after late init and shown with
    `0` on ordinary ones [verified: SDK 24_properties/_4]. Re-link across
    kinds is allowed; CONFIGURE carries the new kind and the device re-runs
    this.
    Not yet seen on the house: `Recall As` shown again on an ordinary
    device after a re-link from a time-based one (#40).
13. **Status** of a smart device: "Hue time-based scene <base name> in
    <group label>; now <slot scene name> (from <07:00 | sunset>)" while
    active, "…; not running" while inactive.
    Current (2026-10-25, build 316): "…; running" while the slot is not
    known, the first part alone before any state, and "(no room)" without
    a group label (`src/hue_scene/driver.lua:smart_status`).
14. **Summary**: the bridge's `Scenes` line counts both: "126 scenes and 15
    time-based on bridge, …" (the other fields unchanged, counting devices
    of both kinds).
    Current (2026-10-25, build 316): it reads "<n> + <m> time-based on
    bridge, <k> imported, <d> deleted", "?" for the time-based count until
    a `/smart_scene` GET has succeeded, "N missing" and "N unbound" only
    when not zero (`src/hue_bridge/bridge/scenes.lua:summary`).

## Messages (strings; additions to `docs/scenes-design.md` §2)

| Message | Change |
|---|---|
| `HUE_SCENE_CONFIGURE` | + `kind` ("scene" / "smart_scene"); smart: + `slot_name`, `slot_start` ("07:00" / "sunset") when known; `auto_dynamic` "false" |
| `HUE_SCENE_STATE` | smart: `active` = "active" / "inactive"; + `slot_name`, `slot_start` when known |
| `HUE_SCENE_HELLO` | + `kind` (device → bridge) |
| `HUE_SCENE_RECALL`, `HUE_SCENE_OFF`, `HUE_SCENE_DIM`, `HUE_SCENE_LEVEL`, `HUE_SCENE_GROUP` | names unchanged; behaviour per Decisions 3–6, 10 |

## Interfaces

- `hue_model.lua` (model agent): `hue_model.smart_scene(item)` → `{ rid,
  name, base_name, group_rid, group_type, state ("active"/"inactive"),
  slot_id, slot_weekday, slots = { { days = {..}, start = "07:00" |
  "sunset", target_rid } }, transition_duration }` or nil for a malformed
  item; `hue_model.update_smart_scene(model, item)` applies an update item
  and returns a table of changed field names (or nil);
  `hue_model.base_name(name)` strips one trailing " <digits>";
  `hue_model.current_slot(model)` → the slot table for (slot_weekday,
  slot_id) or nil. `smart_scene_count` was removed on 2026-10-24 (unused).
- `bridge/scenes.lua` (scenes agent): everything in Decisions 2–14 on the
  bridge side, using the model functions above; tests use the fixtures
  `F.smart_scenes`, `F.smart_scene_rids`, `F.smart_scene_items` and
  `F.events.smart_*` in `tests/fixtures/hue_resources.lua`.
- `hue_scene/driver.lua` (device agent): kind, Decisions 2–6, 12, 13 on the
  device side, `hue_kind` persistence, hello with kind.
- Coordinator: `hue_bridge/driver.lua` (nothing new expected; check the
  routing), the manual, `docs/status.md`, the build and install.
