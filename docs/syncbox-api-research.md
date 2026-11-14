# Hue Play HDMI Sync Boxes: the box and its local API (research)

**Status (2026-11-13): research R1 for issue #514, the sync box itself.
Read-only; nothing here is approved or built.** It covers every sync box
model, the box's local HTTPS API, its link to the Hue Bridge, what it does by
itself over HDMI CEC, and what a Control4 driver needs from each. The Control4
side (proxies, connections, room routing) and the bridge side belong to the
other research files of #514 and then to the feature's contract.

Nothing was checked against a box. This research contacted no LAN host, and
which boxes the house owns is not known (open question 1). Signify's API
reference needs a developer login and was not read (§8, P8). Every API fact
below comes from code that talks to real boxes, from Signify's public pages,
or from community reports.

Markers:

- **[verified: S]**: shown by source S (§8). That is library code that runs
  against real boxes (aiohuesyncbox, Home Assistant's huesyncbox integration,
  openHAB's huesync binding, the Homebridge plugin), a Philips Hue page, a
  file of this repository or of the DriverWorks reference. "S1
  `models/hue.py:92`" means that file and line at the commit named in §8.
- **[community: S]**: reported by a user, a review or a news site, or seen
  only in a search result's summary. Plausible, not shown by code. Treat it as
  assumed when designing.
- **[assumed]**: reasoning or analogy, for the first hardware test to confirm.

aiohuesyncbox's docstrings and its API-level-7 test fixture were written from
Signify's login-only reference (S1 `tests/test_compatibility.py:6`). This file
paraphrases them and copies nothing. Placeholders: 10.0.2.143 for a box or
bridge address, 001788fffe123abc for a bridge id, `<box id>` for a box's
12-digit id.

## Summary

1. **Four devices speak one local API.** Three are HDMI sync boxes: the
   original four-input box (`HSB1`, 2019), the four-input 8K box (`HSB2`,
   September 2024) and the single-input 4K box (`HSB3`, September 2026). The
   fourth is the Play Screen Sync camera (`HSC001`, September 2026), which has
   no HDMI at all (§1).
2. **Signify now calls the original box "4K" too.** Its release notes name
   the 2026 box "4K (2026)", and one retailer sells that one as "Sync Box
   Lite". A driver must go by the `deviceType` the box reports, never by a
   product name (§1.2).
3. **Transport:** HTTPS on port 443, JSON under `/api/v1`, and an
   `Authorization: Bearer <token>` header. One GET of `/api/v1` returns every
   resource at once. Commands are PUTs of partial objects (§2.1, §2.4).
4. **Certificate:** the box's certificate chains to a private Philips Hue
   root, `CN=root-hsb`. Its leaf names the box's 12-digit id, not its address.
   That is the bridge's pattern, so the bridge driver's CA pinning carries
   over (§2.1).
5. **Discovery:** mDNS service `_huesync._tcp.local`, with TXT records `name`,
   `devicetype`, `uniqueid` and `path=/api`. The bridge driver's unicast mDNS
   module can ask for it (§2.2).
6. **Pairing:** an unauthenticated POST to `/api/v1/registrations` answers
   code 16 "Invalid State" until someone holds the box's button for about
   3 seconds. The next POST returns a registration id and an access token. No
   expiry is known; the token lasts until its registration is deleted (§2.3).
7. **No push of any kind.** No client uses an event stream, long-poll or
   webhook; all of them poll, every 3 to 10 seconds. The bridge's own event
   stream does show when an entertainment area starts or stops streaming,
   which can stand in for part of the polling (§2.12, §3).
8. **One request at a time.** No rate limit is published. Every client keeps
   to one connection or one request in flight, and aiohuesyncbox says the box
   handles few connections (§2.13).
9. **The box acts on its own over HDMI.** It switches input when a source
   sends CEC Active Source or is plugged in or powered on. It starts syncing
   when a source links. It goes to powersave on the TV's CEC standby, on loss
   of the TV's USB power, or after 20 idle minutes. Each is a `behavior`
   setting. Control4 will be switching too, so the driver must follow the
   box's `hdmiSource` and only offer to turn these off (§4).
10. **The bridge link.** The box links to one bridge at a time and streams to
    one of that bridge's entertainment areas, named by its CLIP v2
    `entertainment_configuration` id. It refuses with code 16 while another
    app streams to the bridge. The 8K box, the 2026 4K box and the camera can
    also sync one light over Bluetooth without a bridge (API level 14) (§3).

## 1. The models

### 1.1 Overview

| Device | `deviceType` | On sale | HDMI in / out | Video | HDR | Gaming | ARC / eARC | CEC | IR | Radios | Power | Without a bridge |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Play HDMI Sync Box (original) | `HSB1` | 2019; sold out by February 2026 | 4 / 1 | 4K 60 Hz; 1080p and 1440p at 120 Hz | HDR10+, Dolby Vision | FreeSync (firmware 1.6.3) | ARC pass-through only | yes | yes | Wi-Fi; Bluetooth 4.2 for setup | 24 V adapter; can sense the TV's USB power | no |
| Play HDMI Sync Box 8K | `HSB2` | September 2024 | 4 / 1 | 8K 60 Hz, 4K 120 Hz, 4K 60 Hz, 1080p 120 Hz; DSC for 8K 60 Hz, 3D pass-through and 144 Hz light sync since 2.5.0 | HDR10+, Dolby Vision | VRR and ALLM reported | ARC and eARC pass-through | yes | yes | Wi-Fi; Bluetooth 5 for setup | 12 V adapter; reports under-voltage | yes, one light |
| Play HDMI Sync Box 4K (2026) | `HSB3` | September 2026 | 1 / 1 | 4K 60 Hz; 1440p 120 Hz | HDR10+, Dolby Vision | not stated | not stated | yes | no | Bluetooth; Wi-Fi not stated | USB-C adapter | yes, one light |
| Play Screen Sync (camera) | `HSC001` | September 2026 | none: a camera on the TV | — | — | — | — | — | — | Bluetooth; network not stated | not stated | yes, one light |

Sources, row by row:

- **HSB1.** Four inputs, the 4K and 120 Hz formats, HDR10+ and Dolby Vision,
  CEC, IR, Bluetooth 4.2, the 24 V adapter, and "no longer available"
  **[verified: P5]**. First public firmware 1.2.2 on 2019-11-26; HDR10+ in
  1.3.2 and 1.4.7, Dolby Vision in 1.4.7, FreeSync in 1.6.3 **[verified:
  P1]**. ARC only **[verified: P6]**. Sold out **[verified: H8]**. Its old
  power supply has three plugs, so it can also feed two Play light bars
  **[community: H1]**. USB power sensing **[verified: S1
  `models/behavior.py:76-77`]**. HDMI 2.0, by Signify's name for the "4K" box
  **[community: P4 FAQ, which does not say which 4K box it means]**. Plain
  HDR10 is not named on any page; that it works is **[assumed]**.
- **HSB2.** HDMI 2.1 certified, the resolutions, HDR10+, Dolby Vision, CEC,
  IR, Bluetooth 5, 12 V, Dolby Atmos **[verified: P2, P3]**. Four inputs and
  one output **[verified: P3 FAQ; the page's "5 HDMI ports" counts the
  output]**. eARC and ARC **[verified: P6]**. DSC, 3D and 144 Hz in 2.5.0;
  ARC bypass fixed in 2.4.2 **[verified: P1, H3]**. VRR and ALLM "should work"
  **[community: N2]**. Launched September 2024, first update 2.4.2
  **[verified: H2]**; revealed in February 2023 **[community: H1]**.
  Under-voltage flag **[verified: S1 `models/device.py:81-82`]**. Works
  without a bridge with one light **[verified: P7; S1 `models/hue.py:9`]**.
- **HSB3.** One input, HDMI 2.0, 4K 60 Hz and 1440p 120 Hz, Dolby Vision,
  HDR10+, Bluetooth **[verified: P4]**. Hueblog gives 120 Hz at Full HD only
  **[community: H4]**. No IR **[community: H4]**. USB-C adapter, one sync per
  bridge, up to 10 lights with a bridge **[community: H6]**. Bridge-free
  Bluetooth sync **[community: H5, N1; verified: S1 `models/hue.py:92`]**. CEC
  is not stated on P4, but the box has per-input CEC behaviour **[verified:
  S1 `models/behavior.py:35`]**.
- **HSC001.** Camera above the TV; it works with the TV's own apps because it
  does not read HDMI **[community: N1]**. Same API family **[verified: S2
  `README.md:27-30`; S1 releases v0.1.2]**. Bridge-free **[community: N1,
  H5]**.

### 1.2 What a box reports about itself

- **`device.deviceType`**: `HSB1`, `HSB2`, `HSB3` or `HSC001` **[verified: S2
  `helpers.py:32-35`]**. aiohuesyncbox writes the camera as `HSC1` **[verified:
  S1 `models/hue.py:9`]**. Treat any value starting with `HSC` as the camera,
  as Home Assistant does **[verified: S2 `switch.py:42`]**.
- **`device.uniqueId`**: 12 upper-case hex digits without separators. The same
  id is on the label, is the certificate's common name and is the mDNS host
  name **[verified: S1 `models/device.py:51-54`]**. Home Assistant treats it as
  the box's MAC address **[verified: S2 `helpers.py:39-42`]**.
- **`device.apiLevel`** (rises when the API changes), **`firmwareVersion`**
  (`major.minor.patch`) and **`buildNumber`** (always higher for a newer
  build) **[verified: S1 `models/device.py:58-63`]**.
- **The mDNS `devicetype` TXT value** reads `HSB1` in openHAB's capture
  **[verified: S3 `README.md:46`]**, but a Home Assistant code comment says
  `HSB001` **[verified: S2 `config_flow.py:203`]**. The two disagree, so read
  `device.deviceType` instead.
- **Retail codes** (for a receipt or a box label; the API never reports them
  **[assumed]**). Each region has its own 12NC.

  | Box | EAN / UPC | 12NC | Source |
  | --- | --- | --- | --- |
  | HSB1, US | 046677555221 | 929002275801 | **[verified: P5]** |
  | HSB2, US | 046677579753 | 929003499602 | **[verified: P2]** |
  | HSB2, Singapore | 8719514458680 | 929003499604 | **[verified: P9]** |
  | HSB3, US | 046677610616 | 929004315001 | **[verified: P4]** |

  Nothing shows that regional variants differ except in plug and adapter
  **[assumed]**.

### 1.3 Firmware and API levels

- **Firmware lines** **[verified: P1]**:
  - 1.x, 2019 to 2021, the original box only (1.2.2 to 1.8.3).
  - 2.x from 2023: the original box, and the 8K box from 2.4.2 (December
    2024). 2.5.4 (September 2025) added Bridge Migration on both.
  - 3.x on the 2026 4K box: 3.5.2 on 2026-10-06.
  - Updates install from the Hue app or automatically at a set UTC hour
    (`device.update`) **[verified: S1 `models/device.py:16-21`]**.
- **API levels.** Levels below 7 are no longer documented; every library
  requires 7 or later, which firmware had by May 2021 at the latest
  **[verified: S1 releases v0.1.3; S1 `huesyncbox.py:33`; S3
  `HueSyncConstants.java:76`]**. What each later level added **[verified:
  S1 models]**:
  - **Level 10**: `hue.groupId`, the per-input `hpdInputPortSwitch`,
    `device.overheating`, `device.bluetooth`, and a registration's `verified`
    flag.
  - **Level 14**: `hue.operatingMode`, the Bluetooth light fields,
    `behavior.soloMode`, and `device.undervolt` (8K only).
- Which firmware version carries which level is not public **[assumed]**.

### 1.4 Differences that matter to a controller

| Difference | HSB1 | HSB2 | HSB3 | HSC001 | Source |
| --- | --- | --- | --- | --- | --- |
| HDMI inputs in `hdmi` | 4 | 4 | 1 | no `hdmi` resource | **[verified: S1 `models/hdmi.py:50-54`, releases v0.1.2]** |
| Power on/off (powersave) | yes | yes | yes | no | **[verified: S2 `switch.py:42`]** |
| `ir` resource | yes | yes | no IR hardware | optional | **[verified: S1 `huesyncbox.py:177-181`; community: H4]** |
| `usbPowersave`, `hpdInputSwitch` | yes | yes | no | no | **[verified: S1 `models/behavior.py:76-79`]** |
| `hdrMode`, `forceDoviNative` | yes | no | no | no | **[verified: S1 `models/behavior.py:41-42, 84-85`]** |
| `behavior.input2`–`input4` | yes | yes | no | no | **[verified: S1 `models/behavior.py:35`]** |
| Bridge-free mode, `operatingMode` | no | yes | yes | yes | **[verified: S1 `models/hue.py:92`]** |
| `undervolt` | no | yes | no | no | **[verified: S1 `models/device.py:81-82`]** |
| eARC pass-through | no | yes | not stated | — | **[verified: P6]** |

### 1.5 What each device's API exposes

All four answer the same API, and Home Assistant's integration supports all
four through one code path **[verified: S2 `README.md:25-30`,
`helpers.py:30-37`]**. aiohuesyncbox made `behavior`, `hdmi`, `ir`,
`execution.hdmiActive` and `execution.hdmiSource` optional in 0.1.2, "to work
with" the Screen Sync camera and the one-input 4K box **[verified: S1 releases
v0.1.2; `huesyncbox.py:160-181`; `models/execution.py:95-98`]**. Which of
these each device leaves out is not shown by any dump, so the per-device lists
below mark that **[assumed]** where the code only allows it.

