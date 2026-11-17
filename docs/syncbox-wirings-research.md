# The sync box in every wiring: Control4 research for #531

**Status (2026-11-16): research for issue #531, read-only; nothing here is
approved or built.** It answers the questions that
[`hdmi-sync-design.md`](hdmi-sync-design.md) §5.8 leaves open before beta
stage 3: how the Hue Sync Box driver learns a room's power and current
source, what Director sends the box behind a receiver, how a dealer should
connect a box fed from a receiver's second output, the lifecycle cases of
following a room, the probes that settle the rest, and what the contract
and the stage 2 frame need. It builds on
[`syncbox-control4-research.md`](syncbox-control4-research.md) (R3: the AV
switch model and probes P1 to P7), [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md)
(C1 to C4), [`edge-cases-syncbox.md`](edge-cases-syncbox.md) (the C and I
rows) and [`hdmi-sync-stage2-design.md`](hdmi-sync-stage2-design.md).

The three wirings (O17), as the design names them:

| Wiring | Signal path | Box setting |
|---|---|---|
| **In line** | sources → box → receiver or TV | neither |
| **Behind a receiver** | sources → receiver → box → TV | `arcBypassMode` |
| **Second output** | sources → receiver → TV; the receiver's second HDMI output → box; nothing on the box's output | `soloMode` |

Snap One documents and code are paraphrased; only interface names
(functions, commands, parameters, variable and class names) appear as
written. This is not legal advice.

Markers, as in R3:

- **[verified: API x/_y]** = `~/c4-tools/reference/docs-driverworks-api/source/includes/<x>/<_y>.md`;
  **FUND** = `docs-driverworks-fundamentals/source/includes/`;
  **PP** = `docs-driverworks-proxyprotocol/source/includes/`;
  **XML** = `docs-driverworks-xml/source/includes/`.
- **[verified: CL file]** = Snap One's helper library
  `~/c4-tools/drivers-common-public/<file>`, read only, never vendored. It is
  not the SDK, but it is Snap One's own code calling the same APIs.
- **[verified: TPL file]** = Snap One's public template,
  https://github.com/snap-one/drivers-template-code-public, commit `50eee83`,
  `proxies/avswitch_proxy/<file>`, read into the scratch folder with `gh api`.
- **[verified: C4 docs page]** = Control4's public Composer Pro help page of
  that name, read on 2026-11-16 (URL under Sources).
- **[house]** = this repository's code or a hardware finding recorded in it.
- **[assumed]** = inference or undocumented; §6 names the probe that settles it.

## Short answers

**The stage 2 frame (question 7, the urgent part): freeze contracts C1.1 to
C1.3 exactly as written. No wiring needs another proxy, connection or
capability.**

- In line uses HDMI 1 to 4 and HDMI Out. Behind a receiver uses HDMI 1
  (video 1000, audio 3000) and HDMI Out (2000, 4000). Both are declared.
- From a second output, Director builds no path through the box at all. The
  driver follows a room by listening to the room's variables, and that
  needs no binding of any kind [verified: API 36_variable/_10-RegisterVariableListener.md,
  _12-ListofRoomVariables.md].
- **Two things are left out on purpose.** A room binding (type 7, ids 7000
  to 7999) is what lets Composer offer a device as a room's endpoint:
  receivers and TVs declare one with the `VIDEO_SELECTION` and
  `AUDIO_SELECTION` classes [verified: PP 116_proxy_and_protocol_best_practices/_2-AUTOBINDINGSANDTVDRIVERS.md;
  XML 15_common_xml/_34-connections.md]. A room has one Video End Point
  [verified: C4 docs room_connection_types], and it must stay the TV, so a
  room binding on the box would only invite a wrong endpoint. A Power
  Manager binding (8000 to 8999) has a documented id range and nothing else
  [verified: FUND 11_connections/_1-OVERVIEW.md]; nothing can be built on it.
- **The AV set is frozen in practice, not only "add-only".** Connections may
  only be added after release [verified: FUND 14_updating_released_drivers/_2-DRIVERUPDATECONSIDERATIONS.md],
  but `video_consumer_count` and its siblings must match the connections
  [verified: PP 6_audio_video_switch_capabilities/_21-VIDEOCONSUMERCOUNT.md],
  so any AV connection added later also changes a capability, which costs
  every installer a controller reboot [house: CLAUDE.md "Environment"].
  Keep all four inputs and the four audio connections: the behind-a-receiver
  and in-line paths use them.
- **Properties and actions are not part of the frozen frame.** They can be
  added or removed in any later build [verified: FUND 14/_2]. Follow Room,
  the per-source sync modes and their action can all come in stage 3 or 4.
- **Stage 2 should prepare two small things** (§7.3): log every proxy
  command with all its parameters at debug, so the stage 2 beta is itself
  the probe logger for P1 to P5 and P9 to P11; and have the manual (agent E)
  say how to connect each wiring, including "in solo mode, never connect the
  box's HDMI Out".

