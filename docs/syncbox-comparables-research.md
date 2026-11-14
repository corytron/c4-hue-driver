# Sync box research: comparable integrations and Hue's own app (#514)

**Status (2026-11-13): research for issue #514 (2.0, Hue Play HDMI Sync
Boxes in Control4); nothing here is approved or built.** Research file of
agent R6 (comparables), one of six written at the same time. It answers four
questions: which Control4 drivers for the box exist and what owners say about
them (§2), how other ecosystems integrate the box (§3), what Hue's own app
and the box offer, so that nothing an owner expects is missing (§4), and the
lessons (§5). It ends with recommendations (§6) and the owner's choices (§7).

Method: web research only; no LAN host was contacted. Every claim is marked
**[verified: source]** (read on the page, in the PDF or in source code fetched
for this file) or **[assumed]** (seen only in a search-result snippet, on a
page that refused automated fetches, or an inference of this file). Forum
posts are flagged as such, with their dates. Sources are labelled and listed
with their full URLs at the end. Quotations are limited to one short phrase
per source; everything else is paraphrase. The C4 Forums and Automated Now
pages refused automated fetches (HTTP 403), so what they say is marked
assumed; the driver's integration guide hosted by Automated Now was read in
full.

## 0. The device family, as of 2026-11

The issue says "4K and 8K models", but there are now three HDMI boxes and a
camera, and the comparables treat them differently:

| Model id | Product | HDMI inputs | Notes |
|---|---|---|---|
| HSB1 | Play HDMI Sync Box (the original 4K; firmware notes from 2019 [verified: [hue-rn]]) | 4 | HDMI 2.0; Dolby Vision compatibility and per-input HDR settings exist only here [verified: [aio-behavior], [ha-switch]] |
| HSB2 | Play HDMI Sync Box 8K (2024 [assumed: launch news seen in search results only]) | 4 | HDMI 2.1, 8K60 and 4K120, eARC passthrough [verified: [hue-8k], [hue-arc]] |
| HSB3 | Play HDMI Sync Box 4K (new, launched 2026-09-03) | 1 | Slim, one input, 4K60; can pair one Play gradient TV strip over Bluetooth without a bridge [verified: [nbc-launch], [hb-4k-review]] |
| HSC001 | Play Screen Sync (camera, launched the same day) | 0 | Reads the screen with a camera; same API family, no power switch in Home Assistant [verified: [nbc-launch], [ha-helpers], [ha-switch]] |

The model ids come from Home Assistant's integration, which supports all
four [verified: [ha-readme], [ha-helpers]]. The new HSB3 and the camera also
have a **standalone** operating mode without a bridge, in which Home
Assistant hides the entertainment-area selector [verified: [ha-select],
[ha-helpers]].

## 1. Findings

1. **One commercial Control4 driver exists**: Janus Technology's "Philips
   Hue HDMI Sync Box" on DriverCentral, MSRP $100, version 103 of
   2025-08-20 [verified: [janus-dc]]. It is an **AV switch proxy** for the
   inputs plus UI buttons, a relay, keypad button links and a light proxy
   for sync brightness; modes and intensities are **cycled**; entertainment
   areas came in version 102 [verified: [janus-dc], [janus-guide]]. Nothing
   else turned up for Control4: Chowmain, Whistle Projects, Domosapiens,
   Annex4, Blackwire and Extra Vegetables sell Hue *light* drivers only
   [assumed: no sync box driver found in their listings or in searches].
2. **Everyone who models routing treats the box as a 4x1 HDMI switch**:
   Janus (AV switch proxy), Intrinsic Dev for ELAN (a "4×1 HDMI matrix")
   [verified: [janus-guide], [elan-intrinsic]], and a 2023 C4 Forums thread,
   written before any driver existed, where the advice was a generic HDMI
   switch driver [assumed: [c4f-42053], search snippet].
3. **The best open-source integration split one "media player" into
   separate controls.** Home Assistant's huesyncbox dropped its media_player
   entity in v2.0 for a power switch, a light-sync switch and selectors for
   input, mode, intensity, entertainment area and brightness; its maintainer
   said the media-player mappings made it unclear how to use [verified:
   [ha-readme], [ha-issue-65]]. It also offers one combined action that sets
   everything in the right order, because intensity applies to the mode
   that is current [verified: [ha-readme]].
