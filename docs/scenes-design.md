# Scenes: one Control4 switch per Hue scene

The contract for the **scenes** feature (branch `scenes`, built on
`import-ui`): a `hue_scene.c4z` driver that shows one Hue scene as a
light_v2 switch in a Control4 room, created only by the owner, recalled by
ON, mirroring the bridge's scene status, and handled over its life exactly
like a light (gone / forgotten / deleted / re-linked). It extends
`docs/import-design.md` (§1 rules, §3 states, §9 the approved decisions,
§10 Q2/Q6/Q7 defaults) and reuses its registry, groups, pickers and
texts. `docs/edge-cases-hue.md` §3 holds the Hue-side evidence.

Hardware facts this rests on (`docs/design.md`, "Scenes: verified on
hardware"): 125 scenes in 13 groups and 15 smart scenes on the house
bridge; `GET /scene` is 351 KB and decodes in about a second; a recall is
`PUT /scene/<rid> {"recall":{"action":"active"}}` and the bridge streams a
`scene` item with `status.active` 9 ms later, then the `light` and
`grouped_light` items; changing any member light by hand streams the
scene's status again (→ "inactive"). Scenes carry `status.active`,
`status.last_recall`, `auto_dynamic`, `speed`, `group`, `id_v1`.

**Current (2026-10-24):** built, merged and verified on the house
(2026-10-21/22; `docs/design.md`, "Scenes build"). Since then a scene
device also takes keypad holds and drives keypad LEDs
(`docs/keypad-design.md`) and, since build 160, is a **dimmer** whose on
state follows the on rule (`docs/scene-dimmer-design.md`). The parts that
changed are marked "Superseded" below; `docs/status.md` describes the
present.

## 1. Decisions (all approved defaults)

| Topic | Decision |
| --- | --- |
| Device | `hue_scene.c4z`: light_v2 proxy with `dimmer` False (a switch), consumer binding 1 class `HUE_BRIDGE` like a light. Never a `hue_light` with its proxy flipped [verified: FUND 14/_2]. Superseded (2026-10-23): a dimmer since build 160 (same driver, same proxy type); see `docs/scene-dimmer-design.md`. |
| Creation | Only `Add Scene` (one) or `Add All Scenes Of Room` (every unimported scene of one room/zone). Nothing from events, imports or resyncs: Hue keeps ~7 default scenes per room. |
| Name | Room scene: `<Scene>` in the mapped room (Q2). Zone scene: `<Zone> <Scene>`. Set once; `Adopt Hue Name` afterwards. |
| Room | The scene's group's mapping (`hue_rooms`), or the `Room` picked; refused when neither exists (as `Add Light`). |
| ON | `PUT /clip/v2/resource/scene/<rid> {"recall":{"action":<A>}}`, `A` from the device's `Recall As`: "As set in Hue" → `active` (default, Q7), "Static" → `static`, "Dynamic" → `dynamic_palette`. A `RATE` from the proxy becomes `recall.duration` (ms) [assumed field, confirm once; the bridge accepted `duration` 750 with HTTP 200 on 2026-10-21, the transition itself was not measured]. |
| OFF | The scene's group `grouped_light` off, one PUT per group coalesced within a second (Q6; group limit ~1/s). A scene whose group has no grouped_light (empty zone) reports OFF without a PUT. Correction (2026-10-24, as built): the group queue coalesces per grouped_light through the queue's 80 ms debounce and one PUT in flight, and its token bucket is the lights' 10/s with burst 10; no 1/s limit is enforced (`src/hue_bridge/bridge/commands.lua` 36–37, `src/hue_bridge/driver.lua` `new_group_queue`). |
| State | ON while the bridge's `status.active` is `static` or `dynamic_palette`, OFF when `inactive`; from `scene` stream items and from the resync's `GET /scene`. Reported as `LIGHT_BRIGHTNESS_CHANGED` 100 / 0 (a switch). Superseded (2026-10-23): on from any activation until the group turns off, another scene of the group becomes active, or the device turns it off (`held_on`, persisted); the level reported is the group's brightness; see `docs/scene-dimmer-design.md`, Behaviour. |
| Lifecycle | Same states and texts as lights (§3 of import-design): gone (scene deleted in Hue: Status explains, ON logs a warning and reports OFF at once), unbound, tombstone (device deleted in Composer: bulk add skips, `Add Scene` re-creates), re-link, forget, auto-adopt on hello. Scene devices are never removed automatically. |
| Smart scenes | Not in v1: counted in the log, never listed. (Still so on 2026-10-24; a draft for listing them awaits the owner's answers in `docs/smart-scenes-research.md`.) |
| Catalogue | `GET /scene` once per resync (after the lights' six GETs) and on `Refresh Scenes`; kept compact in memory: `{ rid, name, group_rid, id_v1, status, auto_dynamic, speed }` — `actions`/`palette` are dropped at decode time [assumed: a 351 KB decode is fine on the controller; it was in `Hue Request`]. Stream `scene` items update it (`add`/`update`/`delete`). As built, the scene step of a resync is three GETs: `/scene`, `/smart_scene` (counted only) and, since the keypad feature, `/grouped_light` (each group's on/off and level). |

## 2. Messages (bridge ⇄ scene device; all values strings)

| Command | Direction | Params | When |
| --- | --- | --- | --- |
| `HUE_SCENE_HELLO` | scene → bridge | `rid?`, `device_id`, `name?` | late init, `OnBindingChanged(true)`; the bridge answers CONFIGURE + STATE or adopts (§4 of import-design, same rule) |
| `HUE_SCENE_RECALL` | scene → bridge | `rid`, `action` (`active`/`static`/`dynamic_palette`), `duration?` (ms) | proxy ON / `SET_BRIGHTNESS_TARGET` > 0 (superseded 2026-10-23: a target > 0 recalls only while the scene is off, with `brightness`; while on it is `HUE_SCENE_LEVEL`) |
| `HUE_SCENE_OFF` | scene → bridge | `rid` | proxy OFF / target 0 |
| `HUE_SCENE_GOODBYE` | scene → bridge | `rid?`, `device_id` | `OnDriverRemovedFromProject` |
| `HUE_SCENE_FORGET` | scene → bridge | `rid?`, `device_id` | `Forget This Scene` action |
| `HUE_SCENE_CONFIGURE` | bridge → scene | `rid`, `name`, `group_name`, `group_type` (`room`/`zone`/`bridge_home`), `id_v1?`, `auto_dynamic` (`true`/`false`), `state` (`linked`/`gone`), `gone_since?` | at creation, hello, every resync where something changed, re-link |
| `HUE_SCENE_STATE` | bridge → scene | `rid`, `active` (`inactive`/`static`/`dynamic_palette`), `reason` (`event`/`resync`/`hello`/`recall`) | every scene status the bridge learns; `recall` right after the PUT succeeded carries the requested state so the switch settles even if the event is missed |
| `HUE_SCENE_FORGOTTEN` | bridge → scene | `rid`, `name?` | after Forget |
| `DEV_RELOAD` | bridge → scene | `tree` = `scene`, `version`, `files` | dev builds (§6) |

A scene device buffers CONFIGURE/STATE/FORGOTTEN before late init, as the
light does. `ONLINE_CHANGED false` while unbound, gone or forgotten.

Added later: `HUE_SCENE_DIM`, `HUE_SCENE_GROUP` and the recall's
`brightness` (`docs/keypad-design.md`, "Scene hold-to-dim"),
`HUE_SCENE_LEVEL` and `HUE_SCENE_GROUP`'s `level`
(`docs/scene-dimmer-design.md`); in dev builds `HUE_LOG` (a device's log
lines to the bridge) and `HUE_DUMP` (bridge → scene, dumped its state; removed 2026-10-24, nothing sent it).

## 3. Scene device (`src/hue_scene/`)

- `driver.xml`: name "Hue Scene", model "Hue Scene (CLIP v2)", minimum OS
  3.3.0, `<proxy proxybindingid="5001" name="Hue Scene">light_v2</proxy>`,
  capabilities `dimmer` False, `on_off` True, `set_level` False,
  `ramp_level` False, `supports_target` True, `supports_color*` False,
  `reduced_als_support` True, `buttons_are_virtual` True,
  `hide_proxy_properties` True; connections 5001 (LIGHT_V2 provider) and 1
  (`HUE_BRIDGE` consumer) copied from `hue_light`. Superseded
  (2026-10-22/23): the Top, Bottom and Toggle Button Link connections
  200–202, `has_leds` and `hold_rates` (`docs/keypad-design.md`) and, since
  build 160, `dimmer`, `set_level` and `ramp_level` True
  (`docs/scene-dimmer-design.md`); the current list, which also declares
  `supports_brightness_stop`, is `src/hue_scene/driver.xml`. Properties (all read-only
  STRING unless noted): `Driver Version`, `Debug Mode` (LIST Off/On),
  `Status`, `Hue Scene` (name), `Hue Room` (group label), `Hue Scene ID`
  ("#<id_v1 tail> (<rid…>)"), `Recall As` (LIST "As set in Hue" / "Static" /
  "Dynamic", default "As set in Hue", editable, persisted), `Online`,
  `Last Action`. Actions: `Adopt Hue Name`, `Forget This Scene`.
- `driver.lua`: the `hue_light` driver's structure (dispatch, log,
  devloop, HUE_LOG forwarding, buffering before late init, `blocker()` /
  `ready()`, `notify()` with debug lines). Proxy commands: `ON`, `OFF`,
  `TOGGLE`, `SET_BRIGHTNESS_TARGET` (>0 → ON, 0 → OFF), `SET_LEVEL`,
  `SET_BRIGHTNESS_STOP` (settle), `SYNCHRONIZE` (report cached state). ON:
  `LIGHT_BRIGHTNESS_CHANGING` {0 → 100, RATE} then `HUE_SCENE_RECALL`, with
  a 2 s fallback that assumes ON [the bridge's `recall` STATE normally
  arrives first]. OFF: CHANGING {100 → 0} then `HUE_SCENE_OFF`, fallback
  assumes OFF. State: `HUE_SCENE_STATE` → `LIGHT_BRIGHTNESS_CHANGED` 100 or
  0 (only when it differs from what the proxy was last told, plus always
  after CHANGING). `DYNAMIC_CAPABILITIES_CHANGED` is not needed (the switch
  declares everything statically). Persists `hue_rid`, `hue_name`,
  `recall_as`. Superseded (2026-10-23): `SET_BRIGHTNESS_TARGET`,
  `SET_LEVEL` and `RAMP_TO_LEVEL` are the slider (0 = OFF, from off a
  recall at that level, while on `HUE_SCENE_LEVEL`), the state reported is
  the group's level under the on rule, keypad commands (`DO_PUSH`,
  `DO_RELEASE`, `DO_CLICK`, `BUTTON_ACTION`) and LED commands are handled,
  and `held_on`, the hold rates and the button colours are persisted too
  (`docs/keypad-design.md`, `docs/scene-dimmer-design.md`).
