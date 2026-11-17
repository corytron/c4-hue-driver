# What a Hue Play HDMI Sync Box does: the rules both fake boxes keep

The normative behaviour of the two fake sync boxes of issue #547 (part of
#514): `fake.syncbox` in the Lua fake runtime and the Python model under
`tools/fakebox/`. The contract is [`fakebox-design.md`](fakebox-design.md)
§3; the field names and the facts behind them are those of the research
note [`syncbox-api-research.md`](syncbox-api-research.md) (R1 below), the
lifecycle cases those of [`edge-cases-syncbox.md`](edge-cases-syncbox.md).
The scenarios in `tests/fixtures/syncbox_scenarios.json` turn every rule
below into steps; both fakes must pass all of them
(`tests/spec/syncbox_scenarios_spec.lua`, `tools/tests/test_fakebox_scenarios.py`).

Nothing here was checked against a box. Every rule was read from public
code that talks to real boxes, or from public reports, on 2026-11-17, and
is written in our own words: field names only, no passage of any source
copied. A rule no public source shows is marked [assumed]; §16 lists every
one with the check on the owner's box that settles it, and the owner's
final checks settle those first. The fixtures are
`tests/fixtures/hue_syncbox.lua` (and the JSON made from it); their
placeholder values (box id 0A1B2C3D4E5F at 10.0.2.150, bridge
001788fffe123abc, token TEST-TOKEN-NOT-REAL) are the only ones used here.

## How to read a rule

- Each rule is one numbered item, **SBn**. Numbers never change once
  published; the groups start at round numbers and leave gaps for later
  rules.
- Each rule ends with its sources in brackets:
  - **[verified: S …]**: shown by the code of a library or integration that
    runs against real boxes, at the file and line given (the commits are in
    the table below);
  - **[community: …]**: reported by users or a maintainer, not shown by
    code;
  - **[assumed]**: our choice where no public source says; a rule that is
    partly shown says which part is assumed;
  - **[fake]**: a convention of the two fakes, not a claim about a box (how
    time passes, what the fakes leave out). Conventions need no house check.
- "The box" is the fake; "a sync mode" is `video`, `game` or `music`;
  "syncing" means `execution.mode` is a sync mode; "an input" is one the
  model has (`input1` to `input4` on HSB1 and HSB2, `input1` only on HSB3).
- A refusal is written "→ 15": HTTP 400 with `{"code": 15, "message": …}`.
  The status and message of each code are the fixture's
  (`M.error`, `M.error_status`): 2 → 401, 10 → 404, 12, 13, 15 and 16 → 400.

### Sources

| Id | Source |
| --- | --- |
| S1 | aiohuesyncbox 0.1.7, commit `53a3f50`, Apache-2.0: https://github.com/mvdwetering/aiohuesyncbox/tree/53a3f502f637100c270e85b9509565d607edbbd5 (paths under `aiohuesyncbox/`); release notes https://github.com/mvdwetering/aiohuesyncbox/releases |
| S2 | Home Assistant's huesyncbox integration, commit `71da2f9`: https://github.com/mvdwetering/huesyncbox/tree/71da2f95fb75e27e713f7f7fdb5326aae0b281cc (paths under `custom_components/huesyncbox/`, and its `README.md`) |
| S3 | openHAB's huesync binding, openhab-addons commit `4783cad`: https://github.com/openhab/openhab-addons/tree/4783cad9cc5fd21b41caf0a7bd842613129a086d/bundles/org.openhab.binding.huesync (Java paths under `src/main/java/org/openhab/binding/huesync/internal/`, `channel-types.xml` under `src/main/resources/OH-INF/thing/`) |
| S4 | homebridge-philips-hue-sync-box 3.0.7, README: https://unpkg.com/homebridge-philips-hue-sync-box@3.0.7/README.md |
| C1 | Homey community, "Hue Sync Box Mode", post 4: https://community.homey.app/t/hue-sync-box-mode/54510 |
| C2 | Homey community, rebooting a sync box: https://community.homey.app/t/tutorial-reboot-philips-hue-sync-box/39725 |
| C6 | Stack Overflow 72546658 (search summary only): https://stackoverflow.com/questions/72546658 |
| H6 | Hueblog, Sync Box 4K review, 2026-10-12: https://hueblog.com/2026/10/12/philips-hue-play-hdmi-sync-box-4k-review/ |
| I22 | huesyncbox issue 22, the maintainer and a user on port statuses: https://github.com/mvdwetering/huesyncbox/issues/22 |
| I70 | huesyncbox issue 70, a GET of `/api/v1` without a token answered 401: https://github.com/mvdwetering/huesyncbox/issues/70 |
| I184 | huesyncbox issue 184, `device.action` read `checkForFirmwareUpdates` during a background check: https://github.com/mvdwetering/huesyncbox/issues/184 |
| A5 | aiohuesyncbox issue 5, an 8K box's leaf certificate subject: https://github.com/mvdwetering/aiohuesyncbox/issues/5 |

## 1. The state

- **SB1** GET `/api/v1` answers the whole state: `device`, `execution`,
  `hdmi`, `behavior`, `hue`, `ir`, `registrations` and `presets`, each as
  the model has it; a resource the model lacks is absent (HSB3 has no `ir`).
  [verified: S1 `huesyncbox.py:155-183` (`behavior`, `hdmi`, `ir`
  optional); HSB3 without IR: community, R1 §1.4]