4. **Entertainment areas are a per-box selection everywhere, never a room.**
   No comparable maps an area to a room: Janus sets or cycles it, Home
   Assistant selects it by name from the box's list, Homebridge offers an
   optional selector; Homey, openHAB, Hubitat and Google Home do not offer
   it at all [verified: [janus-dc], [ha-select], [hb-syncbox], [homey-hue],
   [oh-huesync], [hubitat-thread], [g-home]]. A bridge (Bridge Pro included)
   syncs **one area at a time** [verified: [hue-bpro], [hb-bpro]].
5. **Input switching is where the box fights a controller.** The box
   switches inputs by itself (hot-plug and per-input CEC) and starts sync by
   itself (per-input auto-sync) [verified: [aio-behavior], [netzwelt]].
   Hueblog's advice for universal remotes is to turn the box's automatic
   switching off [verified: [hb-harmony]]; always-on sources (Apple TV,
   Chromecast) defeat it anyway [verified: [hb-problems], [ha-issue-22]].
6. **"Off" is ambiguous.** The box has *passthrough* (picture passes, no
   sync) and *powersave* (HDMI reported inactive) [verified: [aio-execution]].
   Homebridge's off defaults to passthrough [verified: [hb-syncbox]]; a Home
   Assistant user found that the power switch disturbed other devices, with
   CEC suspected (forum, 2026-07) [verified: [ha-forum-p7]].
7. **Everybody polls.** Home Assistant every 3 s, Homebridge 5 s, openHAB
   10 s, Janus a configurable interval [verified: [ha-readme], [hb-syncbox],
   [oh-huesync], [janus-guide]]; no comparable uses a push channel from the
   box [assumed: none documents one].
8. **Hue's app has more settings than any integration exposes**: per-input
   names and device types, CEC and hot-plug switching, auto-sync per input,
   power-save rules, ARC bypass, an AV-receiver "solo" mode, Dolby Vision
   compatibility, LED brightness, IR learning, presets on the box, and the
   area's light state after sync [verified: [aio-behavior], [aio-presets],
   [aio-ir], [ha-select], [hue-bpro]]. Comparables expose the everyday
   controls and leave the wiring settings to the Hue app; Google Home says
   so outright [verified: [g-home]].
9. **The box speaks neither Matter nor HomeKit natively**: Hue's Matter page
   excludes it [verified: [hue-matter]]; reviews say it is not a HomeKit
   device [verified: [macrumors], [phk-blog]], although the 8K product page
   lists Apple Home and Matter among compatible systems [verified: [hue-8k];
   the conflict is unresolved]. HomeKit users go through Homebridge.
10. **While sync runs, the area's lights ignore normal control**: the Hue app
    cannot control them [verified: [macrumors]]. Control4 keypads and scenes
    for those lights will seem dead during a movie unless the design says
    what happens.

## 2. Control4 drivers

### 2.1 Janus Technology, "Philips Hue HDMI Sync Box" (DriverCentral)

