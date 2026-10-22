# Composer checklist: lights

Run in Composer Pro on the Windows VM with the **dev builds** from `build/`
(`tools/build.sh --dev`; the developer builds them and puts them where the
Windows VM can see them). Lua changes now reach the controller through the
dev loop (`docs/dev-loop.md`), so Composer is needed for three things only:
the `driver.xml` changes in this build (new properties and the new action),
the Import Lights click, and what the dev loop cannot see: the project tree,
the Connections tab, a Navigator, and each light's own Lua output. The
bridge's Lua output is shipped to the dev loop, so you do not need to paste
it; property text, Navigator behaviour and a light's Lua output you do.

Set the bridge's `Debug Mode` to On. Where a step quotes property text, that
is the exact text to expect; where it does not, the contract leaves the
wording open, so paste what you see.

## A. Install and update (Composer)

1. Drivers → Add or update drivers → add `hue_light.c4z` (dev build). It only
   has to be in the project's driver database so the bridge can create lights
   with `C4:AddDevice("hue_light.c4z", …)`; do **not** add a Hue Light device
   by hand. If a Hue Light from the scaffold checklist is still in the
   project, delete it now: it has no Hue light id and the import cannot adopt
   it (it creates its own devices). Deleting a light loses nothing; only the
   bridge holds the pairing.
2. Drivers → Add or update drivers → update `hue_bridge.c4z` **in place**.
   Never delete and re-add it: a re-added bridge has a new device id and an
   empty persistence store, so the pairing and the light registry are lost.
   Expect, within a few seconds:
   - `Driver Version` = the new build number.
   - `Status` = "Paired"; `Event Stream` = "Connected since HH:MM:SS".
   - A new `Lights` property. Paste its text before any import; the contract
     does not define it.
   - Actions tab: a new **Import Lights** action.
   - `Dev Server` kept its value (properties survive an in-place update), so
     the dev loop reconnects by itself; the developer confirms with
     `devctl.py status`.

## B. Import Lights

3. Actions → **Import Lights**. Watch the project tree under the bridge's
   room: Hue Light devices appear **one at a time**, each named as in the Hue
   app (the import adds the next light only after the previous one is in the
   project). If the tree does not update, select another room and come back
   before concluding nothing happened. Note roughly how long the whole import
   took and how many devices appeared.
   - `Lights` changes as the import proceeds and ends with three counts:
     lights on the bridge, imported, new. The wording during a first run is
     not fixed by the contract; paste the final text.
   - Nothing needs binding by hand.
4. Pick two or three of the new lights (one colour bulb, one white-ambiance
   bulb, one white-only bulb if you have them). For each, in Composer:
   - Properties: `Hue Light ID` = a Hue resource id (UUID shape,
     `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`); `Hue Name` = the name in the
     Hue app; `Model` filled; `Online` showing the bulb is reachable;
     `Driver Version` = the build. Paste `Status`, `Model` and `Online` as
     shown: their wording is not fixed by the contract.
   - Connections tab: the light's "Hue Bridge" connection is **already
     bound** to the bridge's "Hue Lights" connection.
   - Lua output: paste the last lines. This is the one Lua output the dev
     loop cannot see.
