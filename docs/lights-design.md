# Lights: import, state and control

The contract between the bridge driver, the light driver, the dev loop and
the tests for representing Hue lights as Control4 `light_v2` devices. Read
`docs/design.md` for the facts behind it (one `C4:url` transfer per host
text, the padded stream spelling, Director's JSON quirks, the light_v2
best practices).

Status markers: [verified] = from the SDK docs or hardware; [assumed] = to be
confirmed on the controller through the dev loop.

**Current (2026-10-24):** built and verified on the house on 2026-10-21
(`docs/design.md`, "Lights: verified on hardware"), then extended by
`docs/import-design.md` (registry v2, more messages, the import actions,
light-side lifecycle), `docs/keypad-design.md` (Button Links, `HUE_DIM`,
keypad LEDs) and `docs/scenes-design.md` §6 (a third dev-loop tree). The
parts those changed are marked "Superseded" below; `docs/status.md`
describes the present (the house has no Hue Light device at the moment).

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

Superseded in part (2026-10-21/23): `HUE_HELLO` also carries `device_id`,
`name` and `model`, `HUE_CONFIGURE` also `hue_room`, `id_v1` and the gone
state, and `HUE_GOODBYE`, `HUE_FORGET` and `HUE_FORGOTTEN` were added
(`docs/import-design.md` §4); `HUE_DIM` carries keypad holds
(`docs/keypad-design.md`, "Light parity"); dev builds add `HUE_LOG`, a
light's log lines to the bridge.

