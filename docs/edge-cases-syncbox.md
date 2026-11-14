# Edge cases and lifecycle policy: Hue Play HDMI Sync Boxes and entertainment areas

> **Research (2026-11-13) for issue #514**, the 2.0 feature, written before any design or contract, against `main` at release 1.8 (build 644); "today" and `[code: …]` mean that code. Read-only. It enumerates the lifecycle corner cases on the box's side, the Hue side and the Control4 side, and their interactions, and recommends per case what the drivers do on their own, what they only offer, and what never happens without a click. Five research notes were written at the same time: [`syncbox-control4-research.md`](syncbox-control4-research.md) (R3, Control4) and [`syncbox-comparables-research.md`](syncbox-comparables-research.md) (R6, comparables) were read before this one was finished and agree with its direction; `docs/syncbox-api-research.md`, `docs/entertainment-areas-research.md` and `docs/syncbox-architecture-research.md` did not exist yet and are not linked. Where they settle a fact or a device model differently, they win, and the rows here keep their class and change only where the text shows.

This note does for the sync box what [`edge-cases-motion.md`](edge-cases-motion.md)
did for motion sensors. It builds on the lights' and scenes' lifecycle
([`edge-cases-hue.md`](edge-cases-hue.md), [`edge-cases-control4.md`](edge-cases-control4.md),
[`edge-cases-ux.md`](edge-cases-ux.md)), the 1.2 automatic behaviours
([`simplify-actions-design.md`](simplify-actions-design.md): local discovery,
re-link by radio, two-way names, room mappings), the scene placement rule
([`scene-rooms-research.md`](scene-rooms-research.md)), the Hue automation
audit ([`edge-cases-automations.md`](edge-cases-automations.md)) and the
bridge outage rule ([`offline-design.md`](offline-design.md)).

Three things make the sync box different from everything the drivers handle
today, and most new rows follow from them:

1. **The box is not a bridge resource.** It has its own local API, its own
   registration (a button press on the box), its own hardware identity (the
   `uniqueId` on its label and in its certificate), and, as far as anyone
   has shown, no event stream: what the Hue Sync app or the box's own HDMI
   logic changes is seen only at the driver's next poll.
2. **It sits in Control4's AV path.** Director chooses the path from what
   the user picks, ignores notifications it did not ask for, and tells
   drivers not to select other devices. A protocol driver hears nothing when
   AV connections are made or removed, and AV connections cannot be created
   at runtime. The box must therefore carry out Director's commands and
   report what it sees, never steer the path.
3. **An entertainment area borrows lights that other Control4 devices
   already own.** While a box syncs, the Hue Light, zone light and Hue Scene
   devices of those lights stand for lamps the stream drives, and Control4's
   lighting rules (L4, L53, L56 of [`c4-lighting-guidelines.md`](c4-lighting-guidelines.md))
   meet a Hue mode the drivers do not read yet.

