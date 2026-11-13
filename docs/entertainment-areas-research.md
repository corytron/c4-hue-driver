# Hue entertainment areas and Control4: research for #514

Research agent R2, 2026-11-13, for issue #514 (2.0: Hue Play HDMI Sync
Boxes in Control4). This is read-only research. It decides nothing; the
2.0 design contract does.

It answers four questions: what an entertainment area is in CLIP v2, how
a sync box uses one, what this driver does today when lamps are streamed,
and how areas should map to Control4.

**How to read the marks.**

- **[verified: source]**: the source says it. A source is a public schema,
  model or fixture, a file and line of this repository, or the DriverWorks
  reference under `~/c4-tools/reference/`.
- **[community: source]**: a user report or a third-party project says it.
  It is true of that source. Nobody has seen it on a real bridge for this
  project yet.
- **[assumed]**: this document's inference. Section 4.5 lists the checks
  that would settle the important ones.

Signify's CLIP v2 reference and its Sync Box API reference need a developer
login. Nothing here is copied from them. Field names come from public
projects that model the API: openhue-api, aiohue, Home Assistant,
aiohuesyncbox and openHAB. External code links are pinned to the commit
read on 2026-11-13.

## Contents

- [1. Summary](#1-summary)
- [2. Entertainment areas in CLIP v2](#2-entertainment-areas-in-clip-v2)
- [3. The sync box and its area](#3-the-sync-box-and-its-area)
- [4. Lamps while a stream runs](#4-lamps-while-a-stream-runs)
- [5. This driver today](#5-this-driver-today)
- [6. Mapping areas to Control4](#6-mapping-areas-to-control4)
- [7. Recommendations for the design](#7-recommendations-for-the-design)
- [8. Open questions for the owner](#8-open-questions-for-the-owner)
- [Sources](#sources)

## 1. Summary

1. An entertainment area is one `entertainment_configuration` resource.
   It has a name, a type, a status (`active` or `inactive`), the
   application streaming to it, and channels that point at the lamps'
   `entertainment` services. It is not a room or a zone. It has no
   `grouped_light` and no scenes, and nothing in it names a room.
2. A bridge runs one stream at a time, the Bridge Pro included. An area
   holds up to 10 lamps.
3. A sync box streams to the one area it has selected. The choice is
   stored on the box (`hue_target`). Several boxes may select the same
   area, but two can never stream on one bridge at the same time.
4. While a stream runs, the bridge marks each streamed lamp
   `mode: streaming` and the area `status: active`. It does not update the
   lamps' on, brightness or colour. Users report the old state (often
   "off") for the whole session.
5. Users report that normal commands have no visible effect on streamed
   lamps. What the bridge answers, and whether a scene or room command ends
   the stream, is not known. Section 4.5 lists ten checks, each under a
   minute.
6. When the stream ends, the area's "Light state after streaming" setting
   (a Hue behavior instance) decides what the lamps do. The bridge then
   reports their new state as ordinary changes.
7. The driver ignores all of this today. A streamed lamp's tile keeps its
   old state. A command to it is shown as done after a short fallback,
   while the lamp keeps syncing.
8. **Recommended mapping:** an area is not a Control4 room and not a
   Control4 device. It belongs to the sync box that drives it, as the box's
   Entertainment Area setting. The bridge driver knows every area as data.
   An area's Control4 rooms are derived from its lamps through the existing
   room mappings, and are never mapped by hand. Each lighting device learns
   when its lamps are syncing and says so.

## 2. Entertainment areas in CLIP v2

### 2.1 `entertainment_configuration`: one per area

| Field | Meaning | Source |
|---|---|---|
| `id`, `id_v1` | The v2 id; `id_v1` is `/groups/N`. In API v1 an area was a group of type Entertainment. | [verified: [aiohue-fixture], [oh-ec]] |
| `metadata.name` | The name shown in the Hue app. A top-level `name` is deprecated. | [verified: [aiohue-ec] lines 122-147] |
| `configuration_type` | `screen`, `monitor`, `music`, `3dspace` or `other`. | [verified: [openhue-ec-get], [aiohue-ec] lines 54-61] |
| `status` | `active` while a stream runs, else `inactive`. | [verified: [openhue-ec-get], [aiohue-ec] lines 64-68] |
| `active_streamer` | `{rid, rtype: auth_v1}`: the application key that streams. Present while active. | [verified: [aiohue-ec] line 149, [aiohue-res] line 40; [hyperhdr] lines 1378-1387 read its `rid` as the owner]; absent while inactive [community: emulators [diyhue-ec] lines 173-174, [bifrost-ec] lines 258-265]. openhue's schema leaves it out [verified: [openhue-ec-get]]. |
| `stream_proxy` | `{mode: auto or manual, node}`: the lamp or bridge `entertainment` service that relays the stream to the other lamps. | [verified: [aiohue-ec] lines 71-84, [aiohue-ent] lines 37-40] |
| `channels[]` | `{channel_id, position {x, y, z}, members[] {service, index}}`. A member is one segment (`index`) of one `entertainment` service. A channel's position is the average of its members'. | [verified: [aiohue-ec] lines 14-51] |
| `locations.service_locations[]` | `{service, positions[], position, equalization_factor}`: where each lamp or segment stands. | [verified: [aiohue-ec] lines 86-108] |
| `light_services[]` | The `light` services of the area. Optional. | [verified: [aiohue-ec] line 144]. openHAB's fixture fills it; aiohue's anonymised Bridge Pro dump has three areas with empty channel and light lists [verified: [oh-ec], [aiohue-fixture]]. |

Writes: a PUT takes `metadata`, `configuration_type` and `action` (`start`
or `stop`) [verified: [openhue-ec-put]; [aiohue-ec] lines 110-119], and
`stream_proxy` and `locations` [community: [bifrost-ec] lines 235-246]. A
POST creates an area and a DELETE removes one [assumed]. This driver should
never do either (section 6.4).

The types in the Hue app's words (TV, PC monitor, music, 3D space, other)
are [assumed].

### 2.2 `entertainment`: one per capable device

| Field | Meaning | Source |
|---|---|---|
| `owner` | The device. | [verified: [aiohue-ent] line 36] |
| `renderer`, `renderer_reference` | The lamp can show a stream; `renderer_reference` names its `light` service. | [verified: [aiohue-ent] lines 37-43] |
| `proxy` | The device can relay a stream to other lamps. | [verified: [aiohue-ent] lines 39-40] |
| `equalizer`, `max_streams`, `segments` | Brightness equalisation; parallel streams supported; the segment layout (`configurable`, `max_segments`, `segments[{start, length}]`). | [verified: [aiohue-ent] lines 44-51] |

The bridge has one too. In aiohue's Bridge Pro dump (BSB003, firmware
1.78) it is a proxy, not a renderer, with `max_streams` 1 [verified:
[aiohue-fixture]].

**How to find an area's lamps.** Follow each channel member to its
`entertainment` service, then `renderer_reference` to the `light`. A
gradient lamp has several segments and so can feed several channels
[verified: [aiohue-ec] lines 14-37]. Use `light_services` only as a
fallback, since one real dump leaves it empty [assumed].

### 2.3 Areas, rooms and zones

- **No link to rooms.** No field of an area names a room or zone
  [verified: [openhue-ec-get], [aiohue-ec]]. In aiohue's Bridge Pro dump
  every `grouped_light` belongs to a room, a zone or the whole home, and
  every scene to a room or zone [verified: [aiohue-fixture], owner and
  group types counted]. So an area has no group light and no scenes of its
  own.
- **Spanning rooms.** The API does not stop an area from holding lamps of
  several rooms [verified: no such constraint in the schemas]. Setup guides
  describe the Hue app's flow as choosing a room first [community: search
  results for the Hue app's set-up, unverified pages]. Whether today's app
  lets one area mix rooms is [assumed: yes]. Check T0 reads the house's
  areas.
- **A room does not have to contain it.** Nothing ties a lamp in an area to
  any room [verified: as above]. A lamp in no Hue room can presumably be in
  an area [assumed].
- **A lamp in several areas** (a "TV" area and a "Music" area over the same
  lamps) is [assumed: allowed]. Only one area streams at a time anyway
  (2.4).
- **Colour lamps only.** Philips' FAQ asks why entertainment works only
  with colour-capable lamps [verified: the question headings of [hue-faq];
  the answers are not readable without the site's script].

### 2.4 Limits

- **One stream per bridge.** One active area per bridge, with at most 10
  lamps; Signify had not changed this for the Bridge Pro and called it an
  idea for later [verified: [hueblog-pro]; community: [hyperion-doc]]. The Bridge
  Pro's own `entertainment` service reports `max_streams` 1 [verified:
  [aiohue-fixture]].
- **One streamer per area.** Another application's start fails while one
  streams [community: [lumasync-ts]].
- **A stream needs data.** The bridge ends a stream after about 10 s
  without frames [community: [hueplusplus-60], 2020, API v1].
- **Control4 cannot stream.** A stream is a DTLS session from the
  streaming application to the bridge [community: [hueplusplus-60],
  [lumasync-ts]]. The DriverWorks reference has no DTLS API [verified: no
  match for "DTLS" anywhere under `~/c4-tools/reference/`]. So Control4 can
  watch streams and stop them, never run one. Stopping another
  application's stream with a PUT `action: stop` worked for Home Assistant
  users [community: [ha-forum-override]].

### 2.5 Start, stop and the event stream

- **Start.** The streaming application sends `action: start`, then opens
  its DTLS session. **Stop.** It sends `action: stop`, or goes quiet
  (2.4) [verified: [openhue-ec-put]; community: [hueplusplus-60]].
- **Who may stop.** HyperHDR stops only a stream of its own and reports
  any other as "in use" [verified: [hyperhdr] lines 1148-1170]. That is
  HyperHDR's choice, not a bridge rule. What a sync box does when its
  stream is stopped from the bridge is unknown (check T6).
- **What the event stream shows.** An `update` on the area with `status`
  and `active_streamer` when a stream starts and stops [community: Home
  Assistant's "entertainment area" binary sensor is `status == active`,
  and every Hue entity follows the `update` events of its resource
  ([ha-bs] lines 281-308, [ha-entity] lines 81-84); the emulators send it
  ([diyhue-ec] lines 236-244)]. An `update` on each streamed light with
  its `mode` [assumed: the bifrost emulator flips the lamps' mode with the
  action ([bifrost-ec] lines 219-221); no recording from a real bridge was
  found]. Check T1 records both.
- **During the stream.** The bridge sends no per-frame light updates: "the
  bridge does not update the fast light changes when syncing" [community:
  Michel, 2024-05-19, [ha-forum-sync6]].

## 3. The sync box and its area

### 3.1 How a box picks its area

- **What the box knows.** The box lists the bridge's areas under
  `hue.groups`: name, number of lamps, `active`, and the owner while active.
  It keeps the selected one in `hue.groupId` (API level 10 and later) and
  in `execution.hueTarget`, "the entertainment configuration id for bridge
  api v2" in aiohuesyncbox's words [verified: [hsb-hue] lines 44-57 and
  68-106, [hsb-exec] lines 72-73 and 88-89].
- **Who sets it.** The Hue Sync app at set-up, or a PUT to the box's `hue`
  resource [verified: [hsb-ctl] lines 63-65]. Home Assistant's sync box
  integration offers an "Entertainment area selection" entity and picks
  areas by exact name [verified: [ha-hsb] lines 48 and 114].
- **Its connection states.** `uninitialized`, `disconnected`,
  `connecting`, `unauthorized`, `connected`, `invalidgroup`, `streaming`
  and `busy` [verified: [hsb-enums] lines 56-64]. After a bridge change the
  area must be selected again when the state reads `invalidgroup`
  [verified: [ha-hsb] line 80]. `busy` means another application holds
  the bridge's stream [assumed: from the name].
- **Ids.** The box's group keys may be v1 group numbers or v2 ids
  [assumed]. The bridge gives both for every area (`id`, `id_v1`), so the
  bridge driver can translate [verified: [aiohue-fixture]].
- **Taking over.** The box can set a group's `active` to false
  (`PUT /hue/groups/{id}`) [verified: [hsb-ctl] lines 58-61]. This is
  probably how it ends another application's stream to start its own
  [assumed].
- **Signal drops end the sync.** The box stops syncing when its HDMI
  signal is interrupted or changes [community: Michel, 2024-05-19,
  [ha-forum-sync6]]. Each such stop runs the area's end state (4.4).

### 3.2 Several boxes and other streamers

- **Sharing an area.** Several boxes may select the same area [assumed:
  nothing in the box's model forbids it]. Because a bridge runs one stream
  (2.4), two boxes on one bridge never sync at the same time, even to
  different areas. The second reports `busy` [assumed].
- **Streams without a box.** The Hue Sync desktop app, TV apps, and the
  Hue app's music sync all stream to an area. A Home Assistant maintainer
  notes that the Hue app's Spotify sync runs over entertainment mode
  [community: [ha-120754]]. Each streams with its own application key.
- **Telling streamers apart.** The bridge gives only the `auth_v1` rid of
  the key [verified: 2.1]. A box device can tell that the stream is its own
  when its state reads `streaming` and its `hueTarget` is that area
  [assumed]. Any other stream reads as "another app".

### 3.3 Standalone mode, without the bridge

Newer boxes (aiohuesyncbox names HSB2, HSB3 and HSC1; API level 14) can
run in a `standalone` mode. They then stream to lamps over Bluetooth, and
list those lamps with each lamp's Zigbee MAC address [verified: [hsb-hue]
lines 7-41 and 83-100, [hsb-enums] lines 70-73]. The bridge then sees no
stream at all [assumed]. This driver already keeps each lamp's Zigbee MAC
(`zigbee_connectivity.mac_address`, `src/hue_bridge/bridge/hue_model.lua:14`
and `:329-331`), so a box device could name the lamps it takes [assumed].

## 4. Lamps while a stream runs

### 4.1 What the bridge reports

| What | During a stream | Source |
|---|---|---|
| `light.mode` | `streaming`, else `normal` | [verified: [openhue-light] lines 148-152, [aiohue-light] lines 91-99 and 263-265; Home Assistant shows it as an attribute, [ha-light] line 254] |
| `on`, `dimming`, `color` | Not updated: the values from before the stream. One user saw his lamps reported "off" while they synced. | [community: ManWithNoPlan, 2024-05-20, [ha-forum-sync108]; Michel, [ha-forum-sync6]] |
| `zigbee_connectivity.status` | One user saw a synced lamp "unavailable" in Home Assistant while it synced. Home Assistant's availability is exactly this status, so that bridge reported the lamp not connected. One report only. | [community: daffyduck42, 2025-09-09, [ha-forum-sync6]; verified: [ha-entity] lines 107-122] |
| The room's or zone's `grouped_light` | Its `on` and `dimming` come from the lamps, so they carry the old values too. | [assumed] |
| A scene's `status` | Unchanged by the stream starting. | [assumed] |

openhue also lists `mode` in the light PUT schema; aiohue does not
[verified: [openhue-light-put], [aiohue-light]]. Whether a PUT of
`mode: normal` would end a lamp's stream is unknown. The design should not
rely on it [assumed].

### 4.2 Commands to a streamed lamp

- **No visible effect.** "When light sync is enabled, no commands from HA
  seem to work" [community: Atrium, 2025-05-19, [ha-forum-override]].
  Hyperion's manual warns that no lamp of the area can be controlled until
  the stream stops [community: [hyperion-doc]].
- **Unknown.** The HTTP answer (200, 207 or an error), whether the bridge
  stores the new state and reports it, and whether the lamp takes it when
  the stream ends [assumed]. Checks T3 and T7.

### 4.3 Scene recalls and room or zone commands

- Whether a scene recall or a `grouped_light` command on the lamp's room
  or zone ends the stream, is ignored by the streamed lamps, or reaches
  them, is unknown [assumed]. One user had to turn off the zone instead of
  the light strip "to get it to work consistently" [community:
  daffyduck42, 2026-01-04, [ha-forum-sync6]]. Checks T4 and T5.
- Lamps of the room that are not in the area obey as usual [assumed].

### 4.4 When the stream ends

- **Hue's end state.** Each area has a "Light state after streaming"
  behavior instance (category `entertainment`, script `7719b841…`). Its
  `where` names the area and its `end_state` the outcome. aiohue's Bridge
  Pro dump holds `last_state` [verified: [aiohue-fixture];
  [hue-automations-research.md](hue-automations-research.md) "Light state
  after streaming"].
- **The app's options.** Users describe "stay at last color", "turn off"
  or a scene [community: Michel, 2024-05-19, [ha-forum-sync6]]. Which of
  them `last_state` is, and whether "back to the previous state" is one
  too, is unknown [assumed].
- **What Control4 would see.** The bridge reports the new state when the
  stream ends. One user's lamp, set to keep its last colour, read "on"
  about three seconds after the box powered off [community:
  [ha-forum-sync108]].
- **Restarting.** Once stopped, a stream can only be started again by its
  source (the box, the app or the TV) [community: Romquenin, 2026-01-19,
  [ha-forum-override]; and 2.4].

### 4.5 Checks on the house

Each takes under a minute. They run through the dev loop
([dev-loop.md](dev-loop.md)) or a probe on the VM, never through a released
driver. They need a sync box or the Hue Sync desktop app and the house
Bridge Pro.

| Check | What | Decides |
|---|---|---|
| T0 | GET `entertainment_configuration` and `entertainment`; list each area's lamps and their Hue rooms. | The area shapes; whether areas span rooms; whether `light_services` is filled. |
| T1 | Start a sync and log whole containers. | The area's `update` shape; whether lamps get a `mode` update; the order and the delay. |
| T2 | During the sync, GET a streamed lamp, its `zigbee_connectivity` and its room's `grouped_light`. | Whether the state is stale; whether the lamp reads not connected. |
| T3 | During the sync, PUT the lamp `on: false`, then a brightness. | The HTTP answer and body; whether an event follows; whether the lamp or the stream changes. |
| T4 | During the sync, turn the lamp's room off through its `grouped_light`. | The same for a room command. |
| T5 | During the sync, recall a scene of that room. | The same for a scene; the scene's `status`. |
| T6 | During a box's sync, PUT `action: stop` on its area with the driver's key. | Whether Control4 can end a box's stream; what the box reports; whether it starts again. |
| T7 | Stop the sync at its source. | The order of area and lamp events; the end state's reports; whether T3's command is applied late. |
| T8 | During the sync, walk through a MotionAware area that holds a streamed lamp. | Whether MotionAware keeps reporting while its lamps stream. |
| T9 | Only if two streamers exist: start the second during the first. | What the second box reports (`busy`?). |

## 5. This driver today

### 5.1 What it does with entertainment resources

Nothing, by design so far:

- **No reads.** A resync is six serial GETs: light, device,
  zigbee_connectivity, room, zone and bridge_home [verified:
  `src/hue_bridge/bridge/lights.lua:133-143`].
- **Events dropped.** Every container reaches every module
  [verified: `src/hue_bridge/driver.lua:991-996`]. Each module switches on
  its own types and drops the rest; the lights module handles light,
  zigbee_connectivity, device, room, zone and bridge_home items [verified:
  `src/hue_bridge/bridge/lights.lua:1372-1386`].
- **`mode` not read.** The normalised light has no mode field [verified:
  `src/hue_bridge/bridge/hue_model.lua:54-58`]. A device's `entertainment`
  service is not kept; only its light and zigbee_connectivity services are
  [verified: `src/hue_bridge/bridge/hue_model.lua:297-320`].
- **The audit.** It treats `entertainment_configuration` as neither a
  trigger nor a target [verified:
  `src/hue_bridge/bridge/automation_model.lua:66-82`]. It counts "Light
  state after streaming" instances on one row, "Not audited: N
  entertainment settings", and never writes them [verified:
  `src/hue_bridge/bridge/automation_model.lua:605-623`,
  `src/hue_bridge/bridge/automations.lua:999-1000` and `:1232-1234`;
  [hue-automation-audit-design.md](hue-automation-audit-design.md) H19].
- **No device kind.** The light driver refuses a configure of kind
  `entertainment` and stays a zone light [verified:
  `tests/spec/light_driver_spec.lua:3077-3083`].
- **Documented as a limit.** The README says areas are not represented
  [verified: `README.md:160-163`]. The project instructions list them as
  later work; [motion-design.md](motion-design.md) does not mention them
  [verified: grep].

### 5.2 What breaks or confuses an owner while lamps stream

| Surface | What happens today | Why | Guideline |
|---|---|---|---|
| Hue Light tile | Keeps the state from before the stream, often off, while the lamp is lit and changing. It does not jump: no reports arrive. | 4.1 | L6, L68 cannot be met |
| A command to the lamp | The PUT goes out. If the bridge answers 200 and reports nothing, the device assumes its target after the ramp plus 1 s, so the tile shows the command done while the lamp keeps syncing. If the bridge stores and reports the state, the same untruth with an event. If it refuses with a 4xx, the queue drops the state and answers "undelivered": the honest case. | `src/hue_light/driver.lua:664-692`; [lights-design.md](lights-design.md) `SET_BRIGHTNESS_TARGET`; `src/hue_bridge/bridge/commands.lua:28-41` | L87 |
| The end of the stream | The end state arrives as ordinary changes. Tiles jump to it, and Light On, Brightness Changed and Color Changed programming fires. True, but a surprise when the end state keeps the last streamed colour. | 4.4 | L68 met |
| Zone and room lights | The group's on and level include the stale lamp. A room Off turns the other lamps off, but the stale lamp can keep the tile on, after the fallback showed it off: the tile goes off, then back on. | `src/hue_bridge/bridge/hue_model.lua:930-938`, D7 | L9, L87 |
| Hue Scene | The recall goes out; the other lamps take the scene. The scene's status may read active though some of its lamps sync. Keypad Follows "Room/zone lights" reads the stale lamps. | [scene-tracking-design.md](scene-tracking-design.md) O1 | L64 |
| Keypad LEDs | Follow the stale state. | as above | L53 |
| Offline | If the bridge reports a streamed lamp not connected (one report, 4.1), its device goes Offline: the tile is disabled and offline programming fires, though the lamp works. | [offline-design.md](offline-design.md) §1.5 | L56, L86 |
| Holds and ramps | A keypad hold on a streamed lamp ramps nothing; the device's estimate drifts until the fallback ends it. | [assumed] | L42 |
| Load groups | As commands and zone lights above. | [load-groups-design.md](load-groups-design.md) | L67 |
| Resyncs | Read the stale state, which agrees with the events. Nothing tells the driver that a lamp streams at start or after a reconnect, because areas are not read and `mode` is dropped. | 5.1 | L5 |
| Automation audit | Correct as it is. It does not show what each area's end state will do to Control4's lamps. | 5.1 | — |
| MotionAware | Unknown (check T8). | — | — |

### 5.3 What each device should do while its lamps stream

A proposal for the design contract, built on the guidelines in 5.4.

| Device | State shown | Commands | Status and programming |
|---|---|---|---|
| Hue Light whose lamp streams | The last state Hue reported. No events while the stream runs. Never offline because of the stream. | Default: not sent. The device answers at once, CHANGING then CHANGED at the level it knows, and logs why. Owner's choice (question 2): end the sync first, then apply. | Status "Syncing with TV area (Living Room sync box)" or "(another app)"; on a refused command "Not changed: syncing with TV area. Stop the sync to control it". A read-only property or variable the programming can test [assumed: a new variable in `driver.xml`; `C4:AddVariable` is documented, `~/c4-tools/reference/docs-driverworks-api/source/includes/36_variable/_1-AddVariable.md`]. |
| Zone or room light with some lamps streaming | On, level and colour from the lamps that do not stream, while any of its lamps streams. | Sent as today; the lamps that do not stream obey. "Dim the room while the TV syncs" keeps working. | "2 of 6 lamps syncing (TV area)". |
| Zone or room light with all its lamps streaming | As a Hue Light. | As a Hue Light. | As a Hue Light. |
| Hue Scene | Tracking as Hue reports it. Keypad Follows "Room/zone lights" reads only the lamps that do not stream. | Recalled as today. | "2 lamps of Living Room are syncing and keep syncing". |
| Keypad LEDs | Follow their device. No special case. | — | — |
| Hue Motion Sensor (MotionAware) | As check T8 shows. | — | — |

When the stream ends, every device reports Hue's end state as an ordinary
change from outside Control4.

### 5.4 Control4 guidelines

Read against [c4-lighting-guidelines.md](c4-lighting-guidelines.md) and
the sources it names. From the light_v2 best practices
(`~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/27_proxy_specific_info/_50-LIGHTV2BESTPRACTICE.md`)
the relevant rules are: report transitions with CHANGING and CHANGED, and
never flood the proxy with intermediate levels. From the Extras page
(`_51-LIGHTV2EXTRAS.md`): device features the proxy does not know go on
the Extras tab, hidden rather than removed when unavailable.

| Row | How 5.3 stands |
|---|---|
| L6, L53, L68 (changes from outside reach the proxy) | Cannot be met while a stream runs: Hue reports no state. Met again when it ends. A departure (below). |
| L7 (no flood of levels) | Met: stream frames are never reported, and Hue sends none. |
| L9 (a lit light never reads off) | Departs during a stream when the lamp was off before it: the device keeps "off" while the lamp is lit, because Hue gives no level to report. Covered by the departure. |
| L56, L86 (online state) | Met by the rule "never offline because of a stream", whatever check T2 shows. |
| L87, L89 (commands must not look delivered) | Met by answering a command to a streamed lamp at once with the known state. Failed today if check T3 shows a 200 with no report. |
| L88 (Status says what is wrong and what to do) | Met by the Status texts of 5.3. |
| L58 (lighting lives in Lighting as light_v2 devices) | Met by not making an area a light_v2 device: it has no level or colour of its own. |
| L60 (Extras) | Not needed for 2.0. A "Stop syncing" button on the Extras tab is possible later, written by this project (never Snap One's library). |
| L64 (scene tracking) | Unchanged; the scene follows Hue's status. |
| L67 (load groups) | As zone lights. |
| L76 (actions are for setup) | Met: choosing a box's area is a property and a programming command, not an everyday action. |
| L79 (never remove or renumber events or variables) | Met if new events and variables are only added, and per-area events keep their ids (question 3). |

**A new departure for §5 of the guidelines.** D21: "While a lamp is in a
Hue entertainment stream, Control4 can neither see nor change it. Its
device keeps the last state Hue reported and says that it is syncing."
Reason: Hue reports no state during a stream, and by user reports ignores
normal commands (4.1, 4.2). Its wording waits for checks T2 and T3.

## 6. Mapping areas to Control4

### 6.1 The options

- **R. An area is a Control4 room** (the owner's first guess): a new
  mapping from each area to one Control4 room.
- **B. An area belongs to the sync box that drives it**: the box device's
  Entertainment Area setting, read from the box and changed only on a click
  or a programming command.
- **D. An area is its own Control4 device**: an "ambience" switch, or a
  light-like device.
- **M. Through the existing mappings**: an area's Control4 rooms are
  derived from its lamps. A lamp with a Hue Light device is in that
  device's Control4 room. Otherwise its Hue room's mapping gives the room
  (Set Room Mapping and the automatic mapping by name,
  `src/hue_bridge/bridge/lights.lua:1036-1057` and `:1914-1920`;
  [scene-tracking-design.md](scene-tracking-design.md) Part 2, O4: each
  Hue room maps to one Control4 room).

### 6.2 The cases

| Case | R: area = room | B: box's setting | D: own device | M: derived rooms |
|---|---|---|---|---|
| A room with a TV and a sync box; the area's lamps in that room | Works | Works: the box sits in the TV's room and AV path | Works, one more device | Gives that room |
| An area spanning two Control4 rooms (an open-plan living room and kitchen) | Must pick one; the other room's lamps are taken without it knowing | Works: the box drives the area wherever its lamps are | The device sits in one room | Gives both rooms |
| Several areas for one TV ("Movie", "Game") | Many-to-one works, but says nothing about which area is in use | Works: the box's area is one setting; a programming command switches it | One device per area, mostly idle | Gives each area's rooms |
| Areas used without a box (PC app, TV app, Hue's music sync) | Gives their events a home | Not covered: there is no box | Covered | Gives rooms, but no events |
| Two boxes on one bridge | Works | Each box shows its area, and `busy` when the other syncs | Works | Works |
| A lamp in no Hue room and with no Hue Light device | Not affected | Not affected | Not affected | No room for that lamp |
| Cost over the life of the system | A new mapping to keep. Area names ("TV area") rarely match room names, so it is mostly by hand. | None: mirrors the box | Devices to create, delete and restore, each a lifecycle case | None: derived |
| Fits Hue's model | No: Hue links an area to its streamer, not to a room | Yes: the box selects its area | Partly | Yes |
| Fits Control4's model | Partly: rooms hold devices, and an area is not a device | Yes: a setting of an AV device | A non-light device in Lighting would break L58 | Yes |

### 6.3 Recommendation: B with M, and the areas as bridge data

An area is neither a Control4 room nor a Control4 device:

1. **The box owns its area.** The sync box device shows the area it uses
   and offers to change it. That is Hue's own model: the box selects
   `hue_target`, and a stream belongs to its streamer (3.1).
2. **Rooms come from the box and the lamps.** A Control4 room holds
   devices. The box is placed in its TV's room and sits in that room's AV
   path, so starting and ending sync follows the room's AV session (the
   other 2.0 research covers the routing). The lamps' rooms come from M.
3. **Spanning areas and several areas per TV need no choices.**
4. **Nothing new to maintain.** There is no new mapping that could go
   stale and need a manual fix later (the owner's rule on automation).
5. **It agrees with Part 2 of the scene contract.** Each Hue room keeps
   mapping to exactly one Control4 room. An area reuses those mappings
   instead of adding a second kind.
6. **The lighting devices get what matters to them directly**: that their
   lamps are syncing (5.3).
7. **The bridge driver knows every area as data**: name, type, lamps,
   derived rooms, status and streamer. It fires the start and stop events
   that programming needs, including for areas without a box (question 3).

What the owner's first guess gets right: in the common case the area's
derived rooms are exactly the box's room. The box device can show that
("TV area: lamps in Living Room") and point out a mismatch ("TV area's
lamps are in Kitchen; this box is in Living Room"). That gives the guess's
clarity without a mapping to keep.

### 6.4 What is automatic, offered, or forbidden without a click

"Box" means the sync box device of the 2.0 design.

| Case | Automatic | Offered (one click or a programming command) | Forbidden without a click |
|---|---|---|---|
| Area created in the Hue app | Read it (event `add`, or the next resync). List it on the bridge and in each box's choices. | — | Creating a Control4 device for it; selecting it on a box |
| Area renamed | New name everywhere. The box's selection is by id and stays. | — | — |
| Lamps added to or removed from an area | Members and derived rooms read again. | — | Moving any Control4 device between rooms |
| Area deleted in Hue | Marked deleted. A box that used it shows `invalidgroup`. Programming that names it keeps its events (L79). | Forget the area's events and variables | Deleting events or variables used in programming |
| Area made again under the same name (new id), or the bridge restored or replaced | — | Select the new area on the box that had the old one, by name | Selecting it by itself (as O6 of the scene contract) |
| A box's area changed in the Hue Sync app | Shown on the box device. | — | Changing it back |
| A stream starts (any streamer) | Lamps marked syncing; Status texts; start events. | — | — |
| A stream stops | Marks cleared; Hue's end state reported as it arrives. | — | Overriding Hue's end state by itself |
| A stream stops without an event (bridge restart, stream gap) | The next resync reads `status` and `mode`. | — | — |
| A Control4 command to a streamed lamp | Answered with the known state; Status says why. | Per device, the owner's choice to end the sync first (question 2) | Ending a stream unless that choice is set |
| A second streamer while one runs | The second box shows `busy`. | — | Ending the first stream by itself |
| The "Light state after streaming" setting | Shown per area as information. | — | Writing it (audit H19; question 4) |
| A box in standalone mode | Its lamps marked syncing from the box's list, matched by Zigbee MAC [assumed]. | — | — |
| A Hue Light or box device moved to another Control4 room | Derived rooms follow. | — | — |
| A project restore or a driver update | Events and variables keep their ids. | — | Renumbering them |
| Creating, editing or deleting areas on the bridge | Never | Never: that is the Hue app's job | Always |

## 7. Recommendations for the design

1. **Read areas.** Add GET `/clip/v2/resource/entertainment_configuration`
   and `/clip/v2/resource/entertainment` to the resync: two more serial
   GETs. Handle `add`, `update` and `delete` items of both types. Keep per
   area: `id`, `id_v1`, name, type, status, streamer rid, member lamps
   (through channels, `entertainment` and `renderer_reference`, with
   `light_services` as a fallback) and the derived Control4 rooms.
2. **Read `light.mode`** from GETs and events into a per-lamp `streaming`
   flag. A lamp is syncing when its mode says so or an active area holds
   it, since either report may come first (check T1).
3. **No area device and no area mapping.** Derive an area's Control4
   rooms (6.1 M). Do not add an area-to-room table.
4. **The box owns the area.** The box device shows its Entertainment Area
   (the box's `hueTarget` or `groupId`, translated to the bridge's name),
   offers the bridge's areas as a property list and a programming command,
   and never changes it by itself.
5. **Lighting devices while their lamps sync** follow 5.3: keep the last
   state, never go offline for a stream, answer commands at once with the
   known state, say why in Status, and offer a value programming can test.
6. **Zone and room lights** compute on, level and colour from their
   non-streaming lamps while any lamp streams, and send commands as today.
7. **Bridge-level programming.** The bridge device fires "Entertainment
   area started" and "stopped" events and keeps variables for the active
   area's name and streamer, for streams without a box. `C4:AddEvent`
   (`~/c4-tools/reference/docs-driverworks-api/source/includes/7_event/_1.1-AddEvent.md`,
   from 2.8.0) makes per-area events possible, with ids kept in persisted
   state (question 3). `C4:FireEvent` (`7_event/_3-FireEvent.md`) fires
   them.
8. **Stop Syncing** as a programming command: on the box device through
   the box's own API (preferred, since the box knows it stopped), and on the
   bridge device per area with `action: stop`, once check T6 shows what a
   box does then.
9. **The audit** keeps H19: never write the end state. The bridge's area
   list shows each area's end state as information, so the owner can see
   what Hue will do to Control4's lamps when a sync ends.
10. **Run checks T0 to T9** before the contract is final. Write the
    answers into #514 as comments and turn the [assumed] rows of 4.1 to
    4.3 into facts.
11. **Write departure D21** into §5 of
    [c4-lighting-guidelines.md](c4-lighting-guidelines.md) and into the
    "Control4 guidelines" section of every lighting contract 2.0 touches.
12. **Standalone boxes.** If the box API lists its Bluetooth lamps with
    their Zigbee MAC (3.3), the box device tells the bridge which lamps it
    takes, matched by MAC, so those lamps read as syncing too.
13. **Update the README's Limits line** (`README.md:160-163`) when areas
    become visible in 2.0.

## 8. Open questions for the owner

1. **The mapping.** The recommendation differs from the first guess: an
   area belongs to the box that drives it, and its Control4 rooms are
   derived from its lamps, with no area-to-room mapping (6.3). Is that
   acceptable, or should an area also get a room of its own?
2. **A Control4 command to a syncing lamp.** (a) Leave the sync running,
   answer at once with the lamp's known state and say why (recommended);
   or (b) end the sync, then apply the command. (b) means a lighting
   scene that includes the TV strip would end the sync that the movie just
   started. One default for all devices, or a per-device property?
3. **Streams without a box** (the Hue Sync desktop app, a TV app, Hue's
   music sync). (a) Bridge-level start and stop events, with the area's
   name in a variable (recommended for 2.0); (b) one pair of events per
   area, added as areas appear; or (c) nothing until a later release.
4. **Who decides what the lamps do when a sync ends.** Today Hue's per-area
   setting decides, and the driver only shows it. Should 2.0 instead
   offer, on a click, to set it to keep the last state, so that Control4
   programming on the "sync stopped" event decides? That would be a write
   to a Hue automation, which the audit forbids today (H19).

## Sources

Repository files are cited by path and line in the text. The DriverWorks
reference is cited by its path under `~/c4-tools/reference/`.

[openhue-ec-get]: https://github.com/openhue/openhue-api/blob/1ffc817857abf456d5ff2ae50400ef768dbce28e/src/entertainment_configuration/schemas/EntertainmentConfigurationGet.yaml
[openhue-ec-put]: https://github.com/openhue/openhue-api/blob/1ffc817857abf456d5ff2ae50400ef768dbce28e/src/entertainment_configuration/schemas/EntertainmentConfigurationPut.yaml
[openhue-light]: https://github.com/openhue/openhue-api/blob/1ffc817857abf456d5ff2ae50400ef768dbce28e/src/light/schemas/LightGet.yaml
[openhue-light-put]: https://github.com/openhue/openhue-api/blob/1ffc817857abf456d5ff2ae50400ef768dbce28e/src/light/schemas/LightPut.yaml
[aiohue-ec]: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/aiohue/v2/models/entertainment_configuration.py
[aiohue-ent]: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/aiohue/v2/models/entertainment.py
[aiohue-light]: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/aiohue/v2/models/light.py
[aiohue-res]: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/aiohue/v2/models/resource.py
[aiohue-fixture]: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/tests/fixtures/v2_resources.json
[oh-ec]: https://github.com/openhab/openhab-addons/blob/68fe65914646aa391bbe3ba07d47c09aa28b3f26/bundles/org.openhab.binding.hue/src/test/resources/entertainment_configuration.json
[ha-bs]: https://github.com/home-assistant/core/blob/2317e5ae4fb9fb74e2123c58be2b8fc118b6b848/homeassistant/components/hue/v2/binary_sensor.py
[ha-light]: https://github.com/home-assistant/core/blob/2317e5ae4fb9fb74e2123c58be2b8fc118b6b848/homeassistant/components/hue/v2/light.py
[ha-entity]: https://github.com/home-assistant/core/blob/2317e5ae4fb9fb74e2123c58be2b8fc118b6b848/homeassistant/components/hue/v2/entity.py
[hsb-hue]: https://github.com/mvdwetering/aiohuesyncbox/blob/53a3f502f637100c270e85b9509565d607edbbd5/aiohuesyncbox/models/hue.py
[hsb-enums]: https://github.com/mvdwetering/aiohuesyncbox/blob/53a3f502f637100c270e85b9509565d607edbbd5/aiohuesyncbox/models/enums.py
[hsb-exec]: https://github.com/mvdwetering/aiohuesyncbox/blob/53a3f502f637100c270e85b9509565d607edbbd5/aiohuesyncbox/models/execution.py
[hsb-ctl]: https://github.com/mvdwetering/aiohuesyncbox/blob/53a3f502f637100c270e85b9509565d607edbbd5/aiohuesyncbox/controllers/hue.py
[ha-hsb]: https://github.com/mvdwetering/huesyncbox/blob/71da2f95fb75e27e713f7f7fdb5326aae0b281cc/README.md
[hyperhdr]: https://github.com/awawa-dev/HyperHDR/blob/b1451f2868072c5b8eda0ae61c0fcf33ecc1bfc5/sources/led-drivers/net/DriverNetPhilipsHue.cpp
[bifrost-ec]: https://github.com/chrivers/bifrost/blob/12d9e37e6ea032fb0708ddcd2faaa6db0133d7c8/src/routes/clip/entertainment_configuration.rs
[diyhue-ec]: https://github.com/diyhue/diyHue/blob/673b0e2386e128fd53578f7aadc07cf6fa0f8bfe/BridgeEmulator/HueObjects/EntertainmentConfiguration.py
[hyperion-doc]: https://docs.hyperion-project.org/user/leddevices/network/philipshue.html
[hueblog-pro]: https://hueblog.com/2025/09/04/hue-bridge-pro-almost-all-the-answers-to-the-most-important-questions/
[hue-faq]: https://www.philips-hue.com/en-sg/support/topic/entertainment/100085
[lumasync-ts]: https://lumasync.app/docs/hue/troubleshooting/
[hueplusplus-60]: https://github.com/enwi/hueplusplus/issues/60
[ha-120754]: https://github.com/home-assistant/core/issues/120754
[ha-forum-sync6]: https://community.home-assistant.io/t/philips-hue-play-hdmi-sync-box-custom-integration/204772?page=6
[ha-forum-sync108]: https://community.home-assistant.io/t/philips-hue-play-hdmi-sync-box-custom-integration/204772/108
[ha-forum-override]: https://community.home-assistant.io/t/overriding-philips-hue-light-sync-with-home-assistant/892474

- openhue-api: [openhue-ec-get], [openhue-ec-put], [openhue-light],
  [openhue-light-put] (commit of 2026-04-15).
- aiohue: [aiohue-ec], [aiohue-ent], [aiohue-light], [aiohue-res], and the
  anonymised Bridge Pro dump [aiohue-fixture] (commit of 2026-11-09).
- openHAB: [oh-ec]. Home Assistant: [ha-bs], [ha-light], [ha-entity]
  (commit of 2026-11-10), [ha-120754].
- Sync box: aiohuesyncbox [hsb-hue], [hsb-enums], [hsb-exec], [hsb-ctl]
  (2026-11-04); Home Assistant's sync box integration [ha-hsb]
  (2026-11-10).
- Streaming clients and emulators: [hyperhdr], [hyperion-doc],
  [bifrost-ec], [diyhue-ec], [lumasync-ts], [hueplusplus-60].
- Signify and Hue press: [hue-faq], [hueblog-pro].
- Forums: [ha-forum-sync6], [ha-forum-sync108], [ha-forum-override].