- Status texts: linked "Hue scene <name> in <group label>"; gone "Scene
  deleted in Hue since <date>; ON does nothing; re-link or Forget";
  forgotten "Forgotten by the bridge (was Hue scene <name>). Delete this
  device in Composer, or bind it again and use Link Devices"; unbound "Not
  bound to a Hue Bridge"; before the bridge answers "<name>" from the
  persisted copy or "Bound; waiting for the bridge".

## 4. Bridge side (`src/hue_bridge/bridge/scenes.lua`, new)

Registry: `bridge.registry` gains a `keys` option so a second instance
persists under `hue_scenes` / `hue_scene_tombstones` (no room mappings):

```lua
registry.new({ persist_get, persist_set, now, log,
               keys = { lights = "hue_scenes", tombstones = "hue_scene_tombstones", rooms = false } })
```
Entry fields: `device_id, proxy_id, name, group_rid, group_type, id_v1,
state, gone_since, unbound_since, created_room_id, created_at,
name_dismissed, recall_as?` (the device owns `Recall As`; the bridge only
caches what the device reported in its hello, for the report).

```lua
local scenes = require("bridge.scenes")
local sc = scenes.new({ http, send, bridge_id, log, now, project,      -- as lights.new's ctx
                        lights = <lights instance>,                   -- for groups, room mappings, pickers' room list
                        group_off = function(grouped_light_rid) end,  -- coalesced grouped_light off (driver.lua)
                        -- added later: group_dim (keypad holds), group_set (the slider with no known level)
                        persist_get, persist_set })
sc:load() / sc:save()
sc:resync(done)                 -- GET /scene (and /smart_scene count only); absorb; reconcile (project side as lights:
                                -- bound+present via driverFileName "hue_scene.c4z"; gone/back/new); CONFIGURE where
                                -- changed; STATE for every linked scene (reason "resync"); done(ok, err, sent)
sc:on_container(container)     -- `scene` items: status/name/group updates, add, delete (→ gone + STATE inactive)
sc:hello(rid, params) / sc:goodbye(params) / sc:forget_request(params) / sc:on_binding_changed(binding, class, bound, id)
sc:recall(params)               -- HUE_SCENE_RECALL: PUT recall; on 200 send STATE { active = requested, reason = "recall" }
sc:off(params)                  -- HUE_SCENE_OFF: ctx.group_off(group's grouped_light) ; STATE inactive
                                -- (as built: the unchanged state when nothing could be queued)
-- added later: sc:dim(params) (HUE_SCENE_DIM), sc:level(params) (HUE_SCENE_LEVEL)
sc:add_scene(rid, room_id, done)        -- one AddDevice("hue_scene.c4z", room, name) + bind + CONFIGURE + STATE
sc:add_all_of_group(group_rid, done)    -- every unimported, non-tombstoned scene of the group into its mapped room
sc:relink(device_id, rid) -> ok, text
sc:forget(device_id) -> ok, text        -- unbind + HUE_SCENE_FORGOTTEN
sc:link_devices() -> text               -- bound hue_scene devices the registry lacks (announced rid; else exact name)
sc:adopt_hue_names() -> text / sc:accept_names() -> text
sc:summary() -> "125 on bridge, 3 imported, 0 missing, 0 unbound, 0 deleted"
sc:attention_items() -> { text... }     -- merged by driver.lua into Attention after the lights' items
sc:picker_scenes() -> { { text = "Kitchen: Relax", value = rid }... }          -- unimported, grouped by group label then name;
                                        -- dynamic scenes suffixed " (dynamic)"; tombstoned last "(deleted from Composer <date>)"
sc:picker_groups() -> { { text = "Kitchen → Kitchen (7 scenes)", value = group_rid }... }   -- groups that have scenes
sc:picker_relink_devices() / sc:picker_forget_devices() -> as the lights' pickers
sc:count() / sc:entry(rid) (its `.device_id`; `device_for(rid)` was removed 2026-10-24)
```