| Aspect | What it does | Source |
|---|---|---|
| Vendor, price, licence | Janus Technology; MSRP $100 on DriverCentral, 30-day return; DriverCentral cloud properties (Cloud Status, Automatic Updates); a reseller lists $125 plus programming | [verified: [janus-dc], [janus-guide]]; reseller price [assumed: [an-listing], snippet] |
| Versions and OS | v100 2023-12-08 (OS 3.4.0, EA1); v101 2023-12-22 light proxy for brightness; v102 2024-01-18 entertainment areas (OS 3.4.1); v103 2025-08-20 light-theme icons, tested on OS 4.0.0 with an EA3 | [verified: [janus-dc]] |
| Pairing | Enter the box's IP (from the Hue app's sync device network info); press the box's button for 3 s until the LED blinks green | [verified: [janus-guide]] |
| Inputs and routing | AV switch proxy: bind its inputs to the sources wired to the box, its output to the TV, its room connections to the TV's room; Control4 then routes through it | [verified: [janus-guide]] |
| Sync on/off | UI button, relay connection, keypad button link, action "Toggle Sync State", command "Set Sync State" | [verified: [janus-guide]] |
| Mode and intensity | UI buttons and keypad links that **cycle** (Video, Music, Game; Subtle to Intense); pressing either while sync is off starts sync first; commands set them directly | [verified: [janus-guide]] |
| Brightness | A light proxy: on, off, toggle and level, usable in Advanced Lighting Scenes; 50 % is the box's neutral 100 %, above it mixes in white | [verified: [janus-guide]] |
| Entertainment area | Set or cycle by UI button, keypad link or command | [verified: [janus-dc]] |
| Navigator | The three UI buttons are shown in the room's Watch menu (Composer: Navigator, Watch, Modify, Show) | [verified: [janus-guide]] |
| Programming | Events Sync Active and Inactive; variables Sync State, Sync Mode, Sync Intensity; conditionals on the same | [verified: [janus-guide]] |
| Properties | Operational Mode, Poll Interval, Firmware Version, Active Source, Sync Mode, Sync Brightness (0 to 200 %), debug | [verified: [janus-guide]] |
| Not mentioned | Power/powersave, input names, input status, auto-switching settings, Dolby Vision, LED, IR, presets, model differences, bridge link status, an input-changed event | [verified: absent from [janus-guide] v101 and [janus-dc] v103] |

The reseller describes automatic input switching that activates the desired
sync mode [assumed: [an-listing], snippet]; the guide documents no such
link between input and mode [verified: [janus-guide]].

### 2.2 Searched, nothing for the sync box

- **Chowmain**: a Philips Hue driver for lights, motion and contacts; no
  sync box [assumed: reseller snippets; the listing refused the fetch].
- **Whistle Projects**: the Ultimate Pack bundles Kinetic, Button,
  Lighting, Security and Wall Switch packs; no sync box or entertainment
  [verified: [whistle-ultimate]].
- **Domosapiens, Annex4, Blackwire, Extra Vegetables, Control4 itself**: no
  sync box driver found [assumed: searches only].

### 2.3 What dealers and owners say

Thin. DriverCentral shows no reviews of the Janus driver [verified:
[janus-dc]], and no forum thread about it was found [assumed]. Before it
existed, a 2023 C4 Forums owner could not make connections work without the
TV changing input, and was told to use a generic switch driver or build a
4x1 driver from IR codes [assumed: [c4f-42053], snippet]. In a general C4
Forums thread on ARC, members warn that CEC switches inputs and powers
devices behind Control4's back, so its state drifts [assumed: [c4f-36113],
snippet].

## 3. Other ecosystems

### 3.1 Feature matrix

