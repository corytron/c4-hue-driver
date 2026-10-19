# Design notes

Status key: **[verified]** = checked in the DriverWorks docs, Control4's sample
drivers, or an independent source; **[assumed]** = not yet confirmed, to be
tested on the real controller or against the Hue docs.

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

- REST calls: `C4:url()` with `ssl_cacerts` pointing at the bundled roots and
  `ssl_verify_host=false`, since the bridge certificate's CN is the bridge ID,
  not the IP **[verified API]**. The bridge's identity is then checked in the
  application layer: its `bridge_id` must match the stored ID.
- Event stream: `C4:url()` with `OnBodyChunk` (body arrives unbuffered).
  `timeout` covers the total transfer time (default 300 s) **[verified]**, so
  the stream reconnects on a schedule and resyncs with a full GET after every
  reconnect. Whether chunks arrive in real time on the controller is
  **[assumed]**; this is the first thing to spike on hardware. The fallback is
  a raw SSL network connection (`CreateNetworkConnection` + `NetPortOptions`)
  with HTTP and chunked encoding handled in Lua.
- Certificates: `src/hue_bridge/certs/` holds Signify's two public roots.
  - `root-bridge`: SHA-256 `F0:BD:8E:65:…:8D:8A:CF`.
  - `Hue Root CA 01`: SHA-256 `D8:B8:94:48:…:03:28:B8`.

  Each matches across openHAB, callionica/hue and LumaSync **[verified]**.
  Community reports say the Bridge Pro writes its CN in upper case, so IDs are
  compared lower-case **[assumed]**.

## Discovery

- Manual IP entry in the `Bridge IP Address` property is always available.
- SSDP: Control4's `drivers-common-public` has an SSDP module with a sample
  driver **[verified]**. Whether current Hue firmware (square bridge and Bridge
  Pro) still answers SSDP is **[assumed]**. Signify has favoured mDNS, and
  DriverWorks has no mDNS API. SSDP is a best-effort "Discover" action.
- SDDP is Control4's own discovery protocol; a device has to announce itself
  with it, and Hue bridges don't **[assumed]**.
- After pairing, the bridge ID is stored. If the IP stops answering,
  rediscovery looks for that ID.

## Commands and rate limiting

- Each light has one pending-state slot where the latest value wins. A short
  debounce (about 50–100 ms) merges brightness and color into one PUT, as the
  light_v2 best-practice doc asks for back-to-back commands **[verified]**.
- Budget: about 10/s for `light` and about 1/s for `grouped_light`, with one
  or two requests in flight and backoff on 429/503 **[assumed]**. To be
  confirmed against the Hue docs.

## Color mapping

- light_v2 color is CIE 1931 xy, the same as Hue: pass it through
  **[verified]**.
- CCT: Kelvin = 1,000,000 / mirek. Per-light CCT min/max come from the light's
  `mirek_schema` and are sent in a single `DYNAMIC_CAPABILITIES_CHANGED`
  together with `supports_color` / `supports_color_correlated_temperature`
  **[verified requirement]**.
- Brightness 0 maps to `on: false`. RATE (ms) maps to `dynamics.duration`.
  A color set while the light is off is stored and applied on the next turn-on
  **[verified best practice]**.
- Out-of-gamut xy is clamped by the bridge **[assumed]**. The driver reports
  the xy the bridge actually set; `color_trace_tolerance` absorbs rounding.

## Storage

- The application key is stored with `C4:PersistSetValue(name, value, true)`
  (encrypted, 2.10.0+) **[verified]**. Properties only show status.
