# Simplifying the drivers: the users' journeys (#334)

Research file of the `journeys` agent for [the simplification contract](simplify-actions-design.md)
(§0.5). Read-only research, 2026-11-04, against `main` = beta 7 (build 425). The question: walk the
dealer, the home owner and the outside tester through the life of the system, count today's clicks,
and design the ideal flow for each journey. Addresses and ids are the contract's placeholders.

Sources: **MAN** = the bridge's manual `src/hue_bridge/www/documentation.html`, cited by line;
**E1…E28** = the evidence list of §2; the other research files by name: **IMPORT**
`docs/simplify-research-import.md`, **MAINT** `docs/simplify-research-maintenance.md`, **COMPOSER**
`docs/simplify-research-composer.md`, **SCHED** `docs/simplify-research-scheduler.md`.

## 1. Findings

1. **A release build shows 29 bridge actions and 27 properties**, not 32 and 29: three actions and
   two properties exist only in development builds (E1). The difficulty is less the count than its
   shape: four verbs (Add, Import, Re-link, Forget) times five nouns (light, zone light, scene,
   sensor, area), and Attention and Last Action texts that name about fifteen different actions
   (E5); Composer clips Attention's before the action's name (E2).
2. **Clicks per job hardly change; what there is to learn does.** Most clicks of a first setup are
   real choices: which Hue room is which Control4 room, which scenes, which zones. The reference
   home of §3 costs about 155 clicks today and about 145 with the merged actions IMPORT and MAINT
   propose; only a picker that takes several items at once would bring it near 90, and that is
   unverified on Composer 3.4.2 (COMPOSER §2 A). The Apple gain is 29 buttons → 9, one place that
   says what needs you, and defaults that are right.
3. **Frequency should decide which job keeps a one-click button.** The journeys that recur after
   setup, a new bulb or sensor and a rename, cost one click today because their actions have no
   dialog. Folded into dialogs (Add From Hue, Resolve Names) they cost 6 and 5. Keep one no-dialog
   **Import All New** (lights and sensors into their mapped rooms) and make the Composer half of
   renames automatic (IMPORT §5.3).
4. **Three journeys are expensive because their bulk case has no bulk action.** A factory-reset or
   replaced bridge costs 8 clicks per device to re-link (about 370 for the 46 devices of the reference home); bulk
   re-link by radio and unique name (IMPORT §5.2) brings it to about 10. A bulb removed from Hue
   costs 10 clicks along the manual's path where 3 do the same (E10).
