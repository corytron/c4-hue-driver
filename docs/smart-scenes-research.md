# Time-based (smart) scenes: research and contract draft

**Status (2026-10-24): research awaiting the owner's answers (§5); nothing
here is approved or built.** Aligned on 2026-10-24 with the scene dimmer
(`docs/scene-dimmer-design.md`): the on rule's `held_on` replaces the
keypad contract's `dimmed_on`, and since a Hue Scene device is now a
dimmer, question 5 asks what a time-based one should do with a level. The
present behaviour of the drivers is in `docs/status.md`.

Owner, 2026-10-23: "think about how to get the scenes that follow the time
of day in hue, like golden hour and daylight, to show up as available scenes
I can trigger for zones. as right now they are not showing."

Markers: **[docs]** Signify's pages saved by the owner (CLIP API list, Core
Concepts) or the DriverWorks SDK; **[verified: hardware]** seen on the house bridge
(`build/dev/driver.log`, `docs/design.md`); **[community: name]**;
**[assumed]** to be tested; **[inference]** reasoning from the above.

## Summary

1. The Hue app's "Natural light" and "Golden hours" (per Hueblog also "Nature's colors" and user-made all-day scenes) are CLIP v2 `smart_scene` resources: a weekly schedule of ordinary scenes for one room or zone.
2. The house bridge has 15: "Golden hours" to "Golden hours 11" and "Natural light", "Natural light 6" to "8"; 6 in rooms, 9 in zones; four zones hold two each [verified: hardware].
3. Nothing on the bridge is named "Daylight" (no scene, no smart scene) [verified: hardware]; question 1 below.
4. They are missing because the driver only counts `/smart_scene` (`scenes.lua` `fetch_all`/`absorb`) and the Add Scene picker lists `/scene` items (`docs/scenes-design.md` §1 "Not in v1").
5. Start: `PUT /smart_scene/<rid> {"recall":{"action":"activate"}}`; stop: `deactivate`; running or not: `state` `active`/`inactive` [community: openhue, aiohue, Home Assistant, openHAB].
6. Proposal: the existing `hue_scene.c4z` with `kind = smart_scene`; listed in `Add Scene` as "Downstairs (zone): Golden hours (time-based)"; ON activates, OFF deactivates and turns the group off, tile and LEDs follow `state` under the scenes' on rule (`held_on`). The device would be a dimmer like every Hue Scene unless question 5 decides otherwise.
7. No `driver.xml` change is needed (no capability change, so no controller reboot, `docs/composer-remote.md` rule 10); lifecycle is the scenes' (gone / re-link / forget / tombstone), nothing created automatically.
8. Unknown until probed: event contents, what group off / manual changes / another scene do to `state`, activation while off, a deleted target scene. §4 lists 14 dev-loop requests (they need a dev build on the house, which runs release builds); activating changes real lights, so the owner names the room.

## 1. Findings

### 1.1 What the time-of-day scenes are

| Fact | Source |
| --- | --- |
| Endpoints: `POST`/`GET /resource/smart_scene`, `GET`/`PUT`/`DELETE /resource/smart_scene/{id}`. | [docs: CLIP API list] |
| Fields: `id`, `metadata{name, image}`, `group{rid, rtype}`, `week_timeslots[]` = `{timeslots[{start_time{kind, time{hour,minute,second}}, target{rid, rtype:"scene"}}], recurrence[weekday]}`, `transition_duration` (ms, default 60000), `active_timeslot{timeslot_id, weekday}`, `state` `active`/`inactive` ("inactive if no recall is provided"), optional `id_v1`. | [community: openhue `SmartSceneGet.yaml`, aiohue `models/smart_scene.py`] |
| `start_time.kind`: openhue lists `time`, `sunset`; aiohue adds `sunrise`. Accept any string. | [community: openhue, aiohue] |
| No `palette`, `speed`, `auto_dynamic`, `status` or `actions`: a smart scene only points at ordinary scenes. | [community: openhue, aiohue] |
| PUT accepts `metadata`, `week_timeslots`, `transition_duration`, `recall`; no `group`, so a smart scene never moves to another room. `recall` has only `action` (no `duration`, no `dimming`). | [community: openhue `SmartScenePut`/`SmartSceneRecall`, aiohue] |
| "Natural light" (app 4.32, Dec 2022) is added per room; Hue's default schedule is editable, slots at least 30 min; lights shift "one minute before the next period". | [community: Hueblog 2022-12-20] |
| "Golden hours" and "Nature's colors" are all-day scenes that "technically work in exactly the same way as natural light"; bridge firmware 1968096020 "Added support for the upcoming All-day scenes". | [community: Hueblog 2024-11-04, 2024-12-07] |
| House: 15 smart scenes, 20 KB; all `inactive` at the 2026-10-21 probe, yet each carried an `active_timeslot` (ids 0–4), so the bridge tracks the slot while not running. The app numbers repeats ("Golden hours 8" in Kitchen). | [verified: hardware, `Probe Scenes`] |
| Targets are ordinary `scene` rids, so the slot scenes are among the 125 already offered by Add Scene. Which ones on the house is not recorded; every group with a Golden hours also has Arise, Shine, Unwind, Sleepy, Nighttime, Storybook. | [community: openhue]; [inference] |
| "Golden hours" is the smart scene's name, not a slot's. | [verified: hardware] |
| A Hue switch's "time-based light" is a behaviour (automation), and behaviours "you can only list"; out of reach. | [docs: Core Concepts] |
| Home Assistant shows each smart scene as a scene entity next to the ordinary ones: activate = recall `activate`, `is_active` = `state == active`, current slot scene found by walking `week_timeslots` with `active_timeslot.timeslot_id` (flattened across days). openHAB's group `scene` channel lists both kinds and sends `activate` for a smart one. | [community: Home Assistant `hue/scene.py`; openHAB `Clip2ThingHandler.java`] |