Current (2026-10-25, build 316): `name` and `model` in `HUE_CONFIGURE` (and
`hue_room`) are display names (`util.display_name`;
`bridge/lights.lua:configure_params`, #217), and a dev build's `DEV_RELOAD`
carries `tree`, `version`, `bundle` (the signed payload) and `mac`
(`common/devloop.lua`, `docs/dev-loop.md`).

`ExecuteCommand` does not tell the receiver who sent a message, so `rid` is
in every message and the bridge maps rid → deviceId through its registry.

`C4:SendToDevice(id, command, params, allowEmptyValues, logCommand)`
[verified: API 32/_19]: empty-string values are dropped unless the 4th
argument is true, so receivers treat a missing `rid` as "unknown" (the
light sends `HUE_HELLO` without `rid` when it has none); and every call is
written to Director's log unless the 5th argument is false, so `DEV_RELOAD`
passes `false` there (its `files` param is tens of kilobytes).
Current (2026-10-25, build 316): every message the bridge sends to a device
passes the 5th argument true only while `Debug Mode` is On
(`hue_bridge/driver.lua:device_send`; `docs/review-leftovers-design.md`,
#51 R7).

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
Current (2026-10-25, build 316): a light, device, group or scene item whose
`id` is not a resource id (letters, digits and hyphens) is dropped with one
debug line (`bridge/hue_model.lua:light`, `devices`; #45).

Registry, persisted with `C4:PersistSetValue("hue_lights", table)` (tables
allowed) [verified: API 26.5]: `{ [rid] = { device_id = N, name = "...",
model = "...", caps = { has_color, has_cct, mirek_min, mirek_max, min_dim }
} }`, loaded at late init, written on every change (superseded 2026-10-21
by registry v2 with states and tombstones, `docs/import-design.md` §3). `caps` is what
`HUE_CONFIGURE` and the command queue's limits need, so both work at bridge
startup before any GET has completed; the resync refreshes it.
`model` is `product_data.product_name` (falling back to `model_id`).

Import (`lights.import(http_ctx, report)`), run from the **Import Lights**
action, serially (superseded 2026-10-21: `Import All New Lights` into each
light's mapped room, skipping unmapped and deleted ones, and `Add Light`
one at a time into a chosen room; a gone light becomes "gone"; results go
to `Last Action`; `docs/import-design.md` §3, §6, §13):
1. GET `/clip/v2/resource/light`, `/device`, `/zigbee_connectivity`.
2. For each light whose rid is not in the registry: `C4:AddDevice(
   "hue_light.c4z", roomId, name, callback)` with the bridge's room
   (`C4:RoomGetId()`), **one at a time** (next AddDevice from the callback;
   47 at once is the risk). The callback is `(deviceId, tDeviceInfo)`;
   `deviceId` is 0 on failure (log and continue), and for a driver with a
   proxy `tDeviceInfo` carries the proxy and protocol ids [verified: API
   9/_0.1]. On OS 3.4.2 the shape is the parsed-XML table style
   `{ Name = "devices", ChildNodes = { { Name = "protocol", Value = "1036" },
   { Name = "proxy", Value = "1037" } } }` and `deviceId` equals the
   protocol id [verified on hardware, Import Lights 2026-10-21]. The
   protocol id is bound; the proxy id is kept in the registry (`proxy_id`)
   so the bridge can address the light's `light_v2` proxy directly. Then `C4:Bind(bridgeId, 1,
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

Current (2026-10-25, build 316): the AddDevice chain is the shared
`bridge/owner.lua:create` and `register_added` (#56), and the name it gives
is the display name of the creation name, or "Hue light" when nothing of it
can be shown (`owner:new_device_name`, #217).

State fan-out (`lights.on_container(container)`): for each item of type
`light` with a registered rid, `HUE_STATE` with the changed fields;
`zigbee_connectivity` items map device_rid → light rids → `HUE_STATE`
with `online`. `lights.resync(http_ctx)` after every stream connect: the
three GETs (six since import-ui, with reconciliation before the fan-out,
`docs/import-design.md` §5), then full `HUE_STATE` (reason "resync") to
every registered light, and `HUE_CONFIGURE` first at startup.
`lights.hello(rid)` answers a light. Current (2026-10-25, build 316):
`resync(done)` and `hello(rid, params)` are `bridge/owner.lua`'s, shared
with the scenes and the zone lights (#56).

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
  on hardware]. No arrays, so `C4:JsonEncode` is fine. Verified 2026-10-21
  and 2026-10-23 (`docs/design.md`, "Color mapping"): the bridge accepts
  `dynamics.duration` on a light and on a grouped_light.
- `send` is `http.request` with method PUT to `/clip/v2/resource/light/<rid>`
  on the dotted address; `done(result)`. On 429 or 5xx: retry after
  `BACKOFF_MS = 500` doubling to 8 s; on 4xx other than 429: drop and log.
  (As built, a transport error without an HTTP code is retried the same
  way. Superseded 2026-10-25, #43: retries end 30 s after the pending
  state's last update (`commands.MAX_AGE_S`), with one warning, and "not
  paired" and "key rejected" are not retried at all.) Added later: a `dim` field for Hue's relative dim, with an optional
  `delta`, and a second instance for grouped_light PUTs with the same
  constants (`docs/keypad-design.md`, "Queue support";
  `docs/scenes-design.md` §5). Current (2026-10-25, build 316): `send` goes
  through `bridge_request` (`hue_bridge/driver.lua`), which answers at once,
  without a request, while `keyed_refusal` gives `not paired`,
  `TLS check failed` or `key rejected` (all three final:
  `bridge/commands.lua` `FINAL_ERRORS`) or the bridge identity is not
  verified yet (retried like a transport error). The grouped_light instance
  runs at one PUT a second with a burst of 3, not the same constants, and in
  both queues a hold's start and stop skip the bucket (`new_group_queue`,
  `commands.urgent`; `docs/zone-light-design.md` Decision 9).
- The light's limits (`min_dim`, `mirek_min/max`) come from the registry's
  cached model; `q:limits(rid, {...})` sets them.

## Light driver (`src/hue_light`)

Modules under `src/hue_light/light/`: `state.lua` (cached Hue state, the
mapping both ways), `caps.lua` (capability notify), plus `driver.lua`.
Properties in `driver.xml`: `Hue Light ID`, `Hue Name`, `Model`, `Online`
("Online"/"Offline"/"" when unknown; read-only) alongside the existing
ones (`Hue Room` and `Last Action` added by `docs/import-design.md` §7).
`Status` reads "Not bound to a Hue Bridge", then "Bound; waiting for
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
  then `LIGHT_COLOR_CHANGED` on the matching state. Verified 2026-10-22
  (`docs/design.md`, "Hardware pass of 2026-10-25 night"): the mode arrives
  as `LIGHT_COLOR_TARGET_MODE`, 1 for a Navigator temperature pick and 0 for
  a colour pick; the driver reads both mode spellings
  (`src/hue_light/driver.lua`, `COLOR_KEYS`).
- Legacy, defensively: `ON` → target 100 (or the last on level),
  `OFF` → 0, `SET_LEVEL`/`RAMP_TO_LEVEL` { `LEVEL`, `TIME` } → the same path
  [assumed these may still arrive from old programming]. As built, `ON`
  always means 100 % (never the last level) and `TOGGLE` goes to 100 or 0.
- `SYNCHRONIZE` → report cached state (brightness, colour, online).

Bridge → proxy (`ExecuteCommand` `HUE_STATE`/`HUE_CONFIGURE`):
- `HUE_CONFIGURE` → one `DYNAMIC_CAPABILITIES_CHANGED` notify carrying all
  of `supports_color`, `supports_color_correlated_temperature`,
  `color_correlated_temperature_min`, `color_correlated_temperature_max`
  (Kelvin = 1000000 / mirek_max and / mirek_min, rounded) [verified: the
  docs require both supports_* in a single notify]; properties updated.
- `HUE_STATE`: `on=false` → `LIGHT_BRIGHTNESS_CHANGED` 0; `on=true` with
  `brightness` → that value rounded to a whole percent, at least 1. Hue
  reports its Zigbee level as a decimal percent (a requested 20 comes back
  as 20.16) and the proxy showed such a value as 0 %/off on OS 3.4.2 even
  though the proxy-protocol reference types `LIGHT_BRIGHTNESS_CURRENT` as a
  double [verified on hardware]. Colour: mode "ct" → `C4:ColorCCTtoXY(1000000 /
  mirek)` and `LIGHT_COLOR_CHANGED` { `LIGHT_COLOR_CURRENT_X`,
  `LIGHT_COLOR_CURRENT_Y`, `LIGHT_COLOR_CURRENT_COLOR_MODE = 1` }; mode "xy"
  → the xy with mode 0. `online` → `ONLINE_CHANGED` { `STATE` }.
- Notify parameter names use underscores (`LIGHT_BRIGHTNESS_CURRENT` is
  verified in the sample driver; the colour ones follow the same pattern
  [assumed]).

## Dev loop for lights (`common/devloop.lua`, `tools/devserver.py`)

Superseded in part (2026-10-21/22): a third tree for the scene driver was
added (`docs/scenes-design.md` §6), a dev build's light forwards its log
lines to the bridge as `HUE_LOG`, and the house has run release builds
without the dev loop since 2026-10-22 (`docs/dev-loop.md`).

- The server serves two trees: `?tree=bridge` (default, `src/hue_bridge` +
  `common/`) and `?tree=light` (`src/hue_light` + `common/`), each with its
  own version in `/manifest`, `/bundle` and `/status`.
- The bridge's loop also polls the light tree. When its version changes, it
  fetches that bundle and sends `DEV_RELOAD` { `version`, `files` = JSON
  text } to every bound light (`GetBoundConsumerDevices`). [assumed: a
  40 KB string param survives `SendToDevice`; if not, chunk it. Verified
  2026-10-21: it reached all 47 lights, `docs/design.md`, "Lights: verified
  on hardware".]
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
