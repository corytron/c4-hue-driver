# Event stream over a raw SSL network connection

Design for moving `GET /eventstream/clip/v2` off `C4:url()` onto Director's
network-connection API, so `C4:url()` stays free for light commands. Follows
on from the spike result in `docs/design.md` ("Event stream"): while a
`C4:url` streaming transfer to the bridge is open, Director opens no second
connection to that host, so commands queue behind the stream and time out.

Status key as in `docs/design.md`: **[verified: file]** = read in the
DriverWorks docs or Control4's sample code; **[assumed]** = not confirmed,
to be tested on hardware. File abbreviations:

- `API/` = `~/c4-tools/reference/docs-driverworks-api/source/includes/`
- `FUND/` = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/`
- `COMMON/` = `~/c4-tools/drivers-common-public/`
- `SAMPLES/` = Control4's `docs-driverworks/sample_drivers/`

## 1. API choice

Three ways to hold a long-lived socket from a driver:

**A. Dynamic network connection**: `C4:CreateNetworkConnection(idBinding,
strAddress, strConnectionType)` + `C4:NetPortOptions(idBinding, nPort,
strIPType, tPortParams)` + `C4:NetConnect(idBinding, nPort)`, data through
`C4:SendToNetwork` and the `ReceivedFromNetwork` callback. "Defines a
dynamic Network Connection so no Connection XML is required"
**[verified: API/32_serial_network_device/_1-CreateNetworkConnection.md]**.
`strConnectionType` `"SSL"` selects TLS **[verified: same file, example;
SAMPLES/generic_tcp/driver.lua; COMMON/module/websocket.lua
`setupC4Connection`]**. `NetPortOptions` carries `CACERTFILE` and
`VERIFY_MODE` for peer verification **[verified: API/32.../_25-NetPortOptions.md]**.
Available since 1.6.0 / 2.8.0 (`NetPortOptions`), so fine for a 3.3.0
minimum **[verified]**.

**B. Static `<connection>` in driver.xml** with `<classname>SSL</classname>`
and `<port>` children `<cacert>`, `<verify_mode>`, `<method>`
**[verified: FUND/25_tls_ssl_driver_configurations/_1-TLSSSLDRIVERCONFIGURATION.md;
API/32.../_30-SampleSSLConnection.md]**. Same TLS features as A, but the
address is "identified" by the installer on Composer's Network tab
(`OnNetworkBindingChanged` reports it) **[verified: API/32.../_28-OnNetworkBindingChanged.md]**
and the port options are fixed at packaging time.

**C. `C4:CreateTCPClient()`**: a socket object with `Connect`, `OnRead`,
`ReadUntil`/`ReadUpTo`/`ReadAtLeast`, `Option("keepalive"|"nodelay"|"linger")`.
Every file in `API/14_lua_tcp_client/` was read; none mentions TLS, SSL,
certificates or verification. Its only options are the three socket
options above **[verified: API/14_lua_tcp_client/_11-Option.md]**. The
`CreateTLSServer` API (3.3.0) exists for the server side only
**[verified: API/3_whats_new/_13-WhatsNewin330.md]**. So C is plain TCP and
unusable for an HTTPS-only bridge.

**Recommendation: A.** It is the only one that gives TLS with a CA file
*and* lets the driver set the address from the `Bridge IP Address` property
(and move it with `C4:SetBindingAddress`) without a Composer step. It is
also what Control4's websocket module does for `wss://` **[verified:
COMMON/module/websocket.lua]**. B is the fallback if dynamic creation
misbehaves on hardware: the `tPortParams` keys map one-to-one onto the XML
`<port>` children **[verified: API/32.../_25-NetPortOptions.md]**.

Not considered further: the lua-openssl interface is 3.4.1+, above our
minimum OS **[verified: API/3_whats_new/_9-WhatsNewin341.md]**.

## 2. TLS details

Keys of `tPortParams` for `C4:NetPortOptions(6001, 443, "SSL", tPortParams)`,
all from **[verified: API/32.../_25-NetPortOptions.md]** unless marked:

