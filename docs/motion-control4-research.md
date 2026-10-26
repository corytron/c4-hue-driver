# Hue motion sensors and MotionAware areas as Control4 motion sensors: research for #268

**Status (2026-10-26): research for issue #268 (1.1 beta 1), read-only;
nothing here is approved or built.** The contract will be
`docs/motion-design.md`. This note covers the Control4 side only: how a Hue
motion sensor and a Hue Bridge Pro MotionAware area should appear in
Composer, on Navigators and in programming, on OS 3.x (the house runs 3.4.2)
and OS 4.x. Hue's resources and the lifecycle edge cases are the other
research notes of #268; the few Hue facts used here are marked [assumed] and
belong to them.

Snap One documents and drivers are paraphrased: only interface names
(commands, connection classes, property and event names) appear as written.
This is not legal advice.

Markers:

- **[verified: API x/_y]** = `~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`;
  **[verified: FUND x/_y]** = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/<x>/<_y>.md`;
  **[verified: LV2 x/_y]** = `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2/source/includes/<x>/<_y>.md`.
- **[verified: PP x/_y]** = Snap One's proxy and protocol guide,
  https://github.com/snap-one/docs-driverworks-proxyprotocol,
  `source/includes/<x>/<_y>.md` (read from a clone; the same text is in
  `docs-driverworks-proxyprotocol-contact` and `-tstat`).
- **[verified: XML file]** = DriverWorks XML reference,
  https://github.com/snap-one/docs-driverworks-xml, `source/includes/15_common_xml/<file>`.
- **[verified: TPL path]** = Snap One's template code,
  https://github.com/snap-one/drivers-template-code-public, `<path>`.
- **[verified: LEAP]** = Snap One's "Lutron LEAP Occupancy Sensor" (version 6,
  2024-12-30) and "Lutron LEAP Area Occupancy Sensor" (version 3, 2024-12-18),
  public downloads https://drivers.control4.com/lutron_leap_occupancy_sensor.c4z
  and https://drivers.control4.com/lutron_leap_area_occupancy_sensor.c4z:
  their `driver.xml`, `www/documentation.md` and its screenshots (the Lua is
  encrypted).
- **[verified: KNX]** = Snap One's "KNX Movement Sensor" (version 1, 2018),
  https://drivers.control4.com/knx_movement_sensor.c4z: `driver.xml` with its
  documentation, and its unencrypted `driver.lua`.
- **[verified: TD]** = Snap One's "Temperature Display Driver (OS 2.10+)"
  (version 13, 2017), https://drivers.control4.com/TemperatureDisplay210.c4z:
  `driver.xml`, `device_specific.lua`, `common/c4_utils.lua`.
- **[verified: DB]** = Control4's public driver database,
  https://drivers.control4.com/solr/drivers/browse (by primary proxy
  `contactsingle_motionsensor`; by "occupancy"; by "Temperature Display").
- **[verified: C4 docs]** = Control4's public documentation: the user guide's
  `locks.htm` and `basics-security.htm`, the OS 3 release notes (rev AC), the
  OS 3.4.0 release notes (rev AQ), the Z2IO installation guide (rev E); URLs
  at the end.
- **[community: name]** = third-party drivers, integrations and posts (URLs at
  the end). **[house]** = `docs/status.md`, `docs/design.md`,
  `docs/edge-cases-control4.md`.
- **[assumed]** = inference or undocumented; the probes are in §8.

## Answer in brief

1. Control4 has no motion proxy in the AV sense: a motion sensor is a
   **contact** device whose state is Open or Closed, with stock icons,
   events, conditionals, variables and history [verified: PP 111/_1].
2. A DriverWorks driver **can be that sensor itself**. Snap One's own child
   drivers for Lutron occupancy groups, Lutron areas and KNX movement sensors
   name `contactsingle_motionsensor` as their proxy, on a type-2 connection
   of class `CONTACT_SENSOR`, and drive it with four notifications [verified:
   LEAP, KNX, PP 112]. That is our case exactly: a bridge driver importing
   child devices. The Lutron *area* driver is the closest Control4 analogue
   of a MotionAware area.
3. **Motion is `OPENED`, no motion is `CLOSED`** [verified: KNX `driver.lua`;
   six third-party sources agree and one disagrees, §4.1].
4. With no binding to make, the owner then gets a stock motion-sensor
   device: its icon, the "senses motion" and "stops sensing motion" events,
   the "is sensing motion" conditionals and loops, the `ContactState`,
   `StateVerified` and `LastActionTime` variables, the proxy's Invert and
   Debounce settings, a place under Security → Locks & Sensors with history,
   and per-device notifications on OS 3.4+ [verified: LEAP, KNX, C4 docs;
   that the proxy writes the history itself: assumed].
5. **Temperature** leaves on a provider connection of class
   `TEMPERATURE_VALUE`, the thermostat proxy's documented value class. Snap
   One's Temperature Display driver shows it on Navigators, and Control4's
   C4-THERM thermostat takes it as a remote sensor [verified: PP 97, TD, C4
   docs Z2IO guide; what C4-THERM requires: community]. **Light level,
   battery and online state** become the driver's own properties,
   variables, conditionals and events, which is what Snap One's KNX driver
   does with its brightness value [verified: KNX]. No documented Control4
   class carries light level or battery.
6. One new `hue_motion.c4z` with **one proxy**, serving sensors and
   MotionAware areas (or two drivers in the Lutron style; that choice is the
   owner's). It binds to the bridge's existing `HUE_BRIDGE` provider as
   `hue_light` and `hue_scene` do, and devices are created only from bridge
   actions with `C4:AddDevice` + `C4:Bind` [verified: API 9/_0.1; house]. The
   proxy can never be changed for that file name [verified: FUND 14/_2].
7. No `<capabilities>` anywhere: the contact proxy takes none, and Snap One's
   drivers declare none. Beta 1 should therefore need no controller reboot
   [verified: LEAP, KNX; the reboot rule: house; that a new driver adds no
   capability: assumed, probe H1].
8. Clear delay: Control4 keeps the hold time in the sensor and sets it from
   Composer (Control4's own wireless sensor, Axxess, KNX), or uses a timer in
   programming. Hue's hold time cannot be set over CLIP v2 [assumed]. The
   recommendation is an "Occupancy Hold Time" property that defaults to 0,
   reporting exactly what Hue reports; that decision is the owner's (§9).

## 1. Proxies and connections

### 1.1 How Control4 models contacts and motion

| Piece | What it is | Source |
| --- | --- | --- |
| Stock contact devices | Composer ships one combo driver per contact kind: Motion Sensor, Door and Window Contact, Doorbell, Driveway, Garage Door, Gate, Glass Break, Heat, Humidity, IR Beam, Pressure, Smoke, CO, Water and a generic Contact (files `contactsingle_<kind>_c4.c4i`). Each declares `<control>control4_contactsingle</control>`, its own file name as proxy, two `<states>` (open and closed icons) and one consumer control connection `Contact Sensor` of class `CONTACT_SENSOR`. | [verified: PP 111/_1]; file names [community: Berto `driver.xml`, hass-control4] |
| Contact providers | Whatever drives a contact is a provider of class `CONTACT_SENSOR`: a controller's contact input, a security panel zone, a driver output. The SDK's example is a provider connection named after a security zone, and `C4:AddDynamicBinding` creates such zones at run time. | [verified: FUND 11/_2, API 22/_1] |
| Contact notifications | Provider to contact: `OPENED`, `CLOSED`, `STATE_OPENED`, `STATE_CLOSED`, no parameters, sent as NOTIFY with an empty table. | [verified: PP 112/_1 to _4; API 25/_6 example] |
| `contactsingle_motionsensor` as a proxy | A DriverWorks protocol driver can name it as its proxy. Director loads the matching proxy driver and makes the internal binding when the driver is added. Drivers in Control4's database with this primary proxy: Nyce ZigBee sensors (2012 to 2014), Lutron RadioRA2 and HomeWorks QS Powr Savr, Snap One's KNX Movement Sensor (2018), Lutron LEAP Occupancy Sensor and Area Occupancy Sensor (2024). | [verified: DB, LEAP, KNX; proxy loading: FUND 14/_2]; that the loaded file is `contactsingle_motionsensor.c4i` [assumed: the file is in Composer's virtual drivers, community: Berto list] |
| Security panel zones | The other model: a security proxy reports zones with a sensor type (5 = motion). The type only chooses icons. | [verified: FUND 27/_60, PP 93.5/_1] |

The stand-alone stock device's proxy is `contactsingle_motionsensor_c4`,
while the DriverWorks drivers above use `contactsingle_motionsensor`. Tools
that read Director may know only one of the two names: hass-control4 maps
only the `_c4` one to a motion sensor [community: hass-control4
`binary_sensor.py`].

### 1.2 What Snap One and others ship

| Driver (year) | Shape | What the owner does | Extras | Source |
| --- | --- | --- | --- | --- |
| Lutron LEAP Occupancy Sensor and Area Occupancy Sensor (Snap One, 2019 to 2024) | Protocol driver; proxy `contactsingle_motionsensor` on 5001 (type 2, provider, `CONTACT_SENSOR`); a consumer link to the Lutron processor; Composer category Sensors; the stock motion icons as `<states>` 1 (open) and 2 (closed); no events or conditionals of its own | One processor action adds the devices with their connections; nothing to bind | Properties HRef and Occupancy State (Occupied, Unoccupied, Unknown); a "Get Status" command | [verified: LEAP] |
| KNX Movement Sensor (Snap One, 2018) | Protocol driver; same proxy (binding 5000); a consumer link to the KNX network driver | Bind one link | Its own events (sensor enabled, disabled), variables `Brightness` (NUMBER) and `Movement Detection Enabled` (BOOL), commands (enable, disable, set switch-off delay, trigger motion or no motion) | [verified: KNX] |
| Control4 Wireless Motion Sensor (ZigBee, made by Card Access) | ZigBee device driver | — | Variables for motion, light level, battery and day/night; an occupancy hold time of 5 s to 60 min set in Composer; Battery Low and Battery Critical events | [community: Control4 data sheet and the ZCA-WMS10 manual, through search summaries] |
| Axxess Motion Sensor AV (2026) | Combo with its own proxy; provider outputs Motion (`CONTACT_SENSOR`), Temperature (`TEMPERATURE_VALUE`), Humidity (`HUMIDITY_VALUE`), Ambient Light (`AMBIENT_LIGHT_LINK`) | Add a stock Motion Sensor and bind it to Motion | Motion Detected and Ended, Battery is Low and Critical, Device Stops and Starts Communicating; Occupancy Hold Time; day and night mode | [community: `axxess_motionsensor.c4z` from the driver database] |
| Unilogiq Hue Sensor (2019) | Combo; outputs Motion and Occupancy (`CONTACT_SENSOR`) and Temperature (`TEMPERATURE_VALUE`) | Add a stock Motion Sensor per sensor and bind it; add the Temperature Display driver for Navigators | Occupancy hold in minutes (default 3) on the second contact | [community: Unilogiq zip, `driver.xml` and PDF] |
| Zigbee2MQTT Hue Motion Sensor (2025, AGPL) | Combo; outputs `CONTACT_SENSOR` (occupancy sends `OPENED`) and `TEMPERATURE_VALUE` | Bind a stock Motion Sensor | Its own events and conditionals for every value | [community: SolutionsLogicielsBreton/Control4-Zigbee2MQTT] |
| ESPHome (finitelabs, AGPL) | A dynamic `CONTACT_SENSOR` binding per binary sensor; `TEMPERATURE_VALUE` and `HUMIDITY_VALUE` outputs since 2026-07 | Bind a stock contact device | — | [community: finitelabs/control4-esphome] |
| Whistle Projects Hue Security Pack (commercial) | Its own motion driver | — | Events for motion, light level, temperature, battery, Zigbee status; Bridge Pro supported | [community: DriverCentral listing] |

The pattern: **when Snap One imports devices from a bridge or a bus
(Lutron, KNX), its driver *is* the motion sensor. Third-party ZigBee and IP
vendors instead provide an output and leave the owner to add the stock
device.**

### 1.3 Our driver as the sensor

The shape the Lutron and KNX drivers share, described in our own words:

- `<proxies>`: one proxy, `contactsingle_motionsensor`, with
  `proxybindingid="5001"` and a `name` that becomes the default device name
  [verified: FUND 8/_1, FUND 8/_2, XML `_32-proxy.md`]. LEAP writes the
  attribute as `proxy="5001"` and KNX uses 5000; both values are in the
  proxy range 5000 to 5999 [verified: FUND 11/_1].
- Connection 5001: type 2 (proxy), not a consumer, class `CONTACT_SENSOR`.
  Proxy connections are hidden in Composer by default [verified: FUND 11/_1].
- Our consumer connection 1 of class `HUE_BRIDGE`, as in `hue_light` and
  `hue_scene` [house], and a provider control connection of class
  `TEMPERATURE_VALUE` (§3.1).
- `<states>` with id 1 (open) and id 2 (closed), and `<small>`/`<large>`
  set to the stock closed-state motion icon [verified: LEAP; PP 111/_1
  shows the same states element on the stock drivers].
- `<composer_categories>` with `Sensors` [verified: XML
  `_100-composercatagories.md`; LEAP, KNX].
- No `<capabilities>` and no `<combo>` [verified: LEAP, KNX].

Composer then shows the device with the proxy's own property page (Invert
Sensor; Enable Debounce Timer with Debounce Time (ms), default 100; State,
Open or Closed; Verified, Yes or No). The driver's own properties, actions,
documentation and Lua appear under Advanced Properties [verified: LEAP
screenshots `Image1.png`, `Image2.png`]. Verified reads No until the first
state reaches the proxy [verified: LEAP documentation].

### 1.4 The choices and what each costs the owner in Composer

| Choice | Per sensor in Composer | Devices per sensor | Programming | Lifecycle |
| --- | --- | --- | --- | --- |
| **A. Our driver is the sensor** (`contactsingle_motionsensor` proxy) | One bridge action (pick the sensor, pick the room) or one click for all; no bindings | 1 | Stock motion programming plus our extras on the same device | One device; rename, move and delete work as for a Hue Light |
| B. Our device with an output; the owner adds a stock Motion Sensor | The bridge action, then: add Motion Sensor from the Sensors category to the room, rename it, and in Connections drag its Contact Sensor input onto our output (about 6 to 8 clicks, our estimate) | 2 | Stock programming on the stock device, extras on ours | Two devices to keep in step (names, rooms, deletes) |
| B'. As B, with the bridge adding and binding the stock device (`C4:AddDevice("contactsingle_motionsensor_c4.c4i")` + `C4:Bind`) | 0 if it works | 2 | As B | As B; that AddDevice accepts a stock .c4i is documented in general [verified: API 9/_0.1] and untested here [assumed] |
| C. A combo with its own proxy and custom events only | One action | 1 | Custom events only: no stock icon, state, history or Locks & Sensors entry | — |
| D. A security panel proxy with zones | One panel, and each zone still needs a stock Motion Sensor bound to it to appear as a sensor | 1 + N | Panel programming | Arming semantics; the security area is out of scope for this beta |

Optional for A or B: Navigator temperature through Snap One's Temperature
Display. Add it from the online database, put it in the room, and bind its
Temperature In to our Temperature output (about 4 or 5 clicks, our estimate) [verified:
TD connections; C4 docs, Z2IO guide].

### 1.5 The protocol on the proxy binding

| Message | Direction | Meaning and use | Source |
| --- | --- | --- | --- |
| `OPENED` | driver to proxy | The contact opened. For a motion sensor that is motion, and it fires "senses motion" | [verified: PP 112/_2; KNX] |
| `CLOSED` | driver to proxy | The contact closed: no motion; fires "stops sensing motion" | [verified: PP 112/_1; KNX] |
| `STATE_OPENED`, `STATE_CLOSED` | driver to proxy | The contact is (still) in that state. Snap One's sensor template uses these to report the first known state, and to answer `GET_STATE`, without firing events; it sends `OPENED`/`CLOSED` only on a change | [verified: PP 112/_3, _4; TPL `c4hooks/c4hook_sensor.lua`]; that the proxy fires no event on them and sets Verified [assumed, probe T6] |
| `GET_STATE` | proxy to driver | The proxy asks for the state. Answer with `STATE_*`, or ignore it while the state is unknown | [verified: TPL `c4hooks/c4hook_sensor.lua`]; when the proxy sends it [assumed] |

All four notifications go out as `C4:SendToProxy(5001, name, {}, "NOTIFY")`
[verified: API 25/_6; TPL `common/c4_notify.lua`], never before
`OnDriverLateInit` [verified: API 22/_25.2]. Control4 tracks a sensor's state
changes whatever caused them, so changes made in the Hue app or by the sensor
itself are proper notifications [verified: PP 116/_1].

## 2. Programming

### 2.1 What the proxy brings (the stock motion programming)

| Kind | Items | Source |
| --- | --- | --- |
| Events | "When *NAME* senses motion" (on `OPENED`), "When *NAME* stops sensing motion" (on `CLOSED`) | [verified: KNX documentation; LEAP documentation] |
| Conditionals and loops | *NAME* is sensing motion; is not sensing motion; State is Verified | [verified: LEAP documentation]; loops follow from conditionals [verified: FUND 10/_1] |
| Variables | `ContactState` (BOOL; true means closed, so true means no motion), `StateVerified` (BOOL), `LastActionTime` | [verified: KNX documentation names the first two, LEAP lists all three]; the polarity [community: hass-control4] |
| Properties | Invert Sensor, Enable Debounce Timer, Debounce Time (ms), State, Verified | [verified: LEAP `Image1.png`] |
| Navigators | Security → Locks & Sensors lists the sensors of the room or the home, with event histories for "movement detectors"; sensors can be favourites under Comfort and Security; OS 3.4.0 lets users switch notifications on per device and per event, and its push notifications deep-link to Locks & Sensors | [verified: C4 docs `basics-security.htm`, `locks.htm`, OS 3 and OS 3.4.0 release notes] |
| History entries | Written by the proxy for every state change | [assumed: stock sensors wired to contact inputs have no driver code, yet the app keeps their history] |

### 2.2 What our driver adds

Snap One's KNX driver declares its own events, variables, commands and
actions next to the contact proxy and fires them with `C4:FireEventByID`
[verified: KNX]. LEAP adds none. Proposal for the contract:

| Kind | Sensor | Area | Precedent |
| --- | --- | --- | --- |
| Properties (read-only unless noted) | Driver Version, Debug Mode (writable), Status, Online, Hue Name, Hue Room, Model, Hue Sensor ID, Hue Motion (unheld state), Light Level ("123 lux"), Temperature (project scale), Battery Level (%), Battery State (Normal, Low, Critical), Last Action, Occupancy Hold Time (s, writable, §4.2) | the same without Light Level, Temperature and Battery; Enabled | Our light and scene drivers; KNX; LEAP Occupancy State |
| Variables | Temperature (NUMBER), Light Level (INT, lux), Battery Level (INT), Battery Low (BOOL), Online (BOOL) | Online, Enabled (BOOL) | KNX `Brightness`, `Movement Detection Enabled`; Control4 wireless sensor [community] |
| Events | Temperature Changed, Light Level Changed (past a threshold), Battery Low, Battery Critical, Battery Normal, Sensor Offline, Sensor Online | Area Enabled, Area Disabled, Offline, Online | KNX enabled/disabled events; Axxess battery and communication events [community] |
| Conditionals | NUMBER Temperature, NUMBER Light Level, NUMBER Battery Level, BOOL Battery Low, BOOL Online | BOOL Online, BOOL Enabled | Z2MQTT and Unilogiq [community] |
| Commands (programming) | optional: Enable Sensor, Disable Sensor, Set Sensitivity (Hue writes) | optional: Enable Area, Disable Area | KNX enable/disable commands |
| Actions (Composer) | Adopt Hue Name, Forget This Sensor, Get Status, Test: Motion, Test: No Motion | the same | Our drivers; LEAP "Get Status"; KNX trigger actions |

Conventions to follow:

- An event's `<description>` carries the `NAME` macro, which Composer
  replaces with "Room->Device"; `<sort_order>` orders events from OS 3.3.0;
  `C4:AddEvent` exists for dynamic events [verified: API 7/_1.1, FUND
  12.5/_10]. Static events in `driver.xml` suffice here.
- Conditionals take the types SIMPLE, BOOL, NUMBER, STRING, LIST, ROOM and
  DEVICE through `TestCondition`; a NUMBER conditional compares integers and
  has `<minimum>` and `<maximum>` since OS 3 [verified: FUND 10/_1, _4, _7;
  FUND `3_what's_new/_20-WHATWASNEWIN OS3.md`]. Dynamic conditionals are
  OS 4.1.0 (FUND `3_what's_new/_5-WhatsNewin400.md`; `_16-WHATSNEWIN320.md`
  places them in 3.2.0) and are not needed.
