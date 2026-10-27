# Composer checklist

What only Composer, a Navigator, a keypad or the Hue app can show, as steps
for the owner. Every step describes what build 316 does (its texts checked
against the code on 2026-10-25, issue #231); where build 316 differs from
the build a step was first written for, a dated note says so. A **Done**
line under a step says when it was checked on the house and what it
showed, in the words of that day; **Open** means it has not been checked
yet. What runs on the house and what is open overall is `docs/status.md`;
the engineering record behind each result is `docs/design.md`.

## Before you start

- **Release builds.** Release builds (no dev loop, no Lua command window)
  ran on the house from build 116 (2026-10-22) to build 259 (2026-10-24).
  Since build 259 (2026-10-24, 23:11) a release reaches the house from
  GitHub (`docs/release-checklist.md`, "Deploy to the house"): `tools/deploy.py
  start` writes the brief, and the Windows Claude session downloads the
  three files of the release from their GitHub URLs (checksums checked)
  and installs them (step 1). A development build goes on the house only
  when the developer asks for a test (dev build 309 since 2026-10-25 03:24,
  for issue #40), and a release replaces it afterwards (issue #228).
- **Capability changes need a reboot.** If an install makes Composer ask
  "Restart Director?", answer Yes, but it does not restart Director: the
  devices keep their old capabilities until you reboot the controller from
  System Manager (Tools > System Manager; it runs elevated, so only you can
  operate it). Then choose File » Refresh Navigators. Builds that change only
  Lua or connections take effect at once. Composer has no "Restart Director"
  command of its own.
- **Logs.** A device's Lua output is in its **Lua** tab in Composer. When a
  step asks for it, set that device's `Debug Mode` to On first and back to
  Off afterwards. A release build ships nothing to the VM; a development
  build ships the bridge's log to the dev server (`docs/dev-loop.md`).
- A quoted property or result text is the exact text to expect; `<…>`
  stands for a value that varies. Where a step does not quote, paste what
  you see.

The house on 2026-10-24: build 160 on all three drivers, paired with the Hue
Bridge Pro; one Hue Scene device, "Shine" (device 1162, Master Bedroom, Hue
scene Shine of the Master Bedroom room); **no Hue Light devices** (all 47
deleted in Composer on 2026-10-22 and remembered as deleted); the "Bedside
Lights Switch" bound to Shine's Top and Bottom Button Links; the "Floor Lamp
Switch" bound to nothing. Steps that need a light start with Add Light
(step 21).

The house on 2026-10-25 (`docs/status.md`): dev build 309 on all five Hue
devices since 03:24; besides Shine, a second Hue Scene device, "Golden
hours" (device 1164, the Master Bedroom's time-of-day scene, created
2026-10-24), and two zone lights made with Add Zone Light on 2026-10-24,
"Bedside Lights" (device 1166, the Hue zone of the two bedside lamps) and
"Master Bedroom Lights" (device 1168, the whole room); still no Hue Light
device for a single lamp, and the switches bound as above.

## A. Install and update

1. Driver » "Add or Update Driver or Agent…", select `hue_bridge.c4z`,
   `hue_light.c4z` and `hue_scene.c4z` of the same build, Open. Expect
   "Update Succeeded: Drivers or agents were successfully updated:
   hue_bridge.c4z, hue_light.c4z, hue_scene.c4z", and within a minute every
   Hue device showing the new `Driver Version`. All three files belong in the
   project even with no device of a type: the bridge creates lights and
   scenes from them (Add Light, Add Scene). Never add a Hue Light or Hue Scene
   device by hand. A right-click "Update Driver" is only for reloading the
   same version ("Versions are equal. Do you want to overwrite…?").
   - **Done** for every build since 84 (2026-10-21), the last being 160
     (2026-10-24), through the Windows session; since then builds 184 to
     259 on 2026-10-24 (259 the first from a GitHub release through
     `tools/deploy.py`, round 34) and dev builds 276, 284 and 309 on
     2026-10-25 (`docs/composer-remote.md`, History).
2. The update is **in place**. Never delete and re-add the bridge: a re-added
   bridge has a new device id and an empty store, so the pairing and every
   device link are lost. Expect on the bridge within a minute: `Status`
   "Paired"; `Event Stream` "Connected since <HH:MM:SS>" (with ", <n>
   containers, last <HH:MM:SS>" once events arrive, and the reconnect count
   after a reconnect); `Attention` "None"; `Lights` "47 on bridge, 0
   imported, 0 new, 0 missing, 0 unbound, 47 deleted" (the house today);
   `Scenes` "<n> + <m> time-based on bridge, <k> imported, <d> deleted"
   ("<g> missing" and "<u> unbound" appear only when not zero; 126 + 15 on
   the bridge and 2 imported on 2026-10-25); `Zone Lights` "7 zones, 16
   rooms on bridge; 2 imported". Corrected 2026-10-25: this step was written
   when `Scenes` read "<n> on bridge, 1 imported, 0 missing, 0 unbound, <d>
   deleted" and a release build still showed the `Dev Server` and
   `Diagnostic Server` rows; the release builds of 1.0 and later have
   neither row.
   - **Done 2026-10-22** (production build 116 over dev build 84): the
     pairing, the registry and `Debug Mode` kept, the stream back 8 s after
     the install.
   - **If Composer asked "Restart Director?"**: reboot the controller as
     described under "Before you start", wait until Composer has Director
     again (7.5 min on 2026-10-22, under 3 min on 2026-10-24), choose File »
     Refresh Navigators, then check this step again. **Done 2026-10-24** for
     build 160 (Director lost at 23:55:14, back at 23:57:33; Shine became a
     dimmer only after the reboot).

## B. Importing lights (done; how lights come back)

3. The first import. **Done 2026-10-21** (dev build): "Import Lights"
   created 47 devices one at a time, bound and registered; `Lights` ended
   "47 lights on bridge, 47 imported, 47 new". Since the import-ui build
   (2026-10-21) the actions are **Import All New Lights** (every new light
   into its mapped room) and **Add Light** (one light, step 21). Today every
   light is remembered as deleted, so Import All New Lights creates nothing
   and answers "Added no lights; skipped 47 deleted in Composer (Add Light
   re-creates one): <name> #<n> (deleted 2026-10-22), …"; bring a light back
   with Add Light.
4. After adding a light, open it in Composer:
   - Properties: `Status` "<Hue name> (<model>)", for example "Left Bedside
     Light (Hue color lamp)"; `Hue Light ID` "#<n> (<first 8 hex digits>…)";
     `Hue Name`, `Model` and `Hue Room` filled; `Online` "Online" while the
     bulb has power; `Driver Version` the build. No rows for click or hold
     rates, the On preset or button LED colours (step 35). Superseded
     (2026-10-25, #59): those settings of the light_v2 proxy now show above
     the driver's rows (step 35).
   - Connections: its "Hue Bridge" input already connected, `Connected To`
     "Hue Bridge->Hue Lights"; under Control Outputs the Top, Bottom and
     Toggle Button Links.
   - **Done 2026-10-21** (Left Bedside Light: "Left Bedside Light (Hue color
     lamp)", "#46 (e0e51794…)", "Master Bedroom", "Online"); the Button Links
     since build 146 (2026-10-22).
5. Import All New Lights a second time: no new device, and "No new lights on
   the bridge (<n> on bridge, <n> imported)" when nothing is deleted, or
   step 3's text. A new device is a bug. **Done 2026-10-21/22** (dev loop:
   "No new lights on the bridge (47 on bridge, 47 imported)").

