# Driving Composer Pro from here: the Windows session

The dev loop (`docs/dev-loop.md`) lets the coordinator change and exercise
the drivers on the live controller, but everything that happens *in
Composer Pro* — driver updates, the Actions tab, dialogs, renaming or
deleting devices, what a Navigator tile looks like — used to need the
owner's hands. The second layer removes that: a Claude Code session
running inside the Claude desktop app **on the Windows VM** acts as the
coordinator's hands in Composer, driven by messages from the coordinator's
session.

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
  controller and this VM; it can reach the dev server's port.

## Rules for the Windows session

Written into every brief; the session is a teammate acting on the owner's
behalf, not the owner.

1. **Read first, click second.** Reading properties, listing actions,
   opening a dialog to inspect its pickers and cancelling it, taking
   screenshots: always allowed.
2. **Nothing hard to undo without the owner's word**: deleting a device,
   Update Driver, Connections changes, Load/Save project, OK in a dialog
   that creates or changes a device. The coordinator asks the owner first
   and quotes the approval in the brief.
3. **Stop on surprises**: any unexpected dialog, error or prompt ends the
   round with a report, not a guess.
4. **Report exact texts** (UIA Names, property values) and keep screenshots
   under `C:\c4-hue\shots\`.
5. **Keystrokes only into a verified target.** Before any key is sent, the
   focused control must have been checked (the tree's in-place editor, a
   dialog button, a text field) and no menu may be active; never tap ALT to
   gain foreground rights (use `AttachThreadInput` + `SetForegroundWindow`
   or a click). Prefer window messages (`WM_SETTEXT`) and rectangle clicks
   over typing; re-check `Get-ComposerDialog` before every Enter and Cancel
   anything unexpected. Learned the hard way on 2026-10-21: an ALT tap left
   Composer's File menu in keyboard mode and the Enter meant for the rename
   editor opened **File ▸ Clear Project**'s confirmation; the session
   cancelled it and nothing was lost, but the project must be backed up
   before any round that changes it.
6. **After every step** confirm the window title (project name) and the
   System Design row count are unchanged unless the step meant to change
   them.

## The helper module

`tools/composer/Composer.psm1` is the PowerShell module the Windows
session grows as it works (it develops and tests it there, then pastes it
back for the repo). Intended surface:

| Function | Does |
| --- | --- |
| `Get-ComposerWindow` | the main window's AutomationElement (title "Composer Pro <ver> / … - <project> (Local)") |
| `Show-Composer` | bring it to the foreground |
| `Save-ComposerShot -Path` | PNG of the Composer window |
| `Get-ComposerProperties` | the current Properties page as label → value |
| `Get-ComposerProperty -Name` | one value |
| `Select-ComposerTab -Name` | Properties / Actions / … |
| `Get-ComposerActions` | the Actions tab's action names |
| `Invoke-ComposerAction -Name` | click an action; returns when a dialog or the result appears |
| `Get-ComposerPickerItems -Label` | the items a CUSTOM_SELECT picker offers |
| `Close-ComposerDialog` | Cancel/close the open dialog |
| `Select-ComposerDevice -Name` | select a device in the System Design tree |

"Proven" versus "untested" is tracked in the module header.

## Workflow

1. The coordinator writes a numbered brief (what to observe, what to
   click, what to report) and sends it to the Windows session.
2. The Windows session runs it and reports texts and screenshots.
3. The coordinator correlates with the shipped driver log (`build/dev/
   driver.log`), records findings in `docs/design.md`, and continues.

The Composer checklist (`docs/composer-checklist.md`) remains the list of
things to verify; its steps are now briefs for the Windows session, with
the owner's approval sought for the destructive ones.