| Key | Value | Why |
| --- | --- | --- |
| `CACERTFILE` | `"certs/hue_ca_bundle.pem"` | "Path to the CA certificate to use for the connection. The path is relative to the driver's C4Z location." The same bundle `bridge/http.lua` already ships. Doc examples write `'./root.pem'`; `C4:url`'s `ssl_cabundle` (also "relative to the .c4z") resolved `certs/hue_ca_bundle.pem` against `/opt/control4/var/drivers/c4z/hue_bridge/` on OS 3.4.2. Whether `CACERTFILE` is resolved by the same code is **[assumed]** (test 2). |
| `VERIFY_MODE` | `"peer"` | "Control4 currently supports only the peer verification mode (SSL VERIFY PEER). Values include: none and peer. If omitted, Director defaults to no verification." Without it the CA file is pointless. |
| `METHOD` | omitted | See below. |
| `CERTIFICATE`, `PRIVATE_KEY`, `PROTECTED` | omitted | Client-certificate authentication; the bridge authenticates us with the `hue-application-key` header. `GetPrivateKeyPassword` is only called for a protected key **[verified: API/22_miscellaneous/_16-GetPrivateKeyPassword.md]**. |
| `AUTO_CONNECT` | `false` | "Director should automatically attempt the connection." We connect explicitly with `NetConnect` only when paired and an IP is known. |
| `KEEP_CONNECTION` | `false` | "Director should automatically attempt to reestablish a connection if it drops." Our own backoff and generation counter own reconnection; two reconnectors would fight and Director's interval is undocumented. |
| `MONITOR_CONNECTION` | `false` | "Director should monitor the connection by periodically polling. Director invokes the OnPoll method". The fundamentals add: "if data is not returned on this socket it will be considered down" **[verified: FUND/11_connections/_1-OVERVIEW.md]**. A quiet SSE stream returns nothing for minutes, so monitoring would tear it down. |
| `KEEP_ALIVE` | `true` | "Director should enable TCP keep-alive for the connection." Dead-peer detection the SSE stream lacks; see §4 for how slow it is. |
| `DELIMITER` | `""` | "If no delimiter is specified, packets are delivered as they are received." (The fundamentals say "data is sent on timeout" when there is no delimiter **[verified: FUND/11_connections/_1-OVERVIEW.md]**, which hints at a short aggregation timer; its length is **[unknown]**, test 5.) A delimiter is wrong here: chunked framing has no fixed terminator and events would be withheld until the delimiter appeared. |
| `SUPPRESS_CONNECTION_EVENTS` | `true` (the default) | Keeps Director from firing `OnDeviceOnline`/`OnDeviceOffline` project events for our socket **[verified: API/7_event/_8-SupressingSystemEvents.md]**. |
| `MIRROR_UDP_PORT` | omitted | UDP only. |

**TLS version.** The bullet list in `NetPortOptions.md` names the key
`VERIFY_METHOD` with values `sslv2, sslv23, sslv3, tlsv1, tlsv1_1`, while
the sample table in the same file uses `METHOD = 'tlsv1'`, and the XML form
is `<method>` with values up to `tlsv12` **[verified:
API/22_miscellaneous/_16-GetPrivateKeyPassword.md]**. The docs therefore
disagree on the key's name, and none of the listed values is newer than
TLS 1.2. "If this property is omitted, then Director defaults to using
sslv23 (which is the OpenSSL default)". In OpenSSL `sslv23` means "negotiate
the highest version both sides support", so omitting the key is the only
setting that can reach TLS 1.2/1.3 on every Director build **[OpenSSL
semantics, not from the DriverWorks docs]**. OS 4.0 is on OpenSSL 3.0
**[verified: API/3_whats_new/_7-WhatsNewin400.md cites the OpenSSL 3.0
notes]**; the OS 3.4.2 library version is **[unknown]**. Recommendation:
omit `METHOD`/`VERIFY_METHOD`; test 4 checks the handshake with the Bridge
Pro. Never set `tlsv1`/`tlsv1_1`: a modern bridge will refuse them.

