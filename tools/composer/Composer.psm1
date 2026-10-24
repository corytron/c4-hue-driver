# Composer.psm1 - drive Control4 Composer Pro 3.4.2 (WinForms) via UI Automation + SendInput.
# Tested on Windows 11 Pro, Windows PowerShell 5.1.  Import with:  Import-Module C:\c4-hue\Composer.psm1 -Force
# NOTE: a property edit reaches Director ONLY when the row's "Set" button is clicked (see Set-ComposerProperty);
#       Enter/blur just change the grid. Never tap ALT to foreground Composer (it arms the menu bar).
#
# Composer exposes every control to UIA as ControlType.Pane with NO patterns (no Invoke/Value/Selection),
# so this module READS through UIA (Name / ClassName / BoundingRectangle) and ACTS through real mouse and
# keyboard input at UIA-reported screen coordinates.
#
# Repo copy: updated 2026-10-24 from the Windows session's C:\c4-hue\Composer.psm1 (49,370 bytes, sha256
# b3dc42a491ae2471f00970d468e831fcd708e629b3b6766656e289eb5e0bbe31), which writes and exercises it through
# Composer rounds 1-20; the rules it follows are in docs/composer-remote.md. Not run on this VM.

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
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
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

function Get-ComposerMainHandle {
    # hwnd of Composer's real main window (title 'Composer Pro ...'). Process.MainWindowHandle is NOT reliable: while a
    # tooltip is showing, .NET reports the (topmost, unowned) tooltip window instead, and every UIA lookup then comes back empty.
    $p = Get-ComposerProcess
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:A::ProcessIdProperty, [int]$p.Id)
    foreach ($w in $script:A::RootElement.FindAll($script:Scope::Children, $cond)) {
        if ($w.Current.Name -like 'Composer Pro*') { return [IntPtr]$w.Current.NativeWindowHandle }
    }
    [IntPtr]$p.MainWindowHandle
}