| Integration | Input | Power | Sync on/off | Mode | Intensity | Brightness | Area | Other |
|---|---|---|---|---|---|---|---|---|
| Janus, Control4 | AV switch proxy | not documented | yes, many surfaces | cycle and set | cycle and set | light proxy | set and cycle | events, variables |
| Intrinsic Dev, ELAN (2020) | 4x1 switcher | ? | ? | ? | ? | ? | ? | "entertainment control" like the Sync app, details not listed; licence per controller [verified: [elan-intrinsic]] |
| Home Assistant huesyncbox | select by input name, only with 2+ inputs | switch (passthrough vs powersave), not on the camera | switch | select | select | number 1 to 100 % | select by name | DV switch (HSB1), LED select, input status, hidden diagnostics, combined action, change bridge [verified: [ha-readme], [ha-select], [ha-switch], [ha-number]] |
| openHAB hueSync | channel | in the mode channel | switch (off means passthrough) | channel incl. powersave and passthrough | not documented | 0 to 200 | not documented | per-input name, type, status; firmware [verified: [oh-huesync]] |
| Homebridge (HomeKit) | TV accessory | optional switch | lightbulb or switch | TV accessory | TV accessory | lightbulb | TV accessory | configurable on and off modes; remote-widget mapping [verified: [hb-syncbox]] |
| Homey (Athom's Hue app) | action and trigger | yes | yes | no | no | dim | no | users script the API for mode [verified: [homey-hue], [homey-mode]] |
| Hubitat (community, 2020) | dropdown, no names | no | via mode | yes | per mode | no | no | reboot command [verified: [hubitat-thread]] |
| Google Home | source | yes | light sync | yes | yes | no | no | no settings [verified: [g-home]] |
| Crestron, Savant, URC, RTI, Josh.ai | none found | | | | | | | RTI's Hue driver targets the bridge [assumed: searches only] |

### 3.2 UX choices worth noting

- **Home Assistant** gates every control on what the model has: no input
  selector with fewer than two inputs (so none on HSB3), no area selector
  in standalone mode, the Dolby Vision switch only on HSB1, no power switch
  on the camera [verified: [ha-select], [ha-switch]]. Diagnostics (bridge
  connection state, bridge id, IP, Wi-Fi quality, content info) exist but
  are disabled by default [verified: [ha-readme]]. Inputs and areas are
  shown and set **by name**; an area given to the combined action must match
  exactly [verified: [ha-select], [ha-readme]]. When the box answers a
  change with an invalid-state error, which its code attributes to another
  application streaming, it **stops whichever area is active and
  retries**, logging the owner [verified: [ha-helpers]]. Brightness 1
  to 100 % maps linearly onto the box's 0 to 200 [verified: [ha-helpers]];
  owners asked for relative steps for a rotary dial (2026-01) [verified:
  [ha-issue-167]]. A 2021 request for per-input signal status came from an
  always-on Chromecast that kept the box from switching; it was added as
  attributes and device triggers, and the status reads "linked" only while
  the box is awake [verified: [ha-issue-22]]. One user's 8K box failed
  certificate verification (2024, still open) [verified: [ha-issue-128]].
- **Homebridge** shows how HomeKit owners want it: a lightbulb whose on/off
  starts sync in a chosen default mode (video or the last one) and whose off
  goes to passthrough by default (powersave optional), plus optional
  TV-style selectors for input, mode, intensity and area. Changing its seed
  recreates every accessory and breaks automations [verified: [hb-syncbox]].
- **Homey's** official Hue app covers power, input, dim and sync on/off only;
  a 2025 forum post still asks for mode control and shows a script against
  the box's API that skips certificate checks [verified: [homey-hue],
  [homey-mode]].
- **Hubitat** (2020): responses took 2 to 3 s; the box then ignored network
  commands in standby, and the author rebooted it every three days because
  it hung every week or so. Custom input names were impossible in a fixed
  dropdown [verified: [hubitat-thread]]; 2020 firmware, so the standby and
  hang reports may be stale [assumed].
- **openHAB** pairs like Janus: start registration, press the box's button
  for 3 s; a blue LED means the box must first be set up in the Hue app
  [verified: [oh-huesync]].

## 4. Hue's own app and the box: the checklist

Sync box control moved into the Hue app's Sync tab with version 4.31
(2022-11) [verified: [hb-app]]. What the app and the box offer, by topic:

