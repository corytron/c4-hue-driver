# Edge cases and lifecycle policy: Hue motion sensors and MotionAware areas

> **Research (2026-10-26) for issue #268**, written before the contract (`docs/motion-design.md`) against `main` at release 1.0 (build 359); "today" and `[code: …]` mean that code. Read-only. It enumerates the lifecycle corner cases on both sides and recommends, per case, what is automatic, what is only offered and what is forbidden without a click. The owner's answers go into §9; until then the recommended defaults stand. It builds on the two research notes written at the same time: `docs/motion-control4-research.md` (C4R below; its recommended device is assumed throughout, §0.3) and `docs/motion-hue-research.md` (HR below).

What the bridge driver and the motion devices do on their own, what they
only offer, and what they never do without a click, for every event in the
life of a Hue motion sensor or a MotionAware motion area that Control4
represents. It extends `docs/edge-cases-ux.md` and the decisions of
`docs/import-design.md` (lights), `docs/zone-light-design.md` (zone
lights) and `docs/scenes-design.md` (scenes) to a fourth kind of device.
Where a case is the same as for lights it reuses their answer: the shared
lifecycle base `src/hue_bridge/bridge/owner.lua` already holds hello and
auto-adopt, goodbye and tombstones, binding changes, the project
reconcile, room resolution, device creation, the names trio, Attention,
the pickers, Re-link, Forget and Link Devices [code: `owner.lua`].

Two things make motion different from lights, and most new rows follow
from them:

1. **A motion state is an event, not a level.** A light's level that was
   missed is corrected by the next change. A missed "no motion" is not: in
   an empty room the next change may be hours away, and Control4
   programming ("when … stops sensing motion") waits on a state that is no
   longer true. Stale, unknown and out-of-order states matter far more here
   than for lights.