- **HSB1, the original box (4 inputs).** Every resource: `device`,
  `execution`, `hdmi` with `input1` to `input4` and `output`, `behavior` with
  all four inputs, `hue`, `ir`, `registrations` and `presets`. This is the
  shape of Signify's level-7 example **[verified: S1
  `tests/test_compatibility.py:8-163`, `deviceType` `HSB1`]**. Only this box
  has `hdrMode` and `forceDoviNative` **[verified: S1
  `models/behavior.py:41-42, 84-85`]**. It has no bridge-free mode, so no
  `operatingMode` or Bluetooth light fields **[verified: S1
  `models/hue.py:92-100`, "HSB2/HSB3/HSC1 only"]**.
- **HSB2, the 8K box (4 inputs).** The same resources and four inputs
  **[verified: S1 `models/behavior.py:35`, "4 hdmi input subresources for
  HSB1 & HSB2"]**. It adds `undervolt` **[verified: S1
  `models/device.py:81-82`]**, `soloMode` **[verified: S1
  `models/behavior.py:82-83`]** and the bridge-free fields (§3).
  It keeps `usbPowersave` and `hpdInputSwitch` **[verified: S1
  `models/behavior.py:76-79`]**.
- **HSB3, the 2026 4K box (1 input), on sale from 2026-09-03** **[community:
  N1]**.
  - **The single input.** `hdmi` holds `input1` and `output` only, and
    `behavior` holds only `input1` **[verified: S1 `models/hdmi.py:51-54`;
    `models/behavior.py:35`, "for HSB3 only 1 hdmi input subresource"]**.
    `usbPowersave` and `hpdInputSwitch` are absent: they are HSB1 and HSB2
    only **[verified: S1 `models/behavior.py:76-79`]**. Home Assistant offers
    no input choice when there is no `input2` **[verified: S2
    `select.py:72-74`]**, but keeps the power switch **[verified: S2
    `switch.py:42`]**. `execution.hdmiSource` presumably stays `input1`
    **[assumed]**. No IR hardware **[community: H4]**, so `ir` is probably
    absent or empty **[assumed]**.
  - **Without a bridge.** From API level 14, `hue.operatingMode` reads
    `standalone` or `bridge`, and `hue.bleConnectionState` and
    `hue.bleEntertainmentLights` describe the Bluetooth light it syncs
    **[verified: S1 `models/hue.py:9-27, 92-100`]**. Without a bridge it syncs
    one light; with a Hue Bridge or Bridge Pro, an area of up to 10
    **[verified: P7; community: H5, N1]**. In standalone mode Home Assistant
    drops the area choice and the bridge status and id **[verified: S2
    `select.py:150`, `sensor.py:60, 67`, `helpers.py:120-121`]**. It adds or
    removes them while running when the mode changes, so a box can move
    between the two modes at any time **[verified: S2 `coordinator.py:68-75`]**.
    In standalone mode `hue.groups` is presumably empty and `hueTarget`
    meaningless **[assumed]**.