- Variable names: Control4's own proxies use Title Case display names
  ("Light State", "Brightness Percent" [verified: LV2 30/_0]; the contact
  proxy's `ContactState` and its kin). Third-party drivers mix Title Case
  and UPPER_SNAKE [community]. Recommendation: Title Case. Add variables in
  `OnDriverInit`, always in the same order, because Composer programming
  refers to variable ids handed out in that order; supported types include
  BOOL, INT, NUMBER, FLOAT and STRING [verified: API 36/_1].
- Once released, never remove, rename, retype or renumber an event,
  variable or command, because programming refers to them; adding is safe
  [verified: FUND 14/_2].

### 2.3 History and notifications

- **Motion** history comes from the proxy (§2.1, assumed) and needs no code.
- **Battery and offline** could be written with `C4:RecordHistory`, but its
  two API pages disagree. The helper page (available from 1.6.0) takes
  severity, type, category, an optional subcategory and a metadata table.
  The OS 3.4.0 page adds a leading device id (the proxy id, used for the
  deep link) and a description [verified: API 9/_15 vs API 15/_15]. Snap
  One's Temperature Display wraps it with severity, type, category,
  subcategory and description [verified: TD `common/c4_utils.lua`].
- `C4:RegisterEvents` (OS 3.4.0) registers event types under a category and
  subcategory so users can switch notifications on. Navigators offer only
  curated categories, and a call made before the History agent is ready
  fails and must be retried [verified: API 7/_5.2]. Deep links need the
  Navigation agent [verified: FUND 12.5/_5].
- Recommendation for beta 1: no `RecordHistory`. Probe the signature on the
  house first (§8 H5; it needs no sensor), then add battery and offline
  entries.

## 3. Light level, temperature and battery

### 3.1 Temperature

| Item | Content | Source |
| --- | --- | --- |
| Class | `TEMPERATURE_VALUE`: the thermostat proxy's Temperature and Outdoor Temperature outputs; humidity has `HUMIDITY_VALUE` | [verified: PP 97/_1] |
| Value | `VALUE_CHANGED` with `CELSIUS`, `FAHRENHEIT` and `TIMESTAMP` | [verified: PP 97/_2] |
| First value | Documented as `VALUE_INITIALIZED` (`STATUS`: active or last_known; `TIMESTAMP`). Snap One's own Temperature Display handles `VALUE_INITIALIZE`, without the D | [verified: PP 97/_2 vs TD `device_specific.lua`] |
| Unavailable | `VALUE_UNAVAILABLE` with `STATUS` = offline | [verified: PP 97/_2] |
| Request | `GET_SENSOR_VALUE` from the consumer; the Temperature Display sends it (and `QUERY_SETTINGS`) when it is bound | [verified: PP 97/_2; TD] |
| Consumers | The Temperature Display (a `thermostatV2` proxy) reads `SCALE` with `VALUE`, or `CELSIUS`, or `FAHRENHEIT`, and shows the value on Navigators. Control4's Z2IO binds its temperature outputs to the C4-THERM thermostat and recommends this display for Navigators. C4-THERM reads `CELSIUS`, needs `TIMESTAMP`, and drops readings older than 900 s | [verified: TD; C4 docs, Z2IO guide]; C4-THERM [community: control4-esphome PR #116, which cites that driver's code] |
| Scale | `C4:GetProjectProperty("TemperatureScale")` (OS 3.0.0) for properties and variables | [verified: API 24/_2] |

