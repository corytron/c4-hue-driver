# 2.0 contracts: the Hue Sync Box driver, its messages and the bridge's changes

The contracts that go with [`hdmi-sync-design.md`](hdmi-sync-design.md)
(#514). Status: **proposed, for review with the owner** (2026-11-13). Names,
ids and texts here become fixed at release, so the review is the time to
change them. Each builder works against this text and nothing else, and a
change to it goes through the coordinator.

- C1 is the box driver's Composer and programming surface (`driver.xml`).
- C2 is the part of the box's API the driver uses, and the state model.
- C3 is the Lua modules and their interfaces.
- C4 is AV routing and sequencing.
- C5 is the messages between the bridge and the box.
- C6 is the bridge's changes.
- C7 is the light, zone light and scene changes while lamps stream.
- C8 is tests, fixtures and placeholders.
- C9 is build, release and docs.

Facts marked [verified] or [assumed] in the research stay as marked there. A
contract item that rests on an [assumed] fact names the probe or check that
settles it.

## C1. `src/hue_syncbox/driver.xml`

- **Basics.** `<name>Hue Sync Box</name>`, manufacturer Philips Hue, model
  "Hue Play HDMI Sync Box (local API)", `control` `lua_gen`,
  `controlmethod` IP, `minimum_os_version` 3.3.0, `<script jit="1">`.

### C1.1 Proxies

| Id | Proxy | Name | Why |
|---|---|---|---|
| 5001 | `avswitch` | Hue Sync Box | The HDMI switch (design 5.1) |
| 5002 | `uibutton` | Hue Sync | The Watch-menu button (design 5.6; only if Q7 keeps it) |

### C1.2 Connections (fixed for good once released)

| Id | Type | Name | Consumer | Class | Proxy binding |
|---|---|---|---|---|---|
| 1000–1003 | 5 video | HDMI 1 … HDMI 4 | True | `HDMI` | 5001 |
| 2000 | 5 video | HDMI Out | False | `HDMI` | 5001 |
| 3000–3003 | 6 audio | HDMI 1 … HDMI 4 | True | `HDMI` | 5001 |
| 4000 | 6 audio | HDMI Out | False | `HDMI` | 5001 |
| 1 | 1 control | Hue Bridge | True | `HUE_SYNCBOX` | — |

Input n of the box is video 999+n and audio 2999+n. The output is 2000 and
4000. All four inputs exist on every model (design 5.1).

### C1.3 Capabilities (frozen before `v2.0-beta.1`)

- `video_consumer_count` 4, `video_provider_count` 1.
- `audio_consumer_count` 4, `audio_provider_count` 1.
- `can_switch` True, `has_discrete_input_select` True.
- `can_switch_separately` False, `requires_separate_switching` False.
- `can_upclass` False, `can_downclass` False.
- Every volume, mute, tone and loudness capability False.
- `has_audio_signal_sense` False, `has_video_signal_sense` False.

### C1.4 Properties

| Name | Type | Values / default | Read-only |
|---|---|---|---|
| Driver Version | STRING | the build (`<build>-dev` on dev builds) | yes |
| Debug Mode | LIST | Off, On / Off (turns itself Off after 8 h, #493) | no |
| Status | STRING | e.g. `Syncing video on HDMI 2 (Apple TV) to Living Room TV` | yes |
| Online | STRING | `Online` / `Offline since <time>` | yes |
| Last Action, Last Action (2)–(6) | STRING | as on the bridge | yes |
| Sync Box | STRING | the box's name in the Hue Sync app | yes |
| Model | STRING | e.g. `Hue Play HDMI Sync Box 8K (HSB2)` | yes |
| Firmware | STRING | the box's version and API level | yes |
| Box ID | STRING | the paired `uniqueId` | yes |
| Box Address | STRING | the address in use | yes |
| Sync Boxes Found | DYNAMIC_LIST | the boxes discovery found, for Pair Sync Box | no |
| Entertainment Area | DYNAMIC_LIST | the box's areas by name; selecting one writes `hueTarget` | no |
| Inputs | STRING | `1 Apple TV (on), 2 PlayStation, 3 —, 4 —`; one input on HSB3 | yes |
| Sync | STRING | `Video, high, brightness 100 %` or `Off (passthrough)` or `Power save` | yes |
| Bridge Link | STRING | `Hue Bridge 001788fffe123abc, connected` / `busy` / `invalid area` / `not linked` | yes |
| When Control4 Selects An Input | LIST | As the box decides, Start syncing, Pass the picture only / As the box decides | no |
| At Room Off | LIST | Power save, Stop syncing and keep the picture / Power save | no |
| Input Switching | STRING | what the box does by itself: `By the box: HDMI CEC and hot-plug; auto-sync on HDMI 1, 2` | yes |

### C1.5 Actions

| Action | Parameters | Does |
|---|---|---|
| Pair Sync Box | Box (DYNAMIC_LIST: the Sync Boxes Found, or "Type an address"), Address (STRING) | Identity check, then a 2-minute window for the button |
| Sync Box Settings | What (DYNAMIC_LIST: Let Control4 choose inputs; Restore the box's input switching; Take over sync from another app) | The offers (design 5.4, 7.3) |
| Diagnostics | What (LIST: Check the box now; Read everything from the box now; Show the box's raw state in the Lua output) | As the bridge's Diagnostics |
| Forget Pairing | Confirm (LIST: No, Yes) | Deletes the registration; keeps the device |

### C1.6 Commands (programming)

| Command | Parameters |
|---|---|
| Start Sync | — |
| Stop Sync | — |
| Toggle Sync | — |
| Set Sync Mode | Mode (LIST: Video, Music, Game) |
| Set Intensity | Intensity (LIST: Subtle, Moderate, High, Intense) |
| Set Brightness | Brightness (RANGED_INTEGER 0–200 %, where 100 % leaves the picture's brightness as is) |
| Adjust Brightness | Step (RANGED_INTEGER −200 to 200) |
| Set Entertainment Area | Area (DYNAMIC_LIST) |
| Apply Sync Settings | Mode, Intensity, Brightness, Area, Start (LIST: Leave, Start, Stop): each optional, sent as one PUT, the mode before the intensity |
| Power Save | — |
| Wake | — |
| Select HDMI Input | Input (LIST: HDMI 1 … HDMI 4). Its description warns that the Control4 room does not follow it. |

### C1.7 Events (ids fixed; never renumbered)

| Id | Event |
|---|---|
| 1 | Sync Started |
| 2 | Sync Stopped |
| 3 | Sync Mode Changed |
| 4 | Intensity Changed |
| 5 | Brightness Changed |
| 6 | HDMI Input Changed |
| 7 | Entertainment Area Changed |
| 8 | Area Busy |
| 9 | Powered On |
| 10 | Power Save |
| 11 | Online |
| 12 | Offline |

### C1.8 Conditionals

| Conditional | Type |
|---|---|
| Sync Active | BOOL |
| Sync Mode | LIST: Video, Music, Game, Off |
| Intensity | LIST: Subtle, Moderate, High, Intense |
| HDMI Input | LIST: HDMI 1 … HDMI 4 |
| Brightness | NUMBER |
| Powered On | BOOL |
| Online | BOOL |

### C1.9 Variables (`C4:AddVariable` in this order, in `OnDriverInit`)

1. SYNC_ACTIVE (BOOL)
2. SYNC_MODE (STRING: video, music, game, off)
3. INTENSITY (STRING)
4. BRIGHTNESS (NUMBER, 0–200)
5. HDMI_INPUT (INT, 1–4)
6. HDMI_INPUT_NAME (STRING)
7. ENTERTAINMENT_AREA (STRING, the name)
8. POWER (STRING: on, powersave)
9. ONLINE (BOOL)

Every variable is set before the event that reports its change fires. At
start, variables come from persisted values, and no event fires for a value
that did not change (design 5.5).

## C2. The box's API as the driver uses it

From `syncbox-api-research.md` §2. The base is `https://<address>/api/v1`,
with `Authorization: Bearer <token>` on keyed requests.

| Request | Keyed | Used for |
|---|---|---|
| `GET /api/v1/device` | no | Identity before pairing and before every first keyed request (C3, `identity`) |
| `POST /api/v1/registrations` `{appName, instanceName}` | no | Pairing; answers code 16 until the button is held, then `{registrationId, accessToken}` |
| `DELETE /api/v1/registrations/<id>` | yes | Forget Pairing |
| `GET /api/v1` | yes | The whole state, every poll |
| `PUT /api/v1/execution` | yes | `mode`, `syncActive`, `hdmiActive`, `hdmiSource`, `hueTarget`, `brightness`, `incrementBrightness`, the mode's `intensity` |
| `PUT /api/v1/behavior` | yes | Only on the offers' clicks: per input `input<n>.cecInputSwitch`, `input<n>.hpdInputPortSwitch` (API level 10) and `input<n>.linkAutoSync`; on HSB1 and HSB2 the box-wide `hpdInputSwitch` (`syncbox-api-research.md` §2.8) |

- **`appName`** is `c4-hue`. **`instanceName`** is the Control4 device's
  name, cut to the box's limit.
- **Polling:** every 5 s while the box is on, 30 s in power save, 1 s after
  a command, and at once on a bridge hint (at most once per 2 s). It backs
  off to 60 s after failures. Connect timeout 3 s, total 6 s; one request
  in flight; bodies over 256 KB refused.
- **Offline** after 5 minutes without an answer, as #428.

**The state model** (`syncbox/state.lua` builds it from `GET /api/v1`; every
value through `num.lua`, every text capped by `http.peer_text`):

| Field | From | Values |
|---|---|---|
| `id`, `name`, `model`, `firmware`, `api_level` | `device` | `model` is one of `HSB1`, `HSB2`, `HSB3`, `HSC001`, else `unknown` |
| `inputs` | `hdmi.input1`…`input4` | a list of `{n, name, type, status}`, as many as the box has |
| `power` | `execution.hdmiActive` | `on` / `powersave` |
| `mode` | `execution.mode` | `video`, `music`, `game`, `passthrough`, `powersave`, `unknown` |
| `syncing` | `execution.syncActive` | true / false |
| `input` | `execution.hdmiSource` | 1–4 |
| `area` | `execution.hueTarget` | the id, and its name from `hue.groups` |
| `brightness` | `execution.brightness` | 0–200 |
| `intensity` | `execution.<mode>.intensity` | `subtle`, `moderate`, `high`, `intense` |
| `bridge` | `hue.bridgeUniqueId`, `hue.connectionState` | the id, and the state (`connected`, `streaming`, `busy`, `invalidgroup` …) |
| `standalone` | `hue.operatingMode` (API level 14) | true on an HSB3 in standalone mode |
| `behavior` | `behavior` | the input switching and auto-sync flags, for Input Switching and the offers |

Unknown values never stop the driver. A field a model lacks is absent, never
required.

## C3. Lua modules (`src/hue_syncbox/`)

`driver.lua` wires these modules together, as the bridge's `driver.lua`
does. Each module has its own spec.

| Module | Interface (sketch; builders refine names, never behaviour) |
|---|---|
| `syncbox/client.lua` | `client.new(ctx)`; `c:get(path, cb)`, `c:put(path, body, cb)`, `c:post(path, body, cb)`, `c:delete(path, cb)`; `cb(ok, status, decoded, err)`. Uses `common/https.lua`. One request in flight, a queue behind it, keyed only after `identity:ok()`. |
| `syncbox/identity.lua` | `identity.new(ctx)`; `i:check(address, cb)`: TLS self-check plus `GET /device` and its `uniqueId`; `i:ok()`; `i:recheck(cb)` |
| `syncbox/pairing.lua` | `pairing.new(ctx)`; `p:open(address, done)`: the 2-minute window, POST once a second, the N-9 rule; `p:forget(done)` |
| `syncbox/poller.lua` | `poller.new(ctx)`; `p:start()`, `p:stop()`, `p:soon(reason)` (after a command or a hint); the cadence of C2 |
| `syncbox/state.lua` | `state.from_api(raw, prev)` → the model of C2 plus the list of changes since `prev` |
| `syncbox/queue.lua` | `queue.new(ctx)`; `q:set(fields, tag)` coalesces execution fields to their latest; `q:flush()`: one PUT, mode before intensity; `on_done(tag, ok, state)` |
| `syncbox/av.lua` | The proxy side of C4: `av.received(command, params)` → intents for the queue; `av.confirm(state)` → `INPUT_OUTPUT_CHANGED`, `ON`, `OFF` notifies |
| `syncbox/discovery.lua` | `_huesync._tcp` through `common/mdns.lua`, with the #490 rules; candidates are listed only after their id answered over the pinned connection |
| `syncbox/link.lua` | The `HUE_SYNCBOX` binding (C5) |
| `syncbox/programming.lua` | Commands, events, conditionals and variables (C1.6–C1.9) |
| `syncbox/offers.lua` | The Sync Box Settings choices and Attention |

**Moved into `src/common/`** before the box driver exists (beta stage 1):
- `common/https.lua`: the bridge's HTTPS core, with its CA bundle, peer
  text and transfer caps as parameters;
- `common/tlscheck.lua`;
- `common/mdns.lua`.

The bridge's modules call them, and the bridge's specs pass unchanged.

## C4. AV routing and sequencing

| From the proxy (5001) | The driver |
|---|---|
| `ON` | Queues `hdmiActive: true` (and the mode the setting asks for); sends `ON` to the proxy once the box reads on |
| `SET_INPUT {INPUT, OUTPUT, AUDIO, VIDEO}` | Input n = `INPUT − 999` for video or `− 2999` for audio; an n the box lacks is refused with Last Action `Not switched: this box has 1 HDMI input`. Queues `hdmiSource: inputN` (with wake if in power save, and the "When Control4 Selects An Input" setting). Confirms `INPUT_OUTPUT_CHANGED {INPUT, OUTPUT, AUDIO, VIDEO}` only when a read shows the input. Retries every 2 s, 4 tries, then Last Action `Not switched: the box did not change input` |
| `OFF`, `DISCONNECT_OUTPUT` | The "At Room Off" setting: `mode: powersave`, or `syncActive: false` with HDMI on; `OFF` to the proxy once done |
| `CONNECT_OUTPUT` | Nothing beyond noting it |
| `BINDING_CHANGE_ACTION {BINDING_ID, IS_BOUND}` | Notes which inputs are bound (for Inputs and the source names) |
| `GET_AUDIO_INPUTS`, `SET_ROOM_BINDING_NAME`, volume and tone commands | Ignored |

Changes the box makes by itself are reported only in properties, variables
and events (C1), never as AV notifications that would move a room.

Probes P1–P7 (Control4 research §6) settle the command order at Room Off,
the parameter shapes, and whether `PREV_DEV_LIST` matters. The contract is
amended from their results before beta stage 3.

## C5. Bridge ↔ box messages (binding `HUE_SYNCBOX`)

All values are strings, as the existing messages are.

| Message | Direction | Params | Meaning |
|---|---|---|---|
| `HUE_SYNCBOX_HELLO` | box → bridge | `box_id`, `bridge_id` (the box's own link), `area_id` | At late init and on binding |
| `HUE_SYNCBOX_CONFIGURE` | bridge → box | `bridge_id`, `match` (`true` when the box is linked to this bridge), `areas` (JSON list of `{id, name, type, status, lamps, rooms}`) | The answer to a hello, and after every resync |
| `HUE_SYNCBOX_AREA` | bridge → box | `id`, `status` (`active`/`inactive`), `streamer` (`this_box`/`other`/`none`) | A stream starts or stops on any area. The box reads its own state at once; nothing else changes |
| `HUE_SYNCBOX_STOP_AREA` | box → bridge | `area_id` | Only from the "Take over sync" click: the bridge PUTs `action: stop` on the area with its own key (check T6) |
| `HUE_SYNCBOX_GOODBYE` | box → bridge | `box_id` | Unbind or removal |

The trust rules of #483 apply on both sides:
- A box acts on bridge messages only as hints.
- The bridge acts on `STOP_AREA` only for an area that exists, and logs the
  sender.
- The bridge's key never travels.

## C6. The bridge's changes (`src/hue_bridge/`)

- **Resync.** Two more GETs: `/resource/entertainment_configuration` and
  `/resource/entertainment`. `hue_model` keeps areas (id, name, type,
  status, active_streamer, channel lamps) and each lamp's `mode`.
- **Events.** Area `update` events and a lamp's `mode` changes are handled.
  A stream start or stop sends `HUE_SYNCBOX_AREA` to every bound box, and
  the light messages of C7.
- **Composer.**
  - A new row, **Entertainment Areas**: `Living Room TV (5 lamps, syncing:
    Living Room sync box) | Office (3 lamps)`.
  - New events on the bridge, **Sync Started** (id 1) and **Sync Stopped**
    (id 2), with the area in the bridge's Last Action. These are the first
    events on the bridge driver.
- **The connection.** Provider connection id 2 "Hue Sync Boxes", class
  `HUE_SYNCBOX` (design 4.2).
- **Never written:** areas, their "light state after streaming" setting,
  and a stream (except `STOP_AREA` after its click).

## C7. Lights, zone lights and scenes while lamps stream

- **`HUE_STATE`** gains `streaming` (`"true"`/`"false"`) and
  `stream_label` (who streams: the box device's name, or `another app`).
  `docs/lights-design.md` is amended.
- **Zone lights** get `streaming_lamps` and `lamps` counts with their
  state. Their state is computed from the lamps that are not streaming.
- **Hue Scenes** get `streaming_lamps` with `HUE_SCENE_GROUP`. Keypad Follows
  "Room/zone lights" reads only the lamps that are not streaming.
- **A light device whose lamp streams:**
  - Status reads `Syncing with the TV (<stream_label>)`.
  - It never goes offline because of the stream.
  - A command is answered at once with the known state (CHANGING, then
    CHANGED at the level it knows), and Last Action reads `Not changed:
    the lamp follows the TV while it syncs (<stream_label>)`. This is the
    Q9 default; the other answer ends the sync first.
- **Departure D21** in `docs/c4-lighting-guidelines.md`: while a stream
  runs, Hue reports no state for a streamed lamp, so L6, L9, L53 and L68
  cannot be met then.
- **Checks T0–T9** settle what the bridge answers, before beta stage 1
  merges.

## C8. Tests, fixtures and placeholders

- **The fake box** in `tests/helpers/fake_c4.lua`: a responder for `C4:url`
  transfers to a box address, answering from a fixture state and recording
  PUTs. The AV switch proxy in the fake runtime (a second `<proxy>` parsed).
- **`tests/fixtures/hue_syncbox.lua`:** hand-written from the public field
  names (never copied from Signify's examples), one state per model (HSB1,
  HSB2, HSB3 with a bridge, HSB3 standalone), and the error answers. It is
  replaced by recordings from a real box when one is available.
- **New placeholders** before the first fixture is committed:
  - a box id `0a1b2c3d4e5f`, invented, because real ids start with an OUI
    the secrets check refuses;
  - a box address `10.0.2.150`.

  Both go into `.gitleaks.toml`'s allowlist and `CLAUDE.md`.
  `src/hue_syncbox/certs/` is allowlisted like the bridge's certs.
- **The ledger** (`tests/fixtures/ledger.lua`) gains the box driver's rows.
  The `lua_limits` rule applies.

## C9. Build, release and documentation

- **Build.** `tools/build.sh` builds `hue_syncbox.c4z` with the others. The
  release attaches five packages. `deploy/house.yaml` names `hue_syncbox`
  in the first 2.0 desired-state PR. The brief reads the box device's
  Status when one exists.
- **Docs.**
  - `src/hue_syncbox/www/documentation.html`, the new manual, in the shape
    the other tabs share.
  - The bridge manual gains a chapter on sync boxes and entertainment
    areas.
  - The Hue Light and Scene manuals gain "While the TV syncs".
  - The README and `docs/status.md` follow.
- **`SECURITY.md`** gains the box: its CA pin, the token, the address
  follow-up's residual risk.
- **`CHANGELOG.md`:** each PR adds its lines.
- **The codename for 2.0** goes into `.github/codenames.json` and its blurb
  into `.github/codename-notes.json` before the first build.
- **The `until 2.0` promises** (Q15) are settled in that same first commit,
  so the ledger spec passes.
