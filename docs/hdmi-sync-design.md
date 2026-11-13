# 2.0: Hue Play HDMI Sync Boxes and entertainment areas in Control4

The design spec for issue #514, the first feature of the 2.x release train.
Status: **proposed, for review with the owner** (2026-11-13). Nothing here is
built. The decisions marked **[owner]** wait for the owner's answer in
section 10. The rest are proposed defaults that the review may change.

The wire-level details every builder works against are in
[`hdmi-sync-contracts.md`](hdmi-sync-contracts.md).

The research it rests on, all of 2026-11-13:

| Document | What it settles |
|---|---|
| [`syncbox-api-research.md`](syncbox-api-research.md) | The devices, the box's local API, TLS, discovery, pairing, polling, what the box does by itself |
| [`entertainment-areas-research.md`](entertainment-areas-research.md) | Areas on the bridge, lamps while streaming, the mapping to Control4, checks T0 to T9 |
| [`syncbox-control4-research.md`](syncbox-control4-research.md) | The AV switch model, routing and sequencing, programming, Navigator, probes P1 to P7 |
| [`edge-cases-syncbox.md`](edge-cases-syncbox.md) | 85 lifecycle cases: B (box), E (areas), C (Control4), I (interaction) |
| [`syncbox-architecture-research.md`](syncbox-architecture-research.md) | A fifth driver, networking, security, integration, testing, the release train |
| [`syncbox-comparables-research.md`](syncbox-comparables-research.md) | Other Control4 drivers, Home Assistant and others, Hue's Sync app, the lessons |

## 1. The owner's request (2026-11-13)

"enable the use of all of the HDMI sync functions that hue supports with the
optional HDMI boxes, supporting all available models of that box and
features of that box. In control4 I'd want the ability to use the hdmi box
like any HDMI switcher, with auto routing and sequencing once the
connections are made, and programmatic control in c4 over the hdmi box. We
need to understand how the concept of entertainment zones in Hue,
associated with the sycn boxes will best translate over to control4. first
guess is that an entertainment zone should map to a room in c4."

## 2. What 2.0 delivers, in one paragraph

A new driver, **Hue Sync Box** (`hue_syncbox.c4z`), adds each sync box to
Control4 as a standard HDMI switch.
- **Routing.** The dealer draws the HDMI connections in Composer once (each
  source into a box input, the box's output into the TV). Control4's own
  routing then picks the box's input whenever someone watches a source,
  powers the box with the room, and switches it off at Room Off.
- **Programming.** Start and stop sync, the mode, intensity, brightness,
  entertainment area and power, with events, conditionals and variables.
  Navigators get a Watch-menu button that shows and toggles sync.
- **Areas.** An entertainment area belongs to the box that drives it. Its
  Control4 rooms are worked out from its lamps.
- **Lights while syncing.** The Hue Light, zone light and Hue Scene devices
  learn when their lamps are syncing and say so, instead of showing a
  command as done while the lamp keeps following the TV.

## 3. Scope

### 3.1 Devices

| Device | `deviceType` | HDMI | In 2.0 |
|---|---|---|---|
| Hue Play HDMI Sync Box (original, now also sold as "4K") | `HSB1` | 4 in, 1 out | Yes |
| Hue Play HDMI Sync Box 8K | `HSB2` | 4 in, 1 out, eARC | Yes |
| Hue Play HDMI Sync Box 4K (2026) | `HSB3` | 1 in, 1 out | Yes, with a bridge. Standalone (Bluetooth) mode **[owner]**, Q2 |
| Hue Play Screen Sync camera | `HSC001` | none | **[owner]**, Q2. Proposed: not in 2.0 |

The model is read from the box's `deviceType` at run time, never from the
product name. Signify now calls two different boxes "4K". One driver covers
every model, and each model shows only the controls it has.

### 3.2 In

- HDMI switching through Control4's routing: inputs, power, Room Off.
- Sync control: start, stop and toggle; mode (video, music, game); intensity
  (subtle, moderate, high, intense); brightness; entertainment area; power
  (wake, power save); one combined "Apply Sync Settings" command.
- The box's state in Composer (properties), in programming (events,
  conditionals, variables) and on Navigators (a Watch-menu button).