| Topic | What Hue offers | Models | Exposed by comparables | Source |
|---|---|---|---|---|
| Inputs and names | Each input gets a name at setup and a device type (Apple TV, PlayStation, AV receiver and about twenty more); status unplugged, plugged or linked | all (HSB3 one input) | HA and openHAB show names and status; Janus shows the active source only | [verified: [hue-setup], [aio-enums], [oh-huesync], [ha-issue-22]] |
| Modes | Video, Music, Game; plus passthrough and powersave as box states; Video and Game have a background-lighting toggle; Music has five palettes | all | mode everywhere except Homey; background lighting and palettes nowhere | [verified: [aio-execution], [aio-enums]] |
| Intensity | Subtle, Moderate, High, Intense, stored per mode | all | most | [verified: [aio-execution], [ha-readme]] |
| Brightness | 0 to 200, 100 neutral, above 100 boosts with white | all | most | [verified: [aio-execution], [janus-guide]] |
| Auto-sync | Start sync when a video signal appears, chosen per input | all | none | [verified: [netzwelt], [aio-behavior]] |
| Input follows | Switch input when a source is plugged in or powered (any input, or per input since API level 10) and when a source sends CEC active (per input) | all | none | [verified: [aio-behavior]] |
| CEC and TV power | Box wakes with the TV (CEC power-state detection); TV off by CEC, or TV USB power gone, puts the box in powersave; powersave after N minutes without signal (default 20); firmware stops the TV switching inputs when the box enters or leaves powersave | USB rule HSB1 and HSB2 | none | [verified: [phk-blog], [aio-behavior], [hue-rn]] |
| Receivers | ARC bypass (only when the box sits between receiver and TV); solo mode for a receiver's second output (API level 14); 8K passes eARC | ARC bypass all; eARC 8K | none | [verified: [aio-behavior], [hue-arc]] |
| Dolby Vision | "Enhanced compatibility" forces player-led Dolby Vision so the box can read it; per-input HDR mode (auto, force SDR, force HDR) | HSB1 only | HA (DV switch) | [verified: [phk-blog], [aio-behavior], [ha-switch]] |
| Presets | Stored on the box: a name of up to 24 bytes and a set of execution values; recall by id | API | iConnectHue (brightness, area, mode, intensity) | [verified: [aio-presets], [hb-iconnect]]; whether the Hue app itself shows them [assumed: not confirmed] |
| IR | Learns codes from any remote and maps each to an action; default codes flag; Harmony support since 2020 | all with IR | none | [verified: [aio-ir], [hb-harmony], [hue-rn]] |
| Entertainment area | Chosen per box from the bridge's areas; one sync per bridge, up to 10 lights; each area has its own setting for the lights' state after sync ends | all with a bridge | Janus, HA, Homebridge | [verified: [ha-select], [hue-bpro], [hb-4k-review]] |
| Bridges | The box can be moved to another bridge (about 15 s, then reselect the area); migration support since firmware 2.5.4 | all | HA action | [verified: [ha-readme], [hue-rn], [hue-bpro]] |
| LED | Off, normal, dimmed | where supported | HA | [verified: [ha-select]] |
| 8K extras | HDMI 2.1, 8K60, 4K120, DSC for PS5 Pro, 3D passthrough, 144 Hz light sync, eARC | HSB2 | none needed | [verified: [hue-rn], [hb-8k-fw], [hue-8k]] |
| Voice | Alexa, Google Assistant, Siri Shortcuts since 2020 | all | n/a | [verified: [hue-rn]] |

## 5. Lessons

### 5.1 What works

1. Routing through an **AV switch proxy**, so Control4's own connections
   pick the input (Janus, ELAN, the forum's advice).
2. **One control per concept** (power, sync, mode, intensity, brightness,
   area, input) rather than one overloaded device (HA v2).
3. **One ordered command** for several settings at once (HA's combined
   action), because intensity belongs to the current mode.
4. **Capabilities by model**, so a one-input box has no input selector and
   only HSB1 shows Dolby Vision (HA).
5. **Keypad links and events** for sync on/off (Janus, Homey triggers);
   **input status** for automations (HA).
6. **Pairing with the box's button** after the box is set up in the Hue app
   (Janus, openHAB, HA).

### 5.2 What to avoid

1. **Names as identifiers.** HA matches areas by exact name; names change in
   the Hue app. Keep ids, show names, follow renames.
2. **Two masters for the input.** With the box's hot-plug or CEC switching
   on, Control4's routing and the box disagree whenever a source wakes or
   stays awake [verified: [hb-harmony], [hb-problems], [ha-issue-22]].
3. **Powersave as Room Off.** The box reports HDMI inactive in powersave
   [verified: [aio-execution]]; side effects on other devices were reported [verified:
   [ha-forum-p7]]; old firmware stopped answering [verified:
   [hubitat-thread]].
4. **A silent takeover of the bridge's one sync.** HA ends whoever is
   streaming (a PC, a TV app, another box) without asking [verified:
   [ha-helpers]].
5. **Cycle-only controls** (Janus): the user cannot pick Game directly and
   does not see the current value on the button [verified: [janus-guide]].
6. **Brightness as a light** (Janus): "off" and 0 % of a light do not map
   onto 0 to 200 with 100 neutral, and Control4's room-wide light commands
   would reach it [assumed: inference from [janus-guide] and the light_v2
   behaviour in [`c4-lighting-guidelines.md`](c4-lighting-guidelines.md)].
7. **Skipping certificate checks** (Homey's script) [verified:
   [homey-mode]]; the box's chain needs care (the library HA uses ships its own CA file, and
   one 8K user still failed) [verified: [aio-repo], [ha-issue-128]].