**Hostname (CN) verification.** The bridge certificate's CN is the bridge
id, not the IP. The DriverWorks docs describe `VERIFY_MODE` purely as
OpenSSL's `SSL_VERIFY_PEER` (chain verification) and offer no hostname
option at all; contrast `C4:url`'s separate `ssl_verify_host` **[verified:
API/35_url/_12-SetOption.md]** and the MQTT client's `SetTlsInsecure`, which
exists precisely to skip the CN check **[verified:
API/22.5_mqtt/_14-settlsinsecure.md]**. In OpenSSL, `SSL_VERIFY_PEER` on its
own does not compare the hostname; that is a separate call the application
has to make **[OpenSSL semantics]**. Expectation, **[assumed]** until test 2:
`VERIFY_MODE = "peer"` verifies the chain against the two Signify roots and
ignores the CN, which is exactly what we want (the bridge id is checked at
the application layer by `bridge/pairing.lua`, as today). If Director does
enforce a CN match, the handshake will fail against every Hue bridge and the
only documented way out is `VERIFY_MODE = "none"` for the stream: the stream
is read-only (a spoofed stream could feed false state, never issue commands)
and all commands stay on the verified `C4:url` path. That fallback must be
an explicit, logged decision, not a silent default.

**Error reporting.** The docs say nothing about how a missing CA file or a
failed handshake reaches Lua. Expect no error at `NetPortOptions`/`NetConnect`
time and simply no `"ONLINE"` (or `"ONLINE"` then `"OFFLINE"`) **[assumed]**;
tests 1-2 read `driver_debug.log` for the reason.

## 3. Data flow

### Callbacks

- `OnConnectionStatusChanged(idBinding, nPort, strStatus)` with `strStatus`
  `"ONLINE"` or `"OFFLINE"` **[verified: API/32.../_27-OnConnectionStatusChanged.md]**.
  Control4's samples send their first bytes from the `"ONLINE"` branch (the
  websocket module sends its HTTP upgrade there) **[verified:
  COMMON/module/websocket.lua `ConnectionChanged`]**. Whether `"ONLINE"` is
  raised after the TCP connect or after the TLS handshake is not documented;
  since data can only flow after the handshake, treat it as "handshake done"
  **[assumed]**.
- `ReceivedFromNetwork(idBinding, nPort, strData)` (a fourth `from`
  parameter was added in 4.0.0, harmless to ignore) **[verified:
  API/32.../_15-ReceivedFromNetwork.md]**. "Network data received may only
  include part of a protocol command ... It is the driver's responsibility
  to re-constitute and parse". Embedded NULs are preserved. Maximum size per
  call: **[unknown]**, test 5.
- `OnNetworkBindingChanged(idBinding, bIsBound)` when the binding's address
  is set or cleared **[verified: API/32.../_28-OnNetworkBindingChanged.md]**.
  If an installer clears the address in Composer, stop the stream and say so
  in the `Event Stream` property.

### Request

`C4:SendToNetwork(idBinding, nPort, strData)` sends an arbitrary string
**[verified: API/32.../_20-SendToNetwork.md]**. Sent once per `"ONLINE"`:

```
GET /eventstream/clip/v2 HTTP/1.1\r\n
Host: <bridge ip>\r\n
hue-application-key: <key>\r\n
Accept: text/event-stream\r\n
Connection: keep-alive\r\n
User-Agent: C4HueBridge/<driver version>\r\n
\r\n
```

The websocket module builds its request the same way (`table.concat` of
header lines with `'\r\n'`, terminated by a blank line) **[verified:
COMMON/module/websocket.lua `MakeHeaders`]**.

### Response