- **HSC001, the Play Screen Sync camera.** **Yes, it shares the sync box API**
  **[verified: S2 `README.md:30`, `helpers.py:35`; S1 `README.md:3`, "box and
  screen sync"]**.
  - It has no HDMI, so `hdmi` and the HDMI fields of `execution` are
    presumably absent **[assumed from S1 0.1.2]**. Home Assistant gives it no
    power switch: the power entity is dropped for any `deviceType` starting
    with `HSC` **[verified: S2 `switch.py:42`]**. Its HDMI status sensors
    appear only when `hdmi` exists **[verified: S2 `sensor.py:79`]**.
  - It keeps sync on and off, mode, intensity, brightness and, with a bridge,
    the area choice **[verified: S2 `switch.py:44-49`, `select.py:137-172`;
    that they work on the camera: assumed]**.
  - It has the bridge-free fields **[verified: S1 `models/hue.py:92`]**.
  - aiohuesyncbox calls it `HSC1` and Home Assistant `HSC001` (§1.2).
  - That it advertises `_huesync._tcp.local` like the boxes is **[assumed]**:
    Home Assistant lists that one service and says devices are usually found
    by themselves **[verified: S2 `manifest.json:17`, `README.md:170`]**.

## 2. The local API

### 2.1 Transport and certificate

- **URL**: `https://10.0.2.143:443/api/v1/<resource>`, with sub-resources
  below some resources **[verified: S1 `huesyncbox.py:46-47, 199`; S3
  `HueSyncConnection.java:57-63`]**. The `/api` part comes from the mDNS
  `path` record **[verified: S2 `config_flow.py:196-201`]**.
- **Body**: JSON both ways; a PUT carries only the fields it changes
  **[verified: S1 `huesyncbox.py:204`, `models/base.py`]**.
- **Authentication**: `Authorization: Bearer <access token>` **[verified: S1
  `huesyncbox.py:205-206`; S4 `client.ts`]**. The token looks like base64
  text **[community: C2]**.
- **The root CA** ships in aiohuesyncbox (Apache-2.0) **[verified: S1
  `hsb_cacert.py`, decoded with `openssl x509`]**:
  - subject and issuer `C=NL, O=Philips Hue, CN=root-hsb`, so it is
    self-signed;
  - valid from 2017-01-01 to 9999-12-31;
  - an ECDSA P-256 key, a CA certificate, serial 1.

  It is a different root from the bridge's two (`src/hue_bridge/certs/`)
  **[verified: R1]**.
- **The leaf** names the box's `uniqueId` as its common name **[verified: S1
  `models/device.py:51-54`]**. aiohuesyncbox therefore connects by IP, sends
  the id as the TLS server name, and lets the common name match
  **[verified: S1 `huesyncbox.py:86-87, 213`]**. Whether an intermediate CA
  sits between the leaf and `root-hsb`: **[assumed: no]**, since the library
  trusts that one certificate and nothing else.
- **Other clients verify less.** Homebridge and a Homey script turn
  verification off **[verified: S4 `client.ts`; community: C1]**. openHAB
  trusts whatever certificate the box shows on first contact **[verified: S3
  `HueSyncTrustManagerProvider.java:38`]**.
- **HTTP status codes** **[verified: S3 `HueSyncConnection.java:180-190`]**:
  - 200: success;
  - 400: invalid state, for example a registration waiting for the button;
  - 401: missing or invalid token;
  - 404: unknown path;
  - 500: internal error.

  A non-200 answer carries `{"code": n, "message": "..."}` **[verified: S1
  `huesyncbox.py:219-226, 239-241`]**.
- **Without a token**, GET `/api/v1/device` still answers with enough to
  identify the box: name, `deviceType`, `uniqueId`, `apiLevel`,
  `firmwareVersion`, `buildNumber`, `wifiState`, `ipAddress`, `capabilities`
  and a few flags. Everything else needs the token **[verified: S3
  `HueSyncConnection.java:183-185`, `HueSyncDeviceConnection.java:147-148`,
  `HueSyncDevice.java`]**. aiohuesyncbox tests a token with GET
  `/registrations`; a 401 means not registered **[verified: S1
  `huesyncbox.py:112-117`]**.

### 2.2 Discovery

- **mDNS service** `_huesync._tcp.local.` **[verified: S1
  `example_zeroconf.py:27`; S2 `manifest.json:17`; S3
  `HueSyncDiscoveryParticipant.java:61`]**.
- **Records** **[verified: S3 `README.md:40-46`]**:
  - instance `HueSyncBox-<box id>`;
  - host `<box id>.local`;
  - port 443;
  - TXT `name` (the friendly name), `devicetype`, `uniqueid` and `path=/api`.

  Home Assistant takes the address, port, `uniqueid`, `path` and `name` from
  them **[verified: S2 `config_flow.py:196-211`]**.
- **By hand**: the address and the id are in the Hue app, under the Sync tab
  ▸ … ▸ Device ▸ Network info and Device info **[verified: S2
  `translations/en.json:17`]**.
