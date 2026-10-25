# Screenshots of the manual without the house: the plan (issue #61)

The owner's manual (`src/hue_bridge/www/documentation.html`, pictures in
`src/hue_bridge/www/img/`) was illustrated on the house's own Composer
project, so its pictures carry the house: the Bridge Pro's id, the floor plan,
the light, scene, zone and room names, Composer device numbers, Hue resource
ids (`docs/licensing-research.md` §4, P3 to P6). There is no demo project. This
plan retakes every picture from the current build **in the house project** and
makes it publishable by two means only: the crop is the driver's own pane or
dialog, and every house-specific text inside it is over-painted with the
neutral example text of §3, in the font Composer itself drew it with, so the
manual looks real and shows nothing of the house.

**Status (2026-10-25):** written, not run. The tooling is
`tools/composer/Shots.ps1` (dot-sourced after `tools/composer/Composer.psm1`
on the Windows VM); the Windows session runs it (§7). The coordinator decides
the open points of §6 and fills in the transport of §8 before the first round.
Nothing here has been tried on the Windows VM yet: every Composer behaviour the
script relies on is either already used by `Composer.psm1` (finding elements,
pickers, list-view reads, safe clicks, captures) or marked as an assumption
in §5.

Scope: the 22 pictures the manual references today, plus the two that
chapter 7 lacks (`add-zone-light.png`, `zone-light-properties.png`). Their
first drafts exist only on the VM in `build/shots/img/` and show the street
address in Composer's title bar and the controller's address in its status
bar: they are never published, and they can be deleted once §4's versions
exist.

## 1. Rules (put them in every brief)