function Get-ComposerWindow {
    # AutomationElement of Composer's main window.
    $el = $script:A::FromHandle((Get-ComposerMainHandle))
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
    $mainH = Get-ComposerMainHandle
    $main = [int]$mainH
    $winCond = New-Object System.Windows.Automation.PropertyCondition($script:A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    $mainEl = $script:A::FromHandle($mainH)
    # ignore unnamed windows (tooltips) - real dialogs have a title
    $owned = @($mainEl.FindAll($script:Scope::Children, $winCond) | Where-Object { $_.Current.Name -and $_.Current.Name -ne 'GlassPanelForm' })
    if ($owned.Count -gt 0) {
        # nested: a dialog opened from a dialog is a child of that dialog; descend to the deepest one
        $d = $owned[-1]
        while ($true) { $sub = @($d.FindAll($script:Scope::Children, $winCond)); if ($sub.Count -eq 0) { break }; $d = $sub[-1] }
        return $d
    }
    Get-ComposerTopWindows | Where-Object { $_.Current.NativeWindowHandle -ne $main -and $_.Current.Name -and $_.Current.Name -ne 'GlassPanelForm' } | Select-Object -First 1
}

function Wait-ComposerDialog {
    param([int]$TimeoutMs = 8000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) { $d = Get-ComposerDialog; if ($d) { return $d }; Start-Sleep -Milliseconds 250 }
    $null
}

function Show-Composer {
    # Bring Composer's main window to the foreground.
    # NEVER tap ALT here: a bare ALT press/release puts Composer's menu bar into keyboard mode, so the next ENTER sent to
    # the window activates a File-menu item (this once triggered "Clear Project"). Use AttachThreadInput instead.
    $h = Get-ComposerMainHandle
    if ([C4.Native]::IsIconic($h)) { [void][C4.Native]::ShowWindow($h, 9) }   # SW_RESTORE
    if ([C4.Native]::GetForegroundWindow() -eq $h) { return $true }
    $fg = [C4.Native]::GetForegroundWindow()
    $pidOut = [uint32]0
    $fgTid = [C4.Native]::GetWindowThreadProcessId($fg, [ref]$pidOut)
    $myTid = [C4.Native]::GetCurrentThreadId()
    [void][C4.Native]::AttachThreadInput($myTid, $fgTid, $true)
    try { [void][C4.Native]::SetForegroundWindow($h); [void][C4.Native]::BringWindowToTop($h) }
    finally { [void][C4.Native]::AttachThreadInput($myTid, $fgTid, $false) }
    Start-Sleep -Milliseconds 400
    ([C4.Native]::GetForegroundWindow() -eq $h)
}

function Save-ComposerShot {
    # Save a PNG of Composer's main window (or -Hwnd) to -Path. PrintWindow(PW_RENDERFULLCONTENT) works even when occluded;
    # -FromScreen copies the window rect from the screen instead (window must be in front; captures overlapping dialogs too).
    param([Parameter(Mandatory)][string]$Path, [IntPtr]$Hwnd = 0, [switch]$FromScreen)
    if ($Hwnd -eq 0) { $Hwnd = Get-ComposerMainHandle }
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
        $ri = { param($v) if ([double]::IsInfinity($v) -or [double]::IsNaN($v)) { -1 } else { [int]$v } }   # hidden shell elements report an infinite rect
        [pscustomobject]@{ Type = ($c.ControlType.ProgrammaticName -replace 'ControlType\.',''); Name = $c.Name
            Class = ($c.ClassName -replace 'WindowsForms10\.','' -replace '\.app\.0\.\S+',''); Id = $c.AutomationId
            X = (& $ri $r.X); Y = (& $ri $r.Y); W = (& $ri $r.Width); H = (& $ri $r.Height); Offscreen = $c.IsOffscreen }
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

function Invoke-MouseDrag {
    # Physical left-button drag from (X1,Y1) to (X2,Y2) in small steps (Composer's Connections view binds by drag & drop).
    param([Parameter(Mandatory)][int]$X1, [Parameter(Mandatory)][int]$Y1, [Parameter(Mandatory)][int]$X2, [Parameter(Mandatory)][int]$Y2, [int]$Steps = 25, [int]$StepMs = 20)
    [void][C4.Native]::SetCursorPos($X1, $Y1); Start-Sleep -Milliseconds 150
    [C4.Native]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 250     # LEFTDOWN
    for ($i = 1; $i -le $Steps; $i++) {
        [void][C4.Native]::SetCursorPos([int]($X1 + ($X2 - $X1) * $i / $Steps), [int]($Y1 + ($Y2 - $Y1) * $i / $Steps))
        Start-Sleep -Milliseconds $StepMs
    }
    Start-Sleep -Milliseconds 300
    [C4.Native]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)                                    # LEFTUP
    Start-Sleep -Milliseconds 400
}

function Move-MouseAway {
    # Park the cursor on Composer's status bar so no tooltip stays open over whatever was just clicked.
    $r = New-Object C4.Native+RECT; [void][C4.Native]::GetWindowRect((Get-ComposerMainHandle), [ref]$r)
    [void][C4.Native]::SetCursorPos([int](($r.Left + $r.Right) / 2), $r.Bottom - 12)
    Start-Sleep -Milliseconds 200
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
$script:TabOffsets = @{ 'Properties' = 36; 'Actions' = 97; 'Documentation' = 173; 'Lua' = 239 }   # measured on Composer Pro 3.4.2 @ 96 DPI; Documentation tab exists from driver build 125 (without it Lua sits at 144)

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
    const uint LVM_EDITLABELW = LVM_FIRST+118, LVM_GETEDITCONTROL = LVM_FIRST+24, WM_SETTEXT = 0x000C, WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, StringBuilder l);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    // Begin in-place label editing of an item; returns the editor's hwnd (0 if the control refused, e.g. it lacks focus).
    public static IntPtr EditLabel(IntPtr h, int item) { return SendMessage(h, LVM_EDITLABELW, (IntPtr)item, IntPtr.Zero); }
    public static IntPtr GetEditControl(IntPtr h) { return SendMessage(h, LVM_GETEDITCONTROL, IntPtr.Zero, IntPtr.Zero); }
    public static void SetWindowText(IntPtr h, string text) { SendMessage(h, WM_SETTEXT, IntPtr.Zero, text); }
    public static string GetWindowText(IntPtr h) { int n = (int)SendMessage(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero); var sb = new StringBuilder(n + 1); SendMessage(h, WM_GETTEXT, (IntPtr)(n + 1), sb); return sb.ToString(); }
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
    # A click on an ALREADY selected row starts the in-place rename editor (slow second click), so by default an
    # already-selected row is not clicked again; -Force clicks anyway.
    param([string]$Name, [string]$DeviceId, [int]$TextOffsetX = 125, [switch]$Force)
    $h = Get-ComposerTreeHandle
    $rows = Get-ComposerDevices
    $row = if ($DeviceId) { $rows | Where-Object { $_.DeviceId -eq $DeviceId } } else { $rows | Where-Object { $_.Name -eq $Name } }
    $row = @($row)
    if ($row.Count -eq 0) { throw "Device '$Name$DeviceId' not found in tree" }
    if ($row.Count -gt 1) { throw "Device name '$Name' is ambiguous (ids: $(($row | % DeviceId) -join ', ')); use -DeviceId" }
    $row = $row[0]
    if ($row.Selected -and -not $Force) { return $row }
    $pt = Get-ListViewItemScreenPoint -Hwnd $h -Index $row.Index
    Invoke-MouseClick -X ($pt.Left + $TextOffsetX) -Y $pt.Y
    Move-MouseAway   # otherwise a hover tooltip pops up over the tree and confuses window lookups
    Start-Sleep -Milliseconds 700
    $sel = ([C4.ListView]::GetState($h, $row.Index) -band 2) -ne 0
    if (-not $sel) { throw "Clicked row $($row.Index) ('$($row.Name)') but it is not selected" }
    Get-ComposerDevices | Where-Object { $_.Index -eq $row.Index }
}

