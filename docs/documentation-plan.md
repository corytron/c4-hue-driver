# Driver documentation tab and Composer icon: the contract

Owner's request (2026-10-22): the Hue Bridge driver's icon in Composer should
look like a Hue Bridge Pro, and every driver should carry a **Documentation**
tab, like professional drivers do, that a layman can read on its own and
then use **all** of the driver: installation, every property, every action,
every flow and corner case, with pictures of the Composer screens being
referenced and examples of what to type into each field, plus how Hue's
constructs map onto Control4's. The deliverable is a new build with the
documentation and icon inside.

**Current (2026-10-24):** delivered. Build 125 (2026-10-22) brought the
Documentation tab in all three drivers and the first icons, build 135 the
reviewed second edition (13 chapters and a Glossary) and the
second-generation icons (`docs/design.md`, "Build 125" and "Build 135").
The manual has since been revised with the features that followed (keypad
Button Links, the scene dimmer). What shipped is noted in §1, §5, §6 and
§8. The 32 px List View tile of lights and scenes cannot be custom (verified 2026-10-25, `docs/icons-research.md`).

## 1. Mechanics (verified in the SDK fundamentals)

- Documentation tab: `driver.xml` gets `<documentation file="www/documentation.html"/>`
  and the file ships under `www/` in the `.c4z` [verified: Fundamentals 26,
  "Markdown Driver Documentation": the tag points at an HTML file under www;
  the SDK's own route renders Markdown to HTML with bundled React assets we
  do not have]. **Verified on the 2026-10-22 install of build 125**: plain static HTML
  in that file renders in Composer 3.4.2's tab, pictures included, with no
  prompt from the embedded browser. Composer's tab is a WinForms
  WebBrowser control (Internet Explorer engine), so the HTML must be
  conservative; see §4.
