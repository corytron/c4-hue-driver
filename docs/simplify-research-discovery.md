# Local bridge discovery: research for D5 (#334)

Research file of the simplification contract
([simplify-actions-design.md](simplify-actions-design.md), section 0), for
the owner's answer D5 of 2026-11-05 (section 1.8): **local discovery only,
never Signify's cloud service, not even as a fallback.** Read-only research
of 2026-11-05; nothing here is built. Citation prefixes: `API/` is
`~/c4-tools/reference/docs-driverworks-api/source/includes/`, `FUND/` the
same for `docs-driverworks-fundamentals`, `LIB/` is
`~/c4-tools/drivers-common-public/`; other paths are this repository's.
Addresses are placeholders: `10.0.2.143` the paired bridge, `192.0.2.x`
any other host, `001788fffe123abc` the bridge id.

## 1. Findings

1. **mDNS can be sent with documented calls; whether answers come back is
   the one open question.** A UDP network connection to `224.0.0.251:5353`
   is how Snap One's own SSDP module searches `239.255.255.250:1900`. A
   query from Director's ephemeral port is a *legacy unicast* query (RFC
   6762 §6.7), answered by unicast to that port, so no group membership is
   needed. Only hardware shows whether Director delivers a reply from an
   address other than the connection's, and whether the bridges honour
   §6.7 (OpenWrt's umdns did not until 2024).
2. **No API gives a driver its netmask or gateway.** A subnet probe must
   guess /24 ranges around the last good address and
   `C4:GetControllerNetworkAddress()`, and stop there.
3. **SSDP is not a route, only the probe's control.** Signify announced its
   switch-off for Q2 2022; it still answered in 2023. `docs/design.md:1313`
   ("disabled [verified]") overstates an announcement.
4. **Identity is the bridge id from the unkeyed `/api/0/config` over the
   pinned Signify chain; the CN is never compared.** No API exposes the
   peer certificate, so a "CN check" does not exist. The identity check
   plus the decoy TLS self-check, unchanged, prove as much as pairing does.
5. **The local fallback: a TCP pre-scan with `C4:CreateTCPClient`, then
   today's `pairing.probe` for the few hosts that accept port 443.** Not
   network connections (a fresh binding id per probe, silent refusals),
   not `C4:url` per host (connect timeouts holding controller-wide slots).
   A /24 costs at most 254 TCP connects in about 95 s with 4 in flight; no
   HTTP request reaches a device that is not Signify's.
6. **First load: one new `DYNAMIC_LIST` row, Bridges Found.** Items read
   `Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC`, plus Search again,
   plus an offered subnet search when nothing answered. A pick sets Bridge
   IP Address and opens the 2-minute pairing window. Typing the address
   keeps working as today.
7. **The follow-up never pairs and never adopts another bridge id.** It
   writes Bridge IP Address and calls the property's own handler
   (`OnPropertyChanged` does not fire for a driver's own `UpdateProperty`).
   The identity and TLS checks of the new address therefore run before the
   key goes out, and Last Action says what moved.
8. **One probe of about two minutes on the D9 dev build settles every
   unknown**, run through `devctl.py run` with no Composer clicks: an SSDP
   control, three mDNS variants, the environment, and a timed sweep.
9. **Cost:** about 700 lines of Lua in three new modules plus specs, one
   new property, no `<capabilities>` change (so no reboot) and no new
   action.

## 2. Evidence

### 2.1 What DriverWorks offers (question 1)

| Call | Use for discovery | OS | Status and source |
| --- | --- | --- | --- |
| `C4:CreateNetworkConnection(id, "224.0.0.251")`, `C4:NetConnect(id, 5353, "UDP")` | a UDP connection to the mDNS group; ids 6000-6999; never in OnDriverInit | 1.6.0+ | **verified** docs `API/32_serial_network_device/_1-CreateNetworkConnection.md`, `_23-NetConnect.md`; the same calls for SSDP in `LIB/module/ssdp.lua:115-188` (verified code; that it works on our controller: **assumed**) |
| NetConnect type `"MULTICAST"` | listed as an IP type; whether it joins the group or binds the port is undocumented | 1.6.0+ | existence **verified** (`_23-NetConnect.md`); behaviour **unknown**; Snap One's SSDP uses `"UDP"`, not this |
| `C4:SendToNetwork(id, port, data)` | one datagram; NUL bytes allowed | 1.6.0+ | **verified** `_20-SendToNetwork.md` |
| `ReceivedFromNetwork(binding, port, data, from)` | the answers; `from`, the sender, only "Enhanced in 4.0.0" | 3.x without `from` | **verified** `_15-ReceivedFromNetwork.md`; whether OS 3.4.2 passes a fourth argument anyway: **unknown** |
| UDP without NetConnect | "no need" for NetConnect with UDP (static XML connection) | all | **verified** `FUND/11_connections/_7-USERDATAGRAMPROTOCOL.md`; Snap One's module still sends only after `ONLINE` (`LIB/module/ssdp.lua:143-157`) |
| `NetPortOptions` `MIRROR_UDP_PORT` | source port = destination port, so a query from 5353 (dynamic connections only) | 2.8.0+ | **verified** `_25-NetPortOptions.md`; a clash with a responder on the controller: **unknown** |
| `C4:PortInUse(5353)` | whether something on the controller holds 5353 | 3.3.1+ | **verified** `API/9_helper/_13.5-Portinuse.md` |
| `C4:CreateServer(0, "", true)`, `OnServerDataIn(handle, data, address, port)` | UDP listener with the sender's address on every version; sending to an address (`ServerSend(port, payload, address)`) only from 4.0.0 | 2.10.0 / 4.0.0 | **verified** `API/33_server_sockets/_2-CreateServer.md`, `_5-OnServerDataIn.md`, `_6-ServerSend.md`; on 3.x it can listen but not ask: not our route |
| `C4:SendBroadcast` | broadcast, not multicast | 2.10.0 | **verified** `_18-SendBroadcast.md`; no use |
| `C4:CreateTCPClient()` | plain TCP: Connect, OnConnect, OnError, Close (Close cancels a pending connect, then OnError) | 1.6.0 per the doc | **verified** docs `API/14_lua_tcp_client/_1-Overview.md`, `_3-Connect.md`; no TLS (`docs/raw-stream-design.md:83-92`); never used in this repository, so its behaviour on OS 3.4.2 is **assumed** |
| `C4:GetControllerNetworkAddress()` | the master controller's address | 1.6.0 | **verified** `_5-GetControllerNetworkAddress.md` |
| Netmask, gateway, interfaces | no API | none | **verified absence**: "netmask" and "subnet" appear nowhere in `~/c4-tools/reference/` |
| `C4:CreatePingClient()`, `C4:GetDeviceMAC(id)` | ICMP reachability; the ARP entry of a binding's address | 3.3.1 / 2.10 | **verified** `API/23.5_ping/`, `_7-GetDeviceMAC.md`; neither proves identity, not needed |
| SDDP, `C4:GetDiscoveryInfo` | Director's discovery of devices that announce SDDP, DDDP or UPnP | 2.10 | **verified** `_8-GetDiscoveryInfo.md`; Hue does not announce SDDP (**assumed**, `docs/design.md:1314-1315`) |
| A discovery or mDNS helper | none in the API; `LIB/` has SSDP only (`module/ssdp.lua`) | none | **verified absence** |
| What OS 4.x adds | only `from`, `ServerSend`'s address and `SendBroadcast`'s source port | 4.0.0 | **verified** the "Enhanced in 4.0.0" lines above and `API/3_whats_new/_5`, `_6`, `_7` |

**Binding ids.** On OS 3.4.3 a never-used id behaves, while an id that was
cleared and then reused may inherit an old connection or do nothing
(`src/hue_bridge/bridge/netcheck.lua:14-27`, hardware, **verified**).
Discovery therefore takes fixed ids never used before in the project. Each
is created once per run and never cleared, as 6001 is for the stream. The
free ids are 6004 to 6099: 6001 is the stream's, 6002 and 6003 belong to
earlier builds, and 6100 to 6999 are netcheck's (`netcheck.lua:28-31`).
The driver's globals route by binding (`src/hue_bridge/driver.lua:2365-2383`),
so discovery adds one branch to each. Between 3.x and 4.x only the sender
address differs: `from` on 4.x, the answer's A record on 3.x.

### 2.2 What the bridges answer (question 2)

- **mDNS records.** Service `_hue._tcp.local`, instance name `Philips Hue -
  <last 6 hex digits of the bridge id>`, TXT keys `bridgeid` and `modelid`
  (`docs/design.md:1306-1308`, **verified** there against Signify's
  Discovery page). Home Assistant's Hue integration reads exactly those two
  TXT keys. When a known bridge id appears at a new address it moves the
  stored host, and its BSB003 path reads `modelid` from the announcement
  ([HA config_flow.py, 2026.10.2](https://raw.githubusercontent.com/home-assistant/core/2026.10.2/homeassistant/components/hue/config_flow.py)).
  So the Bridge Pro advertises the service (**verified**: HA code). The SRV
  target is a host name derived from the MAC, ending in `.local`
  ([rjbs, 2023-01-21](https://rjbs.cloud/blog/2023/01/talking-to-philips-hue-lights-3/),
  **verified** for a v2). Whether the A record comes in the additional
  section of a unicast answer is **unknown** (probe P2).
- **A stale A record.** A Home Assistant maintainer saw a bridge keep
  announcing its old address after a DHCP change
  ([home-assistant/core#75996](https://github.com/home-assistant/core/issues/75996),
  2022-08-16, **verified** report). Every answer is therefore only a
  candidate until `/api/0/config` at that address confirms it.
- **Legacy unicast.** A responder must answer a query from a port other
  than 5353 by unicast to that address and port, repeating the query id
  ([RFC 6762 §6.7](https://www.rfc-editor.org/rfc/rfc6762.html), **verified**).
  OpenWrt's umdns always answered to 5353 instead
  ([openwrt/mdnsd#3](https://github.com/openwrt/mdnsd/issues/3), 2021, fixed
  2024). Which responder either Hue bridge runs, and whether it honours
  §6.7: **unknown** (probe P2). The QU bit (§5.4) with a 5353 source is
  the second variant (P3).
- **SSDP.** Signify's announcement said "will be disabled in Q2 2022". The
  rjbs post saw it still answering in January 2023. Home Assistant's Hue
  maintainer wrote on 2022-10-10 that v2 bridges "should only have zeroconf"
  (#75996). Firmware state on the Bridge Pro: **unknown**. Not a route.
  The probe uses it only as a control for the UDP path (P1), since any
  UPnP device on the LAN answers it.
- **The unauthenticated identity.** `GET /api/0/config` over HTTPS without
  a key answers `bridgeid`, `modelid`, `name`, `swversion` and
  `apiversion`. **Verified** on both models: `bridge/pairing.lua:33-50`
  and `driver.lua:966-985` read them on the house Bridge Pro, and on the
  tester's v2 (#309, `docs/status.md:446`). It also answers
  `replacesbridgeid` (**verified**, `docs/edge-cases-hue.md:105`), and
  `mac` and `factorynew` (**assumed**: community documentation; the code
  reads neither). Ids are compared lower case (`bridge/config.lua:36-45`,
  `docs/design.md:139-141`). Models: BSB002 is the v2, BSB003 the Pro, and
  BSB001 has no CLIP v2 (`config.lua:51-55`).
- **The certificate.** Its CN is the bridge id (`docs/design.md:89`; the
  case differs by model, `config.lua:34-35`). Requests run with
  `ssl_verify_peer = true`, `ssl_verify_host = false` and the two Signify
  roots as `ssl_cabundle` (`bridge/http.lua:37`), which replace the system
  store on OS 3.4.2 (`docs/design.md:110-121`, hardware **verified**).
- **What proves the right bridge answered**: (a) the chain verifies against
  Signify's private roots, so a genuine Signify device; (b) its `bridgeid`
  equals the stored id; (c) the decoy self-check shows (a) is enforced on
  this controller (`bridge/tlscheck.lua`, `docs/design.md:143-243`). No
  `C4:url` option or port option exposes the peer certificate to compare
  its CN (**verified absence**, `API/35_url/_12-SetOption.md`,
  `API/32_serial_network_device/_25-NetPortOptions.md`). Another genuine
  bridge reports its own id and is refused; only one with an extracted
  private key could lie (**assumed** out of reach, as today).
- **No request reaches another device.** A failed chain ends the transfer
  at the handshake (curl error 60) before any HTTP is sent
  (`docs/design.md:233-236`, the decoy, **verified** on OS 3.4.2).

### 2.3 The local fallback: a bounded subnet probe (question 3)

- **Stage A, reachability on port 443.** `C4:CreateTCPClient():Connect(ip,
  443)`, closed at `OnConnect`, at `OnError` or by a 1.5 s timer. It uses
  no binding id and no `C4:url` slot, and sends nothing.
- **Stage B, identity.** For each host that accepted, call
  `pairing.probe(ip)` (unkeyed `/api/0/config`, pinned bundle, 10 s
  timeout), one at a time, and stop at the stored id.
- **Order.** First the /24 of the last good address, starting there and
  alternating outward (DHCP often hands out nearby addresses: **assumed**).
  Then the controller's own /24, if it differs. Skip the controller's
  address. Only private ranges (10/8, 172.16/12, 192.168/16), never more
  than those two /24s, and never a wider guess: there is no netmask API
  (2.1).
- **Why not network connections (#317).** Every probe would need a fresh
  binding id: netcheck's 900 ids last for years at two per Director
  version, and a sweep would spend 254 an hour. A refused handshake is
  silent too, so every HTTPS device that is not Hue's would cost a full
  timeout (`docs/raw-stream-design.md:32`, hardware).
- **Why not `C4:url` for every host.** An absent host holds a transfer for
  the 5 s connect timeout (`bridge/http.lua:27`). Director runs four
  transfers at once controller-wide (`docs/design.md:1435-1440`), so other
  drivers would queue behind the sweep. The per-host queue
  (`docs/design.md:355-362`) does not slow it down, because every probe
  has its own host. Moving the bridge's REST calls onto the TCP module
  (principle 4) is a separate question, and it gains nothing here: the
  bridge is silent while the sweep runs.

| Stage (one /24, 254 addresses) | Connections | Worst case | Note |
| --- | --- | --- | --- |
| A, 4 in flight, 1.5 s cap | 254 TCP connects | 254 / 4 × 1.5 s ≈ 95 s | absent host: ARP failure or the timer; live host without 443: a reset within ms |
| B, one at a time | one per host with 443 open: routers, NAS, printers, other controllers, typically 2 to 10 (**assumed**) | under 10 s each, usually under 5 s in all | a chain that is not Signify's fails at the handshake |
| The controller's /24, when it differs | as above | another 95 s | rare in a home |

- **Larger subnets.** Never swept beyond those two /24s. A bridge outside
  them stays "missing", with the Attention hint to type its address. A /16
  would be 65,534 addresses, about seven hours at this rate: **forbidden**.
- **Politeness and cadence.** At most 4 connections in flight and 8 new
  ones a second, nothing written on any; at most one sweep an hour (the
  time persisted, so a restart does not reset it), none in the first 5
  minutes after a start; only while paired, the bridge unreachable for 5
  minutes and mDNS silent (or unusable here, section 3); it stops at the
  first match.
- **Risks.** A LAN intrusion detection system may flag an hourly sweep of
  port 443 (**assumed**: traffic within a subnet rarely crosses the
  gateway); 254 callbacks in 95 s should be light for Director (**assumed**,
  P5 measures it); some HTTPS devices log the aborted handshakes; a Hue
  emulator (diyHue and the like) fails stage B and is ignored.
- **Build cost.** `bridge/sweep.lua`, about 150 lines plus a spec. The
  fake runtime needs a fake TCP client: `tests/helpers/fake_c4.lua` has
  network connections (`:857-896`) but no `CreateTCPClient` today
  (**verified**).

### 2.4 The installer's first load (question 4)

**When the driver searches.** A driver with no stored key (never paired,
or after Forget Pairing) runs one mDNS search 3 s after `OnDriverLateInit`.
It searches again at 1 and 5 minutes, then every 15 minutes until it is
paired: one datagram each time. Each bridge found costs one unkeyed
`/api/0/config` to its address (`pairing.probe`, extended to return
`replacesbridgeid`), which confirms the chain and the id and reads `name`
and `modelid`. An answer whose address
fails the probe is dropped and logged under Debug Mode. Its A record may
be stale, or it may not be a Signify device.

**The new row.** **Bridges Found** is a `DYNAMIC_LIST` placed right below
Bridge IP Address. Adding a property is safe in an in-place update
(`docs/simplify-research-composer.md` §H). The summary comes first, then
one item per bridge, then the extra items. Items follow today's list rules:
commas become `‚` (`driver.lua:624-626`), and a pick snaps back to the
summary (`driver.lua:1489-1496`). Each item stays under 72 characters:
model label 14, the bridge's name cut to 20, address up to 15, the last 6
hex digits of the id (the mDNS instance name's), separators.

| Situation | Summary (the row's value) | Items |
| --- | --- | --- |
| Searching | `Looking for Hue bridges on the network...` | `Search again` |
| One or more found | `2 Hue bridges found: pick one and click Set to pair` | `Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC`, `Hue Bridge v2 - Garage - 192.0.2.61 - 456DEF`, `Search again` |
| None found | `No Hue bridge answered: type its address in Bridge IP Address` | `Search again`, `Search every address of 192.0.2.x (about 2 minutes)` (offered sweep: a known bridge id is not required at setup, so it lists every Signify device that answers) |
| A first-generation bridge | (as above) | `Hue Bridge v1 - Old - 192.0.2.62 - not supported (no CLIP v2)` (a pick explains, nothing else) |
| Paired | `Paired with Hue Bridge Pro at 10.0.2.143` | `(paired) Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC`, the others, `Search again` |

**What a pick does.**
- **Unpaired driver, a bridge picked.** The driver writes Bridge IP Address
  (`UpdateProperty`, then `dispatch.properties["Bridge_IP_Address"]`, the
  handler at `driver.lua:1199`, because `OnPropertyChanged` does not fire
  for the driver's own update: **verified**,
  `API/24_properties/_3-OnPropertyChanged.md`). It then opens the pairing
  window: up to 2 minutes, `POST /api` every 2 s while the bridge answers
  101 (`docs/simplify-research-maintenance.md` §2.4 a). The id picked is
  the expected one: a different bridge at that address during the window
  is refused, as `pairing.pair(ip, handlers, paired_id)` already refuses
  one (`pairing.lua:101`, `:134`). Status reads `Press the link button on
  Hue Bridge Pro "Upstairs" now (waiting 1:55)`.
- **Two or more bridges** (a Bridge v2 and a Pro side by side). Both are
  listed with the paired one first, then by name, and nothing is chosen
  for the installer. Whether another Hue Bridge driver in the project uses
  one is not shown: multiple bridges are out of scope (CLAUDE.md, "Later").
- **The paired bridge picked.** If its address equals Bridge IP Address,
  Last Action reads `Already paired with this bridge`. Otherwise this is
  the follow-up of 2.5: the address is rewritten, and no pairing happens.
- **Paired driver, another bridge picked.** Refused, as #236 refuses it
  today: `Paired with bridge 123ABC: click Forget Pairing first to switch
  to 456DEF`. The exception: a bridge whose `replacesbridgeid` equals the
  stored id reads `- replaces the paired bridge` in its item. Picking it
  takes the replacement path of the maintenance research (§2.4 a): try the
  stored key, re-pair at a 403, then reconcile. That makes it an offer
  that one click accepts.
- **Search again** repeats the mDNS search now. **Search every address**
  runs the sweep of 2.3 for any Signify device, at the installer's
  request. Both report in Last Action.
- **Zero bridges found.** The installer types the address in Bridge IP
  Address as today. On a never-paired driver that opens the pairing window
  too (maintenance §2.4 a).

### 2.5 The follow-up when the paired bridge changes address (question 5)

**Triggers.** Every trigger applies only while the driver is paired, never
in the first 5 minutes after a start (a power cut reboots the bridge too),
and with one search at a time.
- **T1.** The identity check of an address that verified before (the
  persisted *last good* address) keeps answering "not reachable" for 5
  minutes. That is ten 30 s retries (`driver.lua:845`, `:1011-1014`).
- **T2.** The stream has been down for 60 s or more, and the outage
  identity check (maintenance §2.4 c) fails. T1's clock then starts.
- **T3.** The last good address answers with another bridge id, for
  example when DHCP swapped two bridges. The search starts at once (after
  the start guard), but the other id is never adopted.
- **Not a trigger: an address the installer typed** that never verified.
  It is the installer's value: the driver says what it found and offers
  the bridge's real address as the `(paired)` item of Bridges Found.
  Attention reads `Bridge 123ABC answers at 192.0.2.57, not at the typed
  192.0.2.75: pick it in Bridges Found`. Principle 1 forbids overwriting
  what was set by hand.

**Search and recognition.**
1. mDNS for `_hue._tcp`: one query, 3 s of answers, repeated once. The
   candidate is the answer whose TXT `bridgeid` equals the stored id, at
   its A record, or at `from` on OS 4.x.
2. If no answer carries the id, or its address fails step 3, run the sweep
   of 2.3, at most hourly.
3. Every candidate must pass `pairing.probe` and report the stored id.
   Only then does the driver write the address. Through the handler, the
   new address's own identity check and decoy TLS check run before any
   keyed request (`driver.lua:1215-1246`, `:988-1001`).
4. Last Action: `Bridge 123ABC moved from 192.0.2.40 to 192.0.2.57 (found
   by mDNS): Bridge IP Address updated; reserve its address in the
   router`. The same text sits in Attention for 24 hours. A sweep says
   `found by a search of 192.0.2.x`.
5. If nothing is found, Status keeps today's `Bridge at 192.0.2.40 not
   reachable (...); checking again in 30 s`. After an hour, Attention
   reads `Bridge 123ABC missing since 14:02: not found on the network
   (searched 15:05); check its power, or type its address in Bridge IP
   Address` (section 1.3's "away an hour" item).

**What it must never do.**
- Adopt a different bridge id, even one that names the stored id in
  `replacesbridgeid`: a swap stays a click (2.4;
  `docs/simplify-research-comparables.md` R5).
- Send `POST /api` or open the pairing window by itself.
- Present the key before the new address has passed the identity and TLS
  checks.
- Overwrite an address the installer typed (T3 above).
- Sweep beyond the caps of 2.3, or while the bridge answers.
- Forget the last good address: it is persisted beside `hue_bridge_ip`
  (`bridge/credentials.lua`), together with the last sweep time.

| Lifecycle case | What the driver sees | Decision |
| --- | --- | --- |
| DHCP gives the bridge a new address | T1; mDNS or the sweep finds the id | **automatic** rewrite, said in Last Action and Attention |
| The bridge reboots for a firmware update, or a power cut | unreachable for minutes | nothing for 5 minutes; then a search that finds the old address again, or finds nothing (harmless) |
| The bridge is unplugged for days | nothing found | Attention after an hour; sweeps hourly, then every 6 hours (O2) |
| Two bridges swap addresses | T3: the last good address reports the other id | **automatic** search for the stored id; the other id is never taken |
| A new router renumbers the LAN | the controller's address changes too | the sweep covers the controller's new /24; mDNS finds it anyway |
| The bridge on another VLAN than the controller | mDNS does not cross it; the old /24 is swept | found only inside the old /24; otherwise Attention and the typed address |
| The bridge replaced by a Hue app transfer (new id) | T3, or nothing; Bridges Found shows `replaces the paired bridge` | **offered** (one pick); never automatic |
| The bridge factory-reset (same id, key gone) | same address, key rejected | not discovery: the key re-check of D8 |
| Hue emulator advertising `_hue._tcp` | answer fails stage B (no Signify chain) | ignored, logged under Debug Mode |
| The mDNS A record is stale | the candidate fails `pairing.probe` | the sweep runs |
| The installer types a wrong address | the typed address never verifies | **offered**: Attention and the `(paired)` item |
| Typed address while a search runs | the address generation changes (`driver.lua:1218`) | the search's late result is ignored, as today's checks do |
| Forget Pairing | no key, no stored id | the first-load search of 2.4; no window opens |
| Composer backup restored on a new controller | new controller address; the store may or may not survive (`docs/simplify-research-composer.md` §C) | as a new router if paired; as first load if not |
| Multicast filtered (IGMP snooping, mesh Wi-Fi) | mDNS silent, SSDP control silent | the sweep |

### 2.6 Budget, observability, build cost

- **mDNS.** One datagram per search, at 5 minutes, then backing off to 30
  minutes while the bridge is missing (at most 288 a day at the start
  cadence; `docs/simplify-research-maintenance.md` §2.5 has 288 too).
- **Sweep.** At most 254, or 508 with the second /24, TCP connects an
  hour, only while the bridge is missing. These are not Hue requests, so
  they are outside the housekeeping engine's 60 optional requests an hour
  (section 1.3). The engine still runs it as one job, one at a time and
  never while a command queue is busy.
- **Visible.** Every search writes one Last Action line, and Debug Mode
  logs each answer and candidate. Stopping it: D4 removed the switch, so
  the remedy is to reserve the bridge's address in the router. With a
  stable address the job never triggers.

| Module | Lines (estimate) | Spec |
| --- | --- | --- |
| `bridge/mdns.lua`: query builder, parser for PTR, SRV, TXT and A with name compression | 200 | recorded packets from probe P2, with placeholders |
| `bridge/sweep.lua`: stage A with a fake TCP client | 150 | fake clock, absent, refusing and accepting hosts |
| `bridge/discovery.lua`: first-load list, search for an id, candidates through `pairing.probe`, caps and persisted times | 200 | the table of 2.5 as cases |
| `driver.lua` and `driver.xml`: the row, the triggers, adoption | 150 | in `drivers_spec.lua`-style integration specs |

## 3. Test plan for the D9 dev build (question 6)

The D9 dev build already goes on the house for picker folders and the bulb
re-add of D7. Discovery adds one signed development command, **Probe
Discovery**, in `bridge/devtools.lua`. Signed commands are kept out of
Composer's actions and run only through the dev loop (`docs/dev-loop.md`,
"Signed commands"). It wraps the two network globals for bindings 6004 to
6006 only and passes everything else through. The probes need no Composer
click once the dev build is installed. The core of P2, about a dozen
lines:

```lua
local B = 6004 -- never used in the project before (netcheck.lua:14-27)
local QUERY = string.char(0x4c, 0x7e, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
	.. "\4_hue\4_tcp\5local\0" .. string.char(0, 12, 0, 1) -- PTR, IN; id 0x4c7e
probes[B] = {
	status = function(_, status)
		log.always("mdns: %s", status)
		if status == "ONLINE" then t0 = C4:GetTime(); C4:SendToNetwork(B, 5353, QUERY) end
	end,
	data = function(_, data, ...)
		log.always("mdns: %d bytes after %d ms, %d args, from %s, id %s, model %s", #data,
			C4:GetTime() - t0, 3 + select("#", ...), tostring((...)),
			tostring(data:match("bridgeid=(%x+)")), tostring(data:match("modelid=(%w+)")))
	end,
}
C4:CreateNetworkConnection(B, "224.0.0.251")
C4:NetConnect(B, 5353, "UDP")
```

| Probe | Mode | What it does | What it settles |
| --- | --- | --- | --- |
| P0 | `env` | logs `GetControllerNetworkAddress()`, `PortInUse(5353)` and the Director version | the /24 the sweep would take; whether 5353 is free |
| P1 | `ssdp` | the Snap One pattern on 6005: one `M-SEARCH` with `ST: ssdp:all` to `239.255.255.250:1900`; 5 s; counts answers, notes any `hue-bridgeid` header | whether **any** unicast reply to a multicast query reaches a driver on OS 3.4.2 (the control); whether the Bridge Pro still answers SSDP (a fact only) |
| P2 | `mdns` | the code above, a legacy unicast query from an ephemeral port; 3 s | whether the bridge honours §6.7; whether the answer carries the TXT and the A record; whether a fourth `from` argument arrives on 3.4.2 |
| P3 | `mdns5353` | only if P0 says 5353 is free: 6006 with `MIRROR_UDP_PORT = true` and the QU bit set | the variant for a responder without §6.7 |
| P4 | `multicast` | 6004's query on a connection of type `"MULTICAST"` (a new id, 6007) | what the undocumented type does |
| P5 | `sweep` | stage A over the controller's /24 (4 in flight, 1.5 s), then stage B on every host that accepted; logs duration, the count with 443 open, and which reported the paired id | the real duration and the number of 443 hosts; that `C4:CreateTCPClient` works on 3.4.2 |
| P6 | `mdns` again | P2 after `devctl.py reload` (the same id in a new run) | that a fixed id survives a reload, as 6001 does |

Run from the VM (P0 to P4 take about 15 s; P5 under 100 s):

```sh
tools/devctl.py wait $(tools/devctl.py run "Probe Discovery" Mode=all) --timeout 150
tools/devctl.py log | grep -E "mdns|ssdp|sweep|env"
tools/devctl.py wait $(tools/devctl.py reload) && tools/devctl.py wait $(tools/devctl.py run "Probe Discovery" Mode=mdns)
```

| Result | Decision |
| --- | --- |
| P2 answers with `bridgeid` and an A record | build `mdns.lua` on the legacy query; the sweep stays the second stage |
| P2 silent, P1 answers, P3 answers | build on P3's variant (the 5353 source port, the QU bit) |
| P1 silent too | replies to multicast queries do not reach a driver on 3.4.2: no mDNS; the sweep alone (D5's own fallback) |
| `from` present on 3.4.2 | use it beside the A record, as on 4.x |
| P5 slower than 2 minutes, or Director sluggish | 2 in flight, and the hourly cap becomes 3-hourly |

The Windows Composer session does four things (`docs/composer-remote.md`).
The standing approval covers the install; say so in the brief.
1. Update the bridge driver in place to the dev build (Driver ▸ "Add or
   Update Driver or Agent…"); `<capabilities>` unchanged, so no reboot.
   Read back `Driver Version` and `Debug Mode`.
2. Optional, if the build carries the Bridges Found row: screenshot its
   open drop-down (no item clipped at 75 characters), pick the `(paired)`
   item, click **Set** (`docs/composer-remote.md:97`), read Last Action
   (`Already paired with this bridge`). The VM can simulate the pick with
   `tools/devctl.py set "Bridges Found" "<item>"` (`docs/dev-loop.md`).
3. Nothing for P0 to P6.
4. At the end, install the release build again (CLAUDE.md "Deploy"), which
   ends the dev loop. Record it with `tools/deploy.py record --no-manifest`.
   Never put the dev log's addresses or bridge id in a report: use the
   placeholders.

## 4. Verdicts (question 7)

| Item | Verdict | Reason |
| --- | --- | --- |
| Entering Bridge IP Address | **KEEP** | It is the installer's field and the only path when nothing local answers. The driver writes it only for the paired id (2.5) or on a Bridges Found pick, and never over a typed address that did not verify. |
| Pair Bridge | **KEEP** (one click, a 2-minute window, also opened by a Bridges Found pick or an address entered on an unpaired driver) | Pairing needs a person at the link button. Discovery alone never opens the window, so a button press meant for another app cannot hand Control4 a key. |
| Forget Pairing | **KEEP** (with the confirmation of section 1.2) | It stays the one way to move to another bridge id, which discovery never adopts. After it, the first-load search lists the bridges again. |
| Bridges Found (new row) | **OFFERED** | The driver searches at first load, on Search again, and while the paired bridge is missing, and lists what answered with model, name, address and id. One pick and Set chooses, with the replacement bridge marked. |
| Finding the paired bridge at a new address (new job) | **AUTOMATIC** | Trigger: the last good address unreachable for 5 minutes, a failed outage check, or another id at that address. Guards: the stored id only, never in the first 5 minutes, mDNS first, the sweep at most hourly. Last Action says what moved. |
| Search every address (row item at setup) | **OFFERED** | A sweep with no known id belongs to the installer's click, never to a timer. |

## 5. Risks and open questions for the owner

Each question has a recommended answer, so one word decides it.

- **O1. If mDNS works on the house, should the sweep still ship as the
  second stage?** Multicast can be filtered on other networks, and an mDNS
  A record can be stale. **Recommended: yes**, only after mDNS found
  nothing.
- **O2. How often should the sweep run for a bridge that stays missing?**
  **Recommended:** hourly for the first 6 hours, then every 6 hours.
  Seeing the bridge again, a typed address or Forget Pairing resets it.
- **O3. Should the sweep be offered at setup only as a row item, never
  run by itself?** **Recommended: yes** (section 4).
- **O4. When exactly one bridge is found, should the driver fill the
  address by itself?** **Recommended: no.** The installer picks it, as D5
  says ("let you set the one you want"). The summary says which bridge
  was found.
- **O5. When the installer typed a wrong address and the paired bridge
  answers elsewhere, should the driver offer the fix rather than rewrite
  the address?** **Recommended: offer** (principle 1).
- **O6. Should the manual tell installers that the driver may try port
  443 on the controller's subnet while the bridge is missing, and that
  reserving the bridge's address avoids it?** **Recommended: yes**, which
  answers the risk of an intrusion-detection alarm.
- **O7. Is the identity without a CN comparison enough** (the Signify
  chain, the id in `/api/0/config` and the decoy check)? It is today's
  pairing standard, and DriverWorks offers nothing stronger.
  **Recommended: yes.**
- **O8. Should ids 6004 to 6009 be reserved for discovery, named in
  `netcheck.lua`'s header?** **Recommended: yes**, so no later probe takes
  them.

Other risks: Director may drop replies whose source is not the
connection's address (P1, P2; the sweep covers it); 5353 may be held on the
controller (P0); `C4:CreateTCPClient` has never run in this project (P5);
with several controllers `GetControllerNetworkAddress` is the master's,
hence the last good address's /24 first; a Bridge Pro firmware update may
change its responder, which the sweep does not depend on.