- **SB2** GET of a resource or of an object inside it (`/hdmi/input1`,
  `/behavior/input2`, `/hue/groups/<id>`, `/registrations/<id>`) answers that
  object. A path that names no object of this box (an unknown name, a
  scalar such as `/execution/mode`, `/hdmi/input2` on HSB3) → 10 (HTTP 404).
  [verified: S3 `connection/HueSyncConnection.java:57-62` (resource and
  sub-resource paths), `:187` (404 for an unknown path); the code 10 and the
  scalar case assumed]
- **SB3** `execution.syncActive` is true exactly when the mode is a sync
  mode. [verified: S1 `models/execution.py:39-40, 82-83`; S3
  `channel-types.xml:150`]
- **SB4** `execution.hdmiActive` is false exactly in `powersave`.
  [verified: S1 `models/execution.py:43-44, 95-96`; S3
  `channel-types.xml:171`]
- **SB5** Entering a sync mode sets `execution.lastSyncMode` and the
  selected input's `hdmi.<input>.lastSyncMode` to it. [verified: S1
  `models/execution.py:86-87`, `models/hdmi.py:18-19` (what the fields
  mean); when they change assumed]
- **SB6** In bridge mode, starting to sync makes `hue.connectionState`
  `streaming` and the area named by `execution.hueTarget` read
  `active: true`; stopping while `streaming` makes it `connected` and the
  area inactive. [verified: S1 `models/enums.py:63`, `models/hue.py:52-55`;
  the return to `connected` assumed]
- **SB7** `execution.hueTarget` and, from API level 10, `hue.groupId` name
  the same area and change together. [verified: S1
  `models/execution.py:72-73`, `models/hue.py:78-79, 93-94` (both name the
  selected area); that they move together assumed]
- **SB8** No answer ever carries an access token: registrations are listed
  with their names, role and times only. [verified: S1
  `models/registrations.py:7-25` (the listed fields); the absence of tokens
  assumed]

## 2. Requests, tokens and refusals

- **SB10** Every answer is JSON. Success is HTTP 200; a refusal carries
  `code` and `message` with the status of the code (§ How to read).
  [verified: S1 `huesyncbox.py:219-223, 239-241`; S3
  `connection/HueSyncConnection.java:180-193`]
- **SB11** An accepted PUT or DELETE answers 200 with an empty object.
  [assumed: every client ignores the body, S1 `controllers/base.py:32-33`]
- **SB12** Without a token only two requests are served: GET `/device`,
  which answers the identifying fields (the fixture's unkeyed device: no
  `wifi`, `update`, `ledMode`, `action` or `pushlink`), and POST
  `/registrations`. Anything else → 2 (HTTP 401). [verified: S3
  `connection/HueSyncConnection.java:183-185`,
  `connection/HueSyncDeviceConnection.java:147-149`,
  `api/dto/device/HueSyncDevice.java:28-65` against
  `HueSyncDeviceDetailed.java:31-56`; community: I70; the code 2 assumed]
- **SB13** A token the box does not know → 2 on every path, GET `/device`
  and POST `/registrations` included. [verified: S1
  `controllers/registrations.py:21-23` (the POST), S3
  `connection/HueSyncConnection.java:183-184` (invalid credentials fail);
  the code assumed]
- **SB14** With a valid token, GET `/device` answers the whole `device`
  object. [verified: S3 `connection/HueSyncDeviceConnection.java:151-155`]
- **SB15** A method a path does not take (POST `/execution`, DELETE
  `/device`, PUT `/api/v1`, PUT `/registrations`) → 10. [assumed]
- **SB16** A body that is not JSON → 12. [community: C2]
- **SB17** A PUT whose body is an empty object → 13. [verified: S2
  `services.py:161-166`]
- **SB18** A key the resource does not take (unknown, read-only, or not on
  this model or API level) → 13. [assumed: R1 §2.14, the second case]
- **SB19** A known key whose value has the wrong type or is out of range →
  15. [verified: S1 `errors.py:36` (15 is a request error); community: C6,
  S4 (an unknown area); the general case assumed]
- **SB20** A refused request changes nothing, not even the valid fields of
  the same body. [assumed]
- **SB21** A body is checked in this order and refused at the first
  failure: JSON (12), an empty object (13), keys (13), values (15), the
  box's state (16); SB97 is the one exception. [assumed]

## 3. Power and sync: the modes

- **SB30** PUT `/execution` `{"mode": m}` with `powersave`, `passthrough`,
  `video`, `game` or `music` puts the box in that mode, under SB3 to SB6.
  [verified: S1 `models/enums.py:79-84`; S2 `switch.py:33-41` (power by
  mode), `select.py:115-117` (a sync mode by mode)]
- **SB31** A sync mode set from `powersave` wakes the box and syncs.
  [verified: S2 `README.md:65`]
- **SB32** `{"syncActive": true}` outside a sync mode syncs in the selected
  input's `hdmi.<input>.lastSyncMode`, waking the box from `powersave`;
  while syncing it changes nothing. [verified: S3 `channel-types.xml:153`,
  `README.md:103`; S2 `README.md:64`]
