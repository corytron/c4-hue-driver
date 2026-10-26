# Hue motion sensors and MotionAware: research (the Hue side)

**Status (2026-10-26): research for issue #268, the Hue side only; nothing
here is approved or built.** The Control4 side (which proxy, which
properties, what is imported and when) belongs to the feature's contract.
Every fact below comes from public sources (§8). Nothing was checked against
a bridge: the owner has no sensors and this research could not reach the
house bridge. The tester's first run of the diagnostics in §6 confirms or
corrects every shape marked assumed; §7 lists what he, the house bridge and
Signify's login-only pages can still answer.

Markers:

- **[verified: S]**: shown by source S (§8): code that parses real bridges
  (aiohue, Home Assistant, openHAB), a JSON dump taken from a real bridge, or
  a Philips Hue page.
- **[community: S]**: reported by a user or developer in S (an issue, a
  forum post, a pull request description); plausible, not shown by code or
  a dump. Treat it as assumed when designing.
- **[assumed]**: no source shows it; reasoning or analogy, for the tester to
  confirm.
- **[needs the owner to paste: page]**: the fact is only on Signify's
  login-only developer reference, which this research may not read.

Where this document says "dump", it means a JSON file a project recorded
from its own bridge and kept as a test fixture: aiohue's of July 2026 (a
Bridge Pro: it holds MotionAware areas), openHAB's of 2023 to 2026, Home
Assistant's of 2023. Fixture ids and names in those projects are anonymised;
the shapes are the bridge's. Home Assistant's MotionAware items carry 2023
times, two years before MotionAware existed, so they were written by hand
and count only where a recorded dump agrees.

## Summary

1. A Hue motion sensor is a `device` whose `product_data.model_id` is
   SML001 or SML003 (indoor) or SML002 or SML004 (outdoor), with five or six
   services: `motion`, `light_level`, `temperature`, `device_power`,
   `zigbee_connectivity` and, on current firmware, `device_software_update`.
   Indoor and outdoor sensors expose the same resources.
2. Motion is `motion.motion_report.motion` with the time it last changed;
   light is `light.light_level_report.light_level`, 10000·log10(lux)+1, so
   lux = 10^((v−1)/10000) and 0 means too dark to measure; temperature is
   `temperature.temperature_report.temperature` in °C with two decimals; the
   battery is `power_state.battery_level` (0–100) and `battery_state`
   (`normal`, `low`, `critical`). The older fields (`motion.motion`,
   `motion_valid`, `light_level`, `temperature`, `…_valid`) are deprecated
   but still sent in July 2026.
3. Rooms, zones, the home and the Hue app's sensor groups (`service_group`)
   carry aggregated `grouped_motion` and `grouped_light_level` services
   (motion if any member sees motion; one light level). They exist on both
   bridge generations [assumed: they predate the Bridge Pro].
4. MotionAware is Hue Bridge Pro only. A `motion_area_configuration` (name,
   a room, zone or home as `group`, 3–4 participating lights, `health`,
   `enabled`) owns one `convenience_area_motion` and one
   `security_area_motion`, each shaped like a sensor's `motion`. Which of the
   two carries live motion depends on how the area was set up in the Hue app;
   the area's own `enabled` is the switch that counts. Firmware of 2025-09 to
   2026-04 sometimes left fields out.
5. Events: an `update` item carries `id`, `type`, `owner`, `id_v1` where the
   resource has one, and only the changed blocks. Motion start and motion end
   are separate updates; "no motion" follows the last movement after some
   seconds (about 10 s or more, [assumed] through a bridge); light level and
   temperature arrive every few minutes or on large changes [community].
   Both bridge generations send the same shapes; only the MotionAware types
   differ.
6. The API accepts `enabled` on every sensor service, group service and area,
   `sensitivity` on motion and area services, and an area's `name`.
   Proposal: v1 only reads; enabling or disabling a sensor or an area at most
   as an explicit click, never automatically (§4).
7. The tester's first run: a diagnostics action that lists the served
   resource types (`GET /clip/v2/resource/clip`), the shape and values of
   every sensor resource with ids, names, MAC addresses and times replaced,
   and the events of ten minutes (§6).

## 1. Motion sensor devices

### 1.1 The device and its product data

