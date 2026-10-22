# Composer.psm1 - drive Control4 Composer Pro 3.4.2 (WinForms) via UI Automation + SendInput.
# Tested on Windows 11 Pro, Windows PowerShell 5.1.  Import with:  Import-Module C:\c4-hue\Composer.psm1 -Force
#
# Written and exercised by the Claude Code session on the Windows VM (docs/composer-remote.md); the
# coordinator keeps this copy in the repo. Proven 2026-10-21: Get-ComposerProcess, Get-ComposerWindow,
# Get-ComposerTopWindows, Get-ComposerDialog (incl. a Select picker nested under Action Parameter List),
# Wait-ComposerDialog, Show-Composer, Save-ComposerShot -FromScreen, Save-ScreenShot, Find-ComposerElements,
# Get-ComposerElementInfo, Get-ComposerTree, Invoke-MouseClick, Invoke-ElementClick, Send-Keys ({ESC}),
# Get-ComposerProperties, Get-ComposerProperty, Get-ComposerTabControl, Select-ComposerTab (Properties/Actions),
# Get-ComposerActions, Invoke-ComposerAction, Close-ComposerDialog, C4.ListView, Get-ListViewItems,
# Get-ListViewItemScreenPoint, Get-ComposerPickerItems, Open-ComposerPicker, Get-ComposerParameterValues,
# Get-ComposerTreeHandle, Get-ComposerDevices, Select-ComposerDevice, Get-ComposerSelectedDevice.
# Untested: Save-ComposerShot without -FromScreen (PrintWindow), Select-ComposerPickerItem, Rename-ComposerDevice,
# Set-ComposerTabOffset, Select-ComposerTab 'Lua', right/double click, Show-Composer when minimised.
# Known limits: tab offsets are pixel constants measured at 96 DPI; Select-ComposerDevice only sees expanded
# tree rows; Composer must be on the System Design view.
#
# Composer exposes every control to UIA as ControlType.Pane with NO patterns (no Invoke/Value/Selection),
# so this module READS through UIA (Name / ClassName / BoundingRectangle) and ACTS through real mouse and
# keyboard input at UIA-reported screen coordinates.

Set-StrictMode -Off
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing

if (-not ('C4.Native' -as [type])) {
Add-Type -Namespace C4 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}
[void][C4.Native]::SetProcessDPIAware()

$script:A     = [System.Windows.Automation.AutomationElement]
$script:Scope = [System.Windows.Automation.TreeScope]
$script:Any  = [System.Windows.Automation.Condition]::TrueCondition
$script:Raw   = [System.Windows.Automation.TreeWalker]::RawViewWalker

function Get-ComposerProcess {
    $p = Get-Process ComposerPro -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw "ComposerPro.exe is not running (or has no main window)" }
    $p
}

function Get-ComposerWindow {
    # AutomationElement of Composer's main window.
    $p = Get-ComposerProcess
    $el = $script:A::FromHandle($p.MainWindowHandle)
    if (-not $el) { throw "Could not get UIA element for Composer main window" }
    $el
}

function Get-ComposerTopWindows {
    # All top-level windows of the Composer process (main window + open dialogs).
    $p = Get-ComposerProcess
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:A::ProcessIdProperty, [int]$p.Id)
    @($script:A::RootElement.FindAll($script:Scope::Children, $cond))
}