- **SB33** `{"syncActive": false}` while syncing goes to `passthrough`; in
  `passthrough` or `powersave` it changes nothing. [verified: S3
  `channel-types.xml:154`; the no-change half assumed]
- **SB34** `{"hdmiActive": true}` in `powersave` goes to `passthrough`; in
  any other mode it changes nothing. [verified: S3 `channel-types.xml:174`]
- **SB35** `{"hdmiActive": false}` goes to `powersave` from any mode,
  ending a sync. [verified: S3 `channel-types.xml:175`]
- **SB36** `{"toggleSyncActive": true}` acts as `syncActive` set to the
  opposite of its value; `{"toggleHdmiActive": true}` likewise for
  `hdmiActive`. A toggle sent as `false` changes nothing. [verified: S1
  `models/execution.py:41-42, 45-46`; the `false` case assumed]
- **SB37** `{"toggleSyncMode": m}` syncs in `m` (waking the box), unless
  the box already syncs in `m`, when it goes to `passthrough`. [verified:
  S1 `models/execution.py:63-64` (the first half); the second half assumed]
- **SB38** `{"cycleSyncMode": "next"|"previous"}` syncs in the next or
  previous sync mode in the order `video`, `music`, `game`, wrapping round,
  counted from the current sync mode or, when not syncing, from
  `lastSyncMode`; it wakes the box. [verified: S1
  `models/execution.py:49-50`; the order is S2 `const.py:24-27`'s; the rest
  assumed]
- **SB39** `{"hdmiSource": "inputN"}` selects that input and keeps the
  mode: a box that syncs goes on syncing in the same mode, which becomes
  the new input's `lastSyncMode`; a box in `powersave` stays in it.
  [verified: S1 `models/execution.py:51-52`; keeping the mode and not
  waking assumed (edge-cases I3)]
- **SB40** `hdmiSource` must name an input of this model: `input2` to
  `input4` on HSB3, or any other text → 15. [verified: S1
  `models/hdmi.py:51-54`, S2 `select.py:72-74` (HSB3 has one input); the
  code assumed]
- **SB41** `{"cycleHdmiSource": "next"|"previous"}` moves through the
  model's inputs in order, wrapping round; on a one-input box it stays on
  `input1`. The mode is kept as in SB39. [verified: S1
  `models/execution.py:53-54`; the order and wrapping assumed]
- **SB42** `{"brightness": n}` takes a whole number from 0 to 200 (100
  leaves the picture's brightness as it is); anything else → 15.
  [verified: S1 `models/execution.py:55-56`, S3 `channel-types.xml:216-221`;
  the refusal assumed]
- **SB43** `{"incrementBrightness": d}` takes a whole number from −200 to
  200 and adds it to `brightness`, holding the result within 0 to 200;
  anything else → 15. [verified: S1 `models/execution.py:57-58`,
  `controllers/execution.py:87-89`; the clamping and the refusal assumed]
- **SB44** `{"intensity": i}` (`subtle`, `moderate`, `high`, `intense`)
  sets the intensity of the current sync mode or, when not syncing, of
  `lastSyncMode`'s; it changes no mode. [verified: S1
  `models/execution.py:59-60`, S2 `README.md:66` (the current mode),
  `select.py:40-44, 101-103` (outside a sync mode Home Assistant shows
  `lastSyncMode`'s); writing there when not syncing assumed]
- **SB45** `{"cycleIntensity": "next"|"previous"}` moves SB44's intensity
  through `subtle`, `moderate`, `high`, `intense`, wrapping round.
  [verified: S1 `models/execution.py:61-62`,
  `controllers/execution.py:91-94`; the wrapping assumed]
- **SB46** `{"backgroundLighting": b}` (true or false) sets it on SB44's
  mode, and `{"toggleBackgroundLighting": true}` flips it there; when that
  mode is `music`, which has no background lighting → 15. [verified: S1
  `models/execution.py:68-71`, `:14-32` (music has none); the refusal
  assumed]
- **SB47** `{"video": {…}}` and `{"game": {…}}` take `intensity` and
  `backgroundLighting`; `{"music": {…}}` takes `intensity` and `palette`
  (`happyEnergetic`, `happyCalm`, `melancholicCalm`,
  `melancholicEnergetic`, `neutral`). They set that mode's settings whether
  it is current or not and change no mode. Another key inside → 13; a bad
  value → 15. [verified: S1 `models/execution.py:14-32, 65-67`,
  `models/enums.py:109-124`; the refusals assumed]
- **SB48** `{"hueTarget": id}` takes a key of `hue.groups`, or
  `groups/<n>` naming the key `<n>`, and then reads as sent (`hue.groupId`
  holding the key); anything else → 15. If the box syncs, its stream moves:
  the old area reads inactive and the new one active. [verified: S2
  `helpers.py:103-108`, `select.py:81-91` (the two forms); community: S4,
  C6 (an unknown area is refused, with 15); reading as sent and moving the
  stream assumed]
- **SB49** `{"preset": id}` runs that preset: the preset's stored
  `execution` applies as if it were sent in the same PUT, and
  `presets.<id>.lastUsed` is set from the box's clock; an id `presets` does
  not hold → 15. [verified: S1 `models/execution.py:74-75`,
  `models/presets.py:7-18`; the refusal assumed]
- **SB50** Every other execution field (brightness, intensities, the mode
  objects, `hueTarget`) applies in every mode, `powersave` included, and
  leaves the mode as it is. [assumed]
- **SB51** A `mode` other than the five (`ambient` included) → 15.
  [verified: S1 `models/enums.py:79-84` (five modes); community: C1 names
  `ambient`; the refusal assumed]

## 4. One PUT with several fields

- **SB55** The fields of one PUT `/execution` apply in this order, each
  under its own rule: (1) `preset`; (2) `hdmiActive`, `toggleHdmiActive`;
  (3) `hdmiSource`, `cycleHdmiSource`; (4) `hueTarget`; (5) `mode`,
  `toggleSyncMode`, `cycleSyncMode`; (6) `syncActive`, `toggleSyncActive`;
  (7) `video`, `game`, `music`; (8) `intensity`, `cycleIntensity`,
  `backgroundLighting`, `toggleBackgroundLighting`; (9) `brightness`, then
  `incrementBrightness`. So a mode and an intensity sent together put the
  intensity on the new mode, and `{"hdmiActive": true, "hdmiSource":
  "input2", "syncActive": true}` wakes the box, selects input 2 and syncs in
  input 2's mode. [verified: S2 `README.md:66`, `services.py:128-155` (one
  PUT puts the intensity on the mode sent with it); the rest of the order
  assumed]
