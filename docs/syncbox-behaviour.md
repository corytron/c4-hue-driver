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

The owner has a real box (a Play HDMI Sync Box 8K, HSB2) for a few minutes
only, and does at most a handful of things with his hands. So the 57
[assumed] rules are settled by the conformance probe,
`tools/fakebox/conformance.py`, run from the VM against the box, in this
order:

1. **Hands-on step 1** (`register --twice`): two presses of the box's
   button register the probe twice under the same names; the tokens go to
   `~/.config/c4-hue-driver/fakebox/probe.json` (mode 0600) and nowhere
   else.
2. **`run`** (about three minutes, no hands): every rule of table A. The
   lights and the TV picture change while it runs; it restores the box's
   settings after each check and everything at the end, and reads the box
   again to prove it.
3. **Hands-on steps 2 to 5** (`hands --step N`): the probe sets the box up,
   prints the one thing to do, reads the box meanwhile and restores it.
4. **`forget`**: the probe deletes its own registration.

The commands take `--address` (the box's address, never written to the
repository). Each verdict is confirmed, contradicted (with the box's real
answer) or not checked (with the reason), in `build/conformance/report.md`,
with every address, id, name and token replaced by the placeholders; the
redacted answers are kept under `build/conformance/fixtures/` for folding
into `tests/fixtures/`. A contradicted rule is rewritten to what the box
does, with both fakes and the scenarios, and loses its [assumed].

