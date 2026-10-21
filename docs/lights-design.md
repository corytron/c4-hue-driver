# Lights: import, state and control

The contract between the bridge driver, the light driver, the dev loop and
the tests for representing Hue lights as Control4 `light_v2` devices. Read
`docs/design.md` for the facts behind it (one `C4:url` transfer per host
text, the padded stream spelling, Director's JSON quirks, the light_v2
best practices).

Status markers: [verified] = from the SDK docs or hardware; [assumed] = to be
confirmed on the controller through the dev loop.

## Roles

- **Bridge driver** (`src/hue_bridge`): the only HTTPS speaker. Imports
  lights, keeps the registry, fans state out, coalesces and sends commands.
- **Light driver** (`src/hue_light`, one instance per Hue light): a
  `light_v2` protocol driver that talks only to its bridge with
  `C4:SendToDevice`, and to the proxy with `C4:SendToProxy(5001, ...)`.
- Binding: bridge provider binding 1, class `HUE_BRIDGE`; light consumer
  binding 1, same class. The bridge finds its lights with
  `C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1)` (returns a table of
  deviceId → name, or nil) [verified: API 32/_3]; a light finds its bridge
  with `C4:GetBoundProviderDevice(C4:GetDeviceID(), 1)` [verified: idc_client
  sample]. Device ids are protocol-driver ids.

## Messages (all through `C4:SendToDevice(id, command, params)`; every param
## value is a string, receivers `tonumber()` what they need) [assumed: types]

Bridge → light:

| Command | Params | When |
| --- | --- | --- |
| `HUE_CONFIGURE` | `rid`, `name`, `model`, `has_color` ("true"/"false"), `has_cct`, `mirek_min`, `mirek_max`, `min_dim` (percent, e.g. "0.2") | at import, at bridge startup for every registered light, on `HUE_HELLO` |
| `HUE_STATE` | `rid`, plus any of `on` ("true"/"false"), `brightness` (0–100, decimal), `x`, `y`, `mirek`, `color_mode` ("xy"/"ct"), `online` ("true"/"false"), and `reason` ("event"/"resync"/"hello") | each stream event for the light; full state after a (re)connect or hello |
| `DEV_RELOAD` | `version`, `files` (JSON object path → source, as text) | dev builds only, see "Dev loop" |

Light → bridge:

| Command | Params | When |
| --- | --- | --- |
| `HUE_HELLO` | `rid` ("" if unknown yet) | light late init and `OnBindingChanged` bound; bridge answers `HUE_CONFIGURE` + full `HUE_STATE` (reason "hello") when it knows the rid |
| `HUE_SET` | `rid`, any of `on`, `brightness`, `x`+`y`, `mirek`, and `rate` (ms) | every proxy command, after mapping |

`ExecuteCommand` does not tell the receiver who sent a message, so `rid` is
in every message and the bridge maps rid → deviceId through its registry.

`C4:SendToDevice(id, command, params, allowEmptyValues, logCommand)`
[verified: API 32/_19]: empty-string values are dropped unless the 4th
argument is true, so receivers treat a missing `rid` as "unknown" (the
light sends `HUE_HELLO` without `rid` when it has none); and every call is
written to Director's log unless the 5th argument is false, so `DEV_RELOAD`
passes `false` there (its `files` param is tens of kilobytes).

## Bridge: model, registry, import (`bridge/hue_model.lua`, `bridge/lights.lua`)

Normalised light (`hue_model.light(resource)` from one `/clip/v2/resource/light`
item):

