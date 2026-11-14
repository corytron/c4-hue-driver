# Scene devices follow their own scene and stay in their room: the contract

Issue #469, PR #470. The owner's report (2026-11-12, house): with several
Hue Scene devices in one Control4 room, dimming one of them in the iPhone
app made every scene device of the room show the same level. Lights and
zone lights should do that; scenes should not, because nobody can tell
which scene is on. The owner asked for four things:

1. A scene's tile shows a level only while that scene is the active one.
   While a scene with no Control4 device is active, or none is, no scene
   tile of the room shows a level.
2. Moving a scene's slider switches the room to that scene at once.
3. A Control4 room only holds scene devices for scenes of the Hue room or
   zone that maps to it.
4. A wrong or missing mapping is handled gracefully and plainly.

Research: [`scene-tracking-research.md`](scene-tracking-research.md) (the
"T" cases, section 5's command table, section 6's keypad options) and
[`scene-rooms-research.md`](scene-rooms-research.md) (the rule of 4.1, the
C, H and M cases, the surfaces of section 6). This contract decides; where
it differs from a research recommendation it says so.

This contract supersedes the "one on state" of
[`scene-led-design.md`](scene-led-design.md) (decision 2 there) and the
room choice of [`scenes-design.md`](scenes-design.md) §1 for explicit
rooms. The on rule of [`scene-dimmer-design.md`](scene-dimmer-design.md)
stays.

## Owner's decisions (2026-11-12)