function Get-ComposerSelectedDevice { Get-ComposerDevices | Where-Object Selected | Select-Object -First 1 }

function Rename-ComposerDevice {
    # Rename a device in the System Design tree: select it, F2 (in-place label edit), type the new name, Enter.
    # Returns an object with Before/After names and whether any dialog appeared. Checks the tree row text afterwards.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$NewName, [string]$DeviceId, [int]$SettleMs = 1500, [int]$TextOffsetX = 125)
    # How Composer's tree rename really works (learned 2026-10-21): the editor is a WinForms TextBox (class
    # WindowsForms10.EDIT) that Composer itself places over the row as a CHILD of the SysListView32. It is NOT the
    # native label editor, so LVM_EDITLABEL / LVM_GETEDITCONTROL return 0 and Ctrl+A does nothing in it. It opens on F2
    # (tree focused) or on a slow second click of the already-selected row. Commit = Enter with focus in the editor.
    $edit = Get-ComposerTreeEditor
    $method = 'already-open'
    if (-not $edit) {
        # click the row (selects it and gives the tree keyboard focus; on an already-selected row this is the "slow second click")
        $row = if ($DeviceId) { Select-ComposerDevice -DeviceId $DeviceId -Force } else { Select-ComposerDevice -Name $Name -Force }
        Start-Sleep -Milliseconds 900
        $edit = Get-ComposerTreeEditor; $method = 'click'
    } else { $row = if ($DeviceId) { Select-ComposerDevice -DeviceId $DeviceId } else { Select-ComposerDevice -Name $Name } }
    $h = Get-ComposerTreeHandle
    if (-not $edit) { Send-KeysTo -ExpectedHwnd $h -Keys '{F2}' -DelayMs 600; $edit = Get-ComposerTreeEditor; $method = 'F2' }
    if (-not $edit) {   # slow second click on the selected row's label
        $pt = Get-ListViewItemScreenPoint -Hwnd $h -Index $row.Index
        Invoke-MouseClick -X ($pt.Left + $TextOffsetX) -Y $pt.Y; Move-MouseAway; Start-Sleep -Milliseconds 900
        $edit = Get-ComposerTreeEditor; $method = 'second-click'
    }
    if (-not $edit) {
        $dlg = Get-ComposerDialog
        return [pscustomobject]@{ Before = $row.Name; After = $row.Name; DeviceId = $row.DeviceId; Method = 'none'; Dialog = $(if ($dlg) { $dlg.Current.Name } else { $null }); DialogTree = $(if ($dlg) { Get-ComposerTree -Root $dlg } else { $null }) }
    }
    $eh = [IntPtr]$edit.Current.NativeWindowHandle
    [C4.ListView]::SetWindowText($eh, $NewName); Start-Sleep -Milliseconds 150
    $typed = [C4.ListView]::GetWindowText($eh)
    $r = $edit.Current.BoundingRectangle
    Invoke-MouseClick -X ([int]($r.X + $r.Width - 15)) -Y ([int]($r.Y + $r.Height / 2))   # make sure keyboard focus is in the editor
    Send-KeysTo -ExpectedHwnd $eh -Keys '{ENTER}' -DelayMs $SettleMs   # refuses if focus/menu/dialog state is not as expected
    Move-MouseAway
    $dlg2 = Get-ComposerDialog
    $after = [C4.ListView]::GetText($h, $row.Index, 0)
    [pscustomobject]@{ Before = $row.Name; After = $after; DeviceId = $row.DeviceId; Method = $method; EditorText = $typed; Dialog = $(if ($dlg2) { $dlg2.Current.Name } else { $null }); DialogTree = $(if ($dlg2) { Get-ComposerTree -Root $dlg2 } else { $null }) }
}