```
{ rid, device_rid, name, archetype, on, brightness, min_dim,
  has_color, x, y, gamut = { r={x,y}, g=..., b=... } or nil,
  has_cct, mirek, mirek_valid, mirek_min, mirek_max,
  color_mode = "xy"|"ct"|nil }
```
`color_mode` is "ct" when `color_temperature.mirek_valid` is true, else "xy"
when a colour is present [assumed: meaning of `mirek_valid`].
`hue_model.update(light, delta)` merges a stream-event item (same shapes,
partial). `hue_model.devices(resources)` maps device rid → { name, model,
light_rids, zigbee_rid } from `/clip/v2/resource/device`;
`hue_model.connectivity(item)` reads a `zigbee_connectivity` item into
`{ rid, device_rid, online }` (`status == "connected"`).

Registry, persisted with `C4:PersistSetValue("hue_lights", table)` (tables
allowed) [verified: API 26.5]: `{ [rid] = { device_id = N, name = "...",
model = "...", caps = { has_color, has_cct, mirek_min, mirek_max, min_dim }
} }`, loaded at late init, written on every change. `caps` is what
`HUE_CONFIGURE` and the command queue's limits need, so both work at bridge
startup before any GET has completed; the resync refreshes it.
`model` is `product_data.product_name` (falling back to `model_id`).

Import (`lights.import(http_ctx, report)`), run from the **Import Lights**
action, serially:
1. GET `/clip/v2/resource/light`, `/device`, `/zigbee_connectivity`.
2. For each light whose rid is not in the registry: `C4:AddDevice(
   "hue_light.c4z", roomId, name, callback)` with the bridge's room
   (`C4:RoomGetId()`), **one at a time** (next AddDevice from the callback;
   47 at once is the risk). The callback is `(deviceId, tDeviceInfo)`;
   `deviceId` is 0 on failure (log and continue), and for a driver with a
   proxy `tDeviceInfo` carries the proxy and protocol ids [verified: API
   9/_0.1] in a shape the docs don't spell out, so the first callback's
   `tDeviceInfo` is logged in full and the protocol id is taken from it when
   present [assumed until seen on hardware]. Then `C4:Bind(bridgeId, 1,
   protocolId, 1, "HUE_BRIDGE")`, registry entry, `HUE_CONFIGURE`, full
   `HUE_STATE` (reason "resync").
3. Lights already registered: send `HUE_CONFIGURE` + state again (cheap,
   fixes a light that lost its persisted rid). Names are not renamed in
   Composer; a changed Hue name is logged.
4. Lights in the registry but gone from the bridge: logged, left alone.
5. `report(text)` after each step; the driver puts it in the `Lights`
   property: "Importing: fetching lights", "Importing: added <name> (k of
   n)", and finally "<on bridge> lights on bridge, <registry size> imported,
   <created this run> new"; before any import it shows "<registry size>
   imported".

State fan-out (`lights.on_container(container)`): for each item of type
`light` with a registered rid, `HUE_STATE` with the changed fields;
`zigbee_connectivity` items map device_rid → light rids → `HUE_STATE`
with `online`. `lights.resync(http_ctx)` after every stream connect: the
three GETs, then full `HUE_STATE` (reason "resync") to every registered
light, and `HUE_CONFIGURE` first at startup. `lights.hello(rid)` answers a
light.

## Bridge: command path (`bridge/commands.lua`)

`commands.new({ send = function(rid, body, done) end, now = ms clock })`:
- `q:set(rid, fields)` merges `fields` (`on`, `brightness`, `x`, `y`,
  `mirek`, `rate`) into the pending state for that rid, latest wins. Setting
  `x`/`y` clears `mirek` and vice versa (the bridge applies `xy` and ignores
  `mirek` if both are sent [verified: Core Concepts]).
- Debounce: a pending rid is flushed `DEBOUNCE_MS = 80` after its last
  change (one `C4:SetTimer` per rid), so a brightness and a colour command
  that arrive together become one PUT, as the light_v2 best-practice doc
  asks [verified].
- One PUT in flight per rid; changes made while in flight are sent after it
  returns. Global budget: token bucket, `RATE_PER_SEC = 10`, burst 10
  [verified: Hue guidance "around 10 commands per second to /light"].
