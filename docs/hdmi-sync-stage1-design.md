# 2.0 beta stage 1: shared network code, entertainment areas, lights while they sync

The coordinator's contract for the first of the four beta stages of #514
(design [`hdmi-sync-design.md`](hdmi-sync-design.md) §9.3, contracts
[`hdmi-sync-contracts.md`](hdmi-sync-contracts.md) C3, C6, C7, C9). Every
builder works against this text. A change goes through the coordinator.

Branch `feat/hdmi-sync-stage1-514`, cut from the design branch
`feat/hdmi-sync-514`. Eight agents edit disjoint files at the same time. The
coordinator integrates, runs `tools/check.sh` and `tools/build.sh`, and
commits.

## 1. What stage 1 delivers

1. **The shared network code** moves into `src/common/` (contracts C3). The
   bridge behaves exactly as before.
2. **The Hue Bridge knows entertainment areas** (design 6.2, contracts C6).
   It reads the areas and each lamp's `mode`, shows an **Entertainment
   Areas** row, and fires **Sync Started** and **Sync Stopped** for any
   streamer (O10).
3. **Lights while their lamps stream** (design 6.3, contracts C7), the
   restore when a sync ends (O11), and the property **After A Sync Ends**.
4. **The "until 2.0" promises are kept** (O15): the hidden 1.1 action
   aliases and the hidden On State Follows property are removed, in the
   same commit that adds the 2.0 codename (Luthen) to
   `.github/codenames.json`, so the ledger spec passes.

Not in stage 1: the box driver, the `HUE_SYNCBOX` connection and its
messages (C5), `STOP_AREA`, and the box's name as a stream label. Those
are stage 2. Until then, the stream label is always `another app`.

## 2. Facts, and what checks T0 to T9 settle

The CLIP v2 field names are in `docs/entertainment-areas-research.md`
(read it; cite it in comments). Facts that rest on a check:
- **[assumed, T1]** A lamp's `light` resource reports `mode: "streaming"`
  while it streams and `mode: "normal"` after. An event `update` carries
  the change.
- **[assumed, T2]** While a lamp streams, Hue keeps reporting its state from
  before the stream (on, dimming, colour), not the colours on the TV.
- **[assumed, T7]** When a stream stops, the area's `status` turns
  `inactive`, the lamps' `mode` turns `normal`, and Hue then applies its own
  "light state after streaming" and reports it. The restore waits
  `entertainment.RESTORE_AFTER_S` (3 s, a constant until T7 measures it)
  after the last of those.
- **[assumed, T3]** A PUT to a streaming lamp answers 200 without changing
  it. The drivers never rely on that: they do not send one (O9).

T0 to T9 run on the house before stage 1 merges, not before it is built.

## 3. Shared network code (agent A)

- `src/common/https.lua`: the HTTPS core of today's
  `src/hue_bridge/bridge/http.lua` (request, stream, the keyed queue, peer
  text, URL and path checks, decode). Bridge-specific values become
  parameters of `https.new(opts)`: `ca_bundle` (path), `max_keyed`,
  `header_key` (the auth header's name and value shape: the bridge sends
  `hue-application-key`, the box will send `Authorization: Bearer`), the
  timeouts, the log prefix. A module-level instance stays possible.
- `src/common/tlscheck.lua`: today's `bridge/tlscheck.lua`, given its
  `https` instance and its decoy bundle as parameters.
- `src/common/mdns.lua`: today's `bridge/mdns.lua`, given the service name
  (`_hue._tcp` for the bridge, `_huesync._tcp` later), its config and its
  sweep as parameters. The #490 rules (query id, private and link-local
  addresses, the per-window cap) stay in the common module.
- `src/hue_bridge/bridge/http.lua`, `tlscheck.lua` and `mdns.lua` become thin
  modules that configure the common ones for the bridge and return a table
  with the same fields and functions as today, so every `require` and every
  existing spec stays unchanged and passes unchanged.
- New specs: `tests/spec/common_https_spec.lua`,
  `tests/spec/common_tlscheck_spec.lua`, `tests/spec/common_mdns_spec.lua`,
  for what the parameters change (another header, another service, another
  bundle).
- `tools/build.sh` already copies all of `src/common/` into every package.
  The light, scene and motion packages carry the modules without using them.

## 4. The bridge: entertainment areas

### 4.1 `hue_model.lua` (agent B1)

- The normalised light gains **`streaming`**: `true` when the item's
  `mode` is `"streaming"`, `false` when `"normal"`, absent otherwise, and
  kept through updates like every other field.
- `hue_model.STATE_FIELDS` gains `"streaming"`, after `"online"`, so
  `state_params` emits it as `"true"` or `"false"` like `on`.
