# Driver documentation tab and Composer icon: the contract

Owner's request (2026-10-22): the Hue Bridge driver's icon in Composer should
look like a Hue Bridge Pro, and every driver should carry a **Documentation**
tab, like professional drivers do, that a layman can read on its own and
then use **all** of the driver: installation, every property, every action,
every flow and corner case, with pictures of the Composer screens being
referenced and examples of what to type into each field, plus how Hue's
constructs map onto Control4's. The deliverable is a new build with the
documentation and icon inside.

## 1. Mechanics (verified in the SDK fundamentals)

- Documentation tab: `driver.xml` gets `<documentation file="www/documentation.html"/>`
  and the file ships under `www/` in the `.c4z` [verified: Fundamentals 26,
  "Markdown Driver Documentation": the tag points at an HTML file under www;
  the SDK's own route renders Markdown to HTML with bundled React assets we
  do not have]. **Assumed until the install shows it**: plain static HTML in
  that file renders in Composer 3.4.2's tab. Composer's tab is a WinForms
  WebBrowser control (Internet Explorer engine), so the HTML must be
  conservative; see §4.
- Icons: a `.c4z` provides its own Composer icons with
  `<small image_source="c4z">images/devices_sm/<file></small>` and
  `<large image_source="c4z">images/devices_lg/<file></large>` placed after
  `<version>` in the driver header; the files live under `www/images/...`;
  16×16 and 32×32 pixels, **96 DPI** [verified: Fundamentals 19, "Driver
  Icon Management"]. Light and scene devices keep the light_v2 proxy's
  standard icons (they are lights to Control4); only the bridge changes.

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
   (ON recalls, OFF turns the room or zone off); Hue names → device names
   (Adopt Hue Names / Accept Names As They Are); what has no counterpart
   (Hue zones as controllable devices, motion sensors, entertainment,
   several bridges, smart scenes).
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
10. **Hue Light device**: its Properties and two actions; colour and
    colour temperature appear only when the bulb supports them; Online.
11. **Troubleshooting**: a table of `Status`, `Attention` and `Last Action`
    texts the owner may see and what to do; the diagnostics actions
    (Test Connection, Connection Test with Target Bridge / Diagnostic
    Server, Connect / Disconnect Event Stream, Reload Credentials, Check
    CA Pinning) in one paragraph each, marked "normally not needed".
12. **Limits and what is not supported**, and a one-page **quick
    reference** of all actions with one line each.

Every action and every property of the three drivers must appear at least
once with its exact Composer name in bold. Field examples are written as
the reader would type or pick them, e.g. "Bridge IP Address: 192.168.1.50"
(use documentation addresses such as 192.168.1.50, never the house's).
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

## 6. Icon

A Hue Bridge Pro: a flat, dark (near-black) rounded rectangle seen from
above, a small lit indicator (the bridge's status LEDs) and a lighter edge,
drawn by `tools/make_icons.py` with Pillow at 16×16 and 32×32, 96 DPI
metadata, transparent corners, saved as PNG. No logos or trademarks are
drawn; the shape is the hint.

## 7. Verification

`luacheck src tests`, `busted tests` unchanged; `tools/build.sh` packs
`www/` (the manifest already includes every directory); `unzip -l` shows
`www/documentation.html`, `www/img/*.png`, `www/images/...`. Install
through the Windows session with "Add or Update Driver or Agent…" (owner's
word: "Go ahead and rev a new driver with the document when you are
done"); then read the Hue Bridge's **Documentation** tab: the page renders,
images show, the icon in the tree and list view changed. Results go into
`docs/design.md` (Composer UI section).
