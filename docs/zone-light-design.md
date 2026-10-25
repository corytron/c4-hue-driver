# Hue zones and rooms as Hue Light devices: the contract

Research draft for the coordinator (2026-10-24, against build 180; standing
approval applies, nothing here waits on the owner). Owner's request: "I use
certain zones just to control 2 lamps in a room in tandem. aka bedside
lights zone represents 2 lamps inside a larger room with other lights. But I
want to be able to address that zone as a v2 light device added to the
bedroom, for instance." Style and precedents: `docs/smart-scenes-design.md`
(a kind in an existing driver), `docs/scenes-design.md` and
`docs/import-design.md` §1 (the three rules), `src/hue_bridge/bridge/lights.lua`
and `scenes.lua` (the lifecycle code this copies).
Current (2026-10-25, build 316): that lifecycle code is shared since #56:
`bridge/owner.lua` holds it once for the lights, the scenes and the zone
lights.

## 1. Problem

A Hue zone (or room) has one `grouped_light` service that turns, dims and
colours all its lights with one request, and Hue reports its on/off and
average brightness. Today the driver uses it only behind Hue Scene devices.
The owner wants the zone itself as a light_v2 light in a Control4 room of
his choosing: tile, slider, colour, keypad Button Links with hold-to-dim and
LEDs, two-way state, and the same lifecycle handling as a light.

### Facts