- **SB56** The box checks the whole PUT before applying any of it (SB20,
  SB21); a refusal by state (16, §8) is judged on the result the whole PUT
  would have. [assumed]
- **SB57** The fields that set a value (`hdmiActive`, `hdmiSource`,
  `hueTarget`, `mode`, `syncActive`, the mode objects, `intensity`,
  `backgroundLighting`, `brightness`) leave `execution`, `hdmi` and `hue` the
  same when the same PUT comes again, as a PUT resent after its answer was
  lost does. The commands that step (the toggles, the cycles,
  `incrementBrightness`) are not like that, and the drivers never resend
  them. [assumed: it follows from SB30 to SB50; no source sends a PUT twice]

## 5. Behavior settings

- **SB60** PUT `/behavior` takes box-wide flags and `inputN` objects; a
  PUT of a part of it (`/behavior/input1`) → 10. A flag is the number 0 or
  1; anything else, `true` and `false` included → 15. [verified: S1
  `controllers/behavior.py:8-9, 55-60` (writes go to `/behavior`), release
  0.1.7 and `models/behavior.py:9-23` (flags travel as 0 and 1); the 10 and
  refusing `true` and `false` assumed]
- **SB61** `inactivePowersave` is a whole number of minutes from 0 (off) to
  10000; anything else → 15. [verified: S1 `models/behavior.py:72-73`; the
  refusal assumed]
- **SB62** The keys follow the model and API level: `usbPowersave` and
  `hpdInputSwitch` on HSB1 and HSB2; `forceDoviNative` and the per-input
  `hdrMode` (0, 1, 2) on HSB1; `hpdInputPortSwitch` from level 10;
  `soloMode` from level 14; `input2` to `input4` on four-input boxes;
  `cecInputSwitch`, `linkAutoSync`, `arcBypassMode`, `cecPowersave`,
  `inactivePowersave` everywhere. A key the box lacks → 13. [verified: S1
  `models/behavior.py:35, 41-44, 76-85`; the refusal assumed]
- **SB63** A PUT `/behavior` changes only `behavior`: nothing happens until
  the next event, which then follows the new values. [assumed]
- **SB64** `arcBypassMode` and `soloMode` are stored and shown; in the
  fakes they change none of the other rules. [verified: S1
  `models/behavior.py:80-83` (what they are for); their having no effect in
  the fakes is fake]

## 6. What the box does by itself (events)

The events are those of contract §2 and §4; each changes the state as below
and nothing else.

- **SB70** `cec_active_source` on input N (a source sends CEC Active
  Source): if `behavior.inputN.cecInputSwitch` is 1, the box selects input
  N (keeping the mode, SB39) and, from `powersave`, wakes to
  `passthrough`; otherwise, or for an input the model lacks, nothing.
  [verified: S1 `models/behavior.py:37-38`; waking assumed (R1 §4)]
- **SB71** `hotplug` on input N (a source plugged in or powered on): the
  input's status becomes at least `plugged`; if `behavior.hpdInputSwitch`
  (HSB1, HSB2) or `behavior.inputN.hpdInputPortSwitch` (level 10) is 1, the
  box selects input N as in SB70. [verified: S1 `models/behavior.py:43-44,
  78-79`; the status and waking assumed]
- **SB72** `signal` on a port (an input or `output`) with a status
  (`unplugged`, `plugged`, `linked`, `unknown`) sets that port's status.
  While the box is in `powersave` a `linked` port reads `plugged`, and
  reads `linked` again once the box wakes. [verified: S1
  `models/enums.py:170-174`; community: I22 (linked shows only while the
  box is awake)]
- **SB73** Auto-sync: after an event that makes the selected input and the
  output both read `linked` (a signal, or a CEC or hot-plug switch to a
  linked input) when they did not for that input before, a box in
  `passthrough` whose `behavior.<input>.linkAutoSync` is 1 syncs in the
  input's `lastSyncMode`. A request never starts auto-sync. [verified: S1
  `models/behavior.py:39-40`; the moments assumed]