function Get-ComposerTreeEditor {
    # The in-place rename TextBox over the System Design tree, if one is open (UIA element), else $null.
    $h = Get-ComposerTreeHandle
    $lv = $script:A::FromHandle($h)
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:A::ClassNameProperty, 'WindowsForms10.EDIT.app.0.3309ded_r7_ad1')
    $e = $lv.FindFirst($script:Scope::Children, $cond)
    if (-not $e) { $e = Find-ComposerElements -Class 'EDIT' -Root $lv | Select-Object -First 1 }
    $e
}

# ---- Keyboard-focus guard (standing rule: never send a keystroke unless the intended control has focus and no menu is active) ----
if (-not ('C4.Focus' -as [type])) {
Add-Type -Namespace C4 -Name Focus -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO { public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret; public int l,t,r,b; }
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint id, ref GUITHREADINFO g);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@
}

function Get-ComposerFocus {
    # Focus state of Composer's UI thread: FocusHwnd, FocusClass, MenuActive (GUI_INMENUMODE or a menu owner), ActiveHwnd.
    $h = Get-ComposerMainHandle
    $pid2 = [uint32]0; $tid = [C4.Focus]::GetWindowThreadProcessId($h, [ref]$pid2)
    $g = New-Object C4.Focus+GUITHREADINFO; $g.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($g)
    [void][C4.Focus]::GetGUIThreadInfo($tid, [ref]$g)
    $sb = New-Object Text.StringBuilder 256; [void][C4.Focus]::GetClassName($g.hwndFocus, $sb, 256)
    [pscustomobject]@{ FocusHwnd = $g.hwndFocus; FocusClass = $sb.ToString(); MenuActive = (($g.flags -band 0x4) -ne 0 -or $g.hwndMenuOwner -ne [IntPtr]::Zero); ActiveHwnd = $g.hwndActive; Flags = $g.flags }
}