The probe pins the box's root (`src/hue_syncbox/certs/hsb_ca.pem`) and
checks that the leaf's common name is the `uniqueId` of the unkeyed GET
`/device` before any token leaves the VM, as `syncbox/identity.lua` does.
It never sends a bridge change (SB96), a device action, update or
Bluetooth change (SB111), anything to `/ir` or `/presets` but a GET, a
DELETE of a registration that is not its own, or a behavior key the box
lacks (but SB62's one key of another model, sent as 0); a guard refuses
those before the network. One request at a time, at least 250 ms apart,
503 and a transient 16 retried after 1, 2 and 4 s.

Counts: table A, 45 rows (42 rules whole, SB63, SB73 and SB78 in part);
table B, five steps settling 12 rules (SB56, SB63, SB73, SB78 and SB86 for
the part table A leaves); table C, 5 rules. On the way `run` also checks
these shown rules: SB1, SB3, SB4, SB10, SB14, SB16, SB17, SB30 to SB32,
SB34, SB35, SB64, SB72, SB90, SB111 and SB113.

### A. Checked by the VM probe (no hands)

| Rule | What is assumed | How the probe checks it |
| --- | --- | --- |
| SB2 | Code 10 for an unknown path; a scalar path is 404 | GET `/execution`, an input, a behavior input, an area and its own registration, each compared with GET `/api/v1`; GET `/nothing`, `/execution/mode` and an input the model lacks → 404 code 10 |
| SB5 | `lastSyncMode` (box and port) change as a sync mode is entered | From passthrough `{"mode": "game"}`; reads `execution.lastSyncMode` and the input's |
| SB6 | `connected` again when sync stops | Reads `hue.connectionState` and the area's `active` after a sync starts (streaming, active) and after it stops (connected, inactive) |
| SB7 | `groupId` follows `hueTarget` | `hueTarget` to the other area, then PUT `/hue` `{"groupId"}` back; reads both each time (one area: that they agree) |
| SB8 | No token in any answer | Searches every answer of the run for the probe's two tokens |
| SB11 | An accepted PUT answers `{}` | Every accepted PUT and DELETE of the run |
| SB12 | Code 2 without a token | GET `/device` without a token (no `wifi`, `update`, `ledMode`, `action`, `pushlink`); GET `/api/v1`, GET `/execution` and PUT `/execution` without one → 401 code 2 |
| SB13 | Code 2 for an unknown token, on `/device` and the POST too | GET `/device`, GET `/api/v1` and POST `/registrations` with a made-up token → 401 code 2 (a registration made by mistake is deleted at once) |
| SB15 | 404 code 10 for a method a path does not take | POST `/execution`, PUT `/api/v1` and POST `/device`, each with the current value; no DELETE is tried on a resource |
| SB18 | 13 for an unknown or read-only key | `{"colour": 1}`, `{"lastSyncMode": …}` and PUT `/device` `{"uniqueId": <its own>}` |
| SB19 | 15 for wrong values in general | `{"brightness": 300}`, `{"syncActive": "yes"}`, `{"brightness": "100"}` |
| SB20 | A refused PUT applies nothing | A good brightness with a bad `intensity`, then with a bad `hdmiSource` → 15; brightness unchanged |
| SB21 | The order of the checks | `{"colour": 1, "brightness": 300}` → 13; the same cut short → 12; POST `/registrations` with an empty `appName` before any press → 15, not 16 |
| SB33 | `syncActive: false` outside sync does nothing | In passthrough and in powersave; the mode read twice a second apart |
| SB36 | A toggle sent as false does nothing | `toggleSyncActive` and `toggleHdmiActive` false in passthrough, `toggleSyncActive` false in powersave; then each toggle true, twice |
| SB37 | `toggleSyncMode` of the current mode stops sync | Syncing game, `{"toggleSyncMode": "game"}` → passthrough; then `video` → video |
| SB38 | Order video, music, game, wrapping; counted from `lastSyncMode`; wakes | From video `next` three times and `previous` once; `next` from passthrough and from powersave |
| SB39 | Input change keeps the mode; does not wake | Syncing game, `hdmiSource` to another input: still game, now that input's `lastSyncMode`; in powersave `hdmiSource` alone: still powersave |
| SB40 | 15 for an input the box lacks | `{"hdmiSource": "input5"}` (`input2` on a one-input box) and `"hdmi1"` |
| SB41 | Input cycling order and wrapping | On the last input `cycleHdmiSource` `next` → `input1`, then `previous` → the last |
| SB42 | 15 outside 0 to 200 | 201 and −1 → 15; 0 and 200 read back |
| SB43 | Clamping; 15 beyond ±200 | 150 + 100 → 200, 50 − 100 → 0, 0 + 30 → 30; ±201 → 15 |
| SB44 | `intensity` outside sync writes `lastSyncMode`'s | In passthrough `{"intensity": …}`; reads the three modes' intensities |
| SB45 | `cycleIntensity` wraps | At `intense` `next` → `subtle`, then `previous` → `intense` |
| SB46 | 15 for background lighting on music | Syncing music, `backgroundLighting` and `toggleBackgroundLighting` → 15; in passthrough both act on `lastSyncMode`'s |
| SB47 | 13 and 15 inside a mode object | `{"music": {"colour": 1}}` → 13, `{"music": {"palette": "x"}}` → 15, `{"video": {"palette": …}}` → 13; `{"game": {"intensity": …}}` sets game's and keeps the mode |
| SB48 | The stream moves with `hueTarget`; an unknown area refused | An unknown area → 15; syncing, `hueTarget` to the other area reads as sent, the old area inactive, the new one active |
| SB49 | 15 for an unknown preset | `{"preset": <an id presets does not hold>}` |
| SB50 | Settings apply in powersave without waking | In powersave brightness, `video` intensity and the area; each read back with the mode, twice |
| SB51 | 15 for `ambient` | `{"mode": "ambient"}` and `{"mode": "off"}` (the mode put back at once if one is taken) |
| SB55 | The order inside one PUT | In powersave `{"hdmiActive": true, "hdmiSource": <another>, "syncActive": true}`; syncing music `{"mode": "game", "intensity": …}` |
| SB56 | Checked whole; 16 judged on the result | `{"hdmiSource": <another>, "brightness": 300}` → 15 and the input unchanged; the refusal by state: step 4 |
| SB60 | `true`/`false` refused in `behavior`; no PUT of a part | `{"cecPowersave": true}` → 15 and the number taken; PUT `/behavior/input1` with its current value → 10 |
| SB61 | 15 outside 0 to 10000 | 10001 and −1 → 15; 10000 and 0 read back |
| SB62 | 13 for a key the model lacks | The behavior keys against the model and level; `{"forceDoviNative": 0}` on a box without it → 13 |
| SB63 | (in part) `behavior` writes act at the next event only | CEC, hot-plug and auto-sync switching turned on in passthrough: mode and input unchanged two seconds later; the event half: step 2 |
| SB73 | (in part) Auto-sync never on a request | With a source on: `linkAutoSync` 1, powersave, then `{"hdmiActive": true}`: passthrough, no sync; the link half: step 2 |
| SB78 | (in part) `contentSpecs` empty without a link | Each input selected in turn: a linked one shows specs, true and true, another `""`, false and false; with no source on: step 2 |
| SB80 | 15 for a missing name | POST without `instanceName`, and with an empty `appName`, before any press → 15 |
| SB84 | Role `user`, `verified` false for a new one | The probe's registrations as GET `/api/v1` lists them |
| SB86 | 2 for another's token; 10 for an unknown id | DELETE `/registrations/<an id it does not hold>` → 10; step 1's second registration deleted with the first's token → 2 and still listed, then with its own → 200 `{}` and its token refused |
| SB88 | `lastUsed` moves with each request | Read twice 2 s apart, and against the run's first read |
| SB94 | The rest of stopping a stream | Syncing, PUT `/hue/groups/<its area>` `{"active": false}` → passthrough and connected; again → 200 and nothing; `{"active": true}` → 15; an unknown area → 10 |
| SB100 | The path and the refusals | PUT `/hdmi/<last input>` renames it (put back); `status`, `lastSyncMode` → 13; a bad `type`, an empty `name` → 15; an input the model lacks and PUT `/hdmi` → 10 |
| SB110 | 15 for an empty name | `{"name": ""}` and `{"ledMode": 3}` → 15; the current name and LED mode taken |

### B. Hands-on, five steps

Each step is one physical action (steps 1 to 4 do it and undo it); the
probe prints what to do and when, and reads the box once or twice a second
meanwhile. Steps 2 and 3 need a source on an input of the box whose picture
reaches the TV, with HDMI-CEC on (most streamers and consoles).

| Step | Physical action | Settles | What the owner does | What the VM reads meanwhile |
| --- | --- | --- | --- | --- |
| 1 | Press the box's button twice, about 10 s apart | SB82, SB85; lets `run` check SB84 and SB86's other-token half | While `register --twice` runs, hold the button about 3 s until the LED blinks green; again when the probe asks | POST `/registrations` once a second; after each registration one more POST at once (16 expected: one per press); the second under the same names |
| 2 | Turn a source off with its own remote, then on again | SB63, SB70, SB73, SB78 (also SB72, SB74) | When asked, the source on input K to standby; when asked again, back on | Sets K's `cecInputSwitch` and `linkAutoSync` to 1 and hot-plug switching off, syncs on K; reads until K stops reading linked (the sync ends, `contentSpecs` empty); puts the box in powersave on another input; reads until K is selected and awake (CEC), then syncing (auto-sync), `contentSpecs` filled |
| 3 | Pull a source's HDMI cable out of the box, then push it back | SB71 (also SB72) | When asked, the cable of input K out; when asked again, back in | Sets K's `cecInputSwitch` and `linkAutoSync` to 0 and `hpdInputPortSwitch` to 1, powersave on another input; reads K unplugged, then at least plugged, then K selected and the box awake |
| 4 | Pull the Hue Bridge's network cable (power stays on), then plug it back | SB56, SB91, SB93 | When asked, the bridge's network cable out for about a minute; when asked, back in | Syncs; reads until the link leaves streaming (sync ended, areas inactive); `{"syncActive": true}` → 16; `{"brightness", "syncActive": true}` → 16 and brightness kept; `{"mode": "video", "syncActive": false}` → 200; once connected again: passthrough, no area active, and a sync starts |
| 5 | Restart the box from the Hue Sync app | SB120 | The app's restart for this box, when asked | Unkeyed GET `/device` every second: how long nothing answers; then GET `/api/v1` with the probe's token: the state, registrations and token as before |

The rules each step settles:

| Rule | Step | What is assumed |
| --- | --- | --- |
| SB82 | 1 | One registration per press |
| SB85 | 1 | The same names registered twice make two |
| SB86 | 1 | 2 for another registration's token (read by `run`) |
| SB63 | 2 | The event follows `behavior` values written just before |
| SB70 | 2 | CEC Active Source selects the input and wakes the box |
| SB73 | 2 | Auto-sync starts when the selected input and the output link |
| SB78 | 2 | `contentSpecs` and the two flags with and without a link |
| SB71 | 3 | Hot plug sets at least `plugged`, selects the input and wakes the box |
| SB56 | 4 | A refusal by state is judged on the whole PUT's result |
| SB91 | 4 | 16 in every link state but connected and streaming |
| SB93 | 4 | What a link change does to a sync |
| SB120 | 5 | 30 seconds of silence; the state kept |

### C. Accepted without a house check

| Rule | What is assumed | Why the driver is safe either way |
| --- | --- | --- |
| SB95 | 13 for `groupId` below level 10 | Only a box below API level 10 shows it (`run` checks it when the box is one). The box driver sends no PUT at all in this stage and reads the area from `hueTarget`, else `groupId` (`tests/spec/syncbox_state_spec.lua`, "takes the area from hue.groupId when execution has no hueTarget") |
| SB97 | `hueTarget` refused in standalone; `hue` untouched | Only a box run without a bridge (`run` checks it when the box is one). The driver refuses a standalone box in Status and never writes `hueTarget` (`tests/spec/syncbox_driver_spec.lua`, "refuses a standalone HSB3 in Status (O2)") |
| SB57 | A set-value PUT sent again changes nothing more | The queue resends only whole set-value writes (no toggles, cycles or increments) and confirms each by reading the state back, so a resend that changed something else would show at the next read (`tests/spec/syncbox_queue_spec.lua`, the retry cases) |
| SB114 | Only `ipAddress` changes with the address | Needs the router to move the box. The driver finds the box again by its id, not its address (`tests/spec/syncbox_driver_spec.lua`, "follows the box to a new address the search finds, after the identity proved it (EC B11)"), and reads the whole state at every poll, so anything else a move changed shows at the next one |
| SB121 | Everything else kept across a firmware update | Needs an update from Signify, which takes many minutes. The driver keeps nothing of the box's but its id, address and token, and reads the firmware and level at every poll (`tests/spec/syncbox_state_spec.lua`, "writes the firmware with whatever is known"); the restart itself is SB120, step 5 |
| SB122 | The values a new level adds | Needs an update that raises `apiLevel`. The driver reads every field a level adds as optional (`tests/spec/syncbox_state_spec.lua`, "leaves out what an older box lacks (HSB1 at API level 7)"), so their first values change nothing it does |

Rules in none of the tables are shown by their sources or are conventions
of the fakes; SB83, SB92's owner text, SB96, SB111's refusals, SB121's build
number and §12 need no check.
