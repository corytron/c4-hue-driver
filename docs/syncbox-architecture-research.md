# Hue Play HDMI Sync Boxes: architecture, networking, security and testing (research R5, #514)

> **Research for issue #514 (2.0), 2026-11-13.** Read-only: no code was
> changed. It answers the architecture, networking, security, integration,
> testing and release-train questions of the sync box feature. Five other
> research documents of #514 cover the box's API, entertainment areas,
> Control4 HDMI switching, the lifecycle edge cases and comparable drivers;
> where an answer depends on theirs it says so.
>
> **Status key.** **[verified: source]** = read in the named file (with
> line numbers for this repository) or at the named public URL;
> **[assumed]** = not confirmed, to be settled by the other research of
> #514 or on hardware. Abbreviations: `API/` =
> `~/c4-tools/reference/docs-driverworks-api/source/includes/`, `FUND/` =
> `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/`,
> `PP/` = `~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/`.
> Public code read on 2026-11-13: **AIO** =
> [aiohuesyncbox](https://github.com/mvdwetering/aiohuesyncbox) (Apache 2.0,
> branch `master`), **HA** = the Home Assistant custom integration
> [huesyncbox](https://github.com/mvdwetering/huesyncbox) that uses it, **OH**
> = openHAB's [huesync binding](https://github.com/openhab/openhab-addons/tree/main/bundles/org.openhab.binding.huesync).
> Nothing from Signify's login-walled documentation or from Snap One's
> documentation is copied here: every claim is a paraphrase with its source.
> Placeholders only (bridge 10.0.2.143, bridge id 001788fffe123abc); no box
> address or box id is written here at all (section 4.4 says why).

## Short answers

1. **Structure: a fifth driver, `hue_syncbox.c4z`, that talks HTTPS to
   its own box**, one device per box, with an AV switch proxy. It works
   without the Hue Bridge driver. A binding to the Hue Bridge device is
   optional and adds the bridge's view of the box's entertainment area
   (names, active or not, which Control4 lights are in it) and the dev
   loop. The bridge does not own the boxes the way it owns lights:
   HDMI switching must keep working while the Hue bridge is away, the box
   has its own credential and its own certificate root, and the bridge's
   request budget and Lua budget should not carry it (section 1).
2. **Networking: `C4:url`, short polls, never a long-lived transfer.** One
   request in flight per box, timeouts of a few seconds, the full state
   every 5 s while the box is active and every 30 s while it is idle, a
   re-read right after each command, back-off to 60 s while the box does
   not answer. TLS is pinned to the box's own root (`root-hsb`, a P-256 CA
   that AIO, and with it HA, pins), host-name checking is off as for the
   bridge, and the box's id is checked without the token before the token
   goes out (section 2).
3. **Security: the bridge's rules, applied to a second secret.** The box
   token lives in encrypted persistent storage of the box device and is
   never in a message, a property or a log line; the bridge's key never
   reaches the box driver; messages from the bridge only *trigger* a read
   of the box, never set state; every number and text from the box goes
   through `common/num.lua` and the peer-text caps; mDNS answers follow the
   N-3 rules; the identity is the box's id of 12 hex digits (section 3).
4. **Integration:** the build, the release workflow and CI pick up a fifth
   `src/*/driver.xml` by themselves; `deploy/house.yaml` names it; the
   bridge gains one provider connection (no capability, so no reboot) and
   one module; the HTTPS core, the TLS self-check and the mDNS parser move
   to `src/common/` so both drivers use one copy; the 2.0 line also
   decides what happens to the 1.1 hidden aliases, whose ledger expiry is
   2.0 (sections 4 and 6).