**Question 1, room state.** A driver reads a room like any other device:
`C4:RegisterVariableListener(roomId, varId)` and `OnWatchedVariableChanged`
(both since 1.6.0), `C4:GetDeviceVariable` (1.6.0) and
`C4:GetDeviceVariables` (2.8.0) [verified: API 36/_9, _10, _5; API
22_miscellaneous/_12-GetDeviceVariables.md]. The room's variables are 1000
plus their position in the SDK's list: 1000 the selected device, 1001 the
current audio device, 1002 the current video device, 1007 to 1009 the audio,
video and video-audio paths, 1010 the power state [verified: API 36/_12;
CL global/lib.lua `ROOM_VARS` agrees id for id]. No system event reports a
room's power or selection [verified: API 7_event/_1, _5.5]. All of this is
below the 3.3.0 floor and unchanged through 4.2 [verified: API
3_whats_new/]. What is **not** documented: the value formats of 1002, 1008
and 1010, whether ids are proxy or protocol ids, and how a Listen selection
shows. Probe P8 settles them; the driver should look the ids up by name at
start and fall back to the numbers.

**Question 2, the source's kind.** `C4:GetDevices{DeviceIds = "<id>"}` gives
the device's name, its proxy's driver file (for example `light_v2.c4i`) and,
from a proxy id, the protocol driver's file [verified: API
22_miscellaneous/_9-GetDevices.md; house: docs/design.md "Project APIs"].
That tells a video source from an audio-only one, but **Control4 has no game
console proxy** [verified: PP includes, the proxy list], so Game can only
come from the box's own input type (in line), the dealer's setting, or a hint
in the source's driver file name. A Listen selection is a property of the
selection, not of the device: an Apple TV can be picked under Listen. It
shows as an audio path with no video path [assumed: P8].

**Question 3, behind a receiver.** Director treats the receiver → box → TV
chain like any other: `ON`, `SET_INPUT` with `INPUT` 1000 (and 3000 if the
audio is connected), `OUTPUT` 2000, and `OFF` or `DISCONNECT_OUTPUT` when the
box leaves the path [assumed: standard pathing; P10]. Whether Director sends
`SET_INPUT` again when the source changes but the box's input does not is
not documented; if it does not, only the room's variables say the source
changed. `PREV_DEV_LIST` (3.4.2 and later) is meant to list what lies
upstream, but the two SDK pages disagree on whether it holds the device
directly upstream or all of them, and neither gives its format [verified: PP
3_whats_new/_7-WHATSNEWIN342.md; PP 8_audio_video_switch_proxy_commands/_46-SETINPUT.md].
Snap One's template passes it through unparsed [verified: TPL
avswitch_device_class.lua, `PrxSetInput`]. So: room variables are the
floor-compatible way; `PREV_DEV_LIST` is at most a hint on 3.4.2 and later.

**Question 4, the second output.** Leave the box's HDMI Out unconnected,
always. Connecting the receiver's second HDMI output to the box's HDMI 1 is
optional and recommended where the receiver's driver offers that output. It
changes nothing in Director's path choice (no path can end at the box), and
it lets the driver tell whether the room's current source passes the
receiver at all [assumed: P11]. Connecting the box's HDMI Out to anything in
solo mode would create a path that does not exist on the cables, which
Director may then choose.

**Question 5, Follow Room.** Twenty-four cases in §5. The rules: a room is
stored by id; the default "This device's room" follows the device wherever
it moves; a deleted room stops the following and is never replaced by
itself; the first value after start is a baseline, never a command; nothing
selected outside Control4 is seen or corrected; two boxes on one room must
never take each other's stream over.

**Question 6, probes.** P8 to P13 extend P1 to P7 (§6). P8 (room variables)
needs no Composer change and should run first. P10 and P11 use a scratch
room of generic drivers and an unpaired second box device, so the bedroom is
not disturbed. H1 is the house check of #531 on the real box on the second
output.

**Question 7, the contract.** A Follow Room property, per-source sync modes
for the two wirings where the input cannot name the source, three new
modules (`room.lua`, `sources.lua`, `follow.lua`) and the fake runtime's
variable listeners, all in stage 3 or 4 (§7).

## 1. What a driver can learn about a room (question 1)

### 1.1 The APIs

| API | What it does | Since | At the 3.3.0 floor |
|---|---|---|---|
| `C4:RegisterVariableListener(idDevice, idVariable)` | Watch another device's variable; changes arrive in `OnWatchedVariableChanged(idDevice, idVariable, strValue)`. The callback also runs **once at once** after the listener is set. It fails if the variable does not exist [verified: API 36/_10] | 1.6.0 | Yes |
| `C4:UnregisterVariableListener`, `C4:UnregisterAllVariableListeners()` | Stop one, or all [verified: API 36/_11, _10.5] | 1.6.0; the "all" call is 3.3.0 on its page and 3.2.1/3.2.2 in the what's-new pages [verified: API 3_whats_new/_15, _16] | Yes |
| `C4:GetDeviceVariable(idDevice, idVariable)` | Read one value; nil if not found; not in `OnDriverInit` [verified: API 36/_5] | 1.6.0 | Yes |
| `C4:GetDeviceVariables(id)` | Every variable of a device with its details; not in `OnDriverInit` [verified: API 22/_12] | 2.8.0 | Yes |
| `C4:RoomGetId()` | The room that contains this driver; not in `OnDriverInit` [verified: API 22/_33] | 1.6.0 | Yes |
| `C4:GetDevicesByC4iName("roomdevice.c4i")` | `{ [roomId] = name }` for every room | undocumented | Yes [house: verified on OS 3.4.2, docs/design.md "Project APIs"; CL global/msp.lua `RegisterRooms` uses it the same way] |
| `C4:GetRoomID(proxyId)` | The room of another device | 4.1.0 [verified: API 9_helper/_9.5-getroomid.md] | **No**; use `GetDevices`' `roomId` instead |
| `C4:RegisterSystemEvent(id, 0)` | Project events: `OnPIP`, network bindings, device online and offline, location, locale, Director address; `OnItemAdded`, `OnItemRemoved`, `OnItemNameChanged` by name [verified: API 7_event/_1, _5.5] | — | Yes; **none is about a room's power or selection** |
| `C4:RegisterDeviceEvent(deviceId, eventId)` | Another driver's events by id [verified: API 7/_5] | 2.9.0 | The room's event ids are not documented [assumed: a fallback only, probed in P8] |