function Send-KeysTo {
    # Send keystrokes ONLY if Composer's focused control is $ExpectedHwnd and no menu is active; otherwise throw without sending.
    param([Parameter(Mandatory)][IntPtr]$ExpectedHwnd, [Parameter(Mandatory)][string]$Keys, [int]$DelayMs = 150, [switch]$NoDialogCheck)
    $f = Get-ComposerFocus
    if ($f.MenuActive) { throw "Refusing to send '$Keys': a menu is active (flags=$($f.Flags))" }
    if ($f.FocusHwnd -ne $ExpectedHwnd) { throw "Refusing to send '$Keys': focus is on hwnd $($f.FocusHwnd) ($($f.FocusClass)), expected $ExpectedHwnd" }
    if (-not $NoDialogCheck -and $Keys -match 'ENTER|~') {
        $d = Get-ComposerDialog
        if ($d -and $d.Current.NativeWindowHandle -ne $ExpectedHwnd) {
            $own = $script:A::FromHandle($ExpectedHwnd); $inside = $false
            try { $p = $script:Raw.GetParent($own); while ($p) { if ($p.Current.NativeWindowHandle -eq $d.Current.NativeWindowHandle) { $inside = $true; break }; $p = $script:Raw.GetParent($p) } } catch {}
            if (-not $inside) { throw "Refusing to send Enter: unexpected dialog '$($d.Current.Name)' is open" }
        }
    }
    Send-Keys -Keys $Keys -DelayMs $DelayMs
}

function Assert-ComposerUnchanged {
    # Verify window title and tree row count against a baseline (from Get-ComposerBaseline).
    param([Parameter(Mandatory)]$Baseline)
    $title = (Get-ComposerWindow).Current.Name
    $rows = [C4.ListView]::GetCount((Get-ComposerTreeHandle))
    $ok = ($title -eq $Baseline.Title -and $rows -eq $Baseline.Rows)
    [pscustomobject]@{ Ok = $ok; Title = $title; Rows = $rows; ExpectedTitle = $Baseline.Title; ExpectedRows = $Baseline.Rows }
}

function Get-ComposerBaseline { [pscustomobject]@{ Title = (Get-ComposerWindow).Current.Name; Rows = [C4.ListView]::GetCount((Get-ComposerTreeHandle)) } }


# ---- Round-3 helpers ----
function Get-ComposerBridgeStatus {
    # Select the 'Hue Bridge' device, show its Properties tab and return the full property table.
    param([string]$BridgeName = 'Hue Bridge')
    [void](Select-ComposerDevice -Name $BridgeName)
    Start-Sleep -Milliseconds 500
    $page = $script:Raw.GetFirstChild((Get-ComposerTabControl))
    if ($page.Current.Name -ne 'Properties') { Select-ComposerTab -Name 'Properties'; Start-Sleep -Milliseconds 600 }
    Get-ComposerProperties
}

function Format-BridgeStatus {
    param($Props, [string[]]$Keys = @('Last Action', 'Attention', 'Lights', 'Room Mappings'))
    foreach ($k in $Keys) { "  $k = $($Props[$k])" }
}

function Set-ComposerActionParameter {
    # In the open 'Action Parameter List' dialog: open the picker beside -Label and choose -Item (exact text).
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Item)
    $s = Open-ComposerPicker -Label $Label
    if (-not $s) { throw "Picker for '$Label' did not open" }
    $ok = Select-ComposerPickerItem -Text $Item
    if (-not $ok) { throw "Picker for '$Label' did not close after choosing '$Item'" }
    Start-Sleep -Milliseconds 300
    (Get-ComposerParameterValues)[$Label]
}

function Confirm-ComposerDialog {
    # Click a named button (OK / Yes) on the current dialog. Returns $true when that dialog closed.
    param([string]$Button = 'OK')
    $d = Get-ComposerDialog
    if (-not $d) { throw "No dialog open" }
    $h = $d.Current.NativeWindowHandle
    $b = Find-ComposerElements -Class 'BUTTON' -Name $Button -Root $d | Select-Object -First 1
    if (-not $b) { $b = Find-ComposerElements -Class 'Button' -Name $Button -Root $d | Select-Object -First 1 }
    if (-not $b) { throw "Button '$Button' not found on dialog '$($d.Current.Name)'" }
    Invoke-ElementClick -Element $b; Start-Sleep -Milliseconds 600
    $now = Get-ComposerDialog
    (-not $now -or $now.Current.NativeWindowHandle -ne $h)
}

