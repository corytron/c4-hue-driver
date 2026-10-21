# Design notes

How the work gets done (process, not architecture): every change that can
be split into parts touching disjoint files is built by parallel agents
against a contract written first, with one coordinator integrating,
testing and committing; see "Working with agents" in `CLAUDE.md`. Testing
on the controller goes through the dev loop (`docs/dev-loop.md`), so a
change can be pushed, reloaded and exercised on hardware without Composer.

Status key: **[verified]** = checked in the DriverWorks docs, Control4's sample
drivers, Signify's Hue developer docs (Core Concepts, Using HTTPS, Hue Bridge
Discovery and the CLIP v2 API reference, as of 2025), or independent sources;
**[assumed]** = not yet confirmed, to be tested on the real controller or bridge.

## Targets

- Controller: OS 3.4.2 today; must keep working on OS 4.x.
- `driver.xml` declares `<minimum_os_version>3.3.0</minimum_os_version>`.
  3.3.0 introduced the light_v2 brightness-target and color APIs
  (`SET_COLOR_TARGET`, `LIGHT_COLOR_CHANGED`, CCT capabilities,
  `C4:ColorXYtoCCT` and friends) **[verified]**.
- Lua: `<script jit="1">` loads the driver under LuaJIT, which has Lua 5.1
  semantics **[verified]**. Tests run under `lua5.1`.