5. Actions → **Import Lights** a second time. Expect no new devices and
   `Lights` = "N lights on bridge, N imported, 0 new", with N the number of
   lights the bridge has (for example "47 lights on bridge, 47 imported,
   0 new"). Any other third number, or a new device, is a bug: paste the text.

Leave the lights in the bridge's room for the rest of the checklist; move
them to their real rooms afterwards (moving does not touch the binding).

## C. Two-way state

6. Open the bridge's room in a Navigator (touch screen, OS app or phone).
   The lights show their current state. In the Hue app, turn one light off
   and on and change its brightness. The Control4 light follows each change
   within about 1–2 s (the bridge batches to one event per second). `Events
   Received` on the bridge rises at the same time.
7. If you have a Hue switch or dimmer, press it: same expectation.
8. Switch one bulb off at the lamp (power, not the app) and watch that
   light's `Online` property and its Navigator tile. Note whether and when
   they change; Hue can take minutes to notice a dead bulb. Power it back on
   and note how long it takes to come back.

## D. Control from Control4

9. In the Navigator, on one light: tap on and off, then drag the slider to a
   few levels and let go. Expect the bulb to respond within about a second
   and the slider to settle on the level Hue reports back, never stuck at an
   intermediate value. 0% turns the bulb off; from off, a level turns it on
   at that level. Levels below 100% are the real test: Hue reports a
   requested 20 back as 20.16, and the proxy showed that decimal as 0%/off
   until the light driver started rounding (`slider-fix`). Expect the slider
   to stay at 25%, 60% and 100% and the tile to read "on" for each.
10. On a colour bulb, open the colour controls. Expect both a colour wheel
    and a colour-temperature control; pick a colour, then a temperature, and
    confirm the bulb follows each. On a white-ambiance bulb only the
    temperature control should be offered; on a white-only bulb neither
    (the bridge tells each light what its bulb supports). Paste the
    temperature range the Navigator offers for one bulb; it comes from the
    bulb's own range and should be roughly 2000–6500 K.
11. Colour while off: turn a colour bulb off, pick a colour (if the Navigator
    lets you), confirm the bulb stays off, then turn it on. It should come on
    in that colour.
12. Slider spam. Say when you start, drag one light's slider back and forth
    for five seconds, say when you stop. Expect the bulb to follow with at
    most a short lag and to end at the slider's final position, with no
    error or "Disconnected" on the bridge's `Event Stream`. The developer
    counts the PUTs in the dev loop's log between your two times: at most
    about ten per second (the bridge's budget), far fewer than the slider
    events, and no 429 responses.

## E. Driven through the dev loop (not yours)

The developer does these from the VM; listed so you know which steps are not
waiting on you:

- Pushing Lua to both drivers. The bridge reloads itself and forwards the
  light tree to every bound light. A light's reload line appears only in its
  own Lua output in Composer, so you may be asked to open one light's Lua
  tab and paste the last lines after a push.
- Re-running **Import Lights**, the dev-only **Hue Request**, and reading the
  bridge's log and properties (`devctl.py run|wait|log|status`).
- Counting the PUTs for step 12 (`build/dev/driver.log`).
- Every later Lua change. Composer is needed again only for a `driver.xml`
  change (a new property or action), a Director restart, and anything only
  Composer or a Navigator shows.
- Stream address rotation (branch `stream-rotate`): two reloads a minute
  apart. After each, `Event Stream` must show "Connected since" within
  seconds, not minutes, and `Stream Address` must show a different spelling
  than before (for example `10.000.001.143` then `10.000.01.143`, "rotating
  over 7 spellings"). A reconnect that still sits in "Connecting" until a
  bridge event means the new transfer queued behind the old one after all.

## F. Still open from the spike

13. (spike step 12) Restart Director. Expect, without touching anything:
    `Status` = "Paired", `Event Stream` = "Connected since …", `Lights` still
    showing step 5's text, every light showing its real state in the
    Navigator (the bridge re-sends capabilities and full state to every
    registered light at startup), and the colour controls still present on
    colour bulbs. Toggle a light in the Hue app to confirm the stream. The
    dev loop reconnects on its own; the developer confirms.
14. (spike step 13) Leave it running for at least an hour with the defaults.
    Then paste `Event Stream`, `Events Received` and `Lights`, and whether a
    light in the Navigator still follows the Hue app. The developer checks
    the shipped log for reconnects and errors.

## G. Selective import, rooms and lifecycle (the `import-ui` build)

Both drivers changed their `driver.xml`, so this starts with an in-place
**Update Driver** of the bridge and of the light driver (A.2). The dev
loop has already verified on this controller: six resource GETs per
resync, the one-time room auto-map (9 Hue rooms matched Control4 rooms by
name), Lights Report, Room Audit and Map Rooms By Name. What only Composer
shows is below.

16. After the update, the bridge's Properties page should show three new
    read-only lines: `Attention` ("None" when nothing needs you),
    `Last Action` (the result of your last click) and `Room Mappings`
    ("Dining → Dining; Foyer → Foyer; …; Basement Hallway → (unmapped); …").
    `Lights` reads "47 on bridge, 47 imported, 0 new, 0 missing, 0 unbound,
    0 deleted". Paste all four. If the arrows render as garbage, say so.
17. Open one light's Properties: new `Hue Room` (its Hue room name),
    `Hue Light ID` now "#46 (e0e51794…)", `Last Action`. The Actions tab has
    `Adopt Hue Name` and `Forget This Light`. Paste `Hue Room` and
    `Hue Light ID` for one light.
18. Bridge Actions tab: the list should read Pair Bridge, Add Light, Import
    All New Lights, Re-link Device To Light, Link Devices, Forget Light,
    Adopt Hue Names, Accept Names As They Are, Set Room Mapping, Map Rooms
    By Name, Room Audit, then the diagnostics. Click **Add Light**: a dialog
    with two pickers should open, `Light` saying "(every light on the bridge
    is imported)" and `Room` listing "(mapped room)" then your rooms as
    "Floor / Room". Cancel. Say whether the dialog opened and what the two
    lists showed (this is the CUSTOM_SELECT rendering check for Composer 3.x).
19. **Set Room Mapping**: pick a Hue room without a Control4 twin (e.g.
    `Upstairs Hallway → (unmapped)`) and the Control4 room you want it to
    default to (e.g. `Second / Hallway`), OK. Expect `Last Action` "Mapped
    Upstairs Hallway → Hallway" and `Room Mappings` updated. Repeat for the
    Hue rooms you care about (the basement ones have no Control4 rooms yet;
    leave them, or create rooms first).
20. **Room Audit** → `Last Action` lists every light sitting in a room other
    than the one its Hue room maps to, as "Bar Left is in Room; Hue says
    Kitchen → drag it to Kitchen …". Drag a few in Composer, run it again:
    they should disappear from the list. Nothing is moved for you.
21. **Delete and re-add** (the tombstone flow). Delete one unpowered light
    in Composer. Expect the bridge's `Attention` to say nothing about it but
    `Lights` to end "…, 1 deleted" within a few seconds (if it does not, run
    Lights Report and paste the first lines: the bridge should have heard
    `HUE_GOODBYE` or seen the binding go). Then **Add Light**: the `Light`
    picker lists it as "<name> [<Hue room>] #<n> (deleted from Composer
    <date>)"; pick "(mapped room)" in `Room` explicitly (the dialog remembers
    the values of your last click). OK. Expect "Added <name>
    #<n> to <room> (device <id>)", the device in that Control4 room with the
    Hue name, and the tile working. **Import All New Lights** before the
    re-add must report "No new lights on the bridge" and skip the deleted
    one by name.