Texts follow the lights' wording with "scene" in place of "light":
"Added Relax to Kitchen (device 2061)", "Added 7 scenes of Kitchen: …;
skipped 1 deleted in Composer: …", "Not added: Relax: Hue room Kitchen not
mapped; pick a room, or Set Room Mapping first", "Not added: Relax is
already imported (device 2061)", "Re-linked device 2061 (was Relax) to
Kitchen: Bright", "Forgot Relax (device 2061): unbound and left in the
project for you to delete", "Recall failed: HTTP 404 (scene gone?)".

Attention items: "1 scene missing from the bridge: Relax (device 2061,
since …) (Re-link Scene or Forget Scene)", "1 unbound scene device: …",
name differences counted together with the lights' ("… names differ …").

## 5. Bridge `driver.lua` / `driver.xml` (coordinator)

Properties: `Scenes` (read-only; `sc:summary()`), `Attention` now joins the
lights' and the scenes' items. Actions: `Add Scene` (params `Scene`
CUSTOM_SELECT:SceneList, `Room` CUSTOM_SELECT:RoomList), `Add All Scenes
Of Room` (param `Hue Room` CUSTOM_SELECT:SceneGroupList), `Re-link Scene`
(`Device` CUSTOM_SELECT:RelinkSceneList, `Scene` CUSTOM_SELECT:SceneList),
`Forget Scene` (`Device` CUSTOM_SELECT:ForgetSceneList), `Refresh Scenes`
(GET /scene now). `Adopt Hue Names`, `Accept Names As They Are` and `Link
Devices` run the lights' then the scenes' versions and join the texts.
Routing: `HUE_SCENE_*` commands to `state.scenes`; `on_connected` →
`lights:resync` then `scenes:resync`; `on_container` → both;
`OnBindingChanged` → both. A grouped_light queue
(`commands.new` with path `/clip/v2/resource/grouped_light/<rid>`,
limits 1/s) backs `group_off`. Correction (2026-10-24, as built): the
queue has its own bucket but the same constants as the lights' (80 ms
debounce, one PUT in flight per group, 10/s, burst 10); no 1/s limit is
configured. It also backs `group_dim` and `group_set`.

