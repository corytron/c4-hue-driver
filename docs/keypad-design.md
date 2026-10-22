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
