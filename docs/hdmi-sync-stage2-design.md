# 2.0 beta stage 2: the sync box driver's client, pairing, identity and state

The coordinator's contract for the second of the four beta stages of #514
(design [`hdmi-sync-design.md`](hdmi-sync-design.md) §9.3, contracts
[`hdmi-sync-contracts.md`](hdmi-sync-contracts.md) C1, C2, C3, C5, C8, C9),
issue #534. Every builder works against this text. A change goes through the
coordinator.

Branch `feat/hdmi-sync-stage2-534`. Seven agents edit disjoint files at the
same time (§9). The coordinator integrates, runs `tools/check.sh` and
`tools/build.sh`, and commits.

## 1. What stage 2 delivers

1. **`hue_syncbox.c4z`, the fifth driver.** Added from Composer's driver
   list (O13). It pairs with one box (the button held, §4), proves the box's
   identity over a pinned TLS chain, polls it, and shows its state in
   Composer properties, including the wiring (O17, design 5.8).
2. **Its whole Composer frame, frozen from this first release:** the five
   proxies, the connections and the capabilities of contracts C1.1 to C1.3,
   exactly as written there. Adding a proxy or a connection later would cost
   every installer a controller reboot or a re-add.
3. **The bridge link** (contracts C5 without `STOP_AREA`): the bridge's
   provider connection id 2 "Hue Sync Boxes" (`HUE_SYNCBOX`), `HELLO`,
   `CONFIGURE`, `AREA` and `GOODBYE`, and the stream label of contracts C7
   naming the box device instead of `another app` (§6).
4. **Tests without a box:** a fake box in the fake runtime, hand-written
   fixtures for each model, specs for every module (contracts C8).

**Read-only towards the box.** Stage 2 writes to a box only to register
(`POST /registrations`) and to unregister (`DELETE /registrations/<id>`,
Forget Pairing). No `execution`, `behavior` or `device` write: routing is
stage 3; sync commands, the area choice, the two-way box name (O14), the
periods and the offers are stage 4. A proxy command that arrives now
(`ON`, `SET_INPUT`, a UI Button press) is logged at debug and answered
with Last Action `Not done: routing through the box comes in a later 2.0
beta`; nothing is sent to the box and no proxy notify is sent.

## 2. Facts (cite these in comments)

From [`syncbox-api-research.md`](syncbox-api-research.md) (R1) and
[`syncbox-architecture-research.md`](syncbox-architecture-research.md)
(R5). Facts marked [assumed] there stay assumed; the first install on the
house settles the ones named in §10.
- Base `https://<address>/api/v1`; keyed requests carry `Authorization:
  Bearer <token>` (R1 §2.1, §2.3).
- The certificate chains to the self-signed root `C=NL, O=Philips Hue,
  CN=root-hsb`, SHA-256 fingerprint
  `A8:4F:E4:D6:E4:B7:24:4D:45:D0:A0:03:4F:7E:E1:49:85:2C:EC:B5:2E:BA:7F:C1:2A:3A:CA:76:6E:E6:8C:74`;
  the leaf's CN is the box id (R5 §2.2). The id is checked in the
  application against `GET /device`'s `uniqueId`, as the bridge does.
- `GET /api/v1/device` answers without a key (R1 §2.5). `POST
  /api/v1/registrations` answers error code 16 until the button is held,
  then `{registrationId, accessToken}` (R1 §2.3). A 401 on a keyed request
  means not registered (R1 §2.14).
- The state is polled; the box has no event stream (R1 §2.12). One request
  at a time (R1 §2.13).
- `behavior.arcBypassMode` and `behavior.soloMode` name the wiring (R1
  §2.8; design 5.8).

## 3. The modules (`src/hue_syncbox/`)

`driver.lua` requires `syncbox.<module>` and `common.<module>`, as the
bridge's driver does. Every module takes its dependencies in `new(deps)`
(no globals but `C4` behind injected functions where the bridge's modules
do the same), so its spec runs without the driver. Every module has its
own spec under `tests/spec/syncbox_<module>_spec.lua`. Names below are the
interface; builders add private helpers freely and never change these.

`cb(ok, status, decoded, err)` is the client's callback everywhere: `ok`
true on 2xx with a decoded body, `status` the HTTP status or nil, `decoded`
the JSON body, `err` a short text through `https.peer_text`.

