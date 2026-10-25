# Composer checklist

What only Composer, a Navigator, a keypad or the Hue app can show, as steps
for the owner. Every step describes what the current build (160) does. A
**Done** line under a step says when it was checked on the house and what it
showed; **Open** means it has not been checked yet. What runs on the house
and what is open overall is `docs/status.md`; the engineering record behind
each result is `docs/design.md`.

## Before you start

- **Release builds only.** The house has run release builds (no dev loop,
  no Lua command window) since build 116 on 2026-10-22. The developer builds
  them with `tools/build.sh`; the Windows Claude session downloads the three
  files of one build from the VM (checksums checked) and installs them
  (step 1). A development build goes on the house only when the developer
  asks for a test, and the release files replace it afterwards.
- **Capability changes need a reboot.** If an install makes Composer ask
  "Restart Director?", answer Yes, but it does not restart Director: the
  devices keep their old capabilities until you reboot the controller from
  System Manager (Tools > System Manager; it runs elevated, so only you can
  operate it). Then choose File » Refresh Navigators. Builds that change only
  Lua or connections take effect at once. Composer has no "Restart Director"
  command of its own.
- **Logs.** A device's Lua output is in its **Lua** tab in Composer. When a
  step asks for it, set that device's `Debug Mode` to On first and back to
  Off afterwards. Nothing is shipped to the VM any more.
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
     (2026-10-24), through the Windows session.
2. The update is **in place**. Never delete and re-add the bridge: a re-added
   bridge has a new device id and an empty store, so the pairing and every
   device link are lost. Expect on the bridge within a minute: `Status`
   "Paired"; `Event Stream` "Connected since <HH:MM:SS>"; `Attention` "None";
   `Lights` "47 on bridge, 0 imported, 0 new, 0 missing, 0 unbound, 47
   deleted" (the house today); `Scenes` "<n> on bridge, 1 imported, 0
   missing, 0 unbound, <d> deleted" (126 scenes on the bridge on
   2026-10-24). `Dev Server` and `Diagnostic Server` may still hold old
   values; a release build ignores `Dev Server`.
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
     rates, the On preset or button LED colours (step 35).
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
    temperature range offered (the bulb's own, roughly 2000–6500 K) and the
    line "first SET_COLOR_TARGET params: …" from the light's Lua tab (it is
    written whatever `Debug Mode` says). **Done 2026-10-25 from the record:**
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

## E. The dev loop (not in use on the house)

Since build 116 (2026-10-22) the house runs release builds, so nothing here
applies unless the developer installs a development build for a test. With
one, the developer pushes Lua to the bridge and its devices from the VM
(`docs/dev-loop.md`), reads the bridge's log there, and runs the dev-only
actions (`Hue Request`, `Probe Call`, `Lights Report` and the other probes,
which release builds do not have); a light's or scene's reload line appears
only in its own Lua tab.