- The Hue bridge does not list the box among its devices **[assumed]**.
- The bridge driver already sends a legacy unicast mDNS query for
  `_hue._tcp.local` and reads TXT records (`src/hue_bridge/bridge/mdns.lua:49,
  146`) **[verified: R1]**. That the same code finds `_huesync._tcp.local`
  with only the name changed is **[assumed]**.

### 2.3 Registration and pairing

- **Request**: POST `/api/v1/registrations` without a token, with
  `appName` (the application) and `instanceName` (the user or the device)
  **[verified: S1 `models/registrations.py:31-37`,
  `controllers/registrations.py`]**.
- **Before the button**: 400 with code 16, "Invalid State" **[verified: S3
  `HueSyncConnection.java:181`; community: C1, S4 README]**.
- **The button**: hold it about 3 seconds, until the LED blinks green
  **[verified: S3 `README.md:57`; S2 `translations/en.json:33`]**. Send the
  same POST again within about 5 seconds **[community: S4 README, C1]**.
  Home Assistant simply repeats the POST once a second until it succeeds
  **[verified: S2 `config_flow.py:244-250`]**. Starting that loop the moment a
  box is discovered "seems to get stuck", so Home Assistant waits for a click
  first **[verified: S2 `config_flow.py:217-218`]**.
- **Preconditions**: the box on and not syncing **[community: S4 README,
  C1]**.
- **Answer**: `registrationId` and `accessToken` **[verified: S1
  `models/registrations.py:41-45`]**.
- **Lifetime**: no expiry is known; a token works until its registration is
  removed **[community: C1]**. When a token stops working, the box answers
  401 and Home Assistant asks for the button again **[verified: S2
  `coordinator.py`, `except aiohuesyncbox.Unauthorized`]**.
- **Revocation**: DELETE `/registrations/<id>`, and only with that
  registration's own token **[verified: S1 `huesyncbox.py:139-141`]**. Home
  Assistant tries this when the integration is removed **[verified: S2
  `__init__.py:94-108`]**.
- **The list**: GET `/registrations` shows every app with its name, instance,
  creation and last-use times, role (`admin` or `user`) and, from level 10, a
  `verified` flag **[verified: S1 `models/registrations.py:8-25`]**. In
  Signify's example the Hue app holds the admin role **[verified: S1
  `tests/test_compatibility.py:154-161`]**. Which role a third-party
  registration gets, and what a `user` may not do: **[assumed: `user`, and it
  may do everything a driver needs; Home Assistant changes the bridge with
  one]**.
- **Not known**: how many registrations a box keeps, whether the Hue app can
  remove one, and whether a factory reset clears them **[assumed: yes to
  the last]**.

### 2.4 Resources

| Path | GET | PUT | POST | DELETE | Holds |
| --- | --- | --- | --- | --- | --- |
| `/api/v1` | yes | — | — | — | every resource below, in one answer |
| `/device` | yes (part without a token) | name, LED mode, action, auto-update, Bluetooth | — | — | identity, firmware, Wi-Fi, health |
| `/execution` | yes | yes | — | — | what the box is doing now |
| `/hdmi` | yes | port names and types **[assumed path]** | — | — | ports and the current signal |
| `/behavior` | yes | yes | — | — | what the box does by itself |
| `/hue` | yes | bridge, area | — | — | the bridge link and its areas |
| `/hue/groups/<id>` | — | `active: false` | — | — | stops a stream to that area |
| `/ir`, `/ir/scan`, `/ir/codes/<code>` | yes | scan, code mapping | — | a code | IR remote codes |
| `/registrations` | yes | — | new registration | `/<id>` | apps that may use the box |
| `/presets` | yes | `/<id>` | new preset | `/<id>` | stored executions |

Sources: the paths are in S1 `controllers/*.py`, the root GET in S1
`huesyncbox.py:156`, the top-level keys in S1 `huesyncbox.py:159-183`
**[verified]**.

### 2.5 `device`

- **Fields** **[verified: S1 `models/device.py`; S3 `HueSyncDevice.java:55,
  63`]**:
  - identity: `name`, `deviceType`, `uniqueId`, `ipAddress`;
  - firmware: `apiLevel`, `firmwareVersion`, `buildNumber`, the version and
    build available to install (empty when current), `lastCheckedUpdate`,
    and `update` (auto-update on or off, and the UTC hour);
  - network: `wifiState` (`uninitialized`, `disconnected`, `lan`, `wan`) and
    `wifi` (SSID, strength 0 to 4);
  - health: `temperature`, `overheating` (level 10), `undervolt` (8K, level
    14);
  - other: `ledMode` (0 off, 1 normal, 2 dimmed), `action`, `pushlink`
    (`idle` in the example; its other values are unknown), `bluetooth`
    (level 10), `capabilities` (the most IR codes and presets: 24 and 16 in
    the example), `termsAgreed`, `beta`.
- **Writable**: `name`, `ledMode`, `action`, `update` and `bluetooth`
  **[verified: S1 `models/device.py:33-40`]**. The actions are
  `doSoftwareRestart`, `doFirmwareUpdate` and `checkForFirmwareUpdates`
  **[verified: S1 `models/enums.py:46-50`]**; a restart is PUT `/device`
  `{"action": "doSoftwareRestart"}` **[community: C2]**.
- **Wi-Fi only**: no page lists an Ethernet port **[verified: P2–P5]**. The
  original box is limited to 2.4 GHz networks **[community: search summary of
  Philips support pages; not read]**.

### 2.6 `execution`

- **State** **[verified: S1 `models/execution.py:78-100`]**:
  - `mode`: `powersave`, `passthrough`, `video`, `game` or `music`;
  - `syncActive`: true only while syncing (video, game, music);
  - `hdmiActive`: false only in powersave;
  - `hdmiSource`: `input1` to `input4`;
  - `hueTarget`: the entertainment area;
  - `brightness`: 0 to 200, where 100 leaves the picture's brightness as it
    is;
  - `lastSyncMode`;
  - one object per mode: `video` and `game` hold `intensity` and
    `backgroundLighting`; `music` holds `intensity` and `palette`;
  - `preset`.
- **Values** **[verified: S1 `models/enums.py:79-124`]**:
  - intensity: `subtle`, `moderate`, `high`, `intense`;
  - palette: `happyEnergetic`, `happyCalm`, `melancholicCalm`,
    `melancholicEnergetic`, `neutral`.

  One community post also names an `ambient` mode, which no library lists
  **[community: C1]**. aiohuesyncbox maps any value it does not know to
  "unknown" and keeps working **[verified: S1 `models/enums.py:11-19`]**.
- **What the commands do**:
  - Power on means passthrough; power off means powersave. Home Assistant
    writes `mode` for its power switch **[verified: S2 `switch.py:33-41`]**
    and `hdmiActive` in its combined action **[verified: S2
    `services.py:129`]**.
  - `syncActive: true` starts syncing in the mode the current input used
    last; `false` goes to passthrough **[verified: S3 `README.md:103`]**.
  - Turning sync on, or choosing a sync mode, also powers the box on
    **[verified: S2 `README.md:64-65`, as observed by its author]**.
  - `intensity` applies to the current mode. To change both, send the mode
    first, or both in one PUT, as Home Assistant's combined action does
    **[verified: S2 `README.md:66`, `services.py:128-160`]**.
  - Fields that exist only as commands **[verified: S1
    `models/execution.py:36-75`, `controllers/execution.py`]**:
    `toggleSyncActive`, `toggleHdmiActive`, `cycleSyncMode` and
    `cycleHdmiSource` (`next` or `previous`), `incrementBrightness` (−200 to
    200), `cycleIntensity`, `toggleSyncMode` (enters the given mode unless it
    is already on), `backgroundLighting`, `toggleBackgroundLighting`, and
    `preset` (runs a preset).
  - An empty PUT is refused with code 13, "Invalid Key" **[verified: S2
    `services.py:161-166`]**.