- Body: `{"on":{"on":bool}}`, `{"dimming":{"brightness":n}}` (n clamped to
  [min_dim, 100]; brightness 0 means `on:false` and no `dimming`),
  `{"color":{"xy":{"x":..,"y":..}}}` or `{"color_temperature":{"mirek":n}}`
  (clamped to the light's mirek range), `{"dynamics":{"duration":ms}}` when
  `rate` > 0 [assumed: `dynamics.duration` is the transition field; confirm
  on hardware]. No arrays, so `C4:JsonEncode` is fine.
- `send` is `http.request` with method PUT to `/clip/v2/resource/light/<rid>`
  on the dotted address; `done(result)`. On 429 or 5xx: retry after
  `BACKOFF_MS = 500` doubling to 8 s; on 4xx other than 429: drop and log.
- The light's limits (`min_dim`, `mirek_min/max`) come from the registry's
  cached model; `q:limits(rid, {...})` sets them.

## Light driver (`src/hue_light`)

Modules under `src/hue_light/light/`: `state.lua` (cached Hue state, the
mapping both ways), `caps.lua` (capability notify), plus `driver.lua`.
Properties in `driver.xml`: `Hue Light ID`, `Hue Name`, `Model`, `Online`
("Online"/"Offline"/"" when unknown; read-only) alongside the existing
ones. `Status` reads "Not bound to a Hue Bridge", then "Bound; waiting for
the bridge", then "<Hue name> (<model>)" once configured. Persist `rid`
with `C4:PersistSetValue("hue_rid", rid)`. `C4:GetBoundProviderDevice` is
documented once as returning a table and once as a number [verified: API
32/_4 vs the idc_client sample]; accept both.

Proxy → bridge (`ReceivedFromProxy`, binding 5001):
- `SET_BRIGHTNESS_TARGET` { `LIGHT_BRIGHTNESS_TARGET`, `RATE` }
  [verified: sample light driver]: target 0 → `HUE_SET on=false`; else
  `HUE_SET on=true brightness=<target>`; `rate` passed through. Reply at
  once with `LIGHT_BRIGHTNESS_CHANGING` { `LIGHT_BRIGHTNESS_CURRENT`,
  `LIGHT_BRIGHTNESS_TARGET`, `RATE` } [verified], then
  `LIGHT_BRIGHTNESS_CHANGED` when the matching `HUE_STATE` arrives, or
  after `rate + 1000 ms` if it never does (so the UI never sticks).
- `SET_COLOR_TARGET` with xy and mode [assumed param keys:
  `LIGHT_COLOR_TARGET_X`, `LIGHT_COLOR_TARGET_Y`,
  `LIGHT_COLOR_TARGET_COLOR_MODE`, `LIGHT_COLOR_TARGET_RATE`; the docs print
  them with spaces, so log every param of the first one received]: mode 1
  (CCT) → `C4:ColorXYtoCCT(x, y)` → Kelvin → `mirek = 1000000 / K`, clamped;
  mode 0 → `x`, `y` as given (the bridge clamps to the gamut [verified]).
  If the light is off, store the colour and send nothing; apply it with the
  next turn-on (best practice [verified]). Reply `LIGHT_COLOR_CHANGING`,
  then `LIGHT_COLOR_CHANGED` on the matching state.
- Legacy, defensively: `ON` → target 100 (or the last on level),
  `OFF` → 0, `SET_LEVEL`/`RAMP_TO_LEVEL` { `LEVEL`, `TIME` } → the same path
  [assumed these may still arrive from old programming].
- `SYNCHRONIZE` → report cached state (brightness, colour, online).

Bridge → proxy (`ExecuteCommand` `HUE_STATE`/`HUE_CONFIGURE`):
- `HUE_CONFIGURE` → one `DYNAMIC_CAPABILITIES_CHANGED` notify carrying all
  of `supports_color`, `supports_color_correlated_temperature`,
  `color_correlated_temperature_min`, `color_correlated_temperature_max`
  (Kelvin = 1000000 / mirek_max and / mirek_min, rounded) [verified: the
  docs require both supports_* in a single notify]; properties updated.
- `HUE_STATE`: `on=false` → `LIGHT_BRIGHTNESS_CHANGED` 0; `on=true` with
  `brightness` → that value. Colour: mode "ct" → `C4:ColorCCTtoXY(1000000 /
  mirek)` and `LIGHT_COLOR_CHANGED` { `LIGHT_COLOR_CURRENT_X`,
  `LIGHT_COLOR_CURRENT_Y`, `LIGHT_COLOR_CURRENT_COLOR_MODE = 1` }; mode "xy"
  → the xy with mode 0. `online` → `ONLINE_CHANGED` { `STATE` }.
- Notify parameter names use underscores (`LIGHT_BRIGHTNESS_CURRENT` is
  verified in the sample driver; the colour ones follow the same pattern
  [assumed]).

## Dev loop for lights (`common/devloop.lua`, `tools/devserver.py`)

- The server serves two trees: `?tree=bridge` (default, `src/hue_bridge` +
  `common/`) and `?tree=light` (`src/hue_light` + `common/`), each with its
  own version in `/manifest`, `/bundle` and `/status`.
- The bridge's loop also polls the light tree. When its version changes, it
  fetches that bundle and sends `DEV_RELOAD` { `version`, `files` = JSON
  text } to every bound light (`GetBoundConsumerDevices`). [assumed: a
  40 KB string param survives `SendToDevice`; if not, chunk it.]
- A light driver that contains `common/devloop.lua` (dev build) registers
  `dispatch.commands["DEV_RELOAD"] = devloop.apply_forwarded` and reloads
  itself with the same sequence as the bridge, reporting through its own
  `print` (which the bridge does not see; a reload line in the light's Lua
  output is enough for now).
- `devctl.py status` shows both versions.

## Tests

`tests/helpers/fake_c4.lua` gains (coordinator-owned, done before the agents
start): `AddDevice` (immediate callback, ids from 2001), `Bind`,
`SendToDevice` (recorded; routed to another loaded driver when the harness
knows the id), `GetBoundConsumerDevices`, `GetBoundProviderDevice`,
`RoomGetId`, `RenameDevice` (recorded), `ColorCCTtoXY`/`ColorXYtoCCT`
(approximations good to a few percent), and `fake.pair(bridge_env,
light_env)` to bind two loaded drivers and pump messages between them with
`fake.pump()`. Specs for each module use `fake.install_c4()`; the end-to-end
round trip (import → bind → state → `SET_BRIGHTNESS_TARGET` → PUT body) lives
in `tests/spec/roundtrip_spec.lua`.

## File ownership for this change

| Owner | Files |
| --- | --- |
| Agent: model + import | `src/hue_bridge/bridge/hue_model.lua`, `bridge/lights.lua`, `tests/spec/hue_model_spec.lua`, `tests/spec/lights_spec.lua`, fixtures under `tests/fixtures/` |
| Agent: commands | `src/hue_bridge/bridge/commands.lua`, `tests/spec/commands_spec.lua` |
| Agent: light driver | everything under `src/hue_light/`, `tests/spec/light_*_spec.lua` |
| Agent: dev loop | `src/common/devloop.lua`, `tests/spec/devloop_spec.lua`, `tools/devserver.py`, `tools/devctl.py`, `docs/dev-loop.md` |
| Agent: docs | `docs/composer-checklist.md`, `docs/design.md` (only the sections it is told to), `docs/spike-checklist.md` |
| Coordinator | `src/hue_bridge/driver.lua`, `driver.xml`, `tests/helpers/fake_c4.lua`, `tests/spec/drivers_spec.lua`, `tests/spec/roundtrip_spec.lua`, `tools/build.sh`, `CLAUDE.md`, this file |