Markers, as in the other research notes: [verified: …] = the DriverWorks
reference, cited by file under `~/c4-tools/reference/` (`API` =
`docs-driverworks-api/source/includes/`, `FUND` =
`docs-driverworks-fundamentals/source/includes/`, `PP` =
`docs-driverworks-proxyprotocol/source/includes/`), a project document, or
the house; [code: file] = what the drivers do today; [community: …] = a
library or integration, read on 2026-11-13: `aiohuesyncbox` (the Python
library behind Home Assistant's sync box integration,
https://github.com/mvdwetering/aiohuesyncbox, branch `master`) and `aiohue`
(https://github.com/home-assistant-libs/aiohue); [assumed] = not confirmed
anywhere, to test.

Classes used in every table: **auto** (the driver does it by itself and
says so), **offered** (the driver shows a proposal; one click accepts),
**click** (happens only when the owner starts it; nothing proposes it),
**none** (nothing to do). The column "Never without a click" lists what the
row forbids.

## Rules behind every row

The three rules of [`import-design.md`](import-design.md) §1 and the four of
the motion note hold. For the sync box they read:

1. **The project is the owner's.** Devices are created, renamed, bound or
   re-pointed only from a click (`C4:AddDevice` is for user-initiated use
   [verified: API `9_helper/_0.1-AddDevice.md`]), and no API moves or deletes
   a device [verified: the sweep in `docs/edge-cases-ux.md`]. For the box this
   also covers its AV connections: they are the owner's drags in Composer, and
   the driver never makes, changes or removes one.
2. **Nothing is lost by waiting.** Every change seen on the box or the
   bridge is cached, shown on a row and logged, so the owner can act on it
   later.
3. **The Control4 device is the identity; the box and the area are
   re-pointable.** The sync box device carries its room, its connections,
   its programming and the room's source list. A replaced box is a re-link
   and a new registration, never a delete and re-add. Whatever refers to an
   area (the box's setting, a programming line) must be re-pointable in one
   place when Hue makes the area again under a new id (§6).
4. **Control4 is the source of truth for the AV path** (the owner's rule,
   #280). The driver does what Director asks and reports what the box does.
   A change made outside Control4 (CEC, the box's input-follow, the Hue Sync
   app) goes into the driver's own variables and events and is never
   "corrected" by itself: Director ignores unsolicited notifications and runs
   no pathing in reverse [verified: PP
   `116_proxy_and_protocol_best_practices/_1-AVPATHINGUNSOLICITEDNOTIFICATIONSANDCONTROL4UI.md`].
5. **The box's own automations are Hue-side automations.** CEC input switch,
   hot-plug input switch, auto-sync on link and the power-save triggers act
   on their own, like the Hue automations of #280. They are read and shown,
   and changed only by a click that can be undone, as the Hue Automations
   action does ([`hue-automation-audit-design.md`](hue-automation-audit-design.md)).
6. **The registration is a secret bound to one box.** It goes only to a host
   whose certificate and answer name the stored `uniqueId`, and never moves
   to another box by itself, as the bridge's key never goes to another bridge
   [code: `bridge/identity.lua`, `away:other_bridge`].
7. **Report what is known; invent nothing.** Sync state, mode, input and
   area come from the box's answer, never from what was commanded; a command
   that did not land is answered with the last known state, as for lights
   ([`offline-design.md`](offline-design.md) D8, D9).
8. **The drivers start no streams and stop none.** The box streams to the
   bridge. The drivers never start or stop an entertainment session on the
   bridge, never edit an area, and never write the box's bridge link.

## 0. Facts the policy rests on

### 0.1 The box

| # | Fact | Status |
| --- | --- | --- |
| F1 | A local HTTPS API at `https://<box>/api/v1`; requests carry `Authorization: Bearer <accessToken>`. The library checks TLS against a CA it bundles, with the box's `uniqueId` as the expected host name. | [community: aiohuesyncbox `huesyncbox.py`, `hsb_cacert.py`] |
| F2 | `device`: `name`, `deviceType` (HSB1 is the original 4K box, HSB2 the 8K box, HSB3 the slim 4K box of 2026 with one HDMI input; HSC1 is the Play Screen Sync camera, with no HDMI at all), `uniqueId` (12 hex characters, "used as unique id on label, certificate common name, hostname"), `ipAddress`, `apiLevel` (raised between firmware versions when the API changes), `firmwareVersion`, `buildNumber`, `updatableBuildNumber`, an automatic update at a set UTC hour, `action` (software restart, firmware update, update check), `overheating` (API 10+), `undervolt` (8K only, API 14+). | [community: aiohuesyncbox `models/device.py`, `models/behavior.py`, `models/hue.py`]; the products behind HSB3 and HSC1 [verified: R6 §0, from Home Assistant's integration and launch reports]; that `uniqueId` survives a factory reset [assumed: it is the label's hardware id] |
| F3 | Registration: `POST /registrations` with `appName` and `instanceName`, sent without a token, answers `registrationId` and `accessToken` once the box's button is pressed. Error code 16 means "invalid state"; codes 1 to 3 mean unauthorized. A client may delete only its own registration. The box lists every registration with `appName`, `instanceName`, `created`, `lastUsed` and a role (`admin`, `user`). | [community: aiohuesyncbox `controllers/registrations.py`, `errors.py`, `huesyncbox.py` `unregister`, `models/registrations.py`]; that code 16 is "button not pressed yet", the window's length, and whether the Hue Sync app can remove another app's registration [assumed] |
| F4 | One `GET /api/v1` returns `device`, `hue`, `execution`, `hdmi`, `behavior`, `ir`, `registrations` and `presets`. The library has no push or event mechanism; its users poll. | [community: aiohuesyncbox `huesyncbox.py` `refresh_data`]; that the box offers no push at all [assumed] |
| F5 | `execution`: `mode` (`powersave`, `passthrough`, `video`, `game`, `music`); `syncActive` (true only in the three sync modes); `hdmiActive` (false only in power save); `hdmiSource` (`input1` to `input4`); `hueTarget` (the entertainment configuration id on a v2 bridge); `brightness` 0 to 200 (100 = as the input); per mode `intensity` (`subtle`, `moderate`, `high`, `intense`), background lighting and the music palette; `preset`. Writes take the same fields plus toggles and cycles. Later firmware adds values the library maps to "unknown". | [community: aiohuesyncbox `models/execution.py`, `models/enums.py`] |
| F6 | `hue`: `connectionState` (`uninitialized`, `disconnected`, `connecting`, `unauthorized`, `connected`, `invalidgroup`, `streaming`, `busy`), `bridgeUniqueId`, `bridgeIpAddress`, `groupId` (API 10+), `groups` (the areas: `name`, `numLights`, `active`, and `owner` only while active), `operatingMode` (`bridge` or `standalone`: lights paired to the box over Bluetooth, HSB2 and later, API 14). | [community: aiohuesyncbox `models/hue.py`, `models/enums.py`]; that `busy` means another app streams to the bridge [assumed] |
| F7 | `hdmi`: `input1` to `input4` (HSB3: `input1` only), each with `name`, `type` (`appletv`, `playstation`, …), `status` (`unplugged`, `plugged`, `linked`, `unknown`) and `lastSyncMode`; `output`; `contentSpecs`; `videoSyncSupported`, `audioSyncSupported`. | [community: aiohuesyncbox `models/hdmi.py`, `models/behavior.py`] |
| F8 | `behavior`: `inactivePowersave` (power save after this many minutes in passthrough with no link; default 20, 0 = off), `cecPowersave` (power save when the TV sends CEC off), `usbPowersave` (power save when the USB supply drops), `hpdInputSwitch` (switch to any source plugged in or powered on), per input `cecInputSwitch` (switch when that source sends CEC active), `linkAutoSync` (start syncing when that source and the output link), `hpdInputPortSwitch` (API 10+), `arcBypassMode`, `soloMode` (API 14). | [community: aiohuesyncbox `models/behavior.py`] |
| F9 | Discovery: mDNS `_huesync._tcp.local.`, TXT `devicetype` and `name`, addresses from the A records. | [community: aiohuesyncbox `example_zeroconf.py`]; whether TXT carries `uniqueId`, and whether `GET /api/v1/device` answers without a token [assumed] |

### 0.2 Entertainment areas on the bridge

| # | Fact | Status |
| --- | --- | --- |
| H1 | An area is an `entertainment_configuration`: `metadata.name`, `configuration_type` (`screen`, `monitor`, `music`, `3dspace`, `other`), `status` (`active`, `inactive`), `active_streamer` (while active), `stream_proxy`, `channels`, `locations.service_locations` (the member lights' `entertainment` services), the deprecated `light_services`; a PUT takes `action` `start` or `stop`. | [community: aiohue `v2/models/entertainment_configuration.py`] |
| H2 | Each light has an `entertainment` service (`renderer`, `proxy`, `renderer_reference` to its light); the bridge's own device carries `max_streams`, the number of parallel sessions the bridge supports (the model's default is 1). | [community: aiohue `v2/models/entertainment.py`]; the Bridge Pro's value [assumed: unknown, to read] |
| H3 | `light.mode` is `normal` or `streaming`. The drivers read no `mode` today. | [community: aiohue `v2/models/light.py`]; [code: `bridge/hue_model.lua` and `bridge/lights.lua` read `color_mode` only] |
| H4 | What the lights do when a session ends is a Hue setting per area: an instance of the entertainment script "Light state after streaming", `where` = the area, `end_state` (`last_state` in a dump). The automation audit counts it as not audited and never writes it. | [verified: [`hue-automations-research.md`](hue-automations-research.md), its script table and fixtures; [`hue-automation-audit-design.md`](hue-automation-audit-design.md) H19] |
| H5 | An area's lights may come from any room; an area is neither a room nor a zone and owns no `grouped_light`. Area ids are UUIDs, made new when an area is made again. | lights from any room [assumed: the Hue app offers any entertainment-capable light; R3 §3.4 reaches the same]; no `grouped_light` and new ids [assumed: none in the aiohue model; ids as for rids, `docs/edge-cases-hue.md` §4] |
| H6 | While a session runs, whether a REST command to one of its lights shows at all, and what the light resource reports (the stream's colour, the pre-session state, or the commanded value). | [assumed: the stream overrides REST within a frame and the resource keeps pre-session values; to test] |
| H7 | The event stream carries `entertainment_configuration` updates (`status`, `active_streamer`) and light `mode` changes. | [assumed: the stream carries every resource type's updates, `docs/edge-cases-hue.md` §0; not seen for these two] |
| H8 | The bridge lists no `device` for a sync box; the box shows on the bridge only as a streamer (an `active_streamer` reference while it syncs). | [assumed] |

### 0.3 Control4

| # | Fact | Status |
| --- | --- | --- |
| K1 | The AV switch proxy sends the driver `SET_INPUT` (an input binding id, the upstream device, optionally an output), `SET_OUTPUT_INPUT`, `CONNECT_OUTPUT`, `DISCONNECT_OUTPUT`, `ON` and `OFF`; the driver notifies `INPUT_OUTPUT_CHANGED`, `ON` and `OFF`. Video inputs are bindings 1000 to 1099, video outputs 2000 to 2999, audio inputs 3000 to 3099, audio outputs 4000 to 4999, room bindings 7000 to 7999. ON and OFF only show a power state in Composer and Navigator; anything else is the driver's. | [verified: PP `8_audio_video_switch_proxy_commands/_46-SETINPUT.md`, `_48-SETOUTPUTINPUT.md`, `_3-CONNECTOUTPUT.md`, `_5-DISCONNECTOUTPUT.md`, `_27-OFF.md`, `_28-ON.md`; PP `7_audio_video_switch_protocol_notifications/_4-INPUTOUTPUTCHANGED.md`, `_7-OFF.md`, `_8-ON.md`] |
| K2 | Pathing is Control4's: the user picks a source in a room, Director picks the path and sends each device its commands. Notifications nobody asked for are ignored, pathing never runs in reverse, and drivers are told not to select other devices. | [verified: PP `116_proxy_and_protocol_best_practices/_1-AVPATHINGUNSOLICITEDNOTIFICATIONSANDCONTROL4UI.md`] |
| K3 | Protocol drivers get no `OnBindingChanged` for AV and room bindings. `GetBoundProviderDevice(proxy, input binding)` names the source on an input, `GetBoundConsumerDevices(proxy, output binding)` the devices on an output; `OnPIP` fires when bindings change. A proxy command `BINDING_CHANGE_ACTION` names a changed binding; Snap One's AV switch template handles it, with `BINDING_ID` and `IS_BOUND`. | [verified: API `9_helper/_12-OnBindingChanged.md`; API `32_serial_network_device/_4-GetBoundProviderDevice.md` (example on input 1011), `_3-GetBoundConsumerDevices.md` (example on output 2000); API `7_event/_1-RegisteringforSystemEvents.md`; PP `4_amplifier_proxy_commands/_2-BINDING_CHANGE_ACTION.md` (the amplifier's page); the template per R3 §1.3]; that the AV switch proxy sends it on this controller [assumed: R3's probes] |
| K4 | `AddDynamicBinding` does not work for audio, video and room bindings, so every HDMI connection and its name is fixed in `driver.xml`. | [verified: API `22_miscellaneous/_1-AddDynamicBinding.md`] |
| K5 | An update may add connections, never remove or retype one, and must never add, remove or change a proxy. | [verified: FUND `14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md`] |
| K6 | A driver may listen to a room's variables (the current video device, the power state, …). | [verified: API `36_variable/_10-RegisterVariableListener.md`, `_12-ListofRoomVariables.md`]; the ids as 1000 plus the list position [assumed: the page's examples use 1000 and 1019, which agree] |
| K7 | CUSTOM_SELECT lists serve commands as well as actions, so programming can pick an area or a preset from a list the driver builds. | [verified: FUND `12.3_custom_select_implementation/_1-Overview.md`]; that a programming line keeps the value picked when it was written and never asks again [assumed] |
| K8 | Persisted values follow the device id: an update in place keeps them, a delete and re-add loses them. Whether they come back with a project restore is not documented; encrypted values may not travel to a new controller. | [verified: house, `docs/edge-cases-control4.md` §0]; restore and migration [assumed: same note, 3.6 and 3.7] |
| K9 | `GetDevicesByC4iName` lists the devices of one driver; `GetDeviceVariable` reads another device's variable. | [verified: API `25_proxy/_4-GetDevicesByC4iName.md`, API `36_variable/_5-GetDeviceVariable.md`] |
| K10 | The drivers' outage rule: devices go offline after 300 s of continuous trouble and come back at the first contact; Status texts stay within 60 characters. | [verified: [`offline-design.md`](offline-design.md) D1, D7, §6.3] |

### 0.4 The model this note assumes

Until the architecture research decides, the rows assume: **one sync box
device per box** (here `hue_syncbox.c4z`, a placeholder name) with the AV
switch proxy, HDMI inputs 1 to 4 and one HDMI output, which holds its own
registration and polls its box; **bound to the Hue Bridge driver** like the
lights, so that the bridge's Add From Hue, Link Device, Forget Device and
Attention cover it, and the bridge supplies area names, member lights and the
marks on Hue Light devices during a session. **Areas are not devices**: the
box has an entertainment area setting, and programming picks areas from a
CUSTOM_SELECT list (§6 says what the cases need if areas get an identity of
their own). Action names below (Register Sync Box, Set Entertainment Area,
Sync Box Settings) are placeholders for the contract. "Qn" in a row is open
question n at the end.

Names in the texts are examples: "Living Room Sync Box" (a Hue Sync Box 8K,
`uniqueId` C0FFEE123ABC, shown as #3ABC, at 192.0.2.40, device 1301) in the
Control4 room Living Room, with Apple TV on HDMI 1 and PS5 on HDMI 2, syncing
"TV area"; "Den Sync Box" (#6DEF); "Game area"; the Hue rooms Living and
Kitchen; the paired bridge 001788fffe123abc.

## 1. The box

| # | Case | Driver sees | What it does | Class | Never without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | Box found on the network | An mDNS answer for `_huesync._tcp` with name, model and address; the `uniqueId` from the identity read (F9). | Listed under Add From Hue with model and short id, counted, logged once. Searched at first load and then hourly while a box device is unlinked or away; local only, never the internet. | auto | `AddDevice` from a search; registering; trusting the address before the identity read. | Attention "1 new Hue sync box on the network: Hue Sync Box (8K) #3ABC at 192.0.2.40 (Add From Hue)"; picker "Hue Sync Box (8K) #3ABC, 192.0.2.40". |
| B2 | Box entered by address | The owner types 192.0.2.40 on the box device. | TLS against the box CA, then the `uniqueId`; refused when the answer is not a sync box, or when another device already holds that box (B29). | click | Sending a token before the identity check. | Last Action "Found Hue Sync Box (8K) #3ABC at 192.0.2.40: press its button, then Register Sync Box"; refusal "Not linked: 192.0.2.40 is not a Hue sync box". |
| B3 | Registered (button pressed) | The POST answers `registrationId` and `accessToken` (F3). | The token is persisted the way the bridge key is; `instanceName` names the Control4 device ("Control4 device 1301"), so the owner can tell registrations apart on the box later (C4); the first full read follows. | click (and the owner's hand on the button) | Registering a second time while a registration works. | Last Action "Registered with Hue Sync Box #3ABC as Control4 device 1301"; Status "Ready: HDMI 1, passthrough". |
| B4 | Button not pressed in time | Code 16 for the whole window [community: F3]. | The window closes after 2 minutes, as Pair Bridge's does. | click | Retrying by itself. | Last Action "Not registered: the button on Hue Sync Box #3ABC was not pressed within 2 minutes; run Register Sync Box again". |
| B5 | Registration revoked (the Hue Sync app, another client, a reset) | Every request unauthorized (codes 1 to 3). | As the bridge's rejected key: re-checks at 5 min, 15 min, 1 h, then hourly; Online false after 5 minutes of refusals (K10); commands dropped and answered with the last known state; the token is kept, since a restore or the app may bring it back. | auto; Register offered | Registering again by itself (it needs the button anyway); deleting the stored token. | Status "Sync box refuses the registration since 14:02"; Attention "1 Hue sync box refuses its registration: Living Room Sync Box (press its button, then Register Sync Box)". |
| B6 | Factory reset | The box drops off the network; once set up again in the Hue Sync app it answers with the same `uniqueId` (F2, assumed), refuses the token, and has no bridge link or area (`uninitialized`, no `hueTarget`). | B13 while it is away, then B5; after Register, B18's text until the Hue Sync app has given it a bridge and an area. | auto; Register offered | Registering or choosing an area by itself. | Status "Sync box not set up: finish it in the Hue Sync app". |
| B7 | Replaced by another box (a new `uniqueId`) | The stored address is silent or answers another id (B12); a search lists a box no device holds. | Listed as new, with a hint when exactly one box device has been away or refused for more than an hour. | offered (Link Device, then Register) | Linking or registering on the hint; giving the old token to the new box. | Attention "1 new Hue sync box on the network: Hue Sync Box (8K) #6DEF (looks like a replacement for Living Room Sync Box; Link Device)". |
| B8 | An 8K box replaces a 4K box | As B7; `deviceType` HSB2; the 4K-only settings (HDR mode, Dolby Vision native) are gone, the 8K-only ones (`undervolt`) appear. | After Link Device and Register: the same device, room, connections and programming; rows for settings the model lacks read "not on this model"; a command for one is refused with that text. | offered | Changing connections or static capabilities (a capability change needs a controller reboot, L82). | Last Action "Linked Living Room Sync Box to Hue Sync Box (8K) #6DEF; HDR Mode is not on this model". |
| B9 | A replacement with fewer inputs (the slim one-input 4K box, HSB3, for an original 4K box) | `hdmi` holds `input1` only [community: F7]. | The four HDMI connections stay (K4, K5); a source connected to HDMI 2 to 4 is named on Status and Attention; `SET_INPUT` for them is refused (C10). | offered (link); the drags are the owner's | Routing a source to another input. | Status "HDMI 2 to 4 are not on this box"; Attention "Living Room Sync Box: PS5 is connected to HDMI 2, which this box lacks (move the connection in Composer)". |
| B10 | The same box moved to another TV or room | Same `uniqueId`; perhaps a new address (B11), other HDMI statuses and input names. | B11 for the address; the inputs row refreshed; the area kept; the Composer side is C2. | auto | Changing the area or any connection. | C2's mark. |
| B11 | Address changed (DHCP) | Requests time out; mDNS answers the same `uniqueId` elsewhere. | As the bridge (1.2's D5, D12): after a minute away, mDNS, then at most hourly a bounded sweep; the identity checked; the address rewritten and said once. | auto | An internet lookup; an address without the identity check. | Last Action "Hue Sync Box #3ABC moved to 192.0.2.41; address updated". |
| B12 | Another box or host answers at the stored address | TLS or the `uniqueId` names something else. | No token sent; treated as away; mDNS looks for the stored id. | auto | Sending the token; adopting the other box. | Status "Another device answers at 192.0.2.40 since 14:02"; Attention "Living Room Sync Box: another device answers at its address (Diagnostics finds it, or Link Device)". |
| B13 | Offline (power, Wi-Fi) | Polls fail. | K10's rule per box: trouble, Online false after 300 s, its Offline event once; commands meanwhile answered with the last known input and mode; at contact one full read, and Control4's last input re-sent only under I15's condition. | auto | Queuing commands beyond the bounded retry (L89). | Status "Sync box not answering since 14:02"; Attention "Hue sync boxes offline since 14:07: Living Room Sync Box". |
| B14 | Restarting or updating itself at night | A short outage around the box's update hour; the build number rises. | Under 5 minutes nothing shows (B13's trouble only); logged with both versions. | auto | Starting an update or a restart from Control4 (`device.action`). | Log "syncbox: Living Room Sync Box restarted (firmware 1.12 to 1.13)". |
| B15 | Firmware raised `apiLevel`; fields added, renamed or gone | A higher `apiLevel`, values the driver does not know, an object missing. | Tolerated: an unknown value reads "unknown (<value>)", a missing object makes its rows "not on this firmware"; neither counts as offline, reset or gone. | auto | Marking the box unlinked or offline for a missing field. | Model row "Hue Sync Box (8K), firmware 1.13, API 14". |
| B16 | Firmware below the driver's minimum | `apiLevel` under the minimum the contract sets. | Reads what exists; commands that need more are refused with the reason. | auto | Updating the firmware from Control4. | Status "Update the sync box in the Hue Sync app". |
| B17 | Linked to another Hue bridge in the Hue Sync app | `bridgeUniqueId` differs from the paired bridge's id. | Areas listed from the box's own `groups`; no marks on Hue Light devices (other bridge); said once. | auto | Writing a bridge link into the box; touching the Hue Bridge driver's pairing. | Status "Syncs with another Hue bridge"; Attention "Living Room Sync Box syncs with a Hue bridge other than 001788fffe123abc (set it in the Hue Sync app if that is wrong)". |
| B18 | Its bridge reset, or its bridge key gone | `connectionState` `unauthorized` or `uninitialized`; `groups` empty. | Sync commands refused with the reason; HDMI switching goes on; Attention at once (only the Hue Sync app can fix it). | auto | — | Status "Sync box lost its Hue bridge (Hue Sync app)"; Attention "Living Room Sync Box lost its link to the Hue bridge: set it up again in the Hue Sync app". |
| B19 | The box cannot reach its bridge | `disconnected` or `connecting`. | Switching goes on; a sync command is sent and reported as not syncing; Attention after 5 minutes. | auto | — | Status "Sync box cannot reach the Hue bridge since 14:02". |
| B20 | Standalone: lights paired to the box over Bluetooth | `operatingMode` `standalone` (F6). | Sync, mode, intensity and brightness work; the area picker shows one line for the box's own lights; no bridge marks. | auto | Requiring a bridge or a bridge area. | Area row "Standalone: lights paired to the box". |
| B21 | Inputs renamed or retyped in the Hue Sync app | `hdmi.inputN.name` and `type`. | Shown on the Inputs row beside the Control4 source; connection names cannot change (K4). Naming the box's inputs after their Control4 sources is offered once a source is connected. | auto (display); offered | Renaming Control4 devices after input names; writing input names by itself. | Inputs row "HDMI 1: Apple TV (box: Apple TV, linked); HDMI 2: PS5 (box: Game console, plugged)". |
| B22 | Box renamed in the Hue Sync app | `device.name`. | The names rule of 1.2 (D6), if it is extended to boxes (Q5): the Composer device follows, Control4 winning a clash; otherwise the Hue Name row only. | auto (Q5) | — | Last Action "Renamed Living Room Sync Box to TV Box (renamed in Hue Sync)". |
| B23 | Mode, intensity, brightness, area or input changed in the Hue Sync app or by the box | Seen at the next poll (F4). | The driver's variables follow and its events fire once per change, whatever made it (as lights do, L6, L68); the input change is reported to the proxy only as `INPUT_OUTPUT_CHANGED`, which Director ignores (K2). | auto | Undoing the change. | Log "syncbox: sync started outside Control4 (video, TV area)"; the variables. |
| B24 | The box's own automations are on (input switch by CEC or hot-plug, auto-sync on link, the power-save triggers) | `behavior` (F8). | Listed on a Box Automations row. An input switch that is on gets one Attention item, because it changes the picture behind Control4's back (I1); the others stay on the row. | offered (Sync Box Settings turns the input switches off; a second row puts them back) | Writing `behavior` by itself. | Attention "Living Room Sync Box switches inputs by itself (CEC on HDMI 1 and 2): Control4 may show the wrong source (Sync Box Settings)". |
| B25 | Overheating, or its supply too weak | `overheating`, `undervolt` (F2). | Status and Attention at once; nothing else. | auto | — | Status "Sync box overheating: give it air" / "Sync box power too low: use its own adapter". |
| B26 | A preset made, renamed or deleted in the Hue Sync app | `presets`. | The preset picker follows; programming that names a deleted preset logs and does nothing; one made again under the same name is offered as the new target (§6). | auto; offered | Running another preset on a name match by itself. | Last Action "Not run: preset Movie night was deleted on the box". |
| B27 | Two boxes on one TV (one box's output into the other) | Two devices; the owner's connections chain them. | Each switches as Director asks (pathing handles chains, K2); only one can stream at a time (E8). | auto | Turning one box off so the other can sync. | Status on the second "Not syncing: TV area is in use by Living Room Sync Box". |
| B28 | Several boxes, one per TV, on one bridge | The bridge's `max_streams` (H2). | Each syncs alone; a second session at once fails as E8 while the limit is 1. | auto | Stopping one box for another. | As E8. |
| B29 | Two Control4 devices for one box | Two devices claim one `uniqueId` (a restore that merged projects, a hand-added second device, a link to a box already held). | Neither registers or sends commands until one is forgotten; both Statuses say why. | offered (Forget Device on one) | Registering twice: two tokens would fight over the box. | Attention "2 devices claim Hue sync box #3ABC: 1301 and 1307 (Forget Device on one of them)". |
| B30 | A Hue sync device with no HDMI found (the Play Screen Sync camera, HSC1) | A search answer or a typed address with that `deviceType` [assumed: it answers the same mDNS service]. | Listed as "not an HDMI box" and never offered under Add From Hue or Link Device; logged once. | none | Adding it as an AV switch. | Picker line "Hue Play Screen Sync #9C1E: a camera, not an HDMI sync box". |

## 2. Entertainment areas: the Hue side

| # | Case | Driver sees | What it does | Class | Never without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- |
| E1 | Area made in the Hue app | An `add` on the bridge; the box's `groups` grows. | Listed in the area pickers (the box's setting and programming); logged. No Attention while areas are not devices. | auto | Pointing a box at it; creating anything. | Picker "Game area (screen, 3 lights)". |
| E2 | Renamed | `metadata.name`. | Labels follow; keyed by id, so the box and programming keep working. | auto | — | The new name on the rows. |
| E3 | Deleted while a box syncs to it | A bridge `delete`; the box reads `invalidgroup` or a `hueTarget` no area has. | Sync refused with the reason; Attention at once. No other area is chosen, even when only one is left. | offered (Set Entertainment Area) | Choosing another area by itself. | Status "Entertainment area deleted in Hue; pick another"; Attention "Living Room Sync Box syncs to an entertainment area deleted in Hue (TV area, 11-13): Set Entertainment Area". |
| E4 | Deleted and made again under the same name | E3, then E1 with a new id. | The new area is offered as the old one's replacement: one click points the box, and every programming line that named the old area (§6), at it. | offered | Re-pointing on the name match by itself. | Attention "… (TV area is on the bridge again; Set Entertainment Area)". |
| E5 | Its lights changed | Updates to `channels` and `locations`; `numLights`. | The light count and the lights' rooms refreshed; the marks of §6 derived again. | auto | — | Area row "TV area: 5 lights (Living Room 4, Kitchen 1)". |
| E6 | Its lights span Control4 rooms | The lights' Hue rooms through the room mapping. | No room is derived from the lights (§6); the area's room is its box's. | none | Moving lights, devices or mappings. | As E5. |
| E7 | Several areas for one TV or room (a TV area and a game area) | The box's `groups`. | All listed; the box's setting is the default; programming may switch areas (Set Area, K7). | click | — | Picker "TV area (screen, 5 lights)", "Game area (screen, 3 lights)". |
| E8 | Area busy: the Hue Sync desktop or TV app, the Hue app or another box streams | The box reads `busy`; the area is `active` with another `active_streamer` (H1). | The sync command is reported as not started, once; Status names the other streamer when it is a known box, else "another app"; no retry loop. | auto | Stopping the other session (a `stop` PUT). | Status "Not syncing: TV area is in use by another app"; Last Action "Sync not started: TV area is in use by another app". |
| E9 | A light deleted from the bridge during a session | The light's `delete`; the area's channels shrink. | The light's own device follows the lights' rules (gone); the area's count refreshed; the session is left alone [assumed: it carries on]. | auto | — | The light's usual "deleted in Hue" texts. |
| E10 | A light unreachable during a session | Its `zigbee_connectivity`. | The area row names it; the session is left alone. | auto | — | Area row "…; Desk Lamp not responding". |
| E11 | A session started outside Control4 (the Hue app, the Hue Sync app, the box's auto-sync) | The area `active`; the lights' `mode` `streaming` (H3, H7); a box's `syncActive`. | The Hue Light, zone light and Hue Scene devices of those lights are marked "in a sync session" (I8); a box's variables follow (B23). | auto | Stopping it. | Light Status "In a Hue sync session (TV area)". |
| E12 | A session ends | The area `inactive`; `mode` `normal`; Hue applies its after-sync setting (H4). | The marks clear; one read of the area's lights, whose state goes out as any Hue-side change. | auto | Imposing a Control4 state on the lights at the end. | — |
| E13 | The area's "light state after streaming" | The entertainment instance's `end_state` (H4). | Shown read-only on the area row. | none | Writing it. | Area row "After sync: lights go back to how they were". |
| E14 | Bridge replaced, restored or reset | Area ids kept, changed or gone; after a reset the box reads `unauthorized` (B18). | B18 for the box; areas as E3 and E4, with name hints. | auto; offered | Re-pointing by name by itself. | As B18, E3, E4. |
| E15 | A MotionAware area shares lights with an entertainment area | Both resources. | Nothing; a check for the tester [assumed: MotionAware may sense badly while its lights stream]. | none | — | The manual's note. |
| E16 | The box set to an area of type music, 3dspace or other | `configuration_type`. | Listed with its type; never refused [assumed: the box accepts any area]. | none | — | Picker "Party (music, 6 lights)". |

## 3. The Control4 side

| # | Case | Driver sees | What it does | Class | Never without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | Sync box device added | Add From Hue ▸ Sync boxes (`AddDevice` into the room picked), or the driver added by hand from Composer's search. | The new device waits for its registration; Add From Hue opens the 2-minute button window at once; a hand-added device offers the boxes found (B1) and the typed address (B2). | click | `AddDevice` from a search or a start. | Last Action "Added Living Room Sync Box to Living Room (device 1301): press the button on the box within 2 minutes". |
| C2 | Moved to another Control4 room | Nothing is called; the room is read when shown. | Marked when no light of its area sits in its new room; never moved back; the area unchanged; Set Entertainment Area then lists first the areas whose lights sit in the new room (R3 §3.4). | auto (display); offered | Changing the area; moving the device. | Area row "TV area (lights in Living Room; this box is in Den)". |
| C3 | Renamed in Composer | `OnItemNameChanged`. | The names rule (Q5). | auto (Q5) | — | — |
| C4 | Deleted in Composer | `OnDriverRemovedFromProject`; the token goes with the device's store (K8). | The bridge tombstones the entry; the registration stays on the box, named "Control4 device 1301" (B3), for the owner to remove in the Hue Sync app. | auto (tombstone) | Deleting the registration on the box (a restore would then need the button again); re-creating the device. | Picker "Hue Sync Box #3ABC (deleted from Composer 11-13)"; the manual names the leftover registration. |
| C5 | Forget Device on a box | A click, with Confirm. | The entry goes; the device is unbound and stays in the project; the box's registration is deleted (a client may delete its own, F3), and Last Action says so. | click | — | Last Action "Forgot Living Room Sync Box (device 1301): its registration on the box is removed; delete the device in Composer". |
| C6 | HDMI connections made (a source to HDMI n, the output to the TV) | No `OnBindingChanged` (K3); perhaps the proxy's `BINDING_CHANGE_ACTION`; read at late init, at `OnPIP`, at that command and at every `SET_INPUT`. | The Inputs row rebuilt; checked against the box's HDMI status: a source on HDMI 2 while the box sees only HDMI 3 linked gets a hint. | auto (display) | Making, moving or removing a connection. | Inputs row; hint "Apple TV is on HDMI 2 in Composer; the box sees a picture on HDMI 3 only". |
| C7 | Connections changed (a source moved to another input) | As C6. | `SET_INPUT` carries the binding id, so switching follows by itself; the row refreshed. | auto | — | — |
| C8 | Connections removed | As C6. | The input reads "not connected"; the box untouched. | auto | — | Inputs row "HDMI 3: not connected". |
| C9 | A source added to the project and connected | As C6. | As C6; B21's offer to name the input after it. | auto; offered | Renaming the box's input by itself. | — |
| C10 | A source on an input the box lacks | `SET_INPUT` 1001 to 1003 on a one-input box (B9). | Refused, logged, Last Action; Director goes on believing the path [assumed]. | auto | Switching to another input instead. | Last Action "Not switched: Living Room Sync Box has no HDMI 3 (Apple TV)". |
| C11 | The room's TV replaced | The owner swaps the TV device and connects the output to it. | As C6; the new TV's CEC may change I3. | none | — | — |
| C12 | The box's output into a receiver or a matrix; the box in more than one room's path | Director's commands only. | Each command carried out as sent; sync stops only on Director's commands (I6). | auto | Deciding by itself that a room is off. | — |
| C13 | Project restored from a backup | Devices return with their stores, perhaps older than the box (a replaced box, a newer registration), and programming of that day. | A device's hello adopts it (the device is the evidence); its token is tried at the box whose id it names, never elsewhere (rule 6); refused, B5; areas named by ids that are gone, E3 and E4. | auto; offered | Giving a restored token to another box. | Log "adopted Living Room Sync Box (device 1301) from its own persisted id". |
| C14 | Director restarted during a session | The box goes on syncing by itself. | Nothing is sent at start. The first read sets the variables, firing events only for a value that differs from the persisted one (motion R4). The proxy is told an input only when Director asks [assumed: Director restores its own path state]. | auto | `SET_INPUT`, `ON`, `OFF` or a sync command at start. | Status "Waiting for the sync box", then the usual text. |
| C15 | Controller replaced or migrated | The encrypted token may not travel (K8). | B5. | offered (Register) | — | As B5. |
| C16 | Update Driver | In place: the device id, the store and the connections stay (K5, K8). | Nothing; but the proxy and the full set of HDMI connections are a one-way door decided before the first release, and a `<capabilities>` change needs the controller rebooted from System Manager (L82). | none | Removing or retyping a connection; changing the proxy. | — |
| C17 | Control4 room renamed | Names from the project. | Labels follow; nothing is keyed by room name. | auto | — | — |
| C18 | Control4 room deleted | Composer's own question about its devices [assumed]. | Nothing for the default (an area's room is its box's, §6). Only with a hand mapping of areas to rooms (Q1's third answer) is a record kept, shown "(Control4 room gone)" and offered for a new room, as for room mappings. | auto; offered | Falling back to another room silently. | As [`scene-rooms-research.md`](scene-rooms-research.md) C21. |
| C19 | Programming names an area or a preset that Hue later changes | The value stored in the programming line (K7). | Resolved when the line runs; a deleted one is logged and nothing is done; a re-made one is offered as E4. | auto; offered | Running another area or preset on a name match by itself. | Attention "Programming on Living Room Sync Box names an entertainment area deleted in Hue (TV area): Set Entertainment Area points it at another". |
| C20 | The Hue Bridge driver deleted, or the box unbound from it | The box's bridge binding goes. | The box keeps switching and syncing (its own API); area names from the box; no marks on lights; not offline. | auto | Setting the box offline for it. | Status "Ready; not bound to a Hue Bridge (area names from the box)". |
| C21 | OS 3.x to 4.x | Nothing recorded changes for the AV switch proxy [assumed]. | Nothing; 4.x-only APIs only behind a version check. | none | — | — |

## 4. Interactions

| # | Case | Driver sees | What it does | Class | Never without a click | Owner sees |
| --- | --- | --- | --- | --- | --- | --- |
| I1 | Control4 selects an input while the box's input switch acts too (a source sends CEC active, or powers up) | `SET_INPUT` for HDMI 1; the next poll shows HDMI 1, or HDMI 2 because the PS5 woke. | Same input: nothing. Another input: no switch back (Q3); the box's input variable changes and an "Input changed on the box" event fires; Status names the setting that did it (B24). | auto; B24's remedy offered | Switching back by itself; counting on `INPUT_OUTPUT_CHANGED` to move Control4's source (K2). | Status "Box switched to HDMI 2 by itself (CEC)". |
| I2 | The TV turned off with its own remote | The box goes to power save (CEC off, F8) or after `inactivePowersave`; `hdmiActive` false. | The box's power variable and its event; nothing sent; Control4's room stays on, since the driver never turns a room off (K2). | auto | Turning the room off; sending anything to other devices. | Status "Box in power save (the TV turned off)". |
| I3 | A source picked in Control4 while the box is in power save | `SET_INPUT`. | One write wakes the box and selects the input (`hdmiActive` and `hdmiSource` together) [assumed: a source alone does not wake it]; then sync as Q2 decides. | auto | — | — |
| I4 | A source with CEC turns the TV on through the box | Nothing (CEC passes through) [assumed]. | Nothing beyond B23 if the box switched. | none | — | — |
| I5 | Room Off during a session | `OFF` or `DISCONNECT_OUTPUT` from Director [assumed: which one, and when; to test]. | Sync stops; on `OFF` the box goes to power save (Q6). The lights then do what Hue's after-sync setting says (E13). | auto | Turning lights off (that is Control4 programming's); powering the box off on its own guess. | Status "Off (Room Off)". |
| I6 | The room changes to a source that does not pass the box | `DISCONNECT_OUTPUT` [assumed]. | Sync stops; HDMI stays on until `OFF`. | auto | — | — |
| I7 | A source picked: start syncing or not | `SET_INPUT`; the box's per-input auto-sync (F8). | Q2 decides; the recommended first default leaves it to the box, so an install changes nothing. | auto (Q2) | Changing the box's auto-sync without a click (B24). | — |
| I8 | A Hue Light device of the area commanded during a session | The light's `mode` `streaming` (H3). | The command goes to the bridge as today (Q4); the device's Status says the lamp follows the TV; the tile shows what the bridge reports, which may not be what the lamp shows (H6, a departure from L6 and L53 to write down). | auto (display); Q4 | Stopping the session without the owner's setting. | Light Status "In a Hue sync session (TV area)". |
| I9 | A zone light, room light or load group with lights of the area | As I8 per member. | As I8; the zone light's Status counts the members in the session. | auto | — | Status "3 of 5 lights in a Hue sync session". |
| I10 | A Hue Scene device recalled during a session | The recall PUT. | As I8; the scene's state follows the bridge's `status.active` as today. | auto | — | As I8. |
| I11 | A Control4 Advanced Lighting Scene recalled during a session | Targets to the Hue Light devices. | As I8; scene tracking may read the scene as active while the lamps show the stream, documented in the manual. | none | — | The manual's note. |
| I12 | Keypad LEDs and tiles bound to lights of the area | The lights' reports. | Nothing new: they follow what the bridge reports. | none | — | — |
| I13 | The room mapping disagrees with the area's lights | Hue room Living maps to Living Room; the area's lights are 4 in Living and 1 in Kitchen; the box is in Den. | Marks only, like Room Audit's; no mapping and no device changes. | auto (display) | Mapping Hue rooms from areas; moving devices. | Area row "TV area: lights in Living Room (4), Kitchen (1); this box is in Den". |
| I14 | The Hue bridge offline while the box answers | The bridge's link offline (K10). | The box stays Online and keeps switching; sync commands report the reason. The box is the one device the bridge outage rule does not take offline. | auto | Setting the box offline for the bridge. | Status "Switching works; Hue bridge not answering since 14:02". |
| I15 | The box offline while Control4 switches | `SET_INPUT` cannot be delivered. | Answered with the last known input; at contact Control4's last input is sent once, only if the room's current video device (K6) is still a source through the box. | auto | Re-sending once the room has moved on; replaying sync commands. | Last Action "Switched Living Room Sync Box to HDMI 1 (Apple TV) when it answered again". |
| I16 | Sync asked for while it cannot happen (no area, area busy, no picture, content the box cannot sync) | The answer after the write: `syncActive` false, `connectionState`, `videoSyncSupported` (F5 to F7). | Reported as not syncing, with the reason. | auto | Choosing an area or a mode instead. | Last Action "Sync not started: HDMI 1 has no picture". |
| I17 | Hue automations act on the area's lights during a session | The automation audit. | Nothing new; the audit's rows stand. | none | — | — |
| I18 | Control4 and the Hue Sync app change the box at the same moment | The box keeps the last write. | A read follows every write; the driver reports what the box says (rule 7). | auto | — | — |

## 5. What the box device shows when something is not known

The AV switch proxy has no online notification [verified: PP
`7_audio_video_switch_protocol_notifications/` lists none], so, as for the
motion sensor, Online is the driver's own variable, row and event pair.

| Reason | Online | Switching | Sync variables | Status | Attention |
| --- | --- | --- | --- | --- | --- |
| No answer yet since the start | unchanged | waits; nothing sent at start | unchanged, no events | "Waiting for the sync box" | — |
| Box away under 5 minutes | unchanged | commands answered with the last known input | unchanged | unchanged | — |
| Box away 5 minutes or more | false, Offline event once | dropped, answered with the last known input | marked old | "Sync box not answering since 14:02" | "Hue sync boxes offline since 14:07: …" |
| Registration refused | false after 5 minutes | dropped | marked old | "Sync box refuses the registration since 14:02" | at once (B5) |
| Another device at its address | false after 5 minutes | dropped | marked old | "Another device answers at 192.0.2.40 since 14:02" | at once (B12) |
| Box in power save | true | wakes on the next `SET_INPUT` | sync false | "Box in power save" | — |
| Box lost its bridge, or cannot reach it | true | works | sync false | B18 or B19 text | B18 at once; B19 after 5 minutes |
| Paired Hue bridge offline (the drivers' link) | true | works | from the box | "Switching works; Hue bridge not answering since 14:02" | the bridge's own item |
| Area deleted in Hue | true | works | sync false | "Entertainment area deleted in Hue; pick another" | at once (E3) |
| Area busy | true | works | sync false | "Not syncing: TV area is in use by another app" | — |
| Not registered yet, or forgotten | false | dropped | — | "Not registered: press its button, then Register Sync Box" / "Forgotten by the bridge" | the unlinked item |
| Two devices claim the box | false | dropped | — | "Another device holds this box (device 1307)" | at once (B29) |

## 6. Entertainment areas and Control4 rooms: what the cases say

The owner's first guess is that an entertainment area maps to a Control4
room. The cases test it:

- **An area is not a room on the Hue side either.** Its lights may come from
  several rooms (E6), one TV or room may have several areas (E7), and two
  boxes may share one area (B27). A mapping from areas to rooms would be
  ambiguous in each of these, and Hue keeps no room for an area at all (H5).
- **What stays put is the TV.** The box that syncs an area sits behind the
  TV, and its Control4 device sits in the TV's room. So the cases fit best
  when an area's Control4 room is **the room of the box device that uses
  it**, derived when shown and never stored: moving the box in Composer
  (C2) moves it, and nothing else has to be kept in step. The lights' own
  Control4 rooms are shown beside it (E5, I13) and never decide anything.
- **Identity is the harder problem, not placement.** Hue makes an area again
  under a new id (E4, E14), and programming lines keep the value they were
  written with (K7, C19). If every programming line held an area id, one
  re-made area would mean finding and editing every line by hand, which is
  the kind of later manual fix the owner's rule calls wrong. Whatever
  programming refers to must therefore be re-pointable in one place:
  - **option A, the default assumed above**: programming names areas
    through the box's own list, and the box keeps, per area it was ever
    pointed at, the id and the name; a re-made area with the same name is
    offered once (E4), and the one click re-points the box's setting and
    the stored reference together;
  - **option B**: an area becomes a Control4 device of its own, placed in
    its box's room, with the scenes' rules (keyed by id, gone and re-link,
    the placement rule of [`scene-rooms-research.md`](scene-rooms-research.md)),
    and programming refers to the device.
  Either way, a name match is only offered, never applied by itself, as for
  scenes and MotionAware areas (M9 in `simplify-actions-design.md` §3.2).
- **The room mappings stay as they are.** Areas never map Hue rooms, a
  mapping never moves a box, and Set Room Mapping knows nothing of areas.

## 7. Not in v1, so that nothing automates them

- Writes to the box beyond the commands and the clicks named here: the
  power-save settings, ARC bypass, solo mode, HDR, LED mode, Wi-Fi,
  Bluetooth, IR codes, firmware updates and restarts.
- Linking the box to a bridge, or to another one (B17, B18): the Hue Sync
  app's job.
- Making, editing or deleting entertainment areas, their lights or their
  after-sync setting (E13).
- Starting or stopping an entertainment session on the bridge directly
  (sync starts and stops only through a box's own API), and the controller
  streaming by itself.
- The Play Screen Sync camera (B30): it has no HDMI to switch.
- Standalone Bluetooth light set-up (B20).
- Bulk adds of boxes: one box, one click (C1).

## 8. Checks before the contract

Every [assumed] above that a decision rests on, in the order they matter.
They need a sync box on the house or at a tester; each is a short read
through a dev build or a scratch script, nothing more than a minute away.

1. What Director sends an AV switch at Room Off and at a change to a source
   that does not pass it: `OFF`, `DISCONNECT_OUTPUT`, both, in which order
   (I5, I6).
2. Whether `hdmiSource` alone wakes a box in power save (I3).
3. During a session: what a REST command to a member light does, and what
   the light resource and the event stream report meanwhile (H6, H7, I8).
4. The bridge's `max_streams` on a Bridge Pro and on a Hue Bridge v2, and
   what the box reads when a second app takes the area (H2, E8).
5. The mDNS TXT records, and whether `GET /api/v1/device` answers without a
   token (F9).
6. The registration window, and code 16 before the button (F3, B4).
7. `uniqueId` after a factory reset (F2, B6), read by the tester or from a
   reset the owner already has to do.

## Recommendations for the design

1. **Nothing is created on its own.** A sync box device is added by a click
   (Add From Hue or Composer), and registration takes the owner's hand on
   the button. Discovery only lists and hints (B1, B7), local only.
2. **Key the box by its `uniqueId`** and treat it as the radio MAC of a
   bulb: the identity check guards the token (B2, B12, C13), the follow-up
   search finds it at a new address by itself (B11), and a reset box is the
   same box (B6). A box with a new `uniqueId` is only suggested (B7, B8).
3. **Copy the bridge's outage and refusal rules per box**: 5 minutes to
   Online false, the key re-check cadence for a refused registration, the
   undelivered answer for a command that did not land (B5, B13, §5).
4. **The bridge outage never takes the box offline** (I14, C20): switching
   is the box's own job, and a TV must keep its sources while the Hue bridge
   reboots.
5. **Follow Director, never steer** (rule 4): carry out `SET_INPUT`, `ON`,
   `OFF` and `DISCONNECT_OUTPUT`; report outside changes in the driver's
   variables and events; no switch back, no room off, no selecting other
   devices (I1, I2, C12).
6. **Treat the box's input switches and auto-sync as Hue automations**:
   show them, put the input switches on Attention, and offer one reversible
   click that hands input selection to Control4 (B24).
7. **One write wakes and selects** (I3); every write is followed by a read,
   and the box's answer is the state reported (I18).
8. **Decide the proxy, the HDMI connections and the capabilities once,
   before the first release** (C16, K4, K5): four HDMI inputs and one output
   even for a one-input model (B9), since connections can only be added and
   a capability change costs a controller reboot.
9. **Read HDMI connections on demand** (late init, `OnPIP`, each
   `SET_INPUT`), never expect a callback for them (C6, K3), and cross-check
   them with the box's HDMI status as a hint only.
10. **Give the bridge the light `mode`** (H3): mark Hue Light, zone light and
    Hue Scene devices in a session on their Status, and write the
    departure from L53 into `docs/c4-lighting-guidelines.md` (I8 to I11).
11. **An area's Control4 room is its box's room**, derived, not stored; the
    lights' rooms are information (§6, E6, I13). Room mappings stay as they
    are.
12. **Make every reference to an area or a preset re-pointable in one
    place** (option A or B of §6), offer the same-name successor once, and
    never apply a name match by itself (E4, B26, C19).
13. **Never write a box's bridge link, an area, or another app's session**
    (rule 8, B17, E8, §7).
14. **Leave the registration on the box when the device is deleted in
    Composer, remove it on Forget Device**, and name every registration after
    its Control4 device so the owner can clean up in the Hue Sync app (B3,
    C4, C5).
15. **Fire no events at start for what did not change** (C14), as motion
    does: a Director restart during a film must not run "sync started"
    programming again.

## Open questions for the owner

Each has a recommended answer first.

1. **Where does an entertainment area live in Control4?** **In the room of
   the sync box that uses it, derived from the box device, with areas
   picked from the box's own list (§6 option A)**; or each area as a
   Control4 device placed in its box's room (option B); or the first guess
   as asked, a hand mapping from areas to Control4 rooms (which E6, E7 and
   B27 make ambiguous).
2. **Does picking a source in Control4 start syncing?** **Leave it to the
   box's per-input auto-sync at first, so an install changes nothing, and
   offer (B24) to move it to a Control4 setting per input**; or a Control4
   setting from the start, with the box's auto-sync switched off by a click.
3. **When the box switches input by itself (CEC, hot-plug)**: **report it
   and offer to switch the box's input-follow off, never switch back**; or
   switch back to Control4's input after a few seconds.
4. **A Control4 command to a light that is in a sync session**: **send it as
   today and say on the light's Status that the lamp follows the TV**; or
   stop the session first so the command shows (which also lets timed
   programming end a film's sync).
5. **Two-way names for sync boxes**, as 1.2 decided for lights, scenes and
   motion sensors (D6): **yes, for the box's name; input names only
   offered**; or Composer names only.
6. **Room Off**: **stop syncing and put the box in power save**; or stop
   syncing and keep HDMI passing through.