### 3.1 `syncbox/client.lua` (agent A)

- `client.new{ address, token, log, https }` → `c`. `https` defaults to a
  `common.https` instance made with `ca_bundle = "certs/hsb_ca.pem"`,
  `header_key = { name = "Authorization", prefix = "Bearer " }`,
  `max_keyed = 1`, `timeout = 6`, `connect_timeout = 3`,
  `max_body = 262144`, `log_prefix = "Sync box: "`.
- `c:set_address(a)`, `c:set_token(t)` (nil clears), `c:set_trusted(bool)`
  (the identity module's verdict; keyed requests wait until true).
- `c:get(path, cb)`, `c:put(path, body, cb)`, `c:post(path, body, cb)`,
  `c:delete(path, cb)`; `path` after `/api/v1` (`""`, `"/device"`,
  `"/registrations"`). `opts.unkeyed = true` (a fourth argument) sends no
  token: used for `GET /device` and `POST /registrations` only.
- **One request in flight**; the rest queue first in, first out, at most
  8 (a ninth is answered at once with `err = "busy"`). A keyed request
  never follows a redirect (abort on 3xx, as the bridge's keyed requests).
- **The token never appears** in a log line, a property, Last Action or an
  error text, not even at debug; the registration answer is never logged.

### 3.2 `syncbox/store.lua` (agent A)

- `store.new{ persist_get, persist_set, persist_delete }` (the driver passes
  `C4:PersistGetValue`, `C4:PersistSetValue`, `C4:PersistDeleteValue`).
- `s:load()` → `{ token, registration_id, box_id, address }` (any nil);
  `s:save(t)`; `s:clear()`. The token is saved with the encrypted flag
  (`PersistSetValue(name, value, true)`, R5 §2.5), the rest plain, and kept
  in memory after saving.

### 3.3 `syncbox/identity.lua` (agent A)

- `identity.new{ client, tlscheck, log }`. `tlscheck` is a
  `common.tlscheck` instance using the box's decoy bundle
  `certs/decoy.pem` (the same rule as the bridge, R5 §2.3).
- `i:check(address, expected_id, cb)`: the TLS self-check against the
  address, then unkeyed `GET /device`. `cb(result)` with
  `result = { ok, reason, device }`; `device = { id, name, model,
  firmware, api_level, device_type }` (ids upper-cased); `reason` one of
  `ok`, `not_pinned`, `inconclusive`, `unreachable`, `not_a_box`,
  `wrong_box` (an `expected_id` that differs), `camera` (`HSC001`, O2),
  `unknown_model` (answered, but no known `deviceType`: allowed with a
  warning, `ok = true`).
- `i:ok()` true only after a passing check at the current address;
  `i:reset()` on an address change. Calls `client:set_trusted`.

### 3.4 `syncbox/pairing.lua` (agent A)

- `pairing.new{ client, identity, store, timer, now, log, instance_name }`;
  `instance_name()` returns the Control4 device's name (cut to 32
  characters, the registration's `instanceName`; `appName` is `c4-hue`).
- `p:open(address, done)`: identity first (no expected id on a first
  pairing; the stored id when re-pairing); then a 2-minute window, one
  `POST /registrations` a second while it is open. Code 16 keeps waiting.
  On success: `store:save{ token, registration_id, box_id, address }`,
  `client:set_token`, `done{ ok = true, device = … }`. Otherwise
  `done{ ok = false, reason }`, reason `timeout`, `closed`, `refused`
  (any other error answer, its text kept), or `identity:<reason>`.
- **The window rule (N-9):** a token that arrives after the window closed,
  after `p:close()` or Forget Pairing, or for another address than the one
  opened, is discarded unstored.
- `p:close()`, `p:is_open()`, `p:remaining_s()`.
- `p:forget(done)`: keyed `DELETE /registrations/<id>`; then
  `store:clear()` and `client:set_token(nil)` whatever the answer.
  `done{ ok = true, deleted_on_box = bool }`. When the box did not answer,
  the driver's Last Action says the registration stays on the box until
  removed in the Hue Sync app.

### 3.5 `syncbox/state.lua` (agent B)

- `state.from_api(raw, prev)` → `model, changes` (or `nil, reason` for a
  body that is not the box's state). Every number through `common.num`,
  every text through `https.peer_text`. Unknown values never stop it; a
  field a model lacks is absent.
- The model: the fields of contracts C2, plus
  `wiring = "in_line" | "behind_receiver" | "second_output"` (from
  `behavior.soloMode`, then `behavior.arcBypassMode`, else in line) and
  `area_name` (from `hue.groups[<hueTarget>].name`). `changes` is the list
  of top-level field names that differ from `prev`.
- `state.describe(model)` → the property texts:
  - `sync`: `Video, high, brightness 100 %`, `Off (passthrough)`, `Power
    save`; the area is appended: `… on Living Room TV`.
  - `inputs`: `1 Apple TV (on), 2 PlayStation, 3 —, 4 —`.
  - `model`: `Hue Play HDMI Sync Box 8K (HSB2)`, `Hue Play HDMI Sync Box
    (HSB1)`, `Hue Play HDMI Sync Box 4K (HSB3)`, else the raw type.
  - `firmware`: `<firmwareVersion> (API level <n>)`.
  - `bridge_link`: `Hue Bridge 001788fffe123abc, connected` / `busy` /
    `invalid area` / `not linked`.
  - `input_switching`: what the box does by itself, as contracts C1.4.
  - `wiring`: `In line (sources → box → TV or receiver)`, `Behind a
    receiver (ARC bypass on)`, `From a receiver's second output (solo
    mode)`.
  - `refusal`: nil, or `Not supported: this box runs without a Hue Bridge
    (standalone mode)` (O2).

### 3.6 `syncbox/poller.lua` (agent B)

- `poller.new{ client, timer, now, log, on_state, on_offline, on_online,
  on_refused }`. `on_state(model, changes)` after every good read;
  `on_offline(since_ms)` once after 5 minutes without an answer (#428);
  `on_online()` once on the first good read after that; `on_refused(status)`
  on a 401 or 403 (it stops polling; the driver says the box forgot the
  registration and offers Pair Sync Box).
- `p:start()`, `p:stop()`, `p:soon(reason)`: a read in 1 s after a command
  (stage 3 on), at once on a bridge hint but at most once per 2 s.
- The cadence of contracts C2: 5 s while the box is on, 30 s in power
  save, 60 s after 3 failures in a row. Never two reads at once.

### 3.7 `syncbox/discovery.lua` (agent B)

- `discovery.new{ mdns, identity_for, timer, log }`. Uses `common.mdns`
  for `_huesync._tcp.local` with the rules of #490 (private or link-local
  addresses only, capped answers). `identity_for(address, cb)` is the
  identity check (§3.3); a candidate is listed only after its id answered
  over the pinned chain (contracts C3).
- `d:search(done)` → `done(list)`, `list` of `{ id, name, model, address
  }`, at most 8, sorted by name. `d:busy()`.
- The driver searches at first load, on Pair Sync Box, and every hour while
  no box is paired. Local only, never the internet.

### 3.8 `syncbox/link.lua` (agent C)

The box's side of contracts C5. `link.new{ send, log }`; `send(binding_id,
command, params)` is `C4:SendToDevice` through the driver.
- `l:hello(box_id, bridge_id, area_id)`, `l:goodbye(box_id)`; binding 1.
- `l:received(command, params)` → a checked table or nil:
  `{ kind = "configure", bridge_id, match, areas }` or `{ kind = "area",
  id, status, streamer }`. Every value checked (ids `^[%x%-]+$`, at most 64
  areas, names through `peer_text`); a malformed message is dropped with
  one log line (#483: a bridge message is only a hint).
- The box sends `HELLO` at late init, on binding, and when its `area` or
  `bridge.id` changes.

## 4. Pairing, step by step (the driver, agent G)

1. **Pair Sync Box** (contracts C1.5): Box is a found box or "Type an
   address"; Address is used for the latter. A search runs if the list is
   empty.
2. Status reads `Hold the button on the sync box for 3 seconds (1:58
   left)`, updated every 10 s, and Last Action says the same once.
3. Success: Last Action `Paired with Hue Sync Box (8K) #3ABC at
   10.0.2.150`, the rows fill, polling starts, `HELLO` goes to the bridge if
   bound. Failure: Last Action names the reason in words (§3.4).
4. **Forget Pairing** (Confirm Yes): §3.4; the rows clear except Box
   Address; polling stops; `GOODBYE` goes to the bridge.
5. **At start** with a stored token: identity with the stored id, then
   polling. `wrong_box` at the stored address: polling stops, Status
   `Another device answers at 10.0.2.150 (expected #3ABC); Pair Sync Box to
   find it`; the token is never sent there. A search for the stored id
   then runs; when found at a new address the address is followed (the
   identity proves it, R5 §3.4) and Last Action says so.

## 5. The driver's Composer surface in stage 2 (agent G)

- **`driver.xml`:** contracts C1 basics, C1.1 proxies, C1.2 connections and
  C1.3 capabilities exactly; the properties below; the actions Pair Sync
  Box, Diagnostics (Check the box now; Read everything from the box now;
  Show the box's raw state in the Lua output) and Forget Pairing. No
  commands, events, conditionals or variables yet (stage 4).
- **Properties** (contracts C1.4, the stage 2 rows, in this order):
  Driver Version, Debug Mode, Status, Online, Last Action and (2)–(6),
  Sync Box, Model, Firmware, Box ID, Box Address, Wiring (new, O17, read
  only), Sync, Inputs, Bridge Link, Input Switching.
- **Status** while unpaired: `Not paired: run Pair Sync Box`; with boxes
  found: `Not paired: 1 Hue sync box found (run Pair Sync Box)`. While
  paired and online: the `sync` text. Offline: `Offline since 21:04
  (10.0.2.150 does not answer)`.
- **Debug Mode** turns itself Off after 8 hours (#493), as on the bridge.

## 6. The bridge's side (agent C)

- **`src/hue_bridge/bridge/syncboxes.lua`** (new): the bound boxes,
  `{ [device_id] = { box_id, bridge_id, area_id, name } }`.
  - On `HELLO`: record it; answer `CONFIGURE` with `bridge_id` (this
    bridge's id), `match` (`true` when the box's `bridge_id` equals it) and
    `areas` (JSON list from `hue_model`'s areas: `{id, name, type, status,
    lamps, rooms}`). Again to every bound box after each resync.
  - When an area's stream starts or stops (the hook stage 1's
    `bridge/entertainment.lua` already has): `AREA` to every bound box,
    `streamer` `this_box` for the box whose `area_id` is the area,
    `other` for the rest, `none` when it stopped.
  - On `GOODBYE` or an unbind: forget the box.
  - `label_for(area_id)` → the Composer name of the one bound box whose
    `area_id` is that area, else nil.
- **`src/hue_bridge/bridge/entertainment.lua`:** the stream label is
  `label_for(area)` when it answers, else `another app` as today.
- The bridge's `driver.lua` and `driver.xml` (the connection, the binding
  calls) are the coordinator's: agent C writes the exact snippet into its
  hand-back.

## 7. Tests (agent D owns the fake and the fixtures)

- **`tests/fixtures/hue_syncbox.lua`:** hand-written from the public field
  names of R1 §2 (never copied from Signify's or a library's examples).
  `M.state.HSB1`, `M.state.HSB2`, `M.state.HSB3`, `M.state.HSB3_standalone`
  (the whole `GET /api/v1` body), `M.device.<model>` (the `GET /device`
  body), `M.registration_pending` (code 16), `M.registration_ok`
  (`{registrationId = "7", accessToken = "<placeholder>"}`), and the error
  bodies of R1 §2.14. HSB2 is wired in line; one variant each with
  `arcBypassMode` and `soloMode` set (`M.state.HSB2_behind_receiver`,
  `M.state.HSB2_second_output`). Box id `0A1B2C3D4E5F`, address
  `10.0.2.150`, bridge id `001788fffe123abc`; the token placeholder is
  `TEST-TOKEN-NOT-REAL`.
- **The fake box** in `tests/helpers/fake_c4.lua`:
  `fake.syncbox(opts)` → a handle that answers `C4:url` transfers to its
  address (`opts.address`, `opts.state` a fixture, `opts.device`,
  `opts.button_held` false, `opts.registrations` {}). It answers `GET
  /api/v1`, `GET /device`, `POST /registrations` (code 16 until
  `h:hold_button()`), `DELETE /registrations/<id>` and 401 to a wrong
  token, records every request in `h.requests` (method, path, headers
  without the token's value, body), and `h:silence(true)` makes it stop
  answering (timeouts). Transfers to other addresses keep going to
  `c4.transfers` as today. The decoy rule stays as it is.
- **More than one `<proxy>`:** the fake reads every `<proxy>` of a
  driver.xml; the first one is the device's main proxy as today, so the
  existing specs pass unchanged.
- **`.gitleaks.toml`:** the box id `0A1B2C3D4E5F` (and lower case) and
  `TEST-TOKEN-NOT-REAL` allowlisted; `src/hue_syncbox/certs/` allowlisted
  like the bridge's certs.
- **The driver spec** (`tests/spec/syncbox_driver_spec.lua`, agent G)
  covers pairing, Forget Pairing, start with a stored token, a wrong box,
  offline and back, a 401, a standalone HSB3, each wiring's row, and that
  a proxy command sends nothing.

## 8. Documentation (agent E)

- `src/hue_syncbox/www/documentation.html`: the new manual in the shape the
  other tabs share (read `src/hue_motion/www/documentation.html`): what
  the driver does in this beta and what comes later, adding and pairing,
  the three wirings and how to bind each in Composer (in line: box output
  to the receiver or TV; behind a receiver: receiver's output to box input
  1; second output: nothing bound to the box's output), every property,
  the actions, troubleshooting, the trademark and non-affiliation lines,
  and the `<!-- CHANGELOG -->` marker.
- `src/hue_bridge/www/documentation.html`: the "Hue Sync Boxes"
  connection and what it does.
- `CHANGELOG.md` Unreleased, `SECURITY.md` (the box's CA pin, the token,
  the address follow-up's residual risk), `README.md` (five drivers).

## 9. Writers (one per file)

| Agent | Files (and their specs) |
|---|---|
| **A** | new `src/hue_syncbox/syncbox/client.lua`, `store.lua`, `identity.lua`, `pairing.lua`; new `src/hue_syncbox/certs/hsb_ca.pem`, `certs/decoy.pem`; new `tests/spec/syncbox_client_spec.lua`, `syncbox_store_spec.lua`, `syncbox_identity_spec.lua`, `syncbox_pairing_spec.lua` |
| **B** | new `src/hue_syncbox/syncbox/state.lua`, `poller.lua`, `discovery.lua`; new `tests/spec/syncbox_state_spec.lua`, `syncbox_poller_spec.lua`, `syncbox_discovery_spec.lua` |
| **C** | new `src/hue_syncbox/syncbox/link.lua`, new `src/hue_bridge/bridge/syncboxes.lua`, `src/hue_bridge/bridge/entertainment.lua`; new `tests/spec/syncbox_link_spec.lua`, `syncboxes_spec.lua`, `tests/spec/entertainment_spec.lua` |
| **D** | `tests/helpers/fake_c4.lua`, new `tests/fixtures/hue_syncbox.lua`, `.gitleaks.toml`, new `tests/spec/fake_syncbox_spec.lua` |
| **E** | new `src/hue_syncbox/www/documentation.html`, `src/hue_bridge/www/documentation.html`, `CHANGELOG.md`, `SECURITY.md`, `README.md` |
| **G** | new `src/hue_syncbox/driver.lua`, `src/hue_syncbox/driver.xml`; new `tests/spec/syncbox_driver_spec.lua`; `tests/fixtures/ledger.lua` |
| **R** (research, read-only) | new `docs/syncbox-wirings-research.md` (#531) |
| Coordinator | this file, `src/hue_bridge/driver.lua`, `src/hue_bridge/driver.xml`, `tools/build.sh`, `tools/make_icons.py`, `src/hue_syncbox/www/icons/`, `deploy/house.yaml`, `CLAUDE.md`, `docs/README.md`, `docs/status.md`, integration |

Agents B, C and G write against the interfaces above while A and D build
them; a spec may stub a neighbour module through its `new(deps)`. An agent
that needs a change in a file it does not own asks the coordinator in its
hand-back and does not edit it.

## 10. Done, and what the house settles

- Each module has a spec; `tools/check.sh` passes (lint, tests, Lua
  limits, links, secrets, doc tabs); `tools/build.sh` builds five packages.
- The four existing drivers' `<capabilities>` and connections are
  unchanged except the bridge's new provider connection, so the install
  needs no controller reboot [assumed: a new connection on an existing
  device appears without one, design 9.3].
- On the house, with `v2.0-beta.2`: the box device is added to the bedroom,
  the owner holds the button, and the rows fill. That settles [assumed]
  facts of R5 §2.2: Director's curl verifies the box's chain and the box
  answers with no TLS server name.