The lights were left in the bridge's room after the first import; on
2026-10-22 the owner deleted them all instead of dragging them to their
rooms (step 20). Moving a device never touches its binding.

## C. Two-way state (needs a light: step 21 first)

6. Open the light's room in a Navigator. In the Hue app, turn the light off
   and on and change its brightness: the tile follows each change within
   1–2 s (the bridge reports once a second) and the bridge's `Events
   Received` rises. **Open** for a light on a Navigator; the bridge's fan-out
   of Hue events to the devices is verified (2026-10-21, dev loop).
7. A Hue dimmer switch or a Hue automation acting on the light: the same.
   **Open.**
8. Cut the bulb's power at the lamp: its `Online` turns "Offline" and the
   tile is disabled, possibly only after minutes (Hue is slow to notice);
   with power back it returns to "Online". Note the times. **Open** (an
   unpowered bulb read "Offline" on 2026-10-22; no timings taken).

## D. Control from Control4 (needs a light)

9. On the light's tile: tap on and off, then drag the slider to 25 %, 60 %,
   100 % and 0 %. The bulb responds within about a second and the slider
   settles on the level Hue reports, in whole percents (Hue answers 20 as
   20.16, the tile shows 20 %); 0 % is off, and a level from off turns the
   bulb on at that level. **Done 2026-10-21** (Desk Lamp: 25, 60, 100 and
   off all stuck).
10. A colour bulb offers a colour wheel and a colour temperature control, a
    white-ambiance bulb only the temperature, a white-only bulb neither. Pick
    a colour, then a temperature: the bulb follows each. Paste the
    temperature range offered (the bulb's own, roughly 2000–6500 K). (Until
    2026-10-25 the step also asked for the line "first SET_COLOR_TARGET
    params: …" from the light's Lua tab; build 316 no longer writes it.)
    **Done 2026-10-25 from the record:**
    the driver's own lines of 2026-10-22 show both kinds of pick from the
    phone on colour bulbs, a colour as `LIGHT_COLOR_TARGET_MODE=0` with X and
    Y, a temperature as mode 1 (e.g. X 0.317 Y 0.327, sent to Hue as mirek
    159); every bulb in this house has colour and temperature, so the
    white-ambiance and white-only cases cannot be shown here. The probe line
    is removed (`docs/design.md`, hardware pass of 2026-10-25).
11. Colour while off: turn a colour bulb off, pick a colour if the Navigator
    allows it (the bulb stays off), then turn it on: it comes on in that
    colour. **Done 2026-10-25** on a zone light (Bedside Lights): a
    temperature set while off sent nothing, and the turn-on carried it in the
    same PUT.
12. Slider spam: say when you start, drag one light's slider back and forth
    for five seconds, say when you stop. The bulb follows with a short lag
    and ends at the slider's final position; the bridge's `Event Stream`
    stays "Connected since …". With the bridge's `Debug Mode` On, paste its
    Lua output for those seconds: at most about ten "PUT light" lines a
    second and no 429. **Done 2026-10-25** on a zone light: 50 slider
    targets in five seconds became 9 grouped_light PUTs (the group queue: a
    burst of 3, then one a second; the latest value won), no 429, the stream
    stayed connected. A single light's queue (ten a second) was not run: the
    house has no Hue Light device; its pacing is pinned by `commands_spec`.

## E. The dev loop (on the house only for a test)

The house runs release builds, so nothing here applies unless the developer
installs a development build for a test (dev builds 276, 284 and 309 on
2026-10-25; `docs/status.md` says what runs now). With one, the developer
pushes Lua to the bridge and its devices from the VM (`docs/dev-loop.md`),
reads the bridge's log there, and runs the development commands (`Hue
Request`, `Probe Call`, `Lights Report` and the other probes; since #217,
2026-10-25, through signed dev-loop commands only) and the three DEV-ONLY
actions Composer shows on a dev build (`Connection Test`, `Reload
Credentials`, `Check CA Pinning`); a light's or scene's reload line appears
only in its own Lua tab.

- Stream address rotation: after each reconnect `Event Stream` shows
  "Connected since" within seconds, and `Stream Address` shows a different
  spelling of the bridge address than before, "<spelling> (own queue,
  spelling <i> of <k>)" ("(own queue, the only spelling)" when the address
  has no octet below 8 to pad, "<address> (shared queue with commands:
  <reason>)" when the stream cannot have its own). The release build
  rotates the same way at every reconnect. **Done 2026-10-21** (dev loop,
  PR #6): two reloads took the second and third spelling and connected 200
  and 160 ms after the attempt; the row then read "<spelling> (own queue,
  rotating over <k> spellings; commands use <bridge address>)", reworded
  for Composer's column since.

## F. Controller restart and a long run

13. (spike step 12) Restart. Composer has no "Restart Director" command, so
    the test is a controller reboot from System Manager (yours). Expect,
    without touching anything: the bridge's `Status` "Paired", `Event
    Stream` "Connected since …", `Lights` and `Scenes` unchanged; every device
    bound (a device that cannot see its binding at start looks again 5, 15,
    30 and 60 s later, so allow a minute before taking "Not bound to a Hue
    Bridge" as a fault); tiles showing the real state (Shine ON at its room's
    percentage if it was on before); colour controls still on colour bulbs.
    Toggle something in the Hue app to confirm the stream.
    - **Done 2026-10-22 19:12–19:23** (build 150): Composer lost Director at
      19:12:58 and had it back, idle, at 19:20:35; the event stream was back
      at 19:19:28 (the pairing survived); the Right Bedside Light read "Right
      Bedside Light (Hue color lamp)", Online, version 150 at all 19 reads
      from 19:21:03 to 19:22:33, never "Not bound". **Again 2026-10-24**
      (build 160), Shine working afterwards. Not checked: tiles and colour
      controls of lights after a reboot.
14. (spike step 13) Long run: after at least an hour with the defaults, paste
    `Event Stream`, `Events Received` and `Lights`, and say whether a tile
    still follows the Hue app. **Open** as a recorded check (the house has
    run release builds since 2026-10-22).

## G. Rooms and lifecycle (the import-ui build, 2026-10-21)

All of this is in build 316 too. Verified through the dev loop on
2026-10-21: six resource GETs per resync, the one-time room auto-map (9 Hue
rooms matched Control4 rooms by name), Room Audit and Map Rooms By Name.
Steps 17, 20, 22 and 24 need a Hue Light device; step 21 adds one.

16. Bridge Properties: `Attention` ("None" when nothing needs you), `Last
    Action` (the result of your last click, continued on `Last Action (2)`
    to `(6)` when long), `Room Mappings` and `Lights` ("47 on bridge, 0
    imported, 0 new, 0 missing, 0 unbound, 47 deleted" today). Since
    2026-10-24 `Room Mappings`, `Lights`, `Scenes` and `Zone Lights` are
    drop-downs (`docs/status.md`, "Composer properties fit the column"):
    the row shows the summary and the list every item, and a pick snaps
    back to the summary. `Room Mappings` reads "<n> Hue rooms and zones;
    <u> unmapped (open the list to read)", and its list holds one "<Hue
    room> → <Control4 room>" line each ("Dining → Dining", "Basement
    Hallway → (unmapped)", a zone ending "(zone)"). When this step was
    checked, `Room Mappings` was one line ("Dining → Dining; Foyer → Foyer;
    …"). The arrows must render as arrows. **Done 2026-10-21**
    (`Attention` "None"; `Room Mappings` with 9 mapped rooms, 7 unmapped
    rooms and 7 unmapped zones; `Lights` "47 on bridge, 47 imported, 0 new, 0
    missing, 0 unbound, 0 deleted"; arrows intact).
17. A light's Properties: `Hue Room` (its Hue room's name), `Hue Light ID`
    "#<n> (<8 hex digits>…)", `Last Action`; its Actions tab: Adopt Hue Name
    above Forget This Light. **Done 2026-10-21** (Left Bedside Light: "Master
    Bedroom", "#46 (e0e51794…)").
18. The bridge's Actions tab, top to bottom, on a release build (22
    actions): Pair Bridge, Add Light, Import All New Lights, Add Zone Light,
    Re-link Device To Light, Re-link Zone Light, Link Devices, Forget Light,
    Adopt Hue Names, Accept Names As They Are, Set Room Mapping, Map Rooms By
    Name, Room Audit, Add Scene, Add All Scenes Of Room, Re-link Scene,
    Forget Scene, Refresh Scenes, Test Connection, Connect Event Stream,
    Disconnect Event Stream, Forget Pairing; a development build has
    Connection Test, Reload Credentials and Check CA Pinning before Forget
    Pairing (25). Click **Add Light**: a dialog with two pickers.
    `Light` lists the lights without a device, those deleted in Composer
    last as "<name> [<Hue room>] #<n> (deleted from Composer <date>)" (today
    all 47), or "(every light on the bridge is imported)" when there is
    none; `Room` lists "(mapped room)" then your rooms as "<Floor> / <Room>".
    Cancel. **Done 2026-10-21** (the dialog and lists render, the 23 actions
    of that development build in order, before Add Zone Light and Re-link
    Zone Light existed); **2026-10-22** the `Light` list held all 47 as
    deleted.
19. **Set Room Mapping**: pick a Hue room without a Control4 twin and the
    Control4 room it should default to, OK: `Last Action` "Mapped <Hue room>
    → <room>" and `Room Mappings` updated. **Done 2026-10-21/22** ("Mapped
    Mini Bar (zone) → Kitchen", then "Removed the mapping for Mini Bar
    (zone)"; the dialog listed the 23 Hue rooms and zones).
20. **Room Audit**: `Last Action` reads "<k> of <m> are not in the room their
    Hue room maps to: <light> is in <room>; Hue says <Hue room> → drag it to
    <room> in Composer if you want it there; …". Drag a few, run it again:
    they leave the list. Nothing is moved for you. **Done 2026-10-21** ("26
    of 26 are not in the room their Hue room maps to"; a click from Composer
    reached the driver). The drags were never done: the owner deleted the
    lights instead (2026-10-22).
21. **Delete and re-add** (the tombstone flow), which is also how any light
    comes back. Delete a light device in Composer: within seconds `Lights`
    ends "…, <d> deleted" with `<d>` one higher ("…, 1 deleted" when
    nothing else is) and `Attention` says nothing (a Composer delete is
    deliberate). Then **Add Light**: pick the light (listed with "(deleted
    from Composer <date>)") and pick "(mapped room)" or a room explicitly
    (the dialog remembers your last values), OK: `Last Action` "Added <name>
    #<n> to <room> (device <id>)", the device in that room with its Hue name,
    its tile working. Import All New Lights skips a deleted light by name
    (step 3's text). **Done 2026-10-21 17:22–17:23** (Vanity 3: "47 on
    bridge, 46 imported, 0 new, 0 missing, 0 unbound, 1 deleted", re-added
    within 400 ms, an empty `Room` accepted as the mapping) and **2026-10-22**
    (all 47 deleted, `Attention` stayed "None"; the Right Bedside Light
    re-added under build 125, since deleted again).
22. **Rename** a light in Composer (say "Downlight 4" → "Downlight Four"):
    within a minute `Attention` reads "1 Hue name differs from the Composer
    names: Downlight Four is Downlight 4 in Hue (Adopt Hue Names or Accept
    Names As They Are)". **Adopt Hue Names** renames it back: `Last Action`
    "Renamed 1 device: Downlight Four → Downlight 4 (device <id>) | Scenes:
    No Composer names differ from the Hue scene names | Zone lights: No
    Composer names differ from the Hue zone and room names" (the zone
    lights' part since build 196). Rename it again and click **Accept Names
    As They Are**: `Attention` drops the item. **Done in part 2026-10-21** (a
    rename raised the `Attention` item within seconds); Adopt and Accept on
    a real difference are **open**.
23. **The bare "Hue Light" device** (one added by hand). **Done 2026-10-22**
    (device 1034, bound from a development build with `C4:Bind` because
    Composer's drag cannot be automated): `Status` "Bound; waiting for the
    bridge", `Attention` and `Lights` unchanged; **Link Devices** "not linked
    1: Hue Light (device 1034): no unimported Hue light has that name; rename
    the device in Composer to the Hue light's exact name and run Link Devices
    again"; after **Forget Light** on Vanity 3 and renaming 1034 to "Vanity
    3", **Link Devices** "Linked 1 device: Vanity 3 (device 1034) to Vanity 3
    [Master Bathroom] #92 by name | Scenes: All 2 bound scene devices are
    registered". To repeat it on the release build, bind the device by
    dragging the bridge's "Hue Lights" output onto its "Hue Bridge" input in
    Connections.
24. **Re-link** is for a bulb replaced or deleted on the Hue side: its device
    reads "Gone from the Hue bridge since <date time>; re-link or Forget" and
    Re-link Device To Light's `Device` list offers it as "<name> (device
    <id>, gone since <MM-DD>)"; pick the replacement in `Light`: "Re-linked
    device <id> (was <old>) to <new> [<Hue room>] #<n>", the device keeping
    its name, room and programming. A device you ran Forget Light on is not
    offered; it comes back by binding it again and Link Devices. **Open**
    (no spare bulb).

## H. Scenes (the scenes build, 2026-10-21; a dimmer since build 160)

`hue_scene.c4z` must be in the project (step 1) before Add Scene can create a
device. Verified through the dev loop on 2026-10-21: the scene catalogue GET
at every resync, recall and status events, the bridge's scene actions.

25. Bridge Properties: `Scenes` "<n> + <t> time-based on bridge, <m>
    imported, <d> deleted" once the stream has done its first full read
    ("<m> imported" alone before; "<t>" is "?" until the time-based scenes
    are read; "<g> missing" and "<u> unbound" appear only when not zero).
    Written when it read "<n> on bridge, <m> imported, 0 missing, 0
    unbound, <d> deleted"; reworded 2026-10-24 (time-based scenes, build
    180, and Composer's column). The Actions tab has Add Scene, Add All
    Scenes Of Room, Re-link Scene, Forget Scene and Refresh Scenes between
    Room Audit and Test Connection. **Done 2026-10-21** (the scene actions
    run from Composer).
26. **Add Scene**: the `Scene` list holds every scene without a device as
    "<Room>: <Scene>", zones as "<Zone> (zone): <Scene>", dynamic ones ending
    " (dynamic)", grouped by room, those deleted in Composer last; since
    build 180 a room's or zone's time-based scenes come first in its group
    as "<Room>: <name> (time-based)", and an ordinary scene a schedule uses
    ends " (in <schedule>)". `Room` offers "(mapped room)" first. A zone
    scene with "(mapped room)" while the zone is unmapped: "Not added:
    Nightlight: Hue room Bedside Lights (zone) not mapped; pick a room, or
    Set Room Mapping first". With a room picked:
    "Added <scene> to <room> (device <id>)" and a dimmer tile (a switch
    before build 160), named like the scene for a room scene ("Shine") or
    with the zone's name in front for a zone scene ("Bedside Lights
    Nightlight"). **Done 2026-10-21** (Bedside Lights Nightlight, device
    1132, Master Bedroom); today's device is Shine (1162).
27. Tap the tile ON: the scene's lights take the scene within a second and
    the tile shows ON with the room's percentage. Tap OFF: the whole room or
    zone goes off with one request and the tile shows OFF (0 %). Change one
    of the scene's lights by hand (Hue app or its own tile): since build 160
    the scene tile **stays ON** and shows the room's new percentage (before,
    it dropped to OFF); the room turned off, or another scene of it played,
    turns the tile OFF (step 47). **Done 2026-10-21** for ON and OFF
    (Nightlight: the bridge confirmed the recall after 240 ms, the lights
    were off 360 ms after OFF).
28. The scene's Properties: `Status` "Hue scene <scene> in <room>" ("Hue
    scene Shine in Master Bedroom"; a zone ends "(zone)"), `Hue Scene`, `Hue
    Room`, `Hue Scene ID` "#<id> (<8 hex digits>…)", `Recall As` "As set in
    Hue", `Online` "Online", and no rate or LED colour rows (step 35;
    superseded 2026-10-25, #59: the proxy's hold rates and LED colours now
    show). A time-based scene has no `Recall As` row and reads "Hue
    time-based scene <name> in <room>; now <slot> (from <HH:MM>)" or "…;
    not running".
    Change `Recall As` to "Static", click the row's **Set** button, tap ON:
    the scene is set once instead of played (with the bridge's `Debug Mode`
    On, its Lua tab shows the recall "as static"). Actions: Adopt Hue Name
    above Forget This Scene. **Done 2026-10-21 22:03–22:04** (after Set the
    recall went out as static) and **2026-10-22** ("Static" → "As set in
    Hue" through the Set button).
29. **Add All Scenes Of Room** with a mapped room that has scenes: "Added <k>
    scenes of <Hue room> to <room>: <scene> (device <id>), …", one tile
    each; run again: "No new scenes in <Hue room> (<k> on bridge, <k>
    imported)", or "No new scenes in <Hue room> (<n> scenes and <t>
    time-based on bridge, <k> imported)" where the room has time-based
    scenes (they are added too, after the ordinary ones). **Done
    2026-10-21** on Patio (Ibiza and Lily; the second run "No new scenes in
    Patio (2 on bridge, 2 imported)").
30. Delete a scene device in Composer: `Scenes` ends "…, <d> deleted" with
    `<d>` one higher ("…, 1 deleted" when nothing else is); Add
    Scene lists it last as "<Room>: <Scene> (deleted from Composer <date>)"
    and re-adding works; Add All Scenes Of Room skips it: "Added no scenes;
    skipped 1 deleted in Composer (Add Scene re-creates one): <scene>
    (deleted <date>)". **Done 2026-10-21** (Ibiza; the bulk-skip text not
    recorded).
31. **Forget Scene** on one device: "Forgot <scene> (device <id>): unbound
    and left in the project for you to delete; the Hue scene is listed under
    Add Scene again"; the device's `Status` "Forgotten by the bridge (was Hue
    scene <scene>). Delete this device in Composer, or bind it again and use
    Link Devices". Delete it in Composer. **Done 2026-10-21** (Ibiza, device
    1138).
32. A scene deleted in the Hue app (use a throw-away one): its device reads
    "Scene deleted in Hue since <date time>; ON does nothing; re-link or
    Forget", `Online` "Offline", and `Attention` "1 scene missing from the
    bridge: …"; **Re-link Scene** points the device at another scene
    ("Re-linked device <id> (was <old>) to <Room>: <Scene>") and the tile
    works again; Adopt Hue Name then renames it. **Done 2026-10-21** (a test
    scene made through the API; device 1140 re-linked to "Bedside Lights
    (zone): Read" and renamed "Bedside Lights Read").

## I. Keypads and the scene dimmer (builds 146–160)

The contracts are `docs/keypad-design.md` and `docs/scene-dimmer-design.md`;
the owner's manual (chapters 9.4 and 11) says the same in prose.

Setup (done for Shine on the Bedside Lights Switch):

33. The switch: in its Properties tick "Use as 2 Button Keypad" and leave
    "Buttons Control Load" unticked. Its own load then follows programming
    only, so keep it at 100 % (a "when the project loads" program, for
    example) so the Hue bulbs keep power. Set its "LED Behavior" to the
    option that follows the connected device: "Push/Release" only lights a
    button while it is pressed. **Done** for the Bedside Lights Switch
    (Buttons Control Load off; its LEDs follow Shine, 2026-10-24).
34. Connections: select the Hue Scene (or Hue Light) device. Its Control
    Outputs list "Top Button Link", "Bottom Button Link" and "Toggle Button
    Link". Drag the switch's Top button onto Top Button Link and its Bottom
    button onto Bottom Button Link; a one-button keypad goes to Toggle Button
    Link. As soon as a button is bound its LED shows the device's state: top
    lit blue while the device is on, bottom lit blue while it is off.
    **Done** by 2026-10-23 (Bedside Lights Switch → Shine).
35. The device's Properties show no rows for click or hold rates, the On
    preset or button LED colours: the drivers hide the proxy's own settings
    (`hide_proxy_properties`), so the defaults apply (a tap on a light ramps
    over 250 ms, a hold covers the full range in 5 s, the On preset is
    100 %, the LEDs are blue). Showing them would be a capability change
    (a reboot). **Open** as a recorded check (`docs/status.md` states it).
    Superseded (2026-10-25, #59): the drivers now declare
    `hide_proxy_properties` False. After the install and the owner's
    controller reboot, a Hue Light lists the On preset, click and hold rates
    and LED colours and a Hue Scene its hold rate and LED colours (the
    scene declares no click rates and no On preset); the defaults above
    stay until you change one. A change reaches the driver at once, and the
    driver answers with the value in use, so Composer keeps showing it; a
    value out of range (preset 1–100 %, rates 0–86400000 ms) is not taken.
    Change a hold rate once and see it on a keypad (#59's hardware check).
    **Done 2026-10-25 except on a keypad** (dev builds of the night, after
    the reboot; `docs/design.md`, "Hardware pass of 2026-10-25 night"): the
    proxy's settings page appeared above the driver's "Advanced Properties"
    on light (a zone light) and scene devices; a field commits on Enter and
    arrives as `SET_HOLD_RATE_DOWN RATE=2000`, and a hold down from 3 % then
    went out over 40 ms; Composer kept the value once the drivers answered
    with the bare value (rounds 41 and 42, `common/device.lua`). **Open**: a
    changed rate on a physical keypad.

A Hue Scene on the keypad (Shine):

36. Tap top: Shine plays within about a second; the tile shows ON with the
    room's percentage; the top LED lights and the bottom goes dark. Tap top
    again after a dim: Shine plays again at its own brightness. Tap bottom:
    the whole Master Bedroom room turns off, the tile shows OFF, the bottom
    LED lights. **Done 2026-10-23** (taps) and **2026-10-24** (LEDs, build
    160).
37. With Shine on, hold top (longer than about half a second): the room
    brightens while you hold, Shine's colours and the differences between
    its lights kept, and stops where you let go; 1 % to 100 % takes about
    5 s. Hold bottom: it dims and stops where you let go. The tile stays ON;
    its percentage moves at most once a second and settles on the level Hue
    reports about a second after you let go. Letting go never also plays or
    turns off the scene. **Done 2026-10-23** (build 154: hold-to-dim works).
38. With the room off, hold top: Shine starts at its dimmest (1 %), the LEDs
    show on at once, and it brightens until you let go. Hold bottom while
    off: nothing happens. **Done in part 2026-10-25** through Shine's Lua
    command window (dev build 284; `docs/design.md`, "Hardware pass of
    2026-10-25 night"): a top hold from off, released at 800 ms, recalled
    Shine at 1 % and sent no dim, and a bottom tap turned the room off.
    **Open**: a longer hold, the LEDs, a physical keypad.

A Hue Light on a keypad (needs a light; the Floor Lamp Switch is free):

39. Add Light (step 21) for the lamp, then bind the switch's buttons to the
    light's Top and Bottom Button Links as in step 34.
40. Tap top: the light goes to 100 % (the On preset) over 250 ms, from off
    or from any lower level, and the top LED lights. Tap bottom: off over
    250 ms, and the bottom LED lights. (100 % and 250 ms are the defaults;
    since #59 they are the light's own On preset and click rates, step 35.)
41. With the light on, hold top: it brightens until you let go (the full
    range in about 5 s) and stays at the level reached; the tile settles on
    the level Hue reports, or on the driver's estimate a second later. Hold
    bottom: it dims toward the minimum, never off, and stops where you let
    go. With the light off, hold top: it comes on at 1 % and brightens from
    about half a second later. Hold bottom while off: nothing.
42. Turn the light off and on in the Hue app: the tile and the keypad LEDs
    follow within 1–2 s.
    - **Done 2026-10-22** for taps through a light's Button Links
      (`docs/status.md`). **Open** for 40–42 as described: holds have used
      Hue's own relative dim, and the light has driven the keypad LEDs, only
      since 2026-10-23, and no Hue Light device has been in the project
      since.
    - **Done in part 2026-10-25** on a zone light (a Hue Light device of
      kind group) through its Lua command window (dev build 284;
      `docs/design.md`, "Hardware pass of 2026-10-25 night"): a top hold
      from off, released at 800 ms, turned it on at 1 % (one PUT) and sent
      no dim; a bottom hold with a click 100 ms after the release sent dim
      down and stop, and the click was ignored; a bottom tap turned it off
      over the proxy's click rate (0.75 s on that device).

The scene dimmer (Shine):

43. After installing a build that changes the scene's capabilities, as 160
    did, the tile shows only on and off until the controller is rebooted and
    Navigators are refreshed (step 2); afterwards it has a slider and a
    percentage. **Done 2026-10-24.**
44. With Shine on, the percentage is the Master Bedroom's brightness as Hue
    reports it: the average of the lights that are on, in whole percents
    (100 % until Hue has reported one). Compare it with the room's brightness
    in the Hue app. **Done 2026-10-24** (a slider with the room's percentage
    in the Control4 app on the owner's iPhone).
45. With Shine on, drag the slider to about 30 %: within about a second the
    room dims, Shine's colours and the differences between its lights kept,
    and the tile settles on the level Hue reports. Drag to 80 %: it
    brightens the same way. **Done 2026-10-24** ("behaves correctly").
46. Drag to 0 %: the room turns off with one request, the tile shows OFF and
    the bottom LED lights. From off, drag to 40 %: Shine plays with its
    lights at 40 % and the tile shows ON at 40 %. From off, a tap or 100 %
    plays Shine as designed. **Done 2026-10-24** for 0 % and back on (the
    LEDs follow between 0 % and on); playing at a level from off is **open**.
47. The Hue app and the on rule (Shine on first):
    - Dim the room in the Hue app: Shine's tile stays ON and its percentage
      follows within 1–2 s; the LEDs stay on.
    - Change one of the room's lights in the Hue app (colour or level): the
      tile stays ON. Hue no longer calls Shine active, but the device keeps
      it on until the room goes off.
    - Turn the room off in the Hue app or with a Hue dimmer switch: the tile
      shows OFF and the LEDs follow.
    - Play Shine from the Hue app: the tile shows ON at the room's
      percentage.
    - Play another Master Bedroom scene from the Hue app: Shine's tile shows
      OFF although the room stays lit.
    - **Open.**
48. The on state across a restart (only when a reboot suits you): with Shine
    on after a dim, reboot the controller; afterwards the tile is still ON at
    the room's percentage. **Open.**
49. Programming (optional): a "when Shine turns off" event fires when the
    room is turned off in the Hue app and when another of its scenes is
    played (step 47), and a "when Shine turns on" event when Shine is played
    from the Hue app. **Open.**

## J. Motion sensors and MotionAware areas (1.1 beta 1, #268)

Written on 2026-10-26, before the build, from the contract
(`docs/motion-design.md`) and the texts of `docs/edge-cases-motion.md`
(EC) §6; check every quoted text against the build that ships as
`v1.1-beta.1`. The owner's manual says the same in prose (chapter 14, and
the Hue Motion Sensor's own Documentation tab). The house has the Hue
Bridge Pro and no motion sensor or MotionAware area, so steps 50 to 60
are the smoke test without sensors: EC §10 items 1 to 4 and the probes H1
to H4 of `docs/motion-control4-research.md` (C4R) §8. H5 (a
`C4:RecordHistory` probe in a dev build) is not part of beta 1 (contract
D11). Steps 61 to 72 are the tester's first round: C4R T1 to T8, the
questions of `docs/motion-hue-research.md` (HR) §7.1 and EC §10 items 5
to 8. His results arrive as Beta feedback issues, or through the owner,
and are summed up on #268.

The house smoke test (no sensor; the Windows session, with the owner for
the drag in step 59 and the reboot in step 58):

50. **Install the prerelease** (C4R H1; contract §7). Use Driver » "Add or
    Update Driver or Agent…" and select the four files of `v1.1-beta.1`
    (`hue_bridge.c4z`, `hue_light.c4z`, `hue_motion.c4z`,
    `hue_scene.c4z`), then Open. Expect Composer's "Update Succeeded"
    message naming all four (paste it: the new driver may be listed as
    added, the other three as updated) and **no "Restart Director?"**. The
    motion driver declares no `<capabilities>`, and the other three change
    none. Within a minute every Hue device shows the new `Driver Version`.
    If Composer does ask, note which driver it names, then reboot as under
    "Before you start".
    - **Done:** open.
51. **Nothing regresses** (contract §7). On the bridge, expect `Status`
    "Paired", `Event Stream` "Connected since <HH:MM:SS>", and `Attention`,
    `Lights`, `Scenes` and `Zone Lights` as before the install (step 2).
    Shine plays and turns off from its tile, and the zone light Bedside
    Lights switches from its tile. Disconnect Event Stream, then Connect
    Event Stream: the feed is back within seconds. The full read then runs
    lights, scenes, zone lights and then motion (contract §4.4), and the
    rows are unchanged.
    - **Done:** open.
52. **The bridge's new row and actions.** Properties has a `Motion
    Sensors` row right after `Zone Lights`: one drop-down for sensors and
    areas together. Paste its summary and the lines of its list. The house
    has no sensor and no area, so expect the summary "0 sensors and 0
    areas on the bridge; 0 added" ("0 added" alone until the first full
    read after the install) and no line under it. The Actions tab has Add
    Motion Sensor, Add Motion Area, Re-link Motion Device, Forget Motion
    Device and Log Motion Diagnostics. Paste the full order of the tab, 27
    buttons on a release build (22 before), so that the quick reference in
    the manual's chapter 13 and the caption of its picture in chapter 5 can
    follow it.
    - **Done:** open.
53. **Add Motion Sensor and Add Motion Area with nothing to add** (EC §10
    item 4; EC B5). Open Add Motion Sensor and open its `Sensor` list:
    paste the one line it holds, since the house bridge has no sensor
    (expected "(no motion sensors on the bridge)"; "(no motion sensors
    fetched yet; connect the event stream)" before the first full read).
    Its `Room` list has "(mapped room)" first. Cancel. Do the same with
    Add Motion Area and its `Area` list: the Bridge Pro serves the area
    types but has no area (expected "(no MotionAware areas on the
    bridge)"). Then open each dialog again, leave the lists empty and click
    OK: paste the refusal in `Last Action` (expected "Not added: pick a
    motion sensor first" and "Not added: pick a MotionAware area first").
    Nothing is created.
    - **Done:** open.
54. **Log Motion Diagnostics** (contract §4.3; HR §7.2 items 1 and 2).
    Select the bridge and open its **Lua** tab, then its Actions tab. Click
    Log Motion Diagnostics and return to the Lua tab within 20 seconds.
    Expect `Last Action` "Motion diagnostics start in 20 seconds: open
    this bridge's Lua tab now. The pass and 10 minutes of events follow;
    copy them into the Beta feedback issue.", then in the Lua output (each
    line of the diagnostics starts with "Hue Bridge: diag: ") the pass and
    its last line "Motion diagnostics: pass done (0 sensors, 0 areas, <n>
    automations); capturing events for 10 minutes." After the ten minutes
    `Last Action`, and the Lua output, read "Motion diagnostics done: <n>
    items of events logged. Copy the Lua output into the Beta feedback
    issue." Paste the whole pass, and check:
    - the bridge's model and firmware, and the types `/resource/clip`
      serves, with `motion_area_configuration`, `convenience_area_motion`
      and `security_area_motion` among them;
    - `motion_area_configuration` answered with no items, and
      `motion_area_candidate` with a list of the house's compatible lights
      or a 404;
    - whether any room or zone lists `grouped_motion` without a sensor
      (expected: none);
    - the type counts, cameras, contact sensors and grouped motion
      included;
    - the house's Hue automations (`behavior_instance`, at most 40), each
      named by its script, with names as "name#N" and every time of day
      shown as the literal text "<clock>";
    - **the redaction on real data**: no room, zone or light name in clear
      (names read "name#1", "name#2"), no id longer than its first 4
      characters and "…", no MAC address, no bridge id, and no time of
      day in any line (the capture counts seconds from the start of the
      pass, "+12.40s");
    - **Composer's pane** (`docs/composer-remote.md` rule 13): are the
      lines of the pass all there, although the Actions tab was showing
      when they were written? If some are missing, say which. The manual
      (14.15) gives testers this same procedure and needs the answer.
    - **Done:** open.
55. **The stock proxy file** (C4R H4; read only). On the Windows PC, find
    `contactsingle_motionsensor.c4i` among Composer's own drivers (search
    Composer Pro's installation folder) and paste its path.
    - **Done:** open.
56. **A motion device added by hand** (C4R H2; contract §7). Select a
    room, open Items » Search, type "Hue Motion" and double-click "Hue
    Motion Sensor" (manufacturer Philips Hue; paste the driver's name and
    model as the search lists them). Expect:
    - in the tree, Control4's motion sensor icon, not a Hue icon;
    - Properties: the proxy's rows first (Invert Sensor unticked, Enable
      Debounce Timer, Debounce Time (ms) 100, State, Verified "No"), then
      the driver's rows under Advanced Properties in the contract's order:
      Driver Version, Status, Online, Enabled, Kind, Hue Name, Hue Room,
      Model, Hue Motion, Light Level, Temperature, Battery, Occupancy Hold
      Time (s) ("0"), Last Action, Debug Mode. Paste which of them a device
      without a kind shows. `Status` reads "Not bound to a Hue Bridge";
    - Actions: Refresh From Bridge, Test: Motion, Test: No Motion;
    - Connections: a "Hue Bridge" control input and a "Temperature"
      output, and no visible proxy connection;
    - Programming, the device's events: senses motion, stops sensing
      motion, Light Level Changed, Temperature Changed, Battery Low, Battery
      Normal, Offline, Online, Switched Off In Hue, Switched On In Hue. Its
      conditionals: is sensing motion, is not sensing motion, State is
      Verified, then the driver's own, worded as in `driver.xml`: Online,
      Enabled in the Hue app, Battery Low, Light Level (lux), Temperature C,
      Battery Level (%). Its variables: ContactState, StateVerified,
      LastActionTime, Online, Enabled, Light Level, Temperature C,
      Temperature F, Battery Level, Battery Low.
    - **Done:** open.
57. **Test: Motion and Test: No Motion** (C4R H3; contract §7). Make two
    NUMBER variables first (Agents » Variables, "Motion Test On" and
    "Motion Test Off"). In Programming, add "when <test device> senses
    motion: increment Motion Test On" and the same for "stops sensing
    motion" with "Motion Test Off". Then:
    - Test: Motion: State "Open", Verified "Yes", Motion Test On +1, and
      `Last Action` saying it was a test (the build writes "Test: motion
      sent; Hue's state returns within 30 s"; paste it);
    - Test: No Motion within 30 s: State "Closed", Motion Test Off +1;
    - Test: Motion, then wait 40 s without a click: expect State "Closed"
      again 30 s after the click and Motion Test Off +1, since a device
      that knows no Hue state goes back to what it showed before the first
      test (Closed), as a change; paste State and both variables;
    - the variables `ContactState` and `StateVerified` in Composer while
      Open and while Closed (C4R §2.1 expects `ContactState` true while
      Closed);
    - in the Control4 app, Security » Locks & Sensors: the test device is
      listed, with History entries for the changes (C4R T3, here without a
      sensor). Note whether notifications can be switched on for it
      (OS 3.4).
    - **Done:** open.
58. **Verified across a restart** (EC §10 item 1, as far as a device
    without a sensor can show it; only when a reboot suits you). Leave the
    test device Closed with Verified "Yes" (Test: No Motion). Reboot the
    controller from System Manager, then read State, Verified and `Status`
    on the test device, and the two variables. Verified "No" means the
    proxy forgets at a restart and waits for the device's first state (EC
    §0.2, assumed there). The device sends nothing after a start until the
    bridge reports (EC C12), so with no sensor it stays that way until a
    test. Expect neither event fired (the variables unchanged), and
    `Status` "Not bound to a Hue Bridge" and `Online` "No" after the first
    minute (it is not connected, and a device still unbound a minute after
    its start treats that as a disconnection). EC §10 item 2, a state that
    changed during the restart, needs a sensor: step 69.
    - **Done:** open.
59. **A hand-added device connected** (EC C1; optional, needs the owner's
    hands, since the Windows session cannot drag). Connect the test
    device's "Hue Bridge" input to the bridge's "Hue Lights" output.
    `Status` reads "Bound; waiting for the bridge". On the bridge, Link
    Devices: paste the motion part of `Last Action` (no unimported motion
    sensor has the test device's name). Disconnect it again: `Status` "Not
    bound to a Hue Bridge", and `Attention` gains no item, since the
    device was never linked.
    - **Done:** open.
60. **Delete the test device** (EC §10 item 3; EC C4). Delete it in
    Composer (select it, Delete, Yes). The test program's events go with
    it: Programming no longer lists them. That is why the manual says
    re-link, never delete. The bridge's `Motion Sensors` and `Attention`
    stay as they were, since the device was never linked. Delete the two
    test variables.
    - **Done:** open.

The tester's first round (his system, his sensors; he follows the manual's
chapter 14, and the owner passes on these steps and the answers):

61. **His setup** (C4R T1 and §9 questions 1 to 4; HR §7.1 item 1).
    Collect:
    - the Control4 OS and Composer Pro versions;
    - the bridge's `Bridge Model` and `Bridge Firmware`;
    - the sensors, by model id in the Hue app (indoor SML001 or SML003,
      outdoor SML002 or SML004), and how many;
    - the MotionAware areas, if any (Bridge Pro only);
    - how he programs motion today (Timer agents, or a hold on the device);
    - whether he wants temperature on Navigators or in a thermostat.
    - **Done:** open.
62. **Install** as in step 50 on his system: no "Restart Director?", every
    Hue device on the new `Driver Version`, and a `Motion Sensors` row
    that lists his sensors and areas. Paste the summary and the list.
    - **Done:** open.
63. **Diagnostics first** (C4R T8; HR §6 and §7.1 items 1 to 9; EC §10
    item 5). Run Log Motion Diagnostics before adding any device,
    following the manual's 14.15. During the ten minutes:
    - walk past each sensor twice, waiting in between until it reports no
      motion;
    - switch on a lamp next to one sensor;
    - walk through each area.

    He reads the output for private data, then posts it in a Beta
    feedback issue. From it we read:
    - the served types, and whether the deprecated fields are still sent
      (HR §7.1 item 2);
    - the sensitivity and its status (item 5), and whether sensors are
      children of rooms and which groups carry `grouped_motion` (item 7);
    - the battery state (item 8);
    - for an area: its group, participants and health, and which of its
      two services changes on a walk-through (item 9; EC §10 item 7 in
      part);
    - the order and timing of the motion items around one walk past, and
      whether `changed` is on every item (EC §10 item 5; EC R6);
    - how long motion stays true after the last movement, and whether
      anything arrives while movement continues (HR §7.1 item 3);
    - how often light level and temperature arrive (item 4).
    - **Done:** open.
64. **One sensor added** (C4R T2). Add Motion Sensor with the sensor and
    "(mapped room)" or a room: "Added <sensor> to <room> (device <id>)".
    Its Properties: `Status` "Hue motion sensor <name> in <Hue room>",
    `Kind` "Motion sensor", `Model` "<product name> (<model id>)", `Online`
    "Yes", `Enabled` "Yes", and `Hue Motion`, `Light Level`, `Temperature`
    and `Battery` filled; Verified "Yes" once the first state has arrived.
    With a test program as in step 57: walk in, and State turns "Open" and
    "senses motion" fires; leave, and it turns "Closed" and "stops sensing
    motion" fires. Time, three times, from the last movement to Closed
    (Hue's own hold).
    - **Done:** open.
65. **In the Control4 app** (C4R T3). Security » Locks & Sensors lists the
    sensor, with its history, and notifications can be switched on for it
    (OS 3.4).
    - **Done:** open.
66. **Occupancy Hold Time** (contract D10). Set it to 60 and click Set.
    Walk past and leave: `Hue Motion` reads "No motion since <HH:MM>"
    while State stays Open; about 60 s later State turns Closed and "stops
    sensing motion" fires once. Walk past again during the hold: it stays
    Open, and the hold starts again in full at the next "no motion". Set
    it back to 0.
    - **Done:** open.
67. **The temperature output** (C4R T4; contract D16). Add the
    Temperature Display driver to the sensor's room and connect its
    "Temperature In" to the motion device's "Temperature" output. Expect
    the display to show the temperature on a Navigator. Optionally,
    connect the output to a thermostat with a remote sensor input: does it
    take the value, and does it still use it after 20 minutes of steady
    temperature? A thermostat is reported to drop readings older than 15
    minutes, and the contract has no periodic re-send (only each full read
    sends the last value again).
    - **Done:** open.
68. **Light level, temperature, battery** (C4R T5). The device's rows and
    variables agree with the Hue app. Light Level Changed fires when a
    lamp next to the sensor is switched on (a test program as in step 57).
    - **Done:** open.
69. **A restart** (C4R T6; EC §10 item 2; EC R4; only when a reboot suits
    him). With the room empty and the sensor Closed, reboot the
    controller. Afterwards State is Closed, Verified "Yes" once the bridge
    has reported, and no event fired. Then reboot again while someone
    walks in during the restart: "senses motion" fires once after the
    start, late but never twice.
    - **Done:** open.
70. **Switched off, and unreachable** (EC §10 item 6; EC S7, S8, S9).
    Switch the sensor off in the Hue app while it shows motion. Expect:
    - State Closed at once, and "stops sensing motion" fires once;
    - `Enabled` "Switched off in the Hue app", and Switched Off In Hue
      fires;
    - `Status` "Switched off in the Hue app; no motion is reported";
    - `Attention` "1 motion sensor switched off in the Hue app: <name>".

    Switch it on: `Enabled` "Yes", and Switched On In Hue fires. Then
    remove its batteries and time how long it takes until `Online` reads
    "No" and `Status` "Not reachable since <HH:MM>; motion not current",
    with the contact left as it was. After an hour, at the bridge's next
    refresh of its rows (click Room Audit), `Attention` shows "1 motion
    sensor not reachable for more than 1 h: <name>". Put the batteries
    back: `Online` "Yes", and the item leaves `Attention` at once.
    - **Done:** open.
71. **One MotionAware area** (C4R T7; EC §10 items 7 and 8; EC A5, A6,
    A9; a Bridge Pro with an area only). Add Motion Area: "Added <area> to
    <room> (device <id>)". `Kind` and `Model` read "MotionAware area", and
    `Status` "MotionAware area <name> in <room or zone>" ("MotionAware area
    <name> (whole home)" for the whole home). Walk through: Open, then
    Closed, as in step 64. Pause the area in the Hue app and resume it:
    "Paused in the Hue app; no motion is reported", `Enabled` and the two
    events. Switch one of its lights off at the wall: `Status` "Area
    degraded: <n> of its <m> lights not responding" (or "Area degraded in
    Hue; check that its lights are powered", or "Area recovering in Hue");
    is motion still reported? If he uses the area for security as well as
    for lights, switch its use in the Hue app: does the device still
    follow motion?
    - **Done:** open.
72. **Optional: a sensor deleted and paired again** (HR §7.1 item 10; EC
    S5, S4, S6). With Log Motion Diagnostics capturing, delete the sensor
    in the Hue app and pair it again. Expect:
    - the device reads "Sensor deleted in Hue since <date>; re-link or
      Forget", and fires "stops sensing motion" once if it showed motion;
    - the new sensor appears in `Attention` at once, with a re-link hint:
      "1 new motion sensor on the bridge: <label> (same radio as <name>,
      device <id>; re-link?) (Add Motion Sensor)";
    - Re-link Motion Device points the old device at it, and its
      programming keeps working.
    - **Done:** open.

## K. Raise Level By and Restore Saved Level (#297)

Written on 2026-10-26, before the build, from the contract
(`docs/relative-level-design.md`); check every quoted text against the
build that brings the two commands. The owner's manual says the same in
prose (chapter 10, with this setup as its example, and the Hue Light's own
Documentation tab). The commands change no `<capabilities>`, so the
install needs no reboot. The Windows session reads Composer; the owner
makes the Programming drags (synthesized drags start no OLE drag,
`docs/composer-remote.md`) and walks.

73. **The house setup** (contract §3): the two Foyer lamps get 30 points
    brighter when the MotionAware area senses motion, and go back to their
    own levels 5 minutes after the last movement.
    - Install the build in place, all four files, as in step 50. Expect no
      "Restart Director?" and every Hue device on the new `Driver Version`.
    - The house has no Hue Light device for a single lamp (all deleted on
      2026-10-22, step 21). Add each Foyer lamp with Add Light and `Room`
      "(mapped room)" (Foyer → Foyer): "Added <name> #<n> to Foyer
      (device <id>)". Paste both.
    - On the area's motion device, set `Occupancy Hold Time (s)` to 30 for
      the checks below and click Set (300 at the end). The area's Hue
      automation stays at "do nothing" on motion and on no motion
      (`docs/status.md`), so only Control4 moves the lamps.
    - Programming: select a Foyer lamp among the actions and paste where
      Composer lists Raise Level By and Restore Saved Level, the two
      commands' parameters with their ranges (expected `Points` 1 to 100
      and `Ramp (ms)` 0 to 60000), the values Composer fills in before any
      change (whether it offers the defaults 30 and 1000 is not known), and
      how a dragged line reads in the script. Then the four drags: on the
      motion device's event "senses motion", Raise Level By with `Points`
      30 and `Ramp (ms)` 1000 for each lamp; on its event "stops sensing
      motion", Restore Saved Level with `Ramp (ms)` 1000 for each.
    - The walk: set one lamp to 40 % and switch the other off, then walk
      through the Foyer. Within about two seconds the first fades to
      70 %, `Last Action` "Raised from 40 % to 70 % (saved 40 %)", and the
      second comes on at 30 % (paste its `Last Action`). Leave: about 10 s
      after the last movement the motion device's `Hue Motion` reads "No
      motion since <HH:MM>" while State stays Open; 30 s later "stops
      sensing motion" fires, the first lamp fades back to 40 %
      ("Restored to 40 %") and the second goes off (paste its `Last
      Action`). Note the time from the last movement to the restore
      (expected about 40 s).
    - Changed meanwhile: walk through again and, before the restore, set
      the first lamp to 55 % in the Hue app. When the motion stops it
      stays at 55 % ("Not restored: changed to 55 % since the raise; saved
      level forgotten"), and the second goes off as before. The next walk
      raises the first from 55 % to 85 %, `Last Action` "Raised from
      55 % to 85 % (saved 55 %)".
    - Set `Occupancy Hold Time (s)` to 300 and click Set: the house setup.
      From the next end of motion the lamps go back about 5 min 10 s after
      the last movement.
    - **Done:** open.

## What to paste back

For each step: the property texts as shown, what the Navigator, keypad or
lamp did, the times where asked, and the Lua output of the device a step
names (its Lua tab in Composer). When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