function Get-ComposerDialog {
    # The most recently opened Composer dialog, or $null. Owned (modal) dialogs appear in UIA as ControlType.Window
    # CHILDREN of the main window, so look there first, then at other top-level windows of the process.
    $p = Get-ComposerProcess
    $main = [int]$p.MainWindowHandle
    $winCond = New-Object System.Windows.Automation.PropertyCondition($script:A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    $mainEl = $script:A::FromHandle($p.MainWindowHandle)
    $owned = @($mainEl.FindAll($script:Scope::Children, $winCond))
    if ($owned.Count -gt 0) {
        # nested: a dialog opened from a dialog is a child of that dialog; descend to the deepest one
        $d = $owned[-1]
        while ($true) { $sub = @($d.FindAll($script:Scope::Children, $winCond)); if ($sub.Count -eq 0) { break }; $d = $sub[-1] }
        return $d
    }
    Get-ComposerTopWindows | Where-Object { $_.Current.NativeWindowHandle -ne $main } | Select-Object -First 1
}

function Wait-ComposerDialog {
    param([int]$TimeoutMs = 8000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) { $d = Get-ComposerDialog; if ($d) { return $d }; Start-Sleep -Milliseconds 250 }
    $null
}

function Show-Composer {
    # Bring Composer's main window to the foreground (tap ALT first so SetForegroundWindow is honoured).
    $p = Get-ComposerProcess
    $h = $p.MainWindowHandle
    if ([C4.Native]::IsIconic($h)) { [void][C4.Native]::ShowWindow($h, 9) }   # SW_RESTORE
    [C4.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [C4.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][C4.Native]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 400
    ([C4.Native]::GetForegroundWindow() -eq $h)
}

function Save-ComposerShot {
    # Save a PNG of Composer's main window (or -Hwnd) to -Path. PrintWindow(PW_RENDERFULLCONTENT) works even when occluded;
    # -FromScreen copies the window rect from the screen instead (window must be in front; captures overlapping dialogs too).
    param([Parameter(Mandatory)][string]$Path, [IntPtr]$Hwnd = 0, [switch]$FromScreen)
    if ($Hwnd -eq 0) { $Hwnd = (Get-ComposerProcess).MainWindowHandle }
    $r = New-Object C4.Native+RECT
    [void][C4.Native]::GetWindowRect($Hwnd, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    if ($FromScreen) {
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    } else {
        $hdc = $g.GetHdc()
        $ok = [C4.Native]::PrintWindow($Hwnd, $hdc, 2)   # PW_RENDERFULLCONTENT
        $g.ReleaseHdc($hdc)
        if (-not $ok) { $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h)) }
    }
    $g.Dispose()
    $dir = Split-Path $Path; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Get-Item $Path
}

function Save-ScreenShot {
    # Whole virtual screen to PNG.
    param([Parameter(Mandatory)][string]$Path)
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $v.Width, $v.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($v.X, $v.Y, 0, 0, $v.Size); $g.Dispose()
    $dir = Split-Path $Path; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Get-Item $Path
}

function Find-ComposerElements {
    # Descendants of $Root (default: main window) matching -Name (wildcard) and/or -Class (substring of ClassName).
    param([string]$Name, [string]$Class, $Root)
    if (-not $Root) { $Root = Get-ComposerWindow }
    $all = $Root.FindAll($script:Scope::Descendants, $script:Any)
    foreach ($e in $all) {
        $c = $e.Current
        if ($Name  -and ($c.Name -notlike $Name)) { continue }
        if ($Class -and ($c.ClassName -notlike "*$Class*")) { continue }
        $e
    }
}

function Get-ComposerElementInfo {
    param([Parameter(ValueFromPipeline)]$Element)
    process {
        $c = $Element.Current; $r = $c.BoundingRectangle
        [pscustomobject]@{ Type = ($c.ControlType.ProgrammaticName -replace 'ControlType\.',''); Name = $c.Name
            Class = ($c.ClassName -replace 'WindowsForms10\.','' -replace '\.app\.0\.\S+',''); Id = $c.AutomationId
            X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.Width; H = [int]$r.Height; Offscreen = $c.IsOffscreen }
    }
}

function Get-ComposerTree {
    # Indented text dump of the UIA (raw view) tree under $Root. Debugging aid.
    param($Root, [int]$MaxNameLen = 80)
    if (-not $Root) { $Root = Get-ComposerWindow }
    $sb = New-Object System.Text.StringBuilder
    $walk = { param($el, $d)
        $i = $el | Get-ComposerElementInfo
        $n = $i.Name; if ($n.Length -gt $MaxNameLen) { $n = $n.Substring(0, $MaxNameLen) + '...' }
        [void]$sb.AppendLine(("{0}[{1}] '{2}' cls={3} rect={4},{5},{6},{7}" -f ('  ' * $d), $i.Type, $n, $i.Class, $i.X, $i.Y, $i.W, $i.H))
        $ch = $script:Raw.GetFirstChild($el)
        while ($ch) { & $walk $ch ($d + 1); $ch = $script:Raw.GetNextSibling($ch) }
    }
    & $walk $Root 0
    $sb.ToString()
}

function Invoke-MouseClick {
    # Physical left (or -Right / -Double) click at screen coordinates.
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [switch]$Right, [switch]$Double)
    [void][C4.Native]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 60
    if ($Right) { $down = 0x0008; $up = 0x0010 } else { $down = 0x0002; $up = 0x0004 }
    [C4.Native]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); [C4.Native]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
    if ($Double) { Start-Sleep -Milliseconds 80; [C4.Native]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); [C4.Native]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 150
}