- `hue_model.entertainment_area(item)`: one
  `/resource/entertainment_configuration` item, or a complete `add` event
  item, into `{ id, name, kind, status, streamer, lamps }`. `name` from
  `metadata.name`; `kind` from `configuration_type` (`screen`, `music`,
  `3dspace`, `monitor`, or `other`); `status` `"active"` or `"inactive"`;
  `streamer` the `active_streamer` rid or nil; `lamps` the light rids of
  `light_services`, sorted, or, when that is missing, the lights behind the
  channel members' `entertainment` services through the map below. Ids pass
  `hue_model.resource_id`; names are capped like other names.
- `hue_model.entertainment_owners(items)`: `/resource/entertainment` items
  into entertainment rid → light rid (the item's `renderer_reference`, or
  its `owner` device's light, as the research documents).
- `hue_model.area_update(area, item)`: an `update` event item applied to an
  area; returns the changed field names.

### 4.2 `src/hue_bridge/bridge/entertainment.lua` (new, agent B1)

`entertainment.new(ctx)`, `ctx` as `lights.new` takes it (`http`, `log`,
`now`, timers through `owner.defaults`), plus:

| ctx field | Meaning |
|---|---|
| `lights` | the `bridge.lights` instance, or a function returning it; read for `models` |
| `on_stream(area, started)` | an area started (`true`) or stopped (`false`) streaming |
| `on_lamps_changed(rids)` | some lamps' `streaming` changed; called once per settle |
| `after_sync()` | returns `"Put the lights back"` or `"As Hue decides"` |
| `put_back(rid, body, done)` | send one lamp's restore PUT body through the lights queue |
| `on_restored(area, count)` | the restore of an area sent `count` lamps |

Interface:
- `e:fetch_all(done)`: GET `/clip/v2/resource/entertainment_configuration`
  and `/clip/v2/resource/entertainment`, serially; replaces the areas.
  `done(ok)`. The first fetch after load fires no `on_stream`; a later one
  fires it for each area whose status changed since the last.
- `e:on_container(container)`: `entertainment_configuration` `add`,
  `update` and `delete` items. A status change `inactive` → `active` calls
  `on_stream(area, true)`; `active` → `inactive` calls
  `on_stream(area, false)` and starts the restore of 4.3.
- `e:lamp_mode(rid, streaming, before)`: the lights module reports that a
  lamp's `streaming` changed. `before` is a copy of its model from before
  the change, or nil at first sight. When it turns `true`, the lamp's
  **pre-sync state** is kept: `before` when given, else its current model
  (T2). The rid joins the changed set.
- `e:settle()`: the lights module calls it at the end of each container and
  each fetch. It calls `on_lamps_changed(rids)` once with the changed set,
  if any, and clears it.
- `e:is_streaming(rid)`: the model's `streaming` is true.
- `e:stream_label(rid)`: `"another app"` while the lamp streams, else nil.
  Stage 2 returns the bound box's name instead.
- `e:areas()`: the areas, sorted by name, each with `lamps` and a
  `streaming` flag.
- `e:row()`: the **Entertainment Areas** row text, see 4.4.
- `e:pre_sync(rid)`: the kept pre-sync state, for the specs.

### 4.3 The restore (O11; agent B1, wired by the coordinator)

- When an area stops and `after_sync()` is `"Put the lights back"`: wait
  until none of its lamps reports `streaming`, then
  `entertainment.RESTORE_AFTER_S` more. Then, for each of its lamps with a
  kept pre-sync state whose current model differs from it, call
  `put_back(rid, body)`. Differs means: `on` differs; or both on and
  brightness differs by more than 1; or the colour differs (`color_mode`,
  xy by more than 0.002, or mirek by more than 2).
- The body is a CLIP v2 `light` PUT: `{ on = { on = false } }` when the
  pre-sync state was off; else `on`, `dimming.brightness`, and `color.xy`
  or `color_temperature.mirek` as its `color_mode` says.
- A lamp still streaming in another area keeps its pre-sync state until
  that area stops too.
- Pre-sync states are then dropped. With `"As Hue decides"` they are
  dropped without a PUT. They are kept in memory only: after a reload in
  the middle of a sync, the state Hue reports is the pre-sync state (T2).
- Commands that came in during the stream are never applied (6.3): the
  devices did not send them and the bridge refused them (4.5).
- Coalescing a room or zone into one `grouped_light` PUT is allowed when
  every lamp of that group returns to the same state. Per lamp is
  acceptable in stage 1.
- `on_restored(area, count)` is called when the restore was sent, with the
  number of lamps.

### 4.4 Composer texts on the bridge (the coordinator's `driver.xml`)

| Item | Text |
|---|---|
| Row (read-only STRING property) | `Entertainment Areas`: `Living Room TV (5 lamps, syncing: another app) \| Office (3 lamps)`; `None` when the bridge has no areas. Capped by the rows rule (`rows.ROW_MAX`). |
| Property (LIST) | `After A Sync Ends`: `Put the lights back` (default), `As Hue decides` |
| Event id 1 | `Sync Started`; Last Action `Sync started: <area>` |
| Event id 2 | `Sync Stopped`; Last Action `Sync stopped: <area>` |
| Last Action after a restore | `Lights put back after the sync: <area> (<n> lamps)` |

### 4.5 The bridge's lights module (agent B2)

- `lights.RESOURCES` is unchanged. Each light's `streaming` comes with the
  light GET and the light events, through `hue_model`.
- The ctx gains `entertainment` (the instance, or a function returning it,
  optional). Whenever a light's `streaming` value changes, from a GET or an
  event, the module calls `ent:lamp_mode(rid, streaming, before)` before it
  sends that light's HUE_STATE. At the end of each container and each fetch
  it calls `ent:settle()`.
- **HUE_STATE** carries `streaming` (from `state_params`) and, while it is
  `"true"`, `stream_label` (from `ent:stream_label(rid)`).
- A streaming lamp is never announced offline because of the stream, and
  its offline timer does not run while `streaming` is true.
- `lights:is_streaming(rid)`, for the coordinator's HUE_SET and HUE_DIM
  guard.

The coordinator's `driver.lua`: HUE_SET and HUE_DIM for a streaming lamp
are not queued. The bridge logs `HUE_SET for <rid8>: the lamp syncs with
the TV; not sent` and answers the device with its full state.

### 4.6 Zone lights and scenes (agent B3)

- **Zone lights** (`zone_lights.lua`): HUE_STATE gains `lamps` (the count of
  the group's lamps) and `streaming_lamps` (how many stream). When all
  stream, it also carries `streaming = "true"` and `stream_label`; else
  `streaming = "false"`. While 0 < `streaming_lamps` < `lamps`, `on` and
  `brightness` come from the lamps that do not stream, by the rule Hue's
  `grouped_light` uses (on if any is on; brightness the average of those
  on). `zl:streaming_changed(rids)` re-sends the state of every zone light
  that holds one of those lamps.
- **Scenes** (`scenes.lua`): HUE_SCENE_GROUP gains `streaming_lamps`. While
  it is above 0, the group's on state and level that Keypad Follows "Room/zone
  lights" reads come from the lamps that do not stream, by the same rule.
  `sc:streaming_changed(rids)` re-sends HUE_SCENE_GROUP to the scenes of
  each group that holds one of those lamps.
- Both read a lamp's `streaming` from the lights module's `models`.

## 5. The devices

### 5.1 Hue Light and zone light (agent C1)

- HUE_STATE's `streaming`, `stream_label`, `lamps` and `streaming_lamps` are
  kept as the rest of the state (validated through `common/num.lua`).
- While `streaming` is `"true"`:
  - Status reads `Syncing with the TV (<stream_label>)`.
  - A light command (on, off, level, ramp, toggle, colour, colour
    temperature, a keypad hold or tap) is not sent. The proxy is answered
    at once with the known state (the CHANGING then CHANGED pair the
    driver sends today for an answered command, at the level it knows).
    Last Action reads `Not changed: the lamp follows the TV while it syncs
    (<stream_label>)` on a light, and `Not changed: the lamps follow the TV
    while they sync (<stream_label>)` on a zone light.
  - The device never goes offline because of the stream.
- A zone light with 0 < `streaming_lamps` < `lamps`: Status reads
  `<streaming_lamps> of <lamps> lamps syncing with the TV`; commands go out
  as today.
- When `streaming` turns `"false"`, Status returns to what it shows today.
- The hidden aliases go (O15): `Adopt Hue Name`, `Forget This Light` and any
  other `alias(...)` in `src/hue_light/driver.lua`, with their XML comment.

### 5.2 Hue Scene and Hue Motion Sensor (agent C2)

- **Scene:** HUE_SCENE_GROUP's `streaming_lamps` is kept. While it is above
  0, Status adds `; <n> lamps keep syncing with the TV` (`1 lamp keeps` for
  one). Recall is unchanged.
- **Scene, O15:** the hidden property `On State Follows` goes from
  `driver.xml`, with the code that copied its value into Keypad Follows
  (`docs/scene-tracking-design.md` D12) and its specs. The hidden aliases
  in `src/hue_scene/driver.lua` go.
- **Motion, O15:** the hidden aliases in `src/hue_motion/driver.lua` go,
  with their XML comment. Nothing else changes (T8 decides later).

### 5.3 The bridge's aliases and the ledger (agent D)

- The hidden 1.1 action aliases in `src/hue_bridge/bridge/actions.lua` go,
  with their dispatch entries, their log line, and their specs.
- `tests/fixtures/ledger.lua`: the alias rows and the On State Follows row
  go; rows are added for what stage 1 adds to the bridge (the row
  `Entertainment Areas`, the property `After A Sync Ends`, the events
  `Sync Started` id 1 and `Sync Stopped` id 2), in the ledger's own shape.
  `tests/spec/ledger_spec.lua` changes only if a rule needs it.

## 6. Documentation (agent E)

- `src/hue_bridge/www/documentation.html`: a new chapter, **Entertainment
  areas and syncing**: the row, the two events, After A Sync Ends, what
  the lights do while their lamps stream, and that sync boxes come in a
  later 2.0 beta. Remove any mention of the removed aliases.
- `src/hue_light/www/documentation.html` and
  `src/hue_scene/www/documentation.html`: **While the TV syncs**, in each
  tab's shape. The scene tab drops On State Follows.
- `src/hue_motion/www/documentation.html`: drop mentions of the removed
  aliases, if any.
- `docs/lights-design.md`, `docs/zone-light-design.md`,
  `docs/scene-dimmer-design.md` (or wherever HUE_SCENE_GROUP is specified):
  the new message fields, as dated amendments ("2.0 (#514): …").
- `docs/c4-lighting-guidelines.md`: departure **D21** (while a stream runs,
  Hue reports no state for a streamed lamp, so L6, L9, L53 and L68 cannot be
  met then), with the reason, and L87's status.
- `CHANGELOG.md` under Unreleased: the lines for owners and dealers
  (entertainment areas, Sync Started and Sync Stopped, lights while
  syncing, After A Sync Ends, the removed aliases and On State Follows,
  #514).
- Every text quoted from the drivers is copied from section 4.4 and 5.

## 7. Writers (one per file)

| Agent | Files (and their specs) |
|---|---|
| **A** | new `src/common/https.lua`, `tlscheck.lua`, `mdns.lua`; `src/hue_bridge/bridge/http.lua`, `tlscheck.lua`, `mdns.lua`; new `tests/spec/common_https_spec.lua`, `common_tlscheck_spec.lua`, `common_mdns_spec.lua` |
| **B1** | `src/hue_bridge/bridge/hue_model.lua`, new `bridge/entertainment.lua`; `tests/spec/hue_model_spec.lua`, new `tests/spec/entertainment_spec.lua`, new `tests/fixtures/hue_entertainment.lua` |
| **B2** | `src/hue_bridge/bridge/lights.lua`; `tests/spec/lights_spec.lua`, `roundtrip_spec.lua`, `offline_roundtrip_spec.lua`, new `tests/spec/lights_streaming_spec.lua` |
| **B3** | `src/hue_bridge/bridge/zone_lights.lua`, `scenes.lua`; `tests/spec/zone_lights_spec.lua`, `scenes_spec.lua`, `zone_light_roundtrip_spec.lua`, `scene_roundtrip_spec.lua` |
| **C1** | `src/hue_light/driver.lua`, `src/hue_light/driver.xml`, `src/common/device.lua`; `tests/spec/light_*_spec.lua`, `device_spec.lua` |
| **C2** | `src/hue_scene/driver.lua`, `driver.xml`; `src/hue_motion/driver.lua`, `driver.xml`; `tests/spec/scene_driver_spec.lua`, `motion_driver_spec.lua` |
| **D** | `src/hue_bridge/bridge/actions.lua`; `tests/spec/actions_spec.lua`, `tests/fixtures/ledger.lua`, `tests/spec/ledger_spec.lua` |
| **E** | the four `src/*/www/documentation.html`, `CHANGELOG.md`, `docs/lights-design.md`, `docs/zone-light-design.md`, `docs/scene-dimmer-design.md`, `docs/scene-tracking-design.md`, `docs/c4-lighting-guidelines.md` |
| Coordinator | this file, `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml`, `tests/helpers/fake_c4.lua`, `.github/codenames.json`, `.github/codename-notes.json`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, integration |

An agent that needs a change in a file it does not own asks the
coordinator in its hand-back and does not edit it.

## 8. Done

- Each change has a spec that fails before it and passes after it.
- `tools/check.sh` passes, `tools/build.sh` builds the four packages, and
  `python3 tools/lua_limits.py` passes.
- No `<capabilities>` change, so the install needs no controller reboot.
- The PR names #514 and the stage 1 issue; T0 to T9 are run on the house
  before it merges.