| Fact | Status |
| --- | --- |
| A grouped_light GET item and its events carry `on.on` (true if any member is lit) and `dimming.brightness` (the average of the lit members), plus `alert`, `signaling`, `owner {rid, rtype}`, `id_v1 "/groups/N"`; a new one also announces `dimming_delta` and `dynamics`. No colour or colour-temperature state has ever appeared in one. | verified on the house for on/brightness (`docs/smart-scenes-research.md` §7 V4, V12; `src/hue_bridge/bridge/scenes.lua` `absorb`, `on_grouped_light`; fixtures `F.events.zone_add`, `F.events.scene_recalled`); "no colour" verified only on every item logged so far, assumed in general [community: openhue `GroupedLightGet`; Home Assistant derives a group's colour from its member lights] |
| A grouped_light PUT accepts `on`, `dimming.brightness`, `dimming_delta` (up/down/stop with `brightness_delta`), `dynamics.duration`. | verified (`docs/design.md` "Keypad and scene dimmer: verified on hardware"; research §7 V11 absolute brightness) |
| A grouped_light PUT accepts `color.xy`, `color_temperature.mirek` and `color_temperature_delta`; members that cannot follow ignore the part they cannot do. | verified for `color.xy` and `color_temperature.mirek` on the house (2026-10-24, build 199: the owner's colour picks on the Bedside Lights tile reached both lamps); `color_temperature_delta` still assumed [community: openhue `GroupedLightPut`, aiohue] |
| `on=true` on a grouped_light lights every member at its own last brightness and colour (a Zigbee group on). | assumed; check H2 |
| `on=false` on a grouped_light deactivates the scenes of that group (ordinary and time-based); a whole-group `dimming_delta` or absolute `dimming.brightness` keeps them active. | verified (research §7 V9, V11) |
| A zone with no lights has no grouped_light (empty `services`); deleting a zone deletes its grouped_light; a light can be in any number of zones; a room's children are devices, a zone's are lights. | verified (fixtures `F.zone` Attic comment, hardware 2026-10-21; research §7 V14; `bridge/groups.lua` header) |
| Hue asks for at most about one grouped_light request a second (ten for lights). | verified (Core Concepts page saved by the owner, "Limitations") |
| light_v2: `dimmer`, `supports_color`, `supports_color_correlated_temperature`, the CCT min/max and `supports_target` are dynamic capabilities, changed at run time with the `DYNAMIC_CAPABILITIES_CHANGED` notify; the two colour flags must travel in one notify. `hide_proxy_properties` is not dynamic (on OS 3.x; the proxy reference's "What's New in 4.2.1" makes it dynamic from OS 4.2.1). | verified (`~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/5_light_v2_capabilities/_5-DIMMER.md`, `_30-SUPPORTSCOLOR.md`, `_31-SUPPORTSCOLORCORRELATEDTEMPERATURE.md`, `_8.4-COLORCORRELATEDTEMPERATUREMAX.md`, `_38-HIDEPROXYPROPERTIES.md`; `35_Light_v2_protocol_notifications…/_8-DYNAMICCAPABILITIESCHANGED.md`) |
| The Hue Light driver already sends that notify on every `HUE_CONFIGURE` from `has_color`/`has_cct`/mirek bounds, and the colour controls appeared on the house's lights that way. A later change of the flags on a live device is documented ("capabilities that change during runtime") but not yet seen on the house. | verified / assumed (`src/hue_light/driver.lua` `HUE_CONFIGURE`, `src/hue_light/light/caps.lua`; `docs/status.md`) |
| Add Light = `lights:add_light` → `owner:create`: `C4:AddDevice("hue_light.c4z", room_id, name, cb)`, then `C4:Bind(bridge, 1, protocol_id, 1, "HUE_BRIDGE")`, registry entry, `HUE_CONFIGURE` + `HUE_STATE`. AddDevice is for user-initiated use only. | verified (`src/hue_bridge/bridge/lights.lua`; `~/c4-tools/reference/docs-driverworks-api/source/includes/9_helper/_0.1-AddDevice.md`, `_1-bind.md`) |
| A zone scene's Control4 room: the zone's entry in `hue_rooms` (Set Room Mapping lists zones too), else the `Room` picked, else refused "Not added: <scene>: Hue room <Zone> (zone) not mapped; pick a room, or Set Room Mapping first". Zone scenes are named "<Zone> <Scene>". | verified (`owner.lua` `room_for_add`, `default_room` (in `scenes.lua` until #56); `scenes.lua` `creation_name`; `lights.lua` `set_room_mapping`, `picker_hue_rooms`) |
| `C4:GetDevices({C4iNames="hue_light.c4z"})` returns every device of that driver (used by Link Devices and the reconcile to tell lights from scene devices); `GetBoundConsumerDevices` values are the driver `<name>`, not the Composer name. | verified (`lights.lua` `project_lights`, `link_candidates`, with `link_devices` in `owner.lua` since #56; `docs/design.md` "Project APIs") |
| Adding properties or actions to the bridge's `driver.xml` (it has no `<capabilities>`) and Lua changes take effect with an ordinary "Add or Update Driver"; only a `<capabilities>` change needs the controller reboot. | verified (`docs/status.md` "How builds reach the house"; import-ui and scenes installs, `docs/import-design.md` §2) |
| A deleted device sends `HUE_GOODBYE {rid, device_id}` from `OnDriverRemovedFromProject`; the bridge tombstones the entry; Add Light lists it "(deleted from Composer <date>)" and clears the tombstone. | verified (`src/hue_light/driver.lua`, `owner.lua` `goodbye` (in `lights.lua` until #56), `registry.lua`; hardware 2026-10-22) |
| Hardware (2026-10-24): zone Bedside Lights rid b90ea7b4…, grouped_light 75952a96…, lights Left e0e51794… and Right 686ec9ba…, inside room Master Bedroom (grouped_light 7104cbc3…); two time-based and several ordinary scenes on the zone; the Bedside Lights Switch's buttons are bound to Shine. | verified (`docs/status.md`, research §7) |

## 2. Design choice: a kind in `hue_light`, not a new driver

**Recommendation: the existing `hue_light.c4z` with `kind = "group"`**, the
device persisting `hue_kind` beside `hue_rid` and sending it in its hello,
exactly as `hue_scene` does for time-based scenes (smart-scenes Decision 1).

- `driver.xml` of the light already declares everything a group needs:
  `dimmer`, `supports_target`, the Button Links 200–202, `has_leds`, click and
  hold rates, `supports_brightness_stop`, `reduced_als_support`; colour and
  CT are switched on per device at run time. **No capability change, so no
  controller reboot**; the install is Lua plus bridge properties.
- The proxy, keypad, LED, fallback, binding re-check and lifecycle code (about
  1100 lines, verified on the house) is reused whole; a second driver would
  copy it and double every future "light parity" change (`docs/keypad-design.md`).
- No fourth `.c4z`: no new build target, dev-loop tree, icon set or install step.
- Costs: Composer shows the device's driver as "Hue Light"/"Hue Light (CLIP
  v2)" with the light icon; `Status`, `Model` and `Hue Light ID` must say what
  it is (§5). The bridge can no longer tell lights from group devices by
  `driverFileName`, so hellos carry `kind` and Link Devices gets skip sets (§4).
- A new driver would win a clean label and the `driverFileName` separation
  (the reason the scenes split was clean) and, being new, would also install
  without a reboot. The manual's own chapter 2 says there is no room-light
  device today, so either way the manual changes. The SDK forbids changing a
  driver's proxies with an update (`~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`);
  a kind changes none.

## 3. Decisions

1. **Scope: Hue zones and Hue rooms**, created only by the owner, one at a
   time, through `Add Light` (§4). Not `bridge_home` (no name; the house has a
   Whole House zone). Never created by an import, resync or event.
2. **Device = light_v2 dimmer** with the Hue Light driver's behaviour, kind
   "group". Registry key = the zone/room rid; the grouped_light rid is
   resolved live from the groups cache (as `scenes:grouped_light_of`), so an
   emptied-and-refilled zone needs no re-link.
3. **On state and level** = the grouped_light's `on.on` and
   `dimming.brightness` rounded to 1–100 (0 while off), through `HUE_STATE`
   exactly as a light; the tile is on while any member is lit.
4. **ON, tile tap, keypad top tap, target 100, programming ON** → `HUE_SET
   on=true brightness=100` → PUT `{"on":{"on":true},"dimming":{"brightness":100}}`
   on the grouped_light: parity with the Hue Light device (ON is 100 %; the
   proxy's On preset is hidden and 100). Hue's "restore each lamp's last
   state" stays with the Hue app (open question 1).
5. **Slider and targets are absolute** (`dimming.brightness` on the group),
   not relative as the scene devices move: a light device's level is a
   promise (40 % means every lamp at 40 %) and the tile's average then
   equals what was set; a relative move keeps per-lamp differences but the
   average never lands on the slider's value and saturates at the ends.
   Scene devices keep their relative moves (a scene's look is the differences).
6. **Keypad holds** stay Hue's relative dim (`HUE_DIM` → `dimming_delta` with
   `dynamics`, `stop` on release), unchanged from the light driver and
   verified on a grouped_light; a hold keeps per-lamp differences, as it does
   on a light. Taps, toggle, the 1 % start from off, the 1 s click guard,
   `MATCH_LED_STATE`/`BUTTON_INFO` and button colours: identical, on = Decision 3.
7. **Colour and CT** go to the grouped_light (`color.xy` or
   `color_temperature.mirek`, one of the two, with `dynamics` when a rate is
   given; a colour sent while the group is off is stored for the next turn-on
   as the light driver already does). **Capabilities = the union** of the
   members: `has_color` if any member has `color`, `has_cct` if any has
   `color_temperature`; the mirek range is the intersection of the
   CT-capable members' ranges (max of minimums, min of maximums; the first
   member's range if the intersection is empty). `min_dim` is 1 (Hue clamps
   per lamp). A membership change re-sends `HUE_CONFIGURE` and the device
   re-sends `DYNAMIC_CAPABILITIES_CHANGED`. **The bridge clamps too**
   (2026-10-25, #58): `zone_lights:limits(grouped_light_rid)` returns
   `{ min_dim = 1, mirek_min = n, mirek_max = m }`, the zone's intersected
   range (`nil` while the zone's members are unknown), and the driver gives
   it to the group queue (`state.group_queue:limits(grouped_light_rid, …)`)
   before each `group_set`. So a value from programming outside the range is
   clamped on the bridge side as well, not only by the device's Kelvin range
   on the Navigators; before, grouped_light PUTs were clamped to
   `commands.DEFAULT_LIMITS` (mirek 153–500), because the first `limits`
   was never wired and was removed as unused on 2026-10-24.
8. **Colour shown**: Hue reports none for a group, so the bridge derives it
   from the member lights it already caches (`lights.models`): if any lit
   colour-capable member is in `xy` mode, the first such member's `x`,`y`
   (zone children order); else the first lit member with a valid `mirek`;
   nothing while no member is lit. Sent in `HUE_STATE` when it changes
   (member `light` events, grouped_light on/off, resync, hello). The tile
   therefore follows Hue-app changes; a mixed group shows one lamp's colour
   (manual).
9. **Group queue pacing**: `commands.new` gains `rate_per_sec` and `burst`
   options; the grouped_light queue runs at 1/s sustained with burst 3, the
   light queue stays at 10/10. A slider drag settles to one PUT a second
   (the proxy's `LIGHT_BRIGHTNESS_CHANGING` animates meanwhile), a hold's
   start and stop and a tap after a hold go out at once. Closes the open item
   in `docs/status.md`. Verified 2026-10-25 (`docs/design.md`, "Hardware pass
   of 2026-10-25 night"): 50 slider targets in 5 s on the zone made 9
   grouped_light PUTs (a burst of 3, then one a second, the latest value
   winning), and no 429.
10. **Scenes of the same group** need no new message: both device kinds read
    the same grouped_light events on the bridge. What the owner sees: group
    slider or hold while a scene plays → both tiles show the same level, the
    scene stays on (Hue keeps it active; the scene device's on rule anyway);
    group OFF → Hue deactivates the scene, the scene device hears
    `HUE_SCENE_GROUP on=false` and goes off, the group tile goes off; group
    ON afterwards → group tile on at 100 %, scene tile stays off; a scene
    recalled anywhere → group tile on at the scene's average brightness and
    the first lit lamp's colour.
11. **No lights in the group** (empty zone, sensor-only room): the device is
    told `no_lights=true`: `ONLINE_CHANGED false`, tile off, commands dropped
    with the reason in Status; refilled → online again, nothing to click.
12. **Lifecycle** follows the lights' states and texts (`gone`, `unbound`,
    tombstone, forgotten, re-link, Link Devices, auto-adopt on hello), §4.

## 4. Lifecycle

Rule (CLAUDE.md): automation that makes a later manual fix harder is wrong;
the project is the owner's; nothing is lost by waiting (import-design §1).

### Hue side

| Event | Automatic | Offered (a click) | Forbidden without a click |
| --- | --- | --- | --- |
| Zone or room created | Groups cache updated (existing); listed in `Add Light` as "<Name> (zone, n lights)" | `Add Light` | Creating a device |
| Zone/room renamed | Registry `name`, `Hue Name` and `Status` refreshed; counted in Attention "names differ" with the lights' | `Adopt Hue Name` (device), `Adopt Hue Names`, `Accept Names As They Are` | `RenameDevice` |
| Zone/room deleted | Entry `gone` (date stamped); device Status "Zone deleted in Hue since <date>; re-link or Forget", `ONLINE_CHANGED false`, tile off; Attention "1 zone light missing from the bridge: …" | `Re-link Device To Light` (to another zone/room), `Forget Light` | Deleting the device; dropping the entry |
| Lights added to / removed from the group | Capabilities, colour and light count recomputed → `HUE_CONFIGURE` (+ `DYNAMIC_CAPABILITIES_CHANGED`), `HUE_STATE`; Status "(3 lights)" | — | — |
| Group emptied (grouped_light disappears) and refilled later | Decision 11 both ways; grouped_light rid re-resolved from the cache | — | Marking the entry gone (the zone still exists) |
| Member light replaced, deleted or renamed in Hue | Nothing beyond the recompute above; the light's own device (if any) follows the lights' lifecycle | — | — |
| Group turned on/off/dimmed/recoloured in the Hue app or by a Hue switch | `HUE_STATE` from the grouped_light event and the member events; LEDs follow | — | — |
| A scene of the group played | Decision 10 | — | — |
| Bridge restored from a backup onto the same bridge | Resync: rids kept → nothing; rids changed → entries `gone`, groups listed as new | `Link Devices` (exact name), `Re-link` | Re-linking by name on its own |
| Bridge replaced / re-paired | As lights: `Pair Bridge` refuses a different bridge id until `Forget Pairing`; afterwards every entry `gone`, every group new. Current (2026-10-25, build 316): `Pair Bridge` compares no ids: it pairs with the bridge at the address and stores its id; until then the identity check sends nothing to a bridge whose id differs from the paired one (`bridge/pairing.lua:pair`, `hue_bridge/driver.lua:verify_identity`) | `Link Devices`, `Re-link`, `Forget` | Silent matching |

### Control4 side

| Event | Automatic | Offered | Forbidden without a click |
| --- | --- | --- | --- |
| Device added | — | `Add Light` with the **Light** picker extended: after the unimported lights, "<Zone> (zone, n lights)" then "<Room> (room, n lights)", tombstoned ones last "… (deleted from Composer <date>)", empty ones "(no lights)" (refused with "Not added: Attic (zone) has no lights"); **Room** picker as today: "(mapped room)" = the group's own mapping, refused when none ("Not added: Bedside Lights (zone): Hue room Bedside Lights (zone) not mapped; pick a room, or Set Room Mapping first"). No "Add All Zones" (open question 3) | `Import All New Lights` creating group devices (lights only, unchanged) |
| Renamed in Composer | Nothing; `Hue Name` keeps the Hue name; Attention counts the difference once | `Adopt Hue Name` | Writing names to Hue |
| Moved to another Control4 room | Nothing; `Room Audit` lists it when its group has a mapping and the rooms differ | `Room Audit` | Moving it back |
| Deleted in Composer | `HUE_GOODBYE` → tombstone under `hue_zone_light_tombstones`; `Add Light` lists it as deleted; startup reconcile tombstones an entry whose device `GetDevices` no longer returns (never on an empty or failed lookup, as `registry:reconcile`) | `Add Light` re-creates and clears the tombstone | Re-creating on its own |
| Restored from a Composer backup (device exists with `hue_rid`+`hue_kind`, bridge has no record) | Hello with `kind=group` from a bound device → adopted into the zone-light registry (the device is the evidence; import-design §4); not on the bridge → `gone` | Not bound: bind in Connections, then `Link Devices` | Adopting a device that two devices claim (Attention names both) |
| Driver updated | Lua only; `hue_kind` persisted; no reboot; a device created under this build keeps the light icon | — | — |
| Two devices for one group | Prevented: `Add Light` answers "Not added: Bedside Lights (zone) is already imported (device N)"; a second claimant via hello is a conflict in Attention | `Forget Light` on one | Adopting the second |
| The same group also has Hue Scene devices | Allowed and expected (Decision 10) | — | — |
| Bridge driver deleted and re-added | Devices read "Not bound to a Hue Bridge", keep `hue_rid`/`hue_kind`; after pairing, a bound device's hello adopts it | Bind in Connections (owner's drag), `Link Devices` | — |
| Control4 room of the mapping deleted | `Add Light` refuses as lights do ("mapped to a Control4 room that no longer exists") | `Set Room Mapping` | A silent fallback room |

### Rooms as group lights (recommendation: yes, in v1)

Same code path, one more `group_type`. A room device is the one-request way
to switch a whole Hue room (the manual's "Whole-room commands" chapter
explains today's 0.1 s per light) and the natural keypad target. Picker
label "Master Bedroom (room, 9 lights)"; device name "<Room> Lights"
("Master Bedroom Lights", so the Lighting page of the Master Bedroom does
not list a light called "Master Bedroom"); zones keep their name verbatim
("Bedside Lights"). Default Control4 room = the room's mapping (rooms are
usually mapped by `Map Rooms By Name`).

## 5. Messages, naming, properties, manual, specs, hardware plan

### Messages (all values strings; additions to `docs/lights-design.md` and `docs/import-design.md` §4)

| Message | Direction | Change for a group device |
| --- | --- | --- |
| `HUE_HELLO` | device → bridge | + `kind` = "group" (from persisted `hue_kind`); `model` absent. The bridge routes `kind=group` to the zone-light module, everything else to `lights:hello` as today |
| `HUE_CONFIGURE` | bridge → device | + `kind` "group", `group_type` ("zone"/"room"), `light_count`, `no_lights` ("true" only while the group has no grouped_light), `model` ("Hue zone"/"Hue room"), `hue_room` (the group's own label: "Bedside Lights (zone)" / "Master Bedroom"), `id_v1` ("/groups/2"), `has_color`, `has_cct`, `mirek_min`, `mirek_max`, `min_dim` "1", `state` "gone" + `gone_since` while gone. Sent at creation, hello, startup (from the registry, before any GET), and whenever name, caps, count, no_lights or state change |
| `HUE_STATE` | bridge → device | `rid` (group rid), `on`, `brightness` (group average), `x`+`y` or `mirek` with `color_mode` (Decision 8), `online` ("false" while no grouped_light or gone), `reason` (event/resync/hello) |
| `HUE_SET` | device → bridge | unchanged; the bridge checks `zone_lights:is_group(rid)` first (the `device_for` accessors were removed 2026-10-24) and queues on the group queue (absolute body, Decision 5) |
| `HUE_DIM` | device → bridge | unchanged; group queue (`dim`, `rate`, `level`), Decision 6 |
| `HUE_GOODBYE`, `HUE_FORGET` | device → bridge | unchanged; routed by `device_id` (zone-light registry first, then lights) |
| `HUE_FORGOTTEN` | bridge → device | unchanged; `name` = the group's name |

### Naming

Device name at creation: zone → `metadata.name` verbatim; room → "<Room>
Lights". `expected_name` for Attention and `Adopt Hue Name(s)` apply the same
rule, so a room device named "Master Bedroom Lights" is not reported as
differing. Names are set once; afterwards the Composer name is the owner's.
Current (2026-10-25, build 316): AddDevice gets the `util.display_name` of
that name, or "Hue zone light" when nothing of it can be shown;
`HUE_CONFIGURE` `name` and `hue_room` and `HUE_FORGOTTEN` `name` are
display names too, and the names are compared as display names, Link
Devices' match trimmed and case-insensitive (`util.name_key`)
(`bridge/owner.lua:new_device_name`, `name_differences`, `forget`;
`bridge/zone_lights.lua:configure_params`; #217).

### Composer properties

Device (existing property names, kind-aware texts, each under 60 characters):
`Status` "Hue zone Bedside Lights (2 lights)" / "Hue room Master Bedroom (9
lights)"; no lights: "Hue zone Bedside Lights has no lights; nothing to
control"; gone: "Zone deleted in Hue since 2026-10-24; re-link or Forget"
(room: "Room deleted…"); forgotten: "Forgotten by the bridge (was Hue zone
Bedside Lights)" with the full instruction ("Delete this device in Composer,
or bind it again and use Link Devices") in `Last Action`; unbound and
waiting texts unchanged. `Hue Light ID` "zone #2 (b90ea7b4…)" (from
`id_v1`), `Hue Name` the group's name, `Model` "Hue zone (2 lights)", `Hue
Room` the group label, `Online` Online/Offline. Actions `Adopt Hue Name` and
`Forget This Light` work unchanged (the texts say "zone"/"room").

Bridge: new read-only `Zone Lights` "7 zones, 16 rooms on bridge; 1
imported" with ", n missing" / ", n unbound" / ", n deleted" appended only
when not zero (the `scenes:summary` pattern; under 60 characters). `Lights`
unchanged (lights only). `Attention` gains the zone-light items ("1 zone
light missing from the bridge: Bedside Lights (device 1180, since …)
(Re-link Device To Light or Forget Light)", unbound, name differences joined
with the lights'). `Last Action` texts: "Added Bedside Lights (zone) to
Master Bedroom (device 1180)", "Forgot Bedside Lights (zone, device 1180):
unbound and left in the project for you to delete", "Re-linked device 1180
(was Bedside Lights) to zone Reading Nook". Current (2026-10-25, build 316):
with the separate actions of §8 the missing item ends "(Re-link Zone Light
or Forget Light)" (`zone_lights.WORDS`, `relink_or_forget`).

Pickers: `HueLightList` = lights' list + zone-light list (coordinator joins;
the "(every light on the bridge is imported)" placeholder appears only when
both are empty); `RelinkDeviceList` and `ForgetDeviceList` list group
entries after the lights' as "Bedside Lights (zone light, device 1180, gone
since …)"; re-linking across kinds (a light device to a zone or a zone light
to a light) is refused: "Not re-linked: device 1180 is a zone light; pick a
zone or room".

### The manual (`src/hue_bridge/www/documentation.html`, `src/hue_light/www/documentation.html`)

Bridge: chapter 1 "The three device types" (a Hue Light can also stand for a
zone or room); chapter 2 the mapping table gains a "A Hue zone or room"
row and "What has no counterpart" drops "Hue rooms and zones as controllable
devices"; chapter 7 "Add Light" gains "Adding a zone or room as a light"
(picker labels, the room default, names, "no lights", the colour shown,
union of capabilities, 1 request a second); chapter 8 a short 8.10 "A zone
or room renamed, emptied or deleted in Hue"; chapter 9.4 one paragraph on
group light and scene tiles together (Decision 10); chapter 11 "Whole-room
and whole-house commands" names the room light as the one-request way;
chapter 13 limits and quick reference updated (`Zone Lights` property).
Light device page: "In Control4" and "Status texts" gain the zone/room
variants. `docs/status.md` after the install.

### Specs (busted, `tests/helpers/fake_c4.lua`)

- `tests/spec/zone_lights_spec.lua` (new module): add (AddDevice args
  `hue_light.c4z`, room, name; Bind; entry; CONFIGURE params; refusals: no
  mapping, already imported, no lights, unknown rid); GET `/grouped_light` →
  STATE; events on/level; colour derivation from `lights.models` (xy first,
  then ct, none when nothing lit); membership change → CONFIGURE with new
  caps; emptied → `no_lights`, refilled; zone delete → gone, re-add → back;
  goodbye → tombstone; hello adopt with kind, conflicts; Link Devices with
  skip sets both ways; forget; relink; name differences and Adopt; picker
  texts; summary under 60 characters.
- `tests/spec/light_driver_spec.lua`: `HUE_CONFIGURE kind=group` → labels,
  Status variants, hello carries `kind`, `no_lights` → ONLINE false and
  commands dropped with the reason; everything else unchanged by regression.
- `tests/spec/zone_light_roundtrip_spec.lua`: Add Light (zone) → hello →
  CONFIGURE/STATE → ON → PUT body on `/grouped_light/<rid>` `{on, dimming
  100}` → event → tile; colour target → `color.xy`; hold → `dimming_delta`
  + `dynamics`, release → `stop`; OFF → `on=false` and a scene device of the
  same zone (scenes module in the harness) hears `HUE_SCENE_GROUP on=false`;
  deleted in Hue → gone; deleted in Composer → tombstone cleared by Add.
- `tests/spec/commands_spec.lua`: `rate_per_sec`/`burst` options (1/s with
  burst 3 lets a start and a stop through at once, spaces a drag).
- `tests/spec/drivers_spec.lua`: routing of `HUE_HELLO kind=group`,
  `HUE_SET`/`HUE_DIM` for a group rid, `HueLightList` joined, `Zone Lights`.
- `tests/fixtures/hue_resources.lua`: `F.grouped_light` GET body (one item
  per group with on/dimming/alert/signaling, the empty zone absent),
  `F.events.zone_on`, `zone_off`, `zone_level`, `zone_children` (update with
  the whole `children` array), `zone_emptied` (children `[]`, grouped_light
  delete), plus a member light colour event.

### Hardware test plan (Bedside Lights; Windows session clicks and reads, owner on the iPhone)

Build from the feature branch, install all three through "Add or Update
Driver or Agent…"; expected: **no** "Restart Director?" (a prompt means a
capability slipped into `driver.xml`); read `Driver Version` on the bridge
and both scene devices.

1. `Add Light`: Light "Bedside Lights (zone, 2 lights)", Room "(mapped
   room)" → expect the refusal text (the zone is unmapped), then Room
   "Master Bedroom" → "Added Bedside Lights (zone) to Master Bedroom (device
   N)". Read the device's `Status`, `Hue Light ID`, `Model`, `Hue Name`,
   `Hue Room`, `Online`; the bridge's `Zone Lights` and `Attention`.
2. Owner, Control4 app after Refresh Navigators: the tile shows a slider and
   colour controls; ON → both lamps 100 % (Hue app); slider 40 → both 40;
   colour and CT picks reach both lamps; OFF → both off. Recall Shine from
   its tile, then group OFF → Shine's tile off; group ON → Shine stays off.
3. Hue app: zone slider → group tile follows within 2 s; one lamp off → tile
   on at the other's level; both off → off; a zone scene → tile on, colour
   of a lamp; a Hue dimmer switch if one is bound to the zone.
4. Keypad: owner rebinds the Bedside Lights Switch's top and bottom to the
   new device's Top/Bottom Button Links in Connections; tap top → 100 %, tap
   bottom → off, hold top/bottom → ramp with per-lamp differences kept,
   release stops; LEDs follow; then back to Shine if he prefers.
5. Lifecycle, dev build for the duration (`Hue Request`, research §4 route),
   on a throwaway zone holding the Left Bedside Light (zones are not
   exclusive, nothing else changes): Add → rename it → Attention and `Adopt
   Hue Name`; remove its light → "no lights", Offline, a command dropped;
   add it back → Online; add a CT-only lamp → capabilities recomputed (read
   the DYNAMIC_CAPABILITIES_CHANGED line); delete the zone → gone text →
   `Re-link Device To Light` to a second throwaway zone → `Forget Light` →
   delete the device in Composer → `Add Light` shows "(deleted from Composer
   …)" → add again. Delete the throwaway zones. H1/H2 while there:
   `PUT /grouped_light/<rid>` with `color.xy`, with `color_temperature.mirek`,
   and `on=true` after setting the two lamps to different levels (record
   the HTTP answers and the lamps' states).
6. Pacing: a fast slider drag on the dev build; the log shows at most one
   grouped_light PUT a second and no 429.
7. Room light: `Add Light` "Master Bedroom (room, n lights)" → "Master
   Bedroom Lights"; ON/OFF; keep it or `Forget Light` + delete.

## 6. Files and ownership (one writer per file)

- **Bridge module** `src/hue_bridge/bridge/zone_lights.lua` (new) +
  `tests/spec/zone_lights_spec.lua`: `zone_lights.new({ http, send,
  bridge_id, log, now, project, lights, group_set, group_dim, persist_get,
  persist_set })`; `registry.new` with `keys = { lights = "hue_zone_lights",
  tombstones = "hue_zone_light_tombstones", rooms = false }`; entry fields
  `device_id, proxy_id, name, group_type, light_count, caps, id_v1, state,
  gone_since, unbound_since, created_room_id, created_at, name_dismissed`;
  methods as `scenes`: `load/save`, `configure_all`, `resync(done)` (its own
  GET `/clip/v2/resource/grouped_light`), `on_container` (grouped_light,
  room/zone/bridge_home, and `light` items of members, run **after**
  `lights:on_container`), `hello/goodbye/forget_request/on_binding_changed`,
  `set(params)`/`dim(params)` (HUE_SET/HUE_DIM → `ctx.group_set`/`ctx.group_dim`),
  `add(rid, room_id, done)`, `relink`, `forget`, `link_devices(skip)`,
  `adopt_hue_names`, `accept_names`, `summary`, `attention_items`,
  `picker_groups`, `picker_relink_devices`, `picker_forget_devices`,
  `entry(rid)` (its `.device_id`; `device_for` was removed 2026-10-24), `device_ids()`, `is_group(rid)`.
  Current (2026-10-25, build 316): the entry also keeps `no_lights`; these
  fields (`zone_lights.ENTRY_FIELDS` with `registry.OWN_FIELDS`) are the
  schema the registry is given, so any other persisted field is dropped at
  load (#56); the lifecycle methods are `bridge/owner.lua`'s, shared with
  the lights and the scenes.
- **Model and fixtures** `src/hue_bridge/bridge/hue_model.lua` +
  `tests/spec/hue_model_spec.lua`, `tests/fixtures/hue_resources.lua`:
  `hue_model.grouped_light(item)` → `{ rid, owner_rid, owner_type, on,
  brightness }` and `update_grouped_light`; `hue_model.group_caps(lights)`
  (Decision 7) and `hue_model.group_color(lights)` (Decision 8) over a list
  of `hue_model.light` tables; `hue_model.group_configure_params(...)`.
- **Light device** `src/hue_light/driver.lua`, `src/hue_light/light/state.lua`
  + `tests/spec/light_driver_spec.lua`, `light_state_spec.lua`: `hue_kind`
  persisted and sent, kind-aware labels and Status, `no_lights` in
  `blocker()`/`is_online()`; nothing else moves.
- **Commands** `src/hue_bridge/bridge/commands.lua` + `commands_spec.lua`:
  `rate_per_sec`, `burst` options.
- **Lights module** `src/hue_bridge/bridge/lights.lua` + `lights_spec.lua`:
  `link_devices(skip_ids)`, `picker_lights` unchanged (the join is the
  coordinator's), Room Audit accepting a second source of entries.
- **Coordinator**: `src/hue_bridge/driver.lua` (routing by kind, rid and
  device id; `new_group_queue` options; `HueLightList` and the other picker
  joins; `Add_Light` branch; `Zone Lights`; resync and container order
  lights → scenes → zone_lights), `src/hue_bridge/driver.xml` (property),
  both manuals, `docs/status.md`, `.luacheckrc` if a new global appears,
  integration, build, install brief, hardware plan.

## 7. Open questions (recommended answer first)

1. **ON = 100 % or Hue's "last state"?** 100 % (Decision 4), parity with the
   Hue Light; the Hue app keeps its own semantics.
2. **Absolute slider vs relative moves?** Absolute (Decision 5).
3. **"Add All Zones"?** No: 23 devices in one click is the flood the scenes
   contract avoided; one click per zone is deliberate.
4. **Rooms in v1?** Yes, named "<Room> Lights"; zones verbatim.
5. **Capabilities union or intersection?** Union of flags, intersection of
   CT ranges (Decision 7); a white-only lamp in a colour group ignores colour
   (manual). Intersection would hide colour from the capable lamps.
6. **Colour shown for the group?** First lit member in xy, else ct
   (Decision 8), never "last commanded" (it would lie after a Hue-app change).
7. **Reuse `Add Light` / `Re-link Device To Light` / `Forget Light` or add
   `Add Zone Light` and friends?** Reuse: the owner asked for "a light", the
   Actions tab already holds 20 actions, and the rid tells the bridge which
   module owns the pick. Separate actions are the fallback if the joined
   pickers read badly in Composer.
8. **Group queue at 1/s?** Yes, burst 3 (Decision 9); watch for 429 on the
   dev build and relax to 2/s if drags feel slow.
9. **bridge_home ("all lights") device?** Not in v1; a Whole House zone exists.
10. **Re-link across kinds?** Refused in v1; the registries differ. Revisit if
    a replaced bulb ever needs to become a zone.
11. **Mixed install order** (an old bridge sees `HUE_HELLO kind=group` and
    would adopt the device as a gone light): accept; the deploy installs all
    three files in one dialog and a `Forget Light` repairs it.
12. **Hardware facts to settle before the colour code is final**: H1 (colour
    PUT on a grouped_light) and H2 (what `on=true` restores). If H1 fails for
    `color.xy`, fall back to one PUT per capable member light through the
    light queue (paced at 10/s) and say so in the manual.

## 8. Coordinator decisions (2026-10-24)

The open questions of §7, decided; where a decision changes an earlier
section, this section wins.

1. **ON = 100 %** (Q1), **absolute slider and targets** (Q2), **no "Add All
   Zones"** (Q3), **rooms in v1 named "<Room> Lights"** (Q4), **union of
   flags, intersection of CT ranges** (Q5), **colour of the first lit member**
   (Q6), **group queue 1/s with burst 3** (Q8), **no bridge_home device** (Q9),
   **cross-kind re-link refused** (Q10), **mixed install order accepted**
   (Q11): as recommended.
2. **A separate bridge action `Add Zone Light`** (Q7, changed). Parameters:
   `Group`, a picker from `zone_lights:picker_groups()` (zones first, then
   rooms, "<Name> (zone, 2 lights)" / "<Name> (room, 9 lights)", tombstoned
   ones "… (deleted from Composer <date>)", empty ones "… (no lights)"; one
   entry "(no zones or rooms on the bridge)" with value "" when there is
   nothing), and `Room`, exactly as `Add Light`'s ("(mapped room)" first).
   `Add Light` and `HueLightList` stay lights-only. `Re-link Device To Light`
   and `Forget Light` keep their names and their pickers gain the group
   devices after the lights' entries (the coordinator joins the lists). Reason:
   the owner's own words are "add the zone as a light"; a joined picker of
   70 entries would be hard to read; the lights' picker code stays untouched.
   Current (2026-10-25, build 316): an empty group reads "Attic (zone, no
   lights)", and when every group is imported the one entry reads "(every
   zone and room on the bridge is imported)"
   (`bridge/zone_lights.lua:picker_groups`).
3. **No dev-build round before coding** (Q12, changed). The published CLIP v2
   reference lists `color` and `color_temperature` in the grouped_light PUT
   body (assumed until seen on the house), so the colour path is built as
   Decision 7 says and verified with the production build in step 2 of the
   hardware plan: a colour and a CT pick from the tile reaching both lamps. If
   the bridge refuses, the fallback (one PUT per capable member through the
   light queue) is a follow-up. H2 does not affect the driver (ON always
   sends brightness 100).
4. **Split** as §6, with `hue_model.lua`, `hue_model_spec.lua` and the
   fixtures folded into the bridge-module agent so that no agent waits on
   another; `tests/spec/zone_light_roundtrip_spec.lua` and the `drivers_spec`
   additions are the coordinator's at integration, as are the manuals' final
   wording for the action names.
5. **Branch** `feature/zone-lights`, created from the property-fix branch
   (PR #29, awaiting its Composer check) so that nothing waits; it merges
   after #29. A build of it changes no `<capabilities>`, so the install needs
   no controller reboot.
6. **`Re-link Zone Light`** (coordinator, while wiring): with `Add Light` and
   its `Light` picker lights-only, a zone-light device whose zone was deleted
   could not be re-linked through `Re-link Device To Light`; so a second
   bridge action, `Re-link Zone Light` (`Device` = the zone-light devices,
   `Group` = `picker_groups()`), does it, and `Re-link Device To Light` stays
   lights-only. `Forget Light`'s `Device` picker lists the zone-light devices
   after the lights'. The cross-kind refusal of Q10 is therefore structural.
   Current (2026-10-25, build 316): `Re-link Zone Light`'s `Device` list
   holds the gone and unbound zone-light devices only, else "(no zone light
   device is gone or unbound)" (`hue_bridge/driver.lua:RelinkZoneLightList`,
   `bridge/owner.lua:picker_relink_devices`).