2. **Nobody here can watch the hardware.** The house has a Hue Bridge Pro
   and no sensors; the tester who owns sensors is remote and reports
   through the owner (issue #268). Every case therefore leaves a log line
   and a device `Status`, an `Attention` item when the owner must act, and
   the issue's Diagnostics action (HR §6) records the resources with ids,
   names and times replaced, so that a tester's round can be read here.

Status markers as in the other research documents: [verified: …] = the
DriverWorks reference (`API x/_y` =
`~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`,
`FUND x/_y` = the fundamentals), a source that C4R or HR shows
([verified: C4R §n], [verified: HR §n]), a Signify page, or the house;
[code: file] = what the drivers do today; [community: …] = a library, an
integration, a post or a blog, not shown by code or a dump; [assumed] = not
confirmed anywhere, to test.

## Rules behind every row

The three rules of `docs/import-design.md` §1 hold unchanged:

1. **The project is the owner's.** Devices are created, renamed, bound,
   unbound or re-pointed only from an action he clicked; `C4:AddDevice` is
   for user-initiated use [verified: API 9/_0.1], and no API removes or
   moves a device [verified: sweep in `docs/edge-cases-ux.md`]. For motion
   this also covers the settings of the motion sensor proxy (Invert Sensor,
   Debounce) and the owner's connections of the temperature output: the
   driver never changes them.
2. **Nothing is lost by waiting.** Every change is cached, counted in a
   bridge property and logged, so the owner can act on it later.
3. **The Control4 device is the identity; the Hue resource is
   re-pointable.** The motion device is the sensor Control4 knows: the
   stock motion programming, the Locks & Sensors entry and its history hang
   on its proxy [verified: C4R §2.1; history assumed there]. A replaced
   sensor or a re-created area is therefore a Re-link, never a delete and
   re-add, which would lose all of that.

Four more for motion:

4. **Report what is known; invent nothing.** `OPENED` (motion) and
   `CLOSED` (no motion) go to the proxy only from a valid reading or a
   deliberate end; no missed episode is replayed afterwards, and no state
   is guessed. When knowledge is lost the device follows §6: a deliberate
   end (sensor deleted or switched off in Hue, area paused, device
   forgotten or unbound) sends `CLOSED` once; a failure (stream down,
   sensor unreachable, battery flat, area not running) leaves the contact
   as it is and says so (Q1).
5. **The bridge's clock orders readings.** Each motion reading carries the
   time it last changed (`motion_report.changed`) [verified: HR §1.3]; the
   newest reading wins, a resync GET never replaces a newer event, and
   bridge times are compared only with each other, never with the
   controller's clock.
6. **Read freely, never write.** The driver may read what it needs to
   verify a state (bounded: §5 R3) but changes nothing on the Hue side: no
   sensor or area switched on or off, no sensitivity, no name, no Hue
   automation touched (Q5; HR §4.2 proposes the same).
7. **One device per sensor or area, keyed by what identifies it.** A
   sensor's entry is keyed by the Hue **device** rid: one physical sensor
   owns the motion, light level, temperature, battery and Zigbee services,
   resolved live from the device record. An area's entry is keyed by its
   **`motion_area_configuration`** rid: the area's name, room and health
   live there, and the two motion services under it are resolved live, as
   a zone light resolves its `grouped_light` [code: `bridge/zone_lights.lua`],
   because which of them carries the motion can change (A9).

## 0. Facts the policy rests on

### 0.1 Hue (HR has the evidence and the sources)

| Fact | Status |
| --- | --- |
| A Hue motion sensor is a `device` with model id SML001 or SML003 (indoor) or SML002 or SML004 (outdoor) and five or six services: `motion`, `light_level`, `temperature`, `device_power`, `zigbee_connectivity` and, on current firmware, `device_software_update`. The order of `services` varies. Any device owning a `motion` service is treated as a motion sensor, whatever its model id. | [verified: HR §1.1, §1.2]; the last sentence [assumed: HR's design proposal] |
| Only the device has a name (`metadata.name`, "Hue motion sensor 1" or "Hue outdoor motion sensor 1" until renamed). The device's `id_v1` is `/sensors/N`, shared by its `motion` and `device_power`; `light_level` and `temperature` were N+1 and N+2 on the bridges seen. | [verified: HR §1.1, §1.2]; that the numbering always holds [assumed] |
| `motion`: `enabled` (false while the sensor is switched off in the Hue app: it then reports nothing and keeps its last value), `motion.motion_report` (`changed`, `motion`), the deprecated `motion.motion` and `motion_valid` (false when the value is not to be trusted), still sent in July 2026, and `sensitivity`. On some firmware the `motion` object is missing altogether. | [verified: HR §1.3] |
| `light_level` (10000·log10(lux)+1, 0 = too dark to measure) and `temperature` (°C, two decimals) each have their own `enabled` and `changed`; `device_power.power_state` has `battery_level` 0–100 and `battery_state` `normal`, `low` or `critical` (where `low` begins is not documented). | [verified: HR §1.4–§1.6] |
| `zigbee_connectivity.status` is `connected`, `disconnected`, `connectivity_issue` or `unidirectional_incoming`, with the radio's `mac_address`; Home Assistant treats a sensor as unavailable unless `connected`. When the bridge stops calling a sleeping battery sensor connected, and whether it resets the sensor's motion then, is not known. | [verified: HR §1.7]; sensors' timing [assumed] |
| Motion start and motion end are separate updates; "no motion" follows the last movement after some seconds (10 s or more on other hubs); nothing is expected while motion continues; light level and temperature arrive about every 5 minutes, so a house with sensors keeps the stream busy. | [verified: HR §3.2 for start and end]; the rest [community or assumed: HR §3.2] |
| Since Hue app 5.54.0 the app shows sensors and MotionAware areas inside rooms and lets the owner move them; whether a sensor's device then sits in `room.children` is not shown. | [verified: HR §1.1 for the app]; the API [assumed] |
| Rooms, zones, the home and the Hue app's sensor groups (`service_group`) carry `grouped_motion` and `grouped_light_level` services, on both bridge generations. | [verified: HR §1.8]; both generations [assumed] |
| MotionAware is Hue Bridge Pro only (since 2025-09-04): at most 4 areas a bridge, 3 or 4 compatible lights an area, set up in the Hue app for a room, a zone or the whole home, with a calibration of about 20 s while the area is empty. An area can be paused. When one is "unrecoverable", Signify's advice is to check its lights are powered and save the area again. Signify's developer terms gained conditions on MotionAware that nobody here has read. | [verified: HR §2.1, Philips support article "MotionAware"]; the terms [needs the owner to paste: HR §7.3] |
| Since Hue app 5.71 an area's lights may come from anywhere on the bridge, and one room or zone may hold several areas; a limited MotionAware for the square bridge is rumoured. | [community: hueblog, 2026-07-14 and 2026-05-25] |
| An area is a `motion_area_configuration` with `name` (probably "Motion area" by default), `group` (a room, a zone or `bridge_home`), `participants` (`motion_area_candidate` references, each with its own health, `unhealthy` included), `services`, `health` (`healthy`, `degraded`, `recovering`, `unrecoverable`, `not_running`, `unknown`) and `enabled`; no `id_v1` and no owner. One Bridge Pro answered only `id`, `owner`, `enabled` and `type` for it before a firmware update. | [verified: HR §2.3]; the default name [assumed]; the partial shape [community: HR §2.3] |
| It owns a `convenience_area_motion` and a `security_area_motion`, each shaped like a sensor's `motion` (owner = the configuration, no `id_v1`). Which one reports depends on whether the area is bound to lights in the Hue app; the other keeps a frozen value, and `motion_valid` is false on the one not live and may stay true on a frozen one. Pausing an area clears the configuration's `enabled` and leaves the services' `enabled` alone; firmware 1.73–1.76 sometimes left `motion` out of the security service. | [verified: HR §2.4, §2.5]; the frozen `motion_valid` and the firmware gap [community: HR §2.4, §2.5] |
| An area senses motion only: no light level, temperature or battery. | [verified: HR §2.3, §2.4 (no such fields)] |
| The square bridge serves none of the area types; `GET /clip/v2/resource/clip` lists the types a bridge serves. What the area endpoints answer there is not shown (404 expected); a Bridge Pro with no area answers empty lists. | [verified: HR §2.7, §6.1]; the 404 [assumed]; empty lists [community: HR §2.7] |
| Event stream, as for lights: `add`, `update` and `delete` containers; at most one container a second, a value that changed twice within it reports its last value; one resource may appear twice in a container with parts of a change, so items apply in order; a motion update carries the whole `motion` block; `delete` items carry only `id` and `type`; no keepalive; a reconnect misses what happened meanwhile, and replay is unconfirmed. | [verified: HR §3.1, `docs/design.md` "Event stream"]; delete items and replay [assumed, community] |
| A replacement sensor is a new device with new rids; a reset sensor paired again also gets new rids and keeps its radio's MAC; no replace or transfer feature for sensors is known. | [assumed: HR §3.5, as for bulbs in `docs/edge-cases-hue.md` §1] |
| The API accepts `enabled` on sensor services, group services and areas, `sensitivity` on motion and area services, and an area's `name`; writing an area service's `enabled` changes nothing, and an area's light automation refuses `enabled` (HTTP 400). | [verified: HR §4.1]; the last two [community: HR §4.1] |

### 0.2 Control4 (C4R has the evidence and the sources)

| Fact | Status |
| --- | --- |
| A Control4 motion sensor is a contact device: Open (motion) or Closed (no motion). A DriverWorks driver can be that sensor by naming `contactsingle_motionsensor` as its only proxy, as Snap One's Lutron and KNX child drivers do; Director then makes the proxy binding itself, hidden in Composer. | [verified: C4R §1.1–§1.3, FUND 11/_1] |
| The driver sends the proxy `OPENED` (motion: fires "senses motion") and `CLOSED` (no motion: fires "stops sensing motion"). `STATE_OPENED` and `STATE_CLOSED` report a first known state and answer the proxy's `GET_STATE`; Snap One's sensor template uses them so that no event fires, sends `OPENED` / `CLOSED` only on a change, and leaves `GET_STATE` unanswered while the state is unknown. | [verified: C4R §1.5]; that `STATE_*` fires no event and sets Verified [assumed: C4R probe T6] |
| The proxy brings the stock events, the conditionals "is sensing motion" and "State is Verified", the variables `ContactState`, `StateVerified` and `LastActionTime`, and its own settings Invert Sensor and Debounce. Verified reads No until the first state reaches the proxy. | [verified: C4R §1.3, §2.1]; whether Verified returns to No at a Director restart [assumed] |
| The proxy has no notification for "unknown", "offline" or battery: those are the driver's own variables, events and properties (Online, Enabled, Battery, Light Level, Temperature). | [verified: C4R §3.3] |
| Temperature leaves on a provider connection of class `TEMPERATURE_VALUE`: `VALUE_CHANGED`, a first `VALUE_INITIALIZED`, `VALUE_UNAVAILABLE` with status offline, and the consumer's `GET_SENSOR_VALUE`; a Control4 thermostat drops a reading older than 900 s. | [verified: C4R §3.1]; the thermostat [community: C4R §3.1] |
| A driver's proxy can never change for its file name, and a released event, variable or command must never be removed, renamed or renumbered, since programming refers to them; adding is safe. | [verified: FUND 14/_2] |
| `OnBindingChanged(idBinding, class, bound, otherDeviceID, otherBindingID)` reaches a driver for control bindings; at a Director start it does not arrive for bindings that already exist, so a driver reads them at late init. | [verified: API 9/_12]; the start [assumed, `docs/edge-cases-control4.md` 4.1] |
| `GetBoundConsumerDevices` answers nil, not an empty table, when nothing is bound; one nil means "unknown" until a second one 5 s later confirms it. | [verified: house 2026-10-25; code: `bridge/project.lua`] |
| History registration and `RecordHistory` with a device id are 3.4.0+; our drivers declare 3.3.0 as the minimum. | [verified: API 7/_5.2, C4R §6] |
| Composer has no copy and paste and no Replace Driver for devices. | [community: docs.control4.com, `docs/edge-cases-control4.md` 1.6] |
| A device's persisted values follow its device id: an update in place keeps them, a delete and re-add loses them. | [verified: house] |
| The motion driver declares no `<capabilities>`, so installing or updating it needs no controller reboot. | [verified: C4R §6]; no reboot [assumed: C4R probe H1] |

### 0.3 The device model this document assumes

C4R §7: one **motion device** per Hue sensor or area, a new
`hue_motion.c4z` whose only proxy is `contactsingle_motionsensor`, bound
to the bridge's binding 1 (`HUE_BRIDGE`) as lights and scenes are, created
by a bridge action (here `Add Motion Sensor`) with `AddDevice` and `Bind`,
with the kinds `sensor` and `area` as the zone lights have `group` (or two
drivers: the owner's choice in C4R §9 Q5, which decides Q2 here). It shows
in its room as a stock motion sensor with the stock programming; light
level, battery, online and enabled are its own rows, variables, events and
conditionals; temperature also leaves on a `TEMPERATURE_VALUE` output the
owner may connect to a Temperature Display or a thermostat. An optional
Occupancy Hold Time (default 0) holds "motion" after Hue reports none
(C4R §4.2).

The bridge module (here `bridge/motion.lua`) is a fourth registry owner on
`owner.lua`, persisting under its own keys (here `hue_motion`,
`hue_motion_tombstones`). The lights' resync already fetches every device
on the bridge, sensors included, and keeps each one's name, Zigbee
service, MAC and room (`lights.devices`, `lights.macs`, `lights.groups`)
[code: `lights.lua` `absorb`, `hue_model.devices`]; the motion module reads
those as the zone lights read `lights.models`, and needs the device record
to keep the sensor's other service rids as well. Sensor items already pass
through the lights' event handler harmlessly [verified: HR §3.4].

Names in the texts below are examples, matching HR's fixtures: "Hallway
sensor" (a sensor in the Hue room Hallway, `/sensors/12`, device 1201),
"Porch sensor" (a sensor in no Hue room), "Kitchen motion area" (an area of
the Hue room Kitchen, device 1203), and "Hall", a Control4 room.

## 1. Hue motion sensors: the Hue side

Each row: what the bridge shows and the driver sees; what the driver does
on its own; what it offers as a click; what it never does without one;
the text the owner reads; the lights' precedent, or "new".

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | Sensor added in the Hue app | `add` items for the device and each service, perhaps over several containers and in any order; a room update when the app places it [assumed: HR §3.5]. A resync finds a device with a `motion` service and no entry. | Cache it, list it in `Add Motion Sensor`'s picker, count it as new, log it once. | `Add Motion Sensor` (one sensor into one room); a bulk add only under the lights' rules (§7). A sensor in no Hue room needs a room picked. | `AddDevice` from an event, a resync or a start. | Attention "1 new motion sensor on the bridge: Hallway sensor [Hallway] #12 (Add Motion Sensor)"; picker "Hallway sensor [Hallway] #12" (the device's `/sensors/N`, else 8 hex of its rid), "Porch sensor #15". | Lights: a new light (import-design §1, §5; Q 9). |
| S2 | Renamed in the Hue app | A device `update` with `metadata.name` [assumed: HR §3.5]; the services carry no names. | Registry name, the device's `Hue Name` row and the pickers refreshed; Composer untouched; counted with the other name differences. | `Adopt Hue Name` (device: renames its proxy), `Adopt Hue Names`, `Accept Names As They Are`. | `RenameDevice` on its own; renaming the sensor in Hue. | Attention "1 Hue name differs from the Composer names: Hall Motion is Hallway sensor in Hue (Adopt Hue Names or Accept Names As They Are)". | Lights (naming policy, Q 10). |
| S3 | Moved to another Hue room | Since app 5.54.0 the owner moves sensors between rooms in the app; whether the rooms' `children` change is not shown [assumed: HR §1.1]. | `Hue Room` row refreshed when the rooms say so; feeds Room Audit. | `Room Audit`. | Moving the device. | Room Audit "Hallway sensor is in Hall; Hue says Landing → drag it to Landing in Composer if you want it there". | Lights (a light moved between Hue rooms). |
| S4 | Replaced: a new sensor in the same place with the same name | A new device with new rids and a new MAC (S1). The old one is deleted in the app (S5) or, more likely for sensors, left on the bridge unreachable with a flat battery (S8, S9) [assumed]. | The new sensor is listed as new with a re-link hint when a gone entry, or an entry unreachable for more than an hour, has the same MAC (S6), else the same name in the same Hue room; hinted pairs first. | `Re-link Motion Sensor`: Device = gone, unbound and unreachable-for-an-hour entries; Sensor = unimported sensors, hinted first. | Re-linking on a name match on its own; advising a delete and re-add (rule 3). | Attention "1 new motion sensor on the bridge: Hallway sensor [Hallway] #31 (looks like Hallway sensor, device 1201; re-link?) (Add Motion Sensor)". | Lights (a bulb replaced; `lights:relink_hint`). New: an entry that stopped answering is a re-link source too, since a dead sensor usually stays in the Hue app; the name hint also needs the same room, because default sensor names repeat (S11). |
| S5 | Removed (deleted) in the Hue app | `delete` items for the device and its services, ids only [assumed: HR §3.1]. A resync: the device rid absent from a successful `/device` GET. | Entry `gone` at once (as Q 11); deliberate end (§6): `CLOSED` once if motion showed, Online false, the temperature output unavailable; the rows keep their last values, marked old. | `Re-link Motion Sensor`, `Forget Motion Sensor`. | Deleting the device; dropping the entry. | Status "Sensor deleted in Hue since 10-26; re-link or Forget"; Attention "1 motion sensor missing from the bridge: Hallway sensor (device 1201, since 10-26) (Re-link Motion Sensor or Forget Motion Sensor)". | Lights (gone). New: the `CLOSED`. |
| S6 | Reset at the sensor, then paired again | The sensor leaves the Zigbee network; the bridge keeps its record, unreachable, until it is deleted in the app [assumed]. Paired again: a new device with new rids and the same MAC [assumed: HR §3.5]. | S9 while it is unreachable; the new record listed as new with a MAC hint. | `Re-link Motion Sensor`. | Re-linking on the MAC match on its own. | Attention as S4, "(same radio as Hallway sensor, device 1201; re-link?)". | Lights (a bulb deleted and re-added; MAC hint). |
| S7 | Switched off in the Hue app (`enabled` false) | `motion.enabled` false in an update [assumed: HR §3.5]; the sensor then reports nothing and keeps its last value [verified: HR §1.3]; light level and temperature have their own `enabled`. Hue's own automations for it stop [assumed]. | Deliberate end: `CLOSED` once if motion showed; Enabled false (with its event, if the contract has one); the light level and temperature rows read "off in Hue" while theirs are off, and the temperature output is unavailable; switched on again → Enabled true and the next valid reading is reported. | Nothing in v1: switching it on is a write to Hue (Q5). | Switching it on from Control4; reporting motion from the stale value. | Status "Switched off in the Hue app; no motion is reported"; Attention "1 motion sensor switched off in the Hue app: Hallway sensor" (Q4). | New. |
| S8 | Battery low, critical or flat | `battery_state` `low` or `critical`, `battery_level` (3 % read `low` in a dump) [verified: HR §1.6]. Flat: readings stop and at some point the Zigbee status leaves `connected` [assumed: when]. | Battery rows and variables; the battery events on each change of state (C4R §2.2); an Attention item from `low` on; flat → S9. | — | — | Battery "12 % (low)"; Attention "1 motion sensor battery low: Hallway sensor 12 %" (or "critical"). | New (lights have no battery). |
| S9 | Unreachable | Zigbee status not `connected`; the readings keep their last values [assumed: the bridge does not reset motion]. | Failure: the contact stays as it is (Q1); Online false and the offline event; the temperature output unavailable; light level marked old; Attention after an hour (Q3); reachable again → Online true, and the current reading is reported as a change if it differs. | After an hour the entry is also offered by `Re-link Motion Sensor` (S4). | Reporting a guessed state. | Status "Not reachable since 14:02; motion not current"; Attention "1 motion sensor not reachable for more than 1 h: Hallway sensor (still showing motion)". | Lights (offline: ONLINE false, the last level kept; Attention after 24 h, Q 8). New: the shorter delay, the motion caveat. |
| S10 | Firmware updated | `device_software_update` and the device's software version change; the sensor may drop out and rejoin; the deprecated fields may one day stop [verified: HR §1.3 that both are still sent]. | Refresh; read the `*_report` fields first and the deprecated ones only when they are missing; a dropout is S9; S14 when the services change. | — | Starting an update from Control4. | `Model` row (with the firmware version, if the contract shows it). | Lights (firmware update). |
| S11 | Several sensors with the same name | Default names repeat ("Hue motion sensor 1" in every house) [verified: HR §1.1]; nothing makes names unique. | Picker texts carry the Hue room and `#N`; hints need name and room (S4); Link Devices matches a name only when exactly one unimported sensor has it. | `Link Devices`; a rename in Hue or Composer. | Matching an ambiguous name. | Link Devices "not linked 1: Hall Motion (device 1201): 2 unimported motion sensors have that name; rename the device in Composer to one sensor's exact name and run Link Devices again". | Lights (naming policy; Link Devices). |
| S12 | Sensitivity changed, or a Hue automation on the sensor | A `sensitivity` update [assumed: HR §3.1]; the Hue app's own automation for the sensor. | Nothing: motion is reported as the bridge reports it. | — | Changing Hue's sensitivity or automations. | The manual: a Hue automation and Control4 programming on one sensor both act (R9). | New. |
| S13 | A sensor without some service (a non-Hue sensor, or an unusual model) | A `motion` service, perhaps no light level, temperature, battery level or Zigbee service [assumed]. | Listed when it has a `motion` service; the missing rows read "not available" and their variables are never set; without a Zigbee service, Online is unknown, never false. | — | — | Rows "not available". | Lights (no `zigbee_connectivity`: online unknown, edge-cases-hue §1). |
| S14 | A service replaced under a known sensor (for example after a firmware update), or its motion service gone while the device stays | The device's `services` list changes; `add` or `delete` items for a service only [assumed]. | The services are resolved live from the device record, so a new service rid needs no re-link (rule 7). A device left with no `motion` service is a failure (no motion reading, Q1), never `gone`: an entry is gone only when its device is. | — | Marking the entry gone while its device exists. | Status "No motion reading from Hue yet"; Attention after an hour. | New: the reason the key is the device rid. |

## 2. MotionAware areas: the Hue side

An area has no battery, light level or temperature (its temperature output
stays silent); what stands for "unreachable" is its lights (A5) and its
health (A7), and for "firmware updated" the bridge's (B4, A16) and its
lights' (A4, A5).

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | Area created (in the Hue app only) | `add` items for the configuration and its two services, and a `behavior_instance` when it controls lights [assumed: HR §3.1]; a health other than `healthy` while it calibrates [assumed]. | Listed in `Add Motion Sensor`'s picker after the sensors, counted, logged once. | `Add Motion Sensor`. | `AddDevice` from an event, a resync or a start; creating areas from Control4 (they need a calibration with the room empty). | Attention "1 new MotionAware area on the bridge: Kitchen motion area (Add Motion Sensor)"; picker "Kitchen motion area (MotionAware) [Kitchen] #ac00". | Lights (new light); zone lights (a group listed). |
| A2 | Renamed | The configuration's `name` [verified: HR §2.3]; the services carry none. | As S2. | As S2. | As S2; renaming the area in Hue (the API would take it). | As S2. | Zone lights (zone renamed). |
| A3 | Deleted | `delete` items for the configuration and its services [assumed: HR §3.5]. A resync: absent from a successful configuration GET. | Entry `gone` at once; deliberate end: `CLOSED` once, Online false. | `Re-link Motion Sensor` (to another area, or to a sensor: Q2), `Forget Motion Sensor`. | As S5. | Status "Area deleted in Hue since 10-26; re-link or Forget"; Attention "1 MotionAware area missing from the bridge: Kitchen motion area (device 1203, since 10-26) (Re-link Motion Sensor or Forget Motion Sensor)". | Zone lights (zone deleted). New: the `CLOSED`. |
| A4 | Its lights changed (added, removed, or since 5.71 taken from another room) | A `participants` update; the health may change while it recalibrates [assumed: HR §3.5]. Participants are candidates, each owned by a light's device [verified: HR §2.2]. | Status shows the light count; while not healthy see A5–A7; the key does not change, so nothing needs a re-link. | — | — | Status "MotionAware area Kitchen motion area (4 lights)". | Zone lights (membership change). |
| A5 | One of its lights unreachable or switched off at the wall | That participant `unhealthy`, the area `degraded` [verified: HR §2.3 for the values; the sequence assumed: HR §3.5]; Signify asks for every light to stay powered. | Motion still reported while the area gives a valid reading [assumed: a degraded area still senses]; Status names the light (candidate → its device's name); Attention after an hour (Q3). | — | — | Status "Area degraded: Desk Lamp not responding"; Attention "1 MotionAware area degraded: Kitchen motion area (power its lights)". | New. |
| A6 | Paused (MotionAware switched off for the area) | The configuration's `enabled` false; the services' `enabled` unchanged and their motion frozen [verified: HR §2.5]. | Deliberate end: `CLOSED` once; Enabled false (with its event, C4R §2.2); resumed → Enabled true and the next valid reading. | Nothing in v1 (Q5). | Resuming it from Control4; reading motion from the services while the configuration is off; writing a service's `enabled` (it changes nothing anyway). | Status "Paused in the Hue app; no motion is reported"; Attention "1 MotionAware area paused in the Hue app: Kitchen motion area" (Q4). | New (as S7). |
| A7 | Not running (`health` `not_running` or `unrecoverable`) | The configuration's `health` [verified: HR §2.3]. | Failure: the contact stays as it is (Q1); Online false; Attention at once, since only the owner can fix it, in the Hue app. | — | — | Status "Area not running in Hue; save it again in the Hue app"; Attention "1 MotionAware area not running: Kitchen motion area (open it in the Hue app and save it again)". | New. |
| A8 | Its room or zone deleted | [assumed: the area is deleted with it (A3), or keeps a `group` the room cache no longer has]. | A3; or `Hue Room` reads "(deleted in Hue)" while the area keeps reporting. | As A3. | As A3. | As A3, or `Hue Room` "Kitchen (deleted in Hue)". | Zone lights (room mapping "(deleted in Hue)"). |
| A9 | Its use switched between lights and security in the Hue app | Which service is live depends on whether the area is bound to lights; the other keeps a frozen value, and `motion_valid` cannot tell them apart [verified and community: HR §2.4, §2.5]. | The area's motion is the reading of the enabled service whose `motion_report.changed` is newest, events included (HR §2.5's proposal; Home Assistant takes the convenience service first instead); `motion_valid` is not used on areas; no re-link (the key is the configuration). | — | Any security behaviour (alarms, alerts): `security_area_motion` is read only as a source of motion (issue #268), and only as far as Signify's MotionAware terms allow (HR §7.3). | — | New. |
| A10 | Sensitivity, time slots, daylight or inactivity time changed | Configuration and service updates. | Nothing [assumed: time slots and daylight limit Hue's reactions, not the motion reported]. To confirm in the tester's first round. | — | Changing them from Control4. | — | New. |
| A11 | Several areas with one name, or in one room (since 5.71) | The default name is probably "Motion area" [assumed: HR §2.3]; names repeat. | Picker "<name> (MotionAware) [<room, zone or (whole home)>] #<first 4 hex of the rid>"; Link Devices refuses an ambiguous name. | `Link Devices`; a rename. | Matching an ambiguous name. | As S11. | Lights (naming policy). |
| A12 | No motion reading (no enabled service carries `motion`) | Firmware 1.73–1.76 left `motion` out of the security service on some bridges [community: HR §2.4]. | Failure: nothing sent; the contact stays as it is (Q1). | — | Reading "no motion" into a missing object. | Status "No motion reading from Hue yet". | New. |
| A13 | Re-created: deleted and set up again under the same name (for example after it stopped working) | A3 for the old configuration, A1 for the new one, which has new rids [assumed]. | The new area is listed as new with a re-link hint when a gone area entry has the same name and the same room or zone. | `Re-link Motion Sensor` (hinted pair first). | Re-linking on the name match on its own. | Attention "1 new MotionAware area on the bridge: Kitchen motion area (looks like Kitchen motion area, device 1203; re-link?) (Add Motion Sensor)". | Lights (a bulb replaced); as S4. |
| A14 | Moved: its room or zone changed in the Hue app, if the app allows that [assumed] | The configuration's `group` changes; the rid stays. | `Hue Room` row refreshed; feeds Room Audit; no re-link. | `Room Audit`. | Moving the device. | As S3. | Lights (a light moved between Hue rooms). |
| A15 | An area for the whole home | `group` is `bridge_home` [verified: HR §2.3; it crashed Home Assistant until 2026-09]. | No Hue room to map: `Add Motion Sensor` needs a room picked; `Hue Room` reads "(whole home)"; Room Audit leaves it out. | `Add Motion Sensor` with a room. | Defaulting it into the bridge's room. | Refusal "Not added: Kitchen motion area: the whole home has no mapped room; pick a room". | Lights (no Hue room: Q 9). |
| A16 | The configuration served only in part (an older Bridge Pro firmware) | Only `id`, `owner`, `enabled` and `type`, no `name`, `group`, `participants` or `health` [community: HR §2.3]. | Tolerated: labels fall back to "MotionAware area #<4 hex>", the missing rows read "not available", the motion still comes from the services, and nothing is marked gone for a missing field. | — | Marking the entry gone, or refusing it, for a partial shape. | Status "Hue reports this area only in part; update the bridge". | New. |

## 3. The bridge (sensors and areas alike)

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | Bridge replaced through the Hue app's transfer | A new bridge id; whether rids survive is contradictory [community]. From a square bridge to a Bridge Pro, sensors and groups move along and areas exist only afterwards [assumed: HR §3.5]; between two Bridge Pros, areas need a new calibration [assumed]. | As lights: `Pair Bridge` refuses another bridge until `Forget Pairing` [code: `bridge/pairing.lua` `other_bridge`]; after re-pairing, entries whose rids remain stay linked, the others go `gone` (`CLOSED` once) and the new resources are listed with MAC and name hints. | `Re-link Motion Sensor`, `Link Devices` (by rid or exact unique name), `Forget Motion Sensor`. | Matching by name or MAC on its own. | The existing Status "Bridge at … reports ID …"; then Attention's missing and new items. | Lights (bridge replaced, #236). |
| B2 | Restored from a Hue backup | [assumed: a Hue app feature on the Bridge Pro; whether rids survive is not known]; areas probably not running until saved again (A7). | rids kept → nothing; rids changed → `gone` and new, as B1. | As B1. | As B1. | As B1, plus A7's item. | Zone lights ("Bridge restored from a backup"). |
| B3 | Bridge factory reset | Every keyed request refused (HTTP 403) and the stream stopped [verified: house 403; code: `key_rejected`]. After re-pairing every sensor must be paired again in the Hue app (new rids, same MAC) and every area set up again. | While the key is refused: the bridge is away (R1): contacts stay as they are and every device says its motion is not current; after re-pairing as B1. | `Pair Bridge`; then as B1, with MAC hints for sensors. | — | The bridge's Status "Key rejected by the bridge …"; then as B1. | Lights (key revoked, #44). |
| B4 | Bridge offline, rebooting or updating its firmware | The stream closes or falls silent; reconnect and resync [code: `stream.lua`]. | The bridge is away (R1); the resync reports the truth. A firmware update may add resource types (MotionAware on a bridge that had none) or complete a partial area (A16): the resync finds them. | — | Assuming "no motion" because the bridge is away. | Status "Bridge not answering since 14:02; motion not current". | Lights (bridge reboot). |
| B5 | A Hue Bridge v2 without MotionAware | `/resource/clip` lists no area type; the area endpoints probably answer 404 [verified and assumed: HR §2.7]. | Support is read from the served types (`/resource/clip`), else from the area GETs, never from the bridge's model (a limited MotionAware for the square bridge is rumoured). Without it the picker lists the sensors and one line "(this bridge offers no MotionAware areas)". An error is never read as "every area was deleted": an area goes `gone` only after a successful GET that lacks it. An area entry on a bridge that offers none says so. | `Re-link Motion Sensor`, `Forget Motion Sensor` for such an entry. | Marking areas gone on an error; refusing areas by model. | Status "This bridge offers no MotionAware areas; re-link or Forget"; Attention "1 MotionAware area device on a bridge without MotionAware: Kitchen motion area (Re-link Motion Sensor or Forget Motion Sensor)". | Lights (only a successful full GET marks gone: `lights:fetched`). New: the support check. |
| B6 | Paired again with the same bridge | A new key; rids unchanged. | Nothing; the resync reports every state (R4). | — | — | — | Lights. |
| B7 | Bridge address changed | Identity check and rediscovery as today [code: `verify_identity`]. | The bridge is away until the stream is back (R1). | — | — | As B4. | Lights. |

## 4. The Control4 side

The same for sensor and area devices unless a row says otherwise.

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | Device added | `Add Motion Sensor`: a picker of sensors then areas, and `Room`: the mapping of the sensor's Hue room or of the area's room or zone, else the room picked, else refused. `AddDevice`, `Bind` to the bridge, register; Director binds the proxy itself; then the configuration and, once known, the first state (R4). By hand: the owner adds the driver from Composer's search and connects it to the bridge; its hello carries no rid. | A device added by hand waits ("Bound; waiting for the bridge", Verified No). | `Add Motion Sensor`; `Link Devices` for a device added by hand (exact unique name). Connecting the temperature output to a Temperature Display or a thermostat is the owner's own drag. | `AddDevice` from an event, a resync or a start. | Last Action "Added Hallway sensor to Hall (device 1201)"; refusal "Not added: Hallway sensor: Hue room Hallway not mapped; pick a room, or Set Room Mapping first". | Lights (Add Light, Q 9); zone lights (Add Zone Light). |
| C2 | Renamed in Composer | Composer renames the proxy; `OnItemNameChanged` refreshes Attention within seconds [code]. | Nothing; `Hue Name` keeps the Hue side; counted in the name differences until accepted. | `Adopt Hue Name`, `Adopt Hue Names`, `Accept Names As They Are`. | Writing names to Hue. | As S2. | Lights. |
| C3 | Moved to another Control4 room | Nothing is called. | Nothing; Locks & Sensors lists it under its new room [assumed]. | `Room Audit` lists it when its Hue room's mapping differs (never a whole-home area). | Moving it back. | Room Audit line. | Lights. |
| C4 | Deleted in Composer | The device's `OnDriverRemovedFromProject`; its proxy goes with it, and with the proxy the stock programming on it [assumed: Composer drops it, as for any device]. | The device says goodbye; the bridge tombstones the entry. | `Add Motion Sensor` re-creates a device (new id, no programming) and clears the tombstone. | Re-creating it on its own. | Picker "Hallway sensor [Hallway] #12 (deleted from Composer 10-26)"; the manual: re-link, never delete to fix (rule 3). | Lights (tombstone, Q 4; the goodbye from `OnDriverRemovedFromProject` reaches the bridge [verified: house 2026-10-21]). |
| C5 | Copied | Composer copies no devices (§0.2); a second motion device appears only by an add or by hand, without a rid. | A hand-added device waits; two devices claiming one rid (a restore merging projects, a future Composer) → neither adopted. | `Link Devices`; `Forget Motion Sensor` on one of two claimants. | Adopting either claimant. | Attention "2 devices claim Hue motion sensor Hallway sensor: 1201 and 1207 (Forget Motion Sensor on one of them)". | Lights (conflicts). |
| C6 | Its connections changed | (a) The proxy binding is Director's, made at add time and hidden [verified: C4R §1.3]; the device can look it up as lights do (`GetBoundConsumerDevices(own id, 5001)` [verified: house, for lights]). (b) The temperature output connected to, disconnected from or moved between Temperature Displays or thermostats (`OnBindingChanged` [verified: API 9/_12]). (c) The bridge binding: C11. | (a) A device whose proxy is not bound reports nothing and says so [assumed: only when the proxy driver is missing]. (b) Connected → the value at once (`VALUE_INITIALIZED`, then `VALUE_CHANGED`), or `VALUE_UNAVAILABLE` while it is not known; `GET_SENSOR_VALUE` answered the same way; disconnected → nothing to send; on an area device the output stays silent. | — (the drags are the owner's) | Connecting or disconnecting anything. | Status "…; motion proxy not bound (see the Lua output)" for (a); nothing for (b). | New. |
| C7 | Programming that refers to it | The stock events, conditionals and variables of the proxy, and the device's own (Online, Enabled, Battery, Light Level, Temperature) [verified: C4R §2]. Once released, none of them is removed, renamed or renumbered [verified: FUND 14/_2]. | A gone, forgotten or unbound device keeps its own variables at their last values, its Status explains, and its Online is false; "State is Verified" lets programming ignore a sensor whose state is not yet confirmed after a start (R4). | `Re-link Motion Sensor` keeps everything. | Deleting to fix (C4). | The manual: re-link, never delete; check Verified or Online in programming that must not act on a stale state. | Lights (`docs/edge-cases-control4.md` 5.4). |
| C8 | Project restored from a backup | Devices return with their persisted rid and the state they last sent; the bridge registry may be newer or older; the proxies return with the state the backup holds, perhaps Open [assumed]. | A bound device's hello with a rid the registry lacks → adopted (the device is the evidence); the reconcile tombstones entries whose devices the restore removed; at the first reading each proxy gets the true state by R4 (a change → `OPENED` or `CLOSED`, so programming catches up). | `Link Devices` for devices without a rid. | — | Log "adopted Hallway sensor (device 1201) from its own persisted rid". | Lights (auto-adopt, reconcile, Q 3). New: the stale state. |
| C9 | Bridge driver updated | In place: registries, tombstones and pairing survive [verified: house]. The feature adds bridge properties, actions and a module and no `<capabilities>`; the motion driver is a fourth `.c4z` installed in the same dialog. | Nothing. An older bridge ignores the motion device's hello (an unknown command is logged at debug only [code: `common/dispatch.lua`]); the device waits. `Add Motion Sensor` before the motion driver is on the controller: `AddDevice` answers 0. | — | — | Device Status "Bound; waiting for the bridge"; Last Action "Not added: AddDevice failed for Hallway sensor (see the Lua output)". | Lights (`docs/edge-cases-control4.md` 1.10); zone lights (mixed install order, Q 11). |
| C10 | Bridge re-paired | `Pair Bridge`. | Same bridge → nothing; another bridge → refused until `Forget Pairing`, which keeps the registries [code: `Forget_Pairing`]; then B1. | As B1. | As B1. | As B1. | Lights. |
| C11 | Bridge driver deleted, or a motion device disconnected from the bridge | Each device's bridge binding goes [assumed: `OnBindingChanged` false]. | Deliberate end: `CLOSED` once if motion showed, Online false, the temperature output unavailable, Status "Not bound to a Hue Bridge"; the rid is kept, and once the bridge is added again, paired and the devices connected to it by the owner, each hello adopts its device. Only an actual unbind does this, or the start-up re-check giving up after 60 s: a device that finds itself unbound at the first look after a start changes nothing, since its binding can come late (C12). | Connections (the owner's), `Link Devices`. | — | Device Status "Not bound to a Hue Bridge". | Lights (`docs/edge-cases-control4.md` 1.7, 1.8). New: the `CLOSED`. |
| C12 | Director restarted | All `OnDriverInit`, then all late inits in any order; a binding may show up late [code: `common/device.lua` re-check]. | The registry loads; `configure_all` sends each bound device its configuration from the registry, with no state. Each device shows "Waiting for the bridge", sends nothing and leaves the proxy's `GET_STATE` unanswered until the first reading [verified: C4R §4.3, the template], then R4. The binding re-check at 5, 15, 30 and 60 s applies, and nothing is cleared while it runs (C11). | — | Sending a state before the first reading. | Status "Waiting for the bridge", then the normal text; Verified No until the first state [assumed: C4R probe T6]. | Lights (`configure_all`, early hellos). New: R4. |
| C13 | Controller rebooted | As C12, with the stream reconnecting. | As C12; bridge times are not compared with the controller's clock (rule 5). | — | — | As C12. | Lights. |
| C14 | Upgrade from OS 3.x to 4.x | No change to the contact proxy is recorded for 4.x [assumed: C4R §6]; nothing else the lifecycle uses changes [assumed, as `docs/edge-cases-control4.md` 3.8]. | History calls only where they exist (3.4.0+, guarded by a function check). | — | — | — | Lights. |
| C15 | Two motion devices for one sensor | `Add Motion Sensor` or a hello. | Prevented: the add refuses; a second claimant is a conflict (C5). | `Forget Motion Sensor` on one. | Adopting the second. | Last Action "Not added: Hallway sensor is already imported (device 1201)". | Lights. |
| C16 | The Temperature Display or thermostat on the temperature output deleted | The output's `OnBindingChanged` false. | Nothing to send any more (C6). | — | — | — | New. |
| C17 | Forget | `Forget Motion Sensor` (bridge) or `Forget This Sensor` (device). | The entry goes; deliberate end: `CLOSED` once if motion showed, Online false, the temperature output unavailable; the device is unbound from the bridge and told, and stays in the project for the owner to delete; the sensor or area is listed under Add again. A forgotten device that the owner connects to the bridge again stays forgotten until `Link Devices` links it. | — | — | Last Action "Forgot Hallway sensor (device 1201): unbound and left in the project for you to delete; the Hue motion sensor is listed under Add Motion Sensor again". | Scenes (#47 F8: a forgotten device is not re-adopted). Lights re-adopt a forgotten device when it is connected again; the scenes' rule is chosen here. |
| C18 | The proxy's own settings (Invert Sensor, Debounce) | The owner's, on the proxy's page [verified: C4R §1.3]; the driver cannot read them [assumed]. | Nothing: the driver always sends `OPENED` for motion; Invert flips what Control4 shows. | — | Changing them. | The manual: leave Invert Sensor unticked (C4R §4.1). | New. |
| C19 | The motion driver updated in place | `OnDriverDestroyed("DIT_UPDATING")`, then init and late init; persisted values survive [verified: house, for lights]. Its proxy can never change, and its events, variables and commands may only be added to [verified: FUND 14/_2]. | The device keeps its rid, kind and last state sent; its hello is answered with the configuration and, once known, the state (R4). | — | Removing, renaming or renumbering a released event, variable or command; touching the proxy. | Status "Waiting for the bridge" for a moment. | Lights (driver update in place, `docs/edge-cases-control4.md` 3.4). |
| C20 | Controller replaced (the project moved to a new controller) | As C8 on the new controller; the encrypted application key may not travel [assumed, `docs/edge-cases-control4.md` 3.7]. | As C8; with the key gone, B3's "key rejected" until `Pair Bridge`. | `Pair Bridge`, then as C8. | — | As C8 and B3. | Lights (`docs/edge-cases-control4.md` 3.7). |

## 5. Runtime

| # | Case | Observable | Automatic | Offered (a click) | Forbidden without a click | Owner sees | Precedent |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | The stream lost and resynced while motion is active (stuck "motion") | The stream closes (an error, the transfer timeout of 3600 s) or falls silent (no keepalive; the watchdog reconnects after 600 s, which a house with sensors seldom reaches since they report every few minutes) [verified: `docs/design.md`; HR §3.2]; events in between are lost. | A reconnect within a minute changes nothing visible. After a minute without a stream every device says its motion is not current; the contacts stay as they are, and Online is left alone (it is about the sensor, not the bridge). The resync reads every sensor and area, and a state that changed meanwhile goes out as `OPENED` or `CLOSED`, so programming catches up late rather than never (C4R §4.3). The motion GETs run right after the lights' GETs (which fill the device, MAC and room caches) and before the scenes' 351 KB catalogue. | — | Assuming "no motion" because the stream dropped. | Status "Bridge not answering since 14:02; motion not current"; log "motion: Hallway sensor: no motion since 14:03:10 (missed while the stream was down)". | Lights (a resync after every connect). New: the order, the grace, Online left alone. |
| R2 | A whole motion episode missed (it began and ended while the stream was down) | After the resync the state is unchanged but `motion_report.changed` is newer than the last reading. | Log only: no late pulse (rule 4, Q6). | — | Replaying the episode. | Log "motion: Hallway sensor: a motion at 14:02:31 (bridge time) was missed while the stream was down". | New. |
| R3 | "Motion" stuck while the stream looks alive (a half-open connection and no keepalive) | Nothing arrives; while motion continues nothing is expected either [assumed: HR §3.2]. | While a device has shown motion for 5 minutes without an event about it, one GET of its motion resource (for an area, its configuration and two services), repeated every 5 minutes while it stays on; the answer is applied by rule 5 (Q7). | — | Polling while nothing shows motion; any write. | Log at debug. | New: the only polling. |
| R4 | The first reading after a start, an Add, a Re-link or a re-bind | The resync, an answer to a hello, `OnBindingChanged`. | When the reading equals the state the proxy last got (the device persists it), `STATE_OPENED` or `STATE_CLOSED`: no event, Verified set [assumed: C4R probe T6]. When it differs (the state changed while nobody was watching), `OPENED` or `CLOSED`, so the stock events fire once. A device that never sent a state starts with `STATE_*`. A `GET_STATE` after that is answered with `STATE_*` of the current state. | — | Firing events for a state that did not change. | Motion rows; Verified Yes. | Lights (a full `HUE_STATE` at every resync). New: events only on a real change. |
| R5 | Motion already active at the start | The first reading says motion, with an old `changed`. | By R4: if the proxy last got "no motion", `OPENED` (someone is there now, and "senses motion" fires); if it last got motion, `STATE_OPENED`. Logged with the bridge's time; R3 applies if it stays on. | — | Suppressing or delaying a true state. | `Hue Motion` "Motion since 03:12 (bridge time, at start)". | New. |
| R6 | Events out of order | An abandoned transfer's last chunk; a resync GET answered with an older state than an event already applied; one resource twice in a container with parts of a change [verified: HR §3.1]. | Items apply in order, each motion item with its whole block [verified: HR §3.1]; per entry the newest `changed` wins; without `changed` (old firmware), an event that arrived after the GET was sent beats the GET's value. The stream already drops an abandoned chunk while the live transfer is connected and skips repeated SSE ids [code: `stream.lua`]. | — | Letting an older reading overwrite a newer one. | — | Lights: the GET wins, which is harmless for levels. New for motion. |
| R7 | Motion and no motion within one second | The bridge reports a value's last state per container [verified: `docs/design.md`]: a short blip may arrive as "no motion" only. | Nothing to do; the manual mentions it. | — | — | — | New. |
| R8 | Unknown becomes known again (switched on, reachable, resumed, healthy) | The next valid reading. | Online and Enabled return; the reading goes out as `OPENED` or `CLOSED` when it differs from what the proxy shows; Status returns to normal; the Attention item clears by itself. | — | — | — | Lights (back online). |
| R9 | Hue and Control4 both act on one sensor or area | Hue's own automation (an area's is a `behavior_instance` [verified: HR §2.2]) and Control4 programming on the device. | Nothing. | — | Disabling either; the API refuses it for an area anyway [community: HR §4.1]. | The manual says both run. | New. |
| R10 | Controller and bridge clocks differ | Bridge `changed` times beside the controller's clock. | Ordering uses bridge times only; the rows show the controller's time of receipt, the log the bridge's time. | — | Comparing the two clocks. | — | New. |
| R11 | Occupancy Hold Time (if the contract has it, default 0) across a start, a re-link or a lost state | The hold is the driver's own timer after Hue's "no motion" (C4R §4.2). | Hue's motion restarts the hold; `CLOSED` goes out when it ends. A hold cut by a restart starts again in full at the first "no motion" reading (never shortened by comparing clocks). A failure leaves the held state as it is (Q1); a deliberate end sends `CLOSED` at once, with no hold. A changed setting applies from the next "no motion". `Hue Motion` always shows Hue's own state. | — | Holding after a deliberate end. | `Hue Motion` "No motion since 14:05"; the contact still Open until the hold ends. | New. |
| R12 | `Test: Motion` and `Test: No Motion` actions (if the contract has them, C4R §2.2) | A click. | The test state goes to the proxy as a change, then Hue's state is put back by the next reading or after 30 s, whichever comes first, as a change too, so both stock events can be seen; logged. | The actions. | A test state left standing. | Last Action "Test: motion sent; Hue's state returns within 30 s". | New. |

## 6. What the device shows when its state is not known

"Deliberate" ends are someone's choice and never report again by
themselves, so a motion left showing would never clear; they send `CLOSED`
once. "Failures" may clear themselves, and Hue's own automations also do
nothing while a sensor is away [assumed]; the contact stays as it is, and
Status says the motion is not current (Q1). The proxy has no "unknown"
(§0.2): Online and Enabled are the device's own answer, and Verified covers
the start only.

| Reason | Kind | Motion proxy | Online, Enabled | Temperature output | Device Status | Bridge Attention |
| --- | --- | --- | --- | --- | --- | --- |
| No reading yet since the start | waiting | nothing; `GET_STATE` unanswered; then R4 | unchanged until the first reading | nothing until the first reading | "Waiting for the bridge" | — |
| Bridge away for less than a minute | transient | nothing | unchanged | unchanged | unchanged | — |
| Bridge away longer (offline, key rejected, stream down) | failure, bridge-wide | as it is (Q1) | unchanged | no new value; a periodic re-send, if the contract has one, stops, so a thermostat drops the value after 900 s | "Bridge not answering since 14:02; motion not current" | the bridge's own rows |
| Sensor unreachable, battery flat | failure | as it is (Q1) | Online false, offline event | `VALUE_UNAVAILABLE` | "Not reachable since 14:02; motion not current" | after 1 h (Q3) |
| No motion reading: on a sensor `motion` missing, or `motion_valid` false while enabled; on an area no enabled service with a reading | failure | as it is (Q1) | unchanged | unchanged | "No motion reading from Hue yet" | after 1 h |
| Area not running or unrecoverable | failure | as it is (Q1) | Online false | — | "Area not running in Hue; save it again in the Hue app" | at once |
| Area degraded | still valid | the state | unchanged | — | "Area degraded: Desk Lamp not responding" | after 1 h |
| Switched off in Hue, area paused | deliberate | `CLOSED` once | Enabled false | `VALUE_UNAVAILABLE` (sensor) | "Switched off in the Hue app; no motion is reported" / "Paused in the Hue app; no motion is reported" | yes (Q4) |
| Deleted in Hue (gone) | deliberate | `CLOSED` once | Online false | `VALUE_UNAVAILABLE` | "Sensor deleted in Hue since 10-26; re-link or Forget" | yes |
| Forgotten | deliberate | `CLOSED` once | Online false | `VALUE_UNAVAILABLE` | "Forgotten by the bridge (was Hue motion sensor Hallway sensor)"; the instruction in Last Action | — |
| Unbound from the bridge, bridge driver deleted (an actual unbind, or the start-up re-check giving up) | deliberate | `CLOSED` once | Online false | `VALUE_UNAVAILABLE` | "Not bound to a Hue Bridge" | the unbound item |
| Deleted in Composer | — | goes with the device | — | — | — | listed as deleted under Add |

Q1's alternative: the failure rows also send `CLOSED`, two minutes after
the state stopped being known. Light level and battery follow the same
reasons without an output: their rows and variables keep the last value,
marked "(old, 14:02)" or "off in Hue", and a variable is never set to an
invented value.

## 7. Not offered in v1, so that nothing automates them

- Room, zone and home motion (`grouped_motion`, `grouped_light_level`) and
  Hue sensor groups (`service_group`): not listed in beta 1 unless the
  contract takes HR §1.8's option. If it does, such a device is keyed by its
  group (room, zone, home or sensor group) and follows the area rows.
- Hue Secure cameras (`camera_motion`), contact and tamper sensors,
  buttons: not listed (issue #268); the diagnostics only count them.
- Security-area alarm behaviour: none; `security_area_motion` is read only
  as a source of motion (A9).
- Writes to Hue: switching a sensor or an area on or off, sensitivity,
  names, identify and test mode, creating or deleting areas, automations
  (Q5; HR §4.2; C4R §9 Q9).
- A separate stock Motion Sensor device per sensor, with or without the
  bridge adding it (C4R §1.4 B and B'): rejected there, so none of its
  cases (two names, two rooms, a connection to keep) arise.
- A bulk add is the contract's choice. If it comes, it follows Import All
  New Lights: mapped rooms only, tombstoned ones skipped and listed,
  idempotent by rid, never from an event.

## 8. What differs from the lights

1. **Keys**: the Hue device rid for a sensor, not a service rid; the
   `motion_area_configuration` rid for an area, its motion services
   resolved live (rule 7, S14, A9).
2. **Lost knowledge sends `CLOSED` or keeps the contact** by its cause (§6,
   Q1); lights only send ONLINE false and keep their level.
3. **Events only on a real change** (R4): the first state after a start is
   `STATE_*` unless it changed while nobody watched; lights send a full
   state at every resync.
4. **Ordering by the bridge's `changed` time**: a resync GET never
   overwrites a newer event (R6); for lights the GET simply wins.
5. **No replay** of an episode missed while the stream was down (R2).
6. **One bounded check** while motion has shown for 5 minutes without
   news (R3); lights have no polling at all.
7. **The motion GETs run right after the lights' GETs**, before the
   scenes' catalogue (R1); a bridge-wide outage does not set the devices
   offline.
8. **Re-link also offers a linked entry unreachable for an hour** (S4,
   S9), and the name hint needs the same Hue room; lights offer only gone
   and unbound entries.
9. **Re-link across kinds** (a sensor's device to an area and back) is
   recommended if one driver serves both kinds (Q2); zone lights refuse
   re-links across kinds.
10. **A forgotten device stays forgotten** when connected again, until
    `Link Devices` (the scenes' rule, C17); lights re-adopt it.
11. **Attention items** for battery (at once), unreachable sensors and
    degraded areas (after an hour, Q3), switched-off sensors and paused
    areas (Q4), areas not running (at once), and area devices on a bridge
    without MotionAware; lights nag about offline lamps after 24 h only.
12. **MotionAware support is read from the types the bridge serves**,
    never from its model, and a failed or unsupported area GET never marks
    areas gone (B5); a partial area shape is tolerated (A16).
13. **The driver file is a one-way door**: its proxy can never change, and
    its released events, variables and commands can only be added to
    (C19); lights could still change their proxy's capabilities.
14. **Nothing is written to Hue** (rule 6, Q5): lights send commands (on,
    level, colour) and never Hue settings; motion devices send nothing at
    all.

## 9. Questions for the owner (recommended default first)

1. **When a sensor or area stops reporting by failure** (unreachable,
   battery flat, bridge away, area not running): **keep the contact as it
   is, set Online false and say the motion is not current** (Hue's own
   automations do the same; a room is never darkened on stale data), or
   send `CLOSED` after two minutes so that nothing stays triggered? This is
   C4R §9 Q7. Deliberate ends send `CLOSED` either way.
2. **Re-link across kinds** (a sensor's device to a MotionAware area, for
   a hallway whose battery sensor gives way to an area, and back): **allow
   it when one driver serves both kinds** (the stock programming is the
   same; the sensor-only rows read "not available" on an area), or refuse
   it as zone lights do? With two drivers (C4R §9 Q5) it is impossible
   anyway.
3. **Attention delay for an unreachable sensor or a degraded area**: **1
   hour**, or 24 hours as for lamps? (Sensors are never powered off at the
   wall, so a long silence is never normal.)
4. **A sensor switched off or an area paused in the Hue app in
   Attention**: **yes** (a family member's switch in the Hue app silently
   stops Control4 programming), or only in the device's Status?
5. **Writes to Hue**: **none in beta 1** (no enable, disable or
   sensitivity from Control4), or offer them as clicks? This is C4R §9 Q9
   and HR §4.2.
6. **A motion episode missed while the stream was down**: **log only**, or
   a late `OPENED` then `CLOSED`?
7. **The stuck-motion check**: **one GET after 5 minutes of motion without
   news, then every 5 minutes while it lasts**, or rely on the stream's
   watchdog (up to 10 minutes of stuck motion)?

## 10. Checks

The Control4 probes H1–H5 and tester rounds T1–T8 of C4R §8, and the
diagnostics and questions of HR §6 and §7, cover most of this; the
lifecycle adds the following.

**On the house** (Bridge Pro, no sensors; the Test actions of R12, or the
dev loop):

1. With a test device showing motion, restart Director: what state does
   the proxy come back with, does Verified read No until the first state,
   and does `STATE_*` set it without firing an event (C4R T6, here with no
   sensor)? Does the proxy send `GET_STATE`, and when?
2. A test device's state changed while Director restarts (motion before,
   no motion after): `CLOSED` at the first reading fires "stops sensing
   motion" once (R4).
3. Delete a test device that has programming: the programming goes with
   it (C4), which is why the manual says re-link.
4. `Add Motion Sensor` on the house bridge, which has no sensors: the
   picker's empty line and the areas line, with `/resource/clip` and the
   empty area list of HR §7.2 (B5).

**By the tester** (sensors, the beta's Diagnostics action), adding to
HR §7.1:

5. The order and timing of `motion_report` items around one walk past,
   and whether `changed` is present on every item (R6).
6. The sensor switched off and on in the Hue app (S7); its batteries
   removed until it is not reachable, and how long that takes (S8, S9).
7. An area paused and resumed, and used for lights then for security:
   which service changes, and the configuration's `enabled` and `health`
   (A6, A9).
8. A light of an area switched off at the wall: the participant's and the
   area's health, and whether motion is still reported (A5).