5. **Two traps on today's paths.** Import All New Lights imports a likely replacement as a new
   device, while Import All New Motion Sensors skips it (E8): the dealer who follows Attention's
   "(Add Light or Import All New Lights)" after a bulb swap gets a duplicate. And the manual still
   tells a new installer to readdress a bridge whose address has no number below 8, which stopped
   mattering when the event stream moved to a network connection (#317, E9).
6. **The owner in the Control4 app never hears of Hue changes.** A new bulb, a dead one or a
   rename shows only in Composer's Attention, and AddDevice must stay a click (E3). The ideal flow
   informs instead: a driver event the dealer can turn into a push notification (E15), and a
   Status line in plain words for the owner's occasional Composer visit.
7. **The journeys need five background tasks, all cheap:** a pairing window that waits for the
   link button; Map Rooms By Name for rooms that appear later; the Room Audit as a marker; Link
   Devices at start and at a bind; rediscovery of a moved bridge by its id (the one that is new
   work: mDNS unverified, the cloud endpoint a policy change; MAINT finding 6). They match IMPORT §5.6
   and MAINT §2.4, and stop with one setting (SCHED).
8. **Properties: 22 rows on screen in normal use today, 14 in the ideal** (plus Last Action's
   continuation rows while used). Events Received and Last
   Event repeat Event Stream (E12); Stream Address and Stream Timeout (s) mean something only under
   Web transfer; Bridge ID, Model and Name fold into one row; Debug Mode moves to the bottom; the
   four lists stand together. The six Last Action rows answer a real complaint (#68), but long texts
   fill them: Adopt Hue Names with nothing to do takes four rows (E13).
9. **Already Apple-like: the update in place and the keypad session.** No driver click beyond the
   install; the keypad defaults (On State Follows, LED colours, hold rate) are right (E28).

## 2. Evidence

| # | Claim | Source | Mark |
| --- | --- | --- | --- |
| E1 | Connection Test, Reload Credentials, Check CA Pinning, Dev Server and Diagnostic Server are dev-only, stripped from release builds | `src/hue_bridge/driver.xml:188-202`, `:523-552`; MAN:164 | verified |
| E2 | Composer shows a property value on one line of about 75 characters and clips the rest | #121 (builds 180, 185 on the house); `src/hue_bridge/driver.lua:249-251` | verified |
| E3 | AddDevice is to run only from a dealer's or user's action | `~/c4-tools/reference/docs-driverworks-api/source/includes/9_helper/_0.1-AddDevice.md` | verified |
| E4 | No API moves a device to another room | `docs/import-design.md:28-33`; COMPOSER finding 5 | verified (doc sweep) |
| E5 | Attention is a plain STRING row; each item ends with the actions that resolve it; about fifteen action names appear in these hints | `driver.xml:91-95`, `driver.lua:589-613`, `bridge/lights.lua:1669`, `bridge/owner.lua`, `bridge/motion.lua:178` | verified (code); the clipping on screen follows from E2, not seen in a report |
| E6 | A pick plus Set on a list row reaches the driver; the row snaps back | `driver.lua:1488-1503`; #122 (build 185) | verified |
| E7 | An action dialog: "…", entry, inner OK per row, then the outer OK; it remembers the last values | `docs/design.md:1110-1116`, `:1187-1191`; #185 | verified |
| E8 | Import All New Lights does not skip a likely replacement; the motion import does | `bridge/lights.lua:1256-1275`; MAN:958-959 | verified |
| E9 | The manual asks for an address with a number below 8 (MAN:124, :170); the network-connection stream uses the dotted address | `docs/raw-stream-design.md:8`; `bridge/netstream.lua:58-59` | verified |
| E10 | A Composer delete alone tombstones a device; MAN 8.3 sends the reader through Forget Light first | MAN:417 vs MAN:429; MAN 8.4 | verified |
| E11 | The bridge rows refresh every 5 min and on a Composer rename; MAN 8.2 says a Hue rename shows only at the next click or resync | `driver.lua:2293`, `:2197-2205`; MAN:390 | verified |
| E12 | Event Stream already carries the container count and the last event's time | MAN:233, :242; #65 | verified |
| E13 | Last Action: the owner could not read it (#68); 6 rows of 72 characters, unused rows hidden; Link Devices, Adopt and Accept join four parts | `driver.lua:1394-1398`, `:1551-1563`; `bridge/owner.lua:1266`; `docs/status.md:112-116` | verified |
| E14 | `SetPropertyAttribs` hides a row; Composer drops it when sent with the texts, so the driver sends it 400 ms later | SDK `24_properties/_4-SetPropertyAttribs.md`; `driver.lua:1438-1442` | verified |
| E15 | A driver can fire its own events for programming | SDK `7_event/_3-FireEvent.md` (OS 2.8.0) | verified (doc); a push through the Notification agent assumed |
| E16 | Pair Bridge makes one attempt; a press after the click needs a second click | `bridge/pairing.lua:1-18`, `:160-170`; MAN:183-187 | verified; Hue's error 101 assumed (pairing.lua:18) |
| E17 | Map Rooms By Name runs once by itself, at the first read | `bridge/lights.lua:57`, `:922-946`; MAN:193 | verified |
| E18 | A gone device's hint: the same radio (MAC) first, then the same name | `bridge/lights.lua:464-482`; `bridge/motion.lua:2249-2280` | verified (code); that a reset bulb keeps its MAC: assumed |
| E19 | The tester's round: timeouts, a 4-action workaround, asks for Refresh buttons and one wording; the owner asked him to copy rows by hand | #309, fixed by #317, #324, #325 | verified |
| E20 | The house: 47 lights, 23 Hue rooms and zones (13 unmapped at first), 126 + 15 scenes, 2 imported | `docs/status.md`; #122 | verified |
| E21 | `C4:NetConnect` takes UDP and MULTICAST | SDK `32_serial_network_device/_23-NetConnect.md:17`; COMPOSER §2 D | verified (doc); mDNS answers assumed |
| E22 | A click during an import or resync is refused ("Busy: …; try again in a moment") | MAN:320 | verified |
| E23 | The first import put 47 devices in a placeholder room; rooms-first came from it | #161 | verified |
| E24 | A property type change installs without a reboot | `docs/status.md` ("Verified in Composer (build 185)") | verified |
| E25 | Whether the bridge's store survives a Composer project restore is unverified | MAN:462 | verified (as unverified) |
| E26 | A device that remembers its Hue id is adopted the moment it is bound | MAN:438; MAN 8.9 | verified |
| E27 | Setup reading today: chapters 3–7, 9.1–9.3 and 14.2–14.5 hold about 14,500 words | word count of MAN as text | verified (count) |
| E28 | On State Follows defaults to Room/zone lights; keypad defaults right | `CHANGELOG.md` Unreleased; `docs/scene-led-design.md` | verified |

## 3. The journeys

**Counting.** A no-dialog action is 1 click; a dialog is 1 + 3 per row + the outer OK (two rows 8,
one row 5; E7); a folder picker adds 1 per folder level. Selecting the bridge is 1 and each tab
switch 1; a property edit is the value cell and Set, 2 plus typing; reading a list row 1; File ▸
Refresh Navigators 2; a Composer delete 3 (select, Delete, Yes); a drag 1. Walking to the bridge
and the Hue app do not count. Today's numbers follow the manual; ideal numbers follow §4.

**Reference home.** One bridge; 10 Hue rooms, 7 named like a Control4 room; 2 zones; 30 lights, 2 in
no Hue room; 70 scenes, of which the installer wants 10; 2 zone or room lights; 3 motion sensors and
1 MotionAware area. The house is bigger (E20).

| Journey | Steps today | Clicks today | Friction seen | Ideal flow | Clicks ideal |
| --- | --- | --- | --- | --- | --- |
| 1. First setup and pairing | Driver ▸ Add or Update Driver or Agent… (4 files); Items ▸ Search "Hue Bridge" (pick Philips Hue, not Control4's own); look up the address in the Hue app (readdress if no number below 8); Bridge IP Address + Set; open Actions, walk to the bridge, press the link button, Pair Bridge within ~30 s; read Status | 17 + 2 typings; +1 per mistimed press | press-then-click order and timing (MAN:183-187, E16); obsolete readdress step (E9); the Set button rule (MAN:176); search also finds Control4's Hue drivers (MAN:132) | install; add the bridge; Status "Found Hue Bridge Pro at 10.0.2.143: press its link button" (discovery) or type the address; press the button at any time in the next 2 minutes; Status "Paired with Hue Bridge Pro" | 11 (14 typing the address) |
| 2. First import: lights, rooms, scenes, sensors | read Room Mappings; Set Room Mapping ×3; Import All New Lights; read Last Action; Add Light ×2 (no Hue room); Add Zone Light ×2; Add Scene ×10; Import All New Motion Sensors; Add Motion Area; Room Audit; Refresh Navigators | ≈155 | first import into one room (#161, E23); dialogs remember the last choice (#185); "Busy" refusals (E22); 8 clicks per scene | rooms with the same name map themselves (exists, E17, now also later); map the other 3; Import All New; Add From Hue for the 2 roomless lights, 2 zones, 10 scenes and the area; the audit marker shows nothing to drag; Refresh Navigators | ≈145 (≈90 with multi-pick) |
| 3. A new bulb added in the Hue app | owner sees nothing in the app; in Composer: Attention "1 new light on the bridge: … (Add Light or Import All New Lights)"; Import All New Lights (Add Light if no Hue room); read Last Action; Refresh Navigators | 6 (13 with Add Light) | owner never told; Attention clipped before the hint (E2, E5) | the bridge fires "Hue devices waiting" (dealer may push it to the owner); Attention "1 new light: Lamp 9 (Kitchen); Import All New"; Import All New; Refresh Navigators | 6 |
| 4. A bulb renamed or moved to another room in Hue | rename: Attention (≤5 min, E11), then Adopt Hue Names, Accept Names As They Are or the device's Adopt Hue Name; move: nothing in Attention; Room Audit, read Last Action, drag | 3 rename; 5 move | a move stays invisible unless one thinks of Room Audit (MAN:305); "nothing to do" fills four Last Action rows (E13) | Composer renames accepted by themselves; a Hue rename: Resolve Names (or nothing with `Names From Hue` = Follow, IMPORT §5.3); a move shows as "(in Den)" on the Lights row; drag it | 0–7 rename; 3 move |
| 5. A bulb replaced (dead bulb, new one) | old device "Gone from the Hue bridge…"; new light "(looks like …; re-link?)"; Re-link Device To Light (Device, Light); then Adopt Hue Name or Accept | 11–13 | Import All New Lights would duplicate it (E8); two Attention items for one event | same radio: re-linked by itself once the MAC assumption is proved (Q2), Last Action "Re-linked … by its radio"; otherwise Link Device with the suggestion pre-chosen; Import All New skips it | 0 (radio) or 10 |
| 6. A bulb removed from Hue | device "Gone…; re-link or Forget"; Attention; MAN 8.3: Forget Light, then delete the device | 10 (3 by MAN 8.5) | two paths, the documented one costs three times as much (E10) | Attention "Lamp 5 is gone from Hue (device 1213): delete it, or Link Device"; delete in Composer | 3 |
| 7. A scene added, renamed or deleted in Hue | added: only "N new" on Scenes; Add Scene; Refresh Navigators. Renamed: as 4. Deleted: "Scene deleted in Hue…"; Re-link Scene or delete | 12 / 3 / 10 or 3 | no word about a scene a person made (Hue's seven default scenes a room would flood Attention, MAN:490) | added: Add From Hue (Scenes ▸ room ▸ scene); renamed as 4; deleted as 5 and 6 with a same-room name suggestion | 11 / 0–7 / 3 or 10 |
| 8. A new motion sensor or MotionAware area | Attention "1 new motion sensor … (Add Motion Sensor)"; Import All New Motion Sensors or Add Motion Sensor; Add Motion Area; Refresh Navigators. The tester's beta-5 round: Disconnect Event Stream, Map Rooms By Name, Add All New Motion Sensors, Connect Event Stream | 6 / 12 (area) | timeouts forced the 4-action workaround (#317); "Add" vs "Import" naming (#325); the motion import does not re-read the bridge (MAN:958) | Import All New takes sensors with the lights (areas stay one at a time, IMPORT §5.1); Add From Hue ▸ Motion for an area | 6 / 11 |
| 9. The bridge changes IP address | Event Stream cycles "Disconnected…"; Status "Bridge at … not reachable"; look the address up in the Hue app; Bridge IP Address + Set; reserve it in the router | 4 + typing | the driver never searches (MAN:123); Status may stay Paired meanwhile (MAINT finding 5) | the driver finds its bridge id at the new address, checks identity and TLS, writes Bridge IP Address; Status "Bridge moved to 198.51.100.20; reconnected" | 0 (4 without discovery) |
| 10. Key revoked or bridge factory-reset | Status "Key rejected by the bridge (HTTP 403): re-pair with Pair Bridge"; walk, press, Pair Bridge. After a reset every light, scene, zone and sensor re-made in Hue has a new id: Re-link × every device | 3; reset: 3 + 8 per device (≈370) | no bulk re-link (E18); re-made scenes match only by name | Pair Bridge with the 2-minute window; Link Device ▸ "(every device with a suggested match: 38)"; the leftovers one by one | 3; reset ≈11 + leftovers |
| 11. The bridge replaced by another | Status "Bridge at … reports ID …, expected …"; Forget Pairing; new address if any; press, Pair Bridge; Re-link × every device whose id changed | 4–8 + 8 per device | as 10; a Hue-app transfer may keep the ids, untested (MAN:457) | the same deliberate gate (#236), or Pair Bridge accepting the bridge Hue names as the replacement (MAINT §3); then the bulk row of 10 | 4–8 + ≈8 |
| 12. Project restored from a backup, or driver updated in place | update: Driver ▸ Add or Update… with the 4 files, nothing else (a capability change needs a System Manager reboot). Restore: read Status; Pair Bridge if "Not paired"; read Lights; Link Devices; Map Rooms By Name; Set Room Mapping for the rest | 7 / 5 + mappings | whether the bridge's store survives a restore is unverified (E25) | update unchanged; restore: devices adopted as they announce themselves (exists, E26), Link Devices at start, rooms mapped by name again on an empty store (E17); Status "46 of 46 devices linked" | 7 / 1 |
| 13. A keypad session (scenes on buttons) | Add Scene if needed; switch: Use as 2 Button Keypad, Buttons Control Load off, LED Behavior; a program holding the switch's load at 100 %; Connections: select the Hue Scene, drag Top and Bottom | ≈24 (10 the driver's) | driver rows need Set, proxy rows take Enter (MAN:176); otherwise Control4's own | Add From Hue for the scene; the rest is Control4's; the driver's defaults are already right (E28) | ≈23 (9 the driver's) |
| 14. Support: something is wrong | read Status, Event Stream, Attention, Last Action; Test Connection; Debug Mode On; Lua tab; the tester copied Stream Address, the address and four more rows by hand (E19); Log Motion Diagnostics needs the Lua tab open within 20 s | ≈8 + rows copied by hand | facts spread over eight rows; the Lua tab shows only lines that arrive while it is open (MAN:1089) | Status says what is wrong in plain words; Diagnostics ▸ "Check the connection now" writes every connection fact (model, firmware, transport, stream, counts, last errors; redacted) to the Lua output; copy | ≈8, nothing copied by hand |

Frequency (assumed: no telemetry; from the house's and the tester's history): once, journeys 1–2;
every few weeks, 3, 4, 7, 8; a few times a year, 5, 6, 9, 12, 14; rarely, 10, 11. Journeys 3 and 4
are where a lost one-click button costs most, journeys 10 and 11 where a bulk row saves most.

**What the owner in the Control4 app sees today**: a dead or unpowered bulb greys out (MAN 8.1); a
deleted Hue light's device greys out; a new bulb never appears. Nothing says "your installer has
something to do". The ideal adds one driver event, fired when Attention gains an item, that a dealer
may tie to a push notification (E15).

## 4. What each ideal flow uses

The ideal bridge has nine actions: **Pair Bridge**, **Import All New**, **Add From Hue**, **Link
Device**, **Resolve Names**, **Set Room Mapping**, **Forget Device**, **Diagnostics**, **Forget
Pairing** (IMPORT §7 and MAINT §4, plus Import All New kept as its own button, Q1). Hue Light and Hue
Scene keep no action (IMPORT); Hue Motion keeps **Test Motion Programming** (MAINT).

| Journey | Actions used | Background task (what it shows) | One-click choice | Gone from the journey |
| --- | --- | --- | --- | --- |
| 1 | Pair Bridge as the retry only | discovery fills Bridge IP Address; the pairing window ("Press the link button on the bridge (1:45 left)") | — | the timing rule, the readdress step |
| 2 | Set Room Mapping, Import All New, Add From Hue | map rooms by name for new rooms ("Office → Office (by name)"); the audit marker | bulk rows "All 7 scenes of Kitchen" | Room Audit, Map Rooms By Name, five Add actions |
| 3 | Import All New | the Attention item; the "Hue devices waiting" event | Import All New | the choice between two actions |
| 4 | Resolve Names (Ask) | Composer renames accepted; Follow renames untouched names | Resolve Names ▸ "Rename all" | Room Audit, Accept Names As They Are |
| 5 | Link Device | suggestions on reconcile; the same-radio re-link once proved ("Re-linked … by its radio") | "(the suggested match)" | Re-link Device To Light |
| 6 | Composer's delete | — | — | Forget Light before the delete |
| 7 | Add From Hue, Link Device | the scene catalogue (exists) | a room's bulk row | Refresh Scenes |
| 8 | Import All New, Add From Hue | — | Import All New | Add All New Motion Sensors' workaround |
| 9 | none | rediscovery by bridge id (Status "Bridge moved to …; reconnected") | — | the Hue-app lookup |
| 10 | Pair Bridge, Link Device | key re-check (MAINT); suggestions | "(every device with a suggested match)" | 8 clicks per device |
| 11 | Forget Pairing (or none), Pair Bridge, Link Device | identity check (exists) | the bulk row | 8 clicks per device |
| 12 | none | adoption on hello (exists); link at start and bind; map by name on an empty store (Status "46 of 46 devices linked") | — | Link Devices, Map Rooms By Name |
| 13 | Add From Hue | — | — | Add Scene |
| 14 | Diagnostics | Status in plain words | "Check the connection now" | Test Connection, Connect and Disconnect Event Stream, Log Motion Diagnostics as buttons |

The Apple test, per point:

- **Nothing to learn.** Nine buttons named for what the installer wants, not for the kind of Hue
  thing; every Attention item names one of them. Still to learn: Composer's Set button (MAN:176),
  folders in a picker, and Refresh Navigators after adding.
- **The default is right.** "(mapped room)" first in every Room list; rooms of the same name map
  themselves; Import All New skips what may be a replacement; On State Follows and the keypad
  defaults (E28).
- **A mistake is reversible.** A wrong add is a Composer delete (remembered, so a bulk import does
  not bring it back); a wrong link is Link Device again; a wrong name is a rename. Forget Pairing and
  Forget Device stay deliberate; nothing deletes or moves a device (E3, E4).
- **Status in plain words.** Status says one sentence about the whole bridge ("Paired with Hue
  Bridge Pro; live updates since 14:03", "Not working: the bridge has not answered since 14:02;
  trying again"); Attention lists only what needs a person; background tasks report in Status or
  Attention, not Last Action (SCHED).

## 5. The properties

### 5.1 Why six Last Action rows

- **The need is real.** The owner, 2026-10-24: Last Action could not be read in full (#68). Composer
  clips at about 75 characters (#121); a drop-down was tried and was as narrow as the row. PRs #69,
  #70 and #130 wrapped the text at 72 characters onto `Last Action (2)` to `(6)`, shown only while
  used and re-asserted 400 ms and 1.5 s later because Composer drops attribute changes sent with
  text (`docs/status.md:112-116`, `driver.lua:1394-1474`).
- **Six is the length of the longest common results.** An import that lists what it added and
  skipped, and the four-part answers of Link Devices, Adopt Hue Names and Accept Names As They Are
  ("… | Scenes: … | Zone lights: … | Motion: …"). Adopt Hue Names with nothing to rename runs to
  246 characters, four rows, to say "nothing to do" (MAN 8.2, E13). Longer texts end in
  "… (Lua output)".
- **Cost when unused: none on screen** (rows hidden, E14). The fix is the texts, not the rows: a
  first line under 72 characters that states the outcome ("Added 4 lights; skipped 3, see Lights"),
  the "nothing to do" parts left out, the per-item detail in the list rows and the Lua output. Then
  rows (2) to (6) appear rarely. Recommendation: KEEP the six rows, shorten the texts.

### 5.2 Each row

Release order today (`driver.xml:20-232`); on screen in normal use 22 (27 less the five hidden
continuation rows).

| Row | Who needs it | Proposal |
| --- | --- | --- |
| Driver Version | installer (after an update), support | keep, first (Control4 convention) |
| Debug Mode | support | keep, last |
| Status | everyone | keep; one sentence on pairing and stream together |
| Bridge IP Address | installer | keep; discovery may fill it (MAINT) |
| Bridge ID, Bridge Model, Bridge Name | support | fold into one row **Bridge**: "Hue Bridge Pro (BSB003) 001788fffe123abc" |
| Bridge Firmware | support, with the update note | keep |
| Event Stream | support | keep, after the lists |
| Lights, Zone Lights, Scenes, Motion Sensors | installer | keep, together, plus the audit marker (IMPORT §5.4) |
| Attention | installer, owner | keep; word-wrap it as Last Action is, so the action names are read (E2) |
| Last Action, (2)–(6) | installer | keep; shorter texts (5.1) |
| Room Mappings | installer at setup | keep, after the lists |
| Stream Address | support, Web transfer only | hide unless Web transfer or Debug Mode (MAINT §3) |
| Events Received, Last Event | nobody: Event Stream says it (E12) | hide, or retire |
| Stream Timeout (s) | Web transfer only | hide unless Web transfer or non-default |
| Event Stream Transport, Stream Watchdog (s) | support | hide unless non-default or Debug Mode (MAINT §3) |

On screen in normal use after: Driver Version, Status, Bridge IP Address, Attention, Last Action,
Lights, Zone Lights, Scenes, Motion Sensors, Room Mappings, Bridge, Bridge Firmware, Event Stream,
Debug Mode: 14, plus continuation rows while used.

### 5.3 The order a newcomer expects

What is it and is it well (Driver Version, Status), the one thing to type (Bridge IP Address), what
needs me and what just happened (Attention, Last Action), what is there (Lights, Zone Lights, Scenes,
Motion Sensors), how rooms line up (Room Mappings), then the technical rows (Bridge, Bridge
Firmware, Event Stream, the hidden stream rows) and Debug Mode last. Today Debug Mode is second,
and Attention, six Last Action rows and Room Mappings split Lights from the other three lists. Whether Composer re-orders the
rows of an existing device after an update in place is assumed, not seen; renaming or removing a
property on update is COMPOSER finding 9 and the compat research's question.

## 6. Setup in five minutes

Today the same ground takes chapters 3–7, 9.1–9.3 and 14.2–14.5 of the manual, about 14,500 words
(E27). In the ideal design the whole instruction sheet is this:

1. Copy the four `.c4z` files to the Composer computer. Driver ▸ Add or Update Driver or Agent…,
   select all four, Open.
2. Select the room for the bridge. Items ▸ Search "Hue Bridge" (manufacturer Philips Hue) and
   double-click it.
3. Select the bridge. Status reads "Found Hue Bridge Pro at 10.0.2.143: press its link button". (If
   it reads "Enter the bridge's address", type the address from the Hue app into Bridge IP Address
   and click Set.)
4. Press the round button on the bridge. Status reads "Paired with Hue Bridge Pro".
5. Open Room Mappings. Hue rooms named like your Control4 rooms are mapped. Map any other you want
   with Set Room Mapping.
6. Click Import All New. Every light and motion sensor goes into its room; Last Action says what was
   added and what was left out.
7. For zones, rooms as one light, scenes and MotionAware areas, use Add From Hue: open the folder,
   pick, OK.
8. File ▸ Refresh Navigators.

From then on Attention says when something in Hue needs a decision, and everything else follows by
itself. Never delete the bridge to fix it; update it in place.

About 200 words against 14,500. Steps 3 and 4 depend on discovery and the pairing window (MAINT),
step 6 on Q1, step 7 on folder pickers working on Composer 3.4.2 (IMPORT finding 7).

## 7. Verdicts (journey evidence)

The family verdicts belong to IMPORT and MAINT; this column says what the journeys support. "Agree"
means the same verdict there.

| Action | Verdict | Journey reason |
| --- | --- | --- |
| Pair Bridge | **KEEP** | J1, J10: a person at the bridge; with a 2-minute window, the press and the click come in any order (agree, MAINT) |
| Test Connection | **MOVE to diagnostics** | J14: one entry of Diagnostics; its unlock of a key-rejected stop becomes automatic (MAINT says AUTOMATIC; both apply) |
| Connect Event Stream, Disconnect Event Stream | **MOVE to diagnostics** | J8: their only field use was the #317 workaround, gone since beta 6 (E19) (agree) |
| Connection Test, Reload Credentials, Check CA Pinning | **MOVE to diagnostics** | no journey: already absent from release builds (E1) (agree) |
| Forget Pairing | **KEEP** | J11: the deliberate gate against another bridge (#236) (agree) |
| Add Light, Add Zone Light, Add Scene, Add All Scenes Of Room, Add Motion Sensor, Add Motion Area | **MERGE into Add From Hue** | J2, J7, J8, J13: one action for "a Hue thing into a room", the kind picked in the list (agree) |
| Import All New Lights, Import All New Motion Sensors | **MERGE into Import All New** | J3, J8: the most frequent job stays one click, no dialog; skips likely replacements for lights too (E8). IMPORT and MAINT put it in Add From Hue as a bulk row: Q1 |
| Re-link Device To Light, Re-link Zone Light, Re-link Scene, Re-link Motion Device | **MERGE into Link Device** | J5, J10, J11: one list of gone devices with their suggested match and a bulk row (agree) |
| Link Devices | **AUTOMATIC** | J12: adoption by remembered id already happens on hello (E26); run the name match at start and at a bind, and list what stays unmatched in Attention. IMPORT says MERGE into Link Device: both work, the journey prefers no click |
| Forget Light, Forget Scene, Forget Motion Device | **MERGE into Forget Device** | J6: the common case is a Composer delete; Forget is the rare "release, keep the device" (agree) |
| Adopt Hue Names, Accept Names As They Are | **MERGE into Resolve Names** | J4: the Composer half becomes automatic, the Hue half one dialog (agree) |
| Set Room Mapping | **KEEP** | J2: a real choice (agree) |
| Map Rooms By Name | **AUTOMATIC** | J2, J12: for every room that appears, never over a hand choice (agree) |
| Room Audit | **AUTOMATIC** | J4: the move becomes visible without knowing the action (agree: a marker on the rows) |
| Refresh Scenes | **RETIRE** | J7: events keep scenes live; the tester asked for one refresh for every list, Refresh All (#309) (agree) |
| Refresh All | **AUTOMATIC** | J8, J14: needed only while the stream was down (#324); background reads cover it, Diagnostics keeps the button (agree) |
| Log Motion Diagnostics | **MOVE to diagnostics** | J14: the tester still needs it in release builds (agree) |
| Hue Light, Hue Scene: Adopt Hue Name | **MERGE into Resolve Names** | J4 (agree) |
| Hue Light, Hue Scene: Forget This Light, Forget This Scene | **MERGE into Forget Device** | J6: the per-device act is Composer's delete (agree) |
| Hue Motion: Refresh From Bridge | **RETIRE** | no journey uses it; the manual calls it normally not needed (agree) |
| Hue Motion: Test: Motion, Test: No Motion | **MERGE into Test Motion Programming** | J13: a dealer tests motion programming without walking; one toggle does both (agree) |

## 8. Risks and open questions for the owner

Each with a recommended answer, so the decision costs one word.

- **Q1. May a merged dialog cost more clicks than today's button for a frequent job?** Folding
  Import All New Lights into Add From Hue turns 1 click into 6 for every new bulb (J3).
  *Recommended: no.* Keep **Import All New** (lights and sensors) as its own button: nine actions
  instead of eight.
- **Q2. Re-link by itself when a new light has the radio (MAC) of a gone device?** It is the same
  bulb re-added, and the device keeps its programming. IMPORT forbids it until the MAC assumption is
  proved (E18). *Recommended: yes, after a hardware check* (re-add a bulb on the house); name-only
  matches stay a click.
- **Q3. Fix the two traps now, ahead of #334?** Import All New Lights skipping likely replacements
  (E8), and the manual's address advice and Stream Address text (E9; MAN:124, :170, :241). Both are
  small. *Recommended: yes*, in beta 8.
- **Q4. A driver event "Hue devices waiting" for owner notifications?** Programming is the dealer's
  choice; the event costs nothing until used. *Recommended: yes*, fired when Attention gains an item.
- **Q5. Word-wrap Attention like Last Action?** Today the action that resolves an item is the part
  Composer cuts (E2, E5). *Recommended: yes*, rows shown only while used.
- **Q6. Should the catalogue lists or Attention act on a pick plus Set?** It works (E6; COMPOSER
  finding 3), but those five lists would then behave differently from every other list in Composer,
  which is something to learn; IMPORT §5.7 advises against. *Recommended: no.*
- **Q7. Hide Stream Address, Stream Timeout (s), Events Received and Last Event in normal use; fold
  the bridge identity rows into one?** *Recommended: yes* (MAINT §3 agrees on the first four).
- **Q8. Ever create a device without a click** (a setting "Import new lights automatically")? The
  SDK reserves AddDevice for the user's action (E3), and a swapped bulb with a new name would arrive
  as a duplicate. *Recommended: no.*
- **Risk: multi-pick and folders are unverified on Composer 3.4.2** (COMPOSER §2 A); without them
  J2 stays at about 155 clicks and Add From Hue falls back to three Add actions (IMPORT finding 7).
  A dev-loop spike settles both before the design is built.
- **Risk: discovery** (J9, setup step 3) is new work with no verified receive path for mDNS; the
  cloud endpoint needs internet in release builds, a policy change (MAINT finding 6). The flows work
  without it, with the address typed.
- **Out of scope, seen in #309:** the tester moved lights over from another Hue driver one by one,
  redoing their programming. *Recommended:* note it for a later release; nothing here depends on it.
