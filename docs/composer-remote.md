# Driving Composer Pro from here: the Windows session

The dev loop (`docs/dev-loop.md`) lets the coordinator change and exercise
the drivers on the live controller, but everything that happens *in
Composer Pro* — driver updates, the Actions tab, dialogs, renaming or
deleting devices, what a Navigator tile looks like — used to need the
owner's hands. The second layer removes that: a Claude Code session
running inside the Claude desktop app **on the Windows VM** acts as the
coordinator's hands in Composer, driven by messages from the coordinator's
session.

**Current state (2026-10-24):** in use since 2026-10-21, 29 rounds so far
(history at the end). The house runs production builds, so the dev loop is
off and Composer is where results are read (rule 13); installs follow
`docs/status.md`, "How builds reach the house".

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
  `UIAutomationTypes`, `SendInput` via P/Invoke where a pattern is
  missing), Git Bash, and a `Read` tool that renders PNG files it saved.
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
  here (builds to install, screenshots to upload).

## Rules for the Windows session

Written into every brief; the session is a teammate acting on the owner's
behalf, not the owner.

1. **Read first, click second.** Reading properties, listing actions,
   opening a dialog to inspect its pickers and cancelling it, taking
   screenshots: always allowed.
2. **Hard-to-undo steps are named in the brief**: deleting a device,
   Update Driver, Connections changes, Load/Save project, OK in a dialog
   that creates or changes a device. They are covered by the owner's
   standing approval (rule 8); the brief names them so the session knows
   what it is about to change.
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
   point (round 18c). Learned the hard way on 2026-10-21: an ALT tap left
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
    (`has_leds`, hold rates, `dimmer`) makes Composer ask "Restart
    Director?"; Yes does **not** restart Director, the devices keep the old
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

## The helper module

`tools/composer/Composer.psm1` is the PowerShell module the Windows
session grows as it works (it develops and tests it there, then sends it
back for the repo). The repo copy was refreshed on 2026-10-24 from the
session's own file (54 functions); it is not run on this VM. Composer
exposes no UIA patterns, so the module reads through UIA and acts through
real mouse and keyboard input at the reported rectangles.

| Purpose | Functions |
| --- | --- |
| Window, focus, input | `Get-ComposerProcess`, `Get-ComposerMainHandle`, `Get-ComposerWindow`, `Get-ComposerTopWindows`, `Show-Composer`, `Show-AnyWindow` (foreground without ALT), `Get-ComposerFocus`, `Invoke-SafeClick` (rule 5), `Invoke-MouseClick`, `Invoke-MouseDrag`, `Move-MouseAway`, `Invoke-ElementClick`, `Send-Keys`, `Send-KeysTo` (keys only into the expected window) |
| Reading | `Find-ComposerElements`, `Get-ComposerElementInfo`, `Get-ComposerTree`, `Get-ComposerProperties`, `Get-ComposerProperty`, `Get-ComposerBridgeStatus`, `Format-BridgeStatus` |
| Tabs and actions | `Get-ComposerTabControl`, `Select-ComposerTab`, `Set-ComposerTabOffset`, `Get-ComposerActions`, `Invoke-ComposerAction` |
| Dialogs and pickers | `Get-ComposerDialog`, `Wait-ComposerDialog`, `Get-ComposerDialogText`, `Close-ComposerDialog`, `Confirm-ComposerDialog`, `Get-ListViewItems`, `Get-ListViewItemScreenPoint`, `Get-ComposerPickerItems`, `Open-ComposerPicker`, `Get-ComposerParameterValues`, `Select-ComposerPickerItem`, `Set-ComposerActionParameter` |
| Devices in the tree | `Get-ComposerTreeHandle`, `Get-ComposerDevices`, `Select-ComposerDevice`, `Get-ComposerSelectedDevice`, `Rename-ComposerDevice`, `Get-ComposerTreeEditor`, `Request-ComposerDeviceDelete` (opens the prompt, never confirms) |
| Properties | `Set-ComposerProperty` (edits the row and clicks Set, rule 7) |
| Checks | `Get-ComposerBaseline`, `Assert-ComposerUnchanged` (rule 6) |
| Screenshots | `Save-ComposerShot`, `Save-ScreenShot`, `Save-RegionShot`, `Save-ElementShot`, `Save-PropertyRowShot` (unscaled crops for the manual, round 12), `Send-DocShot` (PUT to `tools/collect.py` on this VM) |

Connections cannot be made with synthesized input (two drag attempts
started no OLE drag); a binding is made from the bridge with `C4:Bind`
in a dev build, or by the owner (`docs/design.md`, Composer UI).

## Workflow

1. The coordinator writes a numbered brief (what to observe, what to
   click, what to report) and sends it to the Windows session.
2. The Windows session runs it and reports texts and screenshots.
3. The coordinator correlates with the drivers' own output: the dev loop's
   shipped log (`build/dev/driver.log`) while a dev build runs; in
   production only the properties and the Lua Output pane (rule 13). It
   records findings in `docs/design.md` and `docs/status.md`, and
   continues.

Installing a build: the coordinator serves the three `.c4z` from
`build/release/` on port 8090 and puts their sha256 in the brief; the
session downloads them, checks the hashes, installs all three at once with
Driver ▸ "Add or Update Driver or Agent…" (approval per rule 8) and reads
every device's `Driver Version` (`CLAUDE.md`, Deploy).

The Composer checklist (`docs/composer-checklist.md`) remains the list of
things to verify; its steps are now briefs for the Windows session, with
the owner's approval sought for the destructive ones.

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
release builds 226 and 228, and read the Documentation tabs' Apache footer.