- **O1. The keypad keeps the room.** The tile follows the scene. What a
  keypad bound to the scene treats as on keeps following the room's
  lights by default (#310's wish for the bedroom switch). The property
  chooses only the keypad and is renamed **Keypad Follows**. Under
  guideline L64 one device with two states is a departure Hue does not
  force, so it is the owner's exception: departure **D20**.
- **O2. A changed lamp keeps the scene lit.** When one lamp of the playing
  scene changes from outside (Hue app, Hue Light device, Hue switch), the
  tile stays on at the room's level until another scene plays or the room
  goes off. This is the existing on rule. Hue says the same after
  Control4's own keypad holds, and the device cannot tell the two apart.
- **O3. An unmapped Hue room is refused.** An add with an explicit Control4
  room, for a scene whose Hue room or zone has no mapping, is refused. The
  refusal names Set Room Mapping. (The research recommended mapping it on
  the click; the owner chose refusing.)
- **O4. No one-to-many.** Each Hue room or zone's scenes go into exactly
  one Control4 room: the one it maps to. There is no escape hatch: no
  "(no mapping) means any room" (the research's 4.3.1) and no list of
  extra rooms. Several Hue rooms or zones may still map to one Control4
  room (many-to-one).

Defaults taken from the research, not asked:

- **O5.** Link Device refuses a scene of a group mapped to another room,
  with the same-group exemption (rooms research question 2).
- **O6.** A room or zone made again under its old name and type after a
  deletion or a bridge reset is **offered** its old mapping, never given it
  by itself (rooms research question 4).
- **O7.** A schedule (time-based scene) and the slot scene it is playing
  both read on (tracking research question 3, T12).

## Part 1: what the tile follows

### Decisions

- **D1. The tile follows the scene alone.** The scene half,
  `effective_on()` (the status, the held state, a time-based scene's own
  rule), decides:
  - the level (`LIGHT_BRIGHTNESS_CHANGED`);
  - the proxy's on and off events;
  - TOGGLE from the proxy;
  - the slider's choice between recalling and moving.

  The room's on/off (`group_on`) never makes the tile read on. The room's
  level is still the level shown while the scene is on.
- **D2. The on rule stays** ([`scene-dimmer-design.md`](scene-dimmer-design.md)
  "The on rule"): held on from any activation until the room goes off,
  another scene takes over (`other_active`), or this device turns it off.
  O2 keeps it through outside lamp changes.
- **D3. Gone and re-linked.**
  - A configure that says this device's scene is gone in Hue ends the held
    state at once, so the tile reads 0 (T16).
  - A configure that brings a new rid clears the held state, the status,
    the cached level and `group_on`. The tile then shows nothing until the
    bridge reports the new scene (T17).
- **D4. Commands on a scene that is not the active one** (tracking
  research 5.1, "Recommended"):
  - **The slider.** `SET_BRIGHTNESS_TARGET` from 1 to 99 recalls this scene
    with `dimming.brightness` = target and `duration` = the target's RATE.
    A target of 100 recalls it as designed.
  - `SET_LEVEL` and `RAMP_TO_LEVEL` take the same path, with `TIME` as the
    rate.
  - **ON, DYNAMIC_ON and TOGGLE** recall it as designed.
  - **OFF, DYNAMIC_OFF and a target of 0** still turn the room or zone off
    (unchanged).

  The Navigator slider sends RATE 0, so the switch is immediate. Once the
  recall is confirmed, this scene is the active one, and its next targets
  move the room's level as today.
- **D5. Slider spam** is handled as today. While a recall is unconfirmed,
  each new target recalls again at the new level, and the bridge
  coalesces recalls of one scene within `RECALL_WINDOW_MS`.
- **D6. The stale level after a switch** (tracking research 5.2):
  - **On the bridge.** After a recall at a level T, `group_level` is
    assumed to be T until Hue reports. `level_before` is kept, as
    `scenes:level` does, so an undelivered recall restores it.
  - **On the device.** After a recall as designed (no level), a target that
    arrives before the first level report since the recall waits for that
    report, at most `FOLLOW_MS`, as a starting time-based scene's does.
    Only the latest waiting target is kept.
- **D7. `other_active` reaches every scene that lost** (tracking research
  recommendations 4 to 6). When a scene or a time-based scene becomes
  active, the bridge sends `HUE_SCENE_GROUP {rid, other_active = "true"}`
  to every linked scene whose room or zone shares at least one lamp with
  the active scene's group. Today only scenes of the same group are told.
  - A whole-home scene shares every lamp.
  - The exception of `smart-scenes-design.md` Decision 10 stays: a
    schedule's own slot scene is not told (O7).
  - It is sent at three moments:
    - on the Hue event, as today, extended to overlapping groups;
    - from a successful recall answer, once per activation, as the
      time-based activate already does;
    - at every resync and in the answer to a device's hello, for a linked
      scene that is not active while another scene of its group, or of an
      overlapping group, is active in the catalogue. This covers a scene
      that has a device and one that has none.

  An active time-based scene counts as active.
- **D8. Time-based scenes** keep Decision 2 of
  [`smart-scenes-design.md`](smart-scenes-design.md): on exactly while Hue
  says they run.

### The keypad (O1)

- **D9. The keypad's own state.** `keypad_on()` is the scene half, or, with
  Keypad Follows = `Room/zone lights`, the scene half or `group_on == true`.
  It drives:
  - the LEDs (`dev.is_on()` as `common/device.lua` reads it for
    `MATCH_LED_STATE` and `BUTTON_INFO`);
  - the toggle button's tap and hold direction;
  - whether a top or bottom hold dims the lit room;
  - whether a bottom tap fades over the click-down share of the room's
    level, which keeps #421's tap stop working.

  `dev.is_on()` keeps its ramp rule (#421 D10).
- **D10. Taps and holds with Keypad Follows = `Room/zone lights`** while
  another scene lights the room:
  - a top tap plays this scene;
  - a bottom tap turns the room off over the click-down share;
  - a top or bottom hold dims the room from where it is, and does **not**
    make this scene active or held. The tile stays 0.
- **D11. Taps and holds with Keypad Follows = `This scene`** while another
  scene lights the room:
  - a top tap plays this scene;
  - a top hold plays this scene at the room's current level (not 1 %),
    then brightens;
  - a bottom hold does nothing (L43);
  - a bottom tap turns the room off.
- **D12. The property is renamed, and its value carries over.**
  - `driver.xml` declares **Keypad Follows** (LIST `Room/zone lights`,
    `This scene`, default `Room/zone lights`).
  - It keeps **On State Follows** declared until 2.0. The driver hides it
    at late init with `C4:SetPropertyAttribs("On State Follows", 1)`, as it
    hides Recall As.
  - **Migration**, once, at late init, when PersistData has no
    `keypad_follows_migrated`:
    - if `Properties["On State Follows"]` is `This scene`, the driver
      writes it to Keypad Follows with
      `C4:UpdateProperty("Keypad Follows", "This scene")`;
    - it applies the value itself, since UpdateProperty does not call
      `OnPropertyChanged`;
    - then it persists the flag.

    A later change by the dealer is never overwritten.
  - A change to the hidden On State Follows does nothing.

  [verified: API `24_properties/_4-SetPropertyAttribs.md`,
  `_5-UpdateProperty.md`, `_3-OnPropertyChanged.md`; the scene driver
  already hides Recall As this way]

  Current (2.0, #514, 2026-11-14): as announced, 2.0 removes On State
  Follows from `driver.xml`, together with this migration (the late-init
  copy into Keypad Follows and the `keypad_follows_migrated` flag) and
  their specs, in the commit that names 2.0 (O15 of
  [`hdmi-sync-design.md`](hdmi-sync-design.md);
  [`hdmi-sync-stage1-design.md`](hdmi-sync-stage1-design.md) §5.2). A
  device updated straight from 1.5 or earlier keeps Keypad Follows at its
  default, `Room/zone lights`; the manuals say to set it again where On
  State Follows read `This scene`.
- **D13. The lights mode no longer turns the tile on** when the room comes
  on. The `group_known()` branches of the `HUE_SCENE_GROUP` handler and of
  `brightness()` go. The LEDs still update on a group change when
  `keypad_on()` moved.

### Cases (tracking research section 4, decided)

Everything in the research's T table holds with O2 and O7. "Keypad" is the
LED column for Keypad Follows = `Room/zone lights`.

| # | Case | This tile | Other scene tiles of the room | Keypad (room) |
|---|---|---|---|---|
| T1/T2 | This scene played (Control4, keypad, Hue app, Hue switch, Hue automation) | On, the room's level | 0 | On |
| T3/T4 | Dimmed from its slider, the Hue app or a Zone Light device | On, the new level | Stay 0 | On |
| T5/T6 | Held from its keypad; one lamp changed from outside | On (on rule, O2) | 0 | On |
| T7 | Another scene with a device played | 0 | That one on | On |
| T8 | A scene with no device played | 0 | All 0 | On |
| T9 | Lamps turned on by hand from off | 0 | All 0 | On |
| T10 | The room off from anywhere | 0 | All 0 | Off |
| T11 | A scene of an overlapping room or zone, or a whole-home scene, played | 0 when they share a lamp (D7) | The same | On |
| T12/T13 | A schedule runs; its slot moves on | The schedule on; its current slot scene on (O7) | Others 0 | On |
| T14/T15 | Restart; bridge back from offline | The persisted state at once, then the hello answer or resync (D7) | The same | The same |
| T16 | This scene deleted in Hue | 0 (D3) and offline | Unchanged | Off |
| T17 | Linked to another scene | Nothing until reported (D3) | Unchanged | Unknown until reported |
| T19 | The slider of a scene that is not active | Plays it (D4), then T1 | As T1 | On |

## Part 2: scenes stay in their room

### The rule (O3, O4, O5)

"R" is the Control4 room picked under Add From Hue's Room, or the room a
device sits in for Link Device. "M" is the room the scene's group maps to.

| The scene's group | Add, Room "(mapped room)" | Add, Room R | Link a device in R |
|---|---|---|---|
| Mapped to M, and M exists | into M | R = M: into M. R ≠ M: **refused** (P2) | R = M, or the same group as the device's previous scene (P5): linked. Otherwise **refused** (P3) |
| Never mapped, a name two Control4 rooms share, or "(no mapping)" | **refused** (P1) | **refused** (P1) | **refused** (P1) unless the same group (P5) |
| Mapped to a Control4 room that is gone | **refused** (P4) | **refused** (P4) | **refused** (P4) unless the same group (P5) |
| The whole home (bridge_home) | as a mapped group, once Set Room Mapping maps the whole home (P6); refused (P1) before | the same | the same |
| Any, while the project's rooms are unknown | into M as remembered | only R = M | the check is skipped while the device's room is unknown; logged |

"All scenes of <group>" follows the same table. An explicit Room equal to
M is accepted. Today that is refused (the rooms research's F2).

### Texts

The texts are proposals. The builder keeps their meaning and their way
out, and may shorten them to fit a Composer row.

- **P1** "Not added: Hue room Garden is not mapped to a Control4 room. Map
  it with Set Room Mapping (Hue Room Garden, Control4 room of your
  choice), then add again". For "(no mapping)": "…Garden is set to (no
  mapping); map it to one Control4 room with Set Room Mapping, then add
  again". Link Device says "Not linked: …".
- **P2** "Not added: Relax belongs to Hue room Kitchen, which maps to
  Control4 room Kitchen, not Den. Set Room to (mapped room), or change the
  mapping with Set Room Mapping".
- **P3** "Not linked: device 1241 is in Den; Relax belongs to Hue room
  Kitchen, which maps to Kitchen. Pick a scene of a Hue room mapped to
  Den, or change the mapping with Set Room Mapping".
- **P4** "Not added: Hue room Kitchen maps to a Control4 room that no
  longer exists. Map it again with Set Room Mapping, then add again".
- **P5 (the exemption, rooms research 4.2).** The rule judges only a new
  pairing of a device and a scene: an add, a pick under To, or a match by
  name. It never judges:
  - a device adopted by the scene it remembers (hello, Link Device's first
    line by rid, a project restore, a binding made again);
  - a re-link to a scene of the same group as before (`owner.same_group`).
- **P6. The whole home.** Set Room Mapping accepts the whole-home group
  (`bridge_home`), shown in its Hue Room list as "(whole home)" when it
  has scenes. Its mapping is used only for scene placement and marks.
  Lights never read it: a light's Hue room is never the bridge_home. The
  refusal "the whole bridge cannot be mapped to one room" goes.

### Surfaces

- **S1. Scene folders show their target and sort by it** (rooms research
  6.1). Add From Hue ▸ What ▸ Scenes and Link Device ▸ To each name where
  their scenes go, sorted by that Control4 room, then by the Hue label.
  Groups with no room come last:
  - "Kitchen → Kitchen: 5 scenes"
  - "Accent (zone) → Living Room: 3 scenes"
  - "Garden → (unmapped; Set Room Mapping first): 4 scenes"
  - "Kitchen → (Control4 room gone): 5 scenes"
  - "TV Area (zone) → (no mapping): 2 scenes"
  - "(whole home) → (unmapped): 1 scene"

  The first row inside a mapped folder: "All 5 scenes of Kitchen into
  Kitchen". An unmapped folder has no "All" row and lists its scenes, so
  the owner sees them; picking one is refused with P1.
- **S2. Link Device ▸ Device** rows of scene devices name the device's
  Control4 room: "Kitchen: Concentrate (device 1241 in Den)". One
  `GetDevices` lookup when the list opens, through the existing project
  call. A failed lookup names no room.
- **S3. Link Device's first line ("Link all suggested"):** a bare device's
  name match is narrowed to the scenes of the groups mapped to the
  device's Control4 room (C15, C16: "Relax" exists in many rooms). When
  the device's room is unknown, today's rule applies.
- **S4. Room Mappings and Set Room Mapping's Hue Room list** add these
  line endings (rooms research 6.4). Each is an offer; nothing is mapped
  until a Set Room Mapping click:
  - "Garden → (unmapped; its 3 scene devices are in Den)" when all of an
    unmapped group's devices sit in one room;
  - "Great Room → (unmapped; the deleted Great Room was mapped to Living)"
    (O6);
  - "Garage → (unmapped; 2 Control4 rooms are named Garage)";
  - "Kitchen → (Control4 room gone; Control4 room Kitchen matches)";
  - "TV Area (zone) → (no mapping, by hand; its scenes cannot be added)".

  The existing "(unmapped; Control4 room Porch matches)" stays.
- **S5. Set Room Mapping's result counts the devices left elsewhere.** For
  example: "Mapped Kitchen → Kitchen; 2 scene devices are in other rooms
  (their rows say where)" (M4).
- **S6. Nothing moves a device; marks never reach Attention.**
  - No DriverWorks API moves a device between rooms, and nothing stops a
    drag in Composer. A dragged device keeps working, and its row reads
    "(in Dining instead of Living)", as today.
  - Devices already in another room, including ones added before 1.6 with
    an explicit room, stay where they are, marked.
  - The update maps nothing by itself (M8).
- **S7. Lights, zone lights and motion are unchanged.** They keep
  accepting an explicit room. The rule is for scenes only, so it lives in
  `scenes.lua` and `actions.lua`, not the shared `owner.lua`.
- **S8. The whole-home refusal text** stops pointing at a Set Room Mapping
  that could not map it (F1). P6 makes it true.

## Control4 guidelines

The owner's rule (#422) and [`c4-lighting-guidelines.md`](c4-lighting-guidelines.md):

- **L64** (a scene tracks like an Advanced Lighting scene: any load on, or
  this scene active). The tile now tracks "this scene active", as an
  Advanced Lighting scene does with its tracking set to the scene. The
  keypad tracks "any load on" by default (O1). One device with two states
  is departure **D20**, the owner's exception of 2026-11-12. Hue could do
  either, so the departure is the owner's choice, not Hue's limit.
- **L19 and L66** (TOGGLE from off activates; an Advanced Lighting toggle
  plays an inactive scene): TOGGLE follows the tile (D4). Meets.
- **L9** (a light that is on never reads off): unchanged for the scene
  half. A scene that is not active reads off, which is what L64's "this
  scene active" means.
- **L68 and D11**: the docs agent reviews these rows against D1 to D13 and
  says what changed.
- **L58, L59, L73, L76 and L88** (rooms research section 7): the room rule
  adds no departure. A drag in Composer stays free, and the device keeps
  working wherever it sits.

## Code (one writer per file)

| Owner | Files | What |
|---|---|---|
| Agent A (scene device) | `src/hue_scene/driver.lua`, `tests/spec/scene_driver_spec.lua` | D1 to D6 (device side), D9 to D13 |
| Agent B (bridge scenes) | `src/hue_bridge/bridge/scenes.lua`, `tests/spec/scenes_spec.lua`, `tests/spec/scene_roundtrip_spec.lua` | D6 (bridge side), D7; the rule (P1 to P5) in `add_scene`, `add_all_of_group` and the scene re-link; S3; `scenes:group_target` (below) |
| Agent C (actions and mappings) | `src/hue_bridge/bridge/actions.lua`, `tests/spec/actions_spec.lua`, `src/hue_bridge/bridge/lights.lua`, `tests/spec/lights_spec.lua` | S1, S2, S4, S5, P6, S8; Add From Hue's group-add refusal (F2) |
| Agent D (docs) | `src/hue_bridge/www/documentation.html`, `src/hue_scene/www/documentation.html`, `CHANGELOG.md`, `docs/c4-lighting-guidelines.md`, `docs/composer-checklist.md`, `docs/scene-led-design.md`, `docs/scene-dimmer-design.md`, `docs/scenes-design.md` | The manuals (bridge chapters 6, 8.8, 8.9, 9.2 to 9.9 and 11; the scene manual), the changelog line, the guideline rows and D20, the checklist section S, "Superseded" notes |
| Coordinator | `src/hue_scene/driver.xml`, `tests/fixtures/ledger.lua`, `docs/README.md`, `docs/status.md`, `src/hue_bridge/driver.lua` if wiring is needed | Keypad Follows declared, On State Follows kept; ledger row S6; integration |

### Interfaces between the agents

- **`scenes:group_target(group_rid)`** (B writes it, C calls it through
  `self:call("scenes", "group_target", g)`, with a fallback to today's
  label when it is missing) returns:
  - `text`, the target as S1 shows it: a Control4 room name,
    `"(unmapped)"`, `"(no mapping)"` or `"(Control4 room gone)"`;
  - `room_id`, or nil when there is none;
  - `sort_key`, the Control4 room name lowercased, or `"~"` for no room,
    so those sort last.
- **`scenes:placement(rid, room_id)`** (B writes it, B and C call it)
  returns `true, room_id, room_name` or `false, refusal_text`. It applies
  the table above for an add. `room_id` nil means "(mapped room)".
  - Add From Hue keeps calling `add_scene` and `add_all_of_group`, which
    call `placement` themselves.
  - C uses `placement` only for F2: before refusing a group add with an
    explicit Room, it accepts the add when `placement` returns that same
    room.
- **The scene re-link** (Link Device ▸ To, and the first line's matches)
  runs through `scenes:relink(id, rid)`. B adds the room check (P3 to P5)
  there, using the device's room from one `self.project:call("devices",
  { DeviceIds = id })` lookup. `actions.lua` passes the refusal text on
  unchanged.
- **The whole-home mapping (P6)** is stored as any other room mapping in
  the lights' registry, keyed by the bridge_home's rid. `default_room`
  already reads it through `room_mapping` once it exists. C changes
  `lights:set_room_mapping` and the Hue Room list. B's `placement`
  treats the bridge_home like any group.
- **The scene device's messages** are unchanged: `HUE_SCENE_GROUP`
  (`on`, `level`, `other_active`), `HUE_SCENE_STATE`, `HUE_SCENE_RECALL`
  and `HUE_SCENE_LEVEL` keep their parameters. The bridge only sends
  `other_active` in more cases (D7).
  Current (2.0, #514, 2026-11-14): `HUE_SCENE_GROUP` also carries
  `streaming_lamps`, and while it is above 0 its `on` and `level` (what
  D9's Keypad Follows `Room/zone lights` reads) come from the lamps that
  do not stream to a Hue entertainment area
  ([`scene-dimmer-design.md`](scene-dimmer-design.md), "Messages").

## Install

- Lua and properties only: no `<capabilities>` change, so no controller
  reboot. The new property appears after "Add or Update Driver or Agent…"
  [assumed: a property added on an update appears without a reboot, as
  Recall As did; `docs/simplify-research-compat.md`].
- The changelog says that scene tiles now show only their own scene, that
  On State Follows is now Keypad Follows (with its value kept), and that
  scenes can only be added to their mapped room.

## Checks on the house (each under a minute; none blocks the release)

1. Two scene devices of one room: play one from the iPhone app, then
   slide the other. The first goes to 0, and the second plays at the
   slider's level.
2. Play a scene that has no device in the Hue app: every scene tile of
   the room reads 0, and the bedroom switch's LEDs stay lit.
3. Dim the playing scene in the iPhone app: only its tile moves.
4. Play a Bedside Lights zone scene over a Master Bedroom scene: the room
   scene's tile goes to 0 (D7, overlap).
5. Run Disconnect and Connect Event Stream, with another scene played in
   between: the resync sets the tiles right (D7).
6. Add From Hue with an explicit wrong room: refused with P2. Link Device
   on a device in a wrong room: refused with P3.
7. Keypad Follows reads the value On State Follows had on every scene
   device after the update.