### 1.2 Activation, events, interactions

| Question | Answer |
| --- | --- |
| Activate / deactivate | `PUT /clip/v2/resource/smart_scene/<rid>` with `{"recall":{"action":"activate"}}` or `"deactivate"`; 200 with a ResourceIdentifier list as other PUTs [community: openhue, aiohue]. |
| Events | `smart_scene` `update` items arrive on the stream in their own container: one second after a scene recall (2026-10-21 21:42:37); at 19:59:00 followed at 19:59:01 by `scene,scene` and 108 `light` items; at 20:01:00 with 20 `light` items [verified: hardware; contents not logged, `stream.lua` logs types only]. 19:59:00 fits a 20:00 slot starting its 60 s transition [inference]. Fields carried: `state`, `active_timeslot` [assumed; HA and openHAB read `state` from updates]. |
| Ordinary scenes marked active? | The running slot's target scene probably goes `static` and the previous one `inactive` (the `scene,scene` pair above) [assumed]. Today that already flips any imported device of the target scene. |
| Group turned off | Smart scene goes `inactive` [assumed; undocumented]. |
| Another scene recalled / a light changed by hand | Smart scene goes `inactive` [assumed; openHAB handles activations and deactivations of a group's scenes arriving together]. |
| Activation while the group is off | Lights come on in the current slot's scene [assumed]. |
| `deactivate` | Leaves lights as they are [assumed]. |
| Rate | No documented limit for `smart_scene`; ~10/s for lights, 1/s for grouped_light [docs: Core Concepts]. Activation is rare; the scenes' per-rid generation guard suffices. |

### 1.3 Dynamic scenes today, and whether a time-of-day scene can be dynamic

- Device: `Recall As` ("As set in Hue" → `active`, "Static" → `static`, "Dynamic" → `dynamic_palette`; `RECALL_ACTIONS` in `src/hue_scene/driver.lua`). Every `HUE_SCENE_RECALL` carries it; the 2 s fallback assumes `dynamic_palette` for `active` only when the scene's `auto_dynamic` is true (`assumed_active`).
- Bridge (`scenes:recall`): PUT `{"recall":{"action":A, "duration"?, "dimming"?}}`; on 200 reports `A`, or for `active` `dynamic_palette` if `auto_dynamic` else `static`. The picker adds " (dynamic)" for `auto_dynamic` scenes (`scene_label`). ON = `static` or `dynamic_palette`, or held on since an activation (the on rule, `docs/scene-dimmer-design.md`).
- A smart scene has no dynamic fields, so `Recall As` means nothing for it. It can only look dynamic if the bridge recalls slot targets honouring their `auto_dynamic` [assumed]. Whole House's "Shine" and "Unwind" are `auto_dynamic` and Whole House has "Golden hours 3": probe V8 tells.

## 2. Contract draft

### 2.1 Device: a Hue Scene with a kind

- Same `hue_scene.c4z`, same light_v2 device, which is a dimmer since build 160 (the draft was written for a switch; question 5). The proxy reference marks `dimmer` as a dynamic capability, so a time-based device could declare itself a switch with `DYNAMIC_CAPABILITIES_CHANGED` [docs: light_v2 capabilities, `dimmer`; not tried on the house]. The registry entry gains `kind` (`smart_scene`; absent = `scene`); the device persists `hue_kind` beside `hue_rid` and sends it in its hello, so a bridge that lost its registry rebuilds it (import-design rule 3).
- Not a third driver: it would copy the proxy, keypad, LED and lifecycle code and add a `.c4z`, a dev-loop tree and an install. `docs/edge-cases-hue.md` §5 already sketched `kind`.
- `Recall As` hidden on smart devices with `C4:SetPropertyAttribs("Recall As", 1)` after late init [docs: DriverWorks API `24_properties/_4-SetPropertyAttribs.md`; not in OnDriverInit]; shown again with `0` after a re-link to a plain scene [assumed: 0 shows].
- The slot goes in `Status`, so `driver.xml` is unchanged.

### 2.2 Messages (additions to `docs/scenes-design.md` §2)

| Message | Change |
| --- | --- |
| `HUE_SCENE_CONFIGURE` | + `kind` (`scene`/`smart_scene`); for smart: + `slot_name?`, `slot_start?` ("07:00", "sunset"); `auto_dynamic` "false". |
| `HUE_SCENE_STATE` | For smart: `active` is `active` or `inactive` (the device counts `active` as on), + `slot_name?`. |
| `HUE_SCENE_HELLO` | + `kind?`. |
| `HUE_SCENE_RECALL` | Smart device sends `action=activate`; the bridge uses `activate` for any smart entry and ignores `duration`/`brightness` (debug line). |
| `HUE_SCENE_OFF` | Smart: `PUT deactivate`, then `ctx.group_off` as today; STATE inactive. Deactivate first, so a slot change cannot relight the room. |
| `HUE_SCENE_DIM` | Unchanged. |
| `HUE_SCENE_LEVEL` | The slider while it runs: unchanged (the group moves relative to its level), unless question 5 says otherwise; the next slot's transition overrides it. |
| `HUE_SCENE_GROUP other_active` | Smart scene → active: to every other linked device of its group. Scene → static/dynamic: as today, except not to a smart device whose current slot targets that scene. |
| `HUE_SCENE_GROUP on`, `level` | Unchanged: the group's on/off ends `held_on`, its level is the tile's level. |

### 2.3 Bridge (`bridge/scenes.lua`, `hue_model.lua`)

- `hue_model.smart_scene(item)` → `{ rid, name, group_rid, group_type, id_v1, state, slot_id, slot_weekday, slots = { {days, start, target_rid} }, transition_duration }`; `update_smart_scene` returns changed fields. Replaces `smart_scene_count`.
- `fetch_all` keeps its GET; `absorb` fills `smart_catalogue`. A **failed** smart GET keeps the previous catalogue and skips smart entries in reconcile (no false "gone").
- `on_container`: `smart_scene` `add`/`update`/`delete` as `on_scene_item`, against `smart_catalogue`.
- `recall`/`off` branch on `entry.kind`. `summary`: "125 scenes and 15 time-based on bridge, …".

### 2.4 Picker and names

- `SceneList`: unimported smart scenes with the scenes, `"<group label>: <name> (time-based)"`, before the plain scenes of the same group; tombstones last as today.
- `SceneGroupList`: "Downstairs (zone) → (unmapped) (16 scenes, 2 time-based)". `Add All Scenes Of Room` includes time-based ones (question 2).
- Room: the group's mapping, else the `Room` picked, else refused (as scenes). Rooms and zones both carry them [verified: hardware]; `bridge_home` never seen.
- Name: room `<name>`, zone `<Zone> <name>`, set once. Proposed: drop the app's trailing number ("Golden hours 8" → "Golden hours") when no other smart scene of that group shares the base; `expected_name` applies the same rule, so `Attention` stays quiet (question 4).
- `Re-link Scene` lists both kinds; crossing kinds is allowed and CONFIGURE carries the new kind.

### 2.5 Smart scene device behaviour

| Input | Behaviour |
| --- | --- |
| ON, target > 0, SET_LEVEL > 0 | From off: CHANGING 0→100, `HUE_SCENE_RECALL action=activate`, 2 s fallback assumes on; RATE ignored; a level below 100 cannot be applied at activation (a smart recall has no brightness; question 5). While running, a target > 0 is the slider (`HUE_SCENE_LEVEL`, question 5). |
| OFF, target 0 | `HUE_SCENE_OFF`; fallback assumes off. |
| TOGGLE | From `effective_on`. |
| Tap top / bottom / toggle | As scenes: activate / OFF / toggle. |
| Hold top or bottom while on | `HUE_SCENE_DIM` up/down, as for scenes (keypad-design "Scene device"); the scene is held on already (the on rule). |
| Hold top while off | Activate only: smart recall has no brightness override, so no 1 % start (question 5). |
| Tile and LEDs | `effective_on` = `state` active or `held_on`; `held_on` is set by any activation (from Control4, a keypad, the Hue app or a schedule) and cleared by the group going off, `other_active` or the device's own OFF (the on rule of `docs/scene-dimmer-design.md`); the level shown is the group's brightness. |
| Status | "Hue time-based scene Golden hours in Downstairs (zone); now Shine (from sunset)" / "…; not running". |

## 3. Corner cases

| Case | Automatic | Offered | Never without a click |
| --- | --- | --- | --- |
| Smart scene created in the app | `add` (or resync) puts it in `Add Scene`; debug log | `Add Scene`, `Add All…` | Creating a device |
| Renamed | Registry name and Status refreshed | `Adopt Hue Name`; counted in Attention | Renaming the Composer device |
| Timeslots edited | Slot list refreshed; Status shows the new current slot | — | — |
| Deleted in the app | Entry `gone`; ON warns, reports OFF | `Re-link Scene`, `Forget Scene` | Deleting the device |
| A target scene deleted | Unknown on Hue's side (refused, slot dropped, or dangling) [assumed; V14]. Keep linked; slot "(deleted scene)"; warn once | — | — |
| Its room/zone deleted | Smart scene presumably deleted too → `gone` [assumed] | Re-link, Forget | Deleting the device |
| Re-created in the app (new rid) | Old entry `gone`, new one listed | Re-link (exact name noted) | Re-linking by name |
| Bridge transfer/restore | Resync: missing rids `gone`, present ones keep devices | `Link Devices` (exact name), Re-link | Re-linking by name |
| Composer project restored | Hello carries `rid` + `kind`; adoption rules unchanged | `Link Devices` | — |
| Device deleted in Composer | Tombstone (shared with scenes) | `Add Scene` re-creates | Bulk re-creation |
| Two smart scenes in one zone (4 on the house) | Each mirrors its own `state`; activating one presumably stops the other [assumed; V10] | — | — |
| Activated while the group is off | ON from the event, else the fallback | — | — |
| Activated from the app, a dial or a switch | Device follows the event (V4 shows the shape) | — | — |
| Ordinary scene recalled in the group | `other_active` ends `held_on`: the device goes off | — | — |
| Light changed by hand in the group | Hue may report the smart scene inactive; under the on rule the device stays on | — | — |
| Slot change while running | Target scene statuses move; smart device stays ON; no `other_active` to it | — | — |
| Hold-to-dim | Group dim; tile stays on (`held_on`) even if Hue stops the schedule; if Hue keeps it running, the next slot overrides the dim (Hue's behaviour) | — | — |
| `/smart_scene` GET fails | Keep previous catalogue; no state changes | — | Marking devices gone |
| Imported plain scene that is a slot target | Unchanged: on when its scene becomes the running slot (any activation counts), off when the next slot's scene becomes active (`other_active`) | — | — |

Rejected: a bridge action "Activate Hue Smart Scene" for programming only (no tile, no state, no keypad).

## 4. Verification on the house bridge (dev loop, before building)

All through `tools/devctl.py run "Hue Request" Method=… Path=/clip/v2/resource/… Body='…' Raw=true` on the dev build (`docs/dev-loop.md`). The house runs release builds, which have no `Hue Request`: a dev build has to be installed first (`docs/dev-loop.md`, "Current state"). No application key is needed on the VM. The stream logs only item types, so either GET after each step or add a dev-only debug line in `bridge/stream.lua` that prints whole `smart_scene` and `scene` items. V4–V11 change real lights: the owner names the room and time (suggested: Office "Golden hours 10"). V12–V14 create and delete throwaway resources; the owner's OK is quoted in the brief.

| V | Request | Expect / record |
| --- | --- | --- |
| V1 | `GET /smart_scene` (Raw) | Full shapes for a fixture (placeholder rids): `start_time.kind` values (sunrise?), recurrence, `transition_duration`, `id_v1`, `metadata.appdata` |
| V2 | Map every target rid to `/scene` names | Which of the 125 are slot scenes; whether the app hides them (owner, optional) |
| V3 | Compare `active_timeslot` with `week_timeslots` | Is `timeslot_id` per-day or flattened (HA's reading)? |
| V4 | `PUT /smart_scene/<rid> {"recall":{"action":"activate"}}` | 200 `{"data":[{"rid":…,"rtype":"smart_scene"}],"errors":[]}`; stream: `smart_scene` (`state`), `scene` (target `static`?), lights; timing |
| V5 | `GET /smart_scene/<rid>`, `GET /scene/<target>` | `state: active`; target `status.active` |
| V6 | Same PUT with `"duration":750` | 400 or ignored (can RATE pass?) |
| V7 | `PUT … {"recall":{"action":"deactivate"}}` | `inactive`; lights unchanged? |
| V8 | Activate Whole House "Golden hours 3" (owner's OK) | Target `dynamic_palette`? |
| V9 | Activate; `PUT /grouped_light/<g> {"on":{"on":false}}`; then on | `state` after off; lights after on |
| V10 | Activate A, then the zone's other smart scene B | A goes `inactive`? |
| V11 | Activate; recall a plain scene of the group; separately change one light; separately `dimming_delta` up/stop on the group | `state` after each |
| V12 | `POST /smart_scene` in a throwaway zone (`POST /zone` with one light): two slots targeting two scenes created by `POST /scene` | `add` shape; minimum slot length enforced? |
| V13 | `PUT` its `metadata.name`, then its `week_timeslots` | `update` shapes |
| V14 | `DELETE` one target scene, then the smart scene, then the zone | Refused, slot dropped or dangling; `delete` shapes |

## 5. Open questions for the owner

1. "Daylight": no scene or smart scene has that name (2026-10-21). A slot name in the app, a scene made since, or "Natural light"?
2. Should `Add All Scenes Of Room` include time-based scenes (**yes**)?
3. OFF on a time-based scene: **deactivate and turn the room/zone off**, or deactivate only and leave the lights?
4. Names: **drop the app's number** ("Golden hours 8" → "Golden hours"), or copy as is?
5. A Hue Scene device is a dimmer since build 160, so a time-based one
   would be too. Slider while it runs: **move the room relative to its
   level, as for scenes** (the next slot's transition then overrides it)?
   Slider or hold top while off: **activate only** (a smart recall has no
   brightness), or activate and then move the room to the level or ramp
   up? Or should time-based devices report themselves as switches, if the
   proxy honours `dimmer` false sent at run time (untested)?
6. Mark slot scenes in the picker, e.g. "Shine (in Golden hours)"?
7. Which room and time may the probes in §4 change, and is a throwaway zone and smart scene on the bridge acceptable?


## 6. Owner's answers (2026-10-24)

1. "Daylight" means **Natural light**.
2. **Add All Scenes Of Room includes** time-based scenes.
3. **OFF stops the schedule and turns the room/zone off**, as OFF on an
   ordinary scene.
4. **Names drop the app's number** ("Golden hours 8" → "Golden hours");
   zone scenes get the zone's name in front, as ordinary zone scenes do.
5. **Hold top while off: start, then brighten.** The owner adds: the scene
   must keep playing after a dim (the schedule keeps switching time slots;
   a dynamic scene keeps animating). Hue may end a scene when its lights
   are dimmed; check it (V11 and a dynamic-scene variant) and, if so, look
   for a way to keep it playing: for dynamic scenes, re-recalling with a
   brightness override instead of `dimming_delta`; for time-based scenes,
   whether the active state and the next slot survive a dim, and what
   re-activation would do. The same expectation applies to ordinary
   dynamic scenes dimmed from a keypad or slider today.
6. **Mark slot scenes** in Add Scene, e.g. "Master Bedroom: Shine (in
   Golden hours)".
7. **Checks now, in the Master Bedroom** (the owner first named the Study and
   its Desk Lamp, then switched: the Study has no keypad); throwaway zone and
   time-based scene on the bridge allowed (created and deleted by the
   checks). Run on a development build of the bridge driver installed for
   the duration; production build back afterwards.

## 7. Check results on the house bridge (2026-10-24 11:17–11:35, dev build 173, Master Bedroom)

All through `Hue Request` on the development bridge build, with a temporary
dev-only log line printing whole `smart_scene`, `scene` and `grouped_light`
event items. Bridge time zone `EST5EDT`.

- **V1 shape.** 15 smart scenes. Each: `id`, `type`, `metadata {name,
  image}`, `group {rid, rtype room|zone}`, `week_timeslots [ { timeslots [
  { start_time { kind "time"|"sunset", time {hour, minute, second} },
  target { rid, rtype "scene" } } … ], recurrence [weekday names] } ]`,
  `transition_duration` (60000 on all app-made ones), `active_timeslot {
  timeslot_id, weekday }` (present even while inactive: the last/current
  slot), `state` "active"|"inactive". No `id_v1`. Master Bedroom (room
  0a41b9f5…) has **Golden hours 4**; the Bedside Lights zone (the two
  bedside lamps) has **Golden hours 11** and **Natural light 6**; the other
  Natural lights are in Downstairs, Whole House and Basement.
- **V2.** Golden hours 4's six slots target ordinary scenes; slot 1 (16:00)
  is **Shine**, slot 0 (07:00) is "Arise".
- **V3.** `timeslot_id` indexes the `timeslots` list of the week entry for
  that `weekday` (slot 0 at 11:19 on a Saturday = the 07:00 slot).
- **V4/V5 activate.** `PUT /smart_scene/<id> {"recall":{"action":"activate"}}`
  → HTTP 200 `{"data":[{"rid":…,"rtype":"smart_scene"}],"errors":[]}`.
  Event order: `smart_scene` update `{state:"active", active_timeslot}`
  about 50 ms **before** the HTTP answer; about 1 s later the slot scene's
  `status.active` "static" (with `last_recall`) and the group's
  `grouped_light` on/brightness. The bridge driver's existing logic sent
  `HUE_SCENE_GROUP other_active` to Shine (another scene of the room).
- **V6.** `activate` with `"duration":750` → HTTP 200, no error (whether the
  fade is used is not visible).
- **V7 deactivate.** → `state:"inactive"`; the lights stay as they are (on,
  same level). OFF therefore needs deactivate **and** group off, as the
  owner chose.
- **V9 group off.** With the smart scene active, group `on:false` → the slot
  scene goes `inactive` and the smart scene `inactive` (events within 5 ms);
  turning the group on again does **not** reactivate it.
- **V10 another one.** Activating another smart scene over the same lights
  (room Golden hours 4, then zone Golden hours 11, then zone Natural light 6)
  makes the previous one `inactive`, each with an event.
- **V11 recall / dim (the owner's question 5).** A relative group dim
  (`dimming_delta` down 30 with `dynamics`) leaves the smart scene
  **active** and its slot scene **still "static"** (no scene event at
  all). Recalling an ordinary scene of the group makes the smart scene
  `inactive`. A dynamic scene (Arise recalled `dynamic_palette`) stays
  **`dynamic_palette`** after a relative group dim and after an absolute
  group `dimming.brightness`; only a change to one light (seen earlier) ends
  a scene. So whole-room dims from Control4 keep a scene playing, by status.
- **Slot advance.** A throwaway schedule (zone with the Left Bedside Light,
  slots 11:20 warm 40 % and 11:28 cool 80 %, later moved to 11:32) did
  **not** advance to its second slot in the following minute, neither after
  a dim nor in a control run without one; state stayed active, slot 0. So
  the dim was not the cause; API-created schedules may not run their slot
  changes the way app-made ones do (open). To be checked with the real
  Golden hours 4 at its 16:00 slot (target Shine): activate before 16:00,
  dim, read the active slot after 16:00.
- **Slot advance after a dim (16:00 check, 2026-10-24, build 199,
  production).** The Golden hours device (1164, Master Bedroom) read "…; now
  Arise (from 07:00)" at 15:57 and "…; now Shine (from 16:00)" at 16:02 and
  16:04, never ending in "not running", with the event feed alive (30
  containers, last 16:01:38). So a running app-made schedule does advance
  its slot at the boundary and the device shows the new slot within two
  minutes. Whether the room had been dimmed before 16:00 is not known (the
  check read Composer only; nobody dimmed it from here); V11 showed a dim
  leaves the schedule active, and this shows an active schedule advances.
  The throwaway API-made schedule above remains the odd one out.
- **V12 create.** `POST /zone` → 201; `POST /scene` → 201; `POST
  /smart_scene` → 201; the add event shows the new smart scene already
  **`active`**. An 8-minute slot was accepted. A new `grouped_light`
  announces `dimming_delta` and `dynamics` support.
- **V13 edit.** `PUT` with `metadata.name` and `week_timeslots` → 200; one
  update event carries both.
- **V14 delete.** Deleting a scene that a slot targets → 200, and **the
  bridge deletes the whole smart scene** one second later (`delete` event).
  Deleting the zone deletes its grouped_light. All test resources removed.
- **V8** (Whole House "Golden hours 3", a dynamic target) not run (it would
  switch the whole house).

## 8. Test plan 2026-10-25

What is left of #40 and how each point gets its answer. Every change to
the house below is covered by the owner's standing approval; probe lights
stay at 1 % unless a step says otherwise. Rids are read at run time and
never written here: `<gh4>` is the Master Bedroom's Golden hours 4
(`smart_scene`), `<room>` the Master Bedroom room, `<lamp>` one of its
lights. Results go into §7 and `docs/status.md`; a defect becomes its own
issue.

Common to all: a dev build on the house and `tools/devserver.py` running
(`docs/dev-loop.md`); the bridge's `Debug Mode` On for the duration
(`tools/devctl.py set "Debug Mode" On`, Off afterwards), because its
`info` lines name every activate ("scenes: activate …"), deactivate ("off
for … deactivate, then its group off"), dim ("scenes: dim … down") and
level move; `tools/devctl.py log -f` in a terminal.

### (a) The keypad on a time-based scene (Decisions 3 to 5)

Not tried by the owner yet. First through the Lua command window of the
"Golden hours" device (1164), worked by the Windows session as round 40
did for Shine. No keypad is bound to it (the Bedside Lights Switch drives
Shine), so the chunk calls the driver's entry point with the binding ids a
bound keypad uses (200 top, 201 bottom) in a keypad's order: `DO_PUSH`,
`DO_RELEASE`, then `DO_CLICK` 100 ms after the release, as in round 40
(`common/device.lua` treats a press still down after 400 ms as a hold and
ignores a click within 1 s of a hold's release). `C4:SetTimer(ms, fn)`
[verified: SDK `34_timer/_1-SetTimer.md`]. Define it once (a Director
restart or a driver update drops it; then define it again):

```lua
c4hue_press = function(binding, ms) -- 200 top, 201 bottom; ms the button is held
  ReceivedFromProxy(binding, "DO_PUSH", {})
  C4:SetTimer(ms, function() ReceivedFromProxy(binding, "DO_RELEASE", {}) end)
  C4:SetTimer(ms + 100, function() ReceivedFromProxy(binding, "DO_CLICK", {}) end)
  print(string.format("c4hue_press %d held %d ms", binding, ms))
end
```

Then one line per step, starting from off, about 10 s apart. After each:
the device's Status and Lua Output pane (Windows), the shipped log (VM),
and Hue's `state`, which `tools/smart_scene_probe.py watch --smart <gh4>
--light <lamp> --until <end>` prints every 20 s for the whole round.

| Step | Lua | Expected |
|---|---|---|
| a1 tap top | `c4hue_press(200, 150)` | "scenes: activate"; `active`; Status "…; now <slot> (from <start>)"; the room in the slot's look |
| a2 hold bottom | `c4hue_press(201, 1500)` | dim down, stop at the release; still `active` (V11), Status unchanged, the level lower |
| a3 hold top | `c4hue_press(200, 1500)` | dim up, stop at the release; still `active` |
| a4 tap bottom | `c4hue_press(201, 150)` | deactivate, then the room off; `inactive`; "…; not running" |
| a5 hold top from off | `c4hue_press(200, 3000)` | activate; the dim up follows once the room reports on with a level (1.9 s after the press at the latest: 400 ms to the hold, `FOLLOW_MS` 1500) and stops at the release; still `active` |
| a6 tap bottom | `c4hue_press(201, 150)` | off |
| a7 short hold top from off | `c4hue_press(200, 800)` | activate only: released before the follow, so no dim; the slot's own level |
| a8 tap bottom | `c4hue_press(201, 150)` | off, as found |

The keypad LEDs cannot be seen this way. The owner's own pass (his hands):
the Windows session binds the Bedside Lights Switch's top and bottom
buttons to Golden hours' Top and Bottom Button Links instead of Shine's
(Connections), the owner taps and holds and watches the LEDs (top lit while
the schedule runs), then the buttons go back to Shine.

### (b) Recall As after a cross-kind re-link (Decision 12)

That `C4:SetPropertyAttribs("Recall As", 0)` shows the row again is
assumed. Re-link Scene's `Device` list in Composer offers only gone and
unbound devices (`bridge/owner.lua`, `picker_relink_devices`), so the
action goes through the dev loop, whose `ExecuteCommand` takes any
registered device:

1. Arise's rid: Golden hours 4's slot 0 target (`GET
   /clip/v2/resource/smart_scene/<gh4>`, V2). Arise is not imported, so
   the re-link is not refused.
2. `tools/devctl.py run "Re-link Scene" Device=1164 Scene=<arise>`:
   `Last Action` "Re-linked device 1164 (was Golden hours) to Master
   Bedroom: Arise".
3. Composer, device "Golden hours" (Windows session): the **Recall As**
   row is back with its last value, Status "Hue scene Arise in Master
   Bedroom". Read it at once, and again after selecting another device
   and coming back: Composer drops attribute changes that arrive together
   with text updates (the `Last Action` rows, build 247). The bridge's
   `Attention` may list the name difference meanwhile.
4. `tools/devctl.py run "Re-link Scene" Device=1164 Scene=<gh4>`: the row
   hidden again, Status "Hue time-based scene Golden hours in Master
   Bedroom; …", `Attention` clear.

Shown at once: Decision 12 verified. Shown only after re-selecting the
device: a Composer refresh, noted in `docs/design.md` (the device could
send the attribute again later, as `Last Action` does). Never shown: a
defect, its own issue.

### (c) A dim before a slot boundary, then the advance (the owner's question 5)

The 16:00 boundary of Golden hours 4 (slot 1, Shine), as scheduled for
this afternoon. Nothing else in the Master Bedroom from 15:40 to 16:10: a
schedule created there (d) would end Golden hours 4 (V10).

1. 15:45: `tools/smart_scene_probe.py watch --smart <gh4> --light <lamp>
   --until 16:06` prints state, slot and the lamp every 20 s.
2. 15:50: start it as a tile does: `tools/devctl.py run "Proxy Command"
   Light=1164 Command=ON`. Expect `active`, slot 0 (Arise, from 07:00).
3. 15:53: dim it from Control4 on the slider's path (`HUE_SCENE_LEVEL`, a
   relative group move): `tools/devctl.py run "Proxy Command" Light=1164
   Command=SET_LEVEL LEVEL=<about half the lamp's level>`. Expect still
   `active`, slot 0, the lamp lower.
4. 15:59 to 16:01: slot 1 at 16:00 or up to 60 s before it (the
   transition, §1.2); then the lamp at Shine's own level, not the dimmed
   one (Decision 6); Status "…; now Shine (from 16:00)"; the tile on.
5. 16:05: `… Command=OFF` (deactivate, then the room off), as found.

Step 4 is the answer to question 5. No slot change, or `inactive` after the
dim, is a finding for the contract (Decisions 2 and 6).

### (d) Do API-made schedules run their slot changes?

The throwaway of 2026-10-24 (§7, "Slot advance") differed from every
app-made schedule in more than its origin [verified: hardware, the shipped
log of 2026-10-24 11:23 to 11:34 and `GET /smart_scene` of 2026-10-25
01:20]: one weekday (saturday) where the app's carry all seven in one week
entry; two slots 8, later 12, minutes apart where the app's have six
covering the day (its 00:00 slot comes last, after 22:00);
`transition_duration` 5000 where the app's have 60000. It was created
already active, activated at 11:25:03 and again at 11:29:24 after slot B
moved, and still read slot 0 at 11:28:51 and at 11:32:54.

`tools/smart_scene_probe.py` (`--help`; every request through the dev
loop, never to the bridge directly) makes a probe in one room: two scenes
at 1 % warm white (A 2200 K, B 2700 K, so a slot change also shows in a
light's mirek) and a smart scene "c4-hue probe" with slot A from the
current minute and slot B `--minutes` later on today's weekday,
`transition_duration` 60000; it activates it as the driver's ON does,
reads `active_timeslot`, both scenes' `status.active` and one light every
20 s, prints a verdict, and deletes all three (a GET answering 404 confirms
each), turning off again the lights that were off before. It refuses a
level above 5 % without `--allow-bright` and lights that are on without
`--allow-on`, and saves its ids in `build/dev/smart_scene_probe.json` after
every step.

1. When and where: away from (c), for example 16:15, in the Master Bedroom
   with its lights off (the owner's room for checks, §6 answer 7), limited
   to one lamp: `tools/smart_scene_probe.py run --room <room> --light
   <lamp> --minutes 3 --brightness 1` (or `create`, `activate`, `watch`,
   `cleanup` one at a time). That the bridge takes a room scene holding
   only some of the room's lights is [assumed]; if it refuses, nothing is
   made, and the same run without `--light` takes every light of the room.
   A new schedule there ends Golden hours 4 if it runs (V10) and the room's
   scene devices hear `other_active`; the probe's scenes are listed in Add
   Scene while they exist; nothing is imported.
2. Advances (verdict "slot B started", scene B `static`, the lamp at mirek
   370): API-made schedules run, and the earlier miss came from its shape.
   §7 says so; nothing changes in the driver.
3. No advance: run again in the app's shape, `--days all --minutes 30`
   (every weekday, and a slot as long as the app's shortest [community:
   Hueblog 2022-12-20]). Advances then: the shape (one weekday or a short
   slot) was the cause. Still none: API-made schedules do not run their
   slot changes on this bridge (firmware 2071524040). The driver only plays
   schedules made in the app, so nothing changes in it; §7 and the manual
   say so.

### (e) V8, the whole-house dynamic scene

Recommendation: **do not run V8 on Whole House.** It would recall the
current slot's scene on every light in the house and leave them there
(deactivate leaves the lights as they are, V7), with no way back but
setting each room by hand. Its question, whether a schedule plays an
`auto_dynamic` slot scene dynamically (§1.3), can be answered in one room:
Golden hours 6 (Basement Hallway, a room) plays Storybook from sunset, and
that Storybook is `auto_dynamic`; Golden hours 3 (Whole House) has Shine
and Unwind `auto_dynamic`; no other schedule on the bridge has an
`auto_dynamic` slot scene [verified: hardware, `GET /smart_scene` and
`GET /scene` of 2026-10-25 01:20].

- When: after sunset (about 18:00 this week [assumed: the bridge's own
  sunset time]) and before 20:00, with the hallway empty. `GET
  /clip/v2/resource/smart_scene/<gh6>` first: `active_timeslot` slot 2
  says Storybook is the current slot (tracked while inactive, §1.1), and
  its target is `<storybook>`.
- Steps: `tools/smart_scene_probe.py watch --smart <gh6> --light <hallway
  light> --until <now + 4 min>` in one terminal; `tools/devctl.py run "Hue
  Request" Method=PUT Path=/clip/v2/resource/smart_scene/<gh6>
  Body='{"recall":{"action":"activate"}}'`; 5 s later `GET
  /clip/v2/resource/scene/<storybook>`; then the same PUT with
  `deactivate` and `PUT /clip/v2/resource/grouped_light/<hallway group>`
  with `{"on":{"on":false}}`, as found.
- Reading: `status.active` "dynamic_palette" (and the light's xy moving
  between polls) means a schedule honours `auto_dynamic`, so a time-based
  device looks dynamic while such a slot plays; "static" means it does not.
  Either way the contract stays (Recall As stays hidden on time-based
  devices); §1.3 and §7 get the fact.
- V8 itself only if the owner asks to see it, at a time he picks while he
  is at home.