### 5.3 Sounds useful, causes trouble

- **The box's automatic input switching** in a Control4 room (above).
- **CEC power coupling**: needed for the box to follow the TV, but firmware
  notes show years of CEC fixes (power detection, 20-minute auto-off on a
  receiver's second output, inputs switching on powersave) [verified:
  [hue-rn]]; Control4 sequencing on top of it needs testing, not trust.
- **ARC bypass, solo mode, Dolby Vision compatibility, HDR mode**: each
  changes the HDMI handshake and is only right for one wiring [verified:
  [aio-behavior], [hue-arc], [phk-blog]]. Not programming commands.
- **Fast polling**: the box answers slowly (2 to 3 s in 2020; HA once
  overran a 2 s interval) [verified: [hubitat-thread], [ha-issue-24]].
- **IR learning**: the box acts on any remote it learned, so a remote used
  with Control4 in that room could also drive the box [assumed: inference
  from [aio-ir]].
- **Scheduled reboots**: a 2020 workaround; the API has a restart action
  for a manual fix [verified: [hubitat-thread], [aio-enums]].

## 6. Recommendations for the design

1. **A Control4 device per box with an AV switch proxy**: one input per HDMI
   port (one for HSB3), its output bound to the TV, so the existing routing
   and sequencing select the input. Whether a one-input AV switch and the
   camera fit the proxy is for the Control4 research.
2. **Separate controls**: Sync On, Sync Off, Toggle Sync; Set Mode
   (Video, Music, Game); Set Intensity; Set Brightness; Set Entertainment
   Area; Set Input; plus one **Apply Sync Settings** command with optional
   fields, applied in the box's order (mode before intensity).
3. **Direct choice in Navigator and programming**, cycle only as an extra
   for keypads: keypad links for Toggle Sync (LED follows sync), Cycle Mode,
   Cycle Intensity, Brightness Up and Down in steps (the box takes
   increments [verified: [aio-execution]]).
4. **Defaults**: Room Off ends sync (passthrough), with powersave as an
   option; Control4 does not start sync on its own unless the owner turns
   that on (§7).
5. **Per-source sync settings** (mode, intensity, area, start sync when
   selected) applied when Control4 selects that input. Hue planned per-input
   settings in 2019 and no source confirms they shipped [verified:
   [hb-problems]; assumed: not shipped]; Control4 knows the source, so this
   is where it can do better than the Hue app.
6. **One owner for input switching**: if Control4 routes, find the box's
   hot-plug and CEC switching and offer one reversible click to turn them
   off, the same click-gated pattern as the Hue automation audit
   ([`hue-automation-audit-design.md`](hue-automation-audit-design.md));
   never change them silently.
7. **Entertainment areas by id**: list from the box, show names, follow
   renames; report "in use by another app" and offer an explicit
   take-over instead of HA's silent one. The box's bridge connection state
   has values such as busy and invalidgroup [verified: [aio-enums]]; which
   one a competing session produces is to be checked [assumed].
8. **Model gating**: HSB1, HSB2, HSB3, HSC001 and standalone mode decide
   which controls and properties exist.
9. **Status properties**: model, firmware, box-to-bridge connection
   (connected, streaming, busy, invalid area), active input with each
   input's status and name, content info, Wi-Fi quality; events for sync
   started and stopped, input changed, mode changed, area busy.
10. **Pairing**: box set up in the Hue app first; Composer action, press the
    box's button for 3 s; local discovery plus manual IP; identity by the
    box's unique id, so an IP change is followed.