Send all three documented keys. Re-sending while the value stays valid
(about every 10 min) keeps a thermostat from dropping it; whether to do that,
and with which timestamp, is a contract decision. Do not declare a room
binding of class `TEMPERATURE`: the Temperature Display declares one (room
binding 7000, `TEMPERATURE` and `TEMPERATURE_CONTROL`, autobind) [verified:
TD], Unilogiq declares it on a sensor [community], and nothing documents it
for a device that is not a thermostat.

### 3.2 Light level

No documented Control4 class carries a light level. Snap One's KNX driver
publishes it as a NUMBER variable `Brightness` [verified: KNX]. Control4's
wireless sensor publishes light level and day/night as variables
[community]. Axxess adds an Illumination % property and variable, day and
night modes with thresholds, and an `AMBIENT_LIGHT_LINK` output
[community]. That output probably feeds the ambient light source/follower
feature that OS 3.2.2 added for button backlights [assumed; the feature:
verified: C4 docs, OS 3.4.0 release notes, release history]. The SDK
documents neither its class nor its protocol (a search of the API, FUND, LV2
and PP texts finds nothing): not for this beta. Hue reports
10000 × log10(lux) + 1 [community; assumed, Hue research]. Proposal:
property, variable and NUMBER conditional in lux, plus an event fired past
a change threshold so the stream does not flood programming.