- Nothing in the design depends on 4.x-only APIs (dynamic commands and
  conditionals are 4.1+, so they're not used) **[verified]**.
- Hue: CLIP API v2 is the current local API; there is no v3 **[verified]**.
  Bridge models are `BSB002` (square bridge) and `BSB003` (Bridge Pro)
  **[verified: the house bridge reports `modelid` BSB003]**. Its certificate
  verified against the two bundled roots **[verified on hardware]**.

## Driver structure

Two drivers, the pattern Control4's own `idc_controller`/`idc_client` samples
use **[verified]**:

- **Hue Bridge** (`hue_bridge.c4z`): a combo driver with a provider CONTROL
  binding (id 1, class `HUE_BRIDGE`). It owns pairing, the HTTPS client, the
  event stream, the command queue, and rooms, zones and scenes for programming.
- **Hue Light** (`hue_light.c4z`): one per Hue light. It has a light_v2 proxy
  (binding 5001) and a consumer binding (id 1, class `HUE_BRIDGE`).

One provider binding serves many consumers: `GetBoundConsumerDevices` returns
a table **[verified]**. Lights are created from a bridge action with
`C4:AddDevice` (3.2.0+, must be user-initiated) and bound with `C4:Bind`.
The two drivers talk through `C4:SendToDevice` in both directions.

## Networking

- HTTPS only, port 443. Signify forbids falling back to plain HTTP, and CLIP v2
  has never supported it **[verified]**. The driver has no HTTP code path.
- REST calls: `C4:url()` with `ssl_cacerts` pointing at the bundled roots and
  `ssl_verify_host=false`, since the certificate's CN is the bridge ID, not the
  IP **[verified API]**.
- Keep consecutive requests on one connection; the bridge also supports TLS
  session tickets **[verified Signify guidance]**. Whether `C4:url()` reuses
  connections between transfers is **[assumed]**.

### Certificates

- `src/hue_bridge/certs/` holds Signify's two private root CAs. Both are
  byte-identical to the bundle on Signify's "Using HTTPS" page, and to copies
  in openHAB, callionica/hue and LumaSync **[verified]**.
- How the bundle reaches `C4:url`, established on OS 3.4.2 by the spike's
  CA probe (five hardware runs) **[verified]**:
  - The `.c4z` is extracted on disk to `/opt/control4/var/drivers/c4z/<name>/`.
  - `ssl_cabundle` is prefixed with that directory (not the sandbox): a path
    relative to the archive works, an absolute path fails with curl error
    77. It replaces the system CA bundle, so trust is pinned to the two
    Signify roots; the **Check CA Pinning** action confirmed that a public
    CA-signed site is rejected with it (curl error 60).
  - `ssl_cacerts` is opened by Director itself: absolute paths work, relative
    paths fail with an asynchronous `LUA_ERROR` and no callback (so the
    documented "relative to the .c4z" is true for `ssl_cabundle` only). It
    adds to the system bundle and therefore pins nothing; with hostname
    checking off that would accept any publicly-trusted certificate.
  - `SANDBOX:/` and `C4Z:/` aliases are not understood by either option.
  - The sandbox is `/control4/drivers/lua/sandbox/<device id>`; the
    `/lua/sandbox/<id>` in the File API docs is an abbreviation.
  - The Bridge Pro's certificate verifies against the bundle.

  Design: the bundle ships in the archive as `certs/hue_ca_bundle.pem`
  (generated from the two PEMs by `tools/gen_ca_bundle.sh`; a spec fails on
  drift) and `bridge/http.lua` uses `ssl_cabundle = "certs/hue_ca_bundle.pem"`
  for every bridge request. Requests to public hosts use the system CAs with
  hostname checking (`mode = "system"`).
- Bridge IDs are 16 hex digits, compared lower-case. The discovery endpoint
  returns lower case (`001788fffe100491`), `/api/0/config` upper case
  (`001788FFFE25B8F8`) **[verified]**.

### Event stream

- `GET /eventstream/clip/v2` with `Accept: text/event-stream` and the
  `hue-application-key` header **[verified]**.
- Each SSE message has an `id:` line and a `data:` line holding a JSON array of
  containers. Each container has `creationtime`, `id`, `type` (`update`,
  `add`, `delete`, `error`) and `data`: partial resources in GET format, with
  only the changed properties **[verified]**.
- The bridge sends at most one container per second. A property that changed
  twice in that second only reports its last value, and changes to several
  resources are grouped in one container **[verified]**.
- On HTTP/1.1 the stream needs its own connection, separate from REST calls
  **[verified]**. `C4:url()` cannot provide that second connection on OS
  3.4.2 (see below).
- Not documented: keepalive or heartbeat messages, resuming with
  `Last-Event-ID`, connection limits **[unknown]**. Design for the worst case:
  a watchdog reconnects on silence, and every reconnect is followed by a full
  GET resync.
- Spike transport: `C4:url()` with `OnBodyChunk`. Results on OS 3.4.2, from
  the bridge and from a controlled experiment against a multithreaded HTTPS
  test server on the LAN whose connection log was inspected (the **Connection
  Test** action, `bridge/conntest.lua`) **[verified]**:
  - `OnBodyChunk` delivers data live, without buffering: chunks the test
    server sent every 2000 ms were logged by the driver every ~2000 ms, the
    first one 9 ms after the headers. Against the bridge, events with
    per-second ids likewise arrived long before the 3600 s transfer timeout.
  - The bridge sends no keepalive on the stream: 300 s of silence tripped the
    watchdog, which reconnected cleanly. So in a quiet house the stream will
    be reopened every watchdog period; the period can be long, but there is
    no application-level liveness signal to rely on.
  - **While a `C4:url()` streaming transfer to a host is open, Director opens
    no second connection to that host.** A GET to the streaming host started
    from a timer or an `OnDone` callback timed out after the full 15 s (curl
    28); two concurrent GETs timed out the same way; and the test server saw
    exactly one connection, the stream's. A GET to a different host succeeded
    meanwhile. The same timeout seen earlier against the bridge (`GET
    /clip/v2/resource/bridge` with the stream open) is therefore Director's
    doing, not the bridge's. The stream cannot share `C4:url()` with light
    commands on this OS.
  - A `C4:url()` transfer started from inside another transfer's `OnHeaders`
    callback fails at once with curl error 2 "Failed initialization" (2 ms).
    Transfers started from timers and from `OnDone` callbacks work. Rule:
    never start a transfer from within `OnHeaders` or `OnBodyChunk`; defer it
    with a 1 ms `C4:SetTimer`. `stream.lua` defers `on_connected` that way,
    and `conntest.lua` its step 2.
  - `C4LuaUrl:Cancel()` does not stop an active streaming transfer: after
    `Cancel()` the body chunks kept arriving every 2 s, and the server saw the
    connection close only when the transfer's 300 s total timeout expired.
    Returning `true` from the `OnBodyChunk`/`OnHeaders` callback does abort
    it. `stream.lua` aborts abandoned transfers that way (the generation
    check at the top of every callback); `conntest.lua` does the same after
    its last step.
  - `timeout` covers the total transfer time (default 300 s) **[verified]**,
    so a `C4:url()` stream also reconnects on a schedule.
- Transport for the stream, now the planned design: a raw SSL network
  connection (`CreateNetworkConnection` + `NetPortOptions` with `CACERTFILE`,
  `VERIFY_MODE=peer`, `KEEP_ALIVE`) with the HTTP request and chunked
  transfer decoding written in Lua. It keeps `C4:url()` free for commands,
  has no total-transfer timeout, and TCP keepalive gives dead-peer detection
  the SSE stream itself lacks. `CACERTFILE` is documented as relative to the
  .c4z, the convention `ssl_cabundle` turned out to follow **[assumed until
  tested]**.

### `C4:url` transfer scheduling on OS 3.4.2 (measured through the dev loop)

All **[verified]** on the controller, with millisecond timings shipped by
the dev loop (`build/dev/driver.log` of 2026-10-20, 20:08–20:26):

- **One active transfer per host at a time, strictly serialized.** A GET to
  the bridge issued while the event stream was open completed at the exact
  moment the stream transfer ended (6929 ms later, 26 ms after the stream's
  timeout); two GETs issued after that took 27 and 38 ms. Against the test
  server on this VM the same GET never reached the server at all. So it is
  not a connection limit but a per-host queue: a transfer waits for the
  previous one to the same host to finish.
- **The queue key is the host text as parsed from the URL.** Sharing a queue
  with `10.0.2.143`: `10.0.2.143:443`, `hue@10.0.2.143`, `@10.0.2.143`
  (all timed out behind the stream). Rejected by curl with error 6
  "Couldn't resolve host name": decimal (`167772559`), hex octets
  (`10.0.2.0x8f`, `0x0a.0x00.0x02.0x8f`), the short form `10.0.655`, and the
  IPv6-mapped `[::ffff:10.0.2.143]`. **Getting their own queue and still
  reaching the bridge: zero-padded octets, `10.0.2.143` and
  `10.0.2.143`** (GET OK in under a second with the stream connected).
  Leading zeros are octal to curl's resolver, so only octets with a value
  below 8 can be padded (`010` means 8: `010.0.2.143` connected to the
  wrong address and hit the 5 s connect timeout). Most home subnets have such
  an octet (`192.168.1.x`, `10.0.x.x`); not all do.
- **`Cancel()` does not end an active transfer.** An abandoned stream only
  dies when its next callback returns `true` (so: on the next event from the
  bridge) or at its total timeout. The driver's reconnect after a reload
  therefore sat in "Connecting" until a `zigbee_connectivity` event arrived.
  The Bridge Pro emits those every so often, which hides the problem most of
  the time, but a quiet bridge would leave a reconnect pending for the whole
  stream timeout.
- A transfer started inside another transfer's `OnHeaders`/`OnBodyChunk`
  fails at once with curl error 2 (timers and `OnDone` are safe).
- `C4:JsonEncode` writes Lua arrays as objects with string keys even with
  `encodeArrays = true` (observed on the `/log` bodies); the dev server
  accepts both shapes. Any Hue request body that needs a real JSON array
  will need a small encoder of our own.

### Two ways to keep commands flowing while the stream is open

**A. Two spellings, one transport.** Keep both on `C4:url`: the stream on a
zero-padded spelling of the bridge address, commands on the dotted one.
Separate queues, so commands never wait for the stream. Same TLS setup (the
bundle pins the chain; hostname checking is already off; the bridge ignored
the odd `Host` header and answered 200). Costs: it relies on an undocumented
scheduler detail and on curl's octal parsing, so the driver must check at
startup that a GET via the padded spelling works and otherwise degrade
(single queue with a short stream timeout); addresses with no octet below 8
cannot use it; and reconnects still queue behind the abandoned stream until
the next event or the stream timeout, which argues for a moderate stream
timeout (minutes, not an hour) plus a resync GET after every reconnect.

**B. Raw SSL network connection for the stream** (`docs/raw-stream-design.md`).
Documented transport, no scheduler interaction with `C4:url`, true
persistent socket with TCP keepalive, no total-transfer timeout. Costs:
~400 lines of new HTTP/chunked plumbing and a fake-runtime extension, plus
its own hardware unknowns, chiefly whether `VERIFY_MODE=peer` tolerates the
certificate's CN being the bridge id.

**Decision (2026-10-21): A**, built and verified through the dev loop.
`bridge/altaddr.lua` derives the spellings; the driver self-checks via the
2-digit padding (`10.0.2.143`), streams on the 3-digit one
(`10.0.2.143`) and keeps commands on the dotted address. Result on the
controller: with the stream connected, `GET /clip/v2/resource/bridge` on the
dotted address returned in 0 s where it had timed out at 15 s before, and
a 47-light listing came back in under a second **[verified]**. Fallback
(self-check fails or no octet below 8): shared queue with the stream
timeout capped at 60 s, shown in the `Stream Address` property. B stays
documented as the alternative if a future OS changes the scheduler.

Operational notes from the same session: every stream reconnect leaves the
previous transfer alive until its next callback or its timeout, now on the
stream's own spelling, so only the stream itself waits; the abandoned
transfer's last chunk is still parsed and delivered. A dev-loop reload is a
reconnect too, so a day of reloads can queue several zombies; bridge
events drain them one per event (the `Hue Request` dev action can generate
harmless events by renaming a light back and forth).

## Lights

How Hue lights become light_v2 devices and how state and commands move
between the two drivers. The full contract (every parameter, the module
layout, the test harness) is `docs/lights-design.md`; this is the summary.

- **Roles.** The bridge driver is the only HTTPS speaker: it imports lights,
  keeps the registry, fans state out, and coalesces and sends commands. The
  light driver (one instance per Hue light) talks only to its bridge with
  `C4:SendToDevice` and to its proxy with `C4:SendToProxy(5001, …)`. The
  bridge lists its lights with `C4:GetBoundConsumerDevices(C4:GetDeviceID(),
  1)` (a table of id → name, or nil) and a light finds its bridge with
  `C4:GetBoundProviderDevice(C4:GetDeviceID(), 1)` **[verified: API docs and
  the idc_client sample]**. The ids are protocol-driver ids.
- **Messages.** All through `C4:SendToDevice(id, command, params)`.
  `ExecuteCommand` does not tell the receiver who sent a message, so every
  message carries the Hue resource id `rid`, and the bridge maps rid → device
  id through its registry. Every param value is a string and receivers
  `tonumber()` what they need **[assumed]**. `SendToDevice` drops a parameter
  whose value is the empty string unless its fourth argument
  (`allowEmptyValues`) is true, and logs the command unless its fifth is
  false **[verified: API docs]**.

  | Direction | Command | Params | When |
  | --- | --- | --- | --- |
  | bridge → light | `HUE_CONFIGURE` | `rid`, `name`, `model`, `has_color`, `has_cct`, `mirek_min`, `mirek_max`, `min_dim` | at import, at bridge startup for every registered light, in answer to `HUE_HELLO` |
  | bridge → light | `HUE_STATE` | `rid`, any of `on`, `brightness` (0–100), `x`, `y`, `mirek`, `color_mode` (`xy`/`ct`), `online`; `reason` = `event`/`resync`/`hello` | each stream event for the light; full state after a (re)connect or a hello |
  | bridge → light | `DEV_RELOAD` | `version`, `files` (JSON text) | dev builds only |
  | light → bridge | `HUE_HELLO` | `rid` ("" while unknown) | light late init and when its binding is made; the bridge answers with `HUE_CONFIGURE` and full `HUE_STATE` when it knows the rid |
  | light → bridge | `HUE_SET` | `rid`, any of `on`, `brightness`, `x`+`y`, `mirek`, `rate` (ms) | every proxy command, after mapping |

- **Registry.** `{ [rid] = { device_id, name } }`, persisted as a table with
  `C4:PersistSetValue("hue_lights", table)` **[verified: API docs allow
  tables]**, loaded at late init and written on every change; between those
  the in-memory copy is authoritative (see "Storage" for why). Each light
  persists its own rid as `hue_rid`.
- **Import** (the **Import Lights** action, serial). GET
  `/clip/v2/resource/light`, `/device` and `/zigbee_connectivity`. For each
  light whose rid is not in the registry: `C4:AddDevice("hue_light.c4z",
  C4:RoomGetId(), name, callback)`, **one at a time**, the next from the
  callback (47 at once is the risk); in the callback `C4:Bind(bridgeId, 1,
  deviceId, 1, "HUE_BRIDGE")`, the registry entry, `HUE_CONFIGURE` and full
  `HUE_STATE`. `C4:AddDevice` is 3.2.0+ and documented for user-initiated use
  only **[verified: API docs]**; whether Director cares when the action is
  run through the dev loop is **[assumed: untested]**. Lights already in the
  registry get `HUE_CONFIGURE` and state again, which repairs a light that
  lost its persisted rid; a renamed Hue light is logged, not renamed in
  Composer; a registered light gone from the bridge is logged and left
  alone. Progress goes to the `Lights` property ("12 lights on bridge, 12
  imported, 0 new").
- **State fan-out and resync.** Each `light` item in a stream container
  becomes a `HUE_STATE` with just the changed fields; a `zigbee_connectivity`
  item maps device → light rids → `HUE_STATE` with `online` (`status ==
  "connected"`). After every stream connect the bridge re-GETs the three
  resources and sends full state (reason `resync`) to every registered
  light, `HUE_CONFIGURE` first at startup, so the connect-then-resync rule
  from "Event stream" covers the lights too.
- **Coalescer** (`bridge/commands.lua`). One pending state per rid, latest
  value wins; setting `x`/`y` clears `mirek` and vice versa (the bridge
  applies xy and ignores mirek when both are sent **[verified]**). A rid is
  flushed 80 ms after its last change (one `C4:SetTimer` per rid), so a
  brightness and a colour that arrive together become one PUT **[verified:
  light_v2 best practice]**. One PUT in flight per rid; changes made
  meanwhile go after it returns. Global token bucket of 10/s, burst 10
  **[verified: Hue guidance]**. Body: `on`; `dimming.brightness` clamped to
  [`min_dim`, 100], brightness 0 meaning `on:false` and no `dimming`;
  `color.xy` or `color_temperature.mirek` clamped to the light's range;
  `dynamics.duration` when `rate` > 0 **[assumed: the transition field]**.
  PUTs go to `/clip/v2/resource/light/<rid>` on the dotted address, so they
  never queue behind the stream (see the option A decision above). On 429 or
  5xx: retry after 500 ms, doubling to 8 s; other 4xx: drop and log.
- **Brightness and colour mapping.** Proxy → bridge:
  `SET_BRIGHTNESS_TARGET` **[verified: sample light driver]** with target 0 →
  `on=false`, otherwise `on=true, brightness=target`, `RATE` passed through;
  the light replies `LIGHT_BRIGHTNESS_CHANGING` at once **[verified]** and
  `LIGHT_BRIGHTNESS_CHANGED` when the matching `HUE_STATE` arrives, or after
  rate + 1 s if it never does, so the UI never sticks. `SET_COLOR_TARGET`:
  mode 1 (CCT) → `C4:ColorXYtoCCT` → mirek = 1,000,000 / K, clamped; mode 0
  → xy as given (the bridge clamps to the gamut **[verified]**); the exact
  parameter key spelling is **[assumed]**, so the first one received is
  logged in full. A colour set while the light is off is stored and applied
  at the next turn-on **[verified best practice]**. Legacy `ON`, `OFF`,
  `SET_LEVEL` and `RAMP_TO_LEVEL` are handled defensively **[assumed: may
  still arrive from old programming]**. Bridge → proxy: `HUE_CONFIGURE` → a
  single `DYNAMIC_CAPABILITIES_CHANGED` carrying both `supports_*` flags and
  the CCT range in Kelvin **[verified: both flags in one notify is
  required]**; `HUE_STATE` → `LIGHT_BRIGHTNESS_CHANGED` (0 when off),
  `LIGHT_COLOR_CHANGED` (mode 1 via `C4:ColorCCTtoXY(1,000,000 / mirek)` for
  `ct`, mode 0 with the xy for `xy`), `ONLINE_CHANGED`. Notify parameter
  names use underscores **[verified for brightness in the sample driver;
  assumed for colour]**.
- **Dev loop.** The bridge's loop polls the light tree too and forwards
  `DEV_RELOAD` (version plus the bundle as JSON text) to every bound light
  **[assumed: a ~40 KB string param survives `SendToDevice`; chunk it if
  not]**. A dev-build light reloads itself with the same sequence as the
  bridge and reports through its own `print`, which only its Lua output in
  Composer shows.

### Lights: verified on hardware (2026-10-21, through the dev loop)

- Import Lights created 47 devices one at a time, bound and registered
  them with real capabilities; `Lights` ended at "47 lights on bridge, 47
  imported, 47 new". The `AddDevice` callback is `(protocolId,
  parsed-XML info)` with child nodes `protocol`/`proxy`; proxy id =
  protocol id + 1 on this controller.
- Resync after a reconnect: 47 `HUE_STATE` messages in 270 ms.
- Command path end to end: `SET_LEVEL 30` into a light's `light_v2` proxy
  → the light driver's `HUE_SET` at the bridge → one PUT 82 ms later (the
  debounce) → the bridge's own event 110 ms after that → lamp at 30.04 %.
  `RAMP_TO_LEVEL 60 TIME 1000` and `OFF` behaved the same.
  `SET_BRIGHTNESS_TARGET` sent to the proxy with `SendToDevice` did nothing
  while `ON`/`OFF`/`SET_LEVEL`/`RAMP_TO_LEVEL` worked **[verified]**.
- Navigator slider: a move arrives as `SET_BRIGHTNESS_TARGET`
  { `LIGHT_BRIGHTNESS_TARGET` = 20, `RATE` = 0 } **[verified]**. The lamp
  went to 20 %, but the bridge then reported `brightness` 20.16 and a
  `LIGHT_BRIGHTNESS_CHANGED` carrying that decimal left the proxy at
  0 %/off (the UI "returned to 0"); 100 and 0 worked, and whether the
  integer fallback or the decimal event reported first made it look
  intermittent. The proxy-protocol reference types the parameter as a
  double, so this is observed behaviour, not documented. The light driver
  now reports whole percents (never 0 while on); with that, the lamp Hue
  reported at 20.16 read 20 % and slider moves to 25, 60, 100 and off all
  stuck **[verified on hardware, 2026-10-21]**.
- The light's `light_v2` proxy is a bound *consumer* of the protocol
  driver's binding 5001: `GetBoundConsumerDevices(protocolId, 5001)` finds
  it; `GetBoundProviderDevice` returns the protocol driver itself.
- `DEV_RELOAD` with a ~40 KB `files` param reached all 47 lights three
  times; each push produced 47 fresh `HUE_HELLO` greetings, so every light
  applied the bundle and re-ran its startup.
- Director decodes JSON `null` as an empty table (a light's
  `color_temperature.mirek` while in xy mode arrives as `{}`); the model only
  accepts numbers, so this is harmless, but any code that tests `~= nil`
  on decoded JSON must remember it.
- Most of the house's lights were unpowered during these tests; only the
  Desk Lamp was exercised.

### Project APIs: verified on hardware (2026-10-21, `Probe Project` / `Probe Call`)

For the import-ui design (`docs/import-design.md`), probed through the dev
loop on OS 3.4.2:

- `C4:GetProjectHierarchy()` returns one nested table keyed by location id;
  every node has `name` and a **numeric** `type` (2 site, 3 building,
  4 floor, 8 room) and its children as further numeric keys; rooms have
  none. The house: site → building → 4 floors → 16 rooms.
- `C4:GetDevicesByC4iName("roomdevice.c4i")` → `{ [roomId] = roomName }`
  for all 16 rooms: the cheap room list (undocumented, used by Control4's
  own `lib.lua`).
- `C4:GetDevices(filter)`: `DeviceIds` and `C4iNames` are comma-separated
  **strings** (a table raises "DeviceIds should be a string"). Returns
  `{ [id] = { deviceName, driverFileName, roomId, roomName, proxies =
  { [proxyId] = { deviceName, driverFileName = "light_v2.c4i" } } } }`;
  no `proxies` key for a driver without proxies (the bridge). The protocol
  device carries the display name AddDevice gave ("Left Bedside Light" on
  both 1080 and its proxy 1081); a hand-added, never-linked `hue_light` shows
  the driver name "Hue Light" — there is one such device (1034) in the
  project today, the manual install that preceded the first import.
- `C4:GetBoundConsumerDevices(bridge, 1)` → `{ [protocolId] = "Hue Light" }`:
  the value is the driver's `<name>`, not the Composer name; 47 entries,
  ids 1036–1128 step 2.
- `C4:GetDeviceDisplayName(id)` returns the Composer name for a protocol id
  and for a proxy id alike.
- `C4:UpdateProperty` on an undeclared name and `C4:SendToDevice` to a
  non-existent id both return nil silently; nothing is logged.
- Hue side: 16 rooms (9.9 KB), 7 zones (6.6 KB), 1 bridge_home (1.3 KB),
  125 scenes (351 KB). The single `GET /clip/v2/resource` returns 497
  items, 588 KB, in 1 s. Room `children` are devices, zone `children`
  lights, bridge_home's are rooms plus the room-less devices and it has no
  `metadata`; rooms carry an extra `geometry` block we ignore. Decision:
  the import feature's resync adds `/room`, `/zone` and `/bridge_home` as
  three more serial GETs (18 KB together); the scenes feature decides how
  to handle its 351 KB separately, and nothing fetches everything at once.

## Discovery

Signify's order is mDNS, then the cloud discovery endpoint, then manual IP.
Discovery runs only at setup, or when the stored bridge stops answering
**[verified guidance]**.

1. **Manual IP** (v1): the `Bridge IP Address` property. A DHCP reservation
   for the bridge is recommended.
2. **Cloud discovery endpoint** (v1): a "Discover Bridges" action calls
   `GET https://discovery.meethue.com`. It returns `[{id, internalipaddress,
   …}]` and an empty array when no bridge is found. It only works if the bridge
   has reached the internet and the controller shares its public IP. Rate
   limit: one request per 15 minutes per client **[verified]**. The driver
   persists the time of the last request and refuses to call sooner. This is a
   public internet service with a normal certificate, so it uses default
   certificate verification, not the Hue roots.
3. **Check each candidate** with `GET https://<ip>/api/0/config`
   (unauthenticated). It returns `bridgeid`, `modelid`, `swversion` and
   others **[verified]**. One valid candidate fills in the IP. Several are
   listed in a property with `C4:UpdatePropertyList` **[verified API]** for
   the user to pick.