function Invoke-ElementClick {
    # Click the centre of a UIA element's bounding rectangle.
    param([Parameter(Mandatory)]$Element, [switch]$Right, [switch]$Double)
    $r = $Element.Current.BoundingRectangle
    if ($r.IsEmpty) { throw "Element '$($Element.Current.Name)' has no bounding rectangle" }
    Invoke-MouseClick -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2)) -Right:$Right -Double:$Double
}

function Send-Keys {
    # SendKeys syntax, e.g. '{F2}', '^a', 'text{ENTER}'. Caller escapes braces/+^%~ in literal text.
    param([Parameter(Mandatory)][string]$Keys, [int]$DelayMs = 150)
    [System.Windows.Forms.SendKeys]::SendWait($Keys); Start-Sleep -Milliseconds $DelayMs
}

function Get-ComposerProperties {
    # Ordered hashtable label -> value for the current Properties page.
    # Layout: each row = Pane{ Pane > EDIT(label, x<500) , Pane > EDIT|COMBOBOX(value, x>=500) }.
    $win = Get-ComposerWindow
    $page = Find-ComposerElements -Name 'Properties' -Class 'Window.8' -Root $win | Where-Object { $_.Current.BoundingRectangle.Height -gt 100 } | Select-Object -First 1
    if (-not $page) { throw "Properties page not found (is the Properties tab selected?)" }
    $rows = @()
    foreach ($e in $page.FindAll($script:Scope::Descendants, $script:Any)) {
        $c = $e.Current
        if ($c.ClassName -notlike '*EDIT*' -and $c.ClassName -notlike '*COMBOBOX*') { continue }
        $r = $c.BoundingRectangle
        $rows += [pscustomobject]@{ Name = $c.Name; X = [int]$r.X; Y = [int]$r.Y; Class = $c.ClassName }
    }
    $split = [int]($page.Current.BoundingRectangle.X + 180)
    $labels = $rows | Where-Object { $_.X -lt $split } | Sort-Object Y
    $result = [ordered]@{}
    foreach ($l in $labels) {
        $v = $rows | Where-Object { $_.X -ge $split -and [math]::Abs($_.Y - $l.Y) -le 8 } | Select-Object -First 1
        $result[$l.Name] = if ($v) { $v.Name } else { $null }
    }
    $result
}

function Get-ComposerProperty { param([Parameter(Mandatory)][string]$Name) (Get-ComposerProperties)[$Name] }

function Get-ComposerTabControl { Find-ComposerElements -Class 'SysTabControl32' | Select-Object -First 1 }

# Tab headers are not exposed to UIA; offsets (px from the tab control's left edge) are measured from a screenshot.
$script:TabOffsets = @{ 'Properties' = 36; 'Actions' = 97; 'Lua' = 144 }   # measured 2026-10-21 on Composer Pro 3.4.2 @ 96 DPI

function Select-ComposerTab {
    # Click a tab header by name using $script:TabOffsets.
    param([Parameter(Mandatory)][string]$Name)
    $tab = Get-ComposerTabControl
    if (-not $tab) { throw "Tab control not found" }
    if (-not $script:TabOffsets.ContainsKey($Name)) { throw "Unknown tab '$Name'; known: $($script:TabOffsets.Keys -join ', ')" }
    $r = $tab.Current.BoundingRectangle
    Invoke-MouseClick -X ([int]($r.X + $script:TabOffsets[$Name])) -Y ([int]($r.Y + 11))
    Start-Sleep -Milliseconds 500
}

function Set-ComposerTabOffset { param([string]$Name, [int]$Offset) $script:TabOffsets[$Name] = $Offset }


