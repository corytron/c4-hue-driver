# Hue Play HDMI Sync Box as a Control4 HDMI switch: Control4 research for #514

**Status (2026-11-13): research for issue #514 (the 2.0 feature), read-only;
nothing here is approved or built.** This note (R3) covers the Control4 side
only: how a Hue Play HDMI Sync Box should appear in Composer, in Director's AV
routing, on Navigators and in programming, on OS 3.x (the house runs 3.4.3)
and OS 4.x. The box's own API, the Hue side of entertainment areas and the
lifecycle edge cases are the other research notes of #514; the few Hue facts
used here are marked [assumed: Hue side] and belong to them.

The owner's request (2026-11-13): use the box in Control4 like any HDMI
switcher, with automatic routing and sequencing once the connections are
made, and programmatic control in Control4 over the box.

Snap One documents and code are paraphrased: only interface names (proxy,
command, notification, capability, connection class, parameter and variable
names) appear as written. This is not legal advice.

Markers:

- **[verified: PP x/_y]** = `~/c4-tools/reference/docs-driverworks-proxyprotocol/source/includes/<x>/<_y>.md`;
  **[verified: FUND x/_y]** = `~/c4-tools/reference/docs-driverworks-fundamentals/source/includes/<x>/<_y>.md`;
  **[verified: API x/_y]** = `~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`;
  **[verified: XML x/_y]** = `~/c4-tools/reference/docs-driverworks-xml/source/includes/<x>/<_y>.md`;
  **[verified: UIB x/_y]** = `~/c4-tools/reference/docs-driverworks-proxyprotocol-uibutton/source/includes/<x>/<_y>.md`.
- **[verified: TPL file]** = Snap One's public template code,
  https://github.com/snap-one/drivers-template-code-public (commit `50eee83`,
  2025-10-10), `proxies/avswitch_proxy/<file>`, read with `gh api` into the
  scratch folder (not vendored, not copied). It is outside the local SDK, so
  it is cited separately: it shows what Director actually puts in the
  parameters, where the proxy guide only names them.
- **[verified: SDK-GH file]** = https://github.com/snap-one/docs-driverworks
  (commit `36076bb`, 2026-06-23), `<file>`.
- **[verified: C4 docs page]** = Control4's public Composer Pro dealer help,
  `https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/<page>.htm`
  (URLs under Sources).
- **[community: name]** = third-party drivers and posts (URLs under Sources).
  **[house]** = this repository's code and notes.
- **[assumed]** = inference or undocumented; the probes that would settle the
  important ones are in §6. **[assumed: Hue side]** = a fact about the box or
  the bridge that the other #514 notes must confirm.

## Answer in brief

1. **The box is an `avswitch` proxy device.** The AV Switch proxy is the one
   Control4 has for a device that sits in the HDMI path and selects an input
   with `SET_INPUT` [verified: FUND 21_universal_minidrivers/_1-OVERVIEW.md].
   It declares 4 HDMI video inputs (1000 to 1003), 1 HDMI video output
   (2000), 4 HDMI audio inputs (3000 to 3003) and 1 HDMI audio output (4000),
   and capability counts that match them (§1.2).
2. **Routing is Director's job, not the driver's.** The dealer binds each
   source to a box input and the box output to a TV input; the TV stays the
   room's Video End Point. When someone picks a source in Watch, Director
   finds the path through the box and sends it `ON` and `SET_INPUT` with
   `INPUT`, `OUTPUT`, `AUDIO` and `VIDEO` (the order is [assumed]); the
   driver switches the box and answers `ON` and `INPUT_OUTPUT_CHANGED`
   (§1.3 to §1.5).
3. **Sequencing lives in the driver.** No Director power-on delay is
   documented for an IP DriverWorks driver. Snap One's own template queues
   and retries the input until the device confirms (§1.5).
4. **Changes made outside Control4 do not move the room.** Control4 ignores
   unsolicited AV notifications. An input picked in the Hue app, or by the
   box's own automatic switching, leaves the room's Watch screen out of step
   (§1.5).
5. **Receiver and TV models are wrong for the box.** A receiver takes over
   the room's audio and volume by default, and a TV is the room's video
   endpoint. No "video pass-through" proxy exists (§1.6).
6. **Sync controls are the driver's own programming.** That means device
   specific commands (sync on/off, mode, intensity, brightness, area),
   events, conditionals, read-only variables and properties. Navigator has
   no AV switch screen. The idiomatic control is a **UI Button** in the
   room's Watch menu; a light_v2 "Sync" tile is possible but is not a light
   (§2).
7. **Being in a room does not matter for routing, but matters for the
   people.** Paths follow bindings, not rooms. The box should still sit in
   the TV's room, so that its programming name, its Watch button and
   `C4:RoomGetId()` all point at the room it serves. An entertainment area
   is not a Control4 room in general. It is a box setting, and its room can
   only be offered as a hint (§3).
8. **Codebase fit.** The new driver shares `common/` (log, dispatch, num,
   link, the dev loop, and `device.lua` the way `hue_motion` uses it), the
   bridge binding pattern and the manual style. New: the first AV proxy, its
   own HTTPS client to the box, a room watcher, and possibly a second proxy
   (§4).
9. **OS 3.x and 4.x.** Nothing in the SDK changes AV routing between them.
   `PREV_DEV_LIST` (3.4.2) is optional, and the 4.x additions
   (`GetBoundPartner`, `GetRoomID`, non-binding connections, dynamic
   commands) are not needed (§5).

## 1. Becoming "any HDMI switcher"

### 1.1 Which proxy

