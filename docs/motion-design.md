# Motion sensors and MotionAware areas

Status: contract, 2026-10-26 (#268). Written before the code, from three
read-only research notes:
- [`motion-control4-research.md`](motion-control4-research.md) (C4R): how Control4 models a motion sensor.
- [`motion-hue-research.md`](motion-hue-research.md) (HR): the Hue resources and events.
- [`edge-cases-motion.md`](edge-cases-motion.md) (EC): the lifecycle policy, row by row.

Where this file is silent, EC decides the behaviour, C4R the Control4 side
and HR the Hue side. Where they disagree, this file wins.

The feature ships as the prerelease `v1.1-beta.1`
([`prerelease-design.md`](prerelease-design.md)) to a tester who owns
sensors. The owner owns none. The house has a Hue Bridge Pro and no sensors.

## 1. Decisions

| # | Question | Decision |
| --- | --- | --- |
| D1 | How the device appears | A new driver `hue_motion.c4z` **is** the sensor: its only proxy is `contactsingle_motionsensor` (C4R §1.3, choice A). Motion is `OPENED`, no motion is `CLOSED`. No `<capabilities>`. The proxy can never change for this file name. |
| D2 | One driver or two (C4R Q5) | **One** driver with two kinds, `sensor` and `area`, as `hue_light` has lights and groups. |
| D3 | A failure while motion shows (C4R Q7, EC Q1) | Keep the contact as it is. Set Online false and say in Status that the motion is not current. Only a deliberate end sends `CLOSED`, once (EC §6). |
| D4 | Re-link across kinds (EC Q2) | **No** in beta 1: a sensor device re-links to a sensor, an area device to an area. |
| D5 | Attention for an unreachable sensor or degraded area (EC Q3) | After 1 hour. A battery at "low" or "critical" is listed at once. |
| D6 | Switched off or paused in the Hue app (EC Q4) | Listed in Attention. |
| D7 | Writes to Hue (C4R Q9, EC Q5) | **None.** The driver never changes anything on the Hue side. |
| D8 | A motion episode missed while the stream was down (EC Q6) | Logged only, never replayed. |
| D9 | Stuck motion (EC Q7) | One bounded GET of that one motion resource when motion has shown for 5 minutes with no news. It is the only polling. |
| D10 | Occupancy hold time (C4R Q6) | An **Occupancy Hold Time (s)** property on the device, 0 to 3600, default 0. Hue's "no motion" is held that long before `CLOSED` is sent. New motion cancels the wait. |
| D11 | History (C4R Q8) | No `C4:RecordHistory` in beta 1. Motion history is the proxy's own. |
| D12 | Bridge connection (C4R Q10) | The existing provider binding 1, `HUE_BRIDGE`. No new connection on the bridge. |
| D13 | Room, zone and home motion (`grouped_motion`), sensor groups, cameras | Not in beta 1. The diagnostics count them. |
| D14 | `security_area_motion` | Read only, and only as a source of an area's motion (EC A9). No alarm behaviour. |
| D15 | Bulk add | None in beta 1. Devices come one at a time from **Add Motion Sensor** and **Add Motion Area**. Superseded in part (2026-10-27, #319): the bridge action **Add All New Motion Sensors** (`motion:add_all_new`) adds every sensor without a device into the Control4 room its Hue room maps to, one at a time, by the rule of Import All New Lights (EC §7): from the cached records, never from an event, idempotent by rid. Skipped and listed: sensors in no Hue room or an unmapped one, those deleted in Composer, and those that look like the replacement of a device (the re-link hint, EC S4 and S6), so Re-link keeps that device. Areas stay one at a time (A15). |
| D16 | Temperature | A provider connection of class `TEMPERATURE_VALUE` on sensor devices (C4R §3.1), plus the device's own rows and variables. |

## 2. The motion device: `src/hue_motion/`

### 2.1 `driver.xml`

- **Proxy:** `contactsingle_motionsensor`, `proxybindingid` 5001, default name "Hue Motion Sensor".
- **Connections:**
  - 5001: type 2, class `CONTACT_SENSOR`, the proxy binding.
  - 1: consumer, class `HUE_BRIDGE`, "Hue Bridge", as in `hue_light`.
  - 2: provider, class `TEMPERATURE_VALUE`, "Temperature". An area never sends on it.
- **Category and icons:** `<composer_categories>` Sensors. `<states>` and the icons follow the stock motion-sensor pattern in C4R §1.3.
- **No `<capabilities>`.**
- The `<version>` is set by `tools/build.sh`. Manufacturer, model and documentation follow `hue_light`.

### 2.2 Properties, in this order

| Property | Kind | Notes |
| --- | --- | --- |
| Driver Version | read-only | as the other drivers |
| Status | read-only | EC §6 texts |
| Online | read-only | "Yes" / "No" |
| Enabled | read-only | "Yes" / "Switched off in the Hue app" / "Paused in the Hue app" |
| Kind | read-only | "Motion sensor" / "MotionAware area" |
| Hue Name | read-only | |
| Hue Room | read-only | |
| Model | read-only | for example "Hue motion sensor (SML003)"; for an area, "MotionAware area" |
| Hue Motion | read-only | Hue's own state before the hold time: "Motion" / "No motion" / "Unknown", with the bridge's change time |
| Light Level | read-only | "123 lux", "Dark", or empty; sensors only |
| Temperature | read-only | "21.5 °C (70.7 °F)"; sensors only |
| Battery | read-only | "85 % (normal)"; sensors only |
| Occupancy Hold Time (s) | writable RANGED_INTEGER 0–3600, default 0 | D10 |
| Last Action | read-only | |
| Debug Mode | writable | as the other drivers |

A row that does not apply to the kind is hidden with `C4:SetPropertyAttribs`, as `hue_light` hides its colour rows.

### 2.3 Variables, created in `OnDriverInit` in this order (ids are fixed forever)

| # | Name | Type | Sensor | Area |
| --- | --- | --- | --- | --- |
| 1 | Online | BOOL | yes | yes |
| 2 | Enabled | BOOL | yes | yes |
| 3 | Light Level | INT (lux, rounded) | yes | stays 0 |
| 4 | Temperature C | NUMBER | yes | stays 0 |
| 5 | Temperature F | NUMBER | yes | stays 0 |
| 6 | Battery Level | INT (%) | yes | stays 0 |
| 7 | Battery Low | BOOL | yes | false |

A variable is never set to an invented value. It keeps its last value when the reading is lost (EC §6).

### 2.4 Events (fixed ids; never renumbered or removed)

| Id | Name | Fires |
| --- | --- | --- |
| 1 | Light Level Changed | the lux moved by at least max(5 lux, 10 %) since the last firing |
| 2 | Temperature Changed | the temperature moved by at least 0.5 °C since the last firing |
| 3 | Battery Low | `battery_state` became low or critical |
| 4 | Battery Normal | `battery_state` became normal again |
| 5 | Offline | Online true to false |
| 6 | Online | Online false to true |
| 7 | Switched Off In Hue | Enabled true to false |
| 8 | Switched On In Hue | Enabled false to true |

Each `<description>` carries `NAME`. Motion events are the proxy's own.

### 2.5 Conditionals

BOOL Online, BOOL Enabled, BOOL Battery Low, NUMBER Light Level (0–100000), NUMBER Temperature C (−40 to 60), NUMBER Battery Level (0–100).

### 2.6 Actions

- **Refresh From Bridge:** sends `HUE_MOTION_HELLO`.
- **Test: Motion** and **Test: No Motion:** send `OPENED` / `CLOSED` to the proxy, saying in Last Action that it is a test. They are for checking programming without a sensor, and are kept in the release build.

### 2.7 Behaviour

- **The proxy.** Send `C4:SendToProxy(5001, "OPENED"|"CLOSED"|"STATE_OPENED"|"STATE_CLOSED", {}, "NOTIFY")`, never before `OnDriverLateInit`.
  - The first known state after a start is sent as `STATE_*`, unless it differs from the last state persisted (`PersistData`). Then it is `OPENED`/`CLOSED`, so programming catches up (EC rule 3, R4).
  - Later, only a real change sends `OPENED`/`CLOSED`.
  - Answer `GET_STATE` with `STATE_*` once the state is known. Ignore it until then.
- **Hold time:**
  - Hue "motion" sends `OPENED` at once and cancels any pending close.
  - Hue "no motion" starts the hold timer (`C4:SetTimer`). When it ends, `CLOSED` is sent.
  - A hold time of 0 closes at once.
  - The hold is never applied to a deliberate end.
- **Deliberate end** (`HUE_MOTION_STATE` with `ended` set): `CLOSED` once if the state shows motion, at once, ignoring the hold.
- **The temperature output** (C4R §3.1):
  - On a reading, and on binding 2 becoming bound: `VALUE_CHANGED` with `CELSIUS`, `FAHRENHEIT` and `TIMESTAMP`.
  - When the reading is lost or the sensor is offline: `VALUE_UNAVAILABLE`.
  - Answer `GET_SENSOR_VALUE` with the last value.
  - Only messages C4R verified, with the parameter names it cites.
- **Binding.** `OnBindingChanged` on binding 1 sends `HUE_MOTION_HELLO` when bound. When unbound it is a deliberate end ("Not bound to a Hue Bridge").
- **Reuse.** Shared code may be reused from `src/common/` (`dispatch`, `log`, and from `device.lua` whatever applies, such as the binding re-check), read-only. If a change to a common module is needed, the hand-back says so.

## 3. Messages between the bridge and a motion device

These go through `C4:SendToDevice`, with string values, `rid` in every message, and the 5th argument as in `device_send`.

**Bridge → device**

| Command | Params |
| --- | --- |
| `HUE_MOTION_CONFIGURE` | `rid`, `kind` ("sensor"/"area"), `name`, `model`, `hue_room`, `id_v1`, `gone` ("true"/"false"), `has_light_level`, `has_temperature`, `has_battery` |
| `HUE_MOTION_STATE` | `rid`, `reason` ("event"/"resync"/"hello"/"check"), and any of: `motion` ("true"/"false"), `motion_changed` (the bridge's ISO time), `online`, `enabled`, `status` (the EC §6 text the bridge chose, or absent for "fine"), `lux` (decimal, "0" means dark), `temperature` (°C, decimal), `battery_level`, `battery_state` ("normal"/"low"/"critical"), `ended` ("deleted"/"off"/"paused"/"forgotten"; a deliberate end) |
| `HUE_MOTION_FORGOTTEN` | `rid`, as `HUE_SCENE_FORGOTTEN` |

**Device → bridge** (no `HUE_MOTION_FORGET`: forgetting is the bridge's Forget Motion Device action only)

| Command | Params |
| --- | --- |
| `HUE_MOTION_HELLO` | `rid` ("" if unknown), `device_id`, `name`, `kind`, `model` |
| `HUE_MOTION_GOODBYE` | as `HUE_SCENE_GOODBYE` |

The bridge decides `status` and `ended`, and the device shows them. Each
`HUE_MOTION_STATE` that carries `motion` also carries `motion_changed`, and
the bridge never sends a reading older than the last one it sent (EC
rule 5).

## 4. The bridge

### 4.1 `bridge/motion_model.lua` (new, pure)

This module parses resources into records. It does no I/O.

- **`sensors(devices, services_by_type)`:** one record per device that owns a `motion` service. Fields: `rid` (the device rid), `name`, `model_id`, `product_name`, `room` (via the lights' groups), `id_v1`, and the service rids `motion`, `light_level`, `temperature`, `device_power`, `zigbee`.
- **`areas(configs, services_by_type)`:** one record per `motion_area_configuration`. Fields: `rid`, `name`, `group` {rtype, rid}, `enabled`, `health`, participant count, and the service rids `convenience`, `security`.
- **`reading(item)`:** for any of `motion`, `light_level`, `temperature`, `device_power`, `zigbee_connectivity`, `convenience_area_motion`, `security_area_motion`, `motion_area_configuration`, the normalised fields:
  - `motion`, `changed`, `valid`, `enabled`;
  - `lux = 10^((v−1)/10000)`, rounded, with v = 0 meaning dark;
  - `temperature`;
  - `battery_level`, `battery_state`;
  - `status`.
  
  Missing fields stay nil. Deprecated fields are used only when the new ones are missing (HR §1.3–§1.7).
- **`area_motion(record, readings)`:** an area's motion is the reading of whichever enabled service changed last (EC rule 7, HR §2.5).
  Superseded on 2026-10-26 (#288): both services report the same walk a few seconds apart, so following the last change flapped the contact on the house. An area now shows motion while any enabled service reports it, and no motion only when all report none.

### 4.2 `bridge/motion.lua` (new): the fourth registry owner, on `owner.lua`

- **Its constants:**
  - `TAG = "motion"`, `DEVICE_DRIVER = "hue_motion.c4z"`, `BINDING = 1`, `BINDING_CLASS = "HUE_BRIDGE"`.
  - `MESSAGES` = the `HUE_MOTION_*` names.
  - Persisted under `hue_motion` and `hue_motion_tombstones`, through the registry exactly as the scenes persist theirs.
  - Its words: "motion sensor" / "motion area".
- **Its public surface mirrors `bridge/zone_lights.lua`'s.** These names are what `driver.lua` will call:
  - `new(ctx)`, `load`, `configure_all`, `reconcile`, `resync(cb)`, `on_container(container)`;
  - `hello(params)`, `goodbye(params)`, `forget_request(params)`, `on_binding_changed(...)`;
  - `attention_items()`, `device_ids()`, `registered_rids()`, `entry(rid)`;
  - `add(rid, room_device_id, cb)`, `relink(device_id, rid)`, `forget(device_id)`;
  - `link_devices(skip_ids)`, `adopt_hue_names()`, `accept_names()`;
  - the pickers `picker_sensors()`, `picker_areas()`, `picker_relink_devices()`, `picker_forget_devices()`;
  - `summary()` (one string, the row) and `list_items()` (the drop-down), as the other modules give `show_module_list`. A bridge without the area types says "MotionAware not supported by this bridge" in the summary.
- **Where the data comes from.** Sensor devices come from the lights' device cache (EC §0.3: `lights.devices`, `lights.groups`), as the zone lights read `lights.models`. `resync(cb)` GETs `motion`, `light_level`, `temperature`, `device_power`, `zigbee_connectivity`, `motion_area_configuration`, `convenience_area_motion` and `security_area_motion`.
  - One GET at a time, after the zone lights in the resync chain.
  - A 404 on the area types means "not supported by this bridge" (EC §0.1). It never means "areas gone".
  - A failed GET never marks anything gone (EC B-rows).
- **Every EC row the decisions above keep:**
  - the §6 table;
  - Attention per D5 and D6;
  - Re-link per D4;
  - Forget as the scenes' rule (EC §8 item 9);
  - the name hint needing the same Hue room (EC §8 item 8);
  - the stuck-motion check of D9, its timer started only while some device shows motion.

### 4.3 `bridge/motion_diag.lua` (new): Log Motion Diagnostics

A bridge action, **Log Motion Diagnostics**, available in release builds. It runs one pass and then a capture:
- **The pass:**
  - GETs, one at a time, every type in HR §6.1, the area and candidate types included.
  - Logs with `log.always`, line by line per HR §6.2 and §6.5, with HR §6.4's redaction: names become "name#1", ids become their first 4 characters plus "…", and MACs and bridge ids are removed.
  - Logs the type counts, including cameras, contact sensors and grouped motion.
- **The capture:** for the next 10 minutes, every stream item of those types is logged the same way, redacted, at most 200 lines.
- **Last Action:** "Motion diagnostics: N sensors, M areas logged; capturing events until 14:12. Copy the Lua output into the Beta feedback issue."
- **Interface:** `motion_diag.new(ctx)`, `:run(cb)`, `:on_container(container)`, `:capturing()`.

### 4.4 `driver.lua` and `driver.xml` (coordinator)

- **Actions:**
  - **Add Motion Sensor:** sensor picker plus Room.
  - **Add Motion Area:** area picker plus Room.
  - **Re-link Motion Device:** device picker plus target.
  - **Forget Motion Device.**
  - **Log Motion Diagnostics.**
- **Properties:** one DYNAMIC_LIST row, **Motion Sensors**, after Zone Lights, for sensors and areas together.
- **Shared actions:** the `HUE_MOTION_*` dispatch. Link Devices, Adopt Hue Names, Accept Names As They Are and the Attention list include the motion module.
- **Resync chain:** lights → scenes → zone lights → motion.
- **Stream fan-out:** `on_container` calls `motion` and then `motion_diag`.

## 5. Tests

- **Fixtures:** `tests/fixtures/hue_motion.lua` holds HR §5 with invented ids: an indoor SML003, an outdoor SML002, a MotionAware area, their grouped resources, and a set of stream containers.
- **Specs:**
  - `motion_model_spec`;
  - `motion_spec` (every EC row it covers, by row id in the test names);
  - `motion_diag_spec` (redaction above all: no name, id or MAC survives);
  - `motion_driver_spec` (the proxy messages, the hold time, `STATE_*` at start, the temperature output, variables, events, the deliberate end).
- **`motion_roundtrip_spec`** (coordinator): the bridge and a device through the fake runtime.
- **The fake runtime** (`tests/helpers/fake_c4.lua`) grows only by addition.

## 6. Files and owners

| Files | Owner |
| --- | --- |
| `src/hue_bridge/bridge/motion_model.lua`, `src/hue_bridge/bridge/motion.lua`, `tests/fixtures/hue_motion.lua`, `tests/spec/motion_model_spec.lua`, `tests/spec/motion_spec.lua` | agent **bridge** |
| `src/hue_motion/driver.lua`, `src/hue_motion/driver.xml`, `src/hue_motion/www/` except `documentation.html`, `tests/spec/motion_driver_spec.lua`, `tests/helpers/fake_c4.lua` (additions only), `tests/spec/drivers_spec.lua` (the new driver's checks), `tools/make_icons.py` (if icons are generated) | agent **device** |
| `src/hue_bridge/bridge/motion_diag.lua`, `tests/spec/motion_diag_spec.lua` | agent **diagnostics** |
| `src/hue_motion/www/documentation.html`, the "Motion sensors" chapter of `src/hue_bridge/www/documentation.html`, `docs/composer-checklist.md` (a motion section, including the house smoke test of EC §10 and C4R §8 probes that need no sensor) | agent **docs** |
| `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml`, `tests/spec/motion_roundtrip_spec.lua`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `SECURITY.md`, `docs/README.md`, `docs/status.md`, `docs/release-checklist.md`, `.github/release-notes.md`, `.github/prerelease-notes.md`, `tools/changelog.py` (intro text) | coordinator |

## 7. Done

- `tools/check.sh` passes and `tools/build.sh` builds four packages.
- On the house (the smoke test, without sensors):
  - the update needs no reboot;
  - a motion device can be added from Composer's driver search;
  - its proxy, connections and programming look as C4R describes;
  - **Test: Motion** and **Test: No Motion** fire the stock events;
  - Log Motion Diagnostics runs;
  - nothing regresses.
- `v1.1-beta.1` is released, and the tester's first round answers HR §7.1.