11. **Polling** at a few seconds while the room is on, slower in
    powersave, at once after a command; coalesce brightness slider steps.
12. **Settings stay in the Hue app**: ARC bypass, solo mode, Dolby Vision,
    HDR mode, power-save timer, IR and LED as read-only properties at most;
    no IR control from Control4; the box's presets are not needed when
    Control4 has its own per-source settings.
13. **Lights during sync**: the light devices of a syncing area should say
    so in their status, and the design must decide what a Control4 command
    to them does (§7).

## 7. Open questions for the owner

1. **Which devices are in scope**: the original 4K, the 8K, the new
   single-input 4K, and also the Screen Sync camera and a box in standalone
   mode without a bridge?
2. **Room Off**: end sync and leave the picture (passthrough), or put the
   box in powersave?
3. **Who switches inputs**: Control4 (offer to turn off the box's
   automatic switching) or the box (Control4 follows and reports)?
4. **Area mapping**: one area per Control4 room (your first guess), per
   source, or a room default with per-source overrides?
5. **Starting sync**: should selecting a source in Control4 start sync
   (per source), or is sync only started by the box's auto-sync, a button
   or programming?
6. **A busy bridge**: when a PC, a TV app or another box is syncing, may a
   Control4 command take over, or only report it?
7. **Sync brightness**: a light in Control4 (scenes can set it, room-wide
   light commands reach it) or a value for programming and Navigator only?
8. **Lights in a syncing area**: does a keypad press or scene on those
   lights stop sync, or wait until sync ends?

## Sources

