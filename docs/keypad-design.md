# Keypad buttons on Hue Light and Hue Scene devices: the contract

Owner's request (2026-10-22): a Control4 Switch V2 or Essential Switch run
as a 2-button keypad with "Buttons Control Load" off (the switch's own load
programmed to 100 %) must drive a Hue Light through the light's Button Link
inputs: tap top = on, tap bottom = off, hold = dim up or down, like a
Control4 dimmer, and the stock Philips driver did this. Source for every
proxy claim: `~/c4-tools/reference/docs-driverworks-proxyprotocol-lightv2`
(cloned from Snap One's repository on 2026-10-22).

## What the proxy does [verified: BUTTON_ACTION command and notification]

- The light_v2 proxy creates the Top, Bottom and Toggle Button Link consumer
  connections itself and forwards every `BUTTON_ACTION` it receives on them
  to the protocol driver: `BUTTON_ID` 0 top, 1 bottom, 2 toggle; `ACTION`
  1 press, 2 release as a click, 0 release after a hold.
- The driver must send a `BUTTON_ACTION` notification back with the same
  values for every press and release; without a press notification the
  proxy generates a second press when it sees a click, and without a
  release later presses stop working.
- "On" preset: `SET_PRESET_LEVEL {LEVEL}` arrives when the proxy's On
  preset changes, for drivers declaring `supports_default_on` (deprecated
  in favour of the on-mode preset capability, but the documented path for
  this command; the two must not be combined) **[assumed until seen on
  hardware]**.
- Rates: `SET_CLICK_RATE_UP/DOWN` and `SET_HOLD_RATE_UP/DOWN {RATE ms}`
  arrive when the dealer edits them in Composer; the properties appear only
  for drivers declaring `click_rates` and `hold_rates`.

## Driver behaviour

Hue Light (`src/hue_light/driver.lua`):

| Input | Behaviour |
|---|---|
| press (any button) | echo the notification; start a 400 ms hold timer |
| click top | brightness target = On preset over click rate up |
| click bottom | target 0 over click rate down |
| click toggle | off → preset over click up; on → 0 over click down |
| hold (timer fired before the release) | ramp to 100 (top, or toggle while off) or to 1 (bottom, or toggle while on) over the hold rate scaled by the distance; a 100 ms tick keeps an estimate of the level |
| release after hold | stop: a brightness target at the estimated level with rate 0 (Hue has no stop request) |
| release-as-click after a ramp started | same as stop |

Settings persist per device (`preset_level`, `click_rate_up`,
`click_rate_down`, `hold_rate_up`, `hold_rate_down`); defaults 100 %,
250 ms, 250 ms, 5000 ms, 5000 ms. `ON` and `TOGGLE` from programming keep
going to 100 % (unchanged; the preset is a keypad matter until the on-mode
preset API is adopted).

Hue Scene (`src/hue_scene/driver.lua`): echo every action; click or release
of top = recall (ON), bottom = OFF, toggle = toggle; holds do nothing.

`driver.xml` (light): `click_rates`, `hold_rates`, `supports_default_on`
true; `click_rate_min` 0, `hold_rate_min` 1000. Scene: unchanged.

## Verification

Specs in `tests/spec/light_driver_spec.lua` and `scene_driver_spec.lua`
(tap, preset, hold and release, echo notifications, persisted rates).
Hardware: bind a switch's buttons to a light's Button Links in Composer's
Connections (a drag; by hand), tap and hold; the manual's chapter "Using
the lights from Control4" describes the setup.

## Hardware findings (2026-10-22, builds 144 and 146 installed)

The proxy creates only the "Brightness Stop" and "Color Stop" Button Links
from the capabilities; the Top, Bottom and Toggle Button Links are
connections the **protocol driver declares itself** (ids 200, 201, 202,
class BUTTON_LINK, provider side, shown under the light's Control Outputs
in Composer), and a bound keypad button delivers `DO_PUSH`, `DO_RELEASE`
and `DO_CLICK` on that binding id rather than `BUTTON_ACTION` [verified:
public light_v2 drivers on GitHub; the SDK's jumpstart template calls the
base id "ButtonLinkBindingIDBase"]. Both drivers now declare the three
connections and route the binding commands into the same button logic;
`BUTTON_ACTION` on the proxy binding stays as the proxy's own route.

Install behaviour seen on the house (build 141 → 144 → 146):

- 144 changed the light's **capabilities** (`click_rates`, `hold_rates`,
  `supports_default_on`): Composer asked "Restart Director?" for
  `hue_light.c4z`. After the restart the bridge ran 144, but the existing
  light device still reported 141 and read "Not bound to a Hue Bridge"
  although Composer showed it bound; a right-click Update Driver ("Versions
  are equal", overwrite) did not change it. A device re-created under 144
  reported a blank Driver Version until a second per-device overwrite
  brought it to 144.
- 146 added the three Button Link **connections**: no restart prompt; the
  existing device showed Top, Bottom and Toggle Button Link under Control
  Outputs at once and read 146. **Existing devices pick up new connections
  on an ordinary "Add or Update Driver or Agent…"; nothing has to be
  re-created.**
- The links are outputs of the light (provider side); a keypad button's
  output is bound to them in Connections by hand.

Open: the light reading "Not bound" while bound after a Director restart
suggests the binding is not yet visible to `GetBoundProviderDevice` at late
init after a restart, and the light never looks again until a binding
event. Fixed on branch `binding-recheck`: when unbound at late init, the
light and scene drivers look again at 5, 15, 30 and 60 s, greet the bridge
as soon as the binding is visible, and stop on a binding event, on destroy,
or after the last check.

Tested on the house with build 150 (2026-10-22 19:12–19:23): Composer has
no Director restart command and System Manager runs elevated, out of the
Windows session's reach, so the owner rebooted the controller by hand from
System Manager. Composer lost Director at 19:12:58 and was idle again at
19:20:35; the bridge's event feed was back at 19:19:28. The light read
"Right Bedside Light (Hue color lamp)", Online, version 150 at all 19 reads
between 19:21:03 and 19:22:33 and never "Not bound". Whether the re-check
ran or the binding was visible at late init cannot be told from Composer
(its Lua pane does not replay startup lines). Note the original failure
followed a Director restart forced by a driver update, not a reboot; the
outcome after a reboot is verified, the re-check path itself is not.

## Scene hold-to-dim and keypad LEDs (owner-approved 2026-10-23)

The owner's use case is a Hue **scene** on two Control4 switches run as
2-button keypads (top button → the scene device's Top Button Link, bottom →
Bottom Button Link). Taps work; this section adds holding to dim and LEDs
that follow the scene. Approved as proposed, including "the scene stays on
through dims from its own buttons".

### Messages (new or extended)

| Message | Direction | Params (all strings) | Meaning |
|---|---|---|---|
| `HUE_SCENE_DIM` | scene → bridge | `rid`, `device_id`, `direction` (`up` / `down` / `stop`), `duration` (ms, up/down only) | Dim the scene's group: one grouped_light PUT `{"dimming_delta":{"action":"up"/"down","brightness_delta":100},"dynamics":{"duration":<ms>}}` to start, `{"dimming_delta":{"action":"stop"}}` to stop. Relative, so the scene's colours and per-light differences are kept. **[assumed: `stop` and `dynamics` on grouped_light; verify on the first hardware test]** |
| `HUE_SCENE_RECALL` | scene → bridge | adds optional `brightness` (1–100) | Recall with `recall.dimming.brightness` override (used for "hold top while off": recall at 1 %). |
| `HUE_SCENE_GROUP` | bridge → scene | `rid`, and `on` (`true`/`false`) and/or `other_active` (`true`) | The scene's room/zone grouped_light turned on/off (from the event feed or the resync), or another scene of the same group became active. Sent at resync (current `on`) and on change. |

### Bridge (`src/hue_bridge/bridge/scenes.lua`)

- `scenes:dim(params)` resolves the device's entry like recall/off
  (`entry_for_command`), finds the scene's group's `grouped_light_rid`
  and calls `ctx.group_dim(grouped_rid, body)`; returns true when queued.
  `duration` is clamped to 0–6 000 000. Gone scene or no grouped_light:
  log and return false.
- `scenes:recall` passes a valid `brightness` param as
  `body.recall.dimming = { brightness = n }`.
- Group on/off: the module keeps `group_on[grouped_rid]` from the resync
  (one extra GET `/clip/v2/resource/grouped_light` in `fetch_all`) and from
  `grouped_light` items in `on_container` (`item.on.on`). On a change it
  sends `HUE_SCENE_GROUP {rid, on}` to every linked scene device whose
  group owns that grouped_light; after each resync it sends the current
  value to every linked device.
- Other scene active: when a scene status event makes scene B `static` or
  `dynamic_palette`, every other linked scene device of B's group gets
  `HUE_SCENE_GROUP {rid, other_active = "true"}`.

### Coordinator (`src/hue_bridge/driver.lua`)

`ctx.group_dim(rid, body)` → `state.group_queue:set(rid, body)` (returns
true when queued); `dispatch.commands["HUE_SCENE_DIM"]` →
`state.scenes:dim(params)`.

### Scene device (`src/hue_scene/driver.lua`)

- **On state**: `effective_on = is_on() or dimmed_on`. `dimmed_on` is set
  when a hold-dim starts from this device's own buttons (or a hold-recall
  from off); it keeps the tile and LEDs on when Hue then reports the scene
  inactive. Cleared by `HUE_SCENE_GROUP on=false`, by `other_active`, by
  this device's OFF / bottom tap / toggle-off, and replaced by a normal
  recall. `LIGHT_BRIGHTNESS_CHANGED` is 100/0 from `effective_on`.
