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
event. A delayed re-check (a few seconds after late init when unbound) is
the proposed fix; not yet built.