| Fact | Source |
| --- | --- |
| Indoor motion sensors are model ids SML001 and SML003, outdoor ones SML002 and SML004 (Philips' own table, which lists them among the products that do not take part in MotionAware). | [verified: [hue-ma-compat]] |
| SML001 is the first indoor sensor: bridge support came on 2016-09-19. SML003 and SML004 are the 2022 indoor and outdoor models. SML002 is the earlier outdoor model; its year is not recorded here. | [verified: [hue-rn-bridge] for 2016; [deconz-sml003] and [deconz-sml004] for 2022] |
| `product_data` has `model_id`, `manufacturer_name` ("Signify Netherlands B.V."), `product_name`, `product_archetype`, `certified`, `software_version` and the optional `hardware_platform_type`. | [verified: [aiohue-device], [ha-fixture], [aiohue-fixture]] |
| `product_name` is "Hue motion sensor" on SML001 and SML003 and "Hue outdoor motion sensor" on SML004. SML002 most likely says "Hue outdoor motion sensor" too. So the product name tells indoor from outdoor; only the model id tells the generation. | SML001 [verified: [ha-fixture]]; SML003 [verified: [aiohue-fixture]]; SML004 [verified: [ha-71344]]; SML002 [assumed from [deconz-sml002]'s default names] |
| `product_archetype` and `metadata.archetype` are both `unknown_archetype` on sensors. `metadata.name` is the name from the Hue app ("Hue outdoor motion sensor 1" until renamed). | [verified: [ha-fixture], [ha-71344], [aiohue-fixture]] |
| The device's `id_v1` is the v1 presence sensor's, `/sensors/N`. Its `motion` and `device_power` share that N; `light_level` was N+1 and `temperature` N+2 on both devices seen. | [verified: [aiohue-fixture]: device, `motion` and `device_power` 140, `light_level` 141, `temperature` 142; [ha-fixture]: `motion` and `device_power` 66, `light_level` 67, `temperature` 68]; that it always holds [assumed] |
| Sample values of July 2026: SML003 `software_version` "2.85.1", `hardware_platform_type` "100b-11b"; SML001 "100b-10d". | [verified: [aiohue-fixture]] |
| The order of `services` differs between devices (motion first on one dump, zigbee_connectivity first on another): never rely on it. | [verified: [ha-fixture], [ha-71344], [aiohue-fixture]] |
| Since Hue app 5.54.0 (2025-10-30) sensors, sensor groups and MotionAware areas are shown inside rooms; the app placed them where it was confident, and Settings ▸ Devices moves them. Whether that puts the sensor's device in `room.children` (rtype `device`) is not shown by any dump. | the app [verified: [hue-rn-android]]; the API [assumed] |
| A device that owns a `motion` service is a motion sensor, whatever its model id; use the model id only for labels and indoor/outdoor, as the driver already reads capabilities from resources, not model ids ([design.md, Color mapping](design.md#color-mapping)). | [assumed: design proposal] |

### 1.2 The services of a sensor

| rtype | Carries | `id_v1` | Source |
| --- | --- | --- | --- |
| `motion` | motion, sensitivity, `enabled` | `/sensors/N` | [verified: [aiohue-fixture], [ha-fixture]] |
| `light_level` | light level, `enabled` | `/sensors/N+1` | [verified: same] |
| `temperature` | temperature, `enabled` | `/sensors/N+2` | [verified: same] |
| `device_power` | battery level and state; no `enabled` | `/sensors/N` | [verified: same, [aiohue-device-power]] |
| `zigbee_connectivity` | reachability, MAC address | `/sensors/N` [assumed, as lights carry `/lights/N`] | [verified: [openhue-zigbee]] |
| `device_software_update` | firmware update state | none | [verified: [oh-swupdate], [aiohue-fixture]] |

### 1.3 `motion`

| Path | Type and range | Meaning | Source |
| --- | --- | --- | --- |
| `id`, `type` = `motion` | string | | [verified: [aiohue-motion]] |
| `owner` | `{rid, rtype: device}` | the sensor's device | [verified: [aiohue-fixture]] |
| `id_v1` | `/sensors/N` | | [verified: [aiohue-fixture]] |
| `enabled` | boolean | false while the sensor is switched off in the Hue app; it then reports nothing and keeps its last value | [verified: [aiohue-motion], [aiohue-feature]] |
| `motion.motion_report.changed` | ISO 8601 UTC with milliseconds | when the motion value last changed | [verified: [openhue-motion], [iobroker-log]] |
| `motion.motion_report.motion` | boolean | motion now | [verified: [openhue-motion]] |
| `motion.motion` | boolean, deprecated | the same value in its old place | [verified: [openhue-motion]]; still sent in July 2026 [verified: [aiohue-fixture]] |
| `motion.motion_valid` | boolean, deprecated | false when the value is not to be trusted (sensor off or not reporting); validity is now shown by `motion_report` being there | [verified: [openhue-motion], [aiohue-feature]] |
| `sensitivity.sensitivity` | integer, 0 to `sensitivity_max` | | [verified: [openhue-motion], [aiohue-feature]] |
| `sensitivity.sensitivity_max` | integer: 2 on SML001, 4 on SML003 and SML004 | read it, never assume it | SML001 and SML003 [verified: [aiohue-fixture]]; SML004 [verified: [ha-71344], through the v1 API]; SML002 unknown: deCONZ lists 4, zigbee2mqtt three levels [verified: [deconz-sml002], [z2m-sml002]] |
| `sensitivity.status` | `set`, `changing` | `changing` while a new value has not reached the sensor [assumed meaning] | enum [verified: [openhue-motion]]; aiohue maps any other value to `unknown` [verified: [aiohue-feature]] |
| `motion` missing altogether | | aiohue made `motion` optional because some firmware leaves it out, "notably Hue Secure and MotionAware areas" | [verified: [aiohue-motion]] |

Reading rule, as aiohue and Home Assistant apply it: unknown while
`enabled` is false; otherwise `motion_report.motion` when present, else
`motion.motion`; aiohue also answers unknown when `motion_valid` is false
[verified: [aiohue-feature], [ha-binary-sensor]].

Not in CLIP v2 as far as the public models show: the v1 sensor settings
`ledindication`, `delay` (the occupancy timeout) and the dark/daylight
thresholds [assumed: absent from [aiohue-motion], [openhue-motion]].

### 1.4 `light_level`

| Path | Type | Meaning | Source |
| --- | --- | --- | --- |
| `enabled` | boolean | the light sensor on or off | [verified: [aiohue-light-level]] |
| `light.light_level_report.light_level` | integer ≥ 0 | 10000·log10(lux)+1 | [verified: [openhue-light-level]] |
| `light.light_level_report.changed` | date-time | last change | [verified: [openhue-light-level]] |
| `light.light_level`, `light.light_level_valid` | integer, boolean; deprecated | old place; still sent in July 2026 | [verified: [openhue-light-level], [aiohue-fixture]] |

Conversion: lux = 10^((v − 1) / 10000) for v > 0; v = 0 means too dark to
measure, so show 0 lux [verified: [openhue-light-level] for the formula,
[z2m-sml003] for 0 meaning too low to measure]. Home Assistant shows
`int(10 ** ((v - 1) / 10000))` and keeps the raw value as an attribute
[verified: [ha-sensor]]. Values seen in dumps: 0 (night), 7728, 9141, 17227,
18027, 30174 [verified: [aiohue-fixture], [oh-grouped-light-level], [ha-fixture]].

| Raw | Lux | Raw | Lux |
| --- | --- | --- | --- |
| 0 | 0 (too dark) | 20001 | 100 |
| 7728 | 5.9 | 30001 | 1000 |
| 10001 | 10 | 33011 | 2000 |
| 18027 | 63.5 | 40001 | 10000 |

There are no dark or daylight flags in CLIP v2 [assumed: absent from the
models]; the Hue app's "daylight sensitivity" belongs to its automations. A
Control4 "dark" condition would compare lux with a threshold of the driver's
own.

### 1.5 `temperature`

| Path | Type | Meaning | Source |
| --- | --- | --- | --- |
| `enabled` | boolean | | [verified: [aiohue-temperature]] |
| `temperature.temperature_report.temperature` | number, °C | values carry two decimals (22.55, 18.14, 23.34) | [verified: [openhue-temperature], [aiohue-fixture], [ha-fixture], [oh-fixtures] `temperature.json`] |
| `temperature.temperature_report.changed` | date-time | | [verified: [openhue-temperature]] |
| `temperature.temperature`, `temperature.temperature_valid` | deprecated | still sent in July 2026 | [verified: [aiohue-fixture]] |

The v1 API reported hundredths of a degree as an integer (2150 = 21.50 °C)
[verified: [deconz-sml001]]; CLIP v2 sends the float. Home Assistant rounds to
0.1 °C [verified: [ha-sensor]]. Outdoor values below zero are expected
[assumed].

### 1.6 `device_power`

| Path | Type | Meaning | Source |
| --- | --- | --- | --- |
| `power_state.battery_level` | integer 0–100 | percent | [verified: [openhue-device-power]] |
| `power_state.battery_state` | `normal`, `low`, `critical` | `low`: replace soon, some functions such as software updates may stop; `critical`: the device may stop at any moment | [verified: [openhue-device-power], [aiohue-device-power]] |

Dumps show 3 % as `low`, and 20 % and above as `normal`; where `low` begins
is not documented [verified: [aiohue-fixture], [oh-device-power]; the threshold
assumed]. Other battery devices have one too: the openHAB fixtures hold 16
`device_power` items on a bridge whose devices include switches and no
sensor [verified: [oh-device-power], [oh-fixtures] `device.json`]. So the
driver must pick the ones owned by the sensors it shows.

### 1.7 `zigbee_connectivity`, `device_software_update` and device actions

- `zigbee_connectivity.status`: `connected`, `disconnected`,
  `connectivity_issue`, `unidirectional_incoming`; also `mac_address`, and
  `channel` and `extended_pan_id`, which the driver does not need [verified:
  [openhue-zigbee]]. Home Assistant shows every sensor entity of a device as
  unavailable unless its device's status is `connected` [verified:
  [ha-entity]].
- `device_software_update.state`: `no_update`, `update_available`,
  `ready_to_install`, `installing`, `install_failed`, with `problems[]`; no
  `id_v1` [verified: [openhue-swupdate], [oh-swupdate]].
- On the `device`: `{"identify":{"action":"identify"}}` makes a sensor flash
  its LED for about 15 s; `{"usertest":{"usertest":true}}` starts the test
  mode for 120 s (or extends it), in which the device reports changes faster
  and shows them on its LED [verified: [openhue-device-put], [aiohue-feature]].
  Whether sensors carry `usertest` in their GET is not shown [assumed].

### 1.8 Grouped sensors and sensor groups

| Fact | Source |
| --- | --- |
| `grouped_motion`: `id`, `owner {rid, rtype}`, `enabled`, `motion.motion_report {changed, motion}`, `type`. Motion is true when any sensor of the group sees motion. | [verified: [aiohue-grouped-motion], [aiohue-fixture], [openhue] description of `GroupedMotionGet`] |
| Recent dumps carry only `motion_report` in `grouped_motion` (no `motion.motion`, no `motion_valid`) and no `id_v1`; one 2024 dump had `id_v1` `/sensors/5`. | [verified: [aiohue-fixture] (2026-07), [oh-grouped-motion] (2024-12)]; a converter reads only `motion_report` because the bridge sends nothing else [community: [loxone2hue-7]] |
| `grouped_light_level`: `id`, `owner`, `enabled`, `light.light_level_report {changed, light_level}`, `type`; no deprecated fields, no `id_v1`. How the bridge combines several sensors' levels is not documented. | [verified: [aiohue-fixture], [oh-grouped-light-level]]; the rule [assumed] |
| Owners seen: `room`, `bridge_home`, `service_group`; Home Assistant also accepts `zone`. Rooms list them in `services` next to `grouped_light`. | [verified: [aiohue-fixture], [ha-fixture], [ha-binary-sensor]]; zones [assumed] |
| Which rooms get them: dumps show them only on some rooms; probably those holding a motion-capable sensor. Home Assistant hides the room's default one when the room has a single child ("not useful"). | [verified: [aiohue-fixture], [ha-binary-sensor]]; the rule [assumed] |
| `service_group` is, very probably, the Hue app's sensor group ("device group", Hue app 5.19, 2024-06-18): `children` are the members' `motion` and `light_level` services, `services` one `grouped_motion` and one `grouped_light_level`, `metadata.name`; no `id_v1`. In the app, members can be indoor and outdoor sensors and Hue Secure cameras, and a sensor belongs to one group at most. | the shape [verified: [oh-service-group], whose one group is named "Sensor group"]; the app feature [verified: [hue-rn-android], [hueblog-groups]]; that the two are the same [assumed] |
| These exist on the v2 bridge: sensor groups came in 2024, the Bridge Pro in 2025-09. Older firmware answers 404 to `/resource/grouped_motion`. | [assumed: inference from the dates]; the 404 [community: [loxone2hue-7], untested] |
| PUT: `enabled` only. | [verified: [aiohue-sensors]] |

A Control4 "room occupancy" device could therefore come from a room's
`grouped_motion` without importing each sensor [assumed: an option for the
contract].

### 1.9 Other sensor-like services the driver will meet

`camera_motion` (Hue Secure cameras; the same `motion` and `sensitivity`
blocks), `contact` and `tamper` (Secure contact sensor SOC001), `button`,
`relative_rotary`, `bell_button` [verified: [aiohue-resource],
[aiohue-feature], [ha-fixture]]. They are out of scope for #268; the diagnostics
count them so the tester's bridge is fully described.

## 2. MotionAware (Hue Bridge Pro)

### 2.1 What it is and what the owner must set up

| Fact | Source |
| --- | --- |
| Exclusive to the Hue Bridge Pro; launched with it on 2025-09-04 (bridge 2071096000, app 5.50.0). | [verified: [hue-ma-article], [hue-rn-pro], [hue-rn-android]] |
| Signify documented the API for creating, configuring and reading motion areas the same day, and its developer Terms of Use gained conditions and restrictions on MotionAware. | [verified: [hue-dev-news]]; what the conditions say [needs the owner to paste: the Hue developer Terms of Use, MotionAware section]; a user's second-hand claim that only security-system use is off limits [community: [ha-disc-960]] |
| It senses motion from changes in the Zigbee radio signals between three or more lights. | [verified: [hue-ma-article], [oh-readme]] |
| 3 or 4 compatible lights per area (3 at least), all on the same bridge; up to 4 areas per Bridge Pro. | [verified: [hue-ma-article], [hueblog-ma-setup]] |
| Lights 1–7 m apart, not all in a line; walls weaken it; detection can reach adjacent rooms or floors; indoor only; the lights must stay powered. | [verified: [hue-ma-article]] |
| Compatible: about 95 % of Hue products. Not compatible: smart plugs (LOM001–LOM011), Go lamps (LCT026, LCT030, LLC020 and others), several early lights (LCT001, LCT002, LLC010, LLC011, LLC012, LLC014, LST001), every switch, sensor, camera and contact sensor, and every third-party device. | [verified: [hue-ma-compat], [hueblog-ma-setup], [pcworld-ma]] |
| Set-up in the Hue app: Settings ▸ MotionAware, or the ⋯ menu of a room or zone (app 5.53.0, 2025-10-14); pick the room or zone, then 3–4 lights (they blink); leave the area for the calibration of about 20 s; choose the response: control lights, send alerts, or both; then time slots (up to 10), sensitivity and a daylight setting. | [verified: [hue-ma-article], [hue-rn-android], [pcworld-ma]] |
| Controlling lights is free; alerts need a Hue Secure plan or a MotionAware plan (0.99 € a month, 30-day trial). | [verified: [hue-ma-article], [pcworld-ma]] |
| Lights came on 1–2 s after entering; one Home Assistant user found an area too slow as a trigger for his own automations. | [community: [hueblog-ma-setup], [ha-disc-960]] |
| Since app 5.54.0 areas appear in their rooms and can use the daylight reading of another sensor or sensor group; sensor groups can include areas. | [verified: [hue-rn-android], [hue-ma-article]] |

### 2.2 The resources and how they relate

```text
motion_area_configuration          one per area; no id_v1, no owner
 ├─ group ─────────────► room | zone | bridge_home
 ├─ participants[] ────► motion_area_candidate ──owner──► device (a light) ──services──► light
 └─ services[] ────────► convenience_area_motion   owner = the configuration
                         security_area_motion      owner = the configuration
behavior_instance (the app's automation) ──source──► motion_area_configuration   [community: ha-181632]
```

### 2.3 `motion_area_configuration`

| Path | Type | Meaning | Source |
| --- | --- | --- | --- |
| `id`, `type` | string | | [verified: [oh-area-config], [aiohue-fixture]] |
| `name` | string | the area's name in the app; "Motion area" in one dump, "Bewegungsbereich" in a German report, so probably the app's default | [verified: [oh-area-config], [ha-181632]]; the default [assumed] |
| `group` | `{rid, rtype}`: `room`, `zone` or `bridge_home` | the room or zone the area belongs to; a whole-home area points at `bridge_home` (which crashed Home Assistant until 2026-09) | [verified: [oh-area-config], [aiohue-fixture] (room), [ha-182586] and [ha-181632] (bridge_home)]; whether a multi-room area also gets `bridge_home` [assumed] |
| `participants[]` | `{resource {rid, rtype: motion_area_candidate}, status {health}}` | the sensing lights: 3 in one dump, 4 per area in another | [verified: [oh-area-config], [aiohue-fixture]] |
| `participants[].status.health` | as `health`, plus `unhealthy`, which only appears here; `status` was missing on early firmware | per light | [verified: [aiohue-area-config]; community: [ha-152937] for the missing `status`] |
| `services[]` | two references: `convenience_area_motion`, `security_area_motion` | | [verified: [oh-area-config], [aiohue-fixture]] |
| `health` | `healthy`, `degraded`, `recovering`, `unrecoverable`, `not_running`, `unknown` | the area's state; `not_running`: not sensing | enum [verified: [aiohue-area-config]]; meanings [assumed]; "unrecoverable" is fixed by checking power and saving the area again [verified: [hue-ma-article]] |
| `enabled` | boolean | the area's on/off switch in the app; the one that counts (§2.5) | [verified: [ha-binary-sensor], [ha-switch]] |
| `id_v1`, `owner` | absent | | [verified: [oh-area-config], [aiohue-fixture]] |
| PUT | `enabled`, `name` | | [verified: [aiohue-area-config]] |

One developer saw a Bridge Pro answer only `id`, `owner`, `enabled` and
`type` for this resource and later found the full shape on firmware
1.77.2071353020; the maintainer judged it firmware-dependent [community:
[aiohue-pr599]]. [openhue]'s schema (`enabled`, `motion_sensors[]`) matches none
of the dumps [verified: [openhue-area-config]].

### 2.4 `convenience_area_motion` and `security_area_motion`

The fields of a sensor's `motion` (§1.3): `id`, `owner {rid of the
configuration, rtype: motion_area_configuration}`, `enabled`, `motion
{motion, motion_valid, motion_report {changed, motion}}`, `sensitivity
{sensitivity, sensitivity_max: 4}`, `type`. Unlike a sensor's, they have no
`id_v1` and no `sensitivity.status` [verified: [oh-convenience], [oh-security],
[aiohue-fixture], [ha-fixture]].

- On firmware 1.73 to 1.76 (2025-09 to 2026-04) `motion` was missing from
  area services on some bridges (the security service; in one report the
  convenience service too), mostly where Hue Secure or a camera was
  involved; a bridge update at the end of April 2026 fixed most reports
  [community: [ha-168297], [ha-152937], [aiohue-pr599]].
- `motion_valid` does not mean on areas what it means on sensors: both
  services had it false in an October 2025 dump; in a July 2026 dump the
  convenience service had it false, with a value unchanged since 2025-09-23,
  and the security service true [verified: [oh-convenience], [oh-security],
  [aiohue-fixture], [ha-177643]]. So it cannot be read as "has a value";
  aiohue's reading rule, which answers unknown when it is false, left areas
  unknown in Home Assistant [assumed: inference from [aiohue-feature] and
  [ha-152937]].

### 2.5 Which service reports, and what `enabled` means

- Which of the two services reports the area's motion depends on whether the
  area is bound to lights in the Hue app [verified: [ha-177643], quoting its
  commit; [ha-binary-sensor]: "a zone that is bound to lights reports on" the
  convenience service]. In one light-bound area the stream carried seven
  convenience updates and no security update [community: [ha-177643]].
- The other service keeps its last value, and may keep `motion_valid` true
  while frozen [community: [ha-177643]].
- Turning an area off in the app sets the configuration's `enabled` to false
  and leaves the services' `enabled` alone; writing a service's `enabled`
  changes nothing on the bridge [verified: [ha-binary-sensor] comment;
  community: [ha-153935]].
- Home Assistant's rule since 2026-08: unknown while the configuration is
  disabled or `not_running`; otherwise the convenience service, then the
  security service, the first that is enabled and has a value [verified:
  [ha-binary-sensor], [ha-177643]].
- An area's light automation is a `behavior_instance` whose source is the
  configuration; enabling or disabling it through the API is refused with
  HTTP 400 "The instance doesn't support triggers" [community: [ha-153935],
  [ha-160393], [ha-181632]].
- Proposed rule for the driver: the area's motion is the value of whichever
  enabled service changed most recently (`motion_report.changed`, events
  included); unknown while the configuration is disabled or `not_running`
  [assumed: design proposal; the diagnostics record both services].

### 2.6 `motion_area_candidate`

- One bridge answered `GET /resource/motion_area_candidate` with four items
  of `id`, `owner {rid, rtype: device}` (a light's device), `capabilities`
  (`sensor`, `collector`, `sync`) and `type`; three of them took part in its
  one area [verified: [oh-candidate], [oh-area-config]]. So candidates are
  probably the bridge's compatible lights, area or not [assumed: inference].
- aiohue calls the type "reference-only", never served (its list of served
  types was checked on a Bridge Pro in July 2026) [verified:
  [aiohue-resource]]. The two disagree; the tester's bridge answers.
- What the three capabilities mean is not public [needs the owner to paste:
  API reference, motion_area_candidate].

### 2.7 What a v2 bridge lacks, and a Bridge Pro without areas

- The v2 (square) bridge has none of `motion_area_configuration`,
  `convenience_area_motion`, `security_area_motion` and
  `motion_area_candidate` [verified: [hue-ma-article], "exclusively with the
  Hue Bridge Pro"]. The served-types list the openHAB binding recorded
  lists none of them, and the bridge device it recorded is a BSB002
  [verified: [oh-clip], [oh-fixtures] `device.json`; that both come from one
  bridge assumed]. What the endpoints answer there (404 or an empty list) is
  not shown [assumed: 404].
- Everything in §1 exists on both bridges [assumed: sensors date from 2016,
  sensor groups from 2024, both before the Bridge Pro].
- A Bridge Pro serves the three area types [verified: [aiohue-resource]]. With
  no area configured their lists are empty [community: [ha-152937], a later
  sync with 0 items]; candidates may still be listed (§2.6).
- The house Bridge Pro can answer all of this without any sensor (§7.2).

### 2.8 Areas and grouped motion

Whether an area's motion also shows in its room's `grouped_motion` is not
known; one reporter's bridge had 2 areas and 1 `grouped_motion` [community:
[ha-152937]; the relation assumed].

## 3. The event stream

### 3.1 Shapes

- Containers are `{creationtime, data[], id, type}` with `type` `add`,
  `update`, `delete` or `error`; at most one container a second (two a
  second seen on the house), a value that changed twice in that second
  reports its last value, and several resources share a container
  [verified: [design.md, Event stream](design.md#event-stream)].
- An update item carries `id`, `type`, `owner`, `id_v1` (when the resource
  has one) and the changed blocks. A sensor's motion update carries the whole
  `motion` block: `motion`, `motion_valid` and `motion_report`; a temperature
  update the whole `temperature` block; keys arrived in alphabetical order
  [verified: [iobroker-log], a v2 bridge in 2023].
- The same resource can appear twice in one container, each item with part
  of the change (a grouped_light's `on` and `dimming` as two items)
  [verified: [oh-event]]. Apply items in order.
- aiohue sends `last-event-id` on reconnect [verified: [aiohue-events]];
  whether the bridge replays anything is unconfirmed
  ([design.md, Event stream](design.md#event-stream)), so state after a
  reconnect comes from the resync GETs.

| Item `type` | What an update carries besides `id`, `type`, `owner` | Source |
| --- | --- | --- |
| `motion` | `id_v1`; `motion {motion, motion_valid, motion_report}`; `enabled` when switched; `sensitivity` when changed | motion [verified: [iobroker-log]]; `enabled`, `sensitivity` [assumed] |
| `light_level` | `id_v1`; `light {light_level, light_level_valid, light_level_report}` | [assumed: as temperature] |
| `temperature` | `id_v1`; `temperature {temperature, temperature_valid, temperature_report}` | [verified: [iobroker-log]] |
| `device_power` | `id_v1`; `power_state {battery_level, battery_state}` | [assumed] |
| `zigbee_connectivity` | `id_v1`; `status` | [assumed, as `F.events.connectivity` in [the fixtures](../tests/fixtures/hue_resources.lua); that the house Bridge Pro sends such updates for lights now and then is verified ([design.md, Event stream](design.md#event-stream))] |
| `grouped_motion` | `motion {motion_report}` | [community: [loxone2hue-7]] |
| `grouped_light_level` | `light {light_level_report}` | [assumed] |
| `convenience_area_motion`, `security_area_motion` | `motion {…}`; only the live one sends updates | [community: [ha-177643]] |
| `motion_area_configuration` | whichever of `enabled`, `health`, `name`, `participants` changed; no `owner` | [assumed] |

- `add` items are complete resources, as in a GET [assumed; aiohue parses an
  added item as a full object: verified [aiohue-base]]. A newly paired sensor
  brings its device and services, perhaps over several containers; a new
  area its configuration and both services, plus a `behavior_instance` when
  it controls lights [assumed].
- `delete` items carry `id` and `type` only [assumed, as
  [edge-cases-hue.md §5](edge-cases-hue.md#5-event-stream-specifics-and-the-resync)
  already assumes for lights; aiohue needs nothing else: verified
  [aiohue-base]]. Resolve them through the cache.

### 3.2 Timing

| What | When | Source |
| --- | --- | --- |
| Motion starts | one update with motion true, within the bridge's one-second batching | [verified: [iobroker-log]; [design.md](design.md#event-stream)] |
| Motion ends | a separate update with motion false. In a 2023 log motion stayed true for 18.8 s and 25.1 s, false for 4.0 s in between | [verified: [iobroker-log]] |
| Hold time after the last movement | at least 10 s on a sensor joined to another Zigbee hub (shorter settings give 10 s); through a Hue bridge, which configures the sensor itself, unknown | [community: [z2m-sml002], [ha-forum-10s]]; through the bridge [assumed] |
| While motion continues | no source; expected: nothing until it ends [assumed]. On its own Zigbee link an SML003 reports occupancy again 5 s and 10 s after detecting | [verified for direct Zigbee: [z2m-sml003]] |
| Light level | about every 5 minutes, sooner on a large change (one user of the v1 era: more than 2000 units) and around motion | [community: [oh-forum-5min], [hubitat-lux]] |
| Temperature | about every 5 minutes, in steps of 0.01 °C | [community: [oh-forum-5min]]; the steps [verified: [aiohue-fixture], [ha-fixture]] |
| Battery | rarely; a first report can take up to 24 h on another hub | [community: [z2m-sml002]] |
| Grouped motion | follows its members | [assumed] |
| MotionAware | lights react 1–2 s after entry; no data on how long motion stays true | [community: [hueblog-ma-setup]] |
| Test mode (`usertest`) | 120 s of faster reports | [verified: [openhue-device-put]] |

A house with sensors sends light-level and temperature updates every few
minutes, so the stream watchdog (600 s by default,
[design.md, Event stream](design.md#event-stream)) would rarely fire there
[assumed].

### 3.3 Bridge generations

The same stream and shapes on both; the differences found are the MotionAware
types (Bridge Pro only) and the Bridge Pro firmware fixes above. Nothing else
was found [assumed].

### 3.4 What it means for the code today

- `bridge/sse.lua` and `bridge/stream.lua` need no change: the containers are
  the ones they parse now, and `on_container` in `src/hue_bridge/driver.lua`
  fans each one out to the modules [verified: code reading].
- `bridge/lights.lua` routes items by `item.type` and ignores types it does
  not know, so sensor items pass through it harmlessly today. It also sees a
  sensor's `device` and `zigbee_connectivity` items: it keeps a device record
  with no lights and the sensor's MAC address in its device-to-MAC map, and
  tells no light [verified: code reading, `on_container_body`,
  `on_connectivity_item`, `on_device_item`; a spec should pin the sensor
  case].
- `hue_model.lua` picks a group's `grouped_light` and a device's `light` and
  `zigbee_connectivity` by rtype, so rooms that also list `grouped_motion` or
  hold a sensor device do not disturb lights, zone lights or scenes
  [verified: code reading].
- A sensor module must resolve every item through its own cache (deletes
  carry no owner), apply items in order, merge partial blocks, read
  `motion_report` first, and tolerate any block being absent.

### 3.5 Lifecycle as the stream shows it (input for the edge-case catalogue)

| Case on the Hue side | What arrives | Source |
| --- | --- | --- |
| Sensor paired | `add` for the device and each service; perhaps a room `update` when the app places it | [assumed] |
| Sensor renamed | `update` of the device's `metadata.name` | [assumed, as for lights] |
| Sensor switched off or on in the app | `update` of `motion.enabled` | [assumed] |
| Sensor moved to another room (app 5.54+) | `update` of both rooms' `children` | [assumed] |
| Batteries flat or removed | `battery_state` `low` then `critical`; later `zigbee_connectivity` not `connected` (how long after: unknown) | [assumed] |
| Sensor deleted, or reset and paired again | `delete` items; a re-paired sensor gets new resource ids | [assumed, as for lights ([edge-cases-hue.md](edge-cases-hue.md))] |
| Area created, edited (lights changed, recalibrated), renamed, deleted | `add`; `update` of `participants`, `health` or `name`; `delete` of the configuration and both services | [assumed] |
| Area switched off in the app | `update` of the configuration's `enabled` | [assumed; the GET side verified: [ha-binary-sensor]] |
| A light of an area powered off | that participant's `health`, then the area's | [assumed; "lights must be powered": verified [hue-ma-article]] |
| Bridge v2 moved to a Bridge Pro | sensors and groups move with it; areas only exist afterwards | [assumed] |

## 4. Writes and rate limits

### 4.1 What the API accepts

`PUT /clip/v2/resource/<type>/<id>`:

| Resource | Body | Effect | Source |
| --- | --- | --- | --- |
| `motion` | `{"enabled":false}` | the sensor stops reporting; presumably the Hue app's automations on it stop too | body [verified: [aiohue-motion], [openhue-motion-put]]; the side effect [assumed] |
| `motion` | `{"sensitivity":{"sensitivity":3}}` | 0 to `sensitivity_max`; `status` reads `changing` until the sleeping battery sensor takes it | body [verified: [openhue-motion-put]]; the delay [assumed] |
| `light_level`, `temperature` | `{"enabled":false}` | | [verified: [aiohue-light-level], [aiohue-temperature]] |
| `grouped_motion`, `grouped_light_level` | `{"enabled":false}` | | [verified: [aiohue-sensors]] |
| `motion_area_configuration` | `{"enabled":false}`, `{"name":"…"}` | the area off or on, as the app does; Home Assistant's area switch writes this | [verified: [aiohue-area-config], [ha-switch]]; that it works [community: [aiohue-pr599]] |
| `convenience_area_motion`, `security_area_motion` | `{"enabled":…}`, `{"sensitivity":{"sensitivity":n}}` | `enabled` changes nothing on the bridge | bodies [verified: [aiohue-sensors]]; no effect [community: [ha-153935]] |
| `device` | `{"identify":{"action":"identify"}}`, `{"usertest":{"usertest":true}}`, `{"metadata":{"name":"…"}}` | LED for 15 s; test mode for 120 s; rename | [verified: [openhue-device-put]] |
| an area's `behavior_instance` | `enabled` | refused, HTTP 400 | [community: [ha-153935]] |
| creating or deleting an area | documented by Signify | | [needs the owner to paste: API reference, motion_area_configuration] |

### 4.2 Should the driver write?

Following CLAUDE.md "Edge cases before automation":

| Write | Proposal | Why |
| --- | --- | --- |
| Anything automatic | Forbidden | The Hue app is where sensors and areas are configured; a write Control4 made on its own would surprise the owner there. |
| Switch a sensor or an area off or on | Offered only, as an action the owner clicks; not in v1 unless the owner asks | It also stops the Hue app's own automations on that sensor or area [assumed]; Control4 programming can ignore a sensor without switching it off. |
| Sensitivity | Forbidden | Per-model ranges; battery sensors apply it late; an area's is tuned together with its calibration in the app. |
| Rename, identify, test mode | Forbidden without a click; identify or test mode could serve a later diagnostics step | Harmless but visible to the household (LED, faster reports). |
| An area service's `enabled`; an area's automation | Forbidden | No effect, or refused (§4.1). |
| Creating or deleting areas | Forbidden | Needs calibration with the room empty. |

### 4.3 Rate limits

- Signify's general guidance, already applied: about 10 commands a second to
  lights, at most one a second to `grouped_light`, and the REST API is not
  for fast streams
  ([design.md, Commands and rate limiting](design.md#commands-and-rate-limiting)).
  No public source gives a limit for sensor resources [needs the owner to
  paste: Core Concepts, if it says more].
- Reads: the resync after each stream connect would grow by up to ten small
  GETs (`motion`, `light_level`, `temperature`, `device_power`,
  `grouped_motion`, `grouped_light_level`, `service_group`,
  `motion_area_configuration`, `convenience_area_motion`,
  `security_area_motion`), plus `/resource/clip` once per start. They queue
  one at a time on the commands' address with the others; the single `GET
  /clip/v2/resource` stays avoided (588 KB on the house). Director's cap of
  four concurrent transfers is unaffected
  ([design.md, Concurrent transfers](design.md#concurrent-transfers-verified-2026-10-25)).
- Writes: clicks only, one PUT in flight through the existing command queue;
  nothing to coalesce.
- Events: no new connection; sensors only add containers.

## 5. Fixtures

Invented data for the specs, in the shapes of §1–§3. Conventions:

- Ids are made up, hexadecimal and coded by type: `de…` device, `a0…`
  motion, `11…` light_level, `7e…` temperature, `ba…` device_power, `2b…`
  zigbee_connectivity, `50…` device_software_update, `40…` room or home,
  `8e…` grouped_light, `9a…` grouped_motion, `91…` grouped_light_level,
  `ac…` motion_area_configuration, `ca…` convenience_area_motion, `5a…`
  security_area_motion, `cd…` motion_area_candidate, `e0…` event container.
  The last digits name the object: `…01` the indoor sensor "Hallway sensor"
  (SML003) and its room "Hallway"; `…02` the outdoor sensor "Porch sensor"
  (SML004), in no room, and the room "Kitchen"; `…03` a sensor paired later
  (SML001); `…11` to `…14` the kitchen lights' devices; `…21` the hallway
  lamp's device; `…f0` the home.
- MAC addresses are invented; the bridge id, where one is needed, is the
  placeholder 001788fffe123abc. Times are UTC on 2026-10-26.
- An SSE message id is the Unix second and a counter, as the bridge sends
  them (`bridge/sse.lua` keeps them whole).
- Assumed parts, as marked in §1–§3: `usertest` on sensor devices, the
  sensors' connectivity `id_v1`, every software and hardware version except
  the SML003's, the grouped light level of the home,
  the event bodies of `light_level`, `device_power`, `enabled`,
  `sensitivity` and every MotionAware event, the add and delete containers,
  and grouped items sharing a container with the sensor's.

### 5.1 The two sensors (GET results)

`GET /clip/v2/resource/device`, the sensors only:

```json
{"errors":[],"data":[
{"id":"de000000-0000-4000-8000-000000000001","id_v1":"/sensors/12",
 "product_data":{"model_id":"SML003","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue motion sensor",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1","hardware_platform_type":"100b-11b"},
 "metadata":{"name":"Hallway sensor","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"2b000000-0000-4000-8000-000000000001","rtype":"zigbee_connectivity"},
  {"rid":"a0000000-0000-4000-8000-000000000001","rtype":"motion"},
  {"rid":"ba000000-0000-4000-8000-000000000001","rtype":"device_power"},
  {"rid":"11000000-0000-4000-8000-000000000001","rtype":"light_level"},
  {"rid":"7e000000-0000-4000-8000-000000000001","rtype":"temperature"},
  {"rid":"50000000-0000-4000-8000-000000000001","rtype":"device_software_update"}],
 "type":"device"},
{"id":"de000000-0000-4000-8000-000000000002","id_v1":"/sensors/20",
 "product_data":{"model_id":"SML004","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue outdoor motion sensor",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1","hardware_platform_type":"100b-11b"},
 "metadata":{"name":"Porch sensor","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"a0000000-0000-4000-8000-000000000002","rtype":"motion"},
  {"rid":"ba000000-0000-4000-8000-000000000002","rtype":"device_power"},
  {"rid":"2b000000-0000-4000-8000-000000000002","rtype":"zigbee_connectivity"},
  {"rid":"11000000-0000-4000-8000-000000000002","rtype":"light_level"},
  {"rid":"7e000000-0000-4000-8000-000000000002","rtype":"temperature"},
  {"rid":"50000000-0000-4000-8000-000000000002","rtype":"device_software_update"}],
 "type":"device"}
]}
```

`GET /clip/v2/resource/motion`:

```json
{"errors":[],"data":[
{"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T07:02:41.318Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"},
{"id":"a0000000-0000-4000-8000-000000000002","id_v1":"/sensors/20",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T06:48:09.770Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"}
]}
```

`GET /clip/v2/resource/light_level` (63.5 lux indoors, 1770 lux on the
porch):

```json
{"errors":[],"data":[
{"id":"11000000-0000-4000-8000-000000000001","id_v1":"/sensors/13",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "enabled":true,
 "light":{"light_level":18027,"light_level_valid":true,"light_level_report":{"changed":"2026-10-26T07:11:58.002Z","light_level":18027}},
 "type":"light_level"},
{"id":"11000000-0000-4000-8000-000000000002","id_v1":"/sensors/21",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "enabled":true,
 "light":{"light_level":32480,"light_level_valid":true,"light_level_report":{"changed":"2026-10-26T07:09:31.415Z","light_level":32480}},
 "type":"light_level"}
]}
```

`GET /clip/v2/resource/temperature`:

```json
{"errors":[],"data":[
{"id":"7e000000-0000-4000-8000-000000000001","id_v1":"/sensors/14",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":21.37,"temperature_valid":true,"temperature_report":{"changed":"2026-10-26T07:08:20.551Z","temperature":21.37}},
 "type":"temperature"},
{"id":"7e000000-0000-4000-8000-000000000002","id_v1":"/sensors/22",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":14.62,"temperature_valid":true,"temperature_report":{"changed":"2026-10-26T07:13:02.919Z","temperature":14.62}},
 "type":"temperature"}
]}
```

`GET /clip/v2/resource/device_power`, `/zigbee_connectivity` and
`/device_software_update`, the sensors' items:

```json
{"errors":[],"data":[
{"id":"ba000000-0000-4000-8000-000000000001","id_v1":"/sensors/12",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":87},
 "type":"device_power"},
{"id":"ba000000-0000-4000-8000-000000000002","id_v1":"/sensors/20",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":64},
 "type":"device_power"}
]}
```

```json
{"errors":[],"data":[
{"id":"2b000000-0000-4000-8000-000000000001","id_v1":"/sensors/12",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "status":"connected","mac_address":"00:17:88:01:0c:00:00:01-02",
 "type":"zigbee_connectivity"},
{"id":"2b000000-0000-4000-8000-000000000002","id_v1":"/sensors/20",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "status":"connected","mac_address":"00:17:88:01:0c:00:00:02-02",
 "type":"zigbee_connectivity"}
]}
```

```json
{"errors":[],"data":[
{"id":"50000000-0000-4000-8000-000000000001",
 "owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},
 "state":"no_update","problems":[],"type":"device_software_update"},
{"id":"50000000-0000-4000-8000-000000000002",
 "owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},
 "state":"no_update","problems":[],"type":"device_software_update"}
]}
```

### 5.2 The room, the home and their grouped sensors

`GET /clip/v2/resource/room`, the hallway (rooms on a real bridge also carry
a `geometry` block, as the existing fixtures show):

```json
{"errors":[],"data":[
{"id":"40000000-0000-4000-8000-000000000001","id_v1":"/groups/7",
 "children":[{"rid":"de000000-0000-4000-8000-000000000021","rtype":"device"},
  {"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"}],
 "services":[{"rid":"8e000000-0000-4000-8000-000000000001","rtype":"grouped_light"},
  {"rid":"9a000000-0000-4000-8000-000000000001","rtype":"grouped_motion"},
  {"rid":"91000000-0000-4000-8000-000000000001","rtype":"grouped_light_level"}],
 "metadata":{"name":"Hallway","archetype":"hallway"},
 "type":"room"}
]}
```

`GET /clip/v2/resource/grouped_motion` and `/grouped_light_level`:

```json
{"errors":[],"data":[
{"id":"9a000000-0000-4000-8000-000000000001",
 "owner":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},
 "enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},
 "type":"grouped_motion"},
{"id":"9a000000-0000-4000-8000-0000000000f0",
 "owner":{"rid":"40000000-0000-4000-8000-0000000000f0","rtype":"bridge_home"},
 "enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},
 "type":"grouped_motion"}
]}
```

```json
{"errors":[],"data":[
{"id":"91000000-0000-4000-8000-000000000001",
 "owner":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},
 "enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":18027}},
 "type":"grouped_light_level"},
{"id":"91000000-0000-4000-8000-0000000000f0",
 "owner":{"rid":"40000000-0000-4000-8000-0000000000f0","rtype":"bridge_home"},
 "enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":25254}},
 "type":"grouped_light_level"}
]}
```

### 5.3 The MotionAware area (GET results)

The kitchen's area, bound to lights, so its convenience service is the live
one and its security service is frozen.

`GET /clip/v2/resource/motion_area_configuration`:

```json
{"errors":[],"data":[
{"id":"ac000000-0000-4000-8000-000000000001",
 "name":"Kitchen motion area",
 "group":{"rid":"40000000-0000-4000-8000-000000000002","rtype":"room"},
 "participants":[
  {"resource":{"rid":"cd000000-0000-4000-8000-000000000011","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"cd000000-0000-4000-8000-000000000012","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"cd000000-0000-4000-8000-000000000013","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],
 "services":[{"rid":"ca000000-0000-4000-8000-000000000001","rtype":"convenience_area_motion"},
  {"rid":"5a000000-0000-4000-8000-000000000001","rtype":"security_area_motion"}],
 "health":"healthy",
 "enabled":true,
 "type":"motion_area_configuration"}
]}
```

`GET /clip/v2/resource/convenience_area_motion` and
`/security_area_motion`:

```json
{"errors":[],"data":[
{"id":"ca000000-0000-4000-8000-000000000001",
 "owner":{"rid":"ac000000-0000-4000-8000-000000000001","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T07:05:12.640Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"convenience_area_motion"}
]}
```

```json
{"errors":[],"data":[
{"id":"5a000000-0000-4000-8000-000000000001",
 "owner":{"rid":"ac000000-0000-4000-8000-000000000001","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":false,"motion_report":{"changed":"2026-10-19T18:22:03.115Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"security_area_motion"}
]}
```

`GET /clip/v2/resource/motion_area_candidate`, if the bridge serves it
(§2.6); the fourth kitchen light is compatible but not in the area:

```json
{"errors":[],"data":[
{"id":"cd000000-0000-4000-8000-000000000011","owner":{"rid":"de000000-0000-4000-8000-000000000011","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"cd000000-0000-4000-8000-000000000012","owner":{"rid":"de000000-0000-4000-8000-000000000012","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"cd000000-0000-4000-8000-000000000013","owner":{"rid":"de000000-0000-4000-8000-000000000013","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"cd000000-0000-4000-8000-000000000014","owner":{"rid":"de000000-0000-4000-8000-000000000014","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"}
]}
```

### 5.4 Event-stream messages

Each block is one SSE message as it arrives: an `id:` line, a `data:` line
holding the container array, and a blank line.

E1: someone walks into the hallway; the room's and the home's grouped motion
follow in the same container.

```text
id: 1792998902:0
data: [{"creationtime":"2026-10-26T07:15:02Z","data":[{"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","motion":{"motion":true,"motion_report":{"changed":"2026-10-26T07:15:02.087Z","motion":true},"motion_valid":true},"owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"type":"motion"},{"id":"9a000000-0000-4000-8000-000000000001","motion":{"motion_report":{"changed":"2026-10-26T07:15:02.140Z","motion":true}},"owner":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},"type":"grouped_motion"},{"id":"9a000000-0000-4000-8000-0000000000f0","motion":{"motion_report":{"changed":"2026-10-26T07:15:02.141Z","motion":true}},"owner":{"rid":"40000000-0000-4000-8000-0000000000f0","rtype":"bridge_home"},"type":"grouped_motion"}],"id":"e0000000-0000-4000-8000-000000000001","type":"update"}]

```

E2: 14 s later, no motion.

```text
id: 1792998916:0
data: [{"creationtime":"2026-10-26T07:15:16Z","data":[{"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T07:15:16.502Z","motion":false},"motion_valid":true},"owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"type":"motion"},{"id":"9a000000-0000-4000-8000-000000000001","motion":{"motion_report":{"changed":"2026-10-26T07:15:16.560Z","motion":false}},"owner":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},"type":"grouped_motion"},{"id":"9a000000-0000-4000-8000-0000000000f0","motion":{"motion_report":{"changed":"2026-10-26T07:15:16.561Z","motion":false}},"owner":{"rid":"40000000-0000-4000-8000-0000000000f0","rtype":"bridge_home"},"type":"grouped_motion"}],"id":"e0000000-0000-4000-8000-000000000002","type":"update"}]

```

E3: the hallway gets brighter (126 lux), with the room's grouped level.

```text
id: 1792999000:0
data: [{"creationtime":"2026-10-26T07:16:40Z","data":[{"id":"11000000-0000-4000-8000-000000000001","id_v1":"/sensors/13","light":{"light_level":21000,"light_level_report":{"changed":"2026-10-26T07:16:39.877Z","light_level":21000},"light_level_valid":true},"owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"type":"light_level"},{"id":"91000000-0000-4000-8000-000000000001","light":{"light_level_report":{"changed":"2026-10-26T07:16:39.950Z","light_level":21000}},"owner":{"rid":"40000000-0000-4000-8000-000000000001","rtype":"room"},"type":"grouped_light_level"}],"id":"e0000000-0000-4000-8000-000000000003","type":"update"}]

```

E4: the porch warms to 14.88 °C.

```text
id: 1792999085:0
data: [{"creationtime":"2026-10-26T07:18:05Z","data":[{"id":"7e000000-0000-4000-8000-000000000002","id_v1":"/sensors/22","owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},"temperature":{"temperature":14.88,"temperature_report":{"changed":"2026-10-26T07:18:04.610Z","temperature":14.88},"temperature_valid":true},"type":"temperature"}],"id":"e0000000-0000-4000-8000-000000000004","type":"update"}]

```

E5: the porch sensor loses its link.

```text
id: 1792999231:0
data: [{"creationtime":"2026-10-26T07:20:31Z","data":[{"id":"2b000000-0000-4000-8000-000000000002","id_v1":"/sensors/20","owner":{"rid":"de000000-0000-4000-8000-000000000002","rtype":"device"},"status":"connectivity_issue","type":"zigbee_connectivity"}],"id":"e0000000-0000-4000-8000-000000000005","type":"update"}]

```

E6: the hallway sensor is switched off in the Hue app.

```text
id: 1792999450:0
data: [{"creationtime":"2026-10-26T07:24:10Z","data":[{"enabled":false,"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"type":"motion"}],"id":"e0000000-0000-4000-8000-000000000006","type":"update"}]

```

E7: switched on again (not shown), its sensitivity is raised in the app;
the sensor takes it 12 s later.

```text
id: 1792999500:0
data: [{"creationtime":"2026-10-26T07:25:00Z","data":[{"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"sensitivity":{"sensitivity":3,"status":"changing"},"type":"motion"}],"id":"e0000000-0000-4000-8000-000000000007","type":"update"}]

id: 1792999512:0
data: [{"creationtime":"2026-10-26T07:25:12Z","data":[{"id":"a0000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"sensitivity":{"status":"set"},"type":"motion"}],"id":"e0000000-0000-4000-8000-000000000008","type":"update"}]

```

E8: motion in the kitchen area, then none 36 s later (the convenience
service only).

```text
id: 1792999844:0
data: [{"creationtime":"2026-10-26T07:30:44Z","data":[{"id":"ca000000-0000-4000-8000-000000000001","motion":{"motion":true,"motion_report":{"changed":"2026-10-26T07:30:43.902Z","motion":true},"motion_valid":true},"owner":{"rid":"ac000000-0000-4000-8000-000000000001","rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"e0000000-0000-4000-8000-000000000009","type":"update"}]

id: 1792999880:0
data: [{"creationtime":"2026-10-26T07:31:20Z","data":[{"id":"ca000000-0000-4000-8000-000000000001","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T07:31:19.655Z","motion":false},"motion_valid":true},"owner":{"rid":"ac000000-0000-4000-8000-000000000001","rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"e0000000-0000-4000-8000-00000000000a","type":"update"}]

```

E9: two separate moments: the area is switched off in the app; later, back
on (not shown), one of its lights loses power.

```text
id: 1793000400:0
data: [{"creationtime":"2026-10-26T07:40:00Z","data":[{"enabled":false,"id":"ac000000-0000-4000-8000-000000000001","type":"motion_area_configuration"}],"id":"e0000000-0000-4000-8000-00000000000b","type":"update"}]

id: 1793000490:0
data: [{"creationtime":"2026-10-26T07:41:30Z","data":[{"health":"degraded","id":"ac000000-0000-4000-8000-000000000001","participants":[{"resource":{"rid":"cd000000-0000-4000-8000-000000000011","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"cd000000-0000-4000-8000-000000000012","rtype":"motion_area_candidate"},"status":{"health":"unhealthy"}},{"resource":{"rid":"cd000000-0000-4000-8000-000000000013","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],"type":"motion_area_configuration"}],"id":"e0000000-0000-4000-8000-00000000000c","type":"update"}]

```

E10: a first-generation indoor sensor (SML001) is paired: complete
resources in one `add` container.

```text
id: 1793001900:0
data: [{"creationtime":"2026-10-26T08:05:00Z","data":[{"id":"de000000-0000-4000-8000-000000000003","id_v1":"/sensors/30","identify":{},"metadata":{"archetype":"unknown_archetype","name":"Hue motion sensor 1"},"product_data":{"certified":true,"hardware_platform_type":"100b-10d","manufacturer_name":"Signify Netherlands B.V.","model_id":"SML001","product_archetype":"unknown_archetype","product_name":"Hue motion sensor","software_version":"2.85.1"},"services":[{"rid":"a0000000-0000-4000-8000-000000000003","rtype":"motion"},{"rid":"ba000000-0000-4000-8000-000000000003","rtype":"device_power"},{"rid":"2b000000-0000-4000-8000-000000000003","rtype":"zigbee_connectivity"},{"rid":"11000000-0000-4000-8000-000000000003","rtype":"light_level"},{"rid":"7e000000-0000-4000-8000-000000000003","rtype":"temperature"},{"rid":"50000000-0000-4000-8000-000000000003","rtype":"device_software_update"}],"type":"device"},{"enabled":true,"id":"a0000000-0000-4000-8000-000000000003","id_v1":"/sensors/30","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T08:04:58.310Z","motion":false},"motion_valid":true},"owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"sensitivity":{"sensitivity":2,"sensitivity_max":2,"status":"set"},"type":"motion"},{"id":"ba000000-0000-4000-8000-000000000003","id_v1":"/sensors/30","owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"power_state":{"battery_level":100,"battery_state":"normal"},"type":"device_power"},{"id":"2b000000-0000-4000-8000-000000000003","id_v1":"/sensors/30","mac_address":"00:17:88:01:0c:00:00:03-02","owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"status":"connected","type":"zigbee_connectivity"},{"enabled":true,"id":"11000000-0000-4000-8000-000000000003","id_v1":"/sensors/31","light":{"light_level":9141,"light_level_report":{"changed":"2026-10-26T08:04:58.402Z","light_level":9141},"light_level_valid":true},"owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"type":"light_level"},{"enabled":true,"id":"7e000000-0000-4000-8000-000000000003","id_v1":"/sensors/32","owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"temperature":{"temperature":20.56,"temperature_report":{"changed":"2026-10-26T08:04:58.455Z","temperature":20.56},"temperature_valid":true},"type":"temperature"},{"id":"50000000-0000-4000-8000-000000000003","owner":{"rid":"de000000-0000-4000-8000-000000000003","rtype":"device"},"problems":[],"state":"no_update","type":"device_software_update"}],"id":"e0000000-0000-4000-8000-00000000000d","type":"add"}]

```

E11: the same sensor is deleted in the app: bare identifiers.

```text
id: 1793002800:0
data: [{"creationtime":"2026-10-26T08:20:00Z","data":[{"id":"a0000000-0000-4000-8000-000000000003","type":"motion"},{"id":"11000000-0000-4000-8000-000000000003","type":"light_level"},{"id":"7e000000-0000-4000-8000-000000000003","type":"temperature"},{"id":"ba000000-0000-4000-8000-000000000003","type":"device_power"},{"id":"2b000000-0000-4000-8000-000000000003","type":"zigbee_connectivity"},{"id":"50000000-0000-4000-8000-000000000003","type":"device_software_update"},{"id":"de000000-0000-4000-8000-000000000003","type":"device"}],"id":"e0000000-0000-4000-8000-00000000000e","type":"delete"}]

```

E12: seven weeks later the hallway sensor's battery runs low.

```text
id: 1797217960:0
data: [{"creationtime":"2026-12-14T03:12:40Z","data":[{"id":"ba000000-0000-4000-8000-000000000001","id_v1":"/sensors/12","owner":{"rid":"de000000-0000-4000-8000-000000000001","rtype":"device"},"power_state":{"battery_level":9,"battery_state":"low"},"type":"device_power"}],"id":"e0000000-0000-4000-8000-00000000000f","type":"update"}]

```

## 6. Diagnostics for the tester's first run

The tester runs a prerelease build, without the dev loop, so the diagnostics
must be an ordinary action of the bridge driver that writes to the driver's
log at a level written whatever Debug Mode says (`log.always`), from where
he copies it into the issue. What it should record:

### 6.1 What to fetch

1. The bridge's model and firmware, already known from `/api/0/config`
   ([bridge-compat-design.md](bridge-compat-design.md)).
2. `GET /clip/v2/resource/clip`: the list of resource types the bridge
   serves, the cheapest way to tell a v2 bridge from a Bridge Pro with
   MotionAware, and to see types nobody has met yet [verified:
   [aiohue-clip], [oh-clip]]. Log the whole list; a 404 is an answer too.
3. One GET per type, logging the HTTP status, the `errors` array and the
   item count, then each item as in §6.2: `device` (only devices owning a
   `motion` service or with a model id starting "SML"), `motion`,
   `light_level`, `temperature`, `device_power`, `zigbee_connectivity` and
   `device_software_update` (those owned by such devices), `grouped_motion`,
   `grouped_light_level`, `service_group`, `motion_area_configuration`,
   `convenience_area_motion`, `security_area_motion`,
   `motion_area_candidate`; and counts only for `camera_motion`, `contact`,
   `tamper`.
4. From `room`, `zone` and `bridge_home` (already fetched by the resync):
   per group only whether its `services` list `grouped_motion` or
   `grouped_light_level`, and how many of its `children` are sensor
   devices.

### 6.2 What to log per resource

- Its shape: every key path present, sorted, with the JSON type of each leaf
  (`motion.motion_report.changed:string`, `sensitivity.status:string`, …).
  This is what settles which fields exist on his firmware, including the
  deprecated ones.
- Its values, except those in §6.4: `enabled`, motion booleans, `motion_valid`,
  `sensitivity`, `sensitivity_max`, `sensitivity.status`, light level (raw
  and lux), temperature, battery level and state, connectivity status,
  update state, `health` (area and each participant), `capabilities`,
  `id_v1`, model id, product name, archetypes, software version, hardware
  platform.
- Its relations, through aliases (§6.4): owner, group, participants,
  services, children.

### 6.3 Event capture

For ten minutes after the action (or until it is run again), log every
container item whose type is one of §6.1's or whose owner is a sensor device:
the time since the capture began in milliseconds, the container's type and
alias, the item's type and alias, its key paths and values as in §6.2, and
the time since the previous item of the same resource. The tester walks past
each sensor, waits, walks past again, and covers or lights a sensor. The log
then answers how long motion stays true, whether a continuing movement sends
anything, how often light level and temperature arrive, and which of an
area's two services reports. Cap it (for example 300 lines) so a busy house
cannot flood the log.

### 6.4 Redaction

| Data | Treatment | Why |
| --- | --- | --- |
| Resource ids (UUIDs) | Replaced by aliases per type, numbered in order of appearance and kept for the whole run: `device#1`, `motion#1`, `area#1`, `convenience#1`, `room#2` | Relations survive; the tester's ids do not leave his house |
| Names: `metadata.name`, an area's `name`, a sensor group's, rooms' and zones' | Replaced by `<name:N chars>` | Household names |
| `mac_address`, `extended_pan_id` | `<mac>`, `<pan>` | Hardware identifiers |
| The bridge id | `<bridge>`; the documents write 001788fffe123abc | It is the bridge's MAC address |
| `changed`, `creationtime` | Seconds relative to the moment of the GET or of the capture's start (`-312.4s`, `+12.35s`) | Motion times say when people move at home |
| The application key, the bridge's address | Never logged; the key is also filtered by the existing redactor (`redact_key` in `bridge/devtools.lua`) | Secrets |
| `id_v1`, model ids, product names, archetypes, software versions, hardware platform, `capabilities`, values | Kept | Needed, and not personal |
| The raw `data:` line | Never logged, only the parsed and redacted form | It carries everything above |

### 6.5 What the lines could look like

```text
diag: bridge BSB003 firmware 2071556020; clip: HTTP 200, 46 types; sensors: motion light_level temperature device_power grouped_motion grouped_light_level service_group; MotionAware: motion_area_configuration convenience_area_motion security_area_motion; not served: motion_area_candidate
diag: GET motion: HTTP 200, errors 0, 2 items
diag: motion#1 owner=device#1 v1=/sensors/12 keys=enabled:boolean id id_v1 motion.motion:boolean motion.motion_report.changed:string motion.motion_report.motion:boolean motion.motion_valid:boolean owner.rid owner.rtype sensitivity.sensitivity:number sensitivity.sensitivity_max:number sensitivity.status:string type
diag: motion#1 enabled=true motion=false valid=true report=false changed=-742.6s sensitivity=2/4 set
diag: device#1 SML003 "Hue motion sensor" unknown_archetype sw=2.85.1 hw=100b-11b name=<14 chars> services=zigbee_connectivity#1,motion#1,device_power#1,light_level#1,temperature#1,device_software_update#1
diag: light_level#1 owner=device#1 v1=/sensors/13 level=18027 (63.5 lx) valid=true changed=-283.0s
diag: area#1 name=<19 chars> group=room#2 health=healthy enabled=true participants=candidate#1:healthy,candidate#2:healthy,candidate#3:healthy services=convenience#1,security#1
diag: convenience#1 owner=area#1 enabled=true motion=false valid=true changed=-470.1s sensitivity=2/4 (no status)
diag: room#1 services: grouped_light grouped_motion#1 grouped_light_level#1; sensor children: 1
diag: capture: 600 s, at most 300 lines
diag: +12402ms update c#3 motion#1 motion=true valid=true changed=+12.35s (first)
diag: +26871ms update c#4 motion#1 motion=false valid=true changed=+26.80s (14469 ms after motion#1's last)
diag: capture end: 41 items in 33 containers: motion#1 4, light_level#1 2, temperature#2 2, convenience#1 2
```

## 7. Open questions

### 7.1 For the tester (his bridge answers, through §6)

1. Which bridge (model, firmware) and which sensors (model ids, how many)?
   What does `/resource/clip` list?
2. Are the deprecated fields (`motion.motion`, `motion_valid`,
   `light.light_level`, `temperature.temperature`, `…_valid`) still in his
   GETs and events?
3. How long does motion stay true after the last movement? Does anything
   arrive while movement continues (a new `changed`, a repeated true)?
4. How often do light level and temperature arrive while nothing moves, and
   on a quick change (a lamp switched on next to the sensor)?
5. Which `sensitivity_max` and `status` do his models report? Is
   `sensitivity.status` ever `changing`?
6. Switching a sensor off in the Hue app: is it `motion.enabled` false, in
   one update? Do any events follow while it is off?
7. Are his sensors children of rooms (Hue app 5.54+)? Which rooms, zones or
   the home list `grouped_motion` and `grouped_light_level`? Any sensor
   groups?
8. Battery: level and state now; when did `device_power` last change?
9. If a Bridge Pro with an area: the configuration's `group` rtype,
   participants and their health, which of the two services changes when he
   walks through, `motion_valid` on each, whether `motion` or `sensitivity`
   is missing, and whether `motion_area_candidate` answers.
10. Optional, if he is willing: removing and re-adding one sensor in the Hue
    app, to record the `delete` and `add` containers.

### 7.2 For the house Bridge Pro (no sensors needed)

1. `/resource/clip`, `/resource/motion_area_configuration` (expected: an
   empty list) and `/resource/motion_area_candidate` (a list of the house's
   compatible lights, or 404): the §6 action run once on the house answers
   all three.
2. Whether any room lists `grouped_motion` without a sensor (expected: no).
3. The owner's decision: whether to create one MotionAware area in a room
   with three or four compatible lights, to record a real area and its
   events without the tester. It needs the room empty for about 20 s of
   calibration, and the "control lights" response, which is free, adds a Hue
   automation that switches lights on with motion (time slots can be set to
   do nothing, though one reviewer saw lights change anyway: [pcworld-ma]).

### 7.3 Pages that need the owner to paste

Not needed to build v1; useful to settle §2.6 and §4.1:

1. The CLIP v2 API reference sections `motion_area_configuration`
   (including creation), `convenience_area_motion`, `security_area_motion`
   and `motion_area_candidate`: field descriptions, the meaning of each
   `health` and of the candidate `capabilities`.
2. The Hue developer Terms of Use, the MotionAware section (what a
   third-party integration may and may not do with areas).
3. Core Concepts, only if it says anything about sensors' event rates or
   limits.

## 8. Sources

All read on 2026-10-26. Code and fixtures are cited at their main branch;
the projects anonymise ids and names in their fixtures.

- aiohue, the library Home Assistant's Hue integration uses
  ([aiohue-models]): [aiohue-motion], [aiohue-feature],
  [aiohue-light-level], [aiohue-temperature], [aiohue-device-power],
  [aiohue-device], [aiohue-resource], [aiohue-clip], [aiohue-grouped-motion],
  [aiohue-grouped-light-level], [aiohue-service-group],
  [aiohue-area-config], [aiohue-convenience], [aiohue-security],
  [aiohue-sensors], [aiohue-base], [aiohue-events]; a Bridge Pro dump of July
  2026, [aiohue-fixture]; [aiohue-pr599].
- Home Assistant: [ha-binary-sensor], [ha-sensor], [ha-helpers],
  [ha-entity], [ha-switch], [ha-fixture]; issues and pull requests
  [ha-71344], [ha-152937], [ha-153079], [ha-153935], [ha-160393],
  [ha-168297], [ha-177643], [ha-181632], [ha-182586]; [ha-disc-960].
- openHAB's Hue binding: [oh-readme], [oh-19838], and its recorded
  responses in [oh-fixtures]: [oh-area-config], [oh-candidate],
  [oh-convenience], [oh-security], [oh-grouped-motion],
  [oh-grouped-light-level], [oh-service-group], [oh-clip], [oh-event],
  [oh-device-power], [oh-swupdate].
- An OpenAPI description of CLIP v2 by the openhue project ([openhue]):
  [openhue-motion], [openhue-motion-put], [openhue-light-level],
  [openhue-temperature], [openhue-device-power], [openhue-device-put],
  [openhue-zigbee], [openhue-swupdate], [openhue-area-config].
- Philips Hue: [hue-ma-article], [hue-ma-compat], [hue-rn-bridge],
  [hue-rn-pro], [hue-rn-android]; the public news page of the developer
  portal, [hue-dev-news].
- Other: [hueblog-ma-setup], [hueblog-groups], [pcworld-ma],
  [deconz-sml001], [deconz-sml002], [deconz-sml003], [deconz-sml004],
  [z2m-sml002], [z2m-sml003], [iobroker-log], [oh-forum-5min],
  [hubitat-lux], [ha-forum-10s], [loxone2hue-7].
- This repository: [design.md](design.md),
  [bridge-compat-design.md](bridge-compat-design.md),
  [edge-cases-hue.md](edge-cases-hue.md),
  [smart-scenes-research.md](smart-scenes-research.md) (the style),
  [`bridge/stream.lua`](../src/hue_bridge/bridge/stream.lua),
  [`bridge/sse.lua`](../src/hue_bridge/bridge/sse.lua),
  [`bridge/lights.lua`](../src/hue_bridge/bridge/lights.lua),
  [`bridge/hue_model.lua`](../src/hue_bridge/bridge/hue_model.lua),
  [the fixtures](../tests/fixtures/hue_resources.lua).

[aiohue-models]: https://github.com/home-assistant-libs/aiohue/tree/main/aiohue/v2/models
[aiohue-motion]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/motion.py
[aiohue-feature]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/feature.py
[aiohue-light-level]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/light_level.py
[aiohue-temperature]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/temperature.py
[aiohue-device-power]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/device_power.py
[aiohue-device]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/device.py
[aiohue-resource]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/resource.py
[aiohue-clip]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/clip.py
[aiohue-grouped-motion]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/grouped_motion.py
[aiohue-grouped-light-level]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/grouped_light_level.py
[aiohue-service-group]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/service_group.py
[aiohue-area-config]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/motion_area_configuration.py
[aiohue-convenience]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/convenience_area_motion.py
[aiohue-security]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/models/security_area_motion.py
[aiohue-sensors]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/controllers/sensors.py
[aiohue-base]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/controllers/base.py
[aiohue-events]: https://github.com/home-assistant-libs/aiohue/blob/main/aiohue/v2/controllers/events.py
[aiohue-fixture]: https://github.com/home-assistant-libs/aiohue/blob/main/tests/fixtures/v2_resources.json
[aiohue-pr599]: https://github.com/home-assistant-libs/aiohue/pull/599
[ha-binary-sensor]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/v2/binary_sensor.py
[ha-sensor]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/v2/sensor.py
[ha-helpers]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/v2/helpers.py
[ha-entity]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/v2/entity.py
[ha-switch]: https://github.com/home-assistant/core/blob/dev/homeassistant/components/hue/switch.py
[ha-fixture]: https://github.com/home-assistant/core/blob/dev/tests/components/hue/fixtures/v2_resources.json
[ha-71344]: https://github.com/home-assistant/core/issues/71344
[ha-152937]: https://github.com/home-assistant/core/issues/152937
[ha-153079]: https://github.com/home-assistant/core/pull/153079
[ha-153935]: https://github.com/home-assistant/core/issues/153935
[ha-160393]: https://github.com/home-assistant/core/issues/160393
[ha-168297]: https://github.com/home-assistant/core/issues/168297
[ha-177643]: https://github.com/home-assistant/core/pull/177643
[ha-181632]: https://github.com/home-assistant/core/issues/181632
[ha-182586]: https://github.com/home-assistant/core/pull/182586
[ha-disc-960]: https://github.com/orgs/home-assistant/discussions/960
[oh-readme]: https://www.openhab.org/addons/bindings/hue/doc/readme_v2.html
[oh-19838]: https://github.com/openhab/openhab-addons/pull/19838
[oh-fixtures]: https://github.com/openhab/openhab-addons/tree/main/bundles/org.openhab.binding.hue/src/test/resources
[oh-area-config]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/motion_area_configuration.json
[oh-candidate]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/motion_area_candidate.json
[oh-convenience]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/convenience_area_motion.json
[oh-security]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/security_area_motion.json
[oh-grouped-motion]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/grouped_motion.json
[oh-grouped-light-level]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/grouped_light_level.json
[oh-service-group]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/service_group.json
[oh-clip]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/clip.json
[oh-event]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/event.json
[oh-device-power]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/device_power.json
[oh-swupdate]: https://github.com/openhab/openhab-addons/blob/main/bundles/org.openhab.binding.hue/src/test/resources/device_software_update.json
[openhue]: https://github.com/openhue/openhue-api
[openhue-motion]: https://github.com/openhue/openhue-api/blob/main/src/motion/schemas/MotionGet.yaml
[openhue-motion-put]: https://github.com/openhue/openhue-api/blob/main/src/motion/schemas/MotionPut.yaml
[openhue-light-level]: https://github.com/openhue/openhue-api/blob/main/src/light_level/schemas/LightLevelGet.yaml
[openhue-temperature]: https://github.com/openhue/openhue-api/blob/main/src/temperature/schemas/TemperatureGet.yaml
[openhue-device-power]: https://github.com/openhue/openhue-api/blob/main/src/device_power/schemas/DevicePowerGet.yaml
[openhue-device-put]: https://github.com/openhue/openhue-api/blob/main/src/device/schemas/DevicePut.yaml
[openhue-zigbee]: https://github.com/openhue/openhue-api/blob/main/src/zigbee_connectivity/schemas/ZigbeeConnectivityGet.yaml
[openhue-swupdate]: https://github.com/openhue/openhue-api/blob/main/src/device_software_update/schemas/DeviceSoftwareUpdateGet.yaml
[openhue-area-config]: https://github.com/openhue/openhue-api/blob/main/src/motion_area_configuration/schemas/MotionAreaConfigurationGet.yaml
[hue-ma-article]: https://www.philips-hue.com/en-us/support/article/motionawaretm--transform-your-hue-lights-into-motion-sensors/000011
[hue-ma-compat]: https://www.philips-hue.com/en-us/support/hue-motionaware
[hue-rn-bridge]: https://www.philips-hue.com/en-us/support/release-notes/bridge
[hue-rn-pro]: https://www.philips-hue.com/en-us/support/release-notes/bridge-pro
[hue-rn-android]: https://www.philips-hue.com/en-gb/support/release-notes/android
[hue-dev-news]: https://developers.meethue.com/
[hueblog-ma-setup]: https://hueblog.com/2025/09/23/step-by-step-guide-setting-up-hue-motionaware/
[hueblog-groups]: https://hueblog.com/2024/07/01/group-multiple-motion-sensors-directly-in-the-hue-app/
[pcworld-ma]: https://www.pcworld.com/article/2957900/philips-hue-turned-my-lights-into-motion-sensors-its-magical-but-imperfect.html
[deconz-sml001]: https://dresden-elektronik.github.io/deconz-rest-doc/devices/philips/sml001_motion_sensor/
[deconz-sml002]: https://dresden-elektronik.github.io/deconz-rest-doc/devices/philips/sml002_motion_sensor/
[deconz-sml003]: https://dresden-elektronik.github.io/deconz-rest-doc/devices/philips/sml003_motion_sensor/
[deconz-sml004]: https://dresden-elektronik.github.io/deconz-rest-doc/devices/philips/sml004_motion_sensor/
[z2m-sml002]: https://www.zigbee2mqtt.io/devices/9290019758.html
[z2m-sml003]: https://www.zigbee2mqtt.io/devices/9290030675.html
[iobroker-log]: https://forum.iobroker.net/post/1023874
[oh-forum-5min]: https://community.openhab.org/t/philips-hue-motion-sensor-in-oh2/18869?page=3
[hubitat-lux]: https://community.hubitat.com/t/hue-motion-sensor-illuminance-reporting-expectations/57525
[ha-forum-10s]: https://community.home-assistant.io/t/philips-hue-motion-sensor-usage/370604
[loxone2hue-7]: https://github.com/AES-Concepts-GmbH/loxone2hue/pull/7