- **Hold** (DO_PUSH on 200/201/202 or BUTTON_ACTION press, still down after
  400 ms): top (or toggle while off) → if on, `HUE_SCENE_DIM up` with the
  hold-up rate; if off, `HUE_SCENE_RECALL {brightness=1}` then
  `HUE_SCENE_DIM up` 600 ms later. Bottom (or toggle while on) → if on,
  `HUE_SCENE_DIM down` with the hold-down rate; if off, nothing. Release
  after a hold → `HUE_SCENE_DIM stop`. Hold rates persist
  (`SET_HOLD_RATE_UP/DOWN`), default 5000 ms; `driver.xml` declares
  `hold_rates` True, `hold_rate_min` 1000.
- A click arriving within 1 s after a hold's release on the same button is
  ignored (some keypads may send it).

### Keypad LEDs (both device drivers) [verified: Snap One's
`drivers-template-code-public` `c4hook_light_v2.lua`]

- On every on/off change, at late init, and when a keypad binds to a link:
  `C4:SendToProxy(b, "MATCH_LED_STATE", { STATE = <boolean on> }, "COMMAND")`
  for b = 200, 201, 202, and `BUTTON_INFO {BUTTON_ID, ON_COLOR, OFF_COLOR,
  CURRENT_COLOR}` to the proxy binding 5001 as a NOTIFY.