Status line, headers, blank line, then the body with `Transfer-Encoding:
chunked` (the bridge's behaviour, from the spike). Chunked format per
HTTP/1.1: `<hex size>[;ext]\r\n<size bytes>\r\n` repeated, then `0\r\n`,
optional trailer lines, `\r\n`. `C4:url` did this decoding for us; now it is
Lua.

### Lua design

Two new pure-Lua modules (no `C4` calls, unit-testable like `sse.lua`) and
one thin wrapper over the network API:

**`bridge/httpresp.lua`**: incremental HTTP/1.1 response parser.

```
local p = httpresp.new()
for _, ev in ipairs(p:feed(bytes)) do ... end
-- ev.kind: "headers" {code, reason, headers (lower-cased keys)}
--          "body"    {data}         decoded body bytes, any length
--          "done"    {}             0-chunk (and trailers) seen, or
--                                   Content-Length reached
--          "error"   {message}      malformed; caller reconnects
```

State machine: `status` (buffer until `\r\n\r\n`; parse `HTTP/1.x <code>
<reason>` and `name: value` lines; cap the block at 16 KiB) -> `chunk_size`
(buffer until `\r\n`; strip `;extensions`; `tonumber(hex, 16)`; 0 ->
`trailer`) -> `chunk_data` (emit `body` for whatever of the remaining `need`
bytes is buffered; at 0 expect `\r\n` -> `chunk_size`) -> `trailer` (lines
until an empty one -> `done`). Without `transfer-encoding: chunked` or
`content-length`, state `identity`: every byte is body until the caller
turns `"OFFLINE"` into end-of-body. Partial chunks are emitted at once and
the parser only consumes what is complete, so splits mid-size-line, mid-data
or between `\r` and `\n` all work. Cap a chunk at 4 MiB and the pending
buffer at `sse.MAX_LINE`, emitting `error` beyond that.

**`bridge/netconn.lua`**: one object per network binding.

```
local c = netconn.new{ binding = 6001, port = 443, ip = ip,
    options = <tPortParams from §2>,
    on_status = function(online) end,  -- OnConnectionStatusChanged
    on_data   = function(bytes) end }  -- ReceivedFromNetwork
c:open()   -- CreateNetworkConnection(binding, ip, "SSL") (first time) or
           -- SetBindingAddress(binding, ip) if the binding exists with
           -- another address; NetPortOptions(binding, port, "SSL", options);
           -- NetDisconnect(binding, port); NetConnect(binding, port)
c:send(s)  -- SendToNetwork(binding, port, s)
c:close()  -- NetDisconnect(binding, port)
```

`NetDisconnect` before `NetConnect` is the pattern in both the websocket
module's `Start` and the Denon example **[verified: COMMON/module/websocket.lua;
FUND/23_command_handling_and_dropped_connections/_1-...md]**. The `SSL`
sample passes no type to `NetConnect` (`C4:NetConnect(6001, 443)`)
**[verified: API/32.../_30-SampleSSLConnection.md]**. Whether
`CreateNetworkConnection` may be called twice for one binding is
undocumented, hence the module-level record and `SetBindingAddress` for
changes ("It is recommended that the NetConnect API is called after
SetBindingAddress") **[verified: API/32.../_16-SetBindingAddress.md]**.

Routing: `common/dispatch.lua` grows a `dispatch.network[binding] =
{ status = fn, data = fn, bound = fn }` table and `dispatch.install(env)`
defines the three globals `OnConnectionStatusChanged`, `ReceivedFromNetwork`
and `OnNetworkBindingChanged`, each looking up its binding id and ignoring
unknown ones. This mirrors Control4's `OCS`/`RFN` tables **[verified:
COMMON/global/handlers.lua lines 354 and 907]**. `.luacheckrc` must list the
three new globals for `driver.lua`.