### 3.3 Battery

The contact proxy has no battery notification: its guide lists four
notifications and nothing else [verified: PP 112]. The app's battery mark on
the Locks & Sensors icon is documented for locks [verified: C4 docs
`locks.htm`] and is not reachable from a contact [assumed]. Convention:
properties and variables for level and state, with Battery Low and Battery
Critical events (Control4's wireless sensor; Axxess "Battery is Low", "Battery
is Critical") [community]. Hue reports `battery_state` (normal, low,
critical) and `battery_level` [assumed, Hue research], which map
one-to-one.

### 3.4 What is realistic on OS 3.3 and later

| Value | Navigator | Programming | Other devices | History |
| --- | --- | --- | --- | --- |
| Motion | yes: stock sensor in Locks & Sensors | stock events, conditionals and variables | through the proxy device | yes, from the proxy [assumed] |
| Temperature | only through a Temperature Display bound to our output | our variable, event, conditional | thermostats through `TEMPERATURE_VALUE` | no |
| Light level | no | our variable, event, conditional | no documented class | no |
| Battery | properties only (Composer) | our variables, events, conditionals | — | OS 3.4+ with `RecordHistory`, after a probe |
| Online | properties only | our variable, events, conditional | — | as battery |

## 4. Occupancy timing

### 4.1 Which state means motion