| Proxy | What Control4 makes of it | Fit for the box |
|---|---|---|
| `avswitch` | A switching device in the AV path; it handles input selection through `SET_INPUT` [verified: FUND 21/_1-OVERVIEW.md]; volume, tone and EQ are optional capabilities [verified: PP 6_audio_video_switch_capabilities/; PP 8.6_avswitch_proxy_nav_eq/_1-INTRO.md] | **Yes**: 4 in, 1 out, no volume |
| `receiver` | Also switches with `SET_INPUT` [verified: FUND 21/_1], but brings volume, surround modes and tuners [verified: PP 19_receiver_capabilities/, 21_receiver_proxy_commands/]; Composer makes a receiver the room's Audio End Point and Video Audio End Point over the TV by default [verified: C4 docs room_connection_types] | No: it would steal the room's audio and volume, which the box does not have |
| `tv` | The room's Video End Point by default [verified: C4 docs room_connection_types]; channels, inputs, volume [verified: PP 30_tv_capabilities/] | No: the real TV is the endpoint |
| none (combo driver) | Combo drivers bind to no proxy and get no Navigator UI [verified: FUND 5_important_concepts_and_terminology/_8-TERMINOLOGY.md]; AV connections belong to a proxy through `proxybindingid` [verified: XML 15_common_xml/_34-connections.md] | Only for "control, no routing" installs (§1.6) |

The XML name is `avswitch`: Snap One's minidriver guide adds one more
`avswitch` proxy to a media driver [verified: FUND 21/_1], its sample XML
declares it with a proxy connection of class `AVSWITCH` [verified: SDK-GH
universal_minidrivers/um_driver.xml], and the template folder is
`proxies/avswitch_proxy` [verified: TPL README.md]. The `name` attribute sets what Composer calls the device
[verified: XML 15_common_xml/_32-proxy.md; FUND 8_proxies_and_proxy_types/_2-MODIFYINGTHEDEFAULTNAMINGOFPROXIES.md].
The audio switch proxy (PP 5) is the audio-only sibling and is not relevant.

### 1.2 Connections and capabilities for 4 HDMI in, 1 HDMI out

Binding ids must sit in fixed ranges: video inputs 1000 to 1099, video
outputs 2000 to 2999, audio inputs 3000 to 3099, audio outputs 4000 to 4999,
proxies 5000 to 5999 [verified: FUND 11_connections/_1-OVERVIEW.md; PP
8_audio_video_switch_proxy_commands/_46-SETINPUT.md]. The AV switch's audio
outputs must start at 4000, or its proxy events misfire [verified: PP
8.7_avswitch_proxy_events/_0-HEADER.md]. Connection types: proxy 2, video 5,
audio 6, control 1 [verified: FUND 11/_1; XML 15_common_xml/_39-type.md].
HDMI is a video class and also an audio class [verified: XML 15/_34 (a TV's
HDMI video inputs); FUND 11_connections/_8-FAVOREDBLOCKEDCLASSES.md (HDMI
among audio classes)].

| Id | Type | Name (proposed) | Consumer | Class | Why |
|---|---|---|---|---|---|
| 5001 | 2 proxy | Hue Sync Box | False | `AVSWITCH` | The proxy binding [verified: SDK-GH universal_minidrivers/um_driver.xml, an `avswitch` proxy connection of class `AVSWITCH`; FUND 21/_1, 11/_6] |
| 1000 to 1003 | 5 video | HDMI 1 to HDMI 4 | True | `HDMI` | A source's HDMI video output binds here |
| 2000 | 5 video | HDMI Out | False | `HDMI` | Binds to the TV's HDMI input |
| 3000 to 3003 | 6 audio | HDMI 1 to HDMI 4 | True | `HDMI` | The same cables' audio, so an audio path exists through the box |
| 4000 | 6 audio | HDMI Out | False | `HDMI` | To the TV, or to whatever plays the audio |
| 1 | 1 control | Hue Bridge | True | `HUE_BRIDGE` | Only if the box driver binds to the Hue Bridge driver, as the other three do (§4) [house: `src/*/driver.xml`] |

Each AV connection carries `proxybindingid="5001"`, as a TV driver's do
[verified: XML 15/_34]. Snap One's sample AV switch gives every input and
output both video and audio classes [verified: SDK-GH
Jumpstart/SampleDriverFiles/AcmeAVSwitch.json]. Without audio connections
Director could not build a "video with audio" path through the box. The
template has a fallback for HDMI audio sent to a video output
[verified: TPL avswitch_device_class.lua, `PrxConnectOutput`], but relying on
it is [assumed] risky.

AV and room bindings cannot be added at run time: `C4:AddDynamicBinding` does
not cover audio, video or room bindings [verified: API
22_miscellaneous/_1-AddDynamicBinding.md]. So all ten AV connections are
static in `driver.xml`. The hidden-bindings feature for large switches
(`ExtraInfo D2`, `allow_dynamic_resize`, OS 3.3.0) is not needed for ten
[verified: PP 8.8_audio_video_switch_connections/_1-HIDDENAVSWITCHBINDINGS.md].

Capabilities (proposed):

| Capability | Value | Source |
|---|---|---|
| `video_consumer_count` / `video_provider_count` | 4 / 1 | must match the connections [verified: PP 6/_21, 6/_22] |
| `audio_consumer_count` / `audio_provider_count` | 4 / 1 | must match the connections [verified: PP 6/_1, 6/_2] |
| `can_switch_separately`, `requires_separate_switching` | False | the box switches audio and video together; `requires_separate_switching` tells Director there are separate audio and video paths [verified: PP 6/_4, 6/_20] |
| `can_upclass`, `can_downclass` | False | no conversion [verified: PP 6/_3, 6/_5] |
| every volume, mute, bass, treble, balance and loudness capability | False | the box has no volume [verified: PP 6/_7 to 6/_18] [assumed: Hue side] |
| `has_audio_signal_sense`, `has_video_signal_sense` | False | they only feed Composer programming, and the guide documents no notification for them [verified: PP 6/_6, 6/_19; PP 7_audio_video_switch_protocol_notifications/] |
| `has_discrete_input_select` | True | in Snap One's AV switch defaults [verified: FUND 26.5_jumpstart/_3-Configuration.md] |
| `can_switch` | True | documented for the receiver and in the AV switch defaults [verified: PP 19_receiver_capabilities/_4-CANSWITCH.md; FUND 26.5/_3]; for `avswitch` [assumed] harmless |