4. **IP change**: after pairing, the bridge ID is stored. If the stored IP
   stops answering, the driver queries the discovery endpoint (within its
   rate limit) for that ID and updates the IP.
5. **mDNS** (later, not v1): bridges advertise `_hue._tcp.local`, instance
   name `Philips Hue - <last 6 of bridge ID>`, with TXT keys `bridgeid` and
   `modelid` **[verified]**. DriverWorks has no mDNS API, but `NetConnect`
   accepts a `MULTICAST` type **[verified]**. That would mean building the
   DNS query and parsing the reply in Lua. Whether this works on the
   controller is **[assumed]**.
6. **Not used**:
   - SSDP: Signify deprecated it and disabled it in Q2 2022 **[verified]**.
   - SDDP: Control4's own protocol, which a device has to announce itself
     with. Hue bridges don't **[assumed: the Hue docs don't mention it]**.

## Commands and rate limiting

- Limits: about 10 commands/s to `/resource/light` and at most 1/s to
  `/resource/grouped_light`. The REST API is not for continuous fast streams
  **[verified]**.
- Each light has one pending-state slot where the latest value wins. A short
  debounce (about 50–100 ms) merges brightness and color into one PUT, as the
  light_v2 best-practice doc asks for back-to-back commands **[verified]**.