The safe-usage table marks `RegisterVariableListener` as unreliable before
`OnDriverLateInit` when the variable does not exist yet, and every read above
as "not in `OnDriverInit`" [verified: API 22/_25.2-SafeUsageTable.md]. So the
room watcher starts in `OnDriverLateInit`, inside `pcall`.

### 1.2 The room's variables

The SDK lists the room's variables in order and its example watches 1000
(the selected device) and 1019 (in navigation), which fits "1000 plus the
position" [verified: API 36/_12]. Snap One's helper library names the same
ids, id for id, and watches 1000 and 1007 on every room [verified: CL
global/lib.lua `ROOM_VARS`; global/msp.lua `RegisterRooms`]. The ones that
matter here:

| Id | Name (library) | Use for the box | Value |
|---|---|---|---|
| 1000 | `CURRENT_SELECTED_DEVICE` | What the room is on | A device id as text; the SDK's example output shows `7` [verified: API 36/_12]; the library reads it as a number, 0 when none [verified: CL global/msp.lua `OWVC.ParseRoomIdSource`] |
| 1001 | `CURRENT_AUDIO_DEVICE` | The Listen source, or the Watch source's audio | [assumed] a device id |
| 1002 | `CURRENT_VIDEO_DEVICE` | The Watch source | [assumed] a device id, 0 for none |
| 1007 | `CURRENT_AUDIO_PATH` | A Listen path | Text with one `<id>` element per device on the path [verified: CL global/msp.lua `OWVC.ParseRoomIdRoute`] |
| 1008 | `CURRENT_VIDEO_PATH` | Whether the box, or the receiver feeding it, is on the picture's path | [assumed] as 1007 |
| 1009 | `CURRENT_VIDEO_AUDIO_PATH` | The Watch source's audio path | [assumed] as 1007 |
| 1010 | `POWER_STATE` | Room on or off | [assumed] format unknown |
| 1026, 1027 | `ROOMOFF_IS_LINKED`, `SELECTIONS_LINKED` | Linked rooms (§5, W8) | [assumed] |

Two cautions:
- Whether the ids are proxy ids or protocol ids is not documented
  [assumed: proxy ids, since a room selects a proxy]. `GetDevices` accepts
  either [verified: API 22/_9], so the driver need not care.
- The library also names 1036 `PLAYING_AUDIO_DEVICE` (the service behind
  Control4's own digital audio), which the SDK list lacks [verified: CL
  global/lib.lua]. Nothing should depend on it.

**Recommendation.** At late init, call `GetDeviceVariables(roomId)` and take
the ids by name when it answers; otherwise use the numbers above. That
survives a renumbering on a later OS, and P8 checks the names on 3.4.3.

### 1.3 What the driver can rely on from OS 3.3.0 up

- Listening to 1000, 1002, 1007 to 1010 of any room; reading them on demand;
  an immediate first callback with the current value [verified: API 36/_10].
- Knowing its own room (`RoomGetId`) and every room's id and name.
- Reading any device's name, driver file and proxies by id (`GetDevices`,
  2.10.0) [verified: API 22/_9].
- Nothing on 3.3.x that names the upstream source in an AV command:
  `PREV_DEV_LIST` is 3.4.2 [verified: PP 3_whats_new/_7-WHATSNEWIN342.md].
- On 4.x nothing documented changes any of this: the 4.0 to 4.2 pages add
  `GetBoundPartner`, `GetRoomID` and dynamic commands only [verified: API
  3_whats_new/_5, _6, _7].

Snap One asks AV drivers to act on the commands they receive and not mimic
pathing [verified: PP 116/_1-AVPATHINGUNSOLICITEDNOTIFICATIONSANDCONTROL4UI.md].
Reading the room's variables is not pathing: the driver selects nothing and
moves no room. It only decides what the box does with its own sync. The same
page names a "room selector property" as the dealer-facing way to tie a
driver to a room, which is what Follow Room is.

## 2. The selected source's kind, and Listen (question 2)

### 2.1 From a device id to a kind