**`bridge/stream.lua`**: same public interface (`new(opts)`, `start`, `stop`,
`running`, `on_status`, `on_connected`, `on_container`, `stats`), new
internals. `connect()` builds `httpresp.new()` and `sse.new()`, opens the
netconn, and arms a 10 s connect timer. On `"ONLINE"`: send the request, arm
a 10 s headers timer. On data: `httpresp:feed`; a `headers` event with code
200 is today's `handle_headers` (state `connected`, backoff reset, watchdog
armed, `on_connected`); any other code is recorded as `HTTP <code>` and the
connection closed (401/403 additionally say "key rejected, re-pair" in the
status text); `body` events go to `sse:feed` exactly as `handle_chunk` does
now; `done`/`error` close the connection and reconnect. On `"OFFLINE"`:
today's `handle_done`. The generation counter stays: any callback whose
generation is stale (we already closed it) is dropped, which covers the
`"OFFLINE"` Director will raise after our own `NetDisconnect`.

### Binding id

Network bindings are 6000-6999 and must be unique within the driver
**[verified: API/32.../_1-CreateNetworkConnection.md; FUND/11_connections/_1-OVERVIEW.md]**.
Use **6001**; the bridge driver has no other network binding. No
`AddDynamicBinding` is needed: its valid types are `CONTROL` and `PROXY`
only **[verified: API/22_miscellaneous/_1-AddDynamicBinding.md]**, and
`CreateNetworkConnection` itself creates the connection with no XML
**[verified]**. (Control4's websocket module instead scans 6100-6199 for an
id whose `C4:GetBindingAddress(i)` is empty **[verified: COMMON/module/websocket.lua]**;
a fixed id is simpler for one connection.) We recreate the connection in
`OnDriverLateInit` on every start; none of these calls is allowed during
`OnDriverInit` **[verified: API/22_miscellaneous/_25.2-SafeUsageTable.md,
all five network calls "NO"]**.

## 4. Lifecycle

- **Start**: `OnDriverLateInit` (as now) and `on_paired`. `stream:start()`
  -> `connect()` as above. The connect timer covers the undocumented case of
  a connect that never reports `"OFFLINE"` (the Denon example also runs its
  own reconnect timer rather than trusting a status callback) **[verified:
  FUND/23_...]**.