- Token buckets enforce 10/s for lights and 1/s for groups, with one or two
  requests in flight. How the bridge responds when a client goes over the
  limit (429/503?) isn't documented **[assumed]**; back off on any 429/5xx.
- Rooms and zones are controlled through their `grouped_light` service.
  Scenes are recalled through `/resource/scene/{id}` **[verified: resources
  exist; recall body to be confirmed from the API reference]**.

## Color mapping

- Capabilities come from the light resource itself: only lights with a
  `color` object support xy, and only those with `color_temperature` support
  CCT. Never infer them from the model ID **[verified]**.
- light_v2 color is CIE 1931 xy, the same as Hue: pass it through. An xy
  outside the bulb's gamut goes to the closest color it can make. The gamut is
  in the light resource **[verified]**.
- CCT: Kelvin = 1,000,000 / mirek (2000 K = 500 mirek, 6500 K = 153 mirek).
  Per-light limits come from `color_temperature.mirek_schema`
  (`mirek_minimum`/`mirek_maximum`). Out-of-range values go to the closest
  supported one **[verified]**. The CCT min/max are sent in a single
  `DYNAMIC_CAPABILITIES_CHANGED` together with `supports_color` /
  `supports_color_correlated_temperature` **[verified requirement]**.
- Never send `color.xy` and `color_temperature.mirek` in the same PUT: the
  bridge applies xy and ignores mirek **[verified]**. The coalescer keeps only
  the most recent color mode.