function Get-ComposerActions {
    # Names of the action buttons on the (already selected) Actions tab, in visual top-to-bottom order.
    $tab = Get-ComposerTabControl
    $page = $script:Raw.GetFirstChild($tab)
    if (-not $page -or $page.Current.Name -ne 'Actions') { throw "Actions tab is not selected (page is '$($page.Current.Name)')" }
    Find-ComposerElements -Class 'BUTTON' -Root $page | Get-ComposerElementInfo | Sort-Object Y | Select-Object -ExpandProperty Name
}

function Invoke-ComposerAction {
    # Click an action button by name on the Actions tab. Returns the dialog element if one opened within -TimeoutMs, else $null.
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutMs = 6000)
    $tab = Get-ComposerTabControl
    $page = $script:Raw.GetFirstChild($tab)
    if (-not $page -or $page.Current.Name -ne 'Actions') { throw "Actions tab is not selected" }
    $btn = Find-ComposerElements -Class 'BUTTON' -Name $Name -Root $page | Select-Object -First 1
    if (-not $btn) { throw "Action '$Name' not found; available: $((Get-ComposerActions) -join ', ')" }
    Invoke-ElementClick -Element $btn
    Wait-ComposerDialog -TimeoutMs $TimeoutMs
}

function Close-ComposerDialog {
    # Press Escape on the current dialog (= Cancel), or click a button named -Button ('Cancel' by default if present).
    param([string]$Button = 'Cancel', [switch]$Escape)
    $d = Get-ComposerDialog
    if (-not $d) { return $false }
    $h = $d.Current.NativeWindowHandle
    if (-not $Escape) {
        $b = Find-ComposerElements -Class 'BUTTON' -Name $Button -Root $d | Select-Object -First 1
        if ($b) { Invoke-ElementClick -Element $b; Start-Sleep -Milliseconds 400 }
        else { [void][C4.Native]::SetForegroundWindow([IntPtr]$h); Send-Keys '{ESC}' 400 }
    } else { [void][C4.Native]::SetForegroundWindow([IntPtr]$h); Send-Keys '{ESC}' 400 }
    $now = Get-ComposerDialog
    (-not $now -or $now.Current.NativeWindowHandle -ne $h)   # $true when THAT dialog is gone
}