- **`hueTarget`** names one of the areas in `hue.groups`. With a CLIP v2
  bridge it is an `entertainment_configuration` id (a UUID). With an older
  bridge it is `groups/<n>` **[verified: S1 `models/execution.py:72-73`; S2
  `select.py:84`, `helpers.py:103-106`]**. An id that is not in `hue.groups`
  is refused **[community: S4 README]**, reportedly with code 15 **[community:
  C6]**.

### 2.7 `hdmi`

- **Ports**: `input1` (`input2` to `input4` only on four-input boxes) and
  `output`. Each has `name` and `type` (set by the user), `status` and
  `lastSyncMode` **[verified: S1 `models/hdmi.py:9-54`]**.
  - The 26 types: `generic`, `video`, `game`, `music`, `xbox`,
    `playstation`, `nintendoswitch`, `phone`, `desktop`, `laptop`, `appletv`,
    `roku`, `shield`, `chromecast`, `firetv`, `diskplayer`, `settopbox`,
    `satellite`, `avreceiver`, `soundbar`, `hdmiswitch`, `tv`, `monitor`,
    `beamer`, `speaker`, `hdmisplitter` **[verified: S1
    `models/enums.py:138-167`]**.
  - The statuses: `unplugged`, `plugged`, `linked`, `unknown` **[verified: S1
    `models/enums.py:170-174`]**. **[assumed]**: `plugged` means the source's
    hot-plug or +5 V is seen, and `linked` means a signal is locked.
- **The signal**: `contentSpecs` is text with resolution, frame rate in mHz
  and HDR format, like `3840 x 2160 @ 60000 - SDR`. `videoSyncSupported` and
  `audioSyncSupported` say whether the signal can be synced **[verified: S1
  `models/hdmi.py:44-49`, `tests/test_compatibility.py:108`]**.
- Port names and types are writable in the library's model, but nothing calls
  that, so the path is **[assumed: PUT `/hdmi/<port>`]** **[verified: S1
  `models/hdmi.py:32-37`]**.

### 2.8 `behavior`

All flags are 0 or 1 in the JSON, not true or false **[verified: S1 releases
v0.1.7; `models/behavior.py:9-24`]**.

| Setting | Scope | What the box does | Models | Source |
| --- | --- | --- | --- | --- |
| `inactivePowersave` | box | powersave after this many minutes in passthrough without a link; 0 off, up to 10000, 20 by default | all boxes | **[verified: S1 `models/behavior.py:72-73`]** |
| `cecPowersave` | box | powersave when the TV sends CEC standby | all boxes | **[verified: S1 `models/behavior.py:74-75`]** |
| `usbPowersave` | box | powersave when the TV's USB port loses its 5 V | HSB1, HSB2 | **[verified: S1 `models/behavior.py:76-77`]** |
| `hpdInputSwitch` | box | switch to any source that is plugged in or powers on | HSB1, HSB2 | **[verified: S1 `models/behavior.py:78-79`]** |
| `arcBypassMode` | box | hides the box's CEC address from source and TV; only for a box between an AV receiver and the TV | all boxes | **[verified: S1 `models/behavior.py:80-81`]** |
| `soloMode` | box | for a box fed from an AV receiver's second output with nothing on its own output (level 14) | all boxes | **[verified: S1 `models/behavior.py:82-83`]** |
| `forceDoviNative` | box | forces Dolby Vision native mode when the TV offers it | HSB1 | **[verified: S1 `models/behavior.py:84-85`]** |
| `cecInputSwitch` | input | switch to this input when its source sends CEC Active Source | all boxes | **[verified: S1 `models/behavior.py:37-38`]** |
| `linkAutoSync` | input | start syncing when this input and the output link | all boxes | **[verified: S1 `models/behavior.py:39-40`]** |
| `hpdInputPortSwitch` | input | switch to this input when its source is plugged in or powers on (level 10) | all boxes | **[verified: S1 `models/behavior.py:43-44`]** |
| `hdrMode` | input | HDR compensation while syncing: 0 auto, 1 force SDR, 2 force HDR | HSB1 | **[verified: S1 `models/behavior.py:41-42`]** |

Signify's example also shows `hpdOutputEnableMs` (1500) **[verified: S1
`tests/test_compatibility.py:117`]**; what it does is **[assumed: a delay
before the box raises hot-plug on its output]**.

### 2.9 `hue`

- **State** **[verified: S1 `models/hue.py:45-101`]**:
  - `bridgeUniqueId`, `bridgeIpAddress`;
  - `connectionState`: `uninitialized`, `disconnected`, `connecting`,
    `unauthorized`, `connected`, `invalidgroup`, `streaming` or `busy`
    **[verified: S1 `models/enums.py:56-64`]**;
  - `groups`: the bridge's entertainment areas by id, each with `name`,
    `numLights`, `active` and, while active, `owner`;
  - `groupId`, the selected area (level 10);
  - `operatingMode` (`bridge`, `standalone`, `uninitialized`) and the
    Bluetooth fields (level 14).
- **Change the bridge**: PUT `/hue` with `bridgeUniqueId`, `username` (an
  application key on that bridge) and `clientKey` (32 hex digits, the
  streaming key) **[verified: S1 `models/hue.py:69-79`, `controllers/hue.py:67`]**.
  The change takes about 15 seconds and passes through `connecting` and
  `disconnected`. It ends `connected`, or `invalidgroup` until an area is
  chosen again **[verified: S1 `README.md:21-31`; S2 `README.md:80`]**.
- **Choose an area**: PUT `/hue` `{groupId}` (level 10) or PUT `/execution`
  `{hueTarget}` **[verified: S1 `controllers/hue.py:63`, `models/execution.py:72`]**.
- **Stop a stream**: PUT `/hue/groups/<id>` `{"active": false}` stops
  whoever streams to that area **[verified: S1 `controllers/hue.py:58-61`]**.
- **The Bluetooth light fields** include a key that Home Assistant hides from
  its diagnostics as a secret **[verified: S1 `models/hue.py:23-27`; S2
  `diagnostics.py:14`]**. A driver should never write or log them.

### 2.10 `ir`

- **State**: `defaultCodes` (the box's own codes are on), `scan` (learning
  state and the codes heard) and `codes`: each learnt hex code mapped to a
  name and an execution change **[verified: S1 `models/ir.py`]**.
- **Learning** stops after the next code or 20 seconds **[verified: S1
  `models/ir.py:9`]**.
- **Limits**: up to `capabilities.maxIrCodes` codes (24 in the example).
  The 2026 4K box has no IR receiver **[community: H4]**.

### 2.11 `presets`

- A preset has a name of at most 24 bytes, a last-used time, and an execution
  change, which may not run another preset **[verified: S1
  `models/presets.py:11-16`]**.
