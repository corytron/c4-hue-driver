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
   at that level.
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

## What to paste back

For each step: the property text as shown, what the Navigator did, the
timings where asked, and a light's Lua output where asked. The bridge's Lua
output is already in the dev loop log. When something differs from the
expectation, the exact wording matters: it tells us which code path ran.