| Call | Gives | Status |
|---|---|---|
| `C4:GetDevices{DeviceIds = "<id>"}` | `deviceName`, `driverFileName`, `roomId`, `roomName`; from a protocol id a `proxies` table (each with its `driverFileName`); from a proxy id a `protocol` table | [verified: API 22/_9 examples 2 and 3; house: the filter value must be a string, docs/design.md "Project APIs"] |
| `C4:GetDeviceDisplayName(id)` | The Composer name, for a proxy or a protocol id | [verified: API 32_serial_network_device/_6-GetDeviceDisplayName.md; house] |
| `C4:GetBoundProviderDevice(proxyId, binding)` on another device | What feeds that device's input; works on any device's proxy id | [verified: API 32/_4, its example reads a receiver's input 1011]; returns 0 when nothing is bound [house: OS 3.4.2] |

The proxy's driver file names the kind: a proxy declared as `tv` is
`tv.c4i`, as the house saw `light_v2.c4i` for `light_v2` [house; assumed for
the AV proxies]. The proxy guide's AV proxies are `tv`, `receiver`,
`avswitch`, generic media player, `dvd`, satellite receiver, tuner, CD player,
disc changer, amplifier and projector [verified: PP includes, the folder
list]. There is **no game console proxy**; a console's driver uses whatever
proxy its author chose [assumed: usually a media player or DVD proxy].

So the driver can tell:

| Kind | From | Mode |
|---|---|---|
| Audio-only selection (Listen) | The selection, not the device (§2.2) | Music |
| A tuner, CD player or disc changer proxy | The proxy's driver file | Music [assumed: these have no picture] |
| Any other source | — | Video |
| A game console | Not from Control4's model. In line: the box's own input type (`xbox`, `playstation`, `nintendoswitch`, design 5.3). Elsewhere: the dealer's per-source setting, or a hint in the protocol driver's file name | Game |

A name hint (`xbox`, `playstation`, `nintendo` in the protocol driver's file
name) is a guess, so the driver shows it as one: "PS5: Game (guessed from its
driver)". The display name is the dealer's text and is not used.

### 2.2 How a Listen selection shows

Nothing documents it [assumed]. What Control4's model suggests, for P8 to
confirm:
- **Listen:** 1000 and 1001 name the source; 1002 is 0 or unchanged; 1007
  holds the audio path; 1008 is empty.
- **Watch:** 1000 and 1002 name the source; 1008 holds the picture's path
  and 1009 its sound's path.