- Icons: a `.c4z` provides its own Composer icons with
  `<small image_source="c4z">images/devices_sm/<file></small>` and
  `<large image_source="c4z">images/devices_lg/<file></large>` placed after
  `<version>` in the driver header; the files live under `www/images/...`;
  16×16 and 32×32 pixels, **96 DPI** [verified: Fundamentals 19, "Driver
  Icon Management"]. Light and scene devices keep the light_v2 proxy's
  standard icons (they are lights to Control4); only the bridge changes.
  Superseded (2026-10-22): the owner asked for light and scene icons too
  (§6).

## 2. Deliverables and owners (one writer per file)

| Piece | Files | Owner |
|---|---|---|
| Bridge documentation | `src/hue_bridge/www/documentation.html` | writer agent |
| Light documentation (short, points to the bridge's) | `src/hue_light/www/documentation.html` | writer agent |
| Scene documentation (short, points to the bridge's) | `src/hue_scene/www/documentation.html` | writer agent |
| Screenshots | `src/hue_bridge/www/img/*.png` (names in §5) | Windows session captures and uploads; coordinator places |
| Icon | `tools/make_icons.py`, `src/hue_bridge/www/images/devices_sm/hue_bridge_pro_16.png`, `src/hue_bridge/www/images/devices_lg/hue_bridge_pro_32.png` | icon agent |
| Upload receiver | `tools/collect.py` | coordinator |
| `driver.xml` tags (documentation, small, large), build, install, this file | — | coordinator |

The light and scene drivers cannot show the bridge's images (each `.c4z`
is served separately), so their pages are text-only: what the device is,
its properties and two actions, and "the full manual is on the Hue
Bridge's Documentation tab".

## 3. Audience and content (the writer's brief)

Written for the home owner, not a programmer: no Lua, no API names, no
rids, no file paths; Composer's own words for every button, tab and field.
Every sentence must be true of the drivers as built (source of truth:
`src/*/driver.xml` for names, items and defaults; `docs/import-design.md`
§1–§10 and `docs/scenes-design.md` for the rules; `docs/design.md` for what
Composer and the bridge actually showed; `docs/composer-checklist.md` for
the exact texts of properties and `Last Action`). Quote those texts
verbatim where the reader will see them.

Required chapters, in this order:

1. **What this driver does** in five sentences; the three device types
   (Hue Bridge, Hue Light, Hue Scene) and how they appear in Composer and
   on Navigators.
2. **How Hue maps onto Control4**: Hue bridge → the Hue Bridge device; Hue
   light → a Hue Light device (a Control4 light with dimming, colour and
   colour temperature as the bulb allows); Hue room and zone → Room
   Mappings → a Control4 room; Hue scene → a Hue Scene switch device
   (ON recalls, OFF turns the room or zone off; a dimmer since 2026-10-23,
   `docs/scene-dimmer-design.md`); Hue names → device names
   (Adopt Hue Names / Accept Names As They Are); what has no counterpart
   (Hue zones as controllable devices, motion sensors, entertainment,
   several bridges, smart scenes).
   Current (2026-10-25, build 316): two of these have counterparts now:
   Hue rooms and zones as zone lights (Add Zone Light,
   `docs/zone-light-design.md`) and time-based ("smart") scenes as Hue
   Scene devices (`docs/smart-scenes-design.md`).
3. **Installation**: the three `.c4z` files, Driver ▸ "Add or Update Driver
   or Agent…" (multi-select), adding the Hue Bridge to a room, what the
   first Properties page looks like, that updates are done the same way
   in place and never by deleting the bridge (the pairing lives on it).
4. **Pairing**: Bridge IP Address (where to find it in the Hue app:
   Settings ▸ My Hue system ▸ the bridge), the **Set** button rule (a
   property change reaches the driver only when the row's Set button is
   clicked), Pair Bridge, pressing the link button within 30 s, what
   `Status` shows at each step (texts from `docs/composer-checklist.md`
   and `docs/design.md`), Test Connection, Forget Pairing, and what
   happens when the bridge is offline or changes IP.
5. **Properties of the Hue Bridge**, one short entry each, in the order
   Composer shows them: Driver Version, Debug Mode, Status, Bridge IP
   Address, Bridge ID, Bridge Model, Event Stream, Lights, Attention,
   Last Action, Room Mappings, Scenes, Stream Address, Events Received,
   Last Event, Diagnostic Server, Dev Server, Stream Timeout (s), Stream
   Watchdog (s). Say which are read-only, which the owner edits, which
   are for the developer only (Diagnostic Server, Dev Server, Debug Mode,
   Stream Address) and should be left alone.
   Current (2026-10-25, build 316): a release build shows Driver Version,
   Debug Mode, Status, Bridge IP Address, Bridge ID, Bridge Model, Bridge
   Name, Bridge Firmware, Event Stream, Lights, Attention, Last Action and
   Last Action (2) to (6), Room Mappings, Scenes, Zone Lights, Stream
   Address, Events Received, Last Event, Stream Timeout (s) and Stream
   Watchdog (s); Diagnostic Server and Dev Server are in the DEV-ONLY
   block of `src/hue_bridge/driver.xml`, which `tools/build.sh` strips
   from release builds.
6. **Rooms first**: Room Mappings, Map Rooms By Name, Set Room Mapping
   (Hue Room picker, Room picker, "(no mapping)"), what "(unmapped)" and
   "(Control4 room gone)" mean, zones in the list, Room Audit and why the
   driver never moves a device itself.
7. **Importing lights**: Import All New Lights, Add Light (Light picker
   with "[Hue room] #n" entries, Room picker with "(mapped room)" and
   "Floor / Room" rows, and the dialog remembering last values), where the
   device lands, the name it gets, what the light's own Properties show,
   Lights count line explained field by field.
8. **Living with it**: two-way state, renames on either side (Attention,
   Adopt Hue Names, Accept Names As They Are, Adopt Hue Name on one
   light), a bulb replaced or deleted in Hue ("Gone from the Hue bridge",
   Re-link Device To Light), a device deleted in Composer (tombstone, Add
   Light lists it as "(deleted from Composer <date>)", Import All New
   Lights skips it on purpose), Forget Light, Link Devices and the bare
   "Hue Light" case (binding in Connections, exact-name rule), bridge
   offline and back, factory reset or restore of the bridge.
9. **Scenes**: Scenes count line, Add Scene (picker format "<Room>: <Scene>",
   zones as "<Zone> (zone): <Scene>", "(dynamic)"), Add All Scenes Of
   Room, the switch device's behaviour (ON, OFF, tile following Hue, a
   member light changed by hand), the scene device's Properties incl.
   Recall As ("As set in Hue", "Static", "Dynamic" as listed in the
   driver.xml), Adopt Hue Name, Forget This Scene, Re-link Scene, Forget
   Scene, Refresh Scenes, a scene deleted or renamed in Hue, programming
   with scenes in Composer (they are lights: Advanced Lighting Scenes and
   programming can turn them on and off).
   Current (2026-10-25, build 316): a Hue Scene is a dimmer since build
   160 (`docs/scene-dimmer-design.md`); the Scene picker also lists
   time-based scenes, first in their room or zone ("<Room>: <name>
   (time-based)"), and marks a scene a schedule plays ("(in
   <schedule>)") (`src/hue_bridge/bridge/scenes.lua:picker_scenes`).
10. **Hue Light device**: its Properties and two actions; colour and
    colour temperature appear only when the bulb supports them; Online.
11. **Troubleshooting**: a table of `Status`, `Attention` and `Last Action`
    texts the owner may see and what to do; the diagnostics actions
    (Test Connection, Connection Test with Target Bridge / Diagnostic
    Server, Connect / Disconnect Event Stream, Reload Credentials, Check
    CA Pinning) in one paragraph each, marked "normally not needed".
    Current (2026-10-25, build 316): Connection Test, Reload Credentials
    and Check CA Pinning are DEV-ONLY actions of
    `src/hue_bridge/driver.xml`, absent from release builds, which the
    Composer manuals describe (`docs/doc-accuracy-design.md` §1).
12. **Limits and what is not supported**, and a one-page **quick
    reference** of all actions with one line each.

As shipped (build 135) the manual has 13 chapters, this list plus "Using
the lights from Control4" (§8 item 11) as chapter 11, and a Glossary.

Every action and every property of the three drivers must appear at least
once with its exact Composer name in bold. Field examples are written as
the reader would type or pick them, e.g. "Bridge IP Address: 10.0.2.143"
(use the bridge placeholder or RFC 5737 documentation addresses, never the
house's; until 2026-10-25 the manual used home-network-looking ones, #64).
Corner cases are stated as "if … then the driver … and you …".

## 4. HTML rules (Composer's tab is an Internet Explorer control)

- One self-contained file: HTML 4-style markup, a single `<style>` block,
  no JavaScript, no external fonts, scripts or stylesheets, no CSS grid or
  flexbox, no CSS variables; tables for tables, `<h2>/<h3>` headings, a
  table of contents with in-page anchors at the top.
- Images: `<img src="img/<name>.png" width="…">` with the names of §5
  only, each with a one-line caption under it; never wider than 700 px.
  The writer references them before they exist; the coordinator drops the
  files in. A missing image shows as a broken icon in the tab, so the
  caption must carry the meaning on its own.
- Plain fonts (Arial/Segoe UI, sans-serif), 14 px body, dark text on
  white; readable when printed.
- No marketing, no exclamation marks; Composer's names in bold on first
  use, property values and `Last Action` texts in `<code>`.

## 5. Screenshots (fixed names; the Windows session captures them)

Captured on the live system on 2026-10-22 with release build 116, cropped
to the window or dialog, PNG, no scaling. "Properties page" means the
right-hand pane with the device selected in System Design.

| File | Shows |
|---|---|
| `img/add-driver-menu.png` | Composer's Driver menu open with "Add or Update Driver or Agent…" highlighted |
| `img/tree-bridge.png` | System Design tree with the Hue Bridge selected in its room |
| `img/bridge-properties.png` | Hue Bridge Properties page, whole pane |
| `img/bridge-actions.png` | Hue Bridge Actions tab, whole list |
| `img/set-button.png` | A bridge property row after editing, with its Set and Cancel buttons visible (edit Stream Timeout, shoot, then Cancel) |
| `img/room-mappings.png` | The Room Mappings row, cropped so the text is readable |
| `img/set-room-mapping.png` | Set Room Mapping dialog with the Hue Room picker list open |
| `img/set-room-mapping-room.png` | The same dialog with the Room picker list open ("(no mapping)" and "Floor / Room" rows) |
| `img/room-audit.png` | Last Action after Room Audit, cropped |
| `img/add-light.png` | Add Light dialog with the Light picker list open |
| `img/add-light-room.png` | Add Light dialog with the Room picker list open ("(mapped room)" first) |
| `img/light-properties.png` | A Hue Light device's Properties page (Left Bedside Light, re-added for this) |
| `img/light-actions.png` | That device's Actions tab (Adopt Hue Name, Forget This Light) |
| `img/attention.png` | Bridge Attention row reading "1 Hue names differ from the Composer names: …" after a rename, cropped |
| `img/connections.png` | Connections view for a Hue Light showing its Hue Bridge input bound to the bridge |
| `img/forget-light.png` | Forget Light dialog with its Device picker open |
| `img/relink-device.png` | Re-link Device To Light dialog with both pickers visible |
| `img/scene-properties.png` | Bedside Lights Nightlight Properties page |
| `img/scene-actions.png` | That device's Actions tab |
| `img/add-scene.png` | Add Scene dialog with the Scene picker list open |
| `img/add-all-scenes.png` | Add All Scenes Of Room dialog with the Hue Room picker open |
| `img/recall-as.png` | The scene device's Recall As row with its list open |

Upload: `python3 -I tools/collect.py --dir build/collect` runs on this VM
(port 8090); the Windows session sends each file with
`Invoke-WebRequest -Method Put -InFile <file> http://<this VM>:8090/img/<name>.png`.
The coordinator copies `build/collect/img/*` to `src/hue_bridge/www/img/`.

Shipped: all 22, plus `relink-device-light.png` from §8 item 26, so 23
files in `src/hue_bridge/www/img/`, each shown once in the manual; all
date from 2026-10-22 and none shows the later keypad or dimmer features
(the module's `Save-*Shot` and `Send-DocShot`, `docs/composer-remote.md`,
do the cropping and upload).
Current (2026-10-25, build 316): 22 files. `tree-bridge.png` left the
manual and the repository on 2026-10-24 (build 231, PR #34, #158: it
showed the house's device inventory), and `bridge-properties.png` was
redacted to the placeholder bridge id; the retake on a demo project is #61
(`docs/screenshots-plan.md`).

## 6. Icons

All drawn by `tools/make_icons.py` with Pillow at 16×16 and 32×32, 96 DPI
metadata, transparent corners, PNG; no logos or trademarks, the shape is
the hint. The owner's addition of 2026-10-22: the light and scene devices
get icons too (they replace the light_v2 proxy's standard ones in
Composer only; Navigator is unaffected).

- **Hue Bridge** (`src/hue_bridge/www/images/devices_{sm,lg}/hue_bridge_pro_{16,32}.png`):
  a Hue Bridge Pro, a flat near-black rounded rectangle seen from above
  with a small row of status LEDs and a lighter edge.
- **Hue Light** (`src/hue_light/www/images/devices_{sm,lg}/hue_light_{16,32}.png`):
  the Philips Hue dimmer switch from the owner's second photo: an off-white
  portrait wall plate with a bevelled edge and a proud rocker remote split
  by three grooves into four stacked buttons marked I, a large sun, a small
  sun and O (glyphs at 32 px; plate, remote and grooves at 16 px).
- **Hue Scene** (`src/hue_scene/www/images/devices_{sm,lg}/hue_scene_{16,32}.png`):
  the same switch with its four buttons lit from within in a hue sweep
  (amber, green, azure, violet) and a coloured glow bleeding onto the plate.

The second generation (2026-10-22, after the owner judged the first flat):
every icon is a 512 px master lit from a height map (bevels, grooves,
ambient occlusion, specular, grain, drop and contact shadows) and
downsampled with LANCZOS, geometry hinted to whole target pixels per size,
then unsharp-masked in premultiplied alpha and contrast/gamma tuned per
size. `python3 tools/make_icons.py --inspect DIR` also writes the masters
and an inspection sheet.

Wiring: each driver's header gets `<small image_source="c4z">` and
`<large image_source="c4z">`; the light and scene drivers also set
`image_source="c4z"`, `small_image` and `large_image` on their `<proxy>`
element so the List View uses them **[assumed: the attribute form for c4z
proxies, by analogy with the url form in Fundamentals 19; verified on the
install]**.

Shipped: the first icons in build 125, the second generation in build 135
(2026-10-22). Outcome on the house (`docs/design.md`, "Build 125" and
"Build 135"): the bridge's icon changed at once in the tree and the List
View. A light or scene device's 16 px tree icon is stamped when the device
is created: a device created under a build that declared a custom icon
shows it and follows later icon changes, one created before keeps the
standard bulb for good. The 32 px tile in the room's List View is
Composer's own: it draws every light_v2 device (Hue or Control4 alike) as a
status tile, "Name:" and "Level:" with a bar, with a picture built into
Composer, so a driver's `large_image` never shows there [verified 2026-10-25,
Composer round 37: the four Hue light and scene tiles are pixel-identical to
the Control4 dimmers' in the same room; the bridge, not a light, shows its
own 32 px icon]. Nothing to change (`docs/icons-research.md`). The Items pane shows a generic placeholder for all
three drivers, as it does for Control4's own Hue drivers.

## 7. Verification

`luacheck src tests`, `busted tests` unchanged; `tools/build.sh` packs
`www/` (the manifest already includes every directory); `unzip -l` shows
`www/documentation.html`, `www/img/*.png`, `www/images/...`. Install
through the Windows session with "Add or Update Driver or Agent…" (owner's
word: "Go ahead and rev a new driver with the document when you are
done"); then read the Hue Bridge's **Documentation** tab: the page renders,
images show, the icon in the tree and list view changed. Results go into
`docs/design.md` (Composer UI section).

## 8. Review round (2026-10-22): five graded readers, one revision

Five read-only reviewers (a child, a novice owner, a hobbyist, an
integrator, and a maximum-depth engineer-editor) compared the shipped
manual with every design document, the checklist, the three `driver.xml`
and the code. Their reports are kept outside the repo; what they agreed on
and what the coordinator accepted is this list. The revision keeps the
chapter structure of §3 and the HTML rules of §4; the code stays the truth.

**Errors to correct (must)**

1. 8.2 renames: a device renamed in Composer is reported in `Attention`
   within seconds (the bridge listens for Composer's rename event); a
   light renamed in the Hue app is reported at the next full read or any
   bridge action. `Accept Names As They Are` remembers the Hue name it
   accepted, so a later Composer rename is not re-reported; only a Hue-side
   name change re-arms it.
2. 8.6 a Forgotten device bound again announces its remembered Hue light
   and the bridge adopts it on the spot; its Status returns to the normal
   text and `Link Devices` then answers "All N bound devices are
   registered", which is success. `Bound; waiting for the bridge` is the
   bare hand-added device only. Mention the conflict answer when that
   light was re-imported meanwhile.
3. 4 step 2: while paired, an invalid `Bridge IP Address` (letters,
   leading zeros, octets above 255) drops the stored address, `Status`
   returns to "Enter the bridge IP address" and the event feed stops until
   a valid one is set.
4. Delete the troubleshooting item "Room Mappings says (deleted in Hue)
   for every room right after a restart" (fixed in code).
5. 5 `Stream Address` example: the manual's address then had one paddable
   octet, so the text is "(own queue, no second spelling to rotate; …)";
   an address with no octet below 8 reads "(shared queue with commands: no
   octet below 8 to pad; stream timeout capped at 60 s)".
   Current (2026-10-25, build 316): the row reads "<address> (own queue,
   the only spelling)" or "(own queue, spelling N of M)", and without an
   octet below 8 "<address> (shared queue with commands: no octet below 8
   to pad)"; the 60 s cap is in the log line only
   (`src/hue_bridge/driver.lua:stream_address_text`,
   `choose_stream_address`).
6. "HTTP 401" everywhere becomes "HTTP 401 or 403" (the code prints the
   code it gets; Hue documents 403 for a revoked key).
7. Import skip label carries the tag: "Vanity 3 #92 (deleted 2026-10-22)".
8. `Forget Pairing` before pairing a different bridge is optional, not
   required (the bridge id is not checked); say devices go "Gone".
9. Chapter 1's "never … on its own" names the two exceptions up front:
   the one-time Map Rooms By Name at first contact, and re-adoption of a
   device that announces a light the bridge already knows.
10. `Attention` lists one item per kind of thing (new, missing, unbound,
    names, conflicts, scenes…), each naming at most three devices and then
    "+N more". (The review called this a six-item cap; six is the number
    of kinds, so the manual states the real rule.)

**Gaps to add (must)**

11. A chapter "Using the lights from Control4" after the Hue Light device
    chapter: a Hue Light is an ordinary Control4 dimmer in Programming,
    keypads and Navigators; `Turn On` and a tap mean 100 %, not Hue's
    power-on level; events fire for changes made in the Hue app too; a Hue
    Scene is a switch (0 or 100) and an Advanced Lighting Scenes member
    (superseded 2026-10-23: a dimmer showing its room's level,
    `docs/scene-dimmer-design.md`);
    a whole-room command sends one request per light at ten per second,
    so a room of 47 lights takes about five seconds; "stop ramp" settles at
    the last reported level; Refresh Navigators after adding devices.
12. Network prerequisite (chapter 3 and 11): the live feed gets its own
    connection only when the bridge address has an octet below 8;
    otherwise it shares the command connection, `Stream Timeout (s)` is
    capped at 60 and commands can wait behind the feed. Recommend such an
    address; IPv4 only.
13. Offline behaviour (chapter 4 and 10): an unreachable light's tile is
    disabled on Navigators; a tap during an outage shows the requested
    level after a second although the bulb did nothing, and the command is
    retried until the bridge is back, even hours later; a scene recall is
    one request and is not retried. (Superseded 2026-10-25, #43: a command
    is retried for at most 30 s after its last change, then dropped.)
14. 8.8 adds project restore from a Composer backup and controller
    replacement: what lives on the bridge device (key, registry,
    tombstones, mappings), what each device remembers, the expected steps
    (Pair Bridge, then Link Devices which adopts by remembered identity),
    and that the store surviving a project restore is unverified.
15. Chapter 3 adds update and rollback (same "Add or Update" route with an
    older build; untested), and how to tell a release from a development
    build (`Dev Server` is ignored by a release).
    Current (2026-10-25, build 316): a release build has no `Dev Server`
    row at all (`tools/build.sh` strips the DEV-ONLY block).
16. `Set Room Mapping` gets the same "the dialog remembers the last values;
    check both rows" warning as Add Light.
17. Chapter 9 lists the scene device's `Driver Version` and `Debug Mode`.
18. One sentence under `Last Action`: "(device N)" in bridge texts is the
    device's protocol id; Composer's tree shows the proxy id, one higher.
19. `Connection Test` can hold the command connection for up to five
    minutes; say so.
    Current (2026-10-25, build 316): Connection Test is a dev-build
    action.
20. Troubleshooting rows for: "Busy: resyncing scenes; try again in a
    moment", "Import failed: …", "Scene refresh failed: …", "Not added:
    pick a Hue room first", "Not re-linked: pick a device and a scene", the
    "no Hue room" and "mapped to a Control4 room that no longer exists"
    variants of "Not added", "Pairing failed: Pairing request failed: …",
    "Pinning check FAILED …", "Stored credentials readable but differ from
    memory …", "Set the Diagnostic Server property first (host:port)", the
    other "Not re-linked" texts, "Not mapped: Control4 room N does not
    exist", "No mapping for X to remove", Room Audit's "; N not found in the
    project", `Event Stream` "Stopped" after Connection Test or an invalid
    address, "Disconnected: server closed the stream (HTTP 200)", "Recall
    failed: HTTP 404", Add All Scenes refusals ("… has no scenes", "… is not
    on the bridge"), Link Devices' duplicate-claim and "(not on the bridge:
    marked gone)" texts, Attention's "unbound scene device" and "2 devices
    claim Hue scene …", and the scene Status texts (Not bound / Bound;
    waiting / Forgotten).
    Current (2026-10-25, build 316): "Pinning check FAILED …", "Stored
    credentials readable but differ from memory …", "Set the Diagnostic
    Server property first (host:port)" and `Event Stream` "Stopped" after
    Connection Test come from dev-build actions only
    (`src/hue_bridge/bridge/devtools.lua`).
21. Scenes: `Link Devices` matches a scene device by the plain scene name;
    OFF on a scene of an empty zone reports off without a request;
    `Recall As` and a programmed ramp (the ramp becomes the recall
    transition); bridge_home scenes appear as "(all lights): Scene".

**Readability (should)**

22. A short "Finding your way in Composer" section at the start of chapter
    3: System Design, the tree, selecting a device, the right-hand tabs
    (Properties, Actions, Documentation, Lua), how an action is run, the
    Select dialog's inner and outer OK, renaming (F2), deleting, dragging
    a device to a room, reaching the Connections view, and where "Lua
    output" is (the Lua tab).
23. A glossary at the end: bound / linked, mapping, room vs zone, scene,
    Navigator, full read, event feed, DHCP reservation, Hue identity.
24. No "rid" (say "its Hue identity"); no GET / HTTP words outside quoted
    texts; "containers" explained once where the Event Stream text is
    quoted.
25. One term each: "event feed" (not live feed / event stream), "full read"
    (not refresh / re-read / resync), "gone" vs "missing" used as the texts
    use them, "Hue Light" for the device and "light" for the bulb.
26. Captions say what to look at; the paired `bridge-properties.png` moves
    under the paired text; `relink-device-light.png` joins §5; images at
    their native widths; scene subsections numbered like 8.x; the light
    paragraphs duplicated between 7 and 10 merged.

**Code nits (fixed in the same pass)**

27. `hue_scene/driver.xml` actions get `<sort_order>` so Composer lists
    Adopt Hue Name before Forget This Scene; the "Pairing failed: Pairing
    failed: …" doubled prefix; Room Audit's "All 1 linked lights" plural.

**Not done**: verifying whether a revoked key answers 401 or 403 (needs the
key revoked on the house bridge). Since 2026-10-25 (#44): an unknown key
gets 403 from the house Bridge Pro (`docs/design.md`, "A rejected key"); a
revoked key is assumed to get the same.

**Outcome**: the revision shipped in build 135 (2026-10-22 14:21); the
Documentation tab then showed the 13 chapters and the
Glossary, in-page links worked and every picture rendered, and the scene
device lists Adopt Hue Name before Forget This Scene (`docs/design.md`,
"Build 135"). The revoked-key question is still open (`docs/status.md`).