- When reporting state, `mirek_valid: true` means the light is in CCT mode
  (report `COLOR MODE=1`); otherwise report xy as full color (`COLOR MODE=0`)
  **[assumed interpretation of mirek_valid]**.
- Brightness: Hue's `dimming.brightness` is a percentage with a minimum above
  zero (`min_dim_level`); minimum brightness is not off **[verified]**.
  C4 brightness 0 maps to `on: false`. RATE (ms) maps to `dynamics.duration`
  **[assumed field for transition time; confirm in the API reference]**.
- A color set while the light is off is stored and applied on the next
  turn-on **[verified best practice]**.
- The bridge's state can lag the bulbs; a power-cycled bulb can take minutes
  to show its real state **[verified]**. The driver reports what the bridge
  reports; `color_trace_tolerance` absorbs rounding.

## Storage

- The application key is stored with `C4:PersistSetValue(name, value, true)`
  (encrypted, 2.10.0+) **[verified]**. Properties only show status.
- `PersistSetValue` writes on its own thread, so `PersistGetValue` may not
  return a value saved moments earlier **[verified: docs, and on hardware
  right after pairing; a later run read back immediately]**. The driver keeps
  what it saved in memory and reads the store only at startup. Updating the
  driver in place in Composer keeps the pairing: the encrypted value survives
  a driver update **[verified on hardware]**. Deleting and re-adding the
  driver does not, because the device ID and sandbox change **[verified]**,
  so always use Composer's update-in-place. Whether the value is readable
  after a Director restart is still **[pending: checklist step 12]**.
- Persisted alongside it: bridge ID, last known IP, and the time of the last
  discovery-endpoint request.