function Get-ComposerDialogText {
    # All non-empty Static/label texts of the current dialog (for quoting prompts).
    $d = Get-ComposerDialog
    if (-not $d) { return $null }
    (Find-ComposerElements -Root $d | Get-ComposerElementInfo | Where-Object { $_.Name -and $_.Class -notlike '*Button*' -and $_.Class -notlike '*BUTTON*' } | ForEach-Object Name) -join ' | '
}

function Request-ComposerDeviceDelete {
    # Select a device in the tree and press Delete. Does NOT confirm: returns the dialog (title + text + buttons) that appears.
    param([string]$Name, [string]$DeviceId)
    $row = if ($DeviceId) { Select-ComposerDevice -DeviceId $DeviceId } else { Select-ComposerDevice -Name $Name }
    if (-not $row.Selected) { throw "Device not selected" }
    $h = Get-ComposerTreeHandle
    if ((Get-ComposerFocus).FocusHwnd -ne $h) {   # give the tree keyboard focus without re-clicking the selected row (that would open the editor)
        [void](Select-ComposerDevice -DeviceId $row.DeviceId -Force -TextOffsetX 300); Start-Sleep -Milliseconds 300
        if (Get-ComposerTreeEditor) { throw "Rename editor opened unexpectedly; aborting delete" }
    }
    Send-KeysTo -ExpectedHwnd $h -Keys '{DELETE}' -DelayMs 800
    $d = Wait-ComposerDialog -TimeoutMs 5000
    [pscustomobject]@{ Device = $row; Dialog = $(if ($d) { $d.Current.Name } else { $null }); Text = (Get-ComposerDialogText); Buttons = $(if ($d) { (Find-ComposerElements -Root $d | Get-ComposerElementInfo | Where-Object { $_.Class -like '*utton*' } | ForEach-Object Name) -join ' | ' } else { $null }) }
}