# ---- Win32 SysListView32 reader (cross-process; Composer is a 32-bit process, so LVITEM/RECT use 32-bit layouts) ----
if (-not ('C4.ListView' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
namespace C4 {
public static class ListView {
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, uint size, uint type, uint prot);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, uint size, uint type);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, uint size, out IntPtr written);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, uint size, out IntPtr read);
    const uint LVM_FIRST = 0x1000, LVM_GETITEMCOUNT = LVM_FIRST+4, LVM_GETITEMRECT = LVM_FIRST+14, LVM_GETITEMSTATE = LVM_FIRST+44,
               LVM_GETITEMTEXTW = LVM_FIRST+115, LVM_ENSUREVISIBLE = LVM_FIRST+19, LVM_GETTOPINDEX = LVM_FIRST+39, LVM_GETCOUNTPERPAGE = LVM_FIRST+40;
    const uint PROCESS_VM = 0x0008|0x0010|0x0020|0x0400; // VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION
    public static int GetCount(IntPtr h) { return (int)SendMessage(h, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero); }
    public static int GetTopIndex(IntPtr h) { return (int)SendMessage(h, LVM_GETTOPINDEX, IntPtr.Zero, IntPtr.Zero); }
    public static int GetCountPerPage(IntPtr h) { return (int)SendMessage(h, LVM_GETCOUNTPERPAGE, IntPtr.Zero, IntPtr.Zero); }
    public static int GetState(IntPtr h, int i) { return (int)SendMessage(h, LVM_GETITEMSTATE, (IntPtr)i, (IntPtr)0xF); }
    public static void EnsureVisible(IntPtr h, int i) { SendMessage(h, LVM_ENSUREVISIBLE, (IntPtr)i, IntPtr.Zero); }
    static IntPtr Open(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); IntPtr p = OpenProcess(PROCESS_VM, false, pid); if (p == IntPtr.Zero) throw new Exception("OpenProcess failed"); return p; }
    // 32-bit LVITEMW: mask,iItem,iSubItem,state,stateMask,pszText,cchTextMax,iImage,lParam,iIndent,iGroupId,cColumns,puColumns,piColFmt,iGroup = 60 bytes
    public static string GetText(IntPtr h, int item, int sub) {
        IntPtr p = Open(h); const int cch = 1024; const int lvSize = 60;
        IntPtr mem = VirtualAllocEx(p, IntPtr.Zero, (uint)(lvSize + cch*2), 0x3000, 0x04);
        try {
            byte[] lv = new byte[lvSize]; int textAddr = (int)mem + lvSize;
            BitConverter.GetBytes(0x0001).CopyTo(lv, 0); BitConverter.GetBytes(item).CopyTo(lv, 4); BitConverter.GetBytes(sub).CopyTo(lv, 8);
            BitConverter.GetBytes(textAddr).CopyTo(lv, 20); BitConverter.GetBytes(cch).CopyTo(lv, 24);
            IntPtr n; WriteProcessMemory(p, mem, lv, (uint)lvSize, out n);
            SendMessage(h, LVM_GETITEMTEXTW, (IntPtr)item, mem);
            byte[] buf = new byte[cch*2]; ReadProcessMemory(p, (IntPtr)textAddr, buf, (uint)buf.Length, out n);
            string s = Encoding.Unicode.GetString(buf); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s;
        } finally { VirtualFreeEx(p, mem, 0, 0x8000); CloseHandle(p); }
    }
    public static int[] GetItemRect(IntPtr h, int item) { // left,top,right,bottom in client coords (LVIR_BOUNDS)
        IntPtr p = Open(h); IntPtr mem = VirtualAllocEx(p, IntPtr.Zero, 16, 0x3000, 0x04);
        try {
            byte[] r = new byte[16]; IntPtr n; WriteProcessMemory(p, mem, r, 16, out n);
            SendMessage(h, LVM_GETITEMRECT, (IntPtr)item, mem); ReadProcessMemory(p, mem, r, 16, out n);
            return new int[] { BitConverter.ToInt32(r,0), BitConverter.ToInt32(r,4), BitConverter.ToInt32(r,8), BitConverter.ToInt32(r,12) };
        } finally { VirtualFreeEx(p, mem, 0, 0x8000); CloseHandle(p); }
    }
}}
'@
}

function Get-ListViewItems {
    # Items of a SysListView32 given its hwnd (UIA NativeWindowHandle). Returns Index, Text, Selected.
    param([Parameter(Mandatory)][IntPtr]$Hwnd, [int]$SubItem = 0)
    $n = [C4.ListView]::GetCount($Hwnd)
    for ($i = 0; $i -lt $n; $i++) {
        [pscustomobject]@{ Index = $i; Text = [C4.ListView]::GetText($Hwnd, $i, $SubItem); Selected = (([C4.ListView]::GetState($Hwnd, $i) -band 2) -ne 0) }
    }
}

function Get-ListViewItemScreenPoint {
    # Screen point of a list view item (scrolls it into view first). Returns X,Y centre plus Left/Width of the item bounds.
    param([Parameter(Mandatory)][IntPtr]$Hwnd, [Parameter(Mandatory)][int]$Index)
    [C4.ListView]::EnsureVisible($Hwnd, $Index); Start-Sleep -Milliseconds 150
    $r = [C4.ListView]::GetItemRect($Hwnd, $Index)
    $wr = New-Object C4.Native+RECT; [void][C4.Native]::GetWindowRect($Hwnd, [ref]$wr)
    [pscustomobject]@{ X = $wr.Left + [int](($r[0] + $r[2]) / 2); Y = $wr.Top + [int](($r[1] + $r[3]) / 2); Left = $wr.Left + $r[0]; Top = $wr.Top + $r[1]; Width = $r[2] - $r[0]; Height = $r[3] - $r[1] }
}

function Get-ComposerPickerItems {
    # Items offered by the currently open 'Select' picker dialog (opened via the '...' button beside a parameter).
    $d = Get-ComposerDialog
    if (-not $d -or $d.Current.Name -ne 'Select') { throw "No 'Select' picker dialog is open (current: '$($d.Current.Name)')" }
    $lv = Find-ComposerElements -Class 'SysListView32' -Root $d | Select-Object -First 1
    Get-ListViewItems -Hwnd ([IntPtr]$lv.Current.NativeWindowHandle)
}

