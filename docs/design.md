# Design notes

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
  **[verified for BSB002; BSB003 from community sources]**.

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
  CA probe (four hardware runs) **[verified]**:
  - The `.c4z` is extracted on disk to `/opt/control4/var/drivers/c4z/<name>/`
    (`FileSetDir("C4Z")` + `FileList()` shows `bridge, certs, common,
    driver.lua, driver.xml, …`).
  - `ssl_cabundle` is prefixed with that directory: a path relative to the
    archive works, an absolute path fails with curl error 77. It replaces
    the system CA bundle, so trust is pinned to the two Signify roots.
  - `ssl_cacerts` is opened by Director itself: absolute paths work, relative
    paths fail with an asynchronous `LUA_ERROR` and no callback (so the
    documented "relative to the .c4z" is true for `ssl_cabundle` only). It
    adds to the system bundle and therefore pins nothing; with hostname
    checking off that would accept any publicly-trusted certificate.
  - `SANDBOX:/` and `C4Z:/` aliases are not understood by either option.
  - The sandbox is `/control4/drivers/lua/sandbox/<device id>`; the
    `/lua/sandbox/<id>` in the File API docs is an abbreviation.
  - `FileExists` only accepts a bare file name in the current alias
    directory, not absolute paths.

  Design: the bundle ships in the archive as `certs/hue_ca_bundle.pem`
  (generated from the two PEMs by `tools/gen_ca_bundle.sh`) and is referenced
  as `ssl_cabundle = "certs/hue_ca_bundle.pem"`. An embedded copy
  (`bridge/ca_bundle.lua`) is written into the sandbox at startup for the
  `ssl_cacerts` fallback. `bridge/ca_probe.lua` still confirms the choice at
  startup with up to four requests to `/api/0/config`; once the next run
  confirms the archive-relative path, the probe can go. The **Check CA
  Pinning** action verifies that a public CA-signed site is rejected with the
  chosen configuration **[pending hardware run]**.
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
  **[verified]**, which suits `C4:url()`.
- Not documented: keepalive or heartbeat messages, resuming with
  `Last-Event-ID`, connection limits **[unknown]**. Design for the worst case:
  a watchdog reconnects on silence, and every reconnect is followed by a full
  GET resync.
- Transport: `C4:url()` with `OnBodyChunk` (body arrives unbuffered).
  `timeout` covers the total transfer time (default 300 s) **[verified]**, so
  the stream also reconnects on a schedule. Whether chunks arrive in real time
  on the controller is **[assumed]**; `docs/spike-checklist.md` tests this
  with `bridge/stream.lua`. The fallback is a raw SSL network connection
  (`CreateNetworkConnection` + `NetPortOptions`) with HTTP and chunked
  encoding handled in Lua.

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
- Persisted alongside it: bridge ID, last known IP, and the time of the last
  discovery-endpoint request.