function Set-ComposerProperty {
    # Change a property on the current Properties page AND commit it. Composer only sends a changed value to Director
    # when the row's "Set" button (which appears beside the value, with "Cancel", once the value differs) is clicked;
    # Enter / blur alone leave the grid showing the new value while Director keeps the old one.
    # -List: a LIST property (combo box) is stepped with Down/Up until -Value shows; otherwise the text field is retyped.
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Value, [switch]$List, [int]$SettleMs = 3000)
    $pg = Find-ComposerElements -Name 'Properties' -Class 'Window.8' | Where-Object { $_.Current.BoundingRectangle.Height -gt 100 } | Select-Object -First 1
    if (-not $pg) { throw "Properties page not shown" }
    $lbl = Find-ComposerElements -Class 'EDIT' -Name $Label -Root $pg | Select-Object -First 1
    if (-not $lbl) { throw "Property '$Label' not found" }
    $ly = [int]$lbl.Current.BoundingRectangle.Y
    $cls = if ($List) { 'COMBOBOX' } else { 'EDIT' }
    $ctl = Find-ComposerElements -Class $cls -Root $pg | Where-Object { [int]$_.Current.BoundingRectangle.X -gt ([int]$pg.Current.BoundingRectangle.X + 180) -and [math]::Abs([int]$_.Current.BoundingRectangle.Y - $ly) -le 8 } | Select-Object -First 1
    if (-not $ctl) { throw "Value control for '$Label' not found" }
    $h = [IntPtr]$ctl.Current.NativeWindowHandle; $r = $ctl.Current.BoundingRectangle
    $before = [C4.ListView]::GetWindowText($h)
    Invoke-MouseClick -X ([int]($r.X + $r.Width - 10)) -Y ([int]($r.Y + $r.Height / 2)); Start-Sleep -Milliseconds 500
    $f = $null
    for ($try = 0; $try -lt 6; $try++) { $f = Get-ComposerFocus; if ($f.FocusHwnd -eq $h) { break }; Start-Sleep -Milliseconds 300 }   # focus can read 0 for a moment while the list drops
    if ($f.FocusHwnd -ne $h -or $f.MenuActive) { throw "Value control for '$Label' did not take focus (focus=$($f.FocusHwnd) menu=$($f.MenuActive))" }
    if ($List) {
        for ($i = 0; $i -lt 8; $i++) {
            $cur = [C4.ListView]::GetWindowText($h); if ($cur -eq $Value) { break }
            Send-KeysTo -ExpectedHwnd $h -Keys '{DOWN}' -DelayMs 250
            if ([C4.ListView]::GetWindowText($h) -eq $cur) { Send-KeysTo -ExpectedHwnd $h -Keys '{HOME}' -DelayMs 250 }   # wrapped: start over from the top
        }
        if ([C4.ListView]::GetWindowText($h) -ne $Value) { Send-KeysTo -ExpectedHwnd $h -Keys '{ESC}' -DelayMs 200; throw "List item '$Value' not reachable for '$Label'" }
    } else {
        Send-KeysTo -ExpectedHwnd $h -Keys '{HOME}+{END}' -DelayMs 150
        Send-KeysTo -ExpectedHwnd $h -Keys ($Value -replace '([+^%~(){}\[\]])', '{$1}') -DelayMs 250
    }
    Send-KeysTo -ExpectedHwnd $h -Keys '{ENTER}' -DelayMs 500
    Move-MouseAway
    $set = Find-ComposerElements -Class 'BUTTON' -Name 'Set' -Root $pg | Select-Object -First 1
    $committed = $false
    if ($set) { Invoke-ElementClick -Element $set; Move-MouseAway; $committed = $true }
    Start-Sleep -Milliseconds $SettleMs
    [pscustomobject]@{ Label = $Label; Before = $before; Requested = $Value; After = (Get-ComposerProperty -Name $Label); SetButtonSeen = ($set -ne $null); Committed = $committed; SetButtonLeft = ((Find-ComposerElements -Class 'BUTTON' -Name 'Set' -Root $pg | Measure-Object).Count -gt 0) }
}

# ---- Documentation screenshots (round 12): unscaled PNG crops of a screen rectangle / UIA element / property row ----
function Save-RegionShot {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [Parameter(Mandatory)][int]$W, [Parameter(Mandatory)][int]$H)
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H)); $g.Dispose()
    $dir = Split-Path $Path; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Get-Item $Path
}

function Save-ElementShot {
    # Crop to a UIA element's BoundingRectangle (+ -Margin px on each side), or to the union of several elements.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Element, [int]$Margin = 0)
    $els = @($Element); $x1 = 1e9; $y1 = 1e9; $x2 = -1e9; $y2 = -1e9
    foreach ($e in $els) { $r = $e.Current.BoundingRectangle; if ($r.X -lt $x1) { $x1 = $r.X }; if ($r.Y -lt $y1) { $y1 = $r.Y }; if (($r.X + $r.Width) -gt $x2) { $x2 = $r.X + $r.Width }; if (($r.Y + $r.Height) -gt $y2) { $y2 = $r.Y + $r.Height } }
    Save-RegionShot -Path $Path -X ([int]($x1 - $Margin)) -Y ([int]($y1 - $Margin)) -W ([int]($x2 - $x1 + 2 * $Margin)) -H ([int]($y2 - $y1 + 2 * $Margin))
}