function Open-ComposerPicker {
    # In an 'Action Parameter List' dialog, click the '...' button beside parameter -Label. Returns the 'Select' dialog or $null.
    param([Parameter(Mandatory)][string]$Label, [int]$TimeoutMs = 5000)
    $d = Get-ComposerDialog
    if (-not $d -or $d.Current.Name -ne 'Action Parameter List') { throw "No 'Action Parameter List' dialog is open" }
    $lbl = Find-ComposerElements -Class 'EDIT' -Name $Label -Root $d | Select-Object -First 1
    if (-not $lbl) { throw "Parameter '$Label' not found in dialog" }
    $y = [int]$lbl.Current.BoundingRectangle.Y
    $btn = Find-ComposerElements -Class 'BUTTON' -Name '...' -Root $d | Where-Object { [math]::Abs([int]$_.Current.BoundingRectangle.Y - $y) -le 6 } | Select-Object -First 1
    if (-not $btn) { throw "No '...' button beside '$Label'" }
    Invoke-ElementClick -Element $btn
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) { $s = Get-ComposerDialog; if ($s -and $s.Current.Name -eq 'Select') { return $s }; Start-Sleep -Milliseconds 200 }
    $null
}

function Get-ComposerParameterValues {
    # Label -> current text of each parameter row in the open 'Action Parameter List' dialog.
    $d = Get-ComposerDialog
    if (-not $d -or $d.Current.Name -ne 'Action Parameter List') { throw "No 'Action Parameter List' dialog is open" }
    $edits = Find-ComposerElements -Class 'EDIT' -Root $d | Get-ComposerElementInfo
    $split = [int]$d.Current.BoundingRectangle.X + 160
    $result = [ordered]@{}
    foreach ($l in ($edits | Where-Object { $_.X -lt $split } | Sort-Object Y)) {
        $v = $edits | Where-Object { $_.X -ge $split -and [math]::Abs($_.Y - $l.Y) -le 6 } | Select-Object -First 1
        $result[$l.Name] = if ($v) { $v.Name } else { $null }
    }
    $result
}

function Select-ComposerPickerItem {
    # Click an item by text in the open 'Select' picker, then its OK. Returns $true when the picker closed.
    param([Parameter(Mandatory)][string]$Text)
    $d = Get-ComposerDialog
    if (-not $d -or $d.Current.Name -ne 'Select') { throw "No 'Select' picker dialog is open" }
    $lv = Find-ComposerElements -Class 'SysListView32' -Root $d | Select-Object -First 1
    $h = [IntPtr]$lv.Current.NativeWindowHandle
    $item = Get-ListViewItems -Hwnd $h | Where-Object { $_.Text -eq $Text } | Select-Object -First 1
    if (-not $item) { throw "Item '$Text' not in picker; items: $((Get-ListViewItems -Hwnd $h | ForEach-Object Text) -join ' | ')" }
    $pt = Get-ListViewItemScreenPoint -Hwnd $h -Index $item.Index
    Invoke-MouseClick -X ($pt.Left + 20) -Y $pt.Y
    Start-Sleep -Milliseconds 300
    $ok = Find-ComposerElements -Class 'BUTTON' -Name 'OK' -Root $d | Select-Object -First 1
    Invoke-ElementClick -Element $ok; Start-Sleep -Milliseconds 500
    $now = Get-ComposerDialog
    (-not $now -or $now.Current.Name -ne 'Select')
}

# ---- System Design tree (a SysListView32 drawn as a tree; column 1 holds the Director device id) ----
function Get-ComposerTreeHandle {
    $nav = $null
    for ($try = 0; $try -lt 5 -and -not $nav; $try++) {   # UIA can briefly return nothing right after a focus change
        $nav = Find-ComposerElements -Name 'System Design' -Class 'Window.8' | Select-Object -First 1
        if (-not $nav) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $nav) { throw "System Design navigator not found (is the System Design view active?)" }
    $lv = Find-ComposerElements -Class 'SysListView32' -Root $nav | Select-Object -First 1
    if (-not $lv) { throw "System Design list view not found" }
    [IntPtr]$lv.Current.NativeWindowHandle
}