- **Disconnect detection**: `"OFFLINE"` from `OnConnectionStatusChanged`
  (remote close, reset, cable pulled with keepalive) and the `httpresp`
  `done`/`error` events (server ended the stream cleanly: Hue's `0\r\n\r\n`).
- **Reconnect**: unchanged `schedule_reconnect` with 1 s doubling to 60 s,
  reset on a 200 response. Every connect is followed by `on_connected`, which
  the driver uses for a full GET resync; with the stream off `C4:url` that
  GET can now run while the stream is open.
- **Silence watchdog**: unchanged in shape; the bridge sends no keepalives
  (spike). TCP keepalive via `KEEP_ALIVE` only detects a *dead* peer, and
  slowly: Linux defaults are 7200 s idle, then 9 probes 75 s apart, about
  2 h 11 min **[kernel defaults; the controller's sysctl values, and whether
  Director sets per-socket keepalive times, are unknown]**. So the
  application watchdog stays. With no total-transfer timeout any more it is
  the only thing that cycles a quiet stream; its default can rise (600 s)
  once test 5 confirms promptness, since each cycle costs a resync GET.
  `Stream Timeout (s)` no longer means anything: remove it from `driver.xml`
  or repurpose it as an optional maximum stream age (0 = never).
- **IP change**: `Bridge_IP_Address` handler already calls
  `restart_stream()`; the new netconn `open()` does `NetDisconnect`,
  `SetBindingAddress(6001, new_ip)`, `NetConnect`.
- **Stop / destroy**: `stream:stop()` -> `netconn:close()` ->
  `C4:NetDisconnect(6001, 443)`; `OnDriverDestroyed` keeps calling
  `stream:stop()`. `OnDriverDestroyed` runs before an update and at shutdown
  **[verified: API/22_miscellaneous/_24-OnDriverDestroyed.md]**. The
  websocket module also clears the address with `C4:SetBindingAddress(id,
  '')` when deleting a socket **[verified]**; do that in `Forget Pairing`
  so a stale bridge address is not left on the binding.
- **Key revoked**: HTTP 401/403 on the stream. Keep reconnecting with
  backoff capped at 60 s as now, but put "key rejected, re-pair" in the
  status property; the resync GET will report the same and the pairing
  code owns recovery.
- **Interaction with commands**: none by construction; `bridge/http.lua`
  keeps using `C4:url` with `ssl_cabundle`. The caveat in `docs/dev-loop.md`
  (no `C4:url` transfer may start inside another transfer's
  `OnHeaders`/`OnBodyChunk`) may or may not extend to `ReceivedFromNetwork`;
  if test 6 shows curl error 2, hop through `C4:SetTimer(1, ...)` first.

## 5. Risks and unknowns, in test order

Each is one dev-loop push (`docs/dev-loop.md`) with the expected
observation. Run them in this order so one unknown is varied at a time.

1. **Raw path works at all, verification off**: `VERIFY_MODE = "none"`, no
   `CACERTFILE`. Expect `"ONLINE"` within 2 s, then `HTTP/1.1 200` with
   `Transfer-Encoding: chunked` in the Lua output, then an event within
   1-2 s of toggling a light in the Hue app. Proves `CreateNetworkConnection
   ... "SSL"` negotiates TLS with the bridge, and the parser.
2. **CA path and peer verification**: `VERIFY_MODE = "peer"`,
   `CACERTFILE = "certs/hue_ca_bundle.pem"`. Expect the same as 1. If never
   `"ONLINE"`: try `"./certs/hue_ca_bundle.pem"`, then an absolute path
   `C4:GetC4zDir() .. "/hue_bridge/certs/hue_ca_bundle.pem"`
   (`GetC4zDir` exists from 2.10.0 **[verified: API/9_helper/_7-GetC4zDir.md]**),
   and read `driver_debug.log`. If it connects, this also settles the CN
   question: the CN mismatch did not fail the handshake.
3. **Verification is real**: `VERIFY_MODE = "peer"` with `CACERTFILE`
   pointing at a bundle that lacks the Signify roots (the pinning check's
   public-CA idea in reverse). Expect no `"ONLINE"` (or `"ONLINE"` then
   `"OFFLINE"` with nothing received). If the stream still works, `peer` is
   being ignored and the design note in §2 about `none` applies for real.
4. **TLS version with METHOD omitted**: covered by 1-3 succeeding against
   the Bridge Pro. If the handshake fails, try `METHOD = "tlsv12"` and
   `VERIFY_METHOD = "tlsv12"` separately to learn which key Director reads.
5. **Promptness and chunk size without a DELIMITER**: stopwatch from Hue-app
   toggle to `Last Event` (expect under 2 s, like `OnBodyChunk`); log
   `#strData` per `ReceivedFromNetwork` call (expect one SSE event or a
   TCP-segment-sized piece; a suspiciously round figure such as 1024 means
   a buffer worth knowing about).
6. **Starting `C4:url` from `ReceivedFromNetwork`**: have `on_connected`
   run its GET directly from the headers event. Expect "Test OK"; if curl
   error 2, use the timer hop.
7. **Disconnect reporting**: pull the bridge's Ethernet cable for 30 s.
   Expect `"OFFLINE"` only after keepalive kicks in (minutes to hours; note
   the time), or the watchdog first; then "Reconnecting in N s" doubling,
   then `"ONLINE"` within a minute of reconnecting the cable. Reboot the
   bridge (it sends FIN/RST): expect `"OFFLINE"` immediately.
8. **Failed connect reporting**: set a wrong IP. Expect either a prompt
   `"OFFLINE"` or nothing until the 10 s connect timer fires; the result
   decides whether the timer can be dropped.
9. **Composer view, restart, update**: does binding 6001 appear on the
   Network tab, and does "Identify" there overwrite our address (watch
   `OnNetworkBindingChanged`)? Restart Director and update the driver in
   place: expect the stream back from `OnDriverLateInit` with no Composer
   step and no duplicate `ReceivedFromNetwork` deliveries.

## 6. Testing plan

### Unit tests (busted)

`tests/spec/httpresp_spec.lua`, pure Lua, no fake needed:

- a recorded bridge response (status line, headers including
  `Transfer-Encoding: chunked`, two chunks each holding one SSE event, a
  `0` chunk) fed whole produces `headers`, `body` x2, `done`;
- the same bytes fed one byte at a time, and split at every position
  (loop over `1..#bytes`), produce byte-identical concatenated body and the
  same event sequence;
- chunk extensions (`1a;foo=bar`), trailers, lower/upper-case hex, a 401
  with a JSON body, an identity body with `Content-Length`, an identity body
  with neither (ends on close), oversize header block and oversize chunk ->
  `error`.

`tests/spec/netconn_spec.lua` and the updated `stream_spec.lua` need the
fake runtime extended. `tests/helpers/fake_c4.lua` currently has no network
API; add, recording every call in `c4.calls` as the existing methods do:

- `C4:CreateNetworkConnection(binding, address, type)` ->
  `c4.network[binding] = { address, type, ports = {} }`
- `C4:NetPortOptions(binding, port, type, options)` -> stores `options`
  under `ports[port]`
- `C4:NetConnect(binding, port, type, suppress)` -> marks `connecting`
- `C4:NetDisconnect(binding, port)` -> marks `closed`
- `C4:SendToNetwork(binding, port, data)` -> appends to `ports[port].sent`
- `C4:SetBindingAddress(binding, ip)`, `C4:GetBindingAddress(binding)`
- spec-side drivers that call the driver's globals the way Director would:
  `c4.net_status(binding, port, "ONLINE"|"OFFLINE")` ->
  `OnConnectionStatusChanged`; `c4.net_receive(binding, port, bytes)` ->
  `ReceivedFromNetwork`; `c4.net_bound(binding, bool)` ->
  `OnNetworkBindingChanged`. Module-level specs get those globals from
  `dispatch.install(_G)`; driver-level specs from `fake.load_driver`.

Stream specs, rewritten against the fake network: request text has the
request line, `Host`, the key and `Accept: text/event-stream`; nothing is
sent before `"ONLINE"`; 200 headers -> `connected`, `on_connected` once,
watchdog armed; an event split across two `net_receive` calls and a chunk
boundary yields one container; non-200 -> `NetDisconnect`, `waiting`, `HTTP
401` in `last_error`; `"OFFLINE"` -> backoff doubling, reset after a 200;
watchdog -> `NetDisconnect` with the stale `"OFFLINE"` ignored; `stop()` ->
`NetDisconnect`, no timers left; connect and headers timers each reconnect;
IP change -> `SetBindingAddress` then `NetConnect`;
`OnNetworkBindingChanged(6001, false)` -> stopped with a status message.
`drivers_spec.lua` moves its stream assertions from `c4.transfers[5]` to
`c4.network[6001]` and checks that pairing and `Test Connection` still use
`c4.transfers` (`C4:url`) while the stream does not.

Also a spec that the `NetPortOptions` table is exactly §2 (`VERIFY_MODE ==
"peer"`, `CACERTFILE == http.CA_BUNDLE`, `MONITOR_CONNECTION == false`,
`KEEP_CONNECTION == false`, `KEEP_ALIVE == true`, `DELIMITER == ""`, no
`METHOD`), so a casual edit cannot silently turn verification off.

### On the controller

Run §5 in order through the dev loop. Then the parts of
`docs/spike-checklist.md` that still apply: B6-B7 (live events), C10
(watchdog), C11 (cable pull), D12-D14 (restart, soak, forget pairing), and
the new decisive check: **with the stream connected, `Test Connection`
returns "Test OK" in well under a second**, and `Connection Test` against
the bridge reports both concurrent GETs OK with the stream open. Record the
`Event Stream` property text and Lua output at each step as before.
