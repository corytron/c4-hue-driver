# Security review 2026-11-13, reviewer N: network trust (#480)

Read-only review of the bridge driver's network surface against
[`../security-review-design.md`](../security-review-design.md). Read whole:
`bridge/http.lua`, `stream.lua`, `netstream.lua`, `sse.lua`, `tlscheck.lua`,
`netgate.lua`, `netcheck.lua`, `altaddr.lua`, `mdns.lua`, `discovery.lua`,
`bridges_found.lua`, `pairing.lua`, `pair_window.lua`, `credentials.lua`,
`identity.lua`, `config.lua`, the parsing parts of `hue_model.lua`, and the
parts of `hue_bridge/driver.lua` that wire them (the gates, the stream, the
address handler, pairing, Test Connection, the key lock and re-check, Forget
Pairing, the network callbacks). Read for context: `away.lua`, `tasks.lua`,
`housekeeping.lua` (scheduling only), `sweep.lua`, `commands.lua` (rate
only). Dev-only `conntest.lua`, `pinning.lua`, `probe12.lua`: their release
exclusion only.

Run: the network-area specs (`http`, `sse`, `stream`, `netstream`,
`tlscheck`, `identity`, `netcheck`, `netgate`, `mdns`, `discovery`,
`pairing`, `pair_window`, `altaddr`, `config`, `hue_model`: 541 successes,
0 failures) and six scratch Lua 5.1 probes against the modules, kept outside
the repository. Nothing was sent to the bridge, the controller or any LAN
host. Timings are CPU seconds on the review VM (x86); a controller is slower
[assumed].

SDK citations: "API x/_y" is
`~/c4-tools/reference/docs-driverworks-api/source/includes/x/_y-*.md`.

## Summary