- Button colours persist per button; defaults top `0000ff`/`000000`, bottom
  `000000`/`0000ff` (lit when off), toggle `0000ff`/`000000`.
  `SET_BUTTON_COLOR {BUTTON_ID, ON_COLOR | OFF_COLOR}` from the proxy stores
  one, then sends `BUTTON_COLORS` on that link and `BUTTON_INFO` to 5001.
  `REQUEST_BUTTON_COLORS` arriving on a link answers `BUTTON_COLORS` on that
  link, then `MATCH_LED_STATE`.
- The light driver gets the same LED and colour handling (on = `st.on`) and
  the same 1 s click suppression after a hold.

The switch's own "LED Behavior" may need its option that follows the bound
device instead of "Push/Release" (owner checks on the switch).

Both `driver.xml` declare `has_leds` True so Composer offers the button LED
colour settings (which arrive as `SET_BUTTON_COLOR`); the scene's also
declares `hold_rates` True with `hold_rate_min` 1000. Both are capability
changes, so installing this build is expected to ask for a Director
restart, as build 144 did.

### Light parity (owner, 2026-10-23: "whatever capabilities we implement for scenes get intelligently carried over to the individual light driver as well")

- Holds on a Hue Light use the same native relative dim as the scene:
  `HUE_DIM {rid, direction up|down|stop, duration, level}` → the light's
  queue sends `dimming_delta` up/down with `dynamics.duration`, then a bare
  `stop`. The device keeps its 100 ms estimate and sends it as `level` with
  the stop; the proxy's tile settles on the bridge's next report, or on the
  estimate after the fallback time.
- Hold top (or toggle) while the light is off: on at 1 %, then dim up
  600 ms later. Hold bottom while off: nothing (it used to turn the light
  on dimmed).
- LED state, button colours, `has_leds`, hold rates and the 1 s click
  suppression after a hold are the same in both drivers.

### Queue support (`src/hue_bridge/bridge/commands.lua`)

A `dim` field (`up`/`down`/`stop`) builds the `dimming_delta` body; a dim
replaces a pending brightness or on/off and vice versa. If the bridge
refuses a stop with a non-retriable error, the queue writes a fallback
brightness: the stop's `level` (lights), else the group level recorded at
the ramp's start (`scenes.group_level`, from grouped_light reports) moved by
the elapsed share of the ramp (scenes). Without either the ramp runs to its
end and a warning is logged.