A capability change needs the controller rebooted from System Manager on the
house [house: CLAUDE.md, "Environment"], so the set is fixed at the first
release.

### 1.3 What the driver receives and sends

Proxy commands arrive in `ReceivedFromProxy(idBinding, strCommand, tParams)`
on the proxy binding [verified: API 25_proxy/_5-ReceivedFromProxy.md]; the
driver answers with `C4:SendToProxy(5001, ...)`, which sends a notify for a
binding of 1000 or more [verified: API 25_proxy/_6-SendToProxy.md].

| From the proxy | Parameters (as Director sends them) | What the driver does |
|---|---|---|
| `ON`, `OFF` | none | Wake or release the box (§1.5). The proxy only shows the power state in Composer and on Navigators; anything else is the driver's [verified: PP 8/_27-OFF.md, 8/_28-ON.md] |
| `SET_INPUT` | `INPUT` (input binding id), `OUTPUT` (output binding id), `AUDIO` and `VIDEO` (booleans as text), since 3.4.2 also `PREV_DEV_LIST` [verified: TPL avswitch_device_class.lua, `PrxSetInput`; PP 8/_46-SETINPUT.md names the ids; PP 3_whats_new/_7-WHATSNEWIN342.md] | Switch the box to the input; confirm |
| `CONNECT_OUTPUT`, `DISCONNECT_OUTPUT` | `OUTPUT`, `AUDIO`, `VIDEO`, `CLASS`, `PREV_DEV_LIST` [verified: TPL `PrxConnectOutput`, `PrxDisconnectOutput`; PP 8/_3, 8/_5] | Connect: nothing extra. Disconnect ("turn off" the output [verified: PP 8/_5]): nothing is watched through the box any more (§1.5) |
| `BINDING_CHANGE_ACTION` | `BINDING_ID`, `IS_BOUND` [verified: TPL `PrxBindingChangeAction`; PP 4_amplifier_proxy_commands/_2-BINDING_CHANGE_ACTION.md] | Note which inputs are bound. The protocol driver gets no `OnBindingChanged` for AV bindings [verified: API 9_helper/_12-OnBindingChanged.md], so this is the only signal |
| `SET_ROOM_BINDING_NAME` | `OUTPUT`, `PartnerDevice` [verified: TPL `PrxSetRoomBindingName`] | Ignore (Snap One's template does too) |
| `IS_AV_OUTPUT_TO_INPUT_VALID` | not documented [verified: TPL avswitch_proxy_commands.lua lists it] | [assumed] answer nothing, as the template's default |
| `GET_AUDIO_INPUTS` | none; sent at proxy start [verified: PP 8/_8] | [assumed] nothing to return |
| `SET_OUTPUT_INPUT`, `PULSE_INPUT` | `INPUT`, `OUTPUT` / none [verified: PP 8/_48, 8/_34] | Programming paths to the same switch |
| volume, mute, tone, number and navigation keys | per command [verified: PP 8/] | Ignored (capabilities say none) |

| To the proxy | Parameters | When |
|---|---|---|
| `ON`, `OFF` | none [verified: PP 7/_7-OFF.md, 7/_8-ON.md] | After the box is awake or released |
| `INPUT_OUTPUT_CHANGED` | `INPUT`, `OUTPUT` [verified: PP 7/_4-INPUTOUTPUTCHANGED.md]; the template adds `AUDIO`, `VIDEO` [verified: TPL avswitch_proxy_notifies.lua] | Once the box confirms the input: the template sends the switch to the device without a notify, and notifies when the device reports the input [verified: TPL avswitch_device_class.lua, `PrxSetInput` and `SetInput`; avswitch_reports.lua, `AVSwitchReport_InputOutputChanged`] |

### 1.4 Input and output ids versus the box's inputs

The template derives each port from the binding id modulo 1000 [verified:
TPL avswitch_device_class.lua, `MakeVideoKey`, `MakeAudioKey`]. For the box:

| Binding id | Box port |
|---|---|
| 1000 or 3000 | HDMI 1 |
| 1001 or 3001 | HDMI 2 |
| 1002 or 3002 | HDMI 3 |
| 1003 or 3003 | HDMI 4 |
| 2000 or 4000 | the one output |

A `SET_INPUT` for the video path and one for the audio path of the same
source both mean "HDMI n"; the driver switches once and confirms each.
Whether Director sends one message with both `AUDIO` and `VIDEO` true or two
messages is [assumed]: the template handles both in one message (P3, §6).

The driver can learn which source sits on which input without a binding
event, with `C4:GetBoundProviderDevice(proxyId, 1000 + n)` [verified: API
32_serial_network_device/_4-GetBoundProviderDevice.md], not in OnDriverInit
[verified: FUND 28_api_specific_info/_2-DRIVERINIT.md]. That gives a
read-only "HDMI 1: Apple TV" row, and an input name the box could adopt; any
name writing is automation and belongs to the edge-case research
(Recommendations, item 4).

### 1.5 Automatic routing and sequencing

**What is documented.** Control4 owns source and endpoint selection. A user
picks a source for a room. Director's pathing chooses the best path from that
source to the room's endpoints over the connections the installer made. The
drivers on the path get the on/off, source selection and input/output
switching commands, and must answer with the notifications the proxy guide
gives [verified: PP 116_proxy_and_protocol_best_practices/_1-AVPATHINGUNSOLICITEDNOTIFICATIONSANDCONTROL4UI.md].
The installer sets up a room's endpoints by starting at the endpoint and
tracing back to see which source selection and input switching are needed
[verified: C4 docs get_room_connections]. A path through a switching device
to a room's video endpoint appears in the SDK's own example of a source
reaching a TV through intermediate devices [verified: FUND
11_connections/_4-NONBINDINGCONNECTION.md].

**One box, one TV, sequence as expected** (order and the room-off part are
[assumed]; P1, P2 and P4 in §6 settle them):

1. The user picks a source in the room's Watch menu.
2. Director finds the path: source, box input n, box output 2000, TV HDMI
   input, room Video End Point. For audio it is the same path through 3000+n
   and 4000 to the Video Audio End Point (TV, soundbar or AVR).
3. Director sends `ON` and `SET_INPUT` to every switching device on the path.
   The box gets `INPUT` 1000+n, `OUTPUT` 2000, `VIDEO` true, and the audio
   equivalent (3000+n, 4000, `AUDIO` true).
4. The driver wakes the box if it sleeps, waits until the box answers,
   switches it to HDMI n+1, reads the input back, and only then sends
   `INPUT_OUTPUT_CHANGED`. Snap One's template retries the input every
   2000 ms up to 4 times before giving up [verified: TPL
   avswitch_device_class.lua, the `Input` retry defaults and `SetInput`].
5. Another source on the same box: a new `SET_INPUT` with no `OFF` between
   [assumed].
6. A source that does not pass the box (the TV's own apps): the box drops out
   of the path; [assumed] Director sends it `DISCONNECT_OUTPUT` or `OFF`.
7. Room Off: [assumed] `OFF` to the devices of the room's path that no other
   room uses, and `DISCONNECT_OUTPUT`.

**Delays.** For IR devices Composer has power management options, such as
toggle, discrete or power feedback [verified: C4 docs
editing_power_management_options], and IR codes carry a delay after each code
[verified: XML 15_common_xml/_65-delayafter.md]. The `<config>` elements
`power_management_method`, `power_command_delay`, `power_delay` and
`power_command_needed` exist, but their descriptions are empty [verified: XML
15_common_xml/_53 to _56]. Nothing documents a Director power-on delay for an
IP DriverWorks driver. So the box driver does its own sequencing: one queue
per box, wake before switching, confirm before notifying. That matches the
house's rule for the bridge, where commands are queued and coalesced
[house: `docs/design.md`].

**Unsolicited changes.** If someone changes the box's input with the Hue
app, the box's own automatic input switching or CEC, the driver's
notification is ignored. The room's Watch screen keeps showing the old
source; Control4 does not run its pathing backwards [verified: PP 116/_1].
Snap One discourages a driver from selecting sources itself. If one does, the
dealer should choose which source each input carries and which room to turn
on. That behaviour must be opt-in, never forced [verified: PP 116/_1]. The
same page limits the rule to AV devices; other kinds of device always have
their state changes tracked [verified: PP 116/_1]. That the box driver's own
properties, variables and events may still follow every change is [assumed]
and harmless, since they are not AV notifications (§2).

The box's own automatic input switching, if it has one, would fight
Control4's routing [assumed: Hue side]; see Open questions.

### 1.6 The modelling choices and what each means

| Choice | Routing | Navigator | Room volume and audio | Verdict |
|---|---|---|---|---|
| **AV switch between the sources and the TV** | The box joins the path; every source bound to it is reachable through it; the TV stays the Video End Point | No screen of its own [assumed: an AV switch is never a Watch source]; sync controls need their own surface (§2.7) | Volume stays with the TV or AVR: a room's volume device is its audio endpoint unless a Video Volume slot names another; Composer's example of that slot is an AV switch with better volume [verified: C4 docs room_connection_types]. The box has no volume, so the slot stays empty | **Recommended** |
| Receiver | Same switching through `SET_INPUT` [verified: FUND 21/_1] | Receiver UI: volume, surround, inputs | Composer makes a receiver the Audio End Point and Video Audio End Point over a TV by default [verified: C4 docs room_connection_types]; volume would go to a box that has none | Rejected |
| TV | The box would be the Video End Point [verified: C4 docs room_connection_types]; the real TV could no longer be | TV UI | Breaks the room | Rejected |
| "Video pass-through" | No such proxy in the proxy guide's folder list [verified: PP includes]; the guide is now split into per-proxy repositories [verified: PP 2_introduction/_1-INTRODUCTION.md], so that none exists anywhere is [assumed] | | | Not available |
| Control only, no AV model | Sources are bound straight to the TV in Composer although the cables go through the box; Control4 never switches the box, and the box's own automatic switching picks the input [assumed: Hue side] | Sync controls only | Unchanged | Fallback for installs that do not want the box in the path |

**HDMI audio, ARC and eARC.** Control4 models signals one way, provider to
consumer [verified: FUND 11/_1, `consumer`]. With the box before the TV, an
HDMI audio path runs source, box (3000+n to 4000), TV. Where the audio plays
is the room's Video Audio End Point: the TV's speakers, or a soundbar or AVR
bound from the TV's audio output, which is how an ARC or eARC return is
modelled [assumed]. With an AVR between the box and the TV, the box's 2000
and 4000 bind to the AVR, and the AVR keeps the audio [assumed]. Whether the
box passes or provides an ARC/eARC return of its own is [assumed: Hue side].
If it does, Control4 still models only the forward path.

## 2. Programmatic control

### 2.1 What the avswitch proxy already gives programming

Composer combines a driver's commands with its proxy's actions in the device's
programming Actions [verified: FUND 15_composerpro_interface_into_the_sdk/_7-PROGRAMMING.md].
So the proxy's `ON`, `OFF` and input commands appear without work [assumed:
exactly which proxy actions Composer lists for an `avswitch`]. Everything
specific to the box is the driver's own, through `<commands>`, `<events>`,
`<conditionals>`, variables and properties.

### 2.2 Commands (`<commands>`, device specific)

Director hands each command, programming's included, to `ExecuteCommand`
with a table of its parameters [verified: API
5_director_command/_1-ExecuteCommand.md]. Parameter types include LIST,
RANGED_INTEGER, DYNAMIC_LIST (filled by `GetCommandParamList`) and
DEVICE_SELECTOR [verified: FUND 9_commands/_1-COMMANDS.md]. DYNAMIC_LIST parameters and `sort_order` are
OS 3.3.0 [verified: FUND 3_what's_new/_12-WHATSNEWIN330.md]. Names and
parameters never change once released [verified: FUND
14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md; house:
`src/hue_light/driver.xml` comment].

| Command (proposed) | Parameters | Note |
|---|---|---|
| Start Sync / Stop Sync / Toggle Sync | none | The everyday control |
| Set Sync Mode | LIST: Video, Music, Game | [assumed: Hue side] mode names |
| Set Intensity | LIST: Subtle, Moderate, High, Intense | [assumed: Hue side] |
| Set Brightness | RANGED_INTEGER, percent | [assumed: Hue side] range |
| Set Entertainment Area | DYNAMIC_LIST of the box's areas | Needs the list from the box or the bridge |
| Select HDMI Input | LIST: HDMI 1 to HDMI 4 | Bypasses Control4's pathing, so the room does not follow (§1.5); offer with that warning, or leave input selection to the proxy |
| Power Save / Wake (or Passthrough) | none | [assumed: Hue side] the box's power states |

### 2.3 Events

`<events>` with fixed ids fired by `C4:FireEvent` or `C4:FireEventByID`, and
`sort_order` for the order in Programming [verified: API 7_event/_3, _4;
FUND 12.5_Events/_10-SORTINGEVENTSINCOMPOSERPRO.md]. An event id is never
removed or renumbered [verified: FUND 14/_2]. Proposed: Sync Started, Sync
Stopped, Sync Mode Changed, HDMI Input Changed (from any cause, including
the Hue app), Entertainment Area Changed, Online, Offline, and possibly HDMI
Signal Lost or Found per input [assumed: Hue side, the box reports it].

### 2.4 Conditionals

`<conditionals>` answered by `TestCondition` [verified: FUND
10_conditionals/_1-OVERVIEW.md, _4-USINGTHETESTCONDITIONFUNCTION.md]. The
types are LIST, STRING, NUMBER, BOOL, SIMPLE, ROOM and DEVICE [verified: FUND
10/_1]. Proposed: BOOL Sync Active, LIST Sync Mode, LIST HDMI Input, LIST
Intensity, NUMBER Brightness, BOOL Online. Dynamic conditionals are OS 4.1.0
only [verified: FUND 3_what's_new/_5-WhatsNewin400.md], so the lists are
static.

### 2.5 Variables

`C4:AddVariable` in OnDriverInit, always in the same order, since programming
refers to variable ids; types BOOL, INT, NUMBER, STRING and others [verified:
API 36_variable/_1-AddVariable.md]. `hue_motion` already does this: read-only
variables starting from persisted values, set before the events fire [house:
`src/hue_motion/driver.lua`, `add_variables`, `update_variables`,
`fire_events`]. Proposed: SYNC_ACTIVE (BOOL), SYNC_MODE (STRING), HDMI_INPUT
(INT), INTENSITY (STRING), BRIGHTNESS (NUMBER), ENTERTAINMENT_AREA (STRING),
ONLINE (BOOL).

### 2.6 Properties

As the other drivers have them: Driver Version, Status, Online, Last Action,
Debug Mode [house: `src/hue_scene/driver.xml`]. Plus the box's identity
(name, model, firmware), the current input and the source bound to each
input (§1.4), the sync state, and the chosen entertainment area, which could
be a DYNAMIC_LIST property [verified: FUND
15_composerpro_interface_into_the_sdk/_2-DYNAMICLISTPROPERTIES.md]. The
routing behaviours of §1.5 ("when Control4 routes through the box", "when
the box is released") would also be properties. The house keeps actions few
[house: `docs/simplify-actions-design.md`].

### 2.7 Navigator surface

| Option | What it gives | Limits |
|---|---|---|
| **UI Button proxy (`uibutton`)** | A button on any experience menu (Watch, Listen, Comfort, Security), placed per room through Composer's room menu settings [verified: UIB 103_ui_button_proxy_overview/_1-UIBUTTONPROXYOVERVIEW.md]. A tap sends `SELECT` with the room and the menu [verified: UIB 107_ui_button_proxy_commands/_1-SELECT.md]; `ICON_CHANGED` switches its icon between states, e.g. sync on and off [verified: UIB 106/_1-ICONCHANGED.md, 104/_1] | One action per button (a toggle); the state icons are 70, 90 and 300 px [verified: UIB 104/_1] |
| UI Button with a web view | An HTML page on touchscreens, and in the mobile app with `mobile_web_view_enabled` (OS 3.0.0+); a JavaScript API to send commands and follow variables (OS 3.1.3+, app 321.46+) [verified: UIB 103/_1, 104/_1, 109_ui_button_webview_js_api/] | Uncertified; Snap One calls it supplementary to the proxy UI; our own HTML to test on every Navigator [verified: UIB 103/_1] |
| light_v2 "Sync" device | A Lighting tile: on/off as sync, slider as brightness; keypad Button Links with LEDs through the existing keypad machine [house: `src/common/device.lua`] | Sync is not a light; the lighting guidelines put lights, not experiences, in Lighting [house: `docs/c4-lighting-guidelines.md` L58]; mode and area have no place on a tile |
| Media service proxy | Browsing media | No fit |

**What dealers expect.** A commercial Control4 driver for the box
(Janus Technology, on Driver Central) switches the HDMI input through an AV
Switch proxy. It also has a light proxy for sync brightness, a button proxy
and a relay connection to toggle sync, a UI Button for sync, mode, intensity
and area, custom commands, and events, variables and conditionals. It was
tested on OS 3.4.0 to 3.4.1 and 4.0.0 [community: Driver Central]. So the
AV switch with a Watch-menu button is the idiomatic shape, and the light is
an extra.

**Keypads.** A keypad button can run "Toggle Sync" through programming, with
its LED set from the events or conditionals [assumed: standard Composer
programming]. Automatic LED feedback, as on our lights, needs a light_v2
proxy with Button Links [house: `docs/keypad-design.md`].

## 3. The room

### 3.1 What being in a room means for an AV device

- Every device sits in a room in Composer. Programming shows it as
  "Room->Device" through the NAME macro [verified: FUND
  10_conditionals/_5-XMLINALISTTYPECONDITIONAL.md].
- `C4:RoomGetId()` returns the room that contains the driver [verified: API
  22_miscellaneous/_33-RoomGetID.md]. `C4:GetRoomID`, for another
  device's room, is OS 4.1.0 only [verified: API 9_helper/_9.5-getroomid.md].
- A driver can watch its room's variables with `C4:RegisterVariableListener`.
  They include the currently selected device, the current video device, the
  current video path and the power state [verified: API
  36_variable/_12-ListofRoomVariables.md, _10-RegisterVariableListener.md].
  The example gives 1000 for the selected device and 1019 for "in
  navigation". By that order, the current video device is 1002 and the power
  state 1010 [assumed: ids derived from the list's order].
- A room has a Video End Point (default the TV), Audio End Points, a Video
  Audio End Point, Video and Audio Volume slots and an On-Screen Device
  [verified: C4 docs room_connection_types].
- The Watch menu lists the room's video sources. Which ones appear follows
  the paths to the Video End Point and the room's Navigator settings
  [assumed]. A UI Button is shown on a room's menu through those same
  settings [verified: UIB 103/_1, its demo steps].

### 3.2 Does the switch need to be in the room it serves?

For routing, no. Paths follow bindings from a source to the room's
endpoints, and the SDK's example runs through devices that are not the
room's [verified: PP 116/_1; FUND 11/_4; C4 docs get_room_connections]. A
rack switch serving several rooms sits in one room and works in all
[assumed: common dealer practice, consistent with the above].

For people, yes: put the box in the TV's room. Then its programming name
reads "Living Room->Hue Sync Box", its Watch button belongs to that room's
menu, and `C4:RoomGetId()` gives the room whose power state and current
video device the driver may watch.

### 3.3 One box, one TV, one room

This is the simple case, and the likely one for a single TV. Sources bind to HDMI 1
to 4, the box's output binds to a TV input, and the TV is the Video End
Point. Every source on the box appears in that room's Watch menu [assumed].
The box is on whenever one of them is watched, and released when the room
turns off or watches the TV's own apps [assumed; P1 and P4]. The driver can
check that independently of Director's commands with the room's power state
and current video device (§3.1). Snap One prefers that AV drivers act on the
commands they get, not mimic pathing [verified: PP 116/_1], so the room
watcher is a fallback, not the main signal.

### 3.4 Is a Hue entertainment area a Control4 room?

The owner's first guess holds in the simple case only.

| Case | Area maps to one Control4 room? |
|---|---|
| One TV, one area made from that room's lamps | Yes |
| Open plan: the area's lamps sit in Hue rooms that map to two Control4 rooms | No single room |
| Two areas for one TV (all lamps, or only the light strip) | The room has several; the box uses one at a time [assumed: Hue side] |
| The same area used by another streamer (the Hue app on a PC, a TV app) | The area is not the box's alone [assumed: Hue side] |
| The box moves to another TV | The area must change; the device moves rooms in Composer |

So the area is a setting of the box device: which area it drives. The box
device's room is the TV's room. The bridge already maps Hue rooms to Control4
rooms for scenes [house: `docs/c4-lighting-guidelines.md` L58 note, #469].
It could offer the area whose lamps lie in the box's room as the first
choice, but must not set it by itself. Whether that offer is worth having is
the edge-case research's call (Recommendations, items 4 and 6).

The room's own lights matter too. While the box syncs, it drives the area's
lamps, and the room's Hue Light tiles are on the same lamps. How those tiles
behave during sync is [assumed: Hue side], and it belongs in the contract's
"Control4 guidelines" section.

## 4. Codebase fit

### 4.1 What a `hue_syncbox` driver shares

| Piece | Today | For the box |
|---|---|---|
| `common/log.lua`, `common/dispatch.lua`, `common/num.lua` | All drivers [house: `src/common/`] | As is: `ExecuteCommand`, `ReceivedFromProxy`, `OnPropertyChanged` routing; with `device.lua`'s `proxy_binding_ok`, proxy commands are taken on 5001 only, which suits the `avswitch` there |
| `common/device.lua` | Light and scene in full, motion in part (bridge binding, properties, goodbye) [house: its header] | The motion way: Driver Version and Debug Mode rows, build-kind checks, the bridge binding and its re-check after a Director restart, the goodbye on delete. Its keypad machine and Button Links are light_v2 only and stay unused unless a light_v2 proxy comes |
| `common/link.lua` | `HUE_BRIDGE_LINK` offline texts [house] | If the box binds to the bridge |
| `common/devloop.lua` | Dev builds of every driver [house: `docs/dev-loop.md`] | As is; the probes of §6 need it |
| Bridge binding (control 1, `HUE_BRIDGE`, consumer) | Light, scene, motion [house: `src/hue_light/driver.xml`, `src/hue_scene/driver.xml`, `src/hue_motion/driver.xml`] | Optional: for area names, the bridge's link state and the import flow. Whether the box needs the bridge at all is [assumed: Hue side] (it has its own API) |
| Programming conventions | Fixed ids, `sort_order`, read-only variables, `TestCondition` [house: `src/hue_motion/driver.xml`, `driver.lua`] | Same |
| Manual, icons, minimum OS | `www/documentation.html` with the changelog, 16 and 32 px icons, `minimum_os_version` 3.3.0 [house: `docs/c4-lighting-guidelines.md` L61; the four `driver.xml`] | Same |

### 4.2 What is new

- **The first AV proxy in the project**: the connections of §1.2, the
  commands of §1.3, a queue that sequences them, and a fake-C4 spec that
  replays Director's real parameter shapes (from P1).
- **Its own HTTPS client to the box.** The bridge's `bridge/http.lua` lives
  in the bridge's tree, and the bridge package strips `common/device.lua`
  [house: `tools/build.sh`]. The client either moves to `common/` or the box
  gets its own. Its traffic counts against Director's four `C4:url`
  transfers per controller [house: `src/hue_bridge/bridge/http.lua` header].
  Pairing, the box's certificate and token storage are [assumed: Hue side].
- **A room watcher** (`RegisterVariableListener`, `OnWatchedVariableChanged`):
  not used anywhere in `src/` today [house].
- **Possibly a second proxy** (`uibutton` on 5002) and its Navigator icons.
- **A fifth package** in `tools/build.sh`, `tools/check.sh` and the release
  assets (the coordinator's).

### 4.3 What is fixed at the first release

A driver may never add, remove or change a proxy after release. Each proxy is
created, with its internal binding, only when the device is added; an update
with a different proxy set corrupts the project. Connections may only be
added, and events, commands and variables only added [verified: FUND 14/_2].
So the 2.0 package fixes its proxies (`avswitch` alone, or `avswitch` plus
`uibutton`) and its ten AV connections for good. A light_v2 "Sync" device
could still come later as a separate small driver bound to the box driver,
as the light and scene drivers bind to the bridge [house]. In a driver with
several proxies, each proxy gets its own proxy device and an internal
binding when the device is added, with no dealer binding [verified: FUND
14/_2, 8/_1, 11_connections/_5-PROXYBINDINGMULTIPLE.md]; one driver may use
several proxy types [verified: PP 2_introduction/_1-INTRODUCTION.md;
SDK-GH universal_minidrivers/um_driver.xml, a media driver with an extra
`avswitch`]. How Composer shows the two devices is [assumed].

## 5. OS 3.x and 4.x

| Feature | OS | At our 3.3.0 floor |
|---|---|---|
| `avswitch` proxy, `SET_INPUT`, `ON`/`OFF`, `INPUT_OUTPUT_CHANGED` | Long-standing; no what's-new entry changes them [verified: PP 3_whats_new/] | Yes |
| Favoured and blocked connection classes | 3.2.0 [verified: FUND 11/_8] | Not needed |
| Navigator EQ for AV switches | 3.2.3, hidden unless enabled [verified: PP 3/_13; FUND 27_proxy_specific_info/_20-AVSWITCHNAVEQ.md] | Not used |
| Hidden AV bindings (`allow_dynamic_resize`) | 3.3.0 [verified: PP 3/_12, 8.8/_1] | Not needed |
| DYNAMIC_LIST command parameters, `sort_order` | 3.3.0 [verified: FUND 3/_12] | Yes |
| UI Button; web view; JS API | 2.9.0; 2.10.0; OS 3.1.3 and app 321.46 [verified: UIB 103/_1]; mobile web view 3.0.0 [verified: UIB 104/_1] | Yes |
| `allow_audio_pathing` (media player with an AV switch) | 3.4.0 [verified: PP 3/_9; PP 16.5_generic_media_player_capabilities/_14-ALLOWAUDIOPATHING.md] | Not relevant |
| `PREV_DEV_LIST` in `SET_INPUT`, `CONNECT_OUTPUT`, `DISCONNECT_OUTPUT` | 3.4.2 [verified: PP 3/_7] | On the house (3.4.3), absent on 3.3.x: never required |
| Nesting a driver under another in System Design | 3.4.2 [verified: PP 3/_7] | Optional, above the floor |
| `C4:GetBoundPartner` | 4.0.0 [verified: API 9_helper/_5.8-GETBOUNDPARTNER.md] | No; `GetBoundProviderDevice` instead |
| `C4:GetRoomID(proxyId)` | 4.1.0 [verified: API 9/_9.5] | No; `RoomGetId` (1.6.0) instead |
| Non-binding connections (media over IP) | 4.1.0 samples [verified: FUND 11/_4] | Not needed |
| Dynamic commands and conditionals | 4.1.0 [verified: FUND 3/_5] | No |

The proxy guide's what's-new ends at 3.4.2 and has no AV routing change
after it [verified: PP 3_whats_new/]. The API and fundamentals pages for
4.0 to 4.2 add only the helpers above [verified: API
3_whats_new/_5-WhatsNewin420.md, _6-WhatsNewin410.md, _7-WhatsNewin400.md;
FUND 3_what's_new/_5, _6]. Routing on 4.x is therefore [assumed] the same.
The commercial driver's test on OS 4.0.0 is consistent with that
[community: Driver Central].

## 6. Probes

All of these use the dev loop [house: `docs/dev-loop.md`] with a skeleton
`avswitch` driver that logs every `ReceivedFromProxy` with all parameters
and times. None needs the box itself: Director sends the commands to the
driver whether or not a box is on the cable. They do need the skeleton bound
in Composer between real sources and a TV, which changes that room's AV
connections while the probe runs [assumed].

| Probe | Question | Settles |
|---|---|---|
| P1 | The exact commands and parameters for: pick a source, switch source, pick a TV app, Room Off, and a Director restart | §1.3, §1.5 steps 3 to 7 |
| P2 | Order and spacing of `ON` and `SET_INPUT`; what Director does if `INPUT_OUTPUT_CHANGED` comes late or never | §1.5 sequencing |
| P3 | One `SET_INPUT` with `AUDIO` and `VIDEO`, or two | §1.4 |
| P4 | Whether Room Off and a TV app send `OFF` or `DISCONNECT_OUTPUT` to the box | §3.3 |
| P5 | `BINDING_CHANGE_ACTION` when a source is bound or unbound in Composer; `GET_AUDIO_INPUTS` at start | §1.3 |
| P6 | The room variables 1002 and 1010 during P1 | §3.1 ids |
| P7 | Which proxy actions Composer lists for the device in Programming | §2.1 |

## Recommendations for the design

1. Model the box as one `avswitch` device between the sources and the TV,
   with the ten HDMI connections and the capabilities of §1.2. Treat the
   capabilities as fixed from the first release.
2. Handle `ON`, `OFF`, `SET_INPUT`, `CONNECT_OUTPUT`, `DISCONNECT_OUTPUT` and
   `BINDING_CHANGE_ACTION` with the parameters of §1.3. Answer `ON`, `OFF`
   and `INPUT_OUTPUT_CHANGED` (`INPUT`, `OUTPUT`, `AUDIO`, `VIDEO`) only once
   the box confirms. Never depend on `PREV_DEV_LIST`.
3. Sequence inside the driver: one queue per box, wake, switch, read back,
   confirm, with retries like Snap One's template (2 s, 4 tries, as a
   starting point the contract fixes).
4. Make what routing does to sync a setting, not a fixed behaviour: what
   happens when Control4 routes a source through the box, and what happens
   when the box is released. Defaults come from the owner (Open questions 2).
   Because this acts by itself over the life of the system, its lifecycle
   cases go through edge-case research before the contract.
5. Never move a Control4 room because of a change made outside Control4.
   Show such changes in the driver's properties, variables and events only,
   as Snap One advises. Any "follow the box" mode would be opt-in, with a
   dealer map of inputs to sources and a room.
6. Put the box device in the TV's room. Keep the entertainment area a box
   setting, with the area whose lamps are in that room offered as the first
   choice, never chosen silently.
7. Give programming the commands, events, conditionals and read-only
   variables of §2.2 to §2.5, with names and ids fixed at release and the
   `hue_motion` pattern for variables before events.
8. For Navigator, use a UI Button in the room's Watch menu that toggles sync
   and shows its state. Leave a light_v2 "Sync" tile out of 2.0; it can come
   later as a separate driver if keypads with automatic LEDs are wanted.
9. Reuse `common/` as `hue_motion` does. Write the new pieces (box client,
   AV handler, room watcher) as modules with specs, and give the fake C4
   runtime the parameter shapes P1 records.
10. Keep `minimum_os_version` 3.3.0 and use no 4.x-only API.
11. Run P1 to P7 through the dev loop before the contract is final; they do
    not need the box.
12. Decide the bridge binding after the Hue-side notes: keep binding 1
    (`HUE_BRIDGE`) if area names or the bridge's link state come from the
    bridge, and make the box work without it if its own API is enough.

## Open questions for the owner

1. **Navigator.** A Watch-menu UI Button (a second proxy in the 2.0 package,
   fixed for good), a separate later light_v2 "Sync" tile for keypads, both,
   or programming only?
2. **What routing does to sync.** When Control4 picks a source through the
   box: start sync (in which mode), or only pass the picture? At Room Off:
   stop sync, put the box in power save, or leave it?
3. **Who owns the input.** Turn the box's own automatic input switching off
   so that Control4 alone picks inputs, or keep it and accept that the
   room's Watch screen can go out of step?
4. **The area.** Set once per box by the dealer, or offered from the box's
   Control4 room each time the room changes?

## Sources

- Snap One DriverWorks SDK under `~/c4-tools/reference/` (paths in the
  markers above).
- Snap One template code: https://github.com/snap-one/drivers-template-code-public
  (`proxies/avswitch_proxy/`, commit `50eee83`).
- Snap One SDK samples: https://github.com/snap-one/docs-driverworks
  (`Jumpstart/SampleDriverFiles/AcmeAVSwitch.json` and
  `universal_minidrivers/um_driver.xml`, commit `36076bb`).
- Control4 Composer Pro help:
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/room_connection_types.htm,
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/get_room_connections.htm,
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/connect_and_verify_devices.htm,
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/editing_power_management_options.htm.
- Janus Technology, "Philips Hue HDMI Sync Box" driver page:
  https://drivercentral.io/platforms/control4-drivers/audio-video/philips-hue-hdmi-sync-box/.
- This repository: [`src/hue_light/driver.xml`](../src/hue_light/driver.xml),
  [`src/hue_scene/driver.xml`](../src/hue_scene/driver.xml),
  [`src/hue_motion/driver.xml`](../src/hue_motion/driver.xml),
  [`src/hue_motion/driver.lua`](../src/hue_motion/driver.lua),
  [`src/common/device.lua`](../src/common/device.lua),
  [`src/hue_bridge/bridge/http.lua`](../src/hue_bridge/bridge/http.lua),
  [`tools/build.sh`](../tools/build.sh),
  [`docs/c4-lighting-guidelines.md`](c4-lighting-guidelines.md),
  [`docs/keypad-design.md`](keypad-design.md),
  [`docs/dev-loop.md`](dev-loop.md),
  [`docs/design.md`](design.md),
  [`docs/simplify-actions-design.md`](simplify-actions-design.md),
  [`docs/motion-control4-research.md`](motion-control4-research.md) (the
  same kind of note for #268).
