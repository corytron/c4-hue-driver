# Simplify research: maintenance (pairing, connection, refresh, motion)

Research for #334, read-only, written 2026-11-04 against `main` = beta 7
(build 425) on branch `research/simplify-actions-334`. Contract:
[simplify-actions-design.md](simplify-actions-design.md) §0. Scope: the
bridge's pairing, connection, credentials, pinning, refresh and motion
actions, the Hue Motion device's three actions, and the connection rows.
Marks: **[verified]** = seen in code, a spec, the SDK docs or a hardware
report; **[assumed]** = not confirmed. `API/` is
`~/c4-tools/reference/docs-driverworks-api/source/includes/`.

Correction applied (owner, 2026-11-04): Director's four-transfer limit is
not a design constraint and sizes nothing below. What still holds: REST
calls use `C4:url`, one transfer per host at a time, so a background read
and a light command to the bridge queue behind each other.

## 1. Findings

1. **Of the 12 release actions in scope (plus 3 dev-only), only Pair Bridge
   and Forget Pairing need their own place, plus one Diagnostics action.**
   The rest are either the driver's own job (Test Connection, Refresh All,
   Refresh From Bridge), support tools (stream connect and disconnect, Log
   Motion Diagnostics, the three dev-only checks) or duplicates of the import
   family's actions (the motion add, import, re-link and forget, which go
   into the import research's Add From Hue, Link Device and Forget Device).
   The Hue Motion device keeps 1 action instead of 3 (section 4).