## 6. Dev loop, build, fake

Built as below. The house has run release builds without the dev loop
since 2026-10-22 (`docs/dev-loop.md`, "Current state").

- `tools/build.sh`: `DRIVERS=(hue_bridge hue_light hue_scene)`.
- `tools/devserver.py`: `TREES = ("bridge", "light", "scene")`; status gains
  `running_scene_version` / `local_scene_version`; `devctl status` shows it.
- `src/common/devloop.lua`: the bridge fetches and forwards every non-bridge
  tree; `DEV_RELOAD` carries `tree`; a receiver applies only the tree whose
  name matches its driver (`C4:GetDriverFileName()` "hue_light.c4z" → light,
  "hue_scene.c4z" → scene) and ignores the rest silently, so both kinds can
  share binding 1. Forwarding state is per tree.
- Fake runtime: `fake.load_driver("hue_scene", …)` already works from the
  driver.xml (proxy name "Hue Scene"); `fake.pair` for a scene device is the
  same call. Nothing else expected; report if something is missing.

## 7. Hardware checks (dev loop first, then Composer)

1. Resync with the scene GET: timing and memory (`collectgarbage("count")`
   before/after the decode, logged once at debug).
2. `Add Scene` through `devctl run` for one Bedside Lights scene into the
   Master Bedroom; `Recall As` default; ON/OFF from a `Proxy Command`; the
   scene event closes the loop within a second; OFF turns the two bedside
   lights off through one grouped_light PUT.