| Id | Rating | Title |
|---|---|---|
| N-1 | Low | The event-stream per-event cap is bypassed by empty `data` lines: memory grows without bound |
| N-2 | Low | The network-connection HTTP head parser is quadratic: one 1 MB answer head stalls the driver for hours |
| N-3 | Low | mDNS answers are taken with any query id and any address: a LAN host can crowd out the paired bridge and steer TLS connects to hosts of its choosing, internet included |
| N-4 | Low | Unkeyed answers (identity check, discovery, pairing) are unbounded: a quadratic trim in Bridges Found, and a foreign bridge's rows written before its id is compared |
| N-5 | Low | The automatic address follow-up (#334) lets a host holding any Signify certificate and its key collect the application key without taking the bridge's address |
| N-6 | Info | A 401/403 on the stream locks the key without re-checking identity; the lock's re-check sends the key without one either |
| N-7 | Info | The stream's backoff resets on every 200: a peer that answers 200 and closes gets a keyed reconnect every second, and neither the resync nor the identity re-check ever runs |
| N-8 | Info | No cap on this driver's concurrent C4:url transfers: with an unresponsive peer a command burst can hold all of Director's transfer slots |
| N-9 | Info | A key request in flight when the pairing window closes still pairs: `pairing.lua` stores the key before the window's own checks |

No Critical, High or Medium finding. Answers to the six questions of the
brief, in short:

1. **Certificates.** Every HTTPS request and both stream transports verify
   the peer against the two Signify roots shipped in the package; hostname
   verification is off and cannot be replaced, since no API exposes the peer
   certificate or a peer-name option (below, "Residual risks"). The bridge
   id is enforced at the application layer, unkeyed, before the first keyed
   request of every start and address, after a stream outage of 60 s, and
   for every address the follow-up may adopt; not per connection. A LAN
   host that wins discovery or takes the address needs a Signify-issued
   certificate *and its private key* (a rooted Hue bridge) to obtain the key
   or feed false state; with a stock Hue bridge it gets neither (its id
   differs), only a misleading "key rejected" (N-6). Discovery widens the
   rooted-bridge path (N-5).
2. **Key handling.** The key goes only into the `hue-application-key`
   header (C4:url) or the request text of the network-connection stream; it
   is stored encrypted, never logged at any level, never in a property,
   never in a URL; send errors are redacted. It goes only to the paired
   address after the identity and TLS checks, with the point-in-time limits
   of N-5 to N-7.
3. **Pairing.** No path pairs without a person: Pair Bridge, a Bridges Found
   pick or an address typed into a never-paired driver. The window accepts,
   for 120 s, any Hue bridge (model `BSB*`, CLIP v2 firmware) at the typed
   address whose link button is pressed; the picked id after a pick; the
   stored id while one is stored. N-9 is the one ordering gap.
4. **Untrusted input.** The mDNS parser is tightly bounded. The SSE parser's
   per-event cap leaks (N-1), the network-connection head parser and the
   Bridges Found label are quadratic (N-2, N-4), C4:url bodies and JSON
   nesting have no cap of the driver's own (N-4). Every event is delivered
   under `pcall`; no error found escapes to Director other than through
   memory exhaustion or a stall.
5. **Resource exhaustion.** Timers are generation-gated or cancelled on
   reset and destroy; the C4:url stream cap and the probe-binding removal
   hold. Open: the 1 s reconnect loop (N-7) and the transfer-slot use (N-8).
6. **Failing closed.** A TLS failure, an id mismatch, an unsupported model,
   a `not_pinned` verdict, an inconclusive verdict on an unproven OS, and a
   401/403 all stop keyed traffic. An unexpected status on the stream
   reconnects with backoff, which is right for a verified peer.

## Findings

### N-1 Low: the event-stream per-event cap is bypassed by empty `data` lines

- **Attacker:** the TLS peer of the event stream at the bridge's address:
  the paired bridge (a firmware fault) or a host with a Signify-issued
  certificate and its key that passed the identity check. Nothing that
  merely writes into the bridge (names, scenes) can produce such lines: the
  bridge writes each event's JSON on one line [assumed].
- **Impact:** controller memory. `sse:line` adds `#value` to `data_bytes`
  per `data` line, so a `data:` (or bare `data`) line with an empty value
  adds 0 bytes to the count and one more entry to `self.data`. Nothing bounds
  the number of entries until a blank line arrives. A scratch run fed 30 MB
  of `data:\n` lines: 5,000,000 entries held, `data_bytes` 0, never
  `overflowed`, the Lua heap 128 MB larger (about 4.3 bytes kept per byte
  sent). At LAN speed that is enough to exhaust the Lua state or Director
  within seconds [assumed: the controller's memory limits are not
  documented]. The blank line then dispatches a 5 MB string to
  `C4:JsonDecode`, five times the 1 MB cap. Both transports share the parser.
  This is the remaining half of 2026-10-24 finding 2.
- **Where:** `src/hue_bridge/bridge/sse.lua`, `sse:line`, lines 63-72 (the
  count), `sse:dispatch` 36-48 (the join); fed from `stream.lua`
  `stream:handle_chunk` (474) and `netstream.lua` `netstream:handle_body`
  (920).
- **Confidence:** [verified: scratch run against `bridge/sse.lua`].
- **Fix:** count `#value + 1` per data line (the newline `table.concat`
  adds), so `data_bytes` bounds the dispatched string exactly, and treat
  passing `MAX_EVENT` as today. Optionally cap containers per event before
  the fan-out. One spec: 2 MB of `data:` lines set `overflowed` and dispatch
  nothing.

### N-2 Low: the network-connection HTTP head parser is quadratic

- **Attacker:** as N-1, on the network-connection stream (the default
  transport, `driver.xml` lines 267-273). The head is parsed only after a
  handshake verified against the Signify roots.
- **Impact:** a stall of the bridge driver's Lua inside
  `ReceivedFromNetwork`, and of whatever else Director runs on that thread
  [assumed: Director's Lua threading is not documented]. Two quadratic
  paths, both within the 1 MB head limit:
  - `trim` (`gsub("%s+$", "")`) on a header value with a long run of
    interior blanks: 16,000 blanks 0.96 s, 32,000 3.91 s, 64,000 15.49 s; a
    1 MB head of blanks extrapolates to about an hour on the VM.
  - A repeated header name concatenates onto the growing value (`before ..
    ", " .. value`), and so does an obsolete folded line: 100,000 `a:x`
    lines 1.74 s; the 250,000 that fit in 1 MB about 11 s.
  `util.display_name` already documents and avoids exactly this `%s+$`
  pattern. The connect timer cannot interrupt a callback that is still
  running, and every reconnect can repeat it.
- **Where:** `src/hue_bridge/bridge/netstream.lua`, `trim` line 224,
  `reader:line` lines 290-304 (the fold at 293, the repeat at 302).
- **Confidence:** [verified: scratch run against `bridge/netstream.lua` with
  a stub C4].
- **Fix:** keep only the two headers the reader uses (`transfer-encoding`,
  `content-length`) and skip every other line without trimming or joining;
  trim with a linear scan (`find("%S")`, then a byte loop from the end, as
  `util.display_name` does); cap the head well below 1 MB (16 KB, and a
  head line at 8 KB: the bridge's head is a few hundred bytes [assumed]).
  One spec with a 1 MB head of blanks and of repeated names, finishing in
  well under a second.

### N-3 Low: mDNS answers are taken with any query id and any address

- **Attacker:** any host on the LAN, no certificate needed. It sees the
  driver's multicast query (and its source port) and answers, or floods
  that port during the 3 s window.
- **Impact:** availability of discovery, and outbound connections chosen
  by the attacker. `D:_take` accepts an answer whose id differs from the
  query's ("taken all the same"), and `mdns.candidates` keeps every A record
  except 0/8, 127/8 and 224/3 and up. A scratch run parsed one spoofed
  821-byte answer naming the paired id (placeholder 001788fffe123abc) with a
  wrong query id into one instance with 40 candidate addresses, public
  ranges included. Consequences:
  - `find_paired` checks the answers that name the paired id first, one at
    a time, within `IDENTITY_CAP_MS` (45 s); a blackholed address costs the
    5 s connect timeout and a tarpit up to 15 s, so 3 to 9 bogus addresses
    exhaust the stage, and only the first `MAX_ANSWERS` (32) datagrams of a
    window are parsed at all. A flood therefore keeps the paired bridge's
    own answer out, and the follow-up after an address change waits for the
    hourly sweep. Bridges Found can be emptied the same way.
  - Each candidate gets the identity check: a TCP connect and TLS
    ClientHello from the controller to an address the attacker chose, on
    the internet too. The sweep refuses anything outside the private and
    documentation networks for that very reason (`sweep.searchable`), and
    the owner's rule is no internet reliance. TLS fails before any HTTP is
    sent, so nothing leaks beyond the connect.
- **Where:** `src/hue_bridge/bridge/discovery.lua`, `D:_take` lines 468-500
  (476: the id), `D:received` 502-523 (514: the 32-answer cap),
  `D:find_paired` 965 on, `D:_check_each` 586; `src/hue_bridge/bridge/mdns.lua`,
  `host_address` 267, `mdns.candidates` 273.
- **Confidence:** [verified: scratch run of `mdns.read` with the specs'
  packet builder; the discovery flow by reading].
- **Fix:** drop answers whose id differs from the query's (a legacy unicast
  answer repeats it: verified on the house's Bridge Pro per the `mdns.lua`
  header; the v2 bridge [assumed]); filter candidate addresses with
  `sweep.searchable`; on OS 4.x, where `ReceivedFromNetwork` names the
  sender (API 32_serial_network_device/_15-ReceivedFromNetwork), keep only
  the sender's own address; count `MAX_ANSWERS` per sender and cap
  addresses per datagram (4 is plenty for one bridge).

### N-4 Low: unkeyed answers are unbounded

- **Attacker:** any host that completes a TLS handshake verified against the
  Signify roots and answers `/api/0/config`. For the identity check that is
  the host at the bridge's address. For discovery (first-load searches,
  Search again, the follow-up) it is any such host anywhere on the LAN that
  answered mDNS or accepted port 443. A stock Hue bridge answers with its
  own firmware's bounded values (names of at most 32 characters [assumed]),
  so the stall needs a rooted bridge.
- **Impact:**
  - `discovery.item_label` trims the bridge's `name` with
    `gsub("^%s+", ""):gsub("%s+$", "")` before cutting it to 20 characters.
    The same quadratic pattern as N-2, measured: 16,000 interior blanks
    0.97 s, 32,000 3.91 s. C4:url aggregates a response body with no size
    limit of its own (no such option in API 35_url/_12-SetOption), so the
    name can be megabytes long.
  - `identity:verify` calls `show_bridge_info` for any answer with a valid
    id *before* comparing that id with the paired one. A different bridge at
    the address therefore rewrites `Bridge Model`, `Bridge Firmware` and
    (sanitised) `Bridge Name`; model and firmware are shown raw and
    unbounded (`config.model_label`, `config.firmware_label`).
  - Peer text reaches Status and the log raw and unbounded: the pairing
    error description ("Pairing failed: bridge error N: <description>"),
    and an event's SSE id in the `undecodable event` warning (an id line can
    be 1 MB). `common/log.lua` neither cuts nor strips control characters.
  - No body-size check before `C4:JsonDecode`, and the decoder's depth or
    size limits are not documented (API 12_json/_3-JsonDecode); deep nesting
    is the decoder's problem, out of scope, but the driver could refuse it.