1. **Never the title bar or the status bar.** Composer's title bar carries the
   project name (the street address) and its status bar the controller's
   address; neither may be in any picture, nor the System Design tree (the
   house's inventory) or the Items pane. `Save-PaneShot` refuses a crop whose
   part on the main window touches the title bar, the status bar or the tree.
2. **Only the driver's own pane or dialog**: the tab control of a device
   (Properties or Actions tab), one property row, a property's dropped list,
   the Action Parameter List dialog with its Select picker, the Connections
   pane of a device, the Driver menu. Never the whole window.
3. **No change to the project.** The script selects devices, tabs and views,
   opens and cancels dialogs, drop-down lists and menus. Two steps go further
   and run only when the plan file allows them (§6): `EditValue` (typing into
   Stream Timeout so that Set and Cancel show, then Cancel, never Set) and
   `RunAction` (one click on Room Audit). Under the owner's standing approval
   the coordinator may allow both; the brief says which.
4. **Raw captures stay on the Windows VM.** `C:\c4-hue\shots\raw\` holds the
   unedited captures and the deny details (house data); only `doc\` is sent
   back. `hold\` holds finished pictures that still have a text nobody
   reviewed or a deny hit: fix the plan or the picture and run the row again.
5. **Placeholders only**, in the pictures, the ledgers and every report: the
   neutral set of §3 (bridge `001788fffe123abc`, address `10.0.2.143`, device
   numbers 1201 to 1206, light numbers #1 to #8). The house's device names are
   given to the script on the command line (`-Devices`), never written into
   the plan, and are turned back into their placeholders in its messages.
6. **The final check is a human-readable list of every text in each final
   PNG.** `Export-ShotTexts` writes it next to the picture (`<name>.txt`): what
   each text region shows now, the texts drawn outside UI Automation that the
   plan declares (tab headers, column headers), and with `-Ocr` what Windows'
   own text recognition reads. The session then looks at every PNG with its
   Read tool and confirms that every text it sees is on that list and none is
   the house's. A picture is done only after that look.
7. The rules of `docs/composer-remote.md` hold: stop on surprises (rule 3),
   clicks through `Invoke-SafeClick` and keys only into a verified control,
   never ALT (rule 5), window title and tree row count unchanged after every
   row (rule 6; `Invoke-ShotPlan` checks it).

## 2. What the script does with each picture

1. Runs the row's setup steps (select the device, the tab, open the action's
   dialog and picker, drop a list, open the menu).
2. Captures the crop with `Save-RegionShot` (screen copy; Composer in front)
   into `raw\`, keeps a 24-bit working copy.
3. Reads every text inside the crop: UI Automation names of the leaves, the
   rows of list views (every column, through the list-view messages
   `Composer.psm1` already uses), the rows of a dropped combo list (MSAA texts,
   list-box geometry), combo box faces, dialog titles; and marks which of them
   a dialog or list on top hides.
4. Decides each text: a list row gets the plan's item for that row (rows the
   neutral list does not need are blanked, or the picture is cut below them for
   a dropped list); a property or parameter value gets the plan's value for its
   row label; an exact text listed under `Texts` gets its replacement;
   everything else is kept only if the plan lists it as reviewed (`Keep`,
   `KeepPatterns`), otherwise it is *unreviewed* and the picture goes to
   `hold\`.
5. Paints: the old text is cleared with the background colour sampled under
   it, the new one is drawn in the font Composer used for it. That font is
   measured, not assumed: `C4.Shots.Match` draws the original string in Segoe
   UI, Microsoft Sans Serif and Tahoma, regular and bold, 7 to 11 pt, with GDI
   (TextRenderer, which is how WinForms and the native controls draw) and
   with GDI+ ClearTypeGridFit and AntiAliasGridFit, keeps the candidates whose
   ink box has the original's height (and width, unless the original is
   clipped), and picks the one closest to the captured pixels; the new text
   goes on the same baseline, left-aligned, clipped where Composer clips. A
   box without text of its own reuses the font measured on a box of the same
   kind. Scroll bars of a list that became short are painted over.
6. Checks every text the picture shows against the deny list (the house's
   names from the System Design tree, the project name, the status bar's
   addresses, every original it painted over, the names inside them) and
   against identifier patterns (any IPv4 address that is not a placeholder, a
   bridge id, a Hue resource id, a device number, a scene id or light number
   outside §3), and writes the PNG to `doc\` or `hold\` with its ledger.
7. Runs the row's teardown steps (Cancel the dialogs, Escape the list, close
   the menu, back to System Design), always, also after an error.

## 3. The neutral example set

One small fictitious home, used in every picture so that the pictures agree
with each other and with the counts on the bridge's Properties page. Every
text follows the exact format the driver writes (`src/hue_bridge/bridge/*.lua`,
`src/hue_light/driver.lua`, `src/hue_scene/driver.lua`); `→` is U+2192, `…`
U+2026, and `‚` (U+201A, a low quotation mark) stands for every comma in the
four list rows (Lights, Room Mappings, Scenes, Zone Lights), as the driver
writes them. Room words such as Kitchen and Living Room are common to most
homes and are used on purpose; none of the house's distinctive names is.

| What | Neutral value |
| --- | --- |
| Bridge | id `001788fffe123abc`, address `10.0.2.143`, stream spelling `10.000.002.143 (own queue, spelling 1 of 7)`, name `Hue Bridge Pro`, model `Hue Bridge Pro (BSB003)` (as read) |
| Control4 rooms (`Floor / Room`) | `Main Floor / Den`, `Main Floor / Kitchen`, `Main Floor / Living Room`, `Upper Floor / Bathroom`, `Upper Floor / Bedroom` |
| Hue rooms | `Bedroom`, `Garden`, `Kitchen`, `Living Room` |
| Hue zones | `Accent (zone)` (Lamp 1 and Lamp 2), `TV Area (zone)` (Lamp 2 and Lamp 7) |
| Room Mappings | `Bedroom → Bedroom`, `Garden → (unmapped)`, `Kitchen → Kitchen`, `Living Room → Living Room`, `Accent (zone) → Living Room`, `TV Area (zone) → (unmapped)`; summary `6 Hue rooms and zones; 2 unmapped (open the list to read)` |
| Lights | `Lamp 1 [Living Room] #1` (imported), `Lamp 2 [Living Room] #2`, `Lamp 3 [Kitchen] #3`, `Lamp 4 [Kitchen] #4`, `Lamp 5 [Bedroom] #5`, `Lamp 6 [Garden] #6`, `Lamp 7 #7` (in no Hue room), `Lamp 8 [Bedroom] #8 (deleted from Composer 2026-10-22)` |
| Light device | `Lamp 1`: Status `Lamp 1 (Hue color lamp)`, Hue Light ID `#1 (1a2b3c4d…)`, Hue Name `Lamp 1`, Model `Hue color lamp`, Online `Online`, Hue Room `Living Room`; bridge texts call it `device 1201` |
| Zone light | `Accent`: Status `Hue zone Accent (2 lights)`, Hue Light ID `zone #1 (5e6f7a8b…)`, Hue Name `Accent`, Model `Hue zone (2 lights)`, Online `Online`, Hue Room `Accent (zone)`; `device 1203` |
| Scene device | `Relax` of the Living Room: Status `Hue scene Relax in Living Room`, Hue Scene `Relax`, Hue Room `Living Room`, Hue Scene ID `#AbCdEfGhIjKlMnOp (0f3a2b1c…)` (the manual's own example), Recall As `As set in Hue`; `device 1205` |
| Scenes | Hue's seven default scenes in every room and zone (`Bright`, `Concentrate`, `Dimmed`, `Energize`, `Nightlight`, `Read`, `Relax`); the Bedroom also has `Sunset (dynamic)` and the time-of-day scene `Natural light (time-based)`, which plays Bright, Energize, Nightlight and Relax there |
| Bridge rows | Lights `8 on bridge‚ 1 imported‚ 6 new‚ 0 missing‚ 0 unbound‚ 1 deleted`; Scenes `43 + 1 time-based on bridge‚ 1 imported‚ 0 deleted`; Zone Lights `2 zones‚ 4 rooms on bridge; 1 imported`; Attention `6 new lights on the bridge: Lamp 2 [Living Room] #2, Lamp 3 [Kitchen] #3, Lamp 4 [Kitchen] #4 +3 more (Add Light or Import All New Lights)`; Last Action `All 1 linked light in a mapped Hue room is in the room its Hue room maps to` |
| Rename example | `Reading Lamp` (the Composer name) for `Lamp 1` (the Hue name) |
| Kept as read | Driver Version, Debug Mode, Bridge Model, Bridge Firmware, Event Stream while it reads `Connected since …`, Events Received, Last Event, the stream settings: generic, not the house's |

## 4. The shots

One row per picture: the 22 the manual references (`grep -o 'img/[^"]*'
src/hue_bridge/www/documentation.html`) and the two new ones for chapter 7.
"Open" is what the row's setup steps do; `{LIGHT}`, `{ZONE_LIGHT}` and `{SCENE}`
stand for house devices named on the command line (§7). "House now" is what the
picture would show of the house without this plan; "Neutral" what it shows after.
The crops are defined in §5.

| # | File (manual section) | Open | Crop | House now | Neutral |
| --- | --- | --- | --- | --- | --- |
| 1 | `add-driver-menu.png` (3, Adding the drivers) | Click the Driver menu (no ALT), rest the pointer on Add or Update Driver or Agent… | Menu | The current picture shows a cut-off row of the device tree under the menu and toolbar fragments beside it | Nothing to paint: the crop is the menu's own width, from the menu bar down |
| 2 | `set-button.png` (4, The Set button rule) | Hue Bridge ▸ Properties; type `3601` into Stream Timeout (s) (`EditValue`, §6 D3); shoot; Cancel | PropertyRow Stream Timeout (s) | Nothing | Nothing (`3601` is kept) |
| 3 | `bridge-properties.png` (4, after pairing) | Hue Bridge ▸ Actions ▸ Room Audit (optional, §6 D4) ▸ Properties | TabControl | Bridge IP Address, Bridge ID, the counts of Lights, Scenes, Zone Lights and Room Mappings, the names in Attention and Last Action, the address in Stream Address, Status if it quotes a test | §3 bridge rows; Status `Paired`; Last Action (2) to (6), if shown, hold the picture |
| 4 | `bridge-actions.png` (5) | Hue Bridge ▸ Actions | TabControl | Nothing | Nothing; a release build shows 22 buttons, Add Zone Light and Re-link Zone Light included |
| 5 | `room-mappings.png` (6, The Room Mappings property) | Hue Bridge ▸ Properties; drop the Room Mappings list | PropertyList Room Mappings | The house's Hue rooms and zones and Control4 room names, the summary's counts | §3 Room Mappings: the summary, then 6 lines; the picture is cut below them and the list's bottom border redrawn |
| 6 | `set-room-mapping.png` (6, Set Room Mapping) | Hue Bridge ▸ Actions ▸ Set Room Mapping ▸ … beside Hue Room | Dialog | Every Hue room and zone with its mapping | The 6 mapping lines; the other rows blanked, the scroll bars painted over |
| 7 | `set-room-mapping-room.png` (6) | The same dialog ▸ … beside Room | Dialog | The project's floors and rooms | `(no mapping)` and the 5 Control4 rooms |
| 8 | `room-audit.png` (6, Room Audit) | Hue Bridge ▸ Properties | PropertyRow Last Action | Whatever Last Action says now, often a house name | `All 1 linked light in a mapped Hue room is in the room its Hue room maps to` (staged, §6 D1) |
| 9 | `add-light.png` (7, Add Light) | Hue Bridge ▸ Actions ▸ Add Light ▸ … beside Light | Dialog | Every house light that has no device, with its room and number | The 7 unimported lights of §3; the other rows blanked, the scroll bars painted over |
| 10 | `add-light-room.png` (7) | The same dialog ▸ … beside Room | Dialog | The project's floors and rooms | `(mapped room)` and the 5 Control4 rooms |
| 11 | `add-zone-light.png` (7, Adding a zone or room as a light; new) | Hue Bridge ▸ Actions ▸ Add Zone Light ▸ … beside Group | Dialog | The house's zones and rooms with their light counts | `Accent (zone, 2 lights)`, `TV Area (zone, 2 lights)`, `Bedroom (room, 2 lights)`, `Garden (room, 1 light)`, `Kitchen (room, 2 lights)`, `Living Room (room, 2 lights)` |
| 12 | `zone-light-properties.png` (7, new) | `{ZONE_LIGHT}` ▸ Properties | TabControl | The zone's name (Status, Hue Name, Hue Room), its number and resource id (Hue Light ID), its light count | §3 zone light `Accent` |
| 13 | `attention.png` (8.2) | Hue Bridge ▸ Properties | PropertyRow Attention | Whatever Attention says now | `1 Hue name differs from the Composer names: Reading Lamp is Lamp 1 in Hue (Adopt Hue Names or Accept Names As They Are)`, clipped by the box as Composer clips it (staged, §6 D1) |
| 14 | `relink-device.png` (8.3) | Hue Bridge ▸ Actions ▸ Re-link Device To Light ▸ … beside Device | Dialog | Normally `(no gone or unbound devices)` | The same text; any other row blanked |
| 15 | `relink-device-light.png` (8.3) | The same dialog ▸ … beside Light | Dialog | As in 9 | As in 9 |
| 16 | `forget-light.png` (8.5) | Hue Bridge ▸ Actions ▸ Forget Light ▸ … beside Device | Dialog | The house's managed devices with their device numbers | `Lamp 1 #1 (device 1201)`, `Accent (zone light, device 1203)` |
| 17 | `connections.png` (8.6) | `{LIGHT}` selected, then the Connections view | Element `Control & Audio Video Connections` | The device's name above the list; the name of a keypad bound to a Button Link, if any | `Lamp 1`; any other name holds the picture |
| 18 | `add-scene.png` (9.2) | Hue Bridge ▸ Actions ▸ Add Scene ▸ … beside Scene | Dialog | The house's rooms, zones and scene names | 22 neutral entries (the Accent zone's seven, the Bedroom's nine with the time-based, `(in …)` and dynamic forms, the Garden's first six) fill the visible rows; the scroll bar stays, the neutral list being longer than the box |
| 19 | `add-all-scenes.png` (9.3) | Hue Bridge ▸ Actions ▸ Add All Scenes Of Room ▸ … beside Hue Room | Dialog | The house's rooms and zones with mappings and counts | `Accent (zone) → Living Room (7 scenes)`, `Bedroom → Bedroom (8 scenes, 1 time-based)`, `Garden → (unmapped) (7 scenes)`, `Kitchen → Kitchen (7 scenes)`, `Living Room → Living Room (7 scenes, 1 imported)`, `TV Area (zone) → (unmapped) (7 scenes)` |
| 20 | `scene-properties.png` (9.5) | `{SCENE}` ▸ Properties | TabControl | The scene's name, its room, its scene id | §3 scene device `Relax` |
| 21 | `recall-as.png` (9.5) | `{SCENE}` ▸ Properties; drop the Recall As list | PropertyList Recall As | Nothing | Nothing |
| 22 | `scene-actions.png` (9.6) | `{SCENE}` ▸ Actions | TabControl | Nothing | Nothing (Adopt Hue Name above Forget This Scene since build 130) |
| 23 | `light-properties.png` (10) | `{LIGHT}` ▸ Properties | TabControl | The values of whichever device stands in (§6 D2) | §3 light device `Lamp 1` |
| 24 | `light-actions.png` (10) | `{LIGHT}` ▸ Actions | TabControl | Nothing | Nothing |

Every row also keeps, as reviewed, the texts that are the same in every home:
property labels, action names, dialog titles, buttons, tab headers, menu items,
`Off`, `Online`, `Paired`, the Recall As choices and the like (the plan's
`Keep` and `KeepPatterns`). In the dialog rows the Action Parameter List's own
value fields, where a sliver of them shows beside the picker, are blanked:
they hold the choices Composer remembers from the last use.

## 5. Crops, steps and plan fields

**Crops** (`New-ShotFromCrop`):

| Kind | What is captured |
| --- | --- |
| `TabControl` | The device's tab control, tab headers and page (`Get-ComposerTabControl`; 778 x 772 at the window size of the old pictures). |
| `PropertyRow` | One row of the Properties page: label, value and the row's buttons, 6 px around (like `Save-PropertyRowShot`). |
| `PropertyList` | A row and its dropped list window, 6 px around. |
| `Dialog` | The Action Parameter List's visible frame (DWM extended frame bounds, without Windows' invisible resize borders), the Select picker inside it. The old pictures had 12 px of the main window around the dialog, with fragments of property labels; the new ones have none. A picker reaching outside the dialog holds the picture. |
| `Element` | The largest element with exactly that name. |
| `Menu` | The open menu's own width, from the top of the menu bar to the bottom of the menu. |

**Steps** (`Invoke-ShotStep`): `Device` (select in the System Design tree),
`Tab`, `Action` (expects the Action Parameter List), `Picker` (the … beside a
parameter), `DropList` / `CloseList` (a property's list; closed with Escape
sent only to that combo box, and a Set button left behind answered with
Cancel), `EditValue` / `CancelEdit` (needs `"AllowEditCancel": true`; Cancel
is checked to restore the old value), `RunAction` (needs `"AllowRunAction":
true`, or is skipped when the step says `"Optional": true`), `Menu` /
`CloseMenu` (a click on the title, a pointer rest for the highlight, a second
click on the title to close), `View` (the view buttons at the lower left),
`CancelDialogs` (Select, then Action Parameter List; any other dialog stops
the run), `Wait`.

**Plan fields.** Root: `Root`, `AllowEditCancel`, `AllowRunAction`, `Keep`
(exact texts reviewed as safe), `KeepPatterns` (regular expressions),
`NeutralWords`, `Shots`. Row: `Name`, `Setup`, `Crop`, `Values` (row label →
neutral text, or `@keep`, `@blank`, `@hold`), `Items` (list rows in order),
`Rest` (`Blank`, default, or `Truncate` for a dropped list), `ClearScrollbars`,
`Texts` (exact original → neutral text; keys may be `{PLACEHOLDERS}`), `Keep`,
`KeepPatterns`, `Static` (texts drawn outside UI Automation, listed in the
ledger), `Teardown`, `Skip` (a reason; the row is not run).

**Assumptions** (not yet seen on the Windows VM; each failure ends in an error
or a held picture, never in a published one):

- A1. The Driver menu is a native menu: UI Automation shows the menu bar's
  items, the open menu is a top-level window of Composer's process (class
  `#32768` or control type Menu), and resting the pointer on an item
  highlights it.
- A2. `GetComboBoxInfo`, `GetScrollBarInfo` and the list-box messages
  `LB_GETCOUNT`, `LB_GETTOPINDEX`, `LB_GETITEMHEIGHT` work across processes on
  Composer's controls (they carry no pointers); `LVM_GETITEMRECT` with
  `LVIR_LABEL` and `LVM_GETSUBITEMRECT` work through remote memory as
  `Composer.psm1`'s item rectangles do.
- A3. The Connections view keeps the device selected in System Design, its
  upper pane is an element named `Control & Audio Video Connections`, and the
  device's name above its list is a leaf text. If the name is not found, or is
  drawn by a container, the row holds with a note saying so, and the session
  selects the device or paints the name by hand (§7).
- A4. TextRenderer on this machine draws the same glyphs Composer's controls
  draw; the ledger gives each painted text's font and match score. A score
  above about 20 (mean R+G+B difference per pixel) deserves a close look.
- A5. On light and scene devices the light_v2 proxy's settings sit above the
  driver's tab control (`docs/design.md`, issue #59); the crop is the tab
  control only.
- A6. `Windows.Media.Ocr` is available for the `-Ocr` cross-check; without it
  the ledger says so and the visual check alone stands.

## 6. Decisions for the coordinator

- **D1. Staged texts.** `room-audit.png` and `attention.png` show a moment
  the house cannot produce without changing the project (no Hue Light device
  exists, so Room Audit cannot report a checked light; a rename would be a
  project change). The plan paints the driver's exact wording for that
  moment, with neutral names, into the real row. The same holds for the
  bridge's Attention and Last Action rows in `bridge-properties.png`.
  Alternative for `room-audit.png` only: keep the current file, which is clean
  but shows the older wording its caption apologises for. `attention.png` has
  no clean alternative.
- **D2. A stand-in for the Hue Light device.** The house has had no Hue Light
  device since 2026-10-22. A zone light is a Hue Light device (same driver,
  same rows, same two actions, same connections), so `{LIGHT}` is the zone
  light and the plan paints a single lamp's values into it
  (`light-properties.png`, `light-actions.png`, `connections.png`). The
  alternative, re-adding one light with Add Light, is a project change that
  also leaves a device to delete and a deletion to remember; not planned.
- **D3. `set-button.png`** needs `"AllowEditCancel": true` (typing into Stream
  Timeout, then Cancel; Director receives nothing without Set). Otherwise keep
  the current file, which is clean.
- **D4. `bridge-properties.png`.** If Last Action currently runs over onto
  its continuation rows (2) to (6), those rows hold the picture. With
  `"AllowRunAction": true` the row first clicks Room Audit, which changes
  nothing in the project and leaves a one-line Last Action.
- **D5. The transport back** (§8).
- **D6. The manual's own texts** (§9): who aligns the captions and the
  examples with the new pictures.
- **D7. Which build is shown.** The round runs on whatever production build
  the house has; Driver Version, Bridge Firmware and the stream rows are kept
  as read. If the pictures should show the build of the release they ship in,
  run the round after that build is installed.

## 7. How to run (the Windows session)

1. Get the files onto the Windows VM the way builds travel (§8):
   `tools/composer/Composer.psm1` and `tools/composer/Shots.ps1` into
   `C:\c4-hue\`, and the plan of §10 as `C:\c4-hue\shots\plan.json` (or this
   file, then `Export-ShotPlanFromDoc`).
2. Composer Pro on the house project, System Design view, Composer at its
   usual size and in front, no dialog open, the rooms that hold the Hue
   Bridge, the zone light and the scene device expanded in the tree (expand
   them all: `Get-HouseTerms` reads the house's names from the rows it can
   see). Nothing in this round changes the project, so no backup is needed
   for it.
3. In Windows PowerShell 5.1 (not elevated):

   ```powershell
   Import-Module C:\c4-hue\Composer.psm1 -Force
   . C:\c4-hue\Shots.ps1
   Initialize-Shots -Root C:\c4-hue\shots
   # Export-ShotPlanFromDoc -Markdown C:\c4-hue\screenshots-plan.md -Out C:\c4-hue\shots\plan.json
   Get-HouseTerms        # house names from the tree, title and status bar; memory only
   $dev = @{ ZONE_LIGHT = '<the zone light device>'; LIGHT = '<the zone light device, D2>'; SCENE = '<an ordinary (not time-based) scene device>' }
   $sum = Invoke-ShotPlan -Path C:\c4-hue\shots\plan.json -Devices $dev -Ocr
   ```

   One row again: `-Only 'add-light.png'`. The plan stops at the first
   "stop and report" (an unexpected dialog, a list or menu that will not
   close, a changed window title or tree): report it, do not improvise.
4. Look at every PNG in `doc\` and `hold\` with Read, next to its `.txt`.
   Every text visible in the picture must be on the list, and none may be the
   house's. Look especially at the edges of the crop and at anything the
   ledger calls `[static]` or did not list at all.
5. A picture in `hold\` says why in its `.txt` (`HOLD:` lines; the house terms
   behind a deny hit are only in `raw\<name>.deny.txt`). Generic texts the plan
   did not know are added to the local plan's `Keep` and the row is run again.
   Something drawn outside UI Automation, or by a container, is painted by
   hand, the rest of the row as the plan says:

   ```powershell
   $plan = (Get-Content -Raw -Encoding UTF8 C:\c4-hue\shots\plan.json) | ConvertFrom-Json
   $row  = $plan.Shots | Where-Object Name -eq 'connections.png'
   foreach ($s in $row.Setup) { Invoke-ShotStep -Step $s -Plan $plan -Devices $dev }
   $shot = New-ShotFromCrop -Row $row; [void](Get-TextRegions -Shot $shot)
   Resolve-ShotRow -Shot $shot -Row $row -Plan $plan -Devices $dev
   Get-ShotRegionTable -Shot $shot -Originals | Format-Table      # originals on this screen only
   # the region (its index from the table) and the rectangle its text really occupies, in picture pixels
   Set-TextReplacement -Shot $shot -Region $shot.Regions[7] -Rect (New-ShotRect 4 26 160 18) -Text 'Lamp 1'
   # a generic text the plan did not know: $shot.Regions[n].Decision = 'Kept'
   $shot.Problems.Clear()                                         # once every listed problem is dealt with
   Save-ShotResult -Shot $shot; Export-ShotTexts -Shot $shot -Ocr
   foreach ($s in $row.Teardown) { Invoke-ShotStep -Step $s -Plan $plan -Devices $dev }
   ```

6. Report to the coordinator: the summary table, every `.txt` ledger from
   `doc\` and the reasons of anything left in `hold\`. Ledgers carry only what
   the pictures show; never paste an original, a device name from `-Devices`
   or anything from `raw\`.

## 8. How the pictures come back (transport: the coordinator fills this in)

The route of round 12 still exists and is the likely one:
`python3 -I tools/collect.py --dir build/collect` on this VM (port 8090,
`PUT /<folder>/<name>`), and on the Windows VM `Send-DocShot -Name <file>
-Server http://<this VM>:8090` from `Composer.psm1` for each PNG in
`C:\c4-hue\shots\doc\`, plus the ledgers with `Invoke-WebRequest -Method Put
-InFile C:\c4-hue\shots\doc\<name>.txt -Uri http://<this VM>:8090/txt/<name>.txt
-UseBasicParsing`. Only `doc\` is sent; never `raw\` or `hold\`.

- [ ] Coordinator: confirm the route, the address and the port for this round
  (or name another), start the receiver, and stop it afterwards.
- [ ] Coordinator: look at every received picture and ledger before anything
  is copied into `src/hue_bridge/www/img/`.

## 9. Follow-ups once the pictures are in

- **Captions** written around the old pictures go stale:
  `bridge-properties.png` (an early development build with Dev Server rows and
  no Zone Lights row), `bridge-actions.png` (23 buttons on a development
  build), `room-audit.png` (the older wording), `forget-light.png` (before zone
  lights), `connections.png` (before the keypad's Button Links),
  `light-properties.png` (before the keypad settings), `scene-actions.png`
  (the older order), `add-scene.png` (before time-of-day scenes); and the
  captions of `scene-properties.png` and `light-properties.png` name the
  devices of the old pictures, which are the house's.
- **Examples in the manual's text** come from the house too: light, zone, room
  and scene names in chapters 4 to 10, and in chapters 7 and 10 the Hue Light
  ID examples carry the resource-id prefixes of the house's own zone and lamp.
  Aligning them with §3 makes text and pictures agree (writer agent).
- **Image widths**: the manual's `width` attributes were set for the old
  sizes; the dialogs are now about 24 px narrower and the menu is its own
  width.
- **Chapter 7**: `add-zone-light.png` after the Group and Room list,
  `zone-light-properties.png` after "Names and properties".
- `docs/licensing-research.md` §4 P3 to P6 marked done; `docs/status.md`'s open
  line about chapter 7; issue #61 closed with the pull request and the build.
- The two drafts in `build/shots/img/` on the VM deleted.

## 10. The plan file

`Invoke-ShotPlan` reads this block as `C:\c4-hue\shots\plan.json`
(`Export-ShotPlanFromDoc -Markdown <this file> -Out C:\c4-hue\shots\plan.json`
writes it). Non-ASCII characters are JSON escapes (`\u2192` →, `\u201a` ‚,
`\u2026` …) so that the file survives any copy. The two `Allow…` switches stay
`false` until the coordinator decides D3 and D4; the house's device names are
not in it and never go into it (`-Devices`, §7). A session that adds generic
texts to `Keep` on its side reports them so that they can be added here.

<!-- shot-plan -->
```json
{
 "Root": "C:\\c4-hue\\shots",
 "AllowEditCancel": false,
 "AllowRunAction": false,
 "NeutralWords": ["deleted from Composer 2026-10-22", "zone light", "room light", "time-based", "dynamic", "imported", "unmapped", "Hue color lamp", "Hue zone"],
 "Keep": [
  "Driver Version", "Debug Mode", "Status", "Bridge IP Address", "Bridge ID", "Bridge Model", "Bridge Name",
  "Bridge Firmware", "Event Stream", "Lights", "Attention", "Last Action", "Last Action (2)",
  "Last Action (3)", "Last Action (4)", "Last Action (5)", "Last Action (6)", "Room Mappings", "Scenes",
  "Zone Lights", "Stream Address", "Events Received", "Last Event", "Stream Timeout (s)",
  "Stream Watchdog (s)", "Hue Light ID", "Hue Name", "Model", "Online", "Hue Room", "Hue Scene",
  "Hue Scene ID", "Recall As", "Pair Bridge", "Add Light", "Import All New Lights", "Add Zone Light",
  "Re-link Device To Light", "Re-link Zone Light", "Link Devices", "Forget Light", "Adopt Hue Names",
  "Accept Names As They Are", "Set Room Mapping", "Map Rooms By Name", "Room Audit", "Add Scene",
  "Add All Scenes Of Room", "Re-link Scene", "Forget Scene", "Refresh Scenes", "Test Connection",
  "Connect Event Stream", "Disconnect Event Stream", "Forget Pairing", "Adopt Hue Name", "Forget This Light",
  "Forget This Scene", "Action Parameter List", "Select", "OK", "Cancel", "...", "Set", "Light", "Room",
  "Group", "Device", "Scene", "Properties", "Actions", "Documentation", "Lua", "Advanced Properties", "Off",
  "On", "Offline", "Paired", "None", "As set in Hue", "Static", "Dynamic", "Hue Bridge Pro (BSB003)",
  "Hue Bridge v2, square (BSB002)", "(no gone or unbound devices)", "(mapped room)", "(no mapping)",
  "Hue Bridge", "Control", "HUE_BRIDGE", "BUTTON_LINK", "Input", "Output", "Hue Bridge->Hue Lights",
  "Hue Lights", "Top Button Link", "Bottom Button Link", "Toggle Button Link",
  "Control & Audio Video Connections", "Control Inputs", "Control Outputs", "Name", "Type", "Connection",
  "Input/Output", "Connected To", "Application", "File", "Driver", "Go", "Tools", "Help", "Create New Driver",
  "Copy Existing Driver", "Edit Existing Driver", "Add or Update Driver or Agent",
  "Add or Update Driver or Agent...", "Manage Drivers and Agents"
 ],
 "KeepPatterns": [
  "^\\d{1,6}$",
  "^\\d{1,2}:\\d{2}:\\d{2}$",
  "^Connected since \\d{1,2}:\\d{2}:\\d{2}[0-9a-z ,;:()-]*$",
  "^\\d{10} \\(API \\d+\\.\\d+\\.\\d+\\)$",
  "^Manage Drivers and Agents\\s+Ctrl\\+M$",
  "^Add or Update Driver or Agent(\\.\\.\\.|\u2026)?$"
 ],
 "Shots": [
  {
   "Name": "add-driver-menu.png",
   "Setup": [{"Do": "Menu", "Name": "Driver", "Hover": "Add or Update Driver or Agent*"}],
   "Crop": {"Kind": "Menu", "Menu": "Driver"},
   "Teardown": [{"Do": "CloseMenu", "Name": "Driver"}]
  },
  {
   "Name": "set-button.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Properties"}, {"Do": "EditValue", "Label": "Stream Timeout (s)", "Text": "3601"}],
   "Crop": {"Kind": "PropertyRow", "Label": "Stream Timeout (s)"},
   "Values": {
    "Stream Timeout (s)": "@keep"
   },
   "Teardown": [{"Do": "CancelEdit", "Label": "Stream Timeout (s)"}]
  },
  {
   "Name": "bridge-properties.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "RunAction", "Name": "Room Audit", "Optional": true, "WaitMs": 3000}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "TabControl"},
   "Values": {
    "Status": "Paired",
    "Bridge IP Address": "10.0.2.143",
    "Bridge ID": "001788fffe123abc",
    "Bridge Name": "Hue Bridge Pro",
    "Lights": "8 on bridge\u201a 1 imported\u201a 6 new\u201a 0 missing\u201a 0 unbound\u201a 1 deleted",
    "Attention": "6 new lights on the bridge: Lamp 2 [Living Room] #2, Lamp 3 [Kitchen] #3, Lamp 4 [Kitchen] #4 +3 more (Add Light or Import All New Lights)",
    "Last Action": "All 1 linked light in a mapped Hue room is in the room its Hue room maps to",
    "Last Action (2)": "@hold",
    "Last Action (3)": "@hold",
    "Last Action (4)": "@hold",
    "Last Action (5)": "@hold",
    "Last Action (6)": "@hold",
    "Room Mappings": "6 Hue rooms and zones; 2 unmapped (open the list to read)",
    "Scenes": "43 + 1 time-based on bridge\u201a 1 imported\u201a 0 deleted",
    "Zone Lights": "2 zones\u201a 4 rooms on bridge; 1 imported",
    "Stream Address": "10.000.002.143 (own queue, spelling 1 of 7)"
   },
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "bridge-actions.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}],
   "Crop": {"Kind": "TabControl"},
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "room-mappings.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Properties"}, {"Do": "DropList", "Label": "Room Mappings"}],
   "Crop": {"Kind": "PropertyList", "Label": "Room Mappings"},
   "Values": {
    "Room Mappings": "6 Hue rooms and zones; 2 unmapped (open the list to read)",
    "Scenes": "@blank",
    "Zone Lights": "@blank",
    "Stream Address": "@blank",
    "Events Received": "@blank",
    "Last Event": "@blank",
    "Stream Timeout (s)": "@blank",
    "Stream Watchdog (s)": "@blank"
   },
   "Items": [
    "6 Hue rooms and zones; 2 unmapped (open the list to read)",
    "Bedroom \u2192 Bedroom",
    "Garden \u2192 (unmapped)",
    "Kitchen \u2192 Kitchen",
    "Living Room \u2192 Living Room",
    "Accent (zone) \u2192 Living Room",
    "TV Area (zone) \u2192 (unmapped)"
   ],
   "Rest": "Truncate",
   "Teardown": [{"Do": "CloseList", "Label": "Room Mappings"}]
  },
  {
   "Name": "set-room-mapping.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Set Room Mapping"}, {"Do": "Picker", "Label": "Hue Room"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Hue Room": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "Bedroom \u2192 Bedroom",
    "Garden \u2192 (unmapped)",
    "Kitchen \u2192 Kitchen",
    "Living Room \u2192 Living Room",
    "Accent (zone) \u2192 Living Room",
    "TV Area (zone) \u2192 (unmapped)"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "set-room-mapping-room.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Set Room Mapping"}, {"Do": "Picker", "Label": "Room"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Hue Room": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "(no mapping)",
    "Main Floor / Den",
    "Main Floor / Kitchen",
    "Main Floor / Living Room",
    "Upper Floor / Bathroom",
    "Upper Floor / Bedroom"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "room-audit.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "PropertyRow", "Label": "Last Action"},
   "Values": {
    "Last Action": "All 1 linked light in a mapped Hue room is in the room its Hue room maps to"
   }
  },
  {
   "Name": "add-light.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Add Light"}, {"Do": "Picker", "Label": "Light"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Light": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "Lamp 2 [Living Room] #2",
    "Lamp 3 [Kitchen] #3",
    "Lamp 4 [Kitchen] #4",
    "Lamp 5 [Bedroom] #5",
    "Lamp 6 [Garden] #6",
    "Lamp 7 #7",
    "Lamp 8 [Bedroom] #8 (deleted from Composer 2026-10-22)"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "add-light-room.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Add Light"}, {"Do": "Picker", "Label": "Room"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Light": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "(mapped room)",
    "Main Floor / Den",
    "Main Floor / Kitchen",
    "Main Floor / Living Room",
    "Upper Floor / Bathroom",
    "Upper Floor / Bedroom"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "add-zone-light.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Add Zone Light"}, {"Do": "Picker", "Label": "Group"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Group": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "Accent (zone, 2 lights)",
    "TV Area (zone, 2 lights)",
    "Bedroom (room, 2 lights)",
    "Garden (room, 1 light)",
    "Kitchen (room, 2 lights)",
    "Living Room (room, 2 lights)"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "zone-light-properties.png",
   "Setup": [{"Do": "Device", "Name": "{ZONE_LIGHT}"}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "TabControl"},
   "Values": {
    "Status": "Hue zone Accent (2 lights)",
    "Hue Light ID": "zone #1 (5e6f7a8b\u2026)",
    "Hue Name": "Accent",
    "Model": "Hue zone (2 lights)",
    "Hue Room": "Accent (zone)",
    "Last Action": "@blank"
   },
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "attention.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "PropertyRow", "Label": "Attention"},
   "Values": {
    "Attention": "1 Hue name differs from the Composer names: Reading Lamp is Lamp 1 in Hue (Adopt Hue Names or Accept Names As They Are)"
   }
  },
  {
   "Name": "relink-device.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Re-link Device To Light"}, {"Do": "Picker", "Label": "Device"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Device": "@blank",
    "Light": "@blank"
   },
   "Items": ["(no gone or unbound devices)"],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "relink-device-light.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Re-link Device To Light"}, {"Do": "Picker", "Label": "Light"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Device": "@blank",
    "Light": "@blank"
   },
   "Items": [
    "Lamp 2 [Living Room] #2",
    "Lamp 3 [Kitchen] #3",
    "Lamp 4 [Kitchen] #4",
    "Lamp 5 [Bedroom] #5",
    "Lamp 6 [Garden] #6",
    "Lamp 7 #7",
    "Lamp 8 [Bedroom] #8 (deleted from Composer 2026-10-22)"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "forget-light.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Forget Light"}, {"Do": "Picker", "Label": "Device"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Device": "@blank"
   },
   "Items": ["Lamp 1 #1 (device 1201)", "Accent (zone light, device 1203)"],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "connections.png",
   "Setup": [{"Do": "Device", "Name": "{LIGHT}"}, {"Do": "View", "Name": "Connections"}],
   "Crop": {"Kind": "Element", "Name": "Control & Audio Video Connections"},
   "Texts": {
    "{LIGHT}": "Lamp 1"
   },
   "Static": ["Control & Audio Video Connections", "Name", "Type", "Connection", "Input/Output", "Connected To", "Control Inputs", "Control Outputs"],
   "Teardown": [{"Do": "View", "Name": "System Design"}]
  },
  {
   "Name": "add-scene.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Add Scene"}, {"Do": "Picker", "Label": "Scene"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Scene": "@blank",
    "Room": "@blank"
   },
   "Items": [
    "Accent (zone): Bright",
    "Accent (zone): Concentrate",
    "Accent (zone): Dimmed",
    "Accent (zone): Energize",
    "Accent (zone): Nightlight",
    "Accent (zone): Read",
    "Accent (zone): Relax",
    "Bedroom: Natural light (time-based)",
    "Bedroom: Bright (in Natural light)",
    "Bedroom: Concentrate",
    "Bedroom: Dimmed",
    "Bedroom: Energize (in Natural light)",
    "Bedroom: Nightlight (in Natural light)",
    "Bedroom: Read",
    "Bedroom: Relax (in Natural light)",
    "Bedroom: Sunset (dynamic)",
    "Garden: Bright",
    "Garden: Concentrate",
    "Garden: Dimmed",
    "Garden: Energize",
    "Garden: Nightlight",
    "Garden: Read"
   ],
   "ClearScrollbars": false,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "add-all-scenes.png",
   "Setup": [{"Do": "Device", "Name": "Hue Bridge"}, {"Do": "Tab", "Name": "Actions"}, {"Do": "Action", "Name": "Add All Scenes Of Room"}, {"Do": "Picker", "Label": "Hue Room"}],
   "Crop": {"Kind": "Dialog"},
   "Values": {
    "Hue Room": "@blank"
   },
   "Items": [
    "Accent (zone) \u2192 Living Room (7 scenes)",
    "Bedroom \u2192 Bedroom (8 scenes, 1 time-based)",
    "Garden \u2192 (unmapped) (7 scenes)",
    "Kitchen \u2192 Kitchen (7 scenes)",
    "Living Room \u2192 Living Room (7 scenes, 1 imported)",
    "TV Area (zone) \u2192 (unmapped) (7 scenes)"
   ],
   "ClearScrollbars": true,
   "Teardown": [{"Do": "CancelDialogs"}]
  },
  {
   "Name": "scene-properties.png",
   "Setup": [{"Do": "Device", "Name": "{SCENE}"}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "TabControl"},
   "Values": {
    "Status": "Hue scene Relax in Living Room",
    "Hue Scene": "Relax",
    "Hue Room": "Living Room",
    "Hue Scene ID": "#AbCdEfGhIjKlMnOp (0f3a2b1c\u2026)",
    "Last Action": "@blank"
   },
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "recall-as.png",
   "Setup": [{"Do": "Device", "Name": "{SCENE}"}, {"Do": "Tab", "Name": "Properties"}, {"Do": "DropList", "Label": "Recall As"}],
   "Crop": {"Kind": "PropertyList", "Label": "Recall As"},
   "Values": {
    "Online": "@keep",
    "Last Action": "@blank"
   },
   "Teardown": [{"Do": "CloseList", "Label": "Recall As"}]
  },
  {
   "Name": "scene-actions.png",
   "Setup": [{"Do": "Device", "Name": "{SCENE}"}, {"Do": "Tab", "Name": "Actions"}],
   "Crop": {"Kind": "TabControl"},
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "light-properties.png",
   "Setup": [{"Do": "Device", "Name": "{LIGHT}"}, {"Do": "Tab", "Name": "Properties"}],
   "Crop": {"Kind": "TabControl"},
   "Values": {
    "Status": "Lamp 1 (Hue color lamp)",
    "Hue Light ID": "#1 (1a2b3c4d\u2026)",
    "Hue Name": "Lamp 1",
    "Model": "Hue color lamp",
    "Hue Room": "Living Room",
    "Last Action": "@blank"
   },
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  },
  {
   "Name": "light-actions.png",
   "Setup": [{"Do": "Device", "Name": "{LIGHT}"}, {"Do": "Tab", "Name": "Actions"}],
   "Crop": {"Kind": "TabControl"},
   "Static": ["Properties", "Actions", "Documentation", "Lua"]
  }
 ]
}
```