| Source | Motion is | Marker |
| --- | --- | --- |
| Snap One KNX Movement Sensor: the "movement" value sends `OPENED`, the "no movement" value `CLOSED` | `OPENED` | [verified: KNX `driver.lua`] |
| Axxess Motion Sensor AV: its output sends `OPENED` on motion unless Invert Contact Output is set | `OPENED` | [community: Axxess documentation in the driver] |
| hass-control4 (reads Director): `ContactState` true means closed or clear | open | [community] |
| ClareOne integration guide: on motion, check that the state changes to open | open | [community] |
| Faradite: a relay that closes on motion needs Invert Sensor ticked on the stock Motion Sensor | open by default | [community] |
| Zigbee2MQTT Hue driver: occupancy true sends `OPENED` | `OPENED` | [community] |
| ESPHome BTHome driver: motion sends `OPENED` | `OPENED` | [community] |
| ESPHome generic binary sensor sends `CLOSED` when triggered; its SwitchBot page says "motion = closed" | `CLOSED` | [community; the outlier] |

Decision basis: `OPENED` = motion, `CLOSED` = clear. The proxy's Invert
Sensor would flip it, so our documentation must tell dealers to leave it
unticked.

### 4.2 Where the clear delay lives

| Who holds the delay | Examples | Marker |
| --- | --- | --- |
| The sensor, set from Composer | Control4 wireless sensor occupancy hold time (5 s to 60 min); Axxess Occupancy Hold Time; the KNX driver sends the sensor's switch-off delay by command, and "stops sensing motion" fires when it expires | [community]; [verified: KNX] |
| The driver | Unilogiq "Occupancy hold" (minutes, default 3) on a second contact | [community] |
| Programming | "senses motion" stops a Timer agent, "stops sensing motion" starts it, and the timer turns the lights off | [community: Faradite, forum summaries] |
| The proxy | only Debounce Time (ms), a filter, not a hold | [verified: LEAP documentation] |