- **Room Off:** 1000 goes to 0 and 1010 changes.
- **Control4's own music service:** 1000 names Control4's digital audio
  device, not the service [verified: CL global/msp.lua compares the room's
  selected device with the digital audio device's id].

The kind belongs to the selection. An Apple TV picked under Listen is a
Music selection, and the same Apple TV under Watch is a Video one. In line,
the proxy says the same thing: an audio-only `SET_INPUT` (`AUDIO` true,
`VIDEO` false) is a Listen route through the box (design 5.3).

## 3. Behind a receiver (question 3)

### 3.1 What Director sends the box

In Composer: the sources connect to the receiver, the receiver's HDMI output
to the box's HDMI 1 (video 1000, and audio 3000 to mirror the cable), and the
box's HDMI Out to the TV. Composer makes the receiver the room's Audio End
Point and Video Audio End Point, and the TV the Video End Point [verified: C4
docs room_connection_types].

| Moment | Expected at the box | Status |
|---|---|---|
| A Watch source through the receiver | `ON`; `SET_INPUT` `INPUT` 1000, `OUTPUT` 2000, `VIDEO` true. No audio `SET_INPUT`, because the sound ends at the receiver | [assumed: standard pathing through a chain, as R3 §1.5 and B27; P10] |
| Another Watch source through the receiver | Possibly nothing: the box's own input is still 1000. Possibly the same `SET_INPUT` again | **Unknown; P10.** If nothing comes, only the room's variables say the source changed |
| A source that bypasses the receiver (the TV's own apps) | `DISCONNECT_OUTPUT`, or `OFF` | [assumed: P4, P10] |
| A Listen source on the receiver | The picture's path is torn down, so `DISCONNECT_OUTPUT` or `OFF`; the receiver plays the sound itself | [assumed: P10] |
| Room Off | `OFF` | [assumed: P4, P10] |

`ON` and `OFF` are only shown as a power state by the proxy; everything else
is the driver's [verified: PP 8/_27-OFF.md, 8/_28-ON.md].

### 3.2 Can the driver see the source without the room?

| Way | What it gives | Verdict |
|---|---|---|
| `PREV_DEV_LIST` in `SET_INPUT`, `CONNECT_OUTPUT` and `DISCONNECT_OUTPUT` | The what's-new page says it lists every device upstream, in order; the `SET_INPUT` page says it holds the device directly upstream [verified: PP 3/_7; PP 8/_46, 8/_5]. Only from 3.4.2. Its format is not given, and Snap One's template does not parse it [verified: TPL avswitch_device_class.lua, `PrxSetInput` passes it on unread] | A hint on 3.4.2 and later, if P10 shows it names the source. It arrives only with a command, so a source change that sends the box nothing is still missed |
| Walking the bindings upstream | `GetBoundProviderDevice(box, 1000)` gives the receiver; `GetBoundProviderDevice(receiver, 1000 … 1099)` gives every source connected to it [verified: API 32/_4] | Gives the **candidates**, not the current one. Useful for the per-source list (§7.2) |
| The receiver's state | The proxy guide documents no receiver variables and no receiver proxy events beyond a binding note [verified: PP includes, 21.5_receiver_proxy_events/_0-HEADER.md] | No |
| The room's variables | 1002 names the Watch source; 1008 shows whether the box is on the path | **The way.** At the 3.3.0 floor, and it hears changes that send the box nothing |

So behind a receiver the driver needs the room as well as Director's
commands: **Director's commands say when the box is on the path and when it
leaves it; the room says which source it carries.** The source's mode then
comes from the per-source settings (§7.2).

### 3.3 Which room

By default, the box device's own room, which is where the dealer puts it
(design 7.1, R3 §3.2). When the box sits elsewhere (a rack room), the driver
can find the room whose picture path runs through it: on each `SET_INPUT`,
read 1008 of every room (16 cheap reads on the house) and look for the box's
proxy id [assumed: 1008 lists proxy ids; P9]. That room is **offered** as
Follow Room, never set by itself (§5, W20).

## 4. From a receiver's second output (question 4)

### 4.1 How to connect it in Composer

| Choice | Box HDMI 1 | Box HDMI Out | Director | What the driver gains |
|---|---|---|---|---|
| **A. Not connected at all** | — | — | Never sends the box an AV command [assumed: P11] | Nothing from bindings; the room alone drives the box |
| **B. Input only (recommended where possible)** | the receiver's second HDMI output (video, and audio if the driver offers it) | — | Never sends an AV command: no path can end at the box, since an AV switch with no room binding is no endpoint and its output leads nowhere [assumed: P11] | The receiver's id, so the driver can check that the room's current source passes the receiver (1008 contains it); the Inputs row reads "1 AV Receiver (second output)"; the receiver's room can be offered as Follow Room |
| **C. Output connected too (wrong)** | as B | anything, e.g. a spare TV input | May route a source "through" the box when that path looks best, switching the TV to an input with no picture [assumed: P11b] | Nothing; the manual forbids it |

Choice B depends on the receiver's driver declaring its second HDMI output
as a separate output connection [assumed: many do, as HDMI monitor 2 or a
zone 2 output; not every one]. Where it does not, choice A is the answer.

**Consequences for Director's path choice.** In A and B the room's paths are
exactly what they were before the box existed: source → receiver → TV. The
box is never an endpoint candidate, because it declares no room binding
(§Short answers) [assumed: Composer offers as endpoints only devices with a
room binding of the matching class; P11 reads the room's endpoint lists].
In C the cables and the model disagree, which Control4's pathing cannot
detect.

### 4.2 What drives the box then

Nothing from Director. The driver follows a room (design 5.8):
- the room turns on with a source that reaches the receiver → wake, sync in
  that source's mode with the period's intensity and brightness;
- the source changes → the new source's mode;
- the room watches something that bypasses the receiver → the When The
  Source Leaves The Box setting (in B the driver knows; in A only a source
  set to "Do not sync" says so);
- Room Off → the At Room Off setting.

**Whether an audio-only source can sync** depends on the receiver sending
its sound on the second output. That is a house check (H1), not a Control4
question.

## 5. Follow Room: the lifecycle cases (question 5)

Classes as in [`edge-cases-syncbox.md`](edge-cases-syncbox.md): **auto**
(done and said), **offered** (one click accepts), **click** (only when the
owner starts it), **none**. The last column lists what the row forbids.

| # | Case | Driver sees | What it does | Class | Never without a click |
|---|---|---|---|---|---|
| W1 | Follow Room at its default, "This device's room" | `RoomGetId()` | Follows that room; Status names it | auto | — |
| W2 | Follow Room set to "None" | — | No listener. In line and behind a receiver, Director's commands alone; the mode falls back to the input's or Video. On a second output the box runs on its own settings (its auto-sync), and Status says so | click | — |
| W3 | Followed room renamed | `OnItemNameChanged` if registered [house: verified for devices, with `iditem` and `itemtype`; assumed for rooms]; the room list on demand | Stored by id, so nothing changes; the label is refreshed | auto | — |
| W4 | Followed room deleted (an explicit choice) | Its id is gone from `GetDevicesByC4iName("roomdevice.c4i")`; the listener goes silent or registering fails [assumed: P12]; `OnItemRemoved` if registered | Stops following and leaves the box as it is; Status and Attention "Follows a deleted room (room 38): pick another in Follow Room". A single room with the old name is offered | offered | Falling back to the device's room or any other room by itself |
| W5 | The box device's own room deleted (default) | Composer moves or deletes the device with it [assumed] | Whatever room the device ends up in is followed; Last Action says so | auto | — |
| W6 | Box device moved to another room | No callback: `OnItemMoved` exists but has never been seen on the house [house: docs/scene-rooms-research.md E11]; `RoomGetId()` re-read on every poll | Default: follows the new room, said once. An explicit room stays; if it differs from the device's room, a note on Status | auto | Rewriting an explicit Follow Room |
| W7 | Follow Room set to a room other than the device's (rack placement, shared receiver) | The choice | Followed as chosen | click | — |
| W8 | Linked rooms (selections or Room Off linked) | The followed room's own 1000 to 1010 [assumed: linked changes show there, P8] | Nothing special | none | Following the linked room too |
| W9 | Two rooms share one receiver (main zone and zone 2, or one receiver feeding two TVs) | Only the followed room | The other room's selections are ignored | click (the dealer picks the room) | Guessing the room from the receiver's state |
| W10 | Two or more boxes follow one room | Each box its own listener | Each acts on its own. With the same entertainment area they would take each other's stream over (O12) in turn: a box takes over only from an app outside this project, and the bridge refuses `STOP_AREA` for an area another bound box reported syncing [assumed: needs a sync state in the box's messages, C5, stage 4]. Attention names both boxes | auto | Taking a stream over from another box of this project |
| W11 | Source picked on a Navigator | 1000, 1002 or 1001, the paths | Acts after a short settle (§7.4) | auto | — |
| W12 | Source picked by programming (room commands) | The same variables [assumed: P8 step f] | As W11 | auto | — |
| W13 | Source changed outside Control4 (the receiver's remote, front panel or app; CEC) | Nothing: Control4 ignores unsolicited changes [verified: PP 116/_1] | The box keeps the room's mode; its own input and signal readings show the change | none | Changing the room or the receiver to "correct" it |
| W14 | Programming that switches the receiver's input directly, not through the room | Nothing in the room [assumed] | As W13; the manual says to select sources through the room | none | — |
| W15 | Driver start, Director restart, controller reboot | The first callback after registering, with the current values [verified: API 36/_10] | A **baseline**: no command to the box and no event (contracts C1.9, edge case C14). Only later changes act | auto | Waking, syncing or power-saving the box at start |
| W16 | Registration fails, or the variables do not exist (another OS numbering) | `pcall` error, or no first callback | Status "Cannot follow Bedroom: its variables do not answer"; retries at `OnPIP` and hourly; ids looked up by name again | auto | — |
| W17 | The followed room watches a source that does not reach the box | Second output, choice B: 1008 lacks the receiver. Choice A: nothing | When The Source Leaves The Box. In A, a source set to "Do not sync" does the same; otherwise the box reports no picture (edge case I16) | auto | — |
| W18 | Listen in the followed room | 1001 and 1007; 1008 empty [assumed: P8] | Music, if the box sees sound on its input (H1); otherwise "No sound on the second output" once | auto | — |
| W19 | Quick source changes (zapping through sources) | Several changes within a second | Coalesced in the box's queue; the last one wins after the settle | auto | — |
| W20 | Behind a receiver or in line, but the box is not on the followed room's path while Director routes through it (box placed in a rack room) | `SET_INPUT` arrives; the followed room's 1008 lacks the box; another room's 1008 has it | Offers that room: "Living Room's picture runs through this box (Follow Room)" | offered | Switching Follow Room by itself |
| W21 | A source device deleted or replaced in Composer | Its id is gone | Its per-source mode is kept and shown as "(device gone)"; the new device starts at Automatic; a same-name device is offered the old mode | offered | Applying a mode to another device by name match by itself |
| W22 | The wiring changes on the box (`soloMode` or `arcBypassMode` set in the Hue Sync app, or by the Sync Box Settings offer) | The next poll | Switches between Director-driven and room-driven; on a change to the second output, the box catches up once with the room's current state, said in Last Action | auto | — |
| W23 | The box is offline when the room changes | Commands cannot be delivered | At contact, the room's current state is applied once if it differs (edge case I15's rule) | auto | Replaying the missed sequence |
| W24 | Project restored from a backup | The stored room id may be gone or name another room [assumed: room ids survive a restore] | The stored name is checked against the id; a mismatch is W4 | auto; offered | Following a room whose name no longer matches without a click |

## 6. Probes (question 6)

P1 to P7 stay as R3 §6 wrote them. Every probe below logs through the dev
loop or the driver's own debug log, and nothing is waited on for more than a
minute (the owner's rule). Composer cannot capture start-up lines, only live
ones [house: docs/composer-remote.md, rule 13], so start-up observations go
through the dev loop's log. Probe code lives in a dev-loop bundle only,
never in a release build (the owner's rule on one-off tooling).

| Probe | Connect | Do | Log | Settles |
|---|---|---|---|---|
| **P8: the room's variables** (no Composer change; run first) | Nothing. A dev-loop bundle on any installed driver (the box device once it exists) that at late init dumps `GetDeviceVariables(<bedroom>)` and registers listeners on 1000, 1001, 1002, 1007, 1008, 1009, 1010, 1026 and 1027 of the bedroom | (a) Watch a source on the box; (b) Watch another; (c) Watch a source that bypasses the box, or the TV's own input; (d) Listen to Control4's own music, and to a box source under Listen if the room offers it; (e) Room Off; (f) the same selection from programming (a room command run from Composer, or the dev loop sending it [assumed: the room accepts `SELECT_VIDEO_DEVICE`]); (g) Update Driver on the probing device, to see the first callbacks | Every `OnWatchedVariableChanged` with milliseconds; for every device id seen, `GetDevices{DeviceIds}` and `GetDeviceDisplayName`; the variable names and ids from the dump. Optionally `RegisterDeviceEvent(<bedroom>, 1 … 40)` and every `OnDeviceEvent` | Q1 and Q2: names to ids, value formats, proxy or protocol ids, how Listen shows, the order and spacing of changes, the first callback, programming equals Navigator |
| **P9: in line, commands and room together** (extends P1 to P4 and P6) | The stage 2 box device in the bedroom, connected as cabled today: sources → box HDMI n (video and audio), box HDMI Out → receiver (video and audio). P8's listeners on | P1's list: pick a source, switch source, pick a TV app, Room Off | Every proxy command with all parameters verbatim (`PREV_DEV_LIST` included) and P8's variables, merged by time | Whether 1008 lists the box's proxy id; `PREV_DEV_LIST`'s format on 3.4.3; which comes first, the command or the variable |
| **P10: behind a receiver** | A scratch room of generic drivers (a receiver, a TV, two video sources, one audio source) and an **unpaired second Hue Sync Box device**: sources → receiver inputs; receiver HDMI out → box HDMI 1 (video and audio); box HDMI Out → TV. Room connections at Composer's defaults (TV video endpoint, receiver audio) | Watch A, Watch B, Listen C, Watch a source connected straight to the TV, Room Off | Every proxy command with all parameters and times; P8's listeners on the scratch room | §3.1's table: whether `SET_INPUT` 1000 comes again for B; whether `PREV_DEV_LIST` names the source or only the receiver; `ON`, `OFF`, `DISCONNECT_OUTPUT`; whether an audio `SET_INPUT` comes |
| **P11: second output** | The same scratch room. The receiver's second HDMI output (if its driver has one) → the unpaired box's HDMI 1; box HDMI Out not connected | P10's list | Proxy commands (expected: only `BINDING_CHANGE_ACTION` and `GET_AUDIO_INPUTS`); the room's endpoint lists in Composer, read by the Windows session | §4.1 choices A and B: no commands, no endpoint candidate, 1008 contains the receiver |
| **P11b: the false path** (optional) | As P11, plus the box's HDMI Out → a spare TV input | P10's list | Which path Director picks; whether the TV is switched to the spare input | Choice C's danger, for the manual |
| **P12: room lifecycle** | P8's bundle following the scratch room explicitly | Rename the scratch room; move the box device to another room and back; register a listener on a room id that does not exist (in `pcall`); delete a second scratch room the bundle follows | `OnSystemEvent` payloads for rooms (`OnItemNameChanged`, `OnItemRemoved`, `OnItemMoved`); what the listener does after the delete; `RoomGetId()` after the move | W3 to W6, W16 |
| **P13: Director restart** (parked) | P8's bundle | Nothing: wait for the next controller reboot the owner does anyway (Composer has no Director restart command [house: docs/composer-remote.md, rule 10]) | The first callbacks and their times relative to `OnDriverLateInit`, through the dev loop's log | W15: how long the room takes to settle after a restart |
| **H1: the house on the second output** (#531; the owner's hands) | The real box on the receiver's second HDMI output, solo mode on; Composer as choice B if the receiver's driver allows | Watch a source, Listen to an audio-only source, Room Off | The box's `hdmi.input1.status`, `audioSyncSupported`, `videoSyncSupported` and `contentSpecs`, and whether music sync runs | Whether the second output carries sound for Listen and a picture for Watch |

**Order.** P8 now (it changes nothing in the project). P9 comes with the
first stage 3 install. P10 to P12 in one Windows-session round on a scratch
room, which is deleted afterwards (standing approval; the brief says so).
H1 whenever the owner re-cables the bedroom. A behind-a-receiver run on real
hardware is not needed: P10 and the fake box cover it.

**The scratch room's generic drivers** must exist in Composer's driver
database [assumed]; if they do not, P10 and P11 run in the bedroom with the
real receiver, and the picture may be wrong while they run.

## 7. Recommendation for the contract (question 7)

### 7.1 The frozen frame (stage 2)

Freeze C1.1 to C1.3 exactly as written; the stage 2 `driver.xml` on the
branch already matches them, with no room binding [house:
`src/hue_syncbox/driver.xml`]. Write the two deliberate omissions into C1.2
so nobody adds them later: no room binding (the box must never be an
endpoint candidate) and no Power Manager binding.

### 7.2 Properties and the action (stage 3 or 4)

| Name | Type | Values / default | Shown |
|---|---|---|---|
| **Follow Room** | DYNAMIC_LIST | `This device's room (Bedroom)`, `None (the box decides)`, then every room by name / `This device's room` | Always. Stored as a room id plus the name it had (PersistData), never as a name alone |
| **Source Sync Modes** | STRING, read-only | `Apple TV: Video; PS5: Game (guessed from its driver); Turntable: Music` | Behind a receiver and second output |
| **HDMI 1 … 4 Sync Mode** | LIST | as C1.4 | In line only |

Properties that do not apply to the wiring are hidden with
`C4:SetPropertyAttribs(name, 1)` [verified: API 24_properties/_4-SetPropertyAttribs.md],
so the dealer sees one set of knobs.

**Action Set Source Sync Mode**: Source (CUSTOM_SELECT: the sources found
upstream of the box by walking bindings, §3.2, plus every source seen in the
followed room), Mode (LIST: Automatic, Video, Game, Music, Do not sync).
CUSTOM_SELECT lists serve actions as the bridge's Set Room Mapping does
[house: `src/hue_bridge/driver.xml`; verified: FUND
12.3_custom_select_implementation/_1-Overview.md]. A per-source property
cannot be declared, because the sources are only known at run time.

**What Follow Room does in each wiring:**

| Wiring | Sync start, stop, power save | The mode |
|---|---|---|
| In line | Director's commands (C4) | The input: HDMI n Sync Mode, else audio-only route → Music, else the box's input type, else Video. Follow Room only serves edge case I15's check and W20's offer |
| Behind a receiver | Director's commands | The followed room's source: Source Sync Modes, else Listen → Music, else the driver hint, else Video. `PREV_DEV_LIST` may stand in on 3.4.2 and later when P10 shows it names the source |
| Second output | The followed room (§4.2) | As behind a receiver |

### 7.3 What stage 2 should already do

1. **Log every proxy command** (`ReceivedFromProxy` on every binding) at
   debug with its name, all parameters verbatim (each value capped, as peer
   text) and the time in milliseconds. Stage 2 already logs them; adding the
   full parameter list makes the stage 2 beta the logger for P9 to P11 with
   no dev build.
2. **The manual's wiring section** (agent E):
   - in line: sources to HDMI 1 to 4, HDMI Out to the receiver or the TV;
   - behind a receiver: the receiver's HDMI output to HDMI 1 (video and
     audio, as the cable carries both), HDMI Out to the TV;
   - second output: the receiver's second HDMI output to HDMI 1 if its
     driver offers it, and **never connect HDMI Out**;
   - and that the sync behaviour per wiring comes in a later beta.
3. Nothing else. The `wiring` field and the Wiring row of stage 2 §3.5 are
   what stage 3 needs. Stage 2 registers no variable listener.

### 7.4 Modules (stage 3)

| Module | Interface (sketch) |
|---|---|
| `syncbox/room.lua` | `room.new{ register, unregister_all, get_variable, get_variables, room_id, timer, now, log }`; `r:follow(room_id)`, `r:stop()`; `r:on_variable(device, variable, value)`, wired from the global `OnWatchedVariableChanged`; the state `{ power, selected, video, audio, video_path, audio_path, kind = "watch" \| "listen" \| "off" }`; `on_baseline(state)` once, then `on_change(state, prev)` after a 1 s settle. Ids by name from `GetDeviceVariables`, else the numbers of §1.2. Every value from another driver goes through `num.lua` and is capped: it is input like a peer's text |
| `syncbox/sources.lua` | `sources.new{ get_devices, display_name, bound_provider, store }`; `s:describe(id)` → `{ id, name, proxy_kind, driver_file }`; `s:upstream(box_proxy_id)` → the sources behind the box's inputs; `s:mode_for(selection, wiring, input)` with the precedence of §7.2; the per-source store keyed by device id |
| `syncbox/follow.lua` | Room state → intents for `queue.lua` on the second output (wake, sync with a mode, the At Room Off and When The Source Leaves The Box settings); nothing on the baseline; W10's guard before any take-over |
| `syncbox/av.lua` (C3) | Gains the wiring: behind a receiver, the mode from `sources:mode_for(room.selected, …)`; edge case I15 checks `room.video_path` |
| `tests/helpers/fake_c4.lua` | `RegisterVariableListener` (the immediate first callback; an error for a variable that does not exist), `UnregisterAllVariableListeners`, `GetDeviceVariables`, and `fake.room_variable(room, id, value)` that calls `OnWatchedVariableChanged`. Rooms already exist in the fake project |

### 7.5 Open questions for the owner

Each with the recommended answer first.

1. **Follow Room's default.** **"This device's room"**, so the second-output
   wiring works once the box device sits in the TV's room; or "None", so
   nothing follows a room until the dealer picks one.
2. **Listen behind a receiver.** Director takes the box off the picture's
   path for a Listen source. **Let the followed room start music sync
   anyway when the box sees sound on HDMI 1**; or treat it as When The
   Source Leaves The Box, as Director's command says.
3. **Game from a driver's file name.** **Apply it as part of Automatic and
   show it as a guess** on Source Sync Modes; or only offer it.

## Sources

- Snap One DriverWorks SDK under `~/c4-tools/reference/` (paths in the
  markers above), read only.
- Snap One helper library, `~/c4-tools/drivers-common-public/global/lib.lua`
  (`ROOM_VARS`) and `global/msp.lua` (`RegisterRooms` and the `OWVC` parsers),
  read only, never vendored.
- Snap One template code: https://github.com/snap-one/drivers-template-code-public,
  commit `50eee83`, `proxies/avswitch_proxy/avswitch_device_class.lua` and
  `avswitch_proxy_commands.lua`.
- Control4 Composer Pro help, "Room connection types":
  https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/room_connection_types.htm
  (read 2026-11-16).
- This repository: [`hdmi-sync-design.md`](hdmi-sync-design.md),
  [`hdmi-sync-contracts.md`](hdmi-sync-contracts.md),
  [`hdmi-sync-stage2-design.md`](hdmi-sync-stage2-design.md),
  [`syncbox-control4-research.md`](syncbox-control4-research.md),
  [`syncbox-api-research.md`](syncbox-api-research.md),
  [`edge-cases-syncbox.md`](edge-cases-syncbox.md),
  [`edge-cases-control4.md`](edge-cases-control4.md),
  [`scene-rooms-research.md`](scene-rooms-research.md),
  [`composer-remote.md`](composer-remote.md),
  [`design.md`](design.md) ("Project APIs"),
  `src/hue_syncbox/driver.xml` (stage 2, on the branch),
  [`src/hue_bridge/driver.xml`](../src/hue_bridge/driver.xml),
  [`tests/helpers/fake_c4.lua`](../tests/helpers/fake_c4.lua).
