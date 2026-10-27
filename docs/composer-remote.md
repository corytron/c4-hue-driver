# Driving Composer Pro from here: the Windows session

The dev loop (`docs/dev-loop.md`) lets the coordinator change and exercise
the drivers on the live controller, but everything that happens *in
Composer Pro* — driver updates, the Actions tab, dialogs, renaming or
deleting devices, what a Navigator tile looks like — used to need the
owner's hands. The second layer removes that: a Claude Code session
running inside the Claude desktop app **on the Windows VM** acts as the
coordinator's hands in Composer, driven by messages from the coordinator's
session.

**Current state (2026-10-25):** in use since 2026-10-21; round 43 (2026-10-25
03:24, dev build 309 for the checks of issue #40) is the last one recorded
(history at the end; `docs/status.md`). A release install follows
`docs/release-checklist.md`, "Deploy to the house": `tools/deploy.py start`
writes the brief the session works from ("Workflow" below). While a dev
build runs, the dev loop's shipped log is the coordinator's view
(`docs/dev-loop.md`); with a release build, Composer is where results are
read (rule 13).

## How it is wired

```
coordinator session (Ubuntu VM, this repo)   --SendMessage over Remote Control-->   "Composer" session (Windows VM)
   reads the shipped driver log, dev loop                                            PowerShell + Windows UI Automation
   decides the steps, interprets results         <--  report (texts, screenshots) --   Composer Pro 3.4.2, WinForms
```

- Both sessions belong to the owner's account and have **Remote Control**
  switched on; they then see each other in `ListAgents` as peer sessions
  and talk with `SendMessage`. The Windows side may hold an incoming
  message for the owner's approval, depending on its permission mode.
- The Windows session has no computer-use tools. It works through
  **PowerShell 5.1** (UI Automation: `UIAutomationClient` /
  `UIAutomationTypes` to read; to act, since Composer offers no patterns,
  mouse input through `SetCursorPos` and `mouse_event` via P/Invoke and
  keys through `SendKeys`), Git Bash, and a `Read` tool that renders PNG
  files it saved.
  No Python is installed on the VM and none is needed.
- Composer Pro is a WinForms application
  (`WindowsForms10.Window.8.app…`): its controls are exposed to UI
  Automation. Every element reports `ControlType.Pane`, but `Name` and
  `ClassName` (`EDIT`, `STATIC`, `BUTTON`, `COMBOBOX`) are meaningful, and a
  driver's Properties page is a sequence of label/value pairs — the
  coordinator can read `Attention`, `Room Mappings`, `Last Action` and the
  rest verbatim, without screenshots **[verified 2026-10-21]**.
- Screenshots: `System.Drawing` `CopyFromScreen` after bringing Composer
  to the foreground (`SetForegroundWindow`), or `PrintWindow` with
  `PW_RENDERFULLCONTENT` for an occluded window; the Claude desktop app
  itself usually covers Composer on that screen.
- The Windows VM runs under KVM on the owner's NAS, on the same LAN as the
  controller and this VM; it can reach the dev server's port and port 8090
  here (dev and test builds to install, screenshots to upload). Release
  packages come from the GitHub release URLs instead.

## Rules for the Windows session

Written into every brief; the session is a teammate acting on the owner's
behalf, not the owner.

1. **Read first, click second.** Reading properties, listing actions,
   opening a dialog to inspect its pickers and cancelling it, taking
   screenshots: always allowed.
2. **Hard-to-undo steps are named in the brief**: deleting a device,
   Update Driver, Connections and Programming changes, Load/Save project,
   OK in a dialog that creates or changes a device. They are covered by
   the owner's standing approval (rule 8); the brief names them so the
   session knows what it is about to change.
3. **Stop on surprises**: any unexpected dialog, error or prompt ends the
   round with a report, not a guess.
4. **Report exact texts** (UIA Names, property values) and keep screenshots
   under `C:\c4-hue\shots\`.
5. **Keystrokes and clicks only into a verified target.** Before any key
   is sent, the focused control must have been checked (the tree's
   in-place editor, a dialog button, a text field) and no menu may be
   active; never tap ALT to gain foreground rights (use
   `AttachThreadInput` with `SetForegroundWindow`, or a click). Prefer window messages
   (`WM_SETTEXT`) and rectangle clicks over typing; re-check
   `Get-ComposerDialog` before every Enter and Cancel anything unexpected.
   **Every click** goes through `Invoke-SafeClick`, which refuses unless
   the intended top-level window is in the foreground and contains the
   point (round 18c). Since 2026-10-25 (#239) that holds for every helper
   of the module too: `Invoke-ElementClick` and the tab, tree, picker,
   rename and property clicks go through `Invoke-SafeClick` with their
   target's top-level window (`Get-ComposerRootWindow`), and
   `Invoke-MouseDrag` checks both points first (`Assert-SafePoint`) and
   releases at the start point if the window loses the foreground
   mid-drag. `Invoke-MouseClick` is called from `Invoke-SafeClick` alone.
   Learned the hard way on 2026-10-21: an ALT tap left
   Composer's File menu in keyboard mode and the Enter meant for the rename
   editor opened **File ▸ Clear Project**'s confirmation; the session
   cancelled it and nothing was lost, but the project must be backed up
   before any round that changes it.
6. **After every step** confirm the window title (project name) and the
   System Design row count are unchanged unless the step meant to change
   them.
7. **A property edit is not done until the row's Set button is clicked.**
   Composer shows the new value at once but sends nothing to Director until
   Set (which appears with Cancel beside the changed value); every earlier
   "the driver ignored my change" was this. `Set-ComposerProperty` does it.
8. **Standing approval (2026-10-24).** Cory: "i approve everything all the
   time everytime". Every coordinator brief is approved: installs,
   "Restart Director?", Composer changes, deletes, Refresh Navigators,
   project actions the brief names. The session does not ask him again on
   its side. (Until then it had asked him per round, which once stalled an
   install he had already requested.) The safety rules that are not
   approvals stay: stop on surprises (rule 3), the click and focus checks,
   no ALT, never elevate.
9. **System Manager is out of reach.** `Sysman.exe` needs administrator
   rights and the non-elevated session's input cannot reach it, so a
   controller reboot is the owner's, by hand. Never elevate or work
   around it.
10. **Capability changes need a controller reboot.** Composer has no
    Director restart command. A build that changes `<capabilities>`
    (`has_leds`, hold rates, `dimmer`, `hide_proxy_properties`) makes
    Composer ask "Restart Director?", once per driver whose capabilities
    changed; Yes does **not** restart Director, the devices keep the old
    capabilities and code until the owner reboots the controller, and a
    per-device Update Driver ("Versions are equal", overwrite) does not
    help while Director's copy is stale. Builds that change only Lua or
    connections take effect at once (build 146's Button Link connections
    reached an existing device with no restart, `docs/keypad-design.md`).
11. **Overlays are not dialogs.** Composer's permanent "GlassPanelForm"
    overlay and the device tooltips ("Device ID:" / "Proxy ID:") are never
    answered or closed.
12. **Re-orient after every Update Driver.** Composer reloads the project
    view (selection lost, panes recreated) and may leave the centre pane in
    List View, which hides the Properties tab: re-select the device and
    click the Properties header before reading.
13. **The Lua Output pane shows only live lines**, those arriving while
    that device's Lua tab is open; startup logs cannot be captured from
    Composer.
14. **Set every action parameter explicitly.** The Action Parameter List
    dialog remembers each action's last values; "(mapped room)" is
    pickable since build 125.
15. **Through a controller reboot** a background logger records the status
    bar and any dialogs; after the reconnect Composer comes back on the
    project root, so devices are re-selected before anything is read.
16. **To find a stale driver copy**, compare the downloaded `.c4z`,
    Composer's driver store (`Documents\Control4\Drivers`) and the device's
    `Driver Version`.
17. **Never turn the mouse wheel over a property page.** It steps the
    drop-down under the pointer: on 2026-10-27 (#312) it moved Engraving
    Size on the project root's Lighting Defaults from Standard to Large
    (set back afterwards). Scroll with clicks on the scrollbar only.
18. **Check every drag twice.** Mid-drag, `GetGUIThreadInfo` must report
    a capture window and the drop or no-drop cursor, or the release drops
    nothing; afterwards the Connections lists, or a Script's Copy All
    (XML), must show the binding or the line where it was meant to go
    ("Learned 2026-10-27" below).

## The helper module

`tools/composer/Composer.psm1` is the PowerShell module the Windows
session grows as it works (it develops and tests it there, then sends it
back for the repo). The repo copy was last refreshed from the session's
own file on 2026-10-25 (#239: every click checked), and holds 58 functions; it is
not run on this VM, but CI's `powershell` check runs PSScriptAnalyzer over
it and `Shots.ps1` (`tools/check.sh`). Composer exposes no UIA patterns,
so the module reads through UIA and acts through real mouse and keyboard
input at the reported rectangles.

| Purpose | Functions |
| --- | --- |
| Window, focus, input | `Get-ComposerProcess`, `Get-ComposerMainHandle`, `Get-ComposerWindow`, `Get-ComposerTopWindows`, `Show-Composer`, `Show-AnyWindow` (foreground without ALT), `Get-ComposerFocus`, `Invoke-SafeClick` (rule 5), `Assert-SafePoint`, `Get-ComposerRootWindow`, `Invoke-MouseClick` (from `Invoke-SafeClick` only), `Invoke-MouseDrag` (both points checked), `Move-MouseAway`, `Invoke-ElementClick`, `Send-Keys`, `Send-KeysTo` (keys only into the expected window) |
| Reading | `Find-ComposerElements`, `Get-ComposerElementInfo`, `Get-ComposerTree`, `Get-ComposerProperties`, `Get-ComposerProperty`, `Get-ComposerBridgeStatus`, `Format-BridgeStatus`, `Get-ComboItems` (a combo box's item count and selection; Composer's combos refuse their texts cross-process), `Get-ComboListItemsMsaa` (the texts of a dropped list through MSAA) |
| Tabs and actions | `Get-ComposerTabControl`, `Select-ComposerTab`, `Set-ComposerTabOffset`, `Get-ComposerActions`, `Invoke-ComposerAction` |
| Dialogs and pickers | `Get-ComposerDialog`, `Wait-ComposerDialog`, `Get-ComposerDialogText`, `Close-ComposerDialog`, `Confirm-ComposerDialog`, `Get-ListViewItems`, `Get-ListViewItemScreenPoint`, `Get-ComposerPickerItems`, `Open-ComposerPicker`, `Get-ComposerParameterValues`, `Select-ComposerPickerItem`, `Set-ComposerActionParameter` |
| Devices in the tree | `Get-ComposerTreeHandle`, `Get-ComposerDevices`, `Select-ComposerDevice`, `Get-ComposerSelectedDevice`, `Rename-ComposerDevice`, `Get-ComposerTreeEditor`, `Request-ComposerDeviceDelete` (opens the prompt, never confirms) |
| Properties | `Set-ComposerProperty` (edits the row and clicks Set, rule 7) |
| Checks | `Get-ComposerBaseline`, `Assert-ComposerUnchanged` (rule 6) |
| Screenshots | `Save-ComposerShot`, `Save-ScreenShot`, `Save-RegionShot`, `Save-ElementShot`, `Save-PropertyRowShot` (unscaled crops for the manual, round 12), `Send-DocShot` (PUT `/img/<name>` to `tools/collect.py` on this VM, port 8090) |
| Manual pictures (`tools/composer/Shots.ps1`, dot-sourced after the module; #61, `docs/screenshots-plan.md`) | `Initialize-Shots` (the `raw\`, `doc\` and `hold\` folders), `Get-HouseTerms` (the house's names for the deny check, in memory only), `Save-PaneShot` (captures one pane, dialog or row, a window by its visible frame; refuses a crop that shows the title bar, the status bar or the tree), `Get-TextRegions`, `Set-TextReplacement` (paints a neutral text in the measured font), `Save-ShotResult` (to `doc\`, or to `hold\` with the reasons), `Invoke-ShotPlan`, `Export-ShotPlanFromDoc`, `Export-ShotTexts` (the per-picture text list) |

Connections and Programming can be changed with synthesized drags since
2026-10-27 (#312, "Learned 2026-10-27" below): a binding when the drag
starts on the selected device's own row in the top pane of Connections,
a Script line by dragging an action's green arrow into the Script. The
two attempts of 2026-10-22 that "started no OLE drag" (`docs/design.md`,
Composer UI) began in the lower list, where no drag starts. The verified
method moves with relative input (`MOUSEEVENTF_MOVE`); the repo copy of
`Invoke-MouseDrag` steps with absolute `SetCursorPos` instead, so until
the module has a function for the verified method, a brief that binds or
programs spells it out. A binding can still be made from the bridge with
`C4:Bind` in a dev build (`docs/design.md`, Project APIs).

## Workflow

1. The coordinator writes a numbered brief (what to observe, what to
   click, what to report) and sends it to the Windows session.
2. The Windows session runs it and reports texts and screenshots.
3. The coordinator correlates with the drivers' own output: the dev loop's
   shipped log (`build/dev/driver.log`) while a dev build runs; in
   production only the properties and the Lua Output pane (rule 13). It
   records findings in `docs/design.md` and `docs/status.md`, and
   continues.

Installing a release (since 2026-10-24, round 34): `tools/deploy.py start`
writes `build/release/<tag>/BRIEF.md` (`docs/release-checklist.md`,
"Deploy to the house") and the coordinator sends it as it is: the three
GitHub download URLs and their sha256, the PowerShell that fetches them
into `C:\c4-hue\drivers\<tag>\` and checks them with `Get-FileHash`, the
Composer steps, what to read back, and the standing-approval sentence. The
session installs all three at once with Driver ▸ "Add or Update Driver or
Agent…", in place (approval per rule 8), and reads back every device's
`Driver Version` and the bridge's `Stream Timeout (s)`, `Stream Watchdog
(s)`, `Debug Mode`, `Status` and `Attention`; the coordinator records the
result with `tools/deploy.py done` or `failed`. A dev build or a
feature-branch test build is the exception (`CLAUDE.md`, Deploy): the
coordinator serves the three `.c4z` from `build/release/` on port 8090
(`python3 -I -m http.server 8090 --bind 0.0.0.0 --directory
build/release`, stopped afterwards), puts their sha256 in the brief, and
records the install with `tools/deploy.py record --no-manifest`.

The Composer checklist (`docs/composer-checklist.md`) remains the list of
things to verify; its steps are briefs for the Windows session. The brief
names the steps that are hard to undo (rule 2) and the standing approval
covers them (rule 8); only what needs the owner's hands (a controller
reboot from System Manager, rule 9; a keypad, a lamp, the phone) waits for
him. Since 2026-10-27 (#312) Connections and Programming are not among
them: the session binds and writes Script lines by synthetic drag and
reads the result back (rule 18).

## History

The first rounds (2026-10-21) read pages, pickers and the action list and
ran the scene lifecycle (`docs/design.md`, Composer UI and Scenes build).
Rounds 9–20 (2026-10-22 to 2026-10-24) moved the house to production
builds and kept it there: the installs from production build 116 to build
160; the 35 remaining light devices deleted on the owner's word
(2026-10-22); the manual's screenshots shot and uploaded (round 12); the
Documentation tab, the icons and every device's version read after each
install; the reboot tests of builds 150 and 160 watched from Composer.
They produced rules 8–16 and, in round 18c, the click check of rule 5.
Rounds 21–23 (2026-10-24) installed builds 184, 185 and 196, read the new
Room Mappings drop-down (its items through MSAA, since Composer's combo
refuses CB_GETLBTEXT cross-process), and created the first zone light from
the Actions tab, reading every picker on the way. Rounds 24–29 found the
blank Driver Version of a fresh device (Director's empty property table at
first init), installed the dev build 224 for the regression pass and the
release builds 226 and 228, and read the Documentation tabs' Apache footer; round 30 installed the
re-cut 1.0 (build 237) and read the new Bridge Name and Bridge Firmware
rows. Since the repository is public, reports leave the house's addresses
and the bridge id out. Rounds 31–33 settled the Last Action rows (a
read-only list is a disabled combo box; Composer drops attribute changes
that arrive with text updates, so the rows' visibility is sent later) and
set the bridge's Debug Mode back to Off after the dev build had left it On.
Round 34 (2026-10-24, 23:11 local; GitHub dates the deployment
2026-10-25 UTC) was the first install through the GitOps flow
(`docs/cicd-gitops-design.md`): the packages came from the GitHub release
URLs named in the brief `tools/deploy.py start` wrote, were hash-checked
with `Get-FileHash`, and all five Hue devices read Driver Version 259
afterwards; the result went back to GitHub as a deployment on the
environment `house` with `tools/deploy.py done`. Rounds 35 to 43
(2026-10-25) served the night's hardware pass on dev builds 276 and 284
(rounds 38 and 40 worked the devices' Lua command windows: `docs/design.md`,
"Hardware pass of 2026-10-25 night"; rounds 41 and 42 showed that the
light_v2 proxy stores a keypad setting the driver reports as a bare value
and reads the documented table form as 0, `common/device.lua`), and round
43 installed dev build 309 for the checks of issue #40 (03:24, no reboot;
`docs/status.md`).

## Done 2026-10-25: every click through Invoke-SafeClick (#239)

The Windows session changed its `Composer.psm1` and sent it back; the repo
copy is that file, with the VM's address in `Send-DocShot`'s default
replaced by the placeholder 192.0.2.7. New: `Get-ComposerRootWindow` (the
top-level window of a handle or of a UIA element through its nearest
ancestor with a handle) and `Assert-SafePoint` (the rectangle and
foreground check, split out of `Invoke-SafeClick`). The tab, tree, picker,
rename and property clicks and `Invoke-ElementClick` go through
`Invoke-SafeClick` with their target's top-level window; `Invoke-MouseDrag`
takes `-Hwnd` (default Composer's main window), checks both points before
pressing and, if the window loses the foreground mid-drag, releases at the
start point and throws. Checked on the Windows VM: the parser finds no
error, the file is ASCII only, all 58 functions import, and with the desktop
disconnected a tab click and a drag both refuse without clicking.
PSScriptAnalyzer runs in CI. `Close-ComposerDialog`'s Escape goes through
`Send-KeysTo -ExpectedHwnd <dialog> -Within` (new: focus on any control
inside that top-level window, which must be in the foreground); raw
`Send-Keys` remains only inside `Send-KeysTo`.

## Learned 2026-10-27: Connections and Programming by synthetic drag (#312)

Verified on the house by the Windows session (Composer Pro 3.4.2, OS
3.4.3). It corrects the finding of 2026-10-22 that synthesized input
cannot make a connection (`docs/design.md`, Composer UI, where a
Superseded line now says so).

- **Connections: drag from the top pane.** Select the device whose
  connection is to be made: the top pane lists its own connection rows
  (for a keypad, its "\<button> Button Link" Control Inputs). Drag that
  row onto the matching connection's row in the lower list ("BUTTON_LINK
  Output Devices" for a Button Link) and the binding is made. A drag that
  starts in the lower list never begins, from the row's text or from its
  icon (no capture, `IDC_ARROW`); double-clicking a lower row does
  nothing, and the right-click menu of either row offers only Disconnect.
- **The drag that works**: relative moves through `SendInput` or
  `mouse_event` (`MOUSEEVENTF_MOVE`). Press, wait 300 ms, move at least
  10 px of real travel in the first steps, then about 30 steps of 20 ms
  to the target, hover 500 ms, release. Windows scales relative moves:
  eight 1 px moves travelled 4 px, exactly the edge of the list's drag
  rectangle (`SM_CXDRAG`, 4 px either side of the press point), and
  started nothing. Once a drag has begun, `GetGUIThreadInfo` reports a
  capture window and the cursor is the no-drop (`IDC_NO`) or the drop
  cursor (rule 18).
- **Disconnect** asks "Are you sure you want to disconnect \<device A>
  from \<device B>?": it names the devices, not the connection, so the
  row right-clicked decides which binding goes; read both lists again
  afterwards.
- **A keypad button follows its link by itself.** Making a button's link
  switched that button's LED Behavior to Follow Connection;
  disconnecting did not switch it back. LED Behavior offers Follow
  Connection, Follow Load, Push/Release and Programmed; Button Behavior
  offers Load On, Load Off, Toggle Load and Keypad.
- **Test one binding before building on a driver's links.** A third-party
  fan driver's BUTTON_LINK connections bound normally and did nothing,
  neither for presses nor for the LED: a driver can declare links it does
  not implement. That is a bug of that driver, not a Composer limit.
- **Programming: drag an action's green arrow into the Script**, with
  the same drag (the capture holds, the drop cursor shows). A command
  nests inside an If only when dropped on the If's blue "?" icon, and
  each further drop there appends it as the If's last child; dropped on
  the If row's text, it lands at top level, before the If (upper half of
  the row) or after it (lower half).
- **The right-click menu of a Script line**: Move Up, Move Down, Disable
  Event, Disable Item (Enable Item once disabled), Insert Comment, View
  Code Item Description, Copy All, Copy Selected, Paste, Find and
  Replace, Delete, Delete All, Change to Customer. Delete asks "Are you
  sure you want to delete the code item: \<text>", Delete All "Are you
  sure you want to delete all code items?". A disabled line shows a grey
  arrow with a small red ×; disabling an If greys its children.
- **Copy All reads a Script back**: the clipboard gets the whole script
  as XML, `<cutitems>` holding `<item>` elements, each with its Type, its
  Description and its child items nested inside, so the nesting can be
  checked exactly (rule 18).
- **Keypad LED commands**: "Set LED On" and "Set LED Off" only choose the
  colour a button shows when lit or dark (the line reads "Set \<button>
  LED on the \<keypad> to \<colour> when on"); "Use the on color for
  \<button>" and "Use the off color for \<button>" light and darken it;
  "Set LED Current" shows a colour now.
- **The mouse wheel changes property values** (rule 17): over a property
  page it stepped the drop-down under the pointer, and Engraving Size on
  the project root's Lighting Defaults went from Standard to Large (set
  back afterwards). Scroll with clicks on the scrollbar only.