- **Where:** `src/hue_bridge/bridge/discovery.lua`, `discovery.item_label`
  line 1154 (the trim in its body); `src/hue_bridge/bridge/identity.lua`,
  `identity:verify` lines 186-199 (before the comparison at 200);
  `src/hue_bridge/driver.lua`, `show_bridge_info` 988-1000;
  `src/hue_bridge/bridge/pairing.lua`, `pairing.parse_response` 86;
  `src/hue_bridge/bridge/stream.lua` and `netstream.lua`, `handle_event`
  (the warning); `src/hue_bridge/bridge/http.lua`, `http.decode` 133.
- **Confidence:** [verified: scratch run of `discovery.item_label`; the
  rest by reading].
- **Fix:** pass every string from an unkeyed answer through
  `util.display_name` (bounded, linear) or a 64-character cut before it is
  used. In `item_label`, replace the two gsubs with `util.display_name`.
  Call `show_bridge_info` only once the id matched. Cut peer text in Status
  and log lines to about 100 characters with control characters removed.
  Refuse REST bodies over a few MB before decoding (the largest real answer
  is the 351 KB scene catalogue, `driver.lua` on_connected).

### N-5 Low: the automatic address follow-up lets a rooted bridge collect the key without taking the address

- **Attacker:** a LAN host holding a Signify-issued bridge certificate *and
  its private key*, for example a Hue bridge rooted by its owner [assumed:
  the key is extractable from a rooted bridge]. It also needs the paired id,
  which is public (mDNS TXT, `/api/0/config`, the certificate's CN).
- **Impact:** the application key, and with it every Hue light. The
  identity of the bridge rests on the id that `/api/0/config` reports
  through any Signify-verified handshake. Earlier reviews accepted that a
  rooted bridge defeats it by *taking the bridge's address* (ARP or DHCP).
  The follow-up of #334 removes that step:
  - once the paired bridge has not answered at its last good address for
    300 s (`away.FIND_AFTER_S`), or another bridge answers there, the
    `find_bridge` task asks mDNS;
  - the attacker answers with the paired id and its own address. That
    address passes discovery's identity check and then the driver's own:
    the decoy CA check reads `pinned`, because the attacker's chain does
    not verify against the decoy either;
  - `Bridge IP Address` moves there and keyed requests follow. A power
    cut, a router reboot or a long bridge update is enough; no packet of
    the real bridge's needs touching.
- **Where:** `src/hue_bridge/bridge/tasks.lua`, the `find_bridge` task
  (from 199); `src/hue_bridge/bridge/away.lua`, `away:unreachable` and
  `away:other_bridge` (207-240); `src/hue_bridge/bridge/discovery.lua`,
  `D:find_paired` 965; `src/hue_bridge/bridge/identity.lua`,
  `identity:verify`.
- **Confidence:** [verified: read]; rooting [assumed].
- **Fix:** none on the driver's side short of a certificate-name check,
  which no API offers (see "Residual risks"). Options for the owner
  (decision D5): record the widening in the residual-risk list; or let the
  follow-up move automatically only to an address the key has worked at
  before (a short persisted history), and only offer (Attention, one click)
  an address never seen.

### N-6 Info: a stream 401/403 locks without re-checking identity

- **Attacker:** a LAN host that can take the bridge's address for a moment
  (ARP, DHCP) with a stock Hue bridge, or just another bridge given the
  address by DHCP.
- **Impact:** the next stream connect presents the key to that bridge
  (which cannot read it out) and gets 403. `key_rejected` locks keyed
  traffic at once, with Status "Key rejected by the bridge (HTTP 403) ...
  re-pair with Pair Bridge", while the cause is another device.
  `identity_ok` stays true, so the `key_recheck` task (guards `paired`,
  `identity_ok`, `not_pairing`) sends the key to the address again 5 min,
  15 min, 1 h and then hourly without a fresh identity check. The stream
  is stopped, so `away:outage_check` returns early and never re-runs the
  check either. Pair Bridge itself refuses the other id, so nothing is lost
  but time and a misleading Status. The key goes nowhere a rooted bridge
  could not get it anyway (N-5).
- **Where:** `src/hue_bridge/driver.lua`, `key_rejected` 350-371, the
  stream's `on_key_rejected` 925-927, `recheck_key` 1283-1308;
  `src/hue_bridge/bridge/tasks.lua`, `key_recheck` 184-195;
  `src/hue_bridge/bridge/away.lua`, `away:outage_check` 355-361.
- **Confidence:** [verified: read].
- **Fix:** on a stream 401/403, run the unkeyed identity check first (cheap,
  no key) and lock only when it passes; on a mismatch show the other-bridge
  text. Let `recheck_key` run the identity check before its keyed GET.

### N-7 Info: the stream's backoff resets on every 200

- **Attacker:** a peer that passed TLS at the address and answers the stream
  with 200 and then ends it (`Content-Length: 0`, a close). A bridge firmware
  fault does the same.
- **Impact:**
  - **Reconnect loop.** `connected()` and `stream:handle_headers` reset the
    backoff to 1 s on every 200, unless the last connection overflowed. A
    scratch run against `netstream.lua` showed eight reconnects in a row,
    each 1,000 ms after the last, each sending the request with the key:
    one TLS handshake, keyed request, info log line and property write a
    second, for ever.
  - **No resync.** Each connect pokes the resync task, whose 2 s debounce
    moves with every poke (`housekeeping.lua`, "a trigger while it waits
    moves its debounce"), so with connects about a second apart the resync
    never runs.
  - **No identity re-check.** Each 200 counts as "Connected since", which
    cancels the 60 s outage check (`away:stream_status`), so the identity
    is never checked again while the loop lasts.
- **Where:** `src/hue_bridge/bridge/netstream.lua`, `netstream:connected`
  848-857, `netstream:fail` 996; `src/hue_bridge/bridge/stream.lua`,
  `stream:handle_headers` 383-399, `stream:handle_done` 606;
  `src/hue_bridge/bridge/away.lua`, `away:stream_status` 251-270.
- **Confidence:** [verified: scratch run against `bridge/netstream.lua`;
  `stream.lua`, the debounce and the outage check by reading].
- **Fix:** reset the backoff only after a connection delivered an event or
  a keepalive, or stayed up for 30 s, extending the existing
  `hold_backoff`; treat a run of short connections as an outage, so the
  identity check runs.

### N-8 Info: no cap on this driver's concurrent C4:url transfers

- **Attacker:** none needed (a bridge that stops answering), or a LAN host
  that blackholes or tarpits the bridge's address.
- **Impact:** Director runs at most four C4:url transfers at once across all
  hosts [verified: hardware, `docs/design.md` "Concurrent transfers"];
  `netstream.lua`'s header says controller-wide, across drivers [assumed].
  The light queue sends a burst of up to 10 PUTs (`commands.BURST`, one in
  flight per light), beside the group queue, the resync chain and the
  identity check. Against an unresponsive peer each transfer holds a slot
  for the 5 s connect timeout, or up to 15 s once connected
  (`http.DEFAULT_TIMEOUT`). One scene recall can therefore delay every
  other driver's C4:url traffic, until the outage check stops keyed
  requests about 60 to 70 s after the stream drops. The C4:url stream's
  cap keeps "two left for commands", but nothing caps the commands
  themselves.
- **Where:** `src/hue_bridge/bridge/http.lua`, `http.request` 186;
  `src/hue_bridge/bridge/commands.lua` `BURST` 65;
  `src/hue_bridge/driver.lua`, `bridge_request` 397.
- **Confidence:** [verified: read]; that the limit spans drivers [assumed].
- **Fix:** cap this driver's concurrent C4:url transfers (two, with a FIFO
  in `http.request` or `bridge_request`), so a slow bridge costs only its
  own commands.

### N-9 Info: a key request in flight when the window closes still pairs

- **Attacker:** none; an ordering gap. It matters when Forget Pairing (or an
  address change) runs while a key request is in flight and the link button
  has been pressed.
- **Impact:** `pairing.pair` stores the new key, bridge id and address
  (`credentials.save`, line 182) before it calls `on_paired`. The window's
  `on_paired` then neither checks that the window is still open nor undoes
  the store:
  - **Forget Pairing.** It closes the window, but the request still in
    flight completes, stores the pairing and re-pairs the driver at once.
  - **Address change.** The result is ignored in memory (`stale()`) but
    already stored, so a later restart loads a pairing the driver had
    discarded. The identity check keeps that one from sending anything to
    another bridge.
- **Where:** `src/hue_bridge/bridge/pairing.lua`, `pairing.pair` 175-184;
  `src/hue_bridge/bridge/pair_window.lua`, `on_paired` 101-105.
- **Confidence:** [verified: read].
- **Fix:** move `credentials.save` to the driver's `on_paired`, after the
  stale check; have `pair_window` drop a result once `pair_until` is nil.

## Earlier fixes rechecked

| Earlier finding | Status now | Where |
|---|---|---|
| 2026-10-24 #1: identity checked, unkeyed, before any keyed request | **Holds.** Every keyed send is gated. `bridge_request` (`driver.lua` 397-413) and `choose_stream_address` (1034-1101) check the refusals and `identity_ok`. So does the stream's `stream_connection` (302-330), the last guard for both transports; the network connection also needs `net_cleared`. `test_connection` (1311-1328), `confirm_key_rejected` (377-384) and `recheck_key` (through the task guard `identity_ok`) are gated too. Still a point-in-time check: see N-5 to N-7 and "Residual risks". | `driver.lua`, `identity.lua` |
| 2026-10-24 #2: one event's data capped at 1 MB | **Partly.** The 1 MB line cap and the byte count hold; empty `data` lines bypass the count (N-1). | `sse.lua` 63-72, 101-106 |
| 2026-10-24 #3: no caller-supplied TLS table on keyed requests | **Holds.** `bridge_request` clears `req.tls` (413). The other keyed calls build literal tables without one. Only `tlscheck.run` passes `tls`, unkeyed. `http.options` keeps `ssl_verify_peer` true unless `tls` sets it. | `driver.lua` 413, `http.lua` 48-67 |
| 2026-10-24 #5: resource ids validated | **Holds** in every constructor (`hue_model.resource_id`, `item_id`). `owner.rid` and `services[].rid` are not validated but serve only as table keys. The one path built from `device_rid`, the device rename, is used only when it names a device of the validated table. `http.url` keeps the host fixed in any case. | `hue_model.lua` 90-117, `lights.lua` 1733-1735 |
| 2026-10-24 #8: a 401/403 on the stream stops it | **Holds** for both transports; see N-6 for the lock's edges. | `stream.lua` `key_rejected`, `netstream.lua` 879-890 |
| 2026-10-24 #12: release stage refuses dev modules | **Holds**, now with `conntest.lua`, `pinning.lua` and `probe12.lua` removed and asserted. The artefact itself is reviewer I's. | `tools/build.sh` 152-158 |
| 2026-10-24 "found sound": key encrypted at rest, never logged | **Holds.** It is stored with the encrypted flag, and `credentials.summary` gives its length only. `http.lua` logs URL and body, never headers. `netstream.lua` logs the request's byte count only and redacts a send error. | `credentials.lua`, `http.lua` 206-208, `netstream.lua` 700-709, 752 |
| 2026-10-25 #1: Test Connection gated | **Holds.** It refuses `not paired` and `TLS check failed`, and runs the identity check first; the keyed GET goes only from its success. | `driver.lua` 1311-1328 |
| 2026-10-25 #2: `not_pinned` sticks | **Holds.** `tls_gate` answers false at once, and `keyed_refusal` refuses every keyed send. The network connection's `not_pinned` holds for the run and moves the stream to Web transfer, which has its own check. | `identity.lua` 121-123, `driver.lua` 190-201, 292-295, `netgate.lua` 94-98 |
| 2026-10-25 #3: inconclusive blocks on an unproven OS | **Holds** for C4:url, and the same rule now covers the network connection. Its documented limit (b) is under "Residual risks". | `identity.lua` 144-153, `tlscheck.lua` `pinned_before`, `netgate.lua` 99-114, `netcheck.lua` `pinned_before` |
| 2026-10-25 #4: a REST 401/403 is confirmed before the lock | **Holds**: one keyed GET of the bridge resource, one at a time, ignored after an address or pairing change. Test Connection and the new background re-check clear the lock. | `driver.lua` 377-395, 1268-1308 |
| 2026-10-25 #5: at most two C4:url stream transfers open | **Holds** (`connect` waits, every path that gives a transfer up counts it). Not applicable to the network connection, which has no abandoned transfers. | `stream.lua` `connect`, `wait_for_close`, `drop_transfer` |
| 2026-10-25 #6: events delivered under `pcall`, non-tables skipped, decode never raises | **Holds** in both transports and in the driver's fan-out. | `stream.lua` `deliver_each`, `handle_event`; `netstream.lua` 897-991; `http.lua` 133-145; `driver.lua` `on_container` |
| 2026-10-25 #7: keyed requests refuse redirects | **Holds.** `OnHeaders` aborts a 3xx and the result says so; both streams abort on any status but 200. Unkeyed requests still follow redirects (by design; only a peer that passed TLS can send one). | `http.lua` 226-245, `stream.lua` 383-388, `netstream.lua` 833-836 |
| 2026-10-25 #10: a path must start with `/` | **Holds.** `http.url` raises; `http.request` and `http.stream` turn that into a failure. | `http.lua` 101-110, 188-192, 308-312 |
| 2026-10-25 residual: padded address spellings | **Unchanged**, and now only used with Web transfer; the default transport is the network connection (dotted address). | `driver.lua` 1034-1101, `altaddr.lua` |

## Residual risks (unchanged by design, restated)

- **No certificate-name check.** C4:url offers no peer-name option (API
  35_url/_12-SetOption), NetPortOptions none either (API
  32_serial_network_device/_25-NetPortOptions: verify mode none or peer
  only), the TCP client has no TLS at all (API 14_lua_tcp_client/_3-Connect,
  _11-Option), and the lua-openssl of OS 3.4.1 on has its `ssl` module and
  the socket methods of `bio` removed (API 13.5_openssl/_0-Header). So
  nothing can compare the certificate's CN with the paired id. Any holder of
  a Signify-issued bridge certificate and its key passes; N-5 is the newest
  path to that point.
- **Identity is a point in time:** per start, address and outage of 60 s,
  not per connection (N-6, N-7 sharpen it).
- **The network connection's TLS check** cannot tell "pinned" from a decoy
  dropped by an active attacker. The first `pinned` of a Director version
  stands until the next update. Documented in `netcheck.lua` (b), and
  relevant only on an OS that ignores `CACERTFILE` or `VERIFY_MODE`; OS
  3.4.3 honours both [verified: hardware, per `netcheck.lua`].
- **Padded spellings** (Web transfer only): the keyed self-check goes to a
  spelling the identity check never visited; on a resolver that read it as
  a name it would go to DNS [assumed: none does; OS 3.4.2 reads it as a
  number, verified on hardware].
- **Inter-driver trust:** any driver in the project can run Pair Bridge,
  Test Connection or Forget Pairing (reviewer C's area).

## Looked at, no finding

- `http.lua`: one TLS configuration (peer verified, bundle pinned), the key
  only in a header, keyed redirects refused, `OnDone` built under `pcall`,
  start errors turned into failures.
- `credentials.lua`: the key encrypted at rest, loaded once, never in a
  property; `summary` prints its length.
- `pairing.lua`: the key request goes out only after the unkeyed probe; a
  stored or picked id other than the probed one is refused first; model
  and firmware refused before the key request; the issued key must hold no
  white space or control character.
- `pair_window.lua`: 120 s, a request every 3 s, stale address results
  dropped (apart from N-9).
- `identity.lua`: unkeyed `/api/0/config`, an unreachable bridge retried
  every 30 s, a different id never retried, an unsupported model stops, the
  TLS gate inside, waiters dropped at an address change or Forget Pairing.
- `tlscheck.lua`: the decoy request carries no key or header; `pinned` needs
  curl 60 or 51 with no HTTP status, `not_pinned` a completed HTTP exchange;
  the memory is per Director version.
- `netgate.lua` and `netcheck.lua`: a fresh binding id per probe; the probe
  sends no key; the answer is kept to 1 KB; probe bindings closed, cleared
  and removed; a backoff of 30 s doubling to an hour; the id budget lasts
  (two ids per Director version).
- `netstream.lua`: the key goes out only on `ONLINE`, after `tls_checked()`
  and the driver's refusals; `header_safe` on address and key; chunked
  decoding bounded (8 hex digits, line cap); one object owns binding 6001;
  `retire()` on destroy.
- `stream.lua`: generation-gated timers and callbacks; the abandoned-transfer
  cap; an overflow aborts the transfer and keeps the backoff.
- `sse.lua`: linear walk, 1 MB line cap (N-1 aside); a small-chunk feed of
  an unterminated 1 MB line costs 1.3 s at 64-byte chunks on the VM, after
  which it overflows and the backoff doubles: acceptable.
- `altaddr.lua`: spellings built only from a `parse_ipv4`-validated dotted
  quad, only octets below 8 padded.
- `config.lua`: `parse_ipv4` refuses leading zeros and octets over 255;
  bridge ids must be 16 hex digits.
- `mdns.lua`: never raises; 9,000-byte packets, 64 records, 16 questions,
  backward pointers only with at most 16 jumps, 255-byte names, TXT strings
  kept inside their record (N-3 is about what discovery does with the
  result).
- `discovery.lua`: every candidate needs the pinned identity check, only the
  paired id is adopted, jobs and stages capped, everything cancelled on
  `stop()`; the sweep is limited to private and documentation /24s.
- `bridges_found.lua`: listing never pairs; a pick needs a click; while
  paired another bridge is refused.
- `hue_model.lua`: ids validated, numbers and points type-checked, no
  recursion, `base_name` linear.
- `driver.lua`: an address change resets identity, TLS verdict, key lock,
  stream spelling and probe; Forget Pairing stops the stream, clears the
  network binding's address and the stored key; the network callbacks are
  routed by binding id (probes 6100-6999, mDNS 6008, stream 6001).
- JSON from the bridge is decoded only through `http.decode`; the other
  `C4:JsonDecode` calls are in dev-only modules.
- `conntest.lua`, `pinning.lua`, `probe12.lua` (the only code with
  unverified or system-CA TLS options): dev builds only, removed and
  asserted absent by `tools/build.sh`.