5. **Testing:** fixtures written by hand from field names until a real box
   is recorded (the complete public example bodies are marked as taken
   from Signify's login-walled pages, and their box ids start with an OUI
   the project's gitleaks rules already refuse); a fake box answering the fake runtime's
   transfers; a `syncbox` dev-loop tree; the owner's hands for the box's
   button, an HDMI source and a TV (section 5).

## 1. Driver structure

### 1.1 How the project is built today

- Four drivers, one release: Hue Bridge (own proxy), Hue Light and Hue
  Scene (`light_v2`), Hue Motion Sensor (`contactsingle_motionsensor`)
  [verified: `docs/design.md:43-51`].
- **Only the bridge talks to Hue.** Every device binds to the bridge's
  provider binding 1 (class `HUE_BRIDGE`) and talks to it with
  `C4:SendToDevice` both ways [verified: `docs/design.md:58-70`,
  `docs/lights-design.md:36-47`].
- Devices are created only by a click on the bridge (`C4:AddDevice`, which
  the SDK reserves for user-initiated use, then `C4:Bind`) [verified:
  `docs/design.md:142-145`, `docs/import-design.md:28-33`, `API/9_helper/_0.1-AddDevice.md`].
- Since 1.2 the bridge has ten actions; the Hue Light and Hue Scene have
  none and the motion device one, so that the bridge is the one place to
  look [verified: `docs/design.md:83-87`, `docs/simplify-actions-design.md:205-230`
  and the owner's answer D3, `:327`].
- The bridge itself is found and paired from its own device: Bridges
  Found (local mDNS, then a bounded sweep), Pair Bridge with the link
  button, the key in encrypted persistent storage, the bridge id pinned,
  the address followed by the id [verified: `docs/design.md:1397-1416`,
  `:1525-1527`; `SECURITY.md:107-127`].

### 1.2 What is different about a sync box

- **It is a peer of the bridge, not a resource on it.** It has its own
  HTTPS API on port 443, its own registration with a button press and a
  bearer token, and its own mDNS service `_huesync._tcp.local` with TXT
  keys `uniqueid`, `devicetype`, `name` and `path` [verified: AIO
  `aiohuesyncbox/huesyncbox.py` (`_request`, `register`), AIO
  `example_zeroconf.py`, HA `custom_components/huesyncbox/config_flow.py`
  (`async_step_zeroconf`), HA `manifest.json` (`"zeroconf"`)].
- **The bridge cannot list it.** Nothing in CLIP v2 is known to describe a
  sync box as a resource; the box appears to the bridge as an
  application that streams to an entertainment area [assumed: the
  entertainment research of #514 confirms].
- **The box knows its bridge.** Its `hue` state names the bridge's id and
  address, its connection state, the entertainment areas it can use and
  the one selected; the 8K box (model HSB2) and later models can also run
  without a bridge ("standalone", Bluetooth lights, API level 14) [verified: AIO
  `aiohuesyncbox/models/hue.py` (`HueData`, `OperatingMode`)]. Its reads
  never contain the bridge's key: only a write (`set_bridge`) carries one
  [verified: AIO `models/hue.py`, `HueUpdate` versus `HueData`;
  `controllers/hue.py`, `set_bridge`].
- **HDMI switching is its first job.** A TV's input must follow Control4's
  room selection whether or not the Hue bridge answers.

### 1.3 The options

| | A. Own driver, own HTTPS (recommended) | B. The bridge owns the boxes | C. Own driver, no bridge link at all |
| --- | --- | --- | --- |
| Who talks to the box | the box device | the bridge; box devices are thin, like Hue Lights | the box device |
| Secrets in one driver | one (the box token) | the bridge key plus every box token | one |
| Bridge away | HDMI switching and sync control go on | every box device would go offline with the bridge (`docs/offline-design.md` §6.1 sends `HUE_BRIDGE_LINK` offline to every bound device), which is wrong for an HDMI switch | go on |
| Bridge's request budget | untouched: another host has its own Director queue [verified: `docs/design.md:445-463`] | box polls share the bridge's keyed queue of 3 (`src/hue_bridge/bridge/http.lua:43`) with light commands; a dead box would hold slots light commands need | untouched |
| Bridge's Lua budget (`docs/driver-locals-design.md`) | one module and a few locals | a second client, pairing and poller in the bridge (147 of 180 locals in its main chunk today [verified: `luac5.1 -p -l -l src/hue_bridge/driver.lua`, 2026-11-13]) | none |
| Standalone 8K box (no bridge) | works | impossible | works |
| Entertainment area names, Control4 lights in the area, instant sync start/stop | yes, through the optional bridge binding | yes | no |
| Dev loop | a `syncbox` tree forwarded by the bridge (section 5.3) | the bridge's own tree | a Composer install per change |

**Recommendation: A.** It keeps the 1.x rule that one driver holds one
credential to one LAN device, isolates a misbehaving box from the lights,
and keeps the TV switching when Hue is down. The cost is a departure from
"only the bridge talks to Hue", which should be written into
`docs/design.md` with this reason: the box is a second Hue product with its
own API, root and secret, not a resource of the bridge.

### 1.4 How a box is added, paired, linked and forgotten

The box's lifecycle is the bridge's lifecycle (a LAN device with its own
credential), so it copies the bridge's flow, not a light's. Whether an
event does it by itself, only offers it, or waits for a click is the
lifecycle research's to settle (CLAUDE.md, "Edge cases before automation");
this table is the architecture's starting point.

| Step | How (recommended) | Gate |
| --- | --- | --- |
| Added | from Composer's driver list into the TV's room, like any AV switch and like the Hue Bridge driver itself; the dealer makes the HDMI connections in Connections as for any switch | click (Composer) |
| Found | at first load the device asks mDNS for `_huesync._tcp.local` and lists the boxes in a **Sync Boxes Found** row (name, model, id), as Bridges Found does; a typed **Sync Box IP Address** also works | automatic (read only) |
| Paired | picking a box, or entering an address on a never-paired device, opens a 2-minute pairing window: Status asks for the box's button to be held until its light blinks green [verified: AIO `README.md`, "Registration"], and the device retries the registration every second while the box answers "not yet" [verified: AIO `README.md` loop with a 1 s sleep; error 16 is the box's "invalid state", AIO `aiohuesyncbox/errors.py`]; **Pair Sync Box** reopens it | click |
| Linked to the Hue Bridge | an ordinary Composer connection from the box device's consumer binding to a new bridge provider binding (section 4.2). The box device reads its box's bridge id and says in Status whether it matches the bound bridge | click (Composer); a mismatch is only shown |
| Address changed | found again by its id through mDNS, as the bridge follows its own address (#491's rule and residual risk, section 3.4) | automatic, said in Last Action |
| Token revoked (in the Hue Sync app) | a 401 is re-checked once, then Status asks for Pair Sync Box; re-checked later like the bridge's key (D8) | automatic re-check, re-pair is a click |
| Forgotten | **Forget Pairing** on the box device (Confirm `No` / `Yes, forget`, as the bridge's): the box is asked to delete this registration with the token itself (a token can only delete its own registration [verified: AIO `huesyncbox.py`, `unregister` docstring]), then the token is deleted locally | click |
| Device deleted in Composer | nothing is sent to the box; the registration stays in the Hue Sync app's list until removed there [assumed: the lifecycle research decides whether `OnDriverRemovedFromProject`, `API/22_miscellaneous/_26-OnDriverRemovedFromProject.md`, should try a best-effort unregister] | — |

The 1.2 action pattern carries over: the box device gets the bridge's
actions 1, 8 and 9 in its own words (**Pair Sync Box**, **Diagnostics**,
**Forget Pairing**) and nothing else; everything the box does is a
property, a programming command or the AV proxy. The bridge's ten actions
do not change, and its Add From Hue does not list boxes in this proposal
(an open question below).

### 1.5 What crosses between the bridge and a box

A sketch, for the entertainment research to complete. Every parameter is a
string, as for the other messages (`docs/lights-design.md:48-49`, which itself marks the types [assumed]).

- Box to bridge, `HUE_SYNCBOX_HELLO`: the box's id, the bridge id its box
  reports, its selected area's id. At start, at bind and when either id
  changes.
- Bridge to box, `HUE_SYNCBOX_CONFIGURE`: the area's name, member count,
  status and whether the bridge ids match; nothing for an area the bridge
  does not know.
- Bridge to box, `HUE_SYNCBOX_AREA`: an `entertainment_configuration`
  event for the box's area (status active or inactive), from the event
  stream the bridge already reads; the bridge ignores those events today
  (`src/hue_bridge/bridge/automation_model.lua:82`) [verified].
- Bridge to box, `HUE_BRIDGE_LINK`: the existing offline and online message
  [verified: `docs/offline-design.md` §6.1, `src/common/link.lua`], so the
  box device can say that light sync cannot work while the bridge is away.
- Box to bridge, `HUE_SYNCBOX_GOODBYE`: unbind or removal.

No message carries the bridge's key or the box's token. Light coordination
(what a Control4 Hue Light in an active area shows and does) needs no
message from the box: the bridge sees the area become active in its own
stream.

## 2. Networking on the controller

### 2.1 Transport: `C4:url`

| | `C4:url` (recommended) | `C4:CreateNetworkConnection` with SSL |
| --- | --- | --- |
| Documented TLS options | `ssl_cabundle` (a CA bundle used instead of the system's), `ssl_verify_peer`, `ssl_verify_host`, timeouts [verified: `API/35_url/_12-SetOption.md`] | `CACERTFILE` and `VERIFY_MODE` none or peer; no host-name option [verified: `API/32_serial_network_device/_25-NetPortOptions.md`; `FUND/25_tls_ssl_driver_configurations/_1-TLSSSLDRIVERCONFIGURATION.md`] |
| Proven on the house | yes: every bridge REST request, the bundle path rule, the decoy check [verified: `docs/design.md:189-208`, `:225-324`] | yes, for the bridge's event stream since 1.1 [verified: `docs/design.md:432-438`] |
| Lua to write | none beyond `bridge/http.lua`'s pattern | an HTTP/1.1 client: request framing, Content-Length and chunked bodies, keep-alive and reconnects (`bridge/netstream.lua` does the streaming half) |
| Pinning proof | the decoy request (`bridge/tlscheck.lua`) | the decoy and control probes of `bridge/netcheck.lua`, which spend a binding id each and leave bindings behind [verified: `docs/tls-probe-bindings-research.md`, short answers 1 to 3] |
| Director's transfer slots | one per request in flight; at most four controller-wide [verified: `docs/design.md:1580-1586`] | none |
| Connection reuse | not known [assumed: `docs/design.md:173-175`] | yes, while the box keeps it open |

`C4:url` fits short polls; a raw connection only pays off for a held
connection. **No box push channel is known:** AIO and OH only poll, HA
declares `local_polling` and refreshes every 3 s, OH every 10 s by default
[verified: HA `const.py` (`COORDINATOR_UPDATE_INTERVAL`), HA `manifest.json`
(`iot_class`), OH binding page https://www.openhab.org/addons/bindings/huesync/].
If the API research finds a long poll, it must not run on `C4:url`: the
1.0 event stream held a `C4:url` transfer for good, queued every request
to its host behind it and, with the transfers it abandoned, filled all
four of Director's slots [verified: `docs/design.md:398-406`, `:1580-1600`]; it would
need the raw connection.

### 2.2 The certificate and how the controller checks it

- **What the box presents:** a leaf whose common name is the box's id (12
  upper-case hex digits, the id on its label) and whose organisational unit
  names the model, issued directly by a self-signed root `C=NL, O=Philips
  Hue, CN=root-hsb` (EC P-256, valid 2017 to 9999) [verified: AIO
  `aiohuesyncbox/hsb_cacert.py` (the root, inspected with `openssl x509`;
  SHA-256 fingerprint `A8:4F:E4:D6:E4:B7:24:4D:45:D0:A0:03:4F:7E:E1:49:85:2C:EC:B5:2E:BA:7F:C1:2A:3A:CA:76:6E:E6:8C:74`),
  AIO `models/device.py` (`unique_id`), and an 8K box's chain shown with
  `openssl s_client` in https://github.com/mvdwetering/aiohuesyncbox/issues/5].
  The 4K and 8K boxes chain to the same root [verified: the same issue and
  https://github.com/mvdwetering/huesyncbox/issues/128, where the library's
  author and other owners run 8K boxes with that one root; the one failure
  there was the reporter's own setup].
- **How clients check it:** AIO trusts only that root and checks the
  common name against the box id it was given (`server_hostname`,
  `hostname_checks_common_name`) [verified: AIO `huesyncbox.py`,
  `_get_clientsession` and `_request`]. OH trusts whatever the box
  presented on first contact [verified: OH
  `internal/connection/HueSyncTrustManagerProvider.java`,
  `PEMTrustManager.getInstanceFromServer`].
- **What the controller can do:** pin the root and check the id in the
  application, exactly as for the bridge. `C4:url` with `ssl_cabundle =
  "certs/hsb_ca.pem"` (a path inside the archive, the only form that works
  [verified: `docs/design.md:195-205`]), `ssl_verify_peer = true`,
  `ssl_verify_host = false`, because the name is the id and the URL holds
  an address. No DriverWorks API compares a certificate name with an
  expected id: neither `C4:url`, nor `NetPortOptions`, nor the TCP client,
  and lua-openssl's socket methods are removed [verified:
  `API/35_url/_12-SetOption.md`, `API/32_serial_network_device/_25-NetPortOptions.md`,
  `API/14_lua_tcp_client/_3-Connect.md`, `API/13.5_openssl/_0-Header.md`;
  the network reviewer's "Residual risks" of 2026-11-13, section 3]. The
  box does not need its id as the TLS server name: an `s_client` run that
  sent the address as the server name got the box's own leaf [verified:
  AIO issue 5]; that curl sends no server name at all for an address, and
  that the box answers that too, is [assumed] until the first dev build.
  The 4K box's organisational unit is [assumed] to read HSB1.
- **The controller can verify it:** the Hue bridge's roots are EC P-256
  too (`openssl x509` of `src/hue_bridge/certs/hue_root_bridge.pem` and
  `hue_root_ca_01.pem`, 2026-11-13) and verify on the house [verified:
  `docs/design.md:208`]; so a P-256 chain is no new risk [assumed: the
  box's TLS versions and ciphers suit Director's curl; the first dev build
  shows it].
- **One bundle per product.** `certs/hsb_ca.pem` holds `root-hsb` only and
  ships in the box package only; the bridge's bundle never gains it. A box
  certificate must never verify as a bridge's, and the other way round.

### 2.3 The TLS self-check

The bridge proves at every start and address that Director honours
`ssl_cabundle`, with one request against a decoy bundle that must fail
(curl 60), and remembers a `pinned` answer per Director version
[verified: `docs/design.md:225-324`, `src/hue_bridge/bridge/tlscheck.lua:70-110`].
That memory is the bridge device's own persistent value (`tls_pinned_on`),
which another driver cannot read [assumed: persistent storage is per
device, `docs/design.md:1530-1535` shows it does not survive a delete and
re-add]. So the box driver runs the same check against its box, with the
same decoy file, before the first request that carries its token, and
blocks exactly as the bridge does on `not_pinned` and on a first
`inconclusive`. The fake runtime already fails any request whose bundle
path contains "decoy" (`tests/helpers/fake_c4.lua:192-203`) [verified].

### 2.4 Polling without starving Director

What limits the controller [verified: `docs/design.md:445-463`,
`:1580-1600`; `src/hue_bridge/bridge/http.lua:22-35`]:

- Director runs one `C4:url` transfer per host at a time, keyed by the
  host text; the box's address is another host than the bridge's, so box
  polls never wait behind light commands and the other way round.
- Director runs at most four transfers controller-wide. The bridge keeps
  its own keyed requests to three (`http.MAX_KEYED`, #489, N-8). The cap is
  per Lua runtime (`http.lua:253-267`), so each driver counts only its own:
  nothing coordinates the bridge and the boxes [assumed: drivers share no
  Lua state].
- Owner's correction of 2026-11-04: the four-slot limit is no longer a
  sizing rule now that the stream holds none [verified:
  `docs/simplify-actions-design.md:45-56`]; it still bites while a peer
  does not answer, which is why N-8 capped it.

Proposed cadence (the box research may tune the numbers):

| State | What is read | How often |
| --- | --- | --- |
| Active (passthrough or syncing) | the full state, `GET /api/v1` | every 5 s (HA 3 s, OH 10 s) |
| Idle (power save) | the same | every 30 s |
| After a command | the same | once, 1 s after the command's answer |
| A bridge hint (`HUE_SYNCBOX_AREA`) | the same | at once, at most once per 2 s |
| Not answering | the same | 5, 10, 30, then every 60 s |

Rules:

- **At most one request in flight per box** (`MAX_IN_FLIGHT = 1`): AIO
  limits itself to one connection per box because the box accepts few
  [verified: AIO `huesyncbox.py`, `limit_per_host=1` and its comment], and
  Director serialises per host anyway. A poll that is due while one is in
  flight is skipped, never queued.
- **User first:** a command goes before a due poll; commands coalesce
  (the latest brightness wins, an `ON` and a `SET_INPUT` from one room
  selection become one `PUT /api/v1/execution`), one in flight, as
  `bridge/commands.lua` does for lights [assumed: the box applies a
  combined execution body; the API research confirms].
- **Short timeouts:** connect 3 s, total 6 s (HA allows 5 s, OH 1 s
  [verified: HA `coordinator.py`, `asyncio.timeout(5)`; OH
  `HueSyncConnection.java`, `timeout(1, TimeUnit.SECONDS)`]). A dead box
  then holds one slot for at most 6 s per attempt, at most every 60 s:
  about a tenth of one slot while the bridge may hold three.
- **Cost on the controller:** a few kilobytes of JSON per poll [assumed:
  the public field list; measured on the first dev build], decoded by
  `C4:JsonDecode` under `pcall` as `http.decode` does. A body over a cap
  (256 KB) is refused before decoding (N-4's advice). Timing of every poll
  is logged at debug only; Debug Mode turns itself off after 8 hours on
  this driver too (#493).
- **Whether `C4:url` reuses the TLS session** between polls is unknown
  [assumed]; the first dev build logs each poll's duration, and the raw
  connection stays the fallback if handshakes prove slow for the box.

### 2.5 The token

- Stored with `C4:PersistSetValue(name, value, true)`, the encrypted flag
  [verified: `API/26.5_persistence/_4-PersistSetValue.md`; the bridge's
  `src/hue_bridge/bridge/credentials.lua:1-28`]. The registration id and
  the box id beside it, unencrypted (no secrets). Never in a property, a
  row, Last Action, a log line or a message; kept in memory after saving,
  because the store's thread may not return a fresh value at once
  [verified: the same API page, usage note; `docs/design.md:1528-1535`].
- Sent only as `Authorization: Bearer …` [verified: AIO `huesyncbox.py`,
  `_request`], only to the paired box id, only after the identity check and
  the TLS self-check, and never across a redirect: a token-carrying
  request aborts on a 3xx in `OnHeaders`, as keyed bridge requests do
  [verified: `src/hue_bridge/bridge/http.lua:437-460`; `API/35_url/_9-OnHeaders.md`].
- The registration answer that carries the token is never logged, not
  even at debug. The pairing window rule of N-9 applies: a token that
  arrives after the window closed, after Forget Pairing or for another
  address is discarded unstored [verified: `src/hue_bridge/bridge/pair_window.lua:20-27`].

### 2.6 Discovery

- The bridge's mDNS module sends a legacy unicast query from the driver's
  own UDP binding 6008, and the house's Bridge Pro answers it [verified:
  `src/hue_bridge/bridge/mdns.lua:1-22`, `src/hue_bridge/bridge/discovery.lua:78-81`,
  `:181`]. The same query for `_huesync._tcp.local` is the cheapest
  discovery for the box [assumed: the box answers a legacy unicast query
  (RFC 6762 §6.7) at all; the first dev build shows it].
- If it does not, the typed address works; a sweep of port 443 under the
  `root-hsb` check, like `bridge/sweep.lua`, is a 2.x step, never the
  internet (the owner's rule, `docs/simplify-actions-design.md:329`, D5)
  [verified].

## 3. Security

Sources: `SECURITY.md` ("What counts", "Trust boundaries"), the review of
2026-11-13 (#480; on branch `security/review-480`: `git show
origin/security/review-480:docs/reviews/security-2026-11-13.md` and its
`-network`, `-controller` and `-devices` reports) and its fix contract
[`security-fixes-2026-11-design.md`](security-fixes-2026-11-design.md);
the first round, [`security-fixes-design.md`](security-fixes-design.md).

### 3.1 The trust boundary between drivers

- Control4 tells a driver nothing about who sent a command or a message,
  so any driver in the project can run the box device's actions and send
  it messages, as for the bridge (C-1, D-1) [verified: `SECURITY.md:80-106`,
  `docs/security-fixes-2026-11-design.md` row #483]. The box device
  accepts that boundary and narrows it the same way:
  - its proxy commands only on its AV proxy binding (D-7);
  - a bridge message about another area than the one its box reports, or
    about none, is dropped with a debug line (D-1);
  - **a bridge message only triggers a read of the box**, rate-limited,
    and never sets the device's state: the box's own answer over the
    pinned connection is the only source of HDMI and sync state. A forged
    hint costs one extra poll at most every 2 s.
- **No secret crosses the boundary.** The token never leaves the box
  device; the bridge's key never reaches it. Setting up the box with a
  bridge (`set_bridge`, which writes the bridge's key and client key into
  the box [verified: AIO `controllers/hue.py`]) stays in the Hue Sync app:
  doing it from Control4 would make the bridge driver pass its key to
  another driver, which `SECURITY.md:90-91` promises never happens.
- The bridge answers a box's hello only for a device bound on its box
  binding, and only with what the box could read from its own box anyway
  (area names, member counts, status).

### 3.2 Number and text checks

Every value from the box, the proxy, programming or the bridge passes
`src/common/num.lua` or a fixed table before it reaches a request body, a
timer, a row or a comparison (#486, #487) [verified: `src/common/num.lua:1-9`]:

| Value | Rule |
| --- | --- |
| HDMI input | one of `input1` to `input4`, from a table; never a caller's text |
| Mode, intensity, palette | members of fixed tables; an unknown value read from the box is shown as unknown, never sent back |
| Brightness | `num.int(v, 0, 200)` [verified: range in AIO `models/execution.py`] |
| API level, build number | `num.int` within sane bounds; a box below the API level the API research names is refused with a Status text |
| Temperature (8K) | `num.within`, dropped when absurd |
| Times (`lastCheckedUpdate` and others) | `C4:ParseIso8601DateTime`, then `num.timestamp` and `num.date` |
| Area and group ids | the bridge's rid rule (`hue_model.resource_id`: letters, digits and `-`), at most 64 characters, at most 64 areas kept; a path segment is only ever an id the box itself reported (D-2) |
| Box id | 12 hex digits, compared upper-case |
| Names (box, inputs, areas) | `util.display_name` or `http.peer_text`: control characters out, 256 bytes in rows, 2,000 in logs (C-4, N-4) [verified: `src/hue_bridge/bridge/http.lua:46-80`] |
| Registration id, token | a short decimal id; a token of printable characters within a length bound, else the registration fails; neither is logged |
| Response bodies | refused over 256 KB before decoding (N-4) |

### 3.3 Discovery limits

The N-3 fixes, applied to `_huesync._tcp.local` [verified: the
`-network` report's N-3 fix; `docs/security-fixes-2026-11-design.md` row #490]:

- an answer counts only if it repeats the query id;
- addresses only private IPv4 or link-local (`mdns.usable_address`,
  `sweep.searchable`), at most four per datagram, at most 32 datagrams per
  window;
- the TXT `uniqueid` must be 12 hex digits; the TXT `path` is never put
  into a URL (the driver's path is the literal `/api/v1/...`, as
  `http.url` insists on `/`, finding 10); the SRV port must be 443
  [verified: 443 is AIO's and HA's default; assumed: every box advertises
  it];
- a candidate is listed only after an unkeyed `GET /api/v1/device` over
  the pinned connection reports the same id [verified: OH
  `HueSyncConnection.java` comment and `HueSyncDeviceConnection.java`,
  `getDeviceInfo`, read the device unauthenticated to identify it;
  assumed: every firmware answers it];
- on OS 4.x, where `ReceivedFromNetwork` names the sender, only the
  sender's own address is kept [verified: `API/32_serial_network_device/_15-ReceivedFromNetwork.md`].

### 3.4 Identity pinned to the box id

- The paired id is persisted at pairing (from the pick, confirmed by
  `/device`) and checked without the token at every start, address change
  and outage of 60 s or more; another id at the address stops every
  token-carrying request, with the bridge's Status pattern ("Sync box at
  … reports ID …, expected …") [verified: the bridge's rule,
  `src/hue_bridge/bridge/identity.lua:1-8`, `docs/design.md:292-306`].
- A 401 (the box's "unauthorized" codes 1 to 3 [verified: AIO `errors.py`;
  OH `HueSyncConnection.java` comment]) is re-checked as #490 (N-6)
  re-checks the bridge's: identity first, one confirming request, then
  the lock.
- **Residual risk, as for the bridge (#491):** no API checks the
  certificate's name, so a host with a `root-hsb` leaf *and its private
  key* (a rooted box) could answer with the paired id while the real box
  is away, and the address follow-up would hand it the token [verified:
  `SECURITY.md:107-127` for the bridge; the same reasoning holds]. The
  token controls one box's HDMI and sync, not the Hue lights. Recommended:
  keep the follow-up, as the owner decided for the bridge, and say so in
  `SECURITY.md`.

### 3.5 The review's findings, for the new driver

| Finding | What the box driver does |
| --- | --- |
| N-1, N-2 (stream caps, head parser) | not applicable while it uses `C4:url` and no stream |
| N-3 | section 3.3 |
| N-4 | caps on bodies and peer text; rows written only after the id matched |
| N-5 | section 3.4 |
| N-6 | identity re-check before a 401 locks the token |
| N-7 | the back-off resets only after a full read succeeded |
| N-8 | one request in flight per box |
| N-9 | the pairing window rule (section 2.5) |
| C-1, D-1, D-7 | section 3.1 |
| C-2, I-5, I-6 | no development handler in a release build; `C4:AllowExecute(false)`; a warning if a dev module is loaded; `tools/build.sh` checks the box package like the others |
| C-3, D-4, D-5, D-6 | section 3.2 |
| D-2 | path segments only from ids the box reported |
| C-5 | Debug Mode off after 8 hours |
| I-4, I-7, I-8 | the build's existing rules cover a fifth package by construction (section 4) |

## 4. Codebase integration

### 4.1 Shared, new, changed

| Piece | Change |
| --- | --- |
| `src/hue_syncbox/` (new) | `driver.lua`, `driver.xml` (AV switch proxy, minimum OS 3.3.0, `<script jit="1">`), `certs/hsb_ca.pem`, a byte-identical copy of the decoy bundle (a spec compares the two), `www/documentation.html` with the one `<!-- CHANGELOG -->` line `tools/build.sh` needs (`tools/build.sh:197-200`), icons; modules under `src/hue_syncbox/syncbox/` (client, identity gate, pairing, poller, state model, AV mapping, discovery, bridge link) |
| `src/common/` | the HTTPS core of `bridge/http.lua` (options, queue, redirect refusal, decode, peer text) becomes `common/https.lua`, parameterised by CA bundle, auth header and in-flight cap; `bridge/http.lua` keeps its interface as a thin wrapper (Hue bundle, `hue-application-key`, 3). `tlscheck.lua` and the mDNS parser move the same way, with the path and the service as parameters. The bridge's specs pass unchanged but for `require` paths, which is the proof that nothing moved in behaviour |
| `tools/build.sh` | finds a fifth `src/*/driver.xml` by itself (`tools/build.sh:43-46`) and copies `src/common/` in (`:174`); add the box package to the list of drivers whose `common/device.lua` is stripped (`:220-223`) if it does not use it, and strip the new HTTPS, TLS and mDNS modules from the light, scene and motion packages that do not need them |
| `.github/workflows/release.yml`, `ci.yml` | none: the package list comes from the `driver.xml` directories and the manifest [verified: `release.yml:253`, `:424`; `ci.yml:134`; `docs/prerelease-design.md` §2] |
| `deploy/house.yaml`, `tools/deploy.py` | `drivers:` must name exactly the release's packages, so the first 2.0 desired-state PR adds `hue_syncbox` [verified: `deploy/house.yaml:9`, `tools/deploy.py:436-444`]; the brief's device read-back is generic; the Windows session also reads the box device's Status when one exists |
| `src/hue_bridge/driver.xml` | one provider connection, for example id 2 "Hue Sync Boxes", class `HUE_SYNCBOX`, so boxes never appear in binding 1's consumer list that the light, scene and motion registries read (`src/hue_bridge/bridge/project.lua:30-31`); no `<capabilities>` (the bridge has none today), so no reboot [verified: `CLAUDE.md:36`, connection-only changes take effect at once] |
| `src/hue_bridge/` modules | new `bridge/syncboxes.lua` (bound boxes, the entertainment areas, the messages of 1.5); `driver.lua` gains a `require`, a state entry and one `on_container` line beside the other modules' (`src/hue_bridge/driver.lua:983-1006`), a few locals of the 33 left; the areas' read joins the resync through the housekeeping engine's gate and hourly budget [verified: `src/hue_bridge/bridge/housekeeping.lua:1-40`, `:167-168`]; light coordination in `bridge/lights.lua` and `bridge/zone_lights.lua` per the entertainment research |
| `tests/helpers/fake_c4.lua` | a responder hook so a fake box answers transfers to its address; the AV switch proxy (today one `<proxy>` per driver is parsed, `:85`, which is enough if the box declares one); a pair helper for binding 2; nothing new for network connections (`:893-1010` cover UDP for mDNS) |
| `tests/fixtures/ledger.lua` | rows for the box's capabilities (a new id letter): its actions, properties, the fixed ids of its connections, proxy, programming commands and events, messages, Documentation tab |
| `tools/lua_limits.py` rule | applies to the new files by itself; the box's `driver.lua` should start under 150 locals in its main chunk, as the bridge's target [verified: `docs/driver-locals-design.md` §2] |
| Manuals and documents | a new Documentation tab; "four drivers" becomes five in the README, `SECURITY.md`, `CONTRIBUTING.md`, the three device manuals and more (a search for "four drivers" or "all four" lists about thirty files); `SECURITY.md` adds the box token, `root-hsb`, the box's own HTTPS and the follow-up risk; `CHANGELOG.md` `## Unreleased` lines per PR; this research belongs in `docs/README.md`'s index, not on the README's front page |
| `.gitleaks.toml` | allowlist `^src/hue_syncbox/certs/` like the bridge's certs (`.gitleaks.toml:20`); see 4.4 for placeholders |
| Dev loop | section 5.3 |

### 4.2 The bridge binding, in Composer terms

The box device's consumer binding (control binding range 1 to 999,
[verified: `API/32_serial_network_device/_1-CreateNetworkConnection.md`,
binding ranges]) has class `HUE_SYNCBOX`. Composer then offers only the
bridge's box binding as its partner [assumed: Composer pairs bindings by
class, as it does for `HUE_BRIDGE` today], and the bridge's registries, which
read binding 1, never see a box. The AV connections (video inputs from
1000, outputs from 2000, audio from 3000 and 4000, the proxy at 5001,
network from 6000 [verified: the same page]) are the HDMI research's.

### 4.3 What 2.0 must not change

No existing device changes unless a feature needs it: the Hue Light and
Hue Scene keep their capabilities, connections and properties; light
coordination is Lua and message work. The bridge gains a connection and
nothing in `<capabilities>`. So installing 2.0 over 1.8 needs no reboot,
and every pairing and binding survives the update in place [assumed until
the first beta's install shows no Restart Director prompt].

### 4.4 Placeholders and the secret scan

- Real box ids begin with a Signify OUI that the `bridge-oui` rule of
  `.gitleaks.toml` (`:124`) refuses in every file but three [verified:
  the rule; the ids in AIO's example and in AIO issue 5 carry it]. So
  fixtures and documents need an invented box id that does not, recorded
  in `.gitleaks.toml`'s allowlist and `CLAUDE.md`'s placeholder list.
- A box address must be private (or the N-3 rules refuse it in the
  discovery specs) and allowlisted. Today the only private placeholder
  outside the README's examples is the bridge's own address
  (`.gitleaks.toml:72-83`); one more documented placeholder in the
  bridge's /24 is needed. That is why this file writes no box address.
- No example token appears anywhere: gitleaks' default rules look for
  values next to words such as "token".

## 5. Testing

### 5.1 Fixtures

- `tests/fixtures/syncbox_api.lua`, JSON text as the bridge's
  `hue_resources.lua` keeps it (`tests/fixtures/hue_resources.lua:1-13`),
  so specs exercise the same decode path: the full state of a 4K box and
  of an 8K box (bridge and standalone), the unauthenticated `/device`
  answer, the registration answers (not pressed, then the token),
  a 401, a 404, a body over the cap, malformed JSON, unknown enum values.
- **Written by hand from field names until a box is recorded.** The only
  complete public example bodies are AIO's test fixtures, which AIO marks
  as taken from Signify's developer documentation (AIO
  `tests/test_compatibility.py`, first comment) [verified]; the project
  copies nothing from those pages. Field names and types are facts and
  can come from AIO's models.
- **Recorded later** through a dev build on a real box: a signed dev-loop
  GET that ships the body to the log, then ids, names and addresses
  replaced by the placeholders of 4.4, as the house's bridge bodies were
  [verified: `tests/fixtures/hue_resources.lua:15-20`].

### 5.2 A fake sync box

`tests/helpers/fake_syncbox.lua`: holds a box's state, answers the fake
runtime's transfers to its address (through the responder hook of 4.1),
applies `PUT` bodies with the box's rules, refuses an unknown token with
401, and can be told to: open the button window (`press()`), answer
slowly, time out (curl 28), refuse (7), fail verification (60), report
another id, or change its own state as the Hue Sync app would. The
roundtrip spec (bridge and box loaded together, like
`tests/spec/motion_roundtrip_spec.lua`) adds the bridge's
`entertainment_configuration` events.

Specs, each new module with its own: client options and gates (bundle,
peer on, host off, no token before identity and TLS check, redirect
refused, body cap, one in flight); identity; pairing (1 s retries, window,
N-9); poller (cadence, skip while in flight, coalescing, back-off, user
first); state model (every row of 3.2); discovery (N-3 rules,
`_huesync` TXT); AV mapping (the HDMI research's commands and
notifications); the bridge module (areas, messages, only bound boxes);
the ledger rows; a sweep that no token, address or box id reaches a log,
row or message (as `tests/spec/motion_diag_spec.lua:1512`).

### 5.3 The dev loop

The server serves three trees and the bridge forwards the light and scene
trees to bound devices; the motion driver has none and needs a Composer
install per change [verified: `docs/dev-loop.md:3-12`,
`tools/devserver.py:260`, `src/common/devloop.lua:916`]. **A `syncbox`
tree is worth adding:** the box's unknowns (TLS with Director's curl,
legacy mDNS, timings, the AV proxy's traffic) are exactly what the loop
iterates on without the Windows session. The bridge forwards it to the
devices bound on its box binding, so the test box must be bound; an
unbound box device needs a Composer install, as the motion driver does.

### 5.4 What needs the owner's hands

| Who | What |
| --- | --- |
| The owner | hold the box's button at each pairing (the first, and after a Forget Pairing test); the box set up with the bridge and an entertainment area in the Hue Sync app, once; an HDMI source and a TV on the box, to see input switching, power save and sync; watching the lights sync; a controller reboot from System Manager only if a box capability changes after its first install |
| The Windows session | install, add the device to a room, make the HDMI and bridge connections, run the actions, build programming, read every row (`docs/composer-remote.md`) |
| This VM | everything else through the dev loop: TLS verdict, mDNS answer, poll timings, recorded fixtures |

Without a box in the house, the betas still go to the house as a smoke
test (all five packages install in place, nothing regresses, a box device
can be added and says no box was found), and a tester with a box does the
rest (section 6.3).

## 6. The 2.x release train

### 6.1 What 2.0 means for compatibility

- **Minimum OS stays 3.3.0** in all five drivers. The box driver needs
  `C4:url` (2.10.5), `C4:CreateNetworkConnection` for mDNS (1.6.0) and the
  encrypted store (2.10.0) [verified: `API/35_url/_0-Header.md`,
  `API/32_serial_network_device/_1-CreateNetworkConnection.md`,
  `API/26.5_persistence/_4-PersistSetValue.md`]; the AV switch proxy's
  hidden bindings are 3.3.0 if used at all [verified:
  `FUND/27_proxy_specific_info/_30-AVSWITCHBINDINGS.md`]. Nothing needs
  4.x [assumed: the HDMI research names no 4.x-only proxy feature].
- **Existing devices do not change** (4.3); no migration is needed.
- **The 1.1 hidden aliases reach their expiry.** Thirty-seven commands,
  four of them dev-only (and the hidden property On State Follows), are kept "until 2.0", and the
  ledger spec fails as soon as `.github/codenames.json` names a 2.0
  [verified: `tests/fixtures/ledger.lua:640`, `:922-981`;
  `tests/spec/ledger_spec.lua:334-339`, `:1069-1074`]. So the first 2.0
  commit must either remove them (with a "Removed" line in the changelog)
  or move their expiry: an owner's choice, below.

### 6.2 Reboots

Every change of a driver's `<capabilities>` costs the owner a reboot from
System Manager [verified: `CLAUDE.md:36`]. The bridge needs no capability
(4.1). The box driver's `<capabilities>` and connection ids are fixed
before `v2.0-beta.1` from the HDMI research's full list and not touched
again in 2.0; a first install of a new driver is not a capability change
for any existing device [assumed: as the motion driver's first beta
needed none, `docs/status.md:431-436`, though that driver declares no
capabilities at all]. If 2.x later needs a capability change, it waits
for a release that batches every such change.

### 6.3 Prereleases

`v2.0-beta.N` tags that never move, built from `main` by the same
workflow, with notes from `## Unreleased`, as the motion feature's eight
betas were [verified: `docs/prerelease-design.md` §1 to §4]. With a box in
the house, the house runs the betas through `deploy/house.yaml`; without
one, the betas go to a tester who has a box (4K or 8K), and the house runs
them as the smoke test of 5.4. The beta feedback form gains the box model,
its firmware and API level. 2.0 itself follows once one box has been
paired, switched and synced through Control4.

## Recommendations for the design

1. Build the box as a fifth driver, `hue_syncbox.c4z`, one device per box,
   talking HTTPS to its box directly; write the reason for leaving "only
   the bridge talks to Hue" into `docs/design.md`.
2. Make the bridge binding optional, on a new provider connection with its
   own class (`HUE_SYNCBOX`), so boxes stay out of binding 1 and the
   bridge's registries; no `<capabilities>` change on the bridge.
3. Add the box like any AV switch, from Composer's driver list; find it
   with mDNS on the box device (Sync Boxes Found) or a typed address; pair
   with the box's button in a 2-minute window; give the device three
   actions, Pair Sync Box, Diagnostics, Forget Pairing.
4. Use `C4:url` with `ssl_cabundle = "certs/hsb_ca.pem"` (`root-hsb`
   only), peer verification on, host verification off, the id checked by
   an unkeyed `GET /api/v1/device`, and the decoy TLS self-check before
   the first token-carrying request of each start and address.
5. Poll the full state with one request in flight per box: 5 s active,
   30 s idle, 1 s after a command, at once on a bridge hint (at most every
   2 s), backing off to 60 s; connect 3 s, total 6 s; commands first and
   coalesced; bodies over 256 KB refused.
6. Store the token encrypted in persistent storage, never shown or sent
   anywhere but in the `Authorization` header to the paired box; refuse
   redirects on such requests; apply the N-9 window rule to the
   registration answer.
7. Let bridge messages only trigger a read of the box; never let them set
   state; never pass the bridge's key to the box driver (no `set_bridge`).
8. Apply the N-3 rules to `_huesync` discovery, ignore the TXT path, insist
   on port 443, list a candidate only after its id answered over the
   pinned connection.
9. Keep the address follow-up by id for boxes, as for the bridge, with the
   same residual risk written into `SECURITY.md`.
10. Move the HTTPS core, the TLS self-check and the mDNS parser to
    `src/common/`, parameterised, with the bridge's specs as the proof that
    the bridge's behaviour did not change; strip unused common modules from
    packages that do not need them.
11. Give the box package its own `www/documentation.html`, ledger rows, a
    `syncbox` dev-loop tree forwarded by the bridge, a fake box and a
    hand-written fixture file until a real box is recorded.
12. Add the box id and box address placeholders to `.gitleaks.toml` and
    `CLAUDE.md` before the first fixture is committed, and allowlist
    `src/hue_syncbox/certs/`.
13. Freeze the box driver's `<capabilities>` and connection ids before
    `v2.0-beta.1`; keep minimum OS 3.3.0 in all five drivers; add
    `hue_syncbox` to `deploy/house.yaml` in the first 2.0 desired-state PR.
14. Decide the 1.1 aliases in the first 2.0 commit, since naming 2.0 fails
    the ledger spec until then.

## Open questions for the owner

1. **Is there a sync box to test with, and which model (4K or 8K)?** If
   not in the house, is there a tester with one, as for the motion
   sensors? It decides whether the house runs the box part of the betas.
2. **Should the bridge's Add From Hue also offer the boxes it finds** and
   create the box device from there (the 1.2 "one place" for creating
   devices), or is the box added only from Composer's driver list like the
   Hue Bridge driver itself (recommended above)? Both can work; offering
   both means two ways to make the same device, which the lifecycle
   research must then cover.
3. **The 1.1 hidden aliases and the hidden On State Follows property, kept
   "until 2.0":** remove them in 2.0 as announced (recommended: they only
   serve the dev loop, older briefs, `tools/regress.sh` and other drivers'
   sends, per `tests/fixtures/ledger.lua:922-925`), or move their expiry
   to a later release? Removing On State Follows from the scene's
   `driver.xml` drops the value of a scene device that goes from 1.5 or
   earlier straight to 2.0 before its one-time migration ran
   (`src/hue_scene/driver.lua:1391-1409`) [verified: the migration reads
   the property; assumed: no such device exists outside the house].