22. **Rename** one light in Composer (e.g. "Downlight 4" → "Downlight Four").
    Expect `Attention` to read "1 Hue names differ from the Composer names:
    Downlight Four is Downlight 4 in Hue (Adopt Hue Names or Accept Names As
    They Are)" after the next resync or within a minute. Click **Adopt Hue
    Names**: the device is renamed back in the tree (`Last Action` "Renamed
    1 devices: Downlight Four → Downlight 4 (device N)"). Rename it again and
    click **Accept Names As They Are** instead: `Attention` drops the item.
23. **The bare "Hue Light" device** (the one added by hand before the first
    import). In Connections, bind it to the Hue Bridge. Expect its `Status`
    "Bound; the bridge does not know this device. Use Link Devices on the
    bridge", bridge `Attention` "1 unbound device …" or the link hint, and
    **Link Devices** to answer "not linked 1: Hue Light (device 1034): no
    unimported Hue light has that name; rename …". Then **Forget Light** on
    one unpowered imported light (say "Vanity 3"), rename the bare device to
    "Vanity 3" in Composer, run **Link Devices** again: "Linked 1 devices:
    Vanity 3 (device 1034) to Vanity 3 [Master Bathroom] #n by name". The old
    Vanity 3 device now says "Forgotten by the bridge …" and can be deleted.
24. **Re-link** is for a bulb replaced or deleted on the Hue side: its device
    reads "Gone from the Hue bridge since …; re-link or Forget" and appears
    in the `Re-link Device To Light` Device picker as "… (device N, gone since
    …)"; pick the replacement light in the Light picker and expect "Re-linked
    device N (was <old>) to <new> [<room>] #n" with the device keeping its
    name, room and programming. Without a spare bulb this step is skipped. (A
    device you ran `Forget Light` on has no registry entry any more, so it is
    not offered here; its way back is binding it again in Connections and
    `Link Devices`, which adopts the rid it announces.)

