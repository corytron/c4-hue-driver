# Bridge compatibility: the contract (2026-10-24)

Owner's ask: "handle the edge case that someone tries to use the wrong hue
bridge generation or device, or a supported bridge device with a firmware
that does not support all the APIs we're relying on here. also make sure to
note the user friendly name along with the Bridge Model in the properties."

## Facts

| Fact | Status |
| --- | --- |
| `GET /api/0/config` needs no key and answers `name` (the bridge's own name from the Hue app), `modelid`, `swversion` (a number such as `1968096020`), `apiversion` (`1.68.0`), `bridgeid`. The driver already reads it at pairing (`bridge/pairing.lua`) and before every keyed request (`verify_identity` in `driver.lua`). | verified on the house Bridge Pro |
| Model ids: `BSB001` the round first-generation bridge (no HTTPS CLIP v2, discontinued 2020), `BSB002` the square version 2 bridge, `BSB003` the Hue Bridge Pro. | BSB003 verified on the house; the others from Signify's public material [assumed] |
| CLIP v2 (`/clip/v2/...`, the event stream) exists from bridge software `1948086000` on; the first-generation bridge never had it. Time-of-day (smart) scenes and `dimming_delta` came later and are discovered at run time: a failed `/smart_scene` GET leaves the Scenes row at `? time-based` and the pickers without them, and a refused `stop` falls back to a level write. | the threshold from Signify's developer notes [assumed]; the fallbacks verified in specs |
| A device that is not a Hue bridge answers `/api/0/config` with an error, with no JSON, or with JSON without `bridgeid`; a Hue bridge of another generation answers with its `modelid`. | assumed |

## Decisions

1. **`bridge/config.lua`** knows the models: `config.model_label(modelid)` →
   "Hue Bridge Pro (BSB003)", "Hue Bridge v2, square (BSB002)", "Hue Bridge
   v1, round (BSB001)", "Hue bridge <id> (untested model)" for any other
   `BSB…`, "<id> (not a Hue bridge)" otherwise, "" for nil;
   `config.model_supported(modelid)` → true for BSB002, BSB003 and any
   other `BSB…` (new models are let through), false for BSB001 and for
   anything that is not a Hue bridge; `config.MIN_FIRMWARE = 1948086000`;
   `config.firmware_check(swversion)` → "ok", "old" or "unknown" (not a
   number); `config.firmware_label(swversion, apiversion)` → "1968096020
   (API 1.68.0)", with "; older than 1948086000, update the bridge in the
   Hue app" appended when old.
2. **Pairing refuses** before any key is requested: a model that is not
   supported ("This is a Hue Bridge v1, round (BSB001): it has no CLIP v2
   API; this driver needs a Hue Bridge v2 (square) or a Hue Bridge Pro" /
   "The device at <ip> is not a Hue bridge (model <id>)"), and firmware
   below the minimum ("Bridge firmware <sw> is older than 1948086000, the
   first with the CLIP v2 API; update the bridge in the Hue app, then pair
   again"). A probe that gets no usable answer reads "No Hue bridge answered
   at <ip>: <reason>". The driver prefixes all of them with "Pairing failed: ".
3. **Properties** `Bridge Model` shows the label ("Hue Bridge Pro (BSB003)");
   new read-only rows `Bridge Name` (the bridge's own name) and `Bridge
   Firmware` (the firmware label). All three are filled at pairing and
   refreshed at every start and address change by the identity check, so
   a firmware update shows after the next start.
4. **The identity check** (`verify_identity`) also refuses a bridge whose
   model is not supported, even when its id matches: Status "Bridge at <ip>
   is a Hue Bridge v1, round (BSB001): no CLIP v2 API; nothing is sent",
   no retry. Old firmware after pairing only warns in `Bridge Firmware` and
   the log; the APIs that fail degrade as before.
5. Manual: chapter 3 "What you need" (supported bridges, the minimum
   firmware, keep the bridge updated), chapter 4 (the new Status texts),
   chapter 5 (the three rows), chapter 12 (the refusals); README likewise.