- **SB74** Sync ends by itself: when the selected input stops reading
  `linked` (a `signal` event) while the box syncs, it goes to
  `passthrough`. [community: H6 (sync stops when the source turns off)]
- **SB75** `tv_standby` (the TV's CEC standby): with
  `behavior.cecPowersave` 1 the box goes to `powersave`; with 0 nothing.
  [verified: S1 `models/behavior.py:74-75`]
- **SB76** `usb_power_lost` (the TV's USB port drops its 5 V): with
  `behavior.usbPowersave` 1 the box goes to `powersave`; with 0, or on a
  model without the setting, nothing. [verified: S1
  `models/behavior.py:76-77`]
- **SB77** `idle` with `minutes`: a box in `passthrough` with
  `inactivePowersave` above 0 and no more than `minutes`, and with no input
  reading `linked` or the output not reading `linked`, goes to `powersave`;
  otherwise nothing. [verified: S1 `models/behavior.py:72-73`]
- **SB78** `hdmi.contentSpecs`, `videoSyncSupported` and
  `audioSyncSupported` describe the selected input's signal: while it does
  not read `linked` they are `""`, false and false; while it does, the
  fixture's values, or `1920 x 1080 @ 60000 - SDR`, true and true when the
  fixture had none. [verified: S1 `models/hdmi.py:44-49` (what they mean);
  the values assumed]

## 7. Registrations

- **SB80** POST `/registrations` takes `appName` and `instanceName`, both
  non-empty text; a missing or bad one → 15, checked before the button
  (SB21). [verified: S1 `models/registrations.py:31-37`; the refusal
  assumed]
- **SB81** Before the button → 16 (Invalid State). [verified: S3
  `connection/HueSyncConnection.java:181`; S1 `README.md:48-57`; S2
  `config_flow.py:243-250`]
- **SB82** The `button` event (held about 3 seconds, LED green) opens a
  window of 5 seconds of the box's clock; the first valid POST inside it
  answers 200 with `registrationId` and `accessToken` and closes it; after
  the window → 16 again. [verified: S3 `README.md:57` (3 seconds); S1
  `models/registrations.py:40-45` (the answer); community: S4, C1 (5
  seconds); one registration per press assumed]
- **SB83** Registration ids are decimal text and never reused: the first
  the fakes issue is the fixture's `REGISTRATION_ID` ("7"), each next one
  is one more than the highest id the box has listed or issued. The first
  token is the fixture's `TOKEN`, a later one `TOKEN-<id>`. [fake: real
  ids and tokens are the box's own]
- **SB84** GET `/registrations` lists each registration by id with
  `appName`, `instanceName`, `role`, `created`, `lastUsed` and, from level
  10, `verified`; a new registration has role `user` and `verified` false.
  [verified: S1 `models/registrations.py:7-25`, `tests/test_compatibility.py:150-164`
  (the fields); the role and flag of a new one assumed]
- **SB85** Several registrations live side by side, each token working on
  its own; the same names registered twice make two registrations.
  [verified: S2 `config_flow.py:247` and S3
  `connection/HueSyncDeviceConnection.java:169-179` (each client registers
  its own instance); the duplicate names assumed]
- **SB86** DELETE `/registrations/<id>` with that registration's own token
  removes it (200 `{}`) and its token is refused from then on (2). With
  another registration's token → 2 and nothing is removed; an id the box
  does not hold → 10. [verified: S1 `huesyncbox.py:139-141`,
  `controllers/base.py:83-84`; S2 `__init__.py:94-112`; the two refusals
  assumed]
- **SB87** `app_deletes` (the registration removed in the Hue Sync app):
  the registration is gone and its token → 2. [community: C1 (a token
  lasts until its registration is removed); verified: S2
  `coordinator.py:77-80` (a refused token asks for a new pairing)]
- **SB88** Each request made with a token sets its registration's
  `lastUsed` from the box's clock. [verified: S1
  `models/registrations.py:21-22` (what the field means); the moment
  assumed]

## 8. The bridge link

- **SB90** The `bridge` event with a `state` (`uninitialized`,
  `disconnected`, `connecting`, `unauthorized`, `connected`,
  `invalidgroup`, `busy`) sets `hue.connectionState`. [verified: S1
  `models/enums.py:56-64`]
- **SB91** In bridge mode a PUT whose result would be a sync mode is
  refused with 16 unless `connectionState` is `connected` or `streaming`.
  [verified: S2 `helpers.py:52-60` (16 while another app streams); the
  other states assumed]
- **SB92** `busy` means another app streams to the bridge: the area named
  by `hueTarget` reads `active: true` with an `owner` that is not this box
  (the fakes write `other-app`). [verified: S1 `models/hue.py:52-55`
  (`owner` while active); S2 `helpers.py:58-60`; the owner's text is fake]
- **SB93** A `bridge` event other than `connected` while the box syncs ends
  the sync (`passthrough`), the connection state being the event's; for
  every state but `busy` all areas read inactive. A `connected` event
  clears another app's stream (its area inactive, no owner) and leaves a
  syncing box `streaming`. [assumed]
- **SB94** PUT `/hue/groups/<id>` `{"active": false}` stops whoever streams
  to that area: if it is this box, it goes to `passthrough` and
  `connected`; if another app (`busy`), the area reads inactive without an
  owner and the state `connected`; an inactive area stays so. `{"active":
  true}` → 15; an id `hue.groups` does not hold → 10. [verified: S1
  `controllers/hue.py:58-61`, S2 `helpers.py:62-73` (stopping another
  app's stream, then syncing); the rest assumed]
- **SB95** PUT `/hue` `{"groupId": id}` (level 10 and later) selects an
  area as `hueTarget` does (SB48); below level 10 → 13. [verified: S1
  `controllers/hue.py:63-65`, `models/hue.py:78-79`; the refusal assumed]
- **SB96** The fakes refuse PUT `/hue` with `bridgeUniqueId`, `username`
  or `clientKey` with 13: a box accepts them and moves to another bridge in
  about 15 seconds, which the drivers must never ask for. [fake; the real
  behaviour is S1 `controllers/hue.py:67-79`, `README.md:19-31`;
  edge-cases rule 8]
- **SB97** Standalone (`hue.operatingMode` `standalone`): sync works with
  no bridge whatever `connectionState` reads, and stays out of `hue`;
  `hueTarget` and `groupId` → 16 whatever their value (an exception to
  SB21's order). [verified: S1 `models/hue.py:91-100`; S2
  `select.py:150`, `helpers.py:120-121`, `switch.py:44-49` (sync stays,
  the area goes); the refusal and the untouched `hue` assumed]
- **SB98** Selecting an area (SB48, SB95) while `connectionState` reads
  `invalidgroup` makes it `connected`. [verified: S2 `README.md:80` (after
  `invalidgroup`, choose the area again); S1 `README.md:31`]

## 9. HDMI ports

- **SB100** PUT `/hdmi/<port>` (`input1` to `input4` the model has, or
  `output`) takes `name` (non-empty text) and `type` (one of the 26 port
  types); a bad value → 15; `status` or `lastSyncMode` → 13; a port the
  model lacks, or PUT `/hdmi` itself → 10. [verified: S1
  `models/hdmi.py:33-37`, `models/enums.py:138-164`; the path and the
  refusals assumed (R1 §2.7)]

## 10. Device, rename, address

- **SB110** PUT `/device` takes `name` (non-empty text) and `ledMode` (0
  off, 1 normal, 2 dimmed); a bad value → 15. [verified: S1
  `models/device.py:32-40`, `models/enums.py:40-43`; the refusal assumed]
- **SB111** Other `device` keys → 13: read-only ones (`uniqueId`,
  `apiLevel`, …) on a box, and in the fakes also `action`, `update` and
  `bluetooth`, which a box accepts (a restart, a firmware update) and the
  drivers never send. [verified: S1 `models/device.py:32-40` (what a box
  accepts); the fakes' refusal of the three is fake (edge-cases B14)]
- **SB112** `rename` (renamed in the Hue Sync app) sets `device.name`; the
  unkeyed GET `/device` shows it too. [verified: S2 `coordinator.py:62-66`
  (a new name is picked up at the next poll)]
- **SB113** `device.uniqueId` and `device.deviceType` never change,
  whatever happens. [verified: S1 `models/device.py:47-55` (the label's
  id, the certificate's name)]
- **SB114** `address` (the box got another address) sets
  `device.ipAddress`; nothing else in the state changes. [verified: S1
  `models/device.py:56-57`; the rest assumed]

## 11. Firmware and restarts

- **SB120** `reboot`: for 30 seconds of the box's clock no request gets an
  answer (no HTTP status at all); then the box answers again with the state
  it had, registrations and tokens included. [assumed: the duration, and
  the state kept]
- **SB121** `firmware` with `version` and `api_level`: the box restarts as
  in SB120 and afterwards reports that `firmwareVersion` and `apiLevel`,
  `buildNumber` made from the version as the fixtures make it (major ×
  1000000 + minor × 10000 + patch × 100), and everything else kept.
  [verified: S1 `models/device.py:58-63` (the three fields); the rest is
  fake or assumed]
- **SB122** A level that rises to 10 or more adds the level-10 fields the
  state lacks: `hue.groupId` (= `hueTarget`), each
  `behavior.inputN.hpdInputPortSwitch` 0, `device.overheating` false,
  `device.bluetooth` true, and `verified` false on each registration; to 14
  or more, `behavior.soloMode` 0 and, on HSB2 and HSB3,
  `hue.operatingMode` `bridge`. A level never falls in the fakes. [verified:
  S1 `models/behavior.py:43-44, 82-83`, `models/hue.py:91-94`,
  `models/device.py:79-84`, `models/registrations.py:24-25` (which level
  adds what); the values assumed]

## 12. How the fakes run the rules

- **Clock.** Each fake has its own clock in milliseconds: the Lua fake the
  fake runtime's (`c4.now_ms`, moved by `c4.advance`), the Python model the
  clock it is given (wall time scaled by `--time-scale` in the server). The
  `advance` event moves it by `ms`. Only the pairing window (SB82), the
  restart (SB120, SB121) and the times written by SB49 and SB88 read it.
  [fake]
- **Idle time** passes only through the `idle` event (SB77): the fakes keep
  no idle timer. [fake]
- **The view.** Each fake gives the whole state as GET `/api/v1` would
  answer it with a valid token (SB72's masking applied, registrations
  without tokens), without counting as a request: `box.state()` in Python,
  `h:view()` in Lua. The scenarios' `state` and `absent` checks read it.
  [fake]
- **Events** take their arguments by name: `h:event(name, {input = …})` in
  Lua, `box.event(name, input=…)` in Python, with the names of contract §4
  (`input`, `status`, `minutes`, `state`, `name`, `registration`,
  `version`, `api_level`, `ms`, and `address` for SB114). [fake]

## 13. Transport (outside the scenarios)

These belong to the Python server and the Lua fake's transport, are tested
by their own specs and the end-to-end harness, and are not in the
scenarios.

- **ST1** HTTPS only, on port 443 for a box (the Python fake: any port it
  is given); the leaf names the box id as its common name and the model as
  its unit, under a private root. [verified: S1 `huesyncbox.py:86-87, 213`;
  A5 (an 8K box's leaf: common name the id, unit `HSB2`)]
- **ST2** One request is served at a time; others wait. [verified: S1
  `huesyncbox.py:97` (the box takes few connections); the queueing assumed]
- **ST3** A box usually answers within milliseconds, now and then after
  more than 2 seconds. [community: S2 issue 24, the maintainer]
- **ST4** The faults of contract §2 (silence, latency, 5xx, a dropped
  connection, a cut or oversized body, a redirect, another CA, another box
  id) are the fakes' own, on demand. [fake]

## 14. The scenarios file

`tests/fixtures/syncbox_scenarios.json` holds `version` 1 and the list
`scenarios`, in the format of contract §4, with these additions read only by
the two runners:

- per scenario: `title` (one line), `model` (a fixture name of
  `M.models`), `setup` (`"paired"`: before the steps the runner presses the
  button and registers `c4-hue`/`Scenario`, saving the token as `t`),
  `given` (dotted paths set in a copy of the fixture's state before the box
  starts), `assumed` (true when one of its rules is [assumed]);
- per request step: `raw` (a body sent as is, for SB16), and in `path` a
  `{name}` is replaced by the registration id saved with that token name;
- per `expect`: `body` (dotted paths into the answer's body, exact values),
  `body_absent`, `body_exact` (the whole body), `present` (state paths
  that must exist, any value), `changed` (state paths whose value differs
  from before the step) and `no_answer` (no HTTP status at all, SB120).

A request step without `expect` prepares the next ones and must answer 200;
an event step without `expect` checks nothing.

`token` is a saved name, `"wrong"` (sends `Bearer WRONG-TOKEN-NOT-REAL`) or
`"none"` (no `Authorization` header); left out, it is `t` in a `paired`
scenario and none otherwise. Event arguments are the step's other keys
(`{"event": "signal", "input": "input1", "status": "linked"}`). Dotted paths
split on `.`; ids with dashes (the areas) are fine. A scenario that a fake
fails is a bug in that fake (or in the scenario), never a skipped test.

## 15. What the fakes leave out

IR codes and learning, presets beyond running one (SB49: they come from
`given`), the Bluetooth light fields, a bridge change (SB96), device actions
(SB111), Wi-Fi, LED colours, the button's short presses, and the Play Screen
Sync camera (no HDMI; only its unkeyed device answer exists, `M.device.HSC001`).
None of these is written by the drivers.

## 16. The [assumed] rules and the check that settles each

Each check is a read or a write against the owner's box, done from the VM
with the drivers' registration or through a development build; "(hands)"
marks the few that need someone at the box, the TV or the Hue Sync app.

| Rule | What is assumed | House check |
| --- | --- | --- |
| SB2 | Code 10 for an unknown path; a scalar path is 404 | GET `/api/v1/nothing` and `/api/v1/execution/mode`; note status and code |
| SB5 | `lastSyncMode` (box and port) change as a sync mode is entered | Start game sync on HDMI 2, stop it, GET `/api/v1`: both read `game` |
| SB6 | `connected` again when sync stops | Stop sync; read `hue.connectionState` |
| SB7 | `groupId` follows `hueTarget` | PUT `hueTarget` to the other area; read `hue.groupId` |
| SB8 | No token in any answer | GET `/api/v1` and `/registrations`; search for the token |
| SB11 | An accepted PUT answers `{}` | PUT `{"brightness": 100}`; read the body |
| SB12 | Code 2 without a token | GET `/api/v1` without a token; note the code |
| SB13 | Code 2 for an unknown token, on `/device` and the POST too | The same three requests with a made-up token |
| SB15 | 404 code 10 for a method a path does not take | POST `/api/v1/execution`, DELETE `/api/v1/device` |
| SB18 | 13 for an unknown or read-only key | PUT `/execution` `{"colour": 1}` and `/device` `{"uniqueId": "X"}` |
| SB19 | 15 for wrong values in general | PUT `{"brightness": 300}` and `{"syncActive": "yes"}` |
| SB20 | A refused PUT applies nothing | PUT `{"brightness": 120, "mode": "ambient"}`; read brightness |
| SB21 | The order of the checks | PUT `{"colour": 1, "brightness": 300}`; expect 13 |
| SB33 | `syncActive: false` outside sync does nothing | In passthrough PUT `{"syncActive": false}`; read the mode |
| SB36 | A toggle sent as false does nothing | PUT `{"toggleSyncActive": false}` |
| SB37 | `toggleSyncMode` of the current mode stops sync | Sync video; PUT `{"toggleSyncMode": "video"}` |
| SB38 | Order video, music, game, wrapping; wakes | Sync video; PUT `{"cycleSyncMode": "next"}` three times; from powersave once |
| SB39 | Input change keeps the mode; does not wake | While syncing PUT `hdmiSource`; in powersave PUT `hdmiSource` alone (edge-cases §8 check 2) |
| SB40 | 15 for an input the box lacks | On the 1-input box PUT `{"hdmiSource": "input2"}` |
| SB41 | Input cycling order and wrapping | PUT `{"cycleHdmiSource": "next"}` on input 4 |
| SB42 | 15 outside 0 to 200 | PUT `{"brightness": 201}` |
| SB43 | Clamping; 15 beyond ±200 | Brightness 150, PUT `{"incrementBrightness": 100}`; then `-201` |
| SB44 | `intensity` outside sync writes `lastSyncMode`'s | In passthrough PUT `{"intensity": "subtle"}`; read the three modes |
| SB45 | `cycleIntensity` wraps | At `intense` PUT `{"cycleIntensity": "next"}` |
| SB46 | 15 for background lighting on music | Sync music; PUT `{"backgroundLighting": true}` |
| SB47 | 13 and 15 inside a mode object | PUT `{"music": {"colour": 1}}`, `{"music": {"palette": "x"}}` |
| SB48 | The stream moves with `hueTarget` | While syncing PUT the other area; read `hue.groups` |
| SB49 | 15 for an unknown preset | PUT `{"preset": "999"}` |
| SB50 | Settings apply in powersave without waking | In powersave PUT `{"brightness": 80}`; read the mode |
| SB51 | 15 for `ambient` | PUT `{"mode": "ambient"}` |
| SB55 | The order inside one PUT | In powersave PUT `{"hdmiActive": true, "hdmiSource": "input2", "syncActive": true}`; and `{"mode": "game", "intensity": "subtle"}` |
| SB56 | Judged on the whole result | While another app streams PUT `{"brightness": 50, "syncActive": true}`; read brightness |
| SB57 | A PUT sent again changes nothing more | In powersave PUT `{"hdmiActive": true, "hdmiSource": "input2", "mode": "game", "syncActive": true}` twice; compare `execution`, `hdmi` and `hue` after each |
| SB60 | `true`/`false` refused in `behavior`; no PUT of a part | PUT `/behavior` `{"cecPowersave": true}`, then put the value back; PUT `/behavior/input1` `{"cecInputSwitch": 1}` |
| SB61 | 15 outside 0 to 10000 | PUT `/behavior` `{"inactivePowersave": 10001}` |
| SB62 | 13 for a key the model lacks | On the 8K box PUT `/behavior` `{"forceDoviNative": 0}` |
| SB63 | `behavior` writes act at the next event only | Turn `cecInputSwitch` on; read the input; then wake a source (hands) |
| SB70 | CEC Active Source wakes the box | In powersave, wake a source with CEC (hands); read the mode |
| SB71 | Hot plug sets `plugged` and wakes | Plug a source in (hands); read its status and the mode |
| SB73 | When auto-sync fires; never on a request | Wake the box with `hdmiActive` onto a linked input with auto-sync on; read the mode; switch a source on (hands) |
| SB78 | `contentSpecs` empty without a link | Turn the source off (hands); read `hdmi` |
| SB80 | 15 for a missing name | POST `/registrations` `{"appName": "x"}` |
| SB82 | One registration per press | Press once (hands); POST twice |
| SB84 | Role `user`, `verified` false for a new one | After pairing GET `/registrations` |
| SB85 | Same names twice make two | Pair twice with the same names (hands) |
| SB86 | 2 for another's token; 10 for an unknown id | DELETE another id with the drivers' token; DELETE `/registrations/999` |
| SB88 | `lastUsed` moves with each request | GET twice a minute apart; read `lastUsed` |
| SB91 | 16 in every state but connected and streaming | Unplug the bridge (hands); PUT `{"syncActive": true}` |
| SB93 | What a link change does to a sync | Unplug the bridge while syncing (hands); read the mode |
| SB94 | The rest of stopping a stream | Stop the box's own area with `{"active": false}`; read the mode |
| SB95 | 13 for `groupId` below level 10 | Only on a level-9 box; none in the house: leave assumed |
| SB97 | `hueTarget` refused in standalone; `hue` untouched | Only on a standalone box; none in the house: leave assumed |
| SB100 | The path and the refusals | PUT `/hdmi/input4` `{"name": "HDMI 4"}`, then `{"status": "linked"}` |
| SB110 | 15 for an empty name | PUT `/device` `{"name": ""}` |
| SB114 | Only `ipAddress` changes | After the router moves the box (hands), GET `/api/v1` |
| SB120 | 30 seconds of silence; the state kept | Restart the box from the Hue Sync app (hands); time it; GET |
| SB121 | Everything else kept across an update | At the next firmware update, compare GETs before and after |
| SB122 | The values a new level adds | At the next update that raises `apiLevel`, read the new fields |

Rules not in the table are shown by their sources or are conventions of
the fakes; SB83, SB92's owner text, SB96, SB111's refusals, SB121's build
number and §12 need no check.