- POST creates one and returns its id; PUT and DELETE work by id; PUT
  `/execution` `{preset: <id>}` runs it **[verified: S1
  `controllers/presets.py:13-20`, `models/execution.py:74`]**.
- Up to `capabilities.maxPresets` (16 in the example). Whether the Hue app
  shows presets at all: **[assumed: no, they are API-only]**.

### 2.12 State changes: polling only

- **No push.** No client has an event stream, a long-poll or a webhook.
  Home Assistant declares the integration `local_polling` **[verified: S1,
  S2, S3, S4 code; S2 `manifest.json:12`]**. Signify's reference might still
  describe one; it was not read **[assumed: none]**.
- **Intervals in use**:
  - Home Assistant: 3 s **[verified: S2 `const.py:11`, `README.md:70`]**.
    It once used 10 s, then 2 s **[verified: S7, maintainer's comment]**.
  - Homebridge: 5 s by default **[verified: S4 `constants.ts`]**.
  - openHAB: 10 s by default **[verified: S3 `README.md:73`]**.
- **One GET of `/api/v1` returns everything**, and an answer is a few
  kilobytes **[verified: S1 `huesyncbox.py:155-183`; community: S4
  `constants.ts` comment]**.
- **A bridge-side hint.** A CLIP v2 `entertainment_configuration` carries
  `status` (`active` or `inactive`) and `active_streamer`, and accepts the
  actions `start` and `stop` **[verified: S5]**. That the bridge's event
  stream reports changes of these fields, as it does for other resources, is
  **[assumed]**.

### 2.13 Rate limits, concurrency and timeouts

- **No limit is published** in any public source; the reference was not read.
- **Connections**: aiohuesyncbox opens at most one connection to a box, with
  the comment that the box handles only a few **[verified: S1
  `huesyncbox.py:97`]**. Homebridge sends every request through one lock, so
  one at a time, on a kept-alive connection **[verified: S4 `client.ts`]**.
- **Timeouts**:
  - aiohuesyncbox: 10 s per request **[verified: S1 `huesyncbox.py:101`]**;
  - Home Assistant: 5 s per poll, and unavailable after 5 failures in a row
    **[verified: S2 `coordinator.py:23, 56`]**;
  - Homebridge: 8 s, then 3 retries of network errors after 1, 2 and 4 s
    **[verified: S4 `constants.ts`]**;
  - openHAB: 1 s **[verified: S3 `HueSyncConnection.java:100`]**.
- **Speed**: a box usually answers within milliseconds, but now and then takes
  more than 2 s **[community: S7, maintainer's comment]**.
- The Hue app, voice assistants, the IR remote and every other client that
  polls all reach the same box **[assumed: their load adds up]**.

### 2.14 Error codes

| Code | Message | When | Source |
| --- | --- | --- | --- |
| 1, 2, 3 | not seen | token missing or rejected | **[verified: S1 `errors.py:28-30`; meanings assumed]** |
| 10, 11, 14 | not seen | request errors | **[verified: S1 `errors.py:31-35`; meanings assumed]** |
| 12 | Invalid JSON | malformed body | **[community: C2]** |
| 13 | Invalid Key | empty body, or a key the resource does not have | **[verified: S2 `services.py:161-166`; the second case assumed]** |
| 15 | Invalid Value | known key, value out of range or format, such as an unknown area id | **[verified: S1 `errors.py:36` (a request error); community: C6]** |
| 16 | Invalid State | registration before the button is pressed; a sync command while another app streams to the bridge | **[verified: S1 `errors.py:37`; S2 `helpers.py:52-74`]** |

"Invalid Token" also appears as a message, with no code shown
**[community: C2]**.

## 3. The box and the Hue Bridge

- **One bridge at a time**: the box has a single `bridgeUniqueId`
  **[verified: S1 `models/hue.py:87`]**. The Hue app sets it up. The box then
  holds its own application key and client key for that bridge, the two
  values a bridge change writes **[verified: S1 `models/hue.py:69-79`]**. That
  key is an ordinary application key, listed on the bridge like any app's, is
  **[assumed]**.
- **Bridge ids**: the box reports upper case (`001788FFFE...` in Signify's
  example) **[verified: S1 `tests/test_compatibility.py:39`]**. The bridge
  driver compares ids in lower case **[verified: `docs/design.md`,
  "Certificates"]**.
- **Entertainment areas**: `hue.groups` lists the bridge's areas with their
  names and light counts. With a CLIP v2 bridge the keys are
  `entertainment_configuration` ids, the same ids the bridge driver can read
  at `/clip/v2/resource/entertainment_configuration` **[verified: S1
  `models/execution.py:72-73`; S5]**. An area holds at most 10 lights; Signify
  has not raised that **[verified: P2; community: H5, H6]**.
- **Streaming**: the box sends the colours to the bridge over the Hue
  Entertainment protocol, DTLS 1.2 on UDP port 2100 with the client key as
  pre-shared key **[community: search results on third-party streaming
  libraries; Signify's page not read]**. A bridge takes one stream at a time
  **[community: H6]**. While another app streams, the box refuses with code
  16; Home Assistant then stops that stream and retries without asking
  **[verified: S2 `helpers.py:52-74`]**.
- **What the bridge shows**: while the box syncs, the area's
  `entertainment_configuration` reads `status: active` with an
  `active_streamer` **[verified: S5]**, and the box reads `connectionState:
  streaming` **[verified: S1 `models/enums.py:63`]**.
- **Lights in a streaming area** follow the stream, and REST commands to them
  have no lasting effect until it ends **[community: search summary of
  streaming-library documentation]**. That matters to this project's light
  drivers.
- **Hue Bridge Pro**: firmware 2.5.4 added Bridge Migration on the 4K and 8K
  boxes **[verified: P1]**. That it keeps the box working after the Hue app
  moves a home to a Bridge Pro is **[community: the release note's name only]**.
- **Without a bridge**: the 8K box, the 2026 4K box and the camera can sync one
  Bluetooth light; a bridge extends that to an area of up to 10 lights
  **[verified: P7; S1 `models/hue.py:9, 92-100`; community: H5, N1]**. In that
  mode there is no bridge link and no area to choose, and Home Assistant hides
  its area and bridge entities **[verified: S2 `select.py:150`,
  `sensor.py:60, 67`]**.

## 4. What the box does by itself over HDMI

These matter because Control4 will be switching the same chain.

- **Input switching**, three triggers, each a setting (§2.8): a source sends
  CEC Active Source (`cecInputSwitch`, per input); any source is plugged in or
  powered on (`hpdInputSwitch`, HSB1 and HSB2); a given source is plugged in
  or powered on (`hpdInputPortSwitch`, per input, level 10). The Hue app sets
  the CEC switching per input **[community: C3]**.
  - Since 1.2.2 the TV no longer switches its own input when the box enters or
    leaves powersave **[verified: P1]**.
  - 2.5.0 sped up switching for a PS5 on LG TVs **[verified: P1]**.
- **Automatic sync**: `linkAutoSync` per input; in the Hue app, "start light
  sync when a video signal is detected" for chosen inputs **[verified: S1
  `models/behavior.py:39-40`; community: C3]**. Sync stops by itself when the
  source turns off **[community: H6]**.
- **Power**:
  - the TV's CEC standby (`cecPowersave`);
  - the TV's USB power, for TVs without usable CEC (`usbPowersave`);
  - 20 minutes idle (`inactivePowersave`).

  An "Automatic" setting in the Hue app also wakes the box: 2.0.5 fixed a box
  that turned on while it was disabled **[verified: P1]**. Which API fields
  that setting writes is **[assumed: `hpdInputSwitch` and the per-input
  switches]**.
- **The TV's power**: no API setting turns the TV on or off. The box passes
  CEC between the sources and the TV **[assumed]**. In powersave the box
  passes no picture (`hdmiActive` false) **[assumed from the field's
  meaning]**.
- **AV receivers**: put the box between the receiver and the TV with ARC
  bypass on, or on the receiver's second output with solo mode on (§2.8).
  2.5.0 fixed CEC power and the 20-minute switch-off on a receiver's second
  output **[verified: P1, H3]**. In distributed video the box can upset EDID
  and HDCP, and turning CEC off helped **[community: C4]**.
- **IR**: with `defaultCodes` on, the box obeys IR codes mapped to actions
  **[verified: S1 `models/ir.py:44`]**. Control4's IR emitters near the box
  could set them off **[assumed]**.

## 5. What a Control4 driver needs

1. **The model, at run time.** `deviceType` decides the input count (4, 1 or
   none), the power control, IR, and which `behavior` fields exist (§1.4).
   `uniqueId` is the stable key to persist; the address may change.
2. **TLS.** The bridge driver sends `C4:url` requests with `ssl_cabundle`,
   `ssl_verify_peer` on and `ssl_verify_host` off, because the bridge's common
   name is its id (`src/hue_bridge/bridge/http.lua:90`) **[verified: R1]**.
   The box has the same pattern with a different root, so a bundle holding
   `root-hsb` fits **[assumed: the controller verifies the box's chain as it
   does the bridge's]**. The identity check carries over too: an unkeyed GET
   `/api/v1/device` must report the paired `uniqueId` before the token is
   sent. Today `http.lua` adds only the `hue-application-key` header
   (`headers_for`, lines 165-173) **[verified: R1]**, so sending `Authorization`
   needs a small change.
3. **Discovery.** A unicast mDNS query for `_huesync._tcp.local`, then a
   manual address, then the box found again by its id after an address change.
   No cloud.
4. **Pairing.** One action: POST once a second for a bounded time while the
   owner holds the button, then store the registration id and token the way
   the bridge key is stored. Forgetting the pairing deletes the driver's own
   registration.
5. **State.** One GET of `/api/v1` per poll, one request in flight, a 5 s
   timeout, offline after a few failures in a row. Read again at once after
   every command.
6. **Commands.** One PUT per user action, through a serial queue for each box
   that keeps only the latest value of each field (brightness sliders). Mode
   and intensity go in one PUT.
7. **Switching.** Control4 has an AV Switch proxy; from OS 3.3.0 it can hide
   bindings that are not in use (`<allow_dynamic_resize>`, `<ExtraInfo>D2`)
   **[verified: FUND/`27_proxy_specific_info/_30-AVSWITCHBINDINGS.md`]**. Its
   commands and notifications are in the Proxy and Protocol Guide, which is
   not in the local reference **[verified: `ls ~/c4-tools/reference`]**. The
   mapping the box needs **[assumed: proxy command names belong to the
   Control4 research]**:
   - input select → `hdmiSource`;
   - power on → `hdmiActive: true`; power off → `hdmiActive: false`;
   - every change the box makes by itself reported back to the proxy.
8. **Sync controls for programming**: sync on, off and toggle, mode,
   intensity, brightness, background lighting, palette, area and presets, as
   commands, variables, events and conditionals. A third-party Control4 driver
   offers roughly this set, through the AV Switch, light and button proxies
   **[community: C5]**.
9. **Settings.** The `behavior` flags shown as properties, changed only by a
   click.
10. **Status.** Bridge link (`connectionState`, and whether `bridgeUniqueId` is
    the paired bridge), the area's name, `contentSpecs`, each input's status,
    Wi-Fi strength, firmware and any update, and the `overheating` and
    `undervolt` alarms.
11. **The camera.** No HDMI and no power: only the sync controls apply.

## Recommendations for the design

1. **One sync box driver for every model,** with the model decided at run time
   from `deviceType`. Declare four HDMI inputs and let the AV Switch proxy
   hide the unused ones (OS 3.3.0 and later). On a one-input box, refuse the
   others with a clear message.
2. **Pin TLS to `root-hsb`** with the bridge driver's bundle mechanism. Run the
   unkeyed identity check (`/api/v1/device` must report the paired
   `uniqueId`) before the first keyed request of every start and every new
   address, and the TLS self-check as for the bridge. Never trust on first
   use, and never turn verification off.
3. **Discover with unicast mDNS** for `_huesync._tcp.local`, reusing
   `bridge/mdns.lua`. Fall back to a typed address, follow a box by its id
   after an address change, and never use the cloud.
4. **Pair with one action.** It posts once a second for up to about 60 s while
   the owner holds the button. It keeps the registration id and token in
   encrypted persistent storage and never logs or reports the token. Forget
   Pairing deletes the box's registration.
5. **Poll gently.** One GET of `/api/v1` every 3 s while the box is on and
   every 10 to 15 s in powersave, with one request in flight, a 5 s timeout,
   and offline after 5 failures in a row. Read again at once after each
   command.
6. **Use the bridge's event stream as a hint.** Changes of an
   `entertainment_configuration`'s `status` and `active_streamer` can prompt
   an immediate read of the box. Verify on hardware that the stream carries
   them.
7. **Send commands through a serial queue for each box** that coalesces each
   field to its latest value, one PUT per user action, with mode and
   intensity in the same PUT.
8. **Behave like an HDMI switch.** Control4's power on writes `hdmiActive:
   true`, power off writes `hdmiActive: false`, and input selection writes
   `hdmiSource`. Report every change the box makes by itself back to the
   proxy, so that Control4 follows the box's CEC switching instead of
   fighting it.
9. **Never change the box's own automation by itself.** CEC and hot-plug
   switching, automatic sync, and the CEC, USB and idle powersave settings are
   read and shown. Changing them is offered with a click, never automatic.
   This follows the project's rule on automation (`CLAUDE.md`, "Edge cases
   before automation").
10. **Watch the bridge link.** Compare the box's `bridgeUniqueId`, in lower
    case, with the paired bridge, and warn on a mismatch. Never change the
    box's bridge by itself: that hands a bridge key and client key to the
    box, so it needs a click.
11. **Ask before taking over a stream.** On code 16 for a sync command, say
    that another app is syncing and offer "Take over sync", which stops that
    area's stream. Home Assistant takes over silently instead.
12. **Tolerate change.** Keep working on unknown values (modes, states, port
    types). Gate level-10 and level-14 fields on `apiLevel`. Never require a
    field that some model lacks.
13. **Research the lifecycle before any automation**, as the project's rule
    requires: a box replaced, factory reset (token gone, 401), moved to
    another bridge, an area renamed or deleted (`invalidgroup`), a firmware
    update that raises `apiLevel`, a Wi-Fi drop, an address change.

## Open questions for the owner

1. **Which sync devices does the house have?** For each: the model, the room,
   its place in the HDMI chain (straight to the TV, between an AV receiver and
   the TV, or on a receiver's second output) and its firmware. Can one be lent
   for testing, or is there an outside tester, as for the motion sensors?
2. **Who switches inputs?** Control4 alone, with the driver offering to turn
   the box's CEC and hot-plug switching off? Or the box keeps switching and
   Control4 follows it?
3. **Should the Play Screen Sync camera be supported?** It speaks the same
   API but has no HDMI.
4. **Bridge-free boxes**: should a box that syncs over Bluetooth without a
   Hue Bridge be supported, or is the bridge required?
5. **Sync brightness**: should it be a Control4 light (light_v2, under the
   lighting guidelines), or only a command and variable?

## 8. Sources

Commits and versions as read on 2026-11-13.

| Id | Source |
| --- | --- |
| S1 | aiohuesyncbox 0.1.7, commit `53a3f50` (2026-11-04), Apache-2.0: https://github.com/mvdwetering/aiohuesyncbox/tree/53a3f502f637100c270e85b9509565d607edbbd5 (files under `aiohuesyncbox/`; release notes at https://github.com/mvdwetering/aiohuesyncbox/releases) |
| S2 | Home Assistant custom integration huesyncbox, commit `71da2f9` (2026-11-10): https://github.com/mvdwetering/huesyncbox/tree/71da2f95fb75e27e713f7f7fdb5326aae0b281cc (files under `custom_components/huesyncbox/`) |
| S3 | openHAB huesync binding, openhab-addons commit `4783cad`: https://github.com/openhab/openhab-addons/tree/4783cad9cc5fd21b41caf0a7bd842613129a086d/bundles/org.openhab.binding.huesync (Java files under `src/main/java/org/openhab/binding/huesync/internal/`) |
| S4 | homebridge-philips-hue-sync-box 3.0.7: https://unpkg.com/homebridge-philips-hue-sync-box@3.0.7/README.md, https://app.unpkg.com/homebridge-philips-hue-sync-box@3.0.7/files/src/lib/client.ts, https://app.unpkg.com/homebridge-philips-hue-sync-box@3.0.7/files/src/lib/constants.ts |
| S5 | aiohue, commit `e4faf06` (2026-11-09), the CLIP v2 entertainment configuration model: https://github.com/home-assistant-libs/aiohue/blob/e4faf0694b4de2e13f36929e69c9f6f93c846c89/aiohue/v2/models/entertainment_configuration.py |
| S7 | huesyncbox issue 24, on update intervals: https://github.com/mvdwetering/huesyncbox/issues/24 |
| P1 | Philips Hue, sync box release notes: https://www.philips-hue.com/en-us/support/release-notes/philips-hue-play-hdmi-sync-box |
| P2 | Philips Hue, Sync Box 8K (US): https://www.philips-hue.com/en-us/p/hue-philips-hue-play-hdmi-sync-box-8K/046677579753 |
| P3 | Philips Hue, Sync Box 8K (Canada): https://philips-hue.com/en-ca/p/hue-philips-hue-play-hdmi-sync-box-8k/046677579753 |
| P4 | Philips Hue, Sync Box 4K, 2026 (US): https://www.philips-hue.com/en-us/p/hue-philips-hue-play-hdmi-sync-box-4K/046677610616 |
| P5 | Philips Hue, original Sync Box (US): https://www.philips-hue.com/en-us/p/hue-hdmi-sync-box-/046677555221 |
| P6 | Philips Hue support, "Hue sync box and ARC setup": https://www.philips-hue.com/en-us/support/article/hue-sync-box-and-arc-setup/000006 |
| P7 | Philips Hue support, sync guide: https://www.philips-hue.com/en-us/support/article/philips-hue-sync-guide/000020 |
| P8 | Signify, HDMI Sync Box API reference (login required; not read): https://developers.meethue.com/develop/hue-entertainment/hue-hdmi-sync-box-api/ |
| P9 | Philips Hue, Sync Box 8K (Singapore): https://philips-hue.com/en-sg/p/hue-philips-hue-play-hdmi-sync-box-8k/8719514458680 |
| H1 | Hueblog, 8K box revealed, 2023-02-11: https://hueblog.com/2023/02/11/philips-hue-play-hdmi-sync-box-8k-revealed/ |
| H2 | Hueblog, first 8K firmware update, 2025-01-09: https://hueblog.com/2025/01/09/first-firmware-update-for-the-philips-hue-play-hdmi-sync-box-8k/ |
| H3 | Hueblog, 8K firmware 2.5.0, 2025-04-08: https://hueblog.com/2025/04/08/numerous-improvements-for-the-philips-hue-play-hdmi-sync-box-8k/ |
| H4 | Hueblog, Play Sync Box Lite, 2026-08-24: https://hueblog.com/2026/08/24/this-is-the-new-philips-hue-play-sync-box-lite/ |
| H5 | Hueblog, bridgeless sync, 2026-09-14: https://hueblog.com/2026/09/14/philips-hue-rolls-out-update-for-its-smart-lights/ |
| H6 | Hueblog, Sync Box 4K review, 2026-10-12: https://hueblog.com/2026/10/12/philips-hue-play-hdmi-sync-box-4k-review/ |
| H7 | Hueblog, firmware 3.5.2, 2026-10-08: https://hueblog.com/2026/10/08/firmware-updates-for-hue-lights-and-the-new-sync-box/ |
| H8 | Hueblog, original box sold out, 2026-02-23: https://hueblog.com/2026/02/23/the-original-hue-play-hdmi-sync-box-is-now-sold-out/ |
| N1 | 9to5Google, Screen Sync and the 2026 4K box, 2026-09-03: https://9to5google.com/2026/09/03/philips-hue-new-sync-camera-box-nanoleaf-ifa-2026/ |
| N2 | hifi.de, the 8K box: https://hifi.de/news/hue-sync-box-8k-lichtshow-im-takt-jetzt-auch-mit-4k-120-hz-moeglich-204517 |
| C1 | Homey community, "Hue Sync Box Mode": https://community.homey.app/t/hue-sync-box-mode/54510 |
| C2 | Homey community, rebooting a sync box: https://community.homey.app/t/tutorial-reboot-philips-hue-sync-box/39725 |
| C3 | netzwelt.de, automatic control guide: https://www.netzwelt.de/anleitung/223673-philips-hue-sync-box-automatische-steuerung-synchronisierung.html |
| C4 | HDA support, sync box and MHUB: https://support.hda.systems/2026/06/philips-hue-sync-box-and-mhub |
| C5 | DriverCentral, a third-party Control4 sync box driver: https://drivercentral.io/platforms/control4-drivers/audio-video/philips-hue-hdmi-sync-box/ |
| C6 | Stack Overflow question 72546658, "Change entertainment area via Hue Sync Box API" (seen only as a search summary): https://stackoverflow.com/questions/72546658 |
| R1 | This repository: `src/hue_bridge/bridge/http.lua`, `src/hue_bridge/bridge/mdns.lua`, `src/hue_bridge/certs/`, `docs/design.md` |
| FUND | DriverWorks Fundamentals, `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/` (Snap One; paraphrased, not copied) |