3. Recall the same scene from the Hue app or a Hue dimmer: the switch
   follows (`scene` item seen on hardware for API recalls; app/dimmer still
   to confirm).
4. Change one member light by hand: the switch goes OFF (status inactive).
5. Composer: install `hue_scene.c4z` (Add or update drivers) before any
   `Add Scene`; the `Add Scene` dialog's pickers; tile is a toggle; the
   scene device in the right room with the right name; delete-and-re-add.

Done on 2026-10-21/22 except check 3's Hue app and Hue dimmer routes, for
which no result is recorded (`docs/design.md`, "Scenes: verified on
hardware" and "Scenes build"). Since build 160 the tile is a slider, and
check 4's expectation is superseded: under the on rule a member light
changed by hand leaves the device on (`docs/scene-dimmer-design.md`).

## 8. Build split (one writer per file; the worktree is `~/projects/c4-hue-driver-scenes`)

| Agent | Owns | Done when |
| --- | --- | --- |
| Scene driver | `src/hue_scene/driver.lua`, `src/hue_scene/driver.xml`, `src/hue_scene/scene/*.lua` (if split), `tests/spec/scene_driver_spec.lua` | §2 + §3 complete with specs; `luacheck`, busted green |
| Model & fixtures | `src/hue_bridge/bridge/hue_model.lua` (`hue_model.scene(item)`, `update_scene`, `scene_state_params`), `tests/spec/hue_model_spec.lua`, `tests/fixtures/hue_resources.lua` (`F.scene`, scene events: recall status, inactive, add, delete) | shapes match the recorded house bridge items |
| Bridge scenes | `src/hue_bridge/bridge/scenes.lua`, `src/hue_bridge/bridge/registry.lua` (`keys` option + spec), `tests/spec/scenes_spec.lua`, `tests/spec/registry_spec.lua`, `tests/spec/scene_roundtrip_spec.lua` | §4 complete; round trip Add Scene → ON → PUT → event → switch ON → member light change → switch OFF |
| Coordinator | `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml`, `src/common/devloop.lua`, `tools/*`, `.luacheckrc`, docs, integration, hardware checks | §5–§7 |

`hue_model.scene(item)` shape, fixed here so the bridge-scenes agent can
start at once:

```
{ rid, name, group_rid, group_type ("room"|"zone"|"bridge_home"|nil), id_v1,
  active ("inactive"|"static"|"dynamic_palette"|nil), last_recall, auto_dynamic (bool), speed (number|nil) }
```
`hue_model.update_scene(scene, item)` merges a stream item and returns the
changed field names (`name`, `active`, `auto_dynamic`, `speed`, `group_rid`).