function Save-PropertyRowShot {
    # Crop one Properties row (label + value + any Set/Cancel buttons on that row) with a small margin.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label, [int]$Margin = 6)
    $pg = Find-ComposerElements -Name 'Properties' -Class 'Window.8' | Where-Object { $_.Current.BoundingRectangle.Height -gt 100 } | Select-Object -First 1
    $lbl = Find-ComposerElements -Class 'EDIT' -Name $Label -Root $pg | Select-Object -First 1
    if (-not $lbl) { throw "Property '$Label' not found" }
    $ly = [int]$lbl.Current.BoundingRectangle.Y
    $row = @($lbl) + @(Find-ComposerElements -Root $pg | Where-Object { $c = $_.Current; ($c.ClassName -like '*EDIT*' -or $c.ClassName -like '*COMBOBOX*' -or $c.ClassName -like '*BUTTON*') -and [math]::Abs([int]$c.BoundingRectangle.Y - $ly) -le 10 })
    Save-ElementShot -Path $Path -Element $row -Margin $Margin
}

function Send-DocShot {
    # Upload a PNG from C:\c4-hue\shots\doc\ to the Ubuntu dev server (PUT http://192.0.2.7:8090/img/<name>); returns the server's reply.
    param([Parameter(Mandatory)][string]$Name, [string]$Server = 'http://192.0.2.7:8090')
    $p = "C:\c4-hue\shots\doc\$Name"
    $r = Invoke-WebRequest -Method Put -InFile $p -Uri "$Server/img/$Name" -UseBasicParsing -TimeoutSec 60
    [pscustomobject]@{ Name = $Name; Bytes = (Get-Item $p).Length; Status = $r.StatusCode; Reply = ($r.Content -as [string]).Trim() }
}

# ---- Foreground-checked clicks (rule from round 18c: never click unless the intended window is foreground and contains the point) ----
if (-not ('C4.Win' -as [type])) {
Add-Type -Namespace C4 -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
}

function Show-AnyWindow {
    # Bring a top-level window to the foreground without ALT (AttachThreadInput + SetForegroundWindow). Returns $true when it is foreground.
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    if ([C4.Native]::IsIconic($Hwnd)) { [void][C4.Native]::ShowWindow($Hwnd, 9) }
    if ([C4.Native]::GetForegroundWindow() -eq $Hwnd) { return $true }
    $fg = [C4.Native]::GetForegroundWindow(); $pidOut = [uint32]0
    $fgTid = [C4.Native]::GetWindowThreadProcessId($fg, [ref]$pidOut); $myTid = [C4.Native]::GetCurrentThreadId()
    [void][C4.Native]::AttachThreadInput($myTid, $fgTid, $true)
    try { [void][C4.Native]::SetForegroundWindow($Hwnd); [void][C4.Native]::BringWindowToTop($Hwnd) } finally { [void][C4.Native]::AttachThreadInput($myTid, $fgTid, $false) }
    Start-Sleep -Milliseconds 400
    ([C4.Native]::GetForegroundWindow() -eq $Hwnd)
}

function Invoke-SafeClick {
    # Click (X,Y) only if top-level window -Hwnd is the foreground window and the point lies inside its rectangle.
    # Tries once to bring it forward; throws (without clicking) otherwise.
    param([Parameter(Mandatory)][IntPtr]$Hwnd, [Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [switch]$Right, [switch]$Double)
    $r = New-Object C4.Native+RECT; [void][C4.Native]::GetWindowRect($Hwnd, [ref]$r)
    if ($X -lt $r.Left -or $X -ge $r.Right -or $Y -lt $r.Top -or $Y -ge $r.Bottom) { throw "Refusing click at ($X,$Y): outside window $Hwnd rect $($r.Left),$($r.Top),$($r.Right),$($r.Bottom)" }
    $fgRoot = [C4.Win]::GetAncestor([C4.Native]::GetForegroundWindow(), 2)   # GA_ROOT
    if ($fgRoot -ne $Hwnd) { [void](Show-AnyWindow -Hwnd $Hwnd); $fgRoot = [C4.Win]::GetAncestor([C4.Native]::GetForegroundWindow(), 2) }
    if ($fgRoot -ne $Hwnd) { throw "Refusing click at ($X,$Y): window $Hwnd is not in the foreground (foreground root = $fgRoot)" }
    Invoke-MouseClick -X $X -Y $Y -Right:$Right -Double:$Double
}

Export-ModuleMember -Function *