The Hue sensor's own clear time is fixed and not writable over CLIP v2
[assumed, Hue research], so a driver-side hold is the only way to offer the
Control4 "Occupancy Hold Time" setting. Recommendation: an Occupancy Hold
Time (s) property, 0 to 3600, **default 0** (report what Hue reports).
Motion restarts the hold, the held state is what the proxy, the events and
the history see, and the raw Hue state stays visible in the Hue Motion
property. A lights-off timeout never belongs in the driver; that stays in
programming.

### 4.3 Start-up, resync, offline

- At start, nothing is sent until the bridge confirms the state; then send
  `STATE_*`. Answer `GET_STATE` the same way, and stay silent while the
  state is unknown [verified: TPL `c4hook_sensor.lua`].
- Live: `OPENED`/`CLOSED` only on a change, never on a repeated report
  [verified: TPL `c4hook_sensor.lua` behaviour].
- After a stream outage, a state that changed meanwhile goes out as
  `OPENED`/`CLOSED`, so programming catches up late rather than never
  (contract decision).
- Sensor unreachable or stream down: the contact keeps its last state;
  Online goes false and Sensor Offline fires. Whether to force `CLOSED` after
  a while (a sensor that died during motion would otherwise hold "sensing
  motion" forever) is an owner question (§9).

## 5. Packaging and binding to the bridge

### 5.1 One proxy per device

- Proxies are fixed at add time. Adding, removing or retyping a proxy in a
  later version corrupts updated devices and needs a new driver file
  [verified: FUND 14/_2]. `contactsingle_motionsensor` is therefore a
  one-way door for `hue_motion.c4z`, and beta 1 must get it right.
- Connections may only be added later, never removed or redefined; events
  and variables may be added, never removed or renumbered [verified: FUND
  14/_2]. The extras can grow; the proxy cannot.
- Rejected: a second proxy per sensor (for example `thermostatV2` to show
  temperature). It doubles the devices, puts a mode-less thermostat in
  Comfort for every sensor, and would be frozen forever. The stock Temperature
  Display does the same job when the owner wants it.
- Rejected: `<dependencies>` that auto-add a stock Motion Sensor, as a
  Reolink driver does [community: dmurray14/c4-reolink-driver]. It is
  documented for drivers loaded into a project [verified: FUND 18/_2],
  creates a second device, and is unknown for `C4:AddDevice` [assumed].
  `<replaces>` deletes the old driver's devices rather than migrating them
  [verified: XML `_33.5-replaces.md`], so it is no migration path either.

### 5.2 One driver with two kinds, or two drivers

| | One `hue_motion.c4z`, kind sensor or area | Two drivers (Lutron style) |
| --- | --- | --- |
| Precedent | `hue_light` kind "group" for zones [house] | LEAP occupancy sensor plus LEAP area sensor [verified: LEAP] |
| Release plumbing | 4 drivers (`tools/build.sh`, Release workflow, deploy brief, manifest) | 5 |
| Properties | area hides the sensor rows with `C4:SetPropertyAttribs` [verified: API 24/_4; house use] | each has only its own |
| Temperature output | inert on areas, unless added at run time with `C4:AddDynamicBinding` (CONTROL, provider), which must be re-added at every init [verified: API 22/_1] | sensors only |
| Composer driver search | one "Hue Motion Sensor" | two entries |

Both work; the owner decides (§9).

### 5.3 Binding to the bridge

- Consumer connection 1, class `HUE_BRIDGE`, bound to the bridge's provider
  connection 1 ("Hue Lights"), as `hue_light` and `hue_scene` are [house].
  The connection's name is cosmetic. Renaming it would change a connection
  definition, which FUND 14/_2 warns against [assumed that the name counts];
  a second provider connection (for example id 2, "Hue Sensors") may be
  added [verified: FUND 14/_2].
- Creation stays user-initiated: `C4:AddDevice` (3.2.0+, documented for user
  actions; it takes a room and a name), whose callback on 3.4.2 passes the
  protocol id and a tree with `protocol` and `proxy` [verified: API 9/_0.1;
  house]. Then `C4:Bind` from the bridge, and later `C4:RenameDevice` on the
  proxy [verified: API 22/_32; house].
- Messages: the light pattern (`HUE_HELLO`, `HUE_CONFIGURE`, `HUE_STATE`,
  `HUE_GOODBYE`, `HUE_FORGET`, `HUE_FORGOTTEN`) [house:
  `docs/import-design.md` §4] extended for motion, or a `HUE_MOTION_*` set:
  a contract decision. `common/device.lua`'s bridge lookup, early-message
  buffer, binding re-check, Driver Version and goodbye fit a motion driver,
  but its keypad, LED and `BUTTON_ACTION` parts are light_v2 only [house],
  so the contract should split the module or give motion a slimmer helper.
- Icons: the stock motion icons through `<states>` make it look like every
  other Control4 sensor [verified: LEAP, PP 111/_1]. Our own artwork on a
  proxy tile was ignored for lights (`docs/icons-research.md`), and the same
  is likely here [assumed].

## 6. OS 3.x and 4.x, Composer versions, capabilities

| Item | OS 3.3 and 3.4 (house 3.4.2) | OS 4.x | Marker |
| --- | --- | --- | --- |
| `contactsingle_motionsensor` proxy for DriverWorks | available: Snap One drivers since 2018; LEAP needs 3.1.0 | no change recorded: the contact guide notes no modification in any release from 3.0.0 to 3.4.2 and has no 4.x entry; Snap One kept LEAP (2024) and its processors (2025 to 2026) current | [verified: DB, LEAP, PP `3_whats_new`]; 4.x [assumed] |
| `TEMPERATURE_VALUE` | documented; Temperature Display since 2.10 | same | [verified: PP 97, TD]; 4.x [assumed] |
| Event sort order | 3.3.0+ | yes | [verified: FUND 12.5/_10] |
| `RegisterEvents`, `RecordHistory` with a device id, per-device notifications | 3.4.0+ | yes | [verified: API 7/_5.2, API 15/_15, C4 docs 3.4.0] |
| `AddDevice` | 3.2.0+ | yes | [verified: API 9/_0.1] |
| Dynamic conditionals | — | 4.1.0 | [verified: FUND `3_what's_new/_5`]; not used |
| X4 Zigbee 3.0 | — | limited to drivers Snap One wrote (locks, shades); no new sensor model | [community: Snap One release-note summaries] |
| `<capabilities>` | none in `hue_motion`; the bridge declares none | same | [verified: LEAP, KNX]; no reboot [assumed, probe H1] |
| Composer Pro 3.x builds vs date-versioned builds | nothing documented differs for contact devices | — | [assumed] |

Minimum OS: 3.3.0, like the other three drivers [house]. Nothing in this
design needs more except `RegisterEvents` and the 3.4.0 `RecordHistory`,
which must be guarded with a function check, as the API page's own example
does [verified: API 7/_5.2].

## 7. Recommendation

Build `hue_motion.c4z` as a protocol driver whose only proxy is
`contactsingle_motionsensor` (5001, type 2, provider, `CONTACT_SENSOR`).
Add a consumer `HUE_BRIDGE` connection 1, a provider `TEMPERATURE_VALUE`
output, stock motion icons, Composer category Sensors and no capabilities.
Each Hue motion sensor and each MotionAware area becomes one such device,
created only from bridge actions with `AddDevice` + `Bind`. The driver sends
`OPENED` for motion and `CLOSED` for clear, `STATE_*` for the start state and
for `GET_STATE`. Temperature goes out as `VALUE_CHANGED`
(`CELSIUS`/`FAHRENHEIT`/`TIMESTAMP`). Light level, battery, online and
enabled become the driver's own properties, variables, events and
conditionals. There is an optional Occupancy Hold Time with default 0, test
actions (Test: Motion and Test: No Motion), and no `RecordHistory` until it
has been probed.

Rejected:

- **B, an output plus a stock Motion Sensor:** two devices and about 6 to 8
  clicks per sensor, and two names to keep in step. It is the third-party
  vendor pattern, not Snap One's pattern for imported devices. It can still
  be added later as a connection if a dealer asks [verified: FUND 14/_2].
- **C, a custom proxy:** no stock icon, state, Locks & Sensors entry,
  history or stock programming.
- **D, a security panel:** arming semantics, zones that still need stock
  devices, and the security area is out of scope.
- **A second proxy for temperature:** frozen forever, and a fake thermostat
  per sensor.
- **`<dependencies>` auto-add:** not for `AddDevice`, and a second device.
- **`AMBIENT_LIGHT_LINK` and a room `TEMPERATURE` binding:** not documented
  in the SDK.

## 8. Probes

House smoke test (no sensors; the Windows session; standing approval):

- **H1.** Install the beta. "Restart Director?" must not appear.
- **H2.** Add `hue_motion` from Composer's driver search into a room. Check
  that the tile and icon are the stock motion sensor; that the proxy page
  shows Invert Sensor, Debounce, State and Verified (No); that Advanced
  Properties shows ours; that Connections shows Hue Bridge and Temperature;
  and that Programming lists the stock events, conditionals and variables
  next to ours.
- **H3.** Run Test: Motion and Test: No Motion. Check State (Open, then
  Closed), that "senses motion" and "stops sensing motion" fire (a one-line
  test macro), and that the app's Locks & Sensors shows the device and a
  History entry. Then delete the test device.
- **H4.** Read only: confirm `contactsingle_motionsensor.c4i` is among
  Composer's virtual drivers.
- **H5.** Optional, dev build: one `C4:RecordHistory` call with each
  documented signature; see which one reaches the app's History.

Tester, round 1:

- **T1.** OS and Composer versions, bridge model, sensor models, number of
  MotionAware areas.
- **T2.** Import one sensor. Walk in: State is Open and "senses motion"
  fires. Leave: Closed and "stops sensing motion" fires. Measure the time
  from the last movement to Closed (Hue's own hold).
- **T3.** The device appears in the app under Locks & Sensors, with History;
  notifications can be switched on (OS 3.4+).
- **T4.** Temperature Display bound to Temperature shows °C; optionally a
  thermostat takes it as a remote sensor.
- **T5.** Light level, temperature and battery agree with the Hue app.
- **T6.** Restart the controller: the state comes back without a false
  event, and Verified stays Yes (this tests `STATE_*`).
- **T7.** One MotionAware area: as T2.
- **T8.** The Diagnostics action's output (issue item 3).

## 9. Open questions

For the tester:

1. Which OS and Composer Pro versions does his controller run, and is his
   bridge a Bridge Pro (MotionAware needs it)?
2. Which sensors (indoor, outdoor, old or new models), and how many
   MotionAware areas?
3. How does he program motion today: Timer agents in programming, or a hold
   time on the device?
4. Does he want temperature on Navigators (Temperature Display) or in a
   thermostat?

For the owner:

5. One `hue_motion.c4z` with two kinds, or two drivers (§5.2)?
6. Occupancy Hold Time in beta 1, default 0 (§4.2)?
7. A sensor that goes offline while showing motion: keep the state, or send
   `CLOSED` after some time (§4.3)?
8. Battery and offline history through `RecordHistory`: after probe H5, or
   later?
9. Hue writes from programming (enable or disable a sensor or area, set
   sensitivity) in beta 1, or read-only first?
10. A second bridge provider connection named "Hue Sensors", or reuse
    "Hue Lights" (§5.3)?

## Sources

Snap One and Control4 (public):

- https://github.com/snap-one/docs-driverworks-proxyprotocol (and `-contact`, `-tstat`)
- https://github.com/snap-one/docs-driverworks-xml
- https://github.com/snap-one/drivers-template-code-public (`c4hooks/c4hook_sensor.lua`, `common/c4_notify.lua`)
- https://drivers.control4.com/solr/drivers/browse?fq=primaryProxy%3A%22contactsingle_motionsensor%22
- https://drivers.control4.com/lutron_leap_occupancy_sensor.c4z, https://drivers.control4.com/lutron_leap_area_occupancy_sensor.c4z
- https://drivers.control4.com/knx_movement_sensor.c4z
- https://drivers.control4.com/TemperatureDisplay210.c4z
- https://docs.control4.com/help/c4/user/userguide/content/topics/security/locks.htm
- https://docs.control4.com/help/c4/user/userguide/content/topics/security/basics-security.htm
- https://docs.control4.com/docs/product/control4-software/dealer-release-notes/english/revision/AC/control4-software-release-notes-rev-ac.pdf (OS 3)
- https://docs.control4.com/docs/product/control4-software/dealer-release-notes/english/revision/AQ/ (OS 3.4.0)
- https://docs.control4.com/docs/product/z2io/dealer-installation-guide/english/latest//z2io-installation-guide-rev-e.pdf
- https://help.snapone.com/c4-osreleasenotes/Content/Intro.htm (X4, OS 4.0 to 4.3)
- https://www.control4.com/docs/product/wireless-motion-sensor/data-sheet/english/revision/A/ (seen through search summaries only)

Third-party:

- https://drivers.control4.com/axxess_motionsensor.c4z; https://www.axxind.com/knowledge/motion-sensor-composer-guide/
- https://unilogiq.com/2025/02/01/control4-driver-hue-motion-sensor-gateway/ (zip with `Unilogiq_HueSensor.c4z` and a PDF)
- https://github.com/SolutionsLogicielsBreton/Control4-Zigbee2MQTT (`src/Z2MQTT_PHILIPS_HUE_MOTION_SENSOR`)
- https://github.com/finitelabs/control4-esphome and https://github.com/finitelabs/control4-esphome/pull/116
- https://github.com/lawtancool/hass-control4 (`custom_components/control4/binary_sensor.py`)
- https://github.com/scruzals/Berto (`src/Berto_HomeAssistant/driver.xml`)
- https://github.com/dmurray14/c4-reolink-driver (`src/driver.xml`)
- https://www.faradite.com/blogs/news/using-faradite-motion-sensors-with-control4
- https://www.clarecontrols.com/helpcenter/clareone-panel-control4-driver-integration-release-notes-doc-id-1935
- https://drivercentral.io/platforms/control4-drivers/philips-hue-security-pack/