[aio-behavior]: https://github.com/mvdwetering/aiohuesyncbox/blob/master/aiohuesyncbox/models/behavior.py
[aio-enums]: https://github.com/mvdwetering/aiohuesyncbox/blob/master/aiohuesyncbox/models/enums.py
[aio-execution]: https://github.com/mvdwetering/aiohuesyncbox/blob/master/aiohuesyncbox/models/execution.py
[aio-ir]: https://github.com/mvdwetering/aiohuesyncbox/blob/master/aiohuesyncbox/models/ir.py
[aio-presets]: https://github.com/mvdwetering/aiohuesyncbox/blob/master/aiohuesyncbox/models/presets.py
[aio-repo]: https://github.com/mvdwetering/aiohuesyncbox/tree/master/aiohuesyncbox
[an-listing]: https://automatednow.com/control4-driver-philips-hue-hdmi-sync-box/
[c4f-36113]: https://www.c4forums.com/forums/topic/36113-control4-and-hdmi-arc/
[c4f-42053]: https://www.c4forums.com/forums/topic/42053-philips-hue-hdmi-sync-box/
[elan-intrinsic]: https://www.intrinsicdev.com/downloads/philips-hue-sync-driver-for-elan/
[g-home]: https://9to5google.com/2023/02/16/google-home-philips-hue-sync-box/
[ha-forum-p7]: https://community.home-assistant.io/t/philips-hue-play-hdmi-sync-box-custom-integration/204772?page=7
[ha-helpers]: https://github.com/mvdwetering/huesyncbox/blob/master/custom_components/huesyncbox/helpers.py
[ha-issue-22]: https://github.com/mvdwetering/huesyncbox/issues/22
[ha-issue-24]: https://github.com/mvdwetering/huesyncbox/issues/24
[ha-issue-65]: https://github.com/mvdwetering/huesyncbox/issues/65
[ha-issue-128]: https://github.com/mvdwetering/huesyncbox/issues/128
[ha-issue-167]: https://github.com/mvdwetering/huesyncbox/issues/167
[ha-number]: https://github.com/mvdwetering/huesyncbox/blob/master/custom_components/huesyncbox/number.py
[ha-readme]: https://github.com/mvdwetering/huesyncbox
[ha-select]: https://github.com/mvdwetering/huesyncbox/blob/master/custom_components/huesyncbox/select.py
[ha-switch]: https://github.com/mvdwetering/huesyncbox/blob/master/custom_components/huesyncbox/switch.py
[hb-4k-review]: https://hueblog.com/2026/10/12/philips-hue-play-hdmi-sync-box-4k-review/
[hb-8k-fw]: https://hueblog.com/2025/04/08/numerous-improvements-for-the-philips-hue-play-hdmi-sync-box-8k/
[hb-app]: https://hueblog.com/2022/11/30/hue-app-now-allows-control-of-the-hdmi-sync-box/
[hb-bpro]: https://hueblog.com/2025/09/04/hue-bridge-pro-almost-all-the-answers-to-the-most-important-questions/
[hb-harmony]: https://hueblog.com/2020/05/29/control-hue-sync-box-with-a-logitech-harmony-remote/
[hb-iconnect]: https://hueblog.com/2025/12/29/iconnecthue-gets-support-for-the-hue-sync-box/
[hb-problems]: https://hueblog.com/2019/10/16/explaining-the-hdmi-sync-box-these-problems-still-exist/
[hb-syncbox]: https://unpkg.com/homebridge-philips-hue-sync-box@3.0.7/README.md
[homey-hue]: https://homey.app/en-us/app/nl.philips.hue/Philips-Hue/
[homey-mode]: https://community.homey.app/t/hue-sync-box-mode/54510
[hubitat-thread]: https://community.hubitat.com/t/control-hue-hdmi-sync-box-via-hubitat/33761
[hue-8k]: https://www.philips-hue.com/en-us/p/hue-philips-hue-play-hdmi-sync-box/046677579753
[hue-arc]: https://www.philips-hue.com/en-us/support/article/Hue-sync-box-and-arc-setup/000006
[hue-bpro]: https://www.philips-hue.com/en-us/support/article/how-to-upgrade-to-the-hue-bridge-pro/000010
[hue-matter]: https://www.philips-hue.com/en-us/explore-hue/works-with/matter
[hue-rn]: https://www.philips-hue.com/en-us/support/release-notes/philips-hue-play-hdmi-sync-box
[hue-setup]: https://www.philips-hue.com/en-us/support/connect-hue-product/accessories/hue-sync-box
[janus-dc]: https://drivercentral.io/platforms/control4-drivers/audio-video/philips-hue-hdmi-sync-box/
[janus-guide]: https://automatednow.com/index.php?dispatch=attachments.getfile&attachment_id=1383
[macrumors]: https://www.macrumors.com/review/philips-hue-play-hdmi-sync-box
[nbc-launch]: https://www.notebookcheck.net/Philips-Hue-launches-new-Play-Screen-Sync-Play-HDMI-sync-box-4K-and-Play-gradient-TV-strip-lights.1386896.0.html
[netzwelt]: https://www.netzwelt.de/anleitung/223673-philips-hue-sync-box-automatische-steuerung-synchronisierung.html
[oh-huesync]: https://www.openhab.org/addons/bindings/huesync/
[phk-blog]: https://practicalhomekit.blogspot.com/2020/10/syncing-lights-with-your-tv-philips-hue.html
[whistle-ultimate]: https://drivercentral.io/platforms/control4-drivers/security-systems/philips-hue-ultimate-pack/

What each source is: [janus-dc] the driver's DriverCentral listing and
changelog; [janus-guide] its integration guide v101 (PDF); [an-listing] a
reseller listing (refused the fetch); [c4f-42053] and [c4f-36113] C4 Forums
threads (refused the fetch); [elan-intrinsic] the ELAN driver listing;
[ha-*] Home Assistant's huesyncbox integration (README, source files,
issues #22, #24, #65, #128, #167, forum page 7); [aio-*] aiohuesyncbox, the
Python library it uses, whose model docstrings describe the box's API;
[oh-huesync] openHAB's binding; [hb-syncbox] the Homebridge plugin's README,
v3.0.7; [homey-*] Athom's Hue app page and a Homey forum thread;
[hubitat-thread] a Hubitat forum thread (2020); [g-home] 9to5Google on
Google Home; [hue-*] Signify's product, support, release-note and Matter
pages; [hb-*] Hueblog articles; [nbc-launch] Notebookcheck on the 2026-09-03
launch; [netzwelt] a German setup guide; [phk-blog] a 2020 owner's blog;
[macrumors] MacRumors' review.