- Pairing, discovery, identity, offline handling and Forget, as the bridge
  has them.
- The bridge reads entertainment areas and each lamp's streaming mode, and
  the light devices behave honestly while their lamps stream.
- Offers, never automatic: handing input selection to Control4 (turning off
  the box's own input switching), and taking over a sync another app runs.

### 3.3 Out of 2.0

- Running an entertainment stream from Control4 (DriverWorks has no DTLS).
- Creating, editing or deleting entertainment areas (the Hue app's job).
- The box's Wi-Fi, IR learning, presets, ARC bypass, Dolby Vision and HDR
  settings, and its bridge link. These stay in the Hue Sync app; some are
  shown as read-only facts.
- A light_v2 "sync brightness" tile with keypad LEDs (a later separate
  driver if wanted, Q7).
- Several Hue bridges (still later work).

## 4. Architecture

### 4.1 A fifth driver

**`hue_syncbox.c4z`**, one Control4 device per box. It talks HTTPS directly
to its own box, because the box has its own local API and the bridge does
not proxy it. It keeps working when the Hue bridge is away: switching HDMI
is the box's own job, and a TV must keep its sources while the bridge
reboots (edge cases I14, C20).

This is the first time a driver other than the Hue Bridge talks to Hue
hardware. The reason goes into `docs/design.md`: the box is a separate
device with its own API, and putting it behind the bridge would make HDMI
switching depend on the bridge.

### 4.2 Its link to the Hue Bridge driver (optional)

A new provider connection on the Hue Bridge driver, **id 2 "Hue Sync Boxes",
class `HUE_SYNCBOX`**, and a consumer connection on the box. Boxes stay out
of binding 1, so the light, scene and motion registries never see them. This
is a connection change, not a capability change, so it needs no reboot.

When bound, the bridge tells the box about entertainment areas and stream
starts and stops. These messages only make the box read its own state
sooner; they never set the box's state. When unbound, the box works fully
except for area names from the bridge, which it also gets from its own API.

### 4.3 Shared code

- The HTTPS core, the TLS self-check and the mDNS parser move from
  `src/hue_bridge/bridge/` into `src/common/`, parameterised. The bridge's
  existing specs prove its behaviour is unchanged.
- The box driver reuses `common/device.lua`, `dispatch.lua`, `log.lua`,
  `num.lua` and `link.lua`, as the motion driver does.
- `tools/build.sh` builds a fifth package by itself.

## 5. The box in Control4

### 5.1 An AV switch

The box is an **`avswitch`** proxy device between the sources and the TV.
- **Connections.** Four HDMI inputs (video 1000–1003, audio 3000–3003) and
  one HDMI output (video 2000, audio 4000). Audio is included so Control4
  can build "video with audio" paths through the box.
- **Every model declares four inputs.** Connections can only be added in a
  later release, and a capability change costs a controller reboot. On a
  one-input box (HSB3), a route to inputs 2–4 is refused with a clear Last
  Action.
- **Capabilities.** 4/1 video and audio, no volume, no separate audio and
  video switching. They are frozen before `v2.0-beta.1`.

### 5.2 Routing and sequencing

Control4 owns routing. The driver carries it out and never steers it.

- **ON** wakes the box: `mode` passthrough, or the sync mode the routing
  setting asks for (5.3).
- **SET_INPUT** switches the box to HDMI n. The driver wakes the box first
  if needed, switches, reads the input back, and only then confirms with
  `INPUT_OUTPUT_CHANGED`. The command goes through one queue per box. A
  write that does not land is retried (2 s, up to 4 tries, the starting
  values from Snap One's template; probe P2 may adjust them), then answered
  as undelivered.
- **OFF and DISCONNECT_OUTPUT** (Room Off, or a source that doesn't pass
  the box) apply the Room Off setting (5.3).
- **Changes made outside Control4** (the Hue Sync app, the box's own CEC or
  hot-plug switching) are reported in the box's properties, variables and
  events. They never move a Control4 room, and the driver never switches
  back. Control4's Watch screen can then be out of step: that is why
  handing inputs to Control4 is offered (5.4).

### 5.3 Settings that decide what routing does to sync

Two properties on the box device:

| Property | Choices | Proposed default |
|---|---|---|
| **When Control4 Selects An Input** | `As the box decides` (its own per-input auto-sync) / `Start syncing` / `Pass the picture only` | `As the box decides`, so an install changes nothing **[owner]**, Q5 |
| **At Room Off** | `Power save` / `Stop syncing, keep the picture` | **[owner]**, Q6. Proposed: `Power save` |

Per-source sync settings (each input with its own mode, intensity and area,
applied when Control4 selects it) are something Control4 can do better than
the Hue app. Proposed for a 2.x point release, not 2.0 (Q5).

### 5.4 One owner for input switching

The box switches inputs by itself when a source wakes it over HDMI CEC or
hot-plug, auto-syncs per input, and goes to power save on the TV's standby
or after idle time. Each is a `behavior` setting on the box.

The driver treats these like the Hue automations of 1.5:
- **Shown** on the box device.
- **On Attention** when the box's input switching is on while Control4
  routes through it.
- **One reversible click** ("Let Control4 choose inputs") turns the box's
  CEC and hot-plug switching off; "Restore the box's input switching" puts
  it back.
- **Never changed by itself.**

### 5.5 Programming

The names and ids are fixed at release; the contract lists them all.

- **Commands:** Start Sync, Stop Sync, Toggle Sync, Set Sync Mode, Set
  Intensity, Set Brightness, Adjust Brightness, Set Entertainment Area,
  Apply Sync Settings (each field optional, sent in the box's order),
  Power Save, Wake. Select HDMI Input is listed with a warning that the
  room does not follow it.
- **Events:** Sync Started, Sync Stopped, Sync Mode Changed, Intensity
  Changed, Brightness Changed, HDMI Input Changed (from any cause),
  Entertainment Area Changed, Area Busy, Powered On, Power Save, Online,
  Offline.
- **Conditionals:** Sync Active, Sync Mode, Intensity, HDMI Input,
  Brightness, Powered On, Online.
- **Variables** (read-only, set before their events fire, as on the motion
  driver): SYNC_ACTIVE, SYNC_MODE, INTENSITY, BRIGHTNESS, HDMI_INPUT,
  HDMI_INPUT_NAME, ENTERTAINMENT_AREA, POWER, ONLINE.
- **No events at start-up** for values that did not change, so a Director
  restart during a film never runs "sync started" programming again.

### 5.6 Navigator

A **UI Button** (`uibutton` proxy) in the room's Watch menu, labelled
"Hue Sync". It toggles sync and shows sync on or off by its icon. A second
proxy is fixed for good once released, so it is decided now **[owner]**, Q7.

### 5.7 The box device's Composer surface

- **Properties:** Driver Version, Debug Mode, Status, Online, Last Action
  (with continuation rows), Sync Box, Model, Firmware, Box ID, Box Address,
  Sync Boxes Found, Entertainment Area, Inputs, Sync, Bridge Link, the two
  settings of 5.3, and Input Switching (what the box does by itself).
- **Actions**, kept few as 1.2 decided:
  - **Pair Sync Box:** pick a found box or type an address, then hold its
    button.
  - **Sync Box Settings:** the offers of 5.4 and 7.3.
  - **Diagnostics.**
  - **Forget Pairing.**

## 6. Entertainment areas

### 6.1 The mapping (the owner's question)

The owner's first guess was that an entertainment area maps to a Control4
room. The research found that this breaks in common cases:
- an area can span two rooms (E6);
- one TV can have several areas: a music area and a film area (E7);
- two boxes can share one area (B27);
- Hue's own PC and TV apps sync areas with no box at all.

No ecosystem the comparables research found maps an area to a room.

**Proposed: the area belongs to the box that drives it.**
- It is the box's **Entertainment Area** setting, picked from the areas the
  box lists, stored by id and followed through renames.
- The area's Control4 rooms are derived from its lamps through the
  existing Hue room to Control4 room mappings. They are shown as
  information and never stored.
- The box device sits in its TV's room, so in the common case (one box, one
  TV, one room, an area of that room's lamps) the area "is" that room. The
  first choice offered is the area whose lamps are in the box's room. It is
  never chosen silently.

**[owner]**, Q3: accept this, or keep "area = room" as a strict mapping.

### 6.2 What the bridge learns

- The resync reads `entertainment_configuration` and `entertainment` (two
  more GETs). Each lamp's `mode` (`normal` or `streaming`) is kept.
- The event stream's area and lamp changes mark streams starting and
  stopping.
- The bridge shows the areas in a new row, and fires two new events, Sync
  Started and Sync Stopped (with the area's name), for any streamer: a box,
  or Hue's own apps. **[owner]**, Q10.

### 6.3 Lights while their lamps stream

Today a streamed lamp's device keeps its old state, and a command to it
looks delivered while the lamp keeps following the TV (guideline L87). The
proposed behaviour:

| Device | While its lamps stream |
|---|---|
| Hue Light | Shows the last state Hue reported, never goes offline because of the stream, and Status reads "Syncing with the TV (Living Room sync box)". A command is answered at once with the known state, and Last Action says why **[owner]**, Q9. |
| Zone light with some lamps streaming | State from the lamps that are not streaming; commands go out as today and the other lamps obey; Status "2 of 6 lamps syncing with the TV". |
| Zone light with all lamps streaming | As a Hue Light. |
| Hue Scene | Recalled as today; Keypad Follows "Room/zone lights" reads only the lamps that are not streaming; Status says which lamps keep syncing. |
| Hue Motion Sensor | Unchanged, unless check T8 shows MotionAware stops while its lamps stream. |

When the stream ends, Hue's end state reaches Control4 as an ordinary change
from outside. Hue's "light state after streaming" setting stays Hue's
**[owner]**, Q11.

This departs from the lighting guidelines while a stream runs (L6, L9, L53,
L68): Hue reports no state for a streamed lamp. That departure is **D21**,
written into `docs/c4-lighting-guidelines.md` with the reason.

## 7. Pairing, identity, security

### 7.1 Pairing and discovery

- **Adding a box.** The dealer adds the Hue Sync Box driver from Composer's
  list, like any AV switch, in the TV's room. **[owner]**, Q13: should the
  bridge's Add From Hue also offer boxes?
- **Finding the box.** By mDNS `_huesync._tcp` (local only, with the
  discovery rules of #490) or a typed address.
- **Pairing.** Pair Sync Box opens a 2-minute window while the owner holds
  the box's button for about 3 s. The token is stored in encrypted
  PersistData, never shown, never logged, and sent only to the paired box.
  The registration is named after the Control4 device, so the owner can
  find it in the Hue Sync app.
- **Forget Pairing** deletes the box's registration. Deleting the device in
  Composer leaves the registration on the box.

### 7.2 Identity

The box is keyed by its `uniqueId`, the 12-hex id on its label and in its
certificate.
- **TLS.** The leaf certificate chains to Hue's `root-hsb` CA. The driver
  pins that CA (`certs/hsb_ca.pem`), checks the leaf's name against the
  paired id with an unkeyed `GET /api/v1/device`, and runs the decoy TLS
  self-check, all before the first keyed request of every start and every
  new address.
- **A moved box** is followed by its id. The same residual risk as #491
  goes into `SECURITY.md`.
- **A box with a new id** (a replacement) is only suggested, never linked
  by itself.
- **A factory-reset box** is the same box: its id stays, only the token
  goes, so the owner pairs it again.

### 7.3 Security

The rules of the 2026-11-13 review apply from the first line:
- every number through `common/num.lua`, every peer text capped;
- one request in flight per box, with bodies over 256 KB refused;
- redirects refused on keyed requests;
- messages from other drivers trusted only as hints.

The bridge's key never reaches the box driver. The driver never changes the
box's bridge link, its area list, or another app's sync without a click:
- **Taking over** another app's stream is offered when the box reports it
  busy ("Take over sync"), never done by itself. Home Assistant does it
  silently.

## 8. Lifecycle defaults (from `edge-cases-syncbox.md`)

- Nothing is created by itself. Discovery lists and hints; a box device is
  added by a click; registering needs the owner's hand on the box.
- The 5-minute offline rule, the refused-key re-check and the "undelivered"
  answer work per box as on the bridge (#428). A bridge outage never takes
  the box offline.
- Anything programming refers to (an area, a preset) can be re-pointed in
  one place. When Hue re-creates an area under a new id, the same-name
  successor is offered once, never applied by itself.
- Two-way names for the box's name, as 1.2 decided for lights, scenes and
  motion sensors. Input names are only shown and offered **[owner]**, Q14.

## 9. Testing and the release train

### 9.1 Without a box

- **Specs.** A fake box in `tests/helpers/fake_c4.lua` (a responder for
  HTTPS transfers to its address), hand-written fixtures from the public
  field names (`tests/fixtures/hue_syncbox.lua`), and the AV switch proxy in
  the fake runtime.
- **Probes P1–P7** on the house through the dev loop. They need no box, but
  they change one room's AV connections in Composer while they run. They
  settle what Director sends at Room Off, the parameter shapes and the
  command order.
- **Checks T0–T9** of the entertainment research. Any sync source can
  stream to a bridge area, including Hue's desktop Sync app, so most need
  no box. They settle what the bridge reports and answers while lamps
  stream.

### 9.2 With a box

Pairing, real fixtures recorded from the box (which replace the
hand-written ones), routing through the box, CEC fights, and power save.
These need a box and the owner's hands (the button, a source, a TV),
**[owner]**, Q1.

### 9.3 Releases

- **2.0 begins the 2.x train.** The minimum OS stays 3.3.0, no existing
  device changes, and every driver keeps its capabilities. The new box
  driver's capabilities and connection ids are frozen before
  `v2.0-beta.1`. The bridge's new connection needs no reboot. The scene,
  light and zone light changes of 6.3 are Lua only.
- **Prereleases.** `v2.0-beta.N`, as for motion (#268): the house where a
  box exists, an outside tester otherwise.
- **The promises "until 2.0".** The 37 hidden 1.1 action aliases and the
  hidden On State Follows property were kept until 2.0, and naming 2.0
  fails the ledger spec until they are settled **[owner]**, Q15.
- **Build order.** Four beta stages, each one PR:
  1. The `common/` move and the bridge's entertainment awareness, with the
     light devices of 6.3. Testable now, with T0–T9.
  2. The box driver's client, pairing, identity and state.
  3. The AV switch, routing and sequencing (P1–P7).
  4. Programming, the UI Button and the offers.

## 10. Questions for the owner

Each has the proposed answer first.

1. **Hardware.** Is there a sync box in the house, and which model, between
   which devices? If not, can one be lent, or is there a tester?
2. **Models.** HSB1, HSB2 and HSB3 with a bridge in 2.0. HSB3 standalone
   (Bluetooth, no bridge) for HDMI switching and sync, without area
   control. The Screen Sync camera later.
3. **Areas.** The area belongs to the box, picked from its list, with its
   Control4 rooms derived; or a strict "area = room" mapping.
4. **Input switching.** Control4 owns inputs. The box's own CEC and hot-plug
   switching is shown and offered off with one reversible click. The
   driver never switches back.
5. **Selecting a source.** "As the box decides" at first (nothing changes on
   install), with the Start Syncing and Pass Only choices available, and
   per-source settings in a 2.x point release.
6. **Room Off.** Power save, with "stop syncing, keep the picture" as the
   other choice.
7. **Navigator.** A Watch-menu UI Button; a light_v2 sync tile later, only
   if keypads with LEDs are wanted.
8. **Sync brightness as a Control4 light.** No in 2.0 (a command, a
   variable and a property).
9. **A command to a syncing lamp.** Leave the sync running, answer with the
   known state and say so; or end the sync first and apply the command.
10. **Streams with no box** (Hue's PC or TV apps). The bridge's own Sync
    Started and Sync Stopped events, for any streamer.
11. **After a sync ends.** Keep Hue's "light state after streaming" setting
    as it is, never written by Control4.
12. **Another app is syncing.** "Take over sync" is offered with a click,
    never done by itself.
13. **Adding a box.** From Composer's driver list only; or also from the
    bridge's Add From Hue.
14. **Names.** Two-way for the box's name; input names only shown and
    offered.
15. **The "until 2.0" promises.** Remove the 1.1 aliases and the hidden On
    State Follows property in 2.0, as announced.