function Get-ComposerDevices {
    # Every row of the System Design tree: Index, Name, DeviceId (column 1), Selected.
    $h = Get-ComposerTreeHandle
    $n = [C4.ListView]::GetCount($h)
    for ($i = 0; $i -lt $n; $i++) {
        [pscustomobject]@{ Index = $i; Name = [C4.ListView]::GetText($h, $i, 0); DeviceId = [C4.ListView]::GetText($h, $i, 1); Selected = (([C4.ListView]::GetState($h, $i) -band 2) -ne 0) }
    }
}

function Select-ComposerDevice {
    # Click a device row in the System Design tree by -Name (exact) or -DeviceId. Returns the row object once selected.
    # Note: only EXPANDED rows exist in the list view; collapse/expand is not handled here.
    param([string]$Name, [string]$DeviceId, [int]$TextOffsetX = 125)
    $h = Get-ComposerTreeHandle
    $rows = Get-ComposerDevices
    $row = if ($DeviceId) { $rows | Where-Object { $_.DeviceId -eq $DeviceId } } else { $rows | Where-Object { $_.Name -eq $Name } }
    $row = @($row)
    if ($row.Count -eq 0) { throw "Device '$Name$DeviceId' not found in tree" }
    if ($row.Count -gt 1) { throw "Device name '$Name' is ambiguous (ids: $(($row | % DeviceId) -join ', ')); use -DeviceId" }
    $row = $row[0]
    $pt = Get-ListViewItemScreenPoint -Hwnd $h -Index $row.Index
    Invoke-MouseClick -X ($pt.Left + $TextOffsetX) -Y $pt.Y
    Start-Sleep -Milliseconds 700
    $sel = ([C4.ListView]::GetState($h, $row.Index) -band 2) -ne 0
    if (-not $sel) { throw "Clicked row $($row.Index) ('$($row.Name)') but it is not selected" }
    Get-ComposerDevices | Where-Object { $_.Index -eq $row.Index }
}

function Get-ComposerSelectedDevice { Get-ComposerDevices | Where-Object Selected | Select-Object -First 1 }

function Rename-ComposerDevice {
    # Rename a device in the System Design tree: select it, F2 (in-place label edit), type the new name, Enter.
    # Returns an object with Before/After names and whether any dialog appeared. Checks the tree row text afterwards.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$NewName, [string]$DeviceId, [int]$SettleMs = 1500)
    $row = if ($DeviceId) { Select-ComposerDevice -DeviceId $DeviceId } else { Select-ComposerDevice -Name $Name }
    $h = Get-ComposerTreeHandle
    Send-Keys '{F2}' 600
    $dlg = Get-ComposerDialog
    $editing = $false
    # the in-place editor is an 'Edit' child of the list view
    $edit = $script:A::FromHandle($h).FindFirst($script:Scope::Children, (New-Object System.Windows.Automation.PropertyCondition($script:A::ClassNameProperty, 'Edit')))
    if ($edit) { $editing = $true }
    if ($dlg -and $dlg.Current.Name -notlike 'Composer Pro*') { # some other dialog appeared; report it and bail out
        return [pscustomobject]@{ Before = $row.Name; After = $row.Name; DeviceId = $row.DeviceId; InPlaceEdit = $editing; Dialog = $dlg.Current.Name; DialogTree = (Get-ComposerTree -Root $dlg) }
    }
    $escaped = $NewName -replace '([+^%~(){}\[\]])', '{$1}'
    Send-Keys '^a' 100
    Send-Keys $escaped 200
    Send-Keys '{ENTER}' $SettleMs
    $dlg2 = Get-ComposerDialog
    $after = [C4.ListView]::GetText($h, $row.Index, 0)
    [pscustomobject]@{ Before = $row.Name; After = $after; DeviceId = $row.DeviceId; InPlaceEdit = $editing; Dialog = $(if ($dlg2) { $dlg2.Current.Name } else { $null }); DialogTree = $(if ($dlg2) { Get-ComposerTree -Root $dlg2 } else { $null }) }
}

Export-ModuleMember -Function *