## H. Scenes as switch devices (the `scenes` build)

A new driver, `hue_scene.c4z`, plus updated bridge and light drivers. Start
with Composer's **Add or update drivers** for all three (`hue_scene.c4z`
must be in the controller's driver store before `Add Scene` can create one);
update the bridge and the light in place as usual. The dev loop verifies
beforehand: the scene catalogue GET at resync, recall and status events,
and the bridge actions through `devctl`. What only Composer shows:

25. Bridge Properties: a new `Scenes` line, "125 on bridge, 0 imported,
    0 missing, 0 unbound, 0 deleted" once the stream has resynced ("0
    imported" before). Actions tab gains `Add Scene`, `Add All Scenes Of
    Room`, `Re-link Scene`, `Forget Scene`, `Refresh Scenes`.
26. **Add Scene** → the `Scene` picker lists every scene as
    "<Room>: <Scene>" (zones as "<Zone> (zone): <Scene>", dynamic ones with
    " (dynamic)"), grouped by room; `Room` offers "(mapped room)" first.
    Pick a Bedside Lights scene (e.g. "Bedside Lights (zone): Nightlight")
    with "(mapped room)" picked explicitly (the dialog remembers the last
    values): expect `Last Action` "Not added: Nightlight: Hue room Bedside
    Lights (zone) not mapped; pick a room, or Set Room Mapping first". Pick
    the Master Bedroom as `Room` instead: "Added Nightlight to
    Master Bedroom (device N)" and a device **"Bedside Lights Nightlight"**
    appears in the Master Bedroom as a switch tile (zone scenes carry the
    zone's name; room scenes are named like the scene alone).
27. Tap the new tile ON in a Navigator: both bedside lights take the
    Nightlight scene within a second and the tile stays ON (the bridge's
    scene status event closes the loop). Tap OFF: both lights go off (one
    grouped_light request) and the tile shows OFF. Change one bedside light
    by hand (Hue app or its own tile): the scene tile drops to OFF.
28. The scene device's Properties: `Status` "Hue scene Nightlight in Bedside
    Lights (zone)", `Hue Scene`, `Hue Room`, `Hue Scene ID` "#<id> (<rid…>)",
    `Recall As` = "As set in Hue" (change it to "Static", click the row's
    **Set** button, and tap ON again: the recall is sent as `static`),
    `Online` "Online". Actions: `Adopt Hue
    Name`, `Forget This Scene`.
29. **Add All Scenes Of Room** with a mapped room that has scenes (Kitchen,
    7 scenes): expect "Added 7 scenes of Kitchen to Kitchen: …" and seven
    switch tiles named after the scenes in the Kitchen. (Or test on a room
    with fewer scenes; Patio has 2.) Running it again: "No new scenes in
    Kitchen (7 on bridge, 7 imported)".
30. Delete one scene device in Composer, then `Add Scene`: the picker lists
    it last as "<Room>: <Scene> (deleted from Composer <date>)" and re-adding
    works; `Add All Scenes Of Room` before that skips it ("skipped 1 deleted
    in Composer (Add Scene re-creates one): …").
31. `Forget Scene` on one device: "Forgot <Scene> (device N): unbound and
    left in the project for you to delete; the Hue scene is listed under Add
    Scene again"; the device's `Status` reads "Forgotten by the bridge (was
    Hue scene <Scene>) …". Delete it in Composer.
32. In the Hue app, delete a throw-away scene you created for the test (or
    rename one): the matching device's `Status` becomes "Scene deleted in
    Hue since …; ON does nothing; re-link or Forget" and `Attention` lists it
    as missing; `Re-link Scene` points the device at another scene and the
    tile works again.

## What to paste back

For each step: the property text as shown, what the Navigator did, the
timings where asked, and a light's Lua output where asked. The bridge's Lua
output is already in the dev loop log. When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