2. **Test Connection and Connection Test are different tools.** Test Connection
   (release) sends one keyed `GET /clip/v2/resource/bridge` after the identity
   and TLS checks, and it is **the only way besides Pair Bridge or a new
   address to lift a key-rejected lock**. Connection Test (dev builds only)
   is the 2026-10 spike's C4:url experiment: it stops the stream, opens a test
   stream, runs one GET and two parallel GETs while it is open, then a GET to
   example.com. Its question was answered and has not mattered since the
   stream moved to a network connection (#317).
3. **Reload Credentials is a spike tool.** It reads the stored key back and
   compares it with the one in memory. Its job was to show the lag of
   `PersistSetValue`. The startup log line already reports what is stored
   (without the key itself).
4. **Check CA Pinning does not duplicate the automatic checks. It is the only
   test of something they cannot prove.** tlscheck and netcheck show that the
   driver's CA bundle is consulted. Only a public-CA site (example.com),
   rejected while the bundle is in use, shows that the bundle *replaces* the
   system store. That needs the internet, and release builds deliberately
   never contact a public host. So it stays a dev-build check run once after
   each OS upgrade (`docs/release-checklist.md` §4), and must not become
   periodic.
5. **Five self-healing gaps are worth closing. All are cheap:**
   - Pairing takes two clicks today: "press the button, then run Pair Bridge
     again". It can be one click, with a 2-minute wait for the link button.
   - A key-rejected lock never lifts by itself. A backed-off re-check can
     lift it.
   - **An IP change is never noticed.** Status stays `Paired` while the stream
     reconnects to the old address every 60 s for ever, and the identity check
     is never run again.
   - Nothing refreshes the lists while the stream is down (#324's cause).
   - Nothing reads the bridge again while the stream stays connected for days.
6. **There is no bridge discovery (`docs/design.md` "Discovery").** Two routes
   are feasible:
   - Signify's cloud endpoint: verified behaviour, 1 request per 15 min. It
     needs the internet, which is a policy change for release builds.
   - mDNS over a UDP or MULTICAST network connection: documented call, but
     receiving the answers is unverified (needs a dev-loop spike).

   SSDP is off at Signify. A subnet sweep is too noisy. Without discovery, an
   IP change can still be *reported* truthfully, but not repaired.
7. **Budgets are tiny next to Hue's limits.**
   - A full read is 17 GETs on a Bridge Pro and 15 on a v2. A 6-hourly safety
     net adds about 68 GETs a day.
   - The stream-down fallback (every 10 min) adds at most 2,448 GETs a day,
     and only while the stream is down.
   - The key re-check is at most 27 GETs a day.
   - The discovery endpoint allows at most 96 requests a day, and 24 is
     recommended.

   Must **never** be periodic: the TLS and network-connection checks,
   Check CA Pinning, Log Motion Diagnostics, and any device creation.
8. **One "Diagnostics" action with a picker is the right home** for support
   runs: check the connection, read everything now, reconnect or stop the
   stream, motion diagnostics, plus the three dev-only checks in dev builds.
   - Debug Mode levels are wrong for this: a property is a state, not a
     one-shot run.
   - The dev loop alone is wrong too: the outside tester runs Log Motion
     Diagnostics on prereleases.
9. **The connection rows can shrink.**
   - Events Received and Last Event repeat what the Event Stream row already
     says ("Connected since …, N containers, last …").
   - Stream Address and Stream Timeout (s) mean something only under Web
     transfer.
   - All four, plus the two rarely-touched stream settings, can be hidden
     unless they are non-default, under Web transfer, or Debug Mode is On.
10. **Refresh From Bridge on Hue Motion is redundant.** The device says hello
    on every start and every bind, and the bridge sends every device its state
    after every full read. The manual already says "Normally not needed".
    Test: Motion and Test: No Motion can become one toggle action without
    losing a case.

## 2. Evidence

### 2.1 What each action does today

Costs are per click. "Keyed" means the request carries the application key.

| Action | What it does | Cost | Who needs it, when |
| --- | --- | --- | --- |
| Pair Bridge | Probes `/api/0/config`: model, firmware and other-bridge refusal (#236). Then `POST /api` with `generateclientkey`; error 101 means "press the link button, then run Pair Bridge again"; stores key, id and IP (`bridge/pairing.lua:134-180`, `driver.lua:1266-1320`) [verified] | 1 GET + 1 POST, unkeyed | Installer at setup; again after a key rejection or a bridge replacement |
| Test Connection | Waits for the identity and TLS checks, then 1 keyed `GET /clip/v2/resource/bridge` and compares the bridge id. A 200 clears the key-rejected lock and restarts the stream; a 401/403 locks (`driver.lua:1331-1388`, `docs/design.md` "A rejected key") [verified] | 1 keyed GET (+1-2 unkeyed if the identity check has not passed) | Everyday: nobody (Status and Event Stream already show health). Only to lift a false key lock |
| Connection Test (dev) | C4:url experiment (`bridge/conntest.lua:1-17`, `bridge/devtools.lua:542-585`) [verified]: stops the stream; on bridge or diagnostic server: stream open, GET, two parallel GETs, GET example.com; restarts the stream | about 5 transfers, stream down for up to about 45 s | Developer only; answered on 2026-10-20 (`docs/design.md` "C4:url transfer scheduling") |
| Connect Event Stream | Refuses unless paired and unlocked; picks an address or starts the stream (`driver.lua:2062-2076`) [verified] | 0 here; a connect then a full read | Only after Disconnect Event Stream: the stream starts itself at start, pairing, address and transport change |
| Disconnect Event Stream | `state.stream:stop()` until Connect or a restart (`driver.lua:2078`) [verified] | 0 | Support: stop the feed while troubleshooting |
| Reload Credentials (dev) | Reads the store back and compares it with memory, reporting only "readable / matches" (`devtools.lua:516-530`) [verified] | 0 | Spike-era (`docs/spike-checklist.md` 4a); the startup line `credentials at startup: key present (N chars), …` (`driver.lua:2267`) covers the readable part |
| Check CA Pinning (dev) | example.com with system CAs (control), then with the Hue bundle: must fail certificate verification (`bridge/pinning.lua`) [verified] | 2 GETs to a public host | Once per new controller OS (`docs/release-checklist.md` §4), dev build |
| Forget Pairing | Clears key, id and IP, stops the stream, clears the stream's binding address and the bridge rows; devices stay (`driver.lua:2082-2101`) [verified] | 0 | Installer: before pairing *another* bridge; decommissioning |
| Refresh All | `resync_all`, the same chain as every stream connect, stream or not (#324, `driver.lua:716-742`, `:1917-1928`) [verified] | 17 GETs on a Pro (lights 6, scenes 3 incl. the 351 KB catalogue, zone lights 0, they reuse the scenes' grouped_light, motion 8); 15 on a v2 (motion stops after the area-config 503, #318) | Only while the stream cannot connect (the tester's #309 case, gone since #317) |
| Add Motion Sensor / Add Motion Area | Both call `state.motion:add(rid, room, cb)`; only the picker differs (`driver.lua:1805-1829`) [verified] | 0 GETs; 1 `AddDevice` | Installer, per sensor or area |
| Import All New Motion Sensors | Every sensor without a device, into its mapped room; the rest listed (`motion:import_new`, D15 in `docs/motion-design.md`) [verified] | AddDevice × N | Installer at setup |
| Re-link Motion Device | Device picker (gone or unbound) × target picker (sensors then areas); kind change refused (D4) (`driver.lua:1793-1839`) [verified] | 0 | Sensor replaced |
| Forget Motion Device | Releases the device; it stays for the installer to delete (`driver.lua:1841-1850`) [verified] | 0 | Sensor removed for good |
| Log Motion Diagnostics | 20 s wait to open the Lua tab, about 23 GETs one at a time, then 10 min of redacted events, at most 200 lines (`bridge/motion_diag.lua:16-30`, `:124-176`) [verified] | about 23 GETs | Tester or support, on request, pasted into a public issue |
| Refresh From Bridge (Hue Motion) | Sends `HUE_MOTION_HELLO`; the bridge answers from its cache (`hue_motion/driver.lua:1094-1102`) [verified] | 0 bridge requests | Nobody: the hello is also sent at late init and on every bind (`hue_motion/driver.lua:1217`, `:1243`) [verified]; manual: "Normally not needed" |
| Test: Motion / Test: No Motion | OPENED or CLOSED to the proxy; Hue's state returns after 30 s (`hue_motion/driver.lua:846-874`) [verified] | 0 | Installer checking programming without walking past the sensor |

### 2.2 Connection rows

| Row | Today | Evidence |
| --- | --- | --- |
| Bridge IP Address | The only address source; a change resets identity, TLS verdict and key lock and restarts the checks (`driver.lua:1199-1248`) [verified] | — |
| Event Stream | State, plus per event "Connected since …, N containers, last …; N reconnects" (`netstream.lua:933`, `driver.lua:745-776`) [verified] | Carries Events Received and Last Event already |
| Stream Address | Network connection: `<ip> (network connection, binding 6001)` (`driver.lua:296`) [verified]; Web transfer: spelling and queue | Only informative under Web transfer |
| Events Received / Last Event | Written at most once a second (`driver.lua:98`, `:813-814`) [verified] | Duplicates of the Event Stream text |
| Diagnostic Server / Dev Server | DEV-ONLY block, stripped from release (`driver.xml:188-202`, `:523-552`, `tools/build.sh:109-117`) [verified] | — |
| Stream Timeout (s) | Web transfer only (`driver.xml:209-212` comment, contract `docs/raw-stream-design.md` §0.1) [verified] | — |
| Event Stream Transport | Network connection (default) / Web transfer; a failed network TLS check falls back for the run without changing the row (`driver.lua:298-301`, `:1071-1075`) [verified] | Changed by hand once (#329) |
| Stream Watchdog (s) | 60 to 3600, default 600; reconnect plus full read after that much silence (`stream.lua:64`, `netstream.lua`) [verified] | — |
| Debug Mode | Off / On, log verbosity only; no auto-off (`driver.lua:1195`, `common/device.lua:327`) [verified] | A dev build once left it On (`docs/status.md`) |
| Motion Sensors | List row with summary; a pick changes nothing (`driver.xml:164-170`) [verified] | Contract §0.3 keeps the four lists |

### 2.3 What already runs by itself (no click)

- **Identity check** (unkeyed `GET /api/0/config`). It runs at every start and
  address change, and again every 30 s while the bridge does not answer; a
  different bridge id never retries (`driver.lua:845`, `:950-1032`)
  [verified].
- **TLS self-check** (1 unkeyed GET with a decoy CA). It runs once per start
  and address. "Inconclusive" passes only on a Director version that answered
  "pinned" before (`driver.lua:908-948`, `bridge/tlscheck.lua`) [verified].
- **Network-connection TLS check.** It runs once per Director version (no
  probe once remembered). While inconclusive it backs off from 30 s to 1 h,
  and its 900 probe ids are spent once each (`bridge/netcheck.lua:26-46`)
  [verified]. Open issue #329: probe bindings stay registered.
- **Stream reconnect.** Backoff 1 to 60 s; the watchdog reconnects after 600 s
  of silence; every connect runs the full read (`stream.lua:63-66`,
  `driver.lua:781-792`) [verified]. Disconnected text: `Disconnected: <err>.
  Reconnecting in <n> s` (`netstream.lua:960`) [verified]. **Neither the
  identity check nor Status reacts to a stream that keeps failing**:
  `verify_identity` is called only from `choose_stream_address` and
  `test_connection` (`driver.lua:1118`, `:1343`) [verified].
- **Rows timer**: Attention and lists re-evaluated every 5 min with no bridge
  request (`driver.lua:2293`) [verified]. Motion's "after one hour" items
  (D5) come due through it.
- **Motion**:
  - Stuck-motion GET after 5 min of motion with no news (D9,
    `motion.lua:158`, `:1621-1730`) [verified].
  - "Bridge away" after 60 s without a stream (`motion.lua:156`,
    `:1233-1245`) [verified].
  - New sensors and areas are cached, listed and counted from `add` events and
    reads; `AddDevice` from an event, a read or a start is forbidden
    (`docs/edge-cases-motion.md` S1, A1) [verified].
- **Children**: a device re-checks its binding after start (motion gives up
  after 61 s, `hue_motion/driver.lua:53`) [verified].

### 2.4 Self-healing audit

**a. Pairing, one click.** Today the first click ends in "press the link
button, then run Pair Bridge again" (`driver.lua:1292`) [verified].
- *Proposal.* Pair Bridge opens a **pairing window**: the probe as today, then
  `POST /api` every 2 s for up to 120 s while the bridge answers 101 (link
  button). It stops at the first key, at an error, at a new address or at
  Forget Pairing.
- *Automatic opening.* The window also opens when `Bridge IP Address` is
  entered (or discovered, d below) on a driver that is not paired and has no
  pairing in progress. Entering the address is the installer's deliberate act.
- *Never.* No window at a start, on a key rejection, or for ever: a window
  left open would hand Control4 a key the next time anyone presses the button
  for another app, which silently undoes a deliberate key removal in the Hue
  app.
- *Status texts.* `Press the link button on the Hue bridge (waiting 1:40)`,
  refreshed every 10 s. Then `Paired`, or `Not paired: the link button was not
  pressed within 2 minutes; press it, then click Pair Bridge`.
- *Facts.* The 101 meaning is [assumed] (`bridge/pairing.lua:17-18`). The
  button staying active about 30 s after a press is [assumed: Hue developer
  docs, login-walled]. 2 s polling stays far under any limit (1 small POST).
  Each success mints a new key, so polling must end at the first one
  [verified: `pairing.lua:174-178` stores what it gets].
- *Replacement bridge.* When the probed bridge's `/api/0/config` reports
  `replacesbridgeid` equal to the stored id (Hue app transfer; field
  [verified: `docs/edge-cases-hue.md` §4, Signify Discovery page]), Pair
  Bridge may accept it without Forget Pairing; rids that survive keep their
  devices (the existing reconcile). Any other bridge still needs Forget
  Pairing (#236).

**b. Key revocation.** A 401/403 on the stream, or a confirmed one on REST,
locks every keyed send until Pair Bridge, a new address, or a Test Connection
that gets 200 (`driver.lua:356-396`, `docs/design.md` "A rejected key")
[verified]. A real revocation (factory reset, key removed) needs the link
button: no automation can fix it. A false lock (a 403 for another reason,
which #217 admits is possible, [assumed]) clears only by hand.
- *Proposal.* An automatic **key re-check**, exactly Test Connection's
  request and rules, at 5 min, 15 min, 1 h, then hourly while locked. Guards:
  identity passed, TLS verdict not `not_pinned`, one at a time.
- *Status text.* `Key rejected by the bridge (HTTP 403) since 14:02: press the
  link button, then click Pair Bridge (checked again at 15:02)`.
- A Director restart already re-presents the key once, since the lock lives
  in memory (`state.key_rejected`, `driver.lua:65`) [verified], so an hourly
  re-check is no new exposure. It does depart from the review rule that only
  Test Connection re-presents a rejected key (`docs/design.md` "A rejected
  key"): question Q3.

**c. Stream drop and outage.**
- *Proposal.* After the stream has been down 60 s or longer, re-run the
  unkeyed identity check (1 GET, plus the TLS check: 1 GET) before the key
  goes out again.
- *What it catches.*
  - A different device or bridge now at the address (today the key would go
    to any Signify-signed peer there, since the hostname is not checked:
    `docs/design.md` "Certificates").
  - The Bridge Firmware and Name rows refresh after a bridge update; today
    they refresh only at a start (`driver.lua:886-896`) [verified].
  - **Status stops saying `Paired` while the bridge is unreachable**: it reads
    `Bridge at 10.0.2.143 not reachable (…); checking again in 30 s`, the
    existing text.
- *Cost.* Two unkeyed GETs per outage; the reconnect waits about 1 s longer.
- *Stays as it is.* Address rotation is Web-transfer-only and needs nothing
  more. The watchdog cadence waits for #65's measurement (section 2.5).

**d. Discovery and IP change** (`docs/design.md` "Discovery": manual IP only,
no discovery code [verified]).

| Route | Facts | Verdict |
| --- | --- | --- |
| Signify cloud endpoint `GET https://discovery.meethue.com` | Returns `[{id, internalipaddress}]`; at most 1 request per 15 min per client; needs the internet and system CAs [verified: `docs/design.md` "Discovery" step 2]. Release builds contact no public host today (`docs/design.md` "Certificates", 2026-10-25 note) [verified] | Feasible now, smallest build (one GET, rate memory, candidate check). Owner decision (Q1) |
| mDNS `_hue._tcp.local`, TXT `bridgeid` | Bridges advertise it [verified: `docs/design.md` "Discovery" step 5]. `NetConnect` takes `UDP` or `MULTICAST` [verified: `API/32_serial_network_device/_23-NetConnect.md`]. Receiving an answer from the bridge on a binding whose address is 224.0.0.251, or a unicast reply (QU bit) to the source port [assumed]; a DNS query and parser in Lua, about 200 lines [assumed] | Local, no internet; needs one dev-loop spike first |
| SSDP | Disabled by Signify in Q2 2022 [verified: `docs/design.md`] | No |
| SDDP | Control4's own; Hue does not announce it [assumed: `docs/design.md`] | No |
| Subnet sweep of `/api/0/config` | A TLS handshake to every host on the LAN; slow on one C4:url queue per host [assumed] | No (at most a Diagnostics run, not proposed) |

- *Proposal (both routes).*
  - **At setup**: a never-paired driver with an empty address runs discovery
    once at late init and on a click of Pair Bridge.
    - Exactly one bridge: it fills `Bridge IP Address` and opens the pairing
      window (a). Status: `Found Hue Bridge Pro at 10.0.2.143: press its link
      button now (waiting 1:55)`.
    - Several: they are listed in Attention as "Hue bridges found: …; enter
      one in Bridge IP Address", and nothing is chosen.
  - **IP change**: the identity check has failed for 5 min (10 retries), or
    c's outage check fails. The driver then looks for the **stored bridge
    id** only: endpoint at most 1 per 15 min, backing off to hourly; mDNS
    every 5 min, backing off to 30 min. A candidate must pass the identity
    and TLS checks.
  - **Then** the driver writes `Bridge IP Address` and calls its own property
    handler: `OnPropertyChanged` does not fire for a driver's own
    `UpdateProperty` [verified: `API/24_properties/_3-OnPropertyChanged.md`].
    Last Action: `The bridge moved from 10.0.2.143 to <new address>: Bridge IP
    Address updated; reserve its address in the router`. Attention shows the
    same item for 24 h.
- *Guards.* An IP-change search looks for the stored bridge id only, never
  starts in the first 5 min after a start (a power cut reboots the bridge
  too), and never runs while the paired bridge answers. The setup search runs
  only on a driver that has never been paired.
- *Without discovery* (if Q1 and the spike both say no), c still makes the
  failure visible and truthful, and the installer types the new address as
  today.

**e. Certificate pinning re-check.** Pinning is a property of the controller
OS: a Director update restarts the driver, and both checks key their memory
on the Director version (`tlscheck.lua` header, `netcheck.lua:40-46`)
[verified]. Periodic runs would add nothing and would burn netcheck's
900-id budget (#329). Check CA Pinning needs example.com, so it cannot be
automatic in release builds without a new internet dependency. **Not
periodic.**

**f. Periodic read as a safety net.**
- *While the stream is connected*: a full read happens only at connects. A
  busy house can stay connected for days. SSE on one TCP connection loses no
  data [assumed], but a full read guards against driver bugs and missed
  edge cases.
  - *Proposal*: a full read when none has run for 6 h, from any cause, with
    ±30 min jitter.
- *While the stream is down and the bridge answers*: the #324 case.
  - *Proposal*: a full read every 10 min after the stream has been down 3 min,
    stopping when it connects.
  - *Status text*: Event Stream `Disconnected: <err>. Reconnecting in 60 s;
    lists read from the bridge at 14:20`.
- *Collision with a click.* An owner action during a read gets `Busy: …; try
  again in a moment` (`bridge/owner.lua:767-787`, `busy_text`) [verified]. A background
  read must not refuse a click: Q8.
- *Command latency.* Reads and commands share Director's per-host C4:url queue
  (`docs/design.md` "C4:url transfer scheduling") [verified]. A command
  therefore waits for at most the one GET in flight (the 351 KB catalogue is
  the longest; its time is not measured [assumed: under 1 s]). The scheduler
  should defer a background read while a command went out in the last 5 s.

**g. Motion.**
- New sensors and areas, battery and reachability already arrive by events and
  reads.
- Attention lists them: a low battery at once, unreachable or degraded after
  1 h (D5, D6), and new devices with re-link hints (EC S1, S4, A1) [verified].
- Creating a device stays **forbidden without a click** (EC S1, A1;
  contract principle 2). So import stays **offered**, and nothing periodic
  is added beyond f.

### 2.5 Cost and budget per background task

Hue limits: about 10 req/s to `light`, 1/s to `grouped_light`; the REST API
is not for continuous streams [verified: `docs/design.md` "Commands and rate
limiting"]. No documented GET limit [assumed]. Every read below is one GET at
a time.

| Task | Trigger and cadence | Requests per run | Budget per day | Status or row |
| --- | --- | --- | --- | --- |
| Full read at connect (exists) | every stream connect | 17 (Pro) / 15 (v2), about 400 KB on the house | unmeasured; at most 6/h in a quiet house under the 600 s watchdog (#65 open) | Event Stream |
| Safety-net full read (new) | none for 6 h, ±30 min jitter; never in the first 10 min after a start | 17 | ≤ 4 runs, 68 GETs | log; Attention on failure |
| Stream-down read (new) | stream down ≥ 3 min, bridge answering; every 10 min | 17 | ≤ 144 runs, 2,448 GETs, only while down | Event Stream suffix |
| Outage identity re-check (new) | stream down ≥ 60 s, before the key goes out again | 2 unkeyed | ≤ 2 per outage | Status (existing texts) |
| Key re-check (new) | while locked: 5 min, 15 min, 1 h, then hourly | 1 keyed | ≤ 27 | Status |
| Identity retry (exists) | 30 s while unreachable | 1 unkeyed | 2,880 while down | Status. Optional: back off to 5 min after 1 h |
| Pairing window (new) | Pair Bridge click; address entered or found while unpaired; every 2 s for 120 s | 1 POST | ≤ 60 per window | Status countdown |
| Discovery, cloud (new, Q1) | setup without an address; unreachable ≥ 5 min | 1 public GET + 1 config GET per candidate | ≤ 96 by Signify's rule; 24 recommended | Status, Last Action, Attention |
| Discovery, mDNS (new, spike) | as above; 5 min backing off to 30 min | 1 multicast packet | ≤ 288 | as above |
| Rows timer (exists) | 5 min | 0 | 0 | Attention, lists |
| Stuck-motion GET (exists) | per sensor after 5 min of motion | 1 | bounded by motion | device Status |

**Must not be periodic:** the TLS self-check and the network-connection
check (once per start or address, and once per Director version: e above),
Check CA Pinning (public host), Log Motion Diagnostics (its output goes into
public issues, and its 10-minute capture logs household motion), and any
`AddDevice` (EC S1, A1).

**Startup after a Director restart.**
- What runs today: late init, then 1 identity GET, 1 TLS GET, no netcheck
  probe (remembered), the stream connect, and 17 GETs (`driver.lua:2262-2328`)
  [verified]. Child hellos are answered from the bridge's cache with no GET.
- None of the new tasks may add to that:
  - The safety net is anchored to the last full read, and the connect's read
    counts.
  - Discovery waits 5 min of unreachability.
  - The key re-check starts only from a lock.
  - The pairing window never opens at a start.
  - The stream-down read starts 3 min after the stream went down.

**REST over a network connection (the owner's suggestion).** Nothing above
depends on it. Cost, if wanted:
- The reusable part: netstream's HTTP reader (status line, headers, chunked
  and Content-Length bodies; `netstream.lua`, 982 lines with the stream
  logic) [verified].
- New work [assumed]: a request writer and FIFO on a keep-alive connection
  (probably two, commands and reads), per-request timeouts, reconnects,
  bodies up to 351 KB and beyond held in Lua strings, fresh binding ids (a
  reused id is only renamed by Director: `netcheck.lua:20-25`) [verified],
  and gating behind the existing netcheck verdict. About 350-500 lines plus a
  spec and a hardware pass.
- What it would remove: the per-host serialisation between commands and
  reads, the C4:url path for keyed requests in `bridge/http.lua`, and with it
  the padded-address spellings (`bridge/altaddr.lua`) and the single-queue
  mode. Worth its own issue; not needed for this simplification.

## 3. Verdicts

| Action | Verdict | Reason |
| --- | --- | --- |
| Pair Bridge | **KEEP** (behaviour changed: one click, a 2-minute wait for the link button, also opened by entering or discovering an address; accepts the replacement bridge Hue names via `replacesbridgeid`) | Pairing needs a person at the bridge; the click is theirs, the second click is not. |
| Test Connection | **AUTOMATIC** | Trigger: a key-rejected lock, re-checked at 5 min, 15 min, 1 h, then hourly, plus the outage identity re-check (2.4 c). Guards: identity passed, TLS not failed, one at a time. Status text as 2.4 b. On demand it stays as Diagnostics ▸ "Check the connection now". |
| Connection Test (dev) | **MOVE to diagnostics** | The Diagnostics picker of dev builds (two entries: bridge, diagnostic server) and `devctl.py run`. The question it answered is settled, but its code is the only harness for the C4:url facts. |
| Connect Event Stream | **MOVE to diagnostics** | Diagnostics ▸ "Reconnect the event stream". The stream starts itself at every start, pairing, address and transport change, so the click is needed only after a Disconnect. |
| Disconnect Event Stream | **MOVE to diagnostics** | Diagnostics ▸ "Stop the event stream until the next start": a support tool; nothing everyday stops the feed. |
| Reload Credentials (dev) | **MOVE to diagnostics** | Dev-build Diagnostics entry. The startup log line covers "readable"; the in-memory comparison is a developer's check. |
| Check CA Pinning (dev) | **MOVE to diagnostics** | Dev-build Diagnostics entry, still run once per OS upgrade (release checklist §4). Not automatic: it needs a public host, which release builds never contact; it proves "replaces, not adds", which the automatic checks cannot. |
| Forget Pairing | **KEEP** | Destructive and rare (another bridge, decommissioning). It must stay a deliberate, named click; the replacement-bridge case no longer needs it (Pair Bridge above). |
| Refresh All | **AUTOMATIC** | Triggers: every stream connect (as today); a full read when none ran for 6 h (±30 min); every 10 min while the stream has been down 3 min and the bridge answers. Guard: defer while an owner action or a command burst runs. Visible as the Event Stream suffix `lists read from the bridge at 14:20` and an Attention item on failure. On demand: Diagnostics ▸ "Read everything from the bridge now". Refresh Scenes (import family) is a subset and should get the same verdict. |
| Add Motion Sensor | **MERGE into Add From Hue** (the import research's one add, §5.1 there) | A folder `Motion sensors and areas (N new)`: sensors first, then MotionAware areas, as EC A1 first recommended; a click per device stays the installer's (EC S1). Fallback if Composer's Folder lists misbehave: Add Motion Sensor stays, its picker holding sensors, areas and the bulk row. |
| Add Motion Area | **MERGE into Add From Hue** | Both handlers call the same `motion:add(rid, room)` (`driver.lua:1805-1829`); areas are rows after the sensors in the motion folder, marked "(MotionAware)". |
| Import All New Motion Sensors | **MERGE into Add From Hue** | The motion folder's first row, "All N new motion sensors → their mapped rooms", runs today's `motion:import_new` with its skips and texts; areas stay one at a time (D15, EC A15). |
| Re-link Motion Device | **MERGE into Link Device** (import research §5.2) | Motion devices join its Device list (gone, unbound) with the MAC or name hint of EC S4 and S6 as "the suggested match"; the module keeps refusing a kind change (D4). Re-linking on its own stays forbidden (EC S4). |
| Forget Motion Device | **MERGE into Forget Device** (import research §5.5) | Precedent: Forget Light already joins lights and zone lights (`driver.lua:1591-1594`); the joined picker adds scenes and motion devices. |
| Log Motion Diagnostics | **MOVE to diagnostics** | Diagnostics ▸ "Log motion diagnostics (10 minutes)", in release builds: the outside tester needs it. |
| Refresh From Bridge (Hue Motion) | **RETIRE** | Replaced by the hello at every start and bind (`hue_motion/driver.lua:1217`, `:1243`) and the bridge's fan-out after every full read, now also every 6 h. The manual already says "Normally not needed". |
| Test: Motion (Hue Motion) | **MERGE into "Test Motion Programming"** | One action, no dialog: it sends the opposite of what the device shows now, then Hue's state again after 30 s. In an empty room one click fires the motion programming, then the no-motion programming. |
| Test: No Motion (Hue Motion) | **MERGE into "Test Motion Programming"** | Its case (the sensor showing motion while someone stands in the room) is the toggle's other half. The logic is `run_test` plus `held_state` (`hue_motion/driver.lua:836-874`). |

Properties:

| Row | Verdict | Reason |
| --- | --- | --- |
| Bridge IP Address | **KEEP** (filled or updated by discovery, 2.4 d) | The installer's field; the driver writes it only for the same bridge id, and says so. |
| Event Stream | **KEEP** | The one health row; gains the stream-down read suffix. |
| Stream Address | **MOVE to diagnostics** | Shown only under Web transfer or Debug Mode On (`C4:SetPropertyAttribs`, hidden rows as Last Action (2) to (6) do, `driver.lua:1428`) [verified]. |
| Events Received, Last Event | **MOVE to diagnostics** | The Event Stream row carries both. Shown only with Debug Mode On. |
| Diagnostic Server, Dev Server | **KEEP** (dev builds only, as today) | Already stripped from release. |
| Stream Timeout (s) | **MOVE to diagnostics** | Shown only under Web transfer or when non-default. |
| Event Stream Transport | **MOVE to diagnostics** | A fallback setting: shown when non-default, after an automatic fallback (Attention already says so), or with Debug Mode On. |
| Stream Watchdog (s) | **MOVE to diagnostics** | Shown when non-default or with Debug Mode On. |
| Debug Mode | **KEEP** | Log verbosity. Optional: back to Off by itself after 24 h, and it reveals the diagnostic rows. |
| Motion Sensors | **KEEP** | One of the four lists (contract §0.3); it carries the offers. |

## 4. Target action lists

**Bridge, these families: 12 release actions (plus 3 dev-only) become 3 of
their own; the six motion actions go into the import family's actions or
Diagnostics.** With the import research's 5, the bridge would show 8
actions instead of 32 (29 in release builds).

1. **Pair Bridge**: one click; waits up to 2 min for the link button.
2. **Forget Pairing**.
3. **Diagnostics** (Run): one CUSTOM_SELECT picker. That action parameters
   render in Composer is [verified: `docs/design.md` "Composer Pro 3.4.2 UI"].
   Entries in this order (harmless first, since Composer remembers the last
   pick per action):
   - Check the connection now
   - Read everything from the bridge now
   - Reconnect the event stream
   - Stop the event stream until the next start
   - Log motion diagnostics (10 minutes)
   - dev builds only: Connection experiment: bridge / diagnostic server;
     Reload credentials; Check CA pinning (needs the internet)

Into the import family's actions: **Add From Hue** (a motion folder with an
"All N new motion sensors" row), **Link Device** and **Forget Device**.

**Hue Motion: 3 actions become 1:** **Test Motion Programming**.

| Old action | New home |
| --- | --- |
| Pair Bridge | Pair Bridge (one click); automatic when an address is entered or found on an unpaired driver |
| Test Connection | automatic key re-check and outage check; Diagnostics ▸ Check the connection now |
| Connection Test (dev) | Diagnostics ▸ Connection experiment (dev builds); `devctl.py run "Connection Test"` |
| Connect Event Stream | automatic at start, pairing, address and transport change; Diagnostics ▸ Reconnect the event stream |
| Disconnect Event Stream | Diagnostics ▸ Stop the event stream until the next start |
| Reload Credentials (dev) | Diagnostics ▸ Reload credentials (dev builds); startup log line |
| Check CA Pinning (dev) | Diagnostics ▸ Check CA pinning (dev builds); release checklist §4 unchanged |
| Forget Pairing | Forget Pairing |
| Refresh All | automatic (connect, 6 h, stream down); Diagnostics ▸ Read everything from the bridge now |
| Add Motion Sensor, Add Motion Area | Add From Hue ▸ Motion sensors and areas (fallback: Add Motion Sensor) |
| Import All New Motion Sensors | Add From Hue ▸ "All N new motion sensors" row |
| Re-link Motion Device | Link Device, with the MAC or name hint as the suggested match |
| Forget Motion Device | Forget Device |
| Log Motion Diagnostics | Diagnostics ▸ Log motion diagnostics (10 minutes) |
| Refresh From Bridge (motion) | automatic: hello at start and bind; fan-out after every full read |
| Test: Motion, Test: No Motion | Test Motion Programming (toggle, back to Hue's state after 30 s) |

**Switching it off** (principle 3): one bridge setting, **Background Tasks**,
with these values:
- **On** (the default if Q1 = yes): everything new in 2.4.
- **On, no internet**: everything but the cloud endpoint.
- **Off**: only what 1.0 did: reads at connect, identity retries, the
  stream's own reconnects. No pairing window, no key re-check, no safety-net
  or stream-down reads, no discovery.

## 5. Risks and open questions for the owner

Each question has a recommended answer; one word decides it.

- **Q1. May release builds ask Signify's discovery service on the internet**,
  at first setup without an address and when the paired bridge has been
  unreachable for 5 min, at most hourly, switchable off? **Recommended: yes**,
  with a dev-loop mDNS spike in parallel. If mDNS works, make "On, no internet"
  the default. Without either, an IP change stays a manual fix.
- **Q2. May the driver rewrite Bridge IP Address by itself** when it finds the
  *same* bridge id elsewhere, after the identity and TLS checks, and say so in
  Last Action and Attention? **Recommended: yes**: it is the same bridge, and
  the change is visible and reversible by typing.
- **Q3. May an hourly key re-check present a rejected key again**, departing
  from the 2026-10-25 rule that only Test Connection does? **Recommended:
  yes**: a restart already does it, the peer is verified, and it ends false
  locks without a visit.
- **Q4. Should the pairing window open by itself** when an address is entered
  or found on a never-paired driver? **Recommended: yes**: 120 s, never at a
  start, never on a key rejection.
- **Q5. Safety-net read every 6 h, and every 10 min while the stream is
  down?** **Recommended: yes** (at most 68 GETs a day while connected).
- **Q6. Diagnostics as one action with a picker, or as Debug Mode levels?**
  **Recommended: the action**: a run is a one-shot; Debug Mode stays log
  verbosity.
- **Q7. Motion test: one toggle action on the device, or entries under the
  bridge's Diagnostics?** **Recommended: the toggle on the device**: an
  installer tests programming where they are working, and it is not a support
  tool.
- **Q8. A click during a background read: wait or refuse?** Today `Busy: …;
  try again in a moment` (`owner.lua:780-787`). **Recommended: wait** (queue
  the action behind the read, at most about 30 s), so a background task never
  refuses the installer.
- **Q9. Hide the six connection rows** (Stream Address, Events Received, Last
  Event, Stream Timeout, Event Stream Transport, Stream Watchdog) unless they
  are non-default, under Web transfer, or Debug Mode is On? **Recommended:
  yes**. Risk: Composer drops attribute changes that arrive with text updates,
  so the Last Action rows' re-send pattern applies (`docs/status.md`, build
  247 notes) [verified].
- **Q10. Keep Check CA Pinning dev-only and manual?** **Recommended: yes**.
  Making it automatic would add a public-host request to every release build.

Further risks:

- **Texts that name actions.** Attention items, Status texts, the manuals,
  `docs/composer-checklist.md`, the release checklist's action count, tester
  briefs and `devctl.py` usage name the actions being merged or moved
  (`Pair Bridge` in `refresh_status`, `(Add Motion Sensor)` in motion
  Attention texts). The compat research owns that list. Composer programming
  does not use these actions, since they are LUA_ACTIONs and not proxy
  commands [assumed: confirmed for #325's rename].
- **mDNS on Director** is unverified (2.4 d). The spike may show that answers
  never reach the driver.
- **Watchdog cost** (#65): in a quiet house every 600 s of silence still means
  a reconnect and a full read. Lengthening the watchdog under Network
  connection, where TCP keepalive detects a dead peer [assumed: timing
  unknown], would cut that. Decide after the day's reading.
- **Pairing-window races**: a second click restarts the window; an address
  change or Forget Pairing ends it. Specs must cover a key arriving after the
  window was cancelled (store nothing).
- **Hidden non-default settings**: covered by "shown when non-default". A row
  hidden while it holds Web transfer would hide why the stream behaves
  differently.