- Stream address rotation: after each reconnect `Event Stream` shows
  "Connected since" within seconds, and `Stream Address` shows a different
  spelling of the bridge address than before, "<spelling> (own queue,
  rotating over <k> spellings; commands use <bridge address>)". The release
  build rotates the same way at every reconnect. **Done 2026-10-21** (dev
  loop, PR #6): two reloads took the second and third spelling and
  connected 200 and 160 ms after the attempt.

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

All of this is in the current build. Verified through the dev loop on
2026-10-21: six resource GETs per resync, the one-time room auto-map (9 Hue
rooms matched Control4 rooms by name), Room Audit and Map Rooms By Name.
Steps 17, 20, 22 and 24 need a Hue Light device; step 21 adds one.

16. Bridge Properties: `Attention` ("None" when nothing needs you), `Last
    Action` (the result of your last click), `Room Mappings` ("Dining →
    Dining; Foyer → Foyer; …; Basement Hallway → (unmapped); …") and
    `Lights` ("47 on bridge, 0 imported, 0 new, 0 missing, 0 unbound, 47
    deleted" today). The arrows must render as arrows. **Done 2026-10-21**
    (`Attention` "None"; `Room Mappings` with 9 mapped rooms, 7 unmapped
    rooms and 7 unmapped zones; `Lights` "47 on bridge, 47 imported, 0 new, 0
    missing, 0 unbound, 0 deleted"; arrows intact).
17. A light's Properties: `Hue Room` (its Hue room's name), `Hue Light ID`
    "#<n> (<8 hex digits>…)", `Last Action`; its Actions tab: Adopt Hue Name
    above Forget This Light. **Done 2026-10-21** (Left Bedside Light: "Master
    Bedroom", "#46 (e0e51794…)").
18. The bridge's Actions tab, top to bottom: Pair Bridge, Add Light, Import
    All New Lights, Re-link Device To Light, Link Devices, Forget Light,
    Adopt Hue Names, Accept Names As They Are, Set Room Mapping, Map Rooms By
    Name, Room Audit, Add Scene, Add All Scenes Of Room, Re-link Scene,
    Forget Scene, Refresh Scenes, Test Connection, Connect Event Stream,
    Disconnect Event Stream, Connection Test, Reload Credentials, Check CA
    Pinning, Forget Pairing. Click **Add Light**: a dialog with two pickers.
    `Light` lists the lights without a device, those deleted in Composer
    last as "<name> [<Hue room>] #<n> (deleted from Composer <date>)" (today
    all 47), or "(every light on the bridge is imported)" when there is
    none; `Room` lists "(mapped room)" then your rooms as "<Floor> / <Room>".
    Cancel. **Done 2026-10-21** (the dialog and lists render, the 23 actions
    in this order); **2026-10-22** the `Light` list held all 47 as deleted.
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
    ends "…, 1 deleted" and `Attention` says nothing (a Composer delete is
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
    No Composer names differ from the Hue scene names". Rename it again and
    click **Accept Names As They Are**: `Attention` drops the item. **Done in
    part 2026-10-21** (a rename raised the `Attention` item within seconds);
    Adopt and Accept on a real difference are **open**.
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

25. Bridge Properties: `Scenes` "<n> on bridge, <m> imported, 0 missing, 0
    unbound, <d> deleted" once the stream has done its first full read
    ("<m> imported" alone before). The Actions tab has Add Scene, Add All
    Scenes Of Room, Re-link Scene, Forget Scene and Refresh Scenes between
    Room Audit and Test Connection. **Done 2026-10-21** (the scene actions
    run from Composer).
26. **Add Scene**: the `Scene` list holds every scene without a device as
    "<Room>: <Scene>", zones as "<Zone> (zone): <Scene>", dynamic ones ending
    " (dynamic)", grouped by room, those deleted in Composer last; `Room`
    offers "(mapped room)" first. A zone scene with "(mapped room)" while the
    zone is unmapped: "Not added: Nightlight: Hue room Bedside Lights (zone)
    not mapped; pick a room, or Set Room Mapping first". With a room picked:
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
    Hue", `Online` "Online", and no rate or LED colour rows (step 35).
    Change `Recall As` to "Static", click the row's **Set** button, tap ON:
    the scene is set once instead of played (with the bridge's `Debug Mode`
    On, its Lua tab shows the recall "as static"). Actions: Adopt Hue Name
    above Forget This Scene. **Done 2026-10-21 22:03–22:04** (after Set the
    recall went out as static) and **2026-10-22** ("Static" → "As set in
    Hue" through the Set button).
29. **Add All Scenes Of Room** with a mapped room that has scenes: "Added <k>
    scenes of <room> to <room>: <scene> (device <id>), …", one tile each; run
    again: "No new scenes in <room> (<k> on bridge, <k> imported)". **Done
    2026-10-21** on Patio (Ibiza and Lily; the second run "No new scenes in
    Patio (2 on bridge, 2 imported)").
30. Delete a scene device in Composer: `Scenes` ends "…, 1 deleted"; Add
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
    and LED colours and a Hue Scene its hold rate and LED colours; change a
    hold rate once and see it on a keypad (#59's hardware check).

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
    off: nothing happens. **Open.**

A Hue Light on a keypad (needs a light; the Floor Lamp Switch is free):

39. Add Light (step 21) for the lamp, then bind the switch's buttons to the
    light's Top and Bottom Button Links as in step 34.
40. Tap top: the light goes to 100 % (the On preset) over 250 ms, from off
    or from any lower level, and the top LED lights. Tap bottom: off over
    250 ms, and the bottom LED lights.
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

## What to paste back

For each step: the property texts as shown, what the Navigator, keypad or
lamp did, the times where asked, and the Lua output of the device a step
names (its Lua tab in Composer). When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
