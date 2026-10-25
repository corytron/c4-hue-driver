# Shots.ps1 - retake the owner's manual screenshots from the live Composer without showing the house
# (issue #61; the plan, the neutral example texts and the run steps are in docs/screenshots-plan.md).
#
# Windows PowerShell 5.1 on the Windows VM, Composer Pro open on the house project, not elevated:
#     Import-Module C:\c4-hue\Composer.psm1 -Force
#     . C:\c4-hue\Shots.ps1
#     Initialize-Shots -Root C:\c4-hue\shots
#     Invoke-ShotPlan -Path C:\c4-hue\shots\plan.json -Devices @{ ZONE_LIGHT = '...'; SCENE = '...' } -Ocr
#
# What it does: crops each picture to the driver's own pane or dialog (never the main window's title bar,
# status bar or device tree), reads every text inside the crop through UI Automation and the list-view and
# list-box messages, over-paints the house-specific ones with the plan's neutral texts in the font Composer
# itself used (measured, not guessed), and writes a ledger of every text the finished PNG shows.
# What it never does: change the project. It selects devices and tabs, opens and cancels dialogs, drop-down
# lists and menus; two optional steps (EditValue + CancelEdit, RunAction) run only when the plan allows them.
#
# Files: <root>\raw\  the unedited captures and deny details (house data: stay on this VM, never uploaded)
#        <root>\doc\  finished PNGs and their .txt ledgers (the only folder that is sent back)
#        <root>\hold\ finished PNGs with a text nobody reviewed or a deny hit (fix the plan, run the row again)
#
# Uses Composer.psm1 for everything it already does (finding elements, devices, tabs, actions, pickers,
# dialogs, safe clicks, keys into a verified target, region captures); adds only what it lacks.
# ASCII only on purpose: Windows PowerShell 5.1 reads a file without BOM as ANSI, so the few non-ASCII
# characters the driver writes are built from their code points ($script:ShotChars).

Set-StrictMode -Off
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing

if (-not (Get-Command Get-ComposerWindow -ErrorAction SilentlyContinue)) {
    throw "Import Composer.psm1 first:  Import-Module C:\c4-hue\Composer.psm1 -Force"
}

$script:ShotRoot      = 'C:\c4-hue\shots'
$script:ShotFamilies  = @('Segoe UI', 'Microsoft Sans Serif', 'Tahoma')   # candidates for the font match, Segoe UI first
$script:ShotInk       = 48            # a pixel is ink when its R+G+B distance from the background exceeds this
$script:ShotFonts     = @{}           # font-match cache, see Set-TextReplacement
$script:ShotCmp       = [StringComparer]::OrdinalIgnoreCase
$script:ShotReplaced  = New-Object 'System.Collections.Generic.HashSet[string]' ($script:ShotCmp)   # originals painted over (house data, memory only)
$script:ShotNeutral   = New-Object 'System.Collections.Generic.HashSet[string]' ($script:ShotCmp)   # tokens of the neutral texts
$script:ShotDenyTerms = New-Object 'System.Collections.Generic.HashSet[string]' ($script:ShotCmp)   # house names (memory only)
$script:ShotA         = [System.Windows.Automation.AutomationElement]
$script:ShotScope     = [System.Windows.Automation.TreeScope]
$script:ShotWalker    = [System.Windows.Automation.TreeWalker]::RawViewWalker
$script:ShotChars     = @{ Arrow = [string][char]0x2192; LowComma = [string][char]0x201A; Ellipsis = [string][char]0x2026 }
$script:ShotEdit      = $null         # the value an EditValue step replaced, for CancelEdit's check
$script:ShotDenyPhrases = @(); $script:ShotDenySig = ''   # Get-ShotDenyPhrases' cache

# ---- Compiled helpers: window geometry, list geometry, pixels, text rendering and the font match ----
if (-not ('C4.Shots' -as [type])) {
Add-Type -Language CSharp -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace C4 {
public class FontMatch {
    public string Family; public float Size; public bool Bold; public int Renderer;   // Renderer 0 GDI (TextRenderer), 1 GDI+ ClearTypeGridFit, 2 GDI+ AntiAliasGridFit
    public int OriginX; public int OriginY; public int OffsetX; public int OffsetY;  // text origin in the image; and relative to the region it was measured in
    public double Score; public int Background; public int Foreground;
}

public static class Shots {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct COMBOBOXINFO { public int cbSize; public RECT rcItem; public RECT rcButton; public int stateButton; public IntPtr hwndCombo; public IntPtr hwndItem; public IntPtr hwndList; }
    [StructLayout(LayoutKind.Sequential)] public struct SCROLLBARINFO { public int cbSize; public RECT rcScrollBar; public int dxyLineButton; public int xyThumbTop; public int xyThumbBottom; public int reserved; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public int[] rgstate; }
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT rect, int points);
    [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr hwnd, ref COMBOBOXINFO info);
    [DllImport("user32.dll")] static extern bool GetScrollBarInfo(IntPtr hwnd, int idObject, ref SCROLLBARINFO info);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, uint size, uint type, uint prot);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, uint size, uint type);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, uint size, out IntPtr written);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, uint size, out IntPtr read);

    static int[] Xywh(RECT r) { return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top }; }
    static int Msg(IntPtr h, uint msg, int w) { return (int)(long)SendMessage(h, msg, (IntPtr)w, IntPtr.Zero); }

    // ---- window and control geometry (screen x, y, w, h) ----
    // The visible frame of a top-level window: Windows 10/11 add invisible resize borders to GetWindowRect.
    public static int[] FrameBounds(IntPtr hwnd) {
        RECT r;
        if (DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf(typeof(RECT))) == 0 && r.Right > r.Left) return Xywh(r);   // DWMWA_EXTENDED_FRAME_BOUNDS
        if (GetWindowRect(hwnd, out r)) return Xywh(r);
        return null;
    }
    public static int[] ClientBounds(IntPtr hwnd) {
        RECT r; if (!GetClientRect(hwnd, out r)) return null;
        MapWindowPoints(hwnd, IntPtr.Zero, ref r, 2); return Xywh(r);
    }
    // A combo box: [0..3] the face (text area), [4..7] the drop-down button, [8] the hwnd of its drop-down list.
    public static long[] ComboParts(IntPtr hwnd) {
        COMBOBOXINFO ci = new COMBOBOXINFO(); ci.cbSize = Marshal.SizeOf(typeof(COMBOBOXINFO));
        if (!GetComboBoxInfo(hwnd, ref ci)) return null;
        RECT a = ci.rcItem, b = ci.rcButton;
        MapWindowPoints(hwnd, IntPtr.Zero, ref a, 2); MapWindowPoints(hwnd, IntPtr.Zero, ref b, 2);
        return new long[] { a.Left, a.Top, a.Right - a.Left, a.Bottom - a.Top, b.Left, b.Top, b.Right - b.Left, b.Bottom - b.Top, ci.hwndList.ToInt64() };
    }
    // A window's own scroll bar while it is shown, else null (OBJID_VSCROLL -5, OBJID_HSCROLL -6).
    public static int[] ScrollBar(IntPtr hwnd, bool vertical) {
        SCROLLBARINFO si = new SCROLLBARINFO(); si.rgstate = new int[6]; si.cbSize = Marshal.SizeOf(typeof(SCROLLBARINFO));
        if (!GetScrollBarInfo(hwnd, vertical ? -5 : -6, ref si)) return null;
        if ((si.rgstate[0] & 0x18000) != 0) return null;                                   // invisible or offscreen
        if (si.rcScrollBar.Right <= si.rcScrollBar.Left || si.rcScrollBar.Bottom <= si.rcScrollBar.Top) return null;
        return Xywh(si.rcScrollBar);
    }

    // ---- list view (cross-process; Composer is 32-bit, a RECT is 16 bytes either way) ----
    static RECT RemoteRect(IntPtr h, uint msg, int wParam, RECT init) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        IntPtr p = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (p == IntPtr.Zero) throw new Exception("OpenProcess failed");
        IntPtr mem = VirtualAllocEx(p, IntPtr.Zero, 16, 0x3000, 0x04);
        try {
            byte[] b = new byte[16]; IntPtr n;
            BitConverter.GetBytes(init.Left).CopyTo(b, 0); BitConverter.GetBytes(init.Top).CopyTo(b, 4);
            BitConverter.GetBytes(init.Right).CopyTo(b, 8); BitConverter.GetBytes(init.Bottom).CopyTo(b, 12);
            WriteProcessMemory(p, mem, b, 16, out n);
            SendMessage(h, msg, (IntPtr)wParam, mem);
            ReadProcessMemory(p, mem, b, 16, out n);
            RECT r; r.Left = BitConverter.ToInt32(b, 0); r.Top = BitConverter.ToInt32(b, 4); r.Right = BitConverter.ToInt32(b, 8); r.Bottom = BitConverter.ToInt32(b, 12);
            return r;
        } finally { VirtualFreeEx(p, mem, 0, 0x8000); CloseHandle(p); }
    }
    // An item's rectangle on screen: part 0 the whole row (LVIR_BOUNDS), 2 the text (LVIR_LABEL); sub > 0 one column.
    public static int[] ListItemRect(IntPtr h, int item, int sub, int part) {
        RECT init = new RECT(); init.Left = part; init.Top = sub;
        RECT r = sub > 0 ? RemoteRect(h, 0x1000 + 56, item, init) : RemoteRect(h, 0x1000 + 14, item, init);   // LVM_GETSUBITEMRECT / LVM_GETITEMRECT
        MapWindowPoints(h, IntPtr.Zero, ref r, 2);
        return Xywh(r);
    }
    public static int ListColumnCount(IntPtr h) {
        IntPtr hdr = SendMessage(h, 0x1000 + 31, IntPtr.Zero, IntPtr.Zero);                 // LVM_GETHEADER
        if (hdr == IntPtr.Zero) return 1;
        int n = Msg(hdr, 0x1200, 0);                                                         // HDM_GETITEMCOUNT
        return n < 1 ? 1 : n;
    }
    // ---- a dropped combo list (class ComboLBox): no pointers involved, so plain messages work cross-process ----
    public static int ListBoxCount(IntPtr h) { return Msg(h, 0x018B, 0); }        // LB_GETCOUNT
    public static int ListBoxTopIndex(IntPtr h) { return Msg(h, 0x018E, 0); }     // LB_GETTOPINDEX
    public static int ListBoxCurSel(IntPtr h) { return Msg(h, 0x0188, 0); }       // LB_GETCURSEL
    public static int ListBoxItemHeight(IntPtr h) { return Msg(h, 0x01A1, 0); }   // LB_GETITEMHEIGHT

    // ---- pixels ----
    public static Rectangle Clip(Bitmap bmp, Rectangle r) { r.Intersect(new Rectangle(0, 0, bmp.Width, bmp.Height)); return r; }
    public static int[] Read(Bitmap bmp, Rectangle r) {
        r = Clip(bmp, r);
        if (r.Width <= 0 || r.Height <= 0) return new int[0];
        BitmapData d = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int[] px = new int[r.Width * r.Height];
            for (int y = 0; y < r.Height; y++) Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), px, y * r.Width, r.Width);
            return px;
        } finally { bmp.UnlockBits(d); }
    }
    public static int Dist(int a, int b) {
        return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)) + Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)) + Math.Abs((a & 255) - (b & 255));
    }
    public static int Mode(int[] px) {
        Dictionary<int, int> c = new Dictionary<int, int>(); int best = 0, bestN = -1;
        foreach (int v in px) { int n; c.TryGetValue(v, out n); n++; c[v] = n; if (n > bestN) { bestN = n; best = v; } }
        return best;
    }
    // The text colour: the most frequent of the pixels farthest from the background (ClearType fringes are not).
    public static int InkColor(int[] px, int bg) {
        int max = 0; foreach (int v in px) { int d = Dist(v, bg); if (d > max) max = d; }
        if (max == 0) return bg;
        Dictionary<int, int> c = new Dictionary<int, int>(); int best = bg, bestN = -1;
        foreach (int v in px) { if (Dist(v, bg) * 10 < max * 8) continue; int n; c.TryGetValue(v, out n); n++; c[v] = n; if (n > bestN) { bestN = n; best = v; } }
        return best;
    }
    // Bounding box {x0, y0, x1, y1} (inclusive) of the ink, ignoring rows and columns that are ink almost end to
    // end (a control's border or a grid line, not a glyph); null when there is no ink.
    public static int[] InkBox(int[] px, int w, int h, int bg, int thr) {
        if (w <= 0 || h <= 0 || px.Length < w * h) return null;
        bool[] ink = new bool[w * h]; int[] rows = new int[h]; int[] cols = new int[w];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            if (Dist(px[y * w + x], bg) > thr) { ink[y * w + x] = true; rows[y]++; cols[x]++; }
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        for (int y = 0; y < h; y++) {
            if (w >= 8 && rows[y] * 100 > w * 95) continue;
            for (int x = 0; x < w; x++) {
                if (!ink[y * w + x] || (h >= 8 && cols[x] * 100 > h * 95)) continue;
                if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
            }
        }
        if (x1 < 0) return null;
        return new int[] { x0, y0, x1, y1 };
    }
    // {hasInk, background, ink colour, x0, y0, x1, y1} of a region, coordinates in the image.
    public static int[] Probe(Bitmap img, Rectangle r, int thr) {
        r = Clip(img, r);
        if (r.Width < 1 || r.Height < 1) return null;
        int[] px = Read(img, r); int bg = Mode(px); int fg = InkColor(px, bg);
        int[] b = InkBox(px, r.Width, r.Height, bg, thr);
        if (b == null) return new int[] { 0, bg, fg, 0, 0, 0, 0 };
        return new int[] { 1, bg, fg, r.X + b[0], r.Y + b[1], r.X + b[2], r.Y + b[3] };
    }

    // ---- bitmaps ----
    // An exact 24-bit copy of a part of an image (no alpha: GDI text drawn on 32-bit ARGB loses its alpha).
    public static Bitmap Copy24(Bitmap src, Rectangle part) {
        Bitmap dst = new Bitmap(part.Width, part.Height, PixelFormat.Format24bppRgb);
        dst.SetResolution(96f, 96f);
        using (Graphics g = Graphics.FromImage(dst)) {
            g.CompositingMode = CompositingMode.SourceCopy; g.InterpolationMode = InterpolationMode.NearestNeighbor; g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(src, new Rectangle(0, 0, part.Width, part.Height), part, GraphicsUnit.Pixel);
        }
        return dst;
    }
    public static void Fill(Bitmap img, Rectangle r, int color) {
        r = Clip(img, r); if (r.Width <= 0 || r.Height <= 0) return;
        using (Graphics g = Graphics.FromImage(img)) using (SolidBrush b = new SolidBrush(Color.FromArgb(255, Color.FromArgb(color)))) g.FillRectangle(b, r);
    }
    public static int Pixel(Bitmap img, int x, int y) {
        if (x < 0 || y < 0 || x >= img.Width || y >= img.Height) return 0;
        return img.GetPixel(x, y).ToArgb();
    }

    // ---- text ----
    static Font MakeFont(string family, float size, bool bold) { return new Font(family, size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Point); }
    // Draws one line with its layout origin at (x, y), clipped. Renderer 0 is GDI through TextRenderer, which is how
    // WinForms and the native controls draw their text; 1 and 2 are GDI+ DrawString with ClearTypeGridFit or AntiAliasGridFit.
    static void Draw(Graphics g, string text, Font f, int renderer, int x, int y, Color fg, Rectangle clip) {
        g.SetClip(clip);
        if (renderer == 0) {
            TextRenderer.DrawText(g, text, f, new Point(x, y), fg,
                TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.PreserveGraphicsClipping);
        } else {
            g.TextRenderingHint = renderer == 1 ? TextRenderingHint.ClearTypeGridFit : TextRenderingHint.AntiAliasGridFit;
            using (StringFormat sf = (StringFormat)StringFormat.GenericTypographic.Clone())
            using (SolidBrush b = new SolidBrush(fg)) {
                sf.FormatFlags |= StringFormatFlags.NoWrap;
                g.DrawString(text, f, b, (float)x, (float)y, sf);
            }
        }
        g.ResetClip();
    }
    public static void Text(Bitmap img, string text, string family, float size, bool bold, int renderer, int x, int y, int fg, Rectangle clip) {
        clip = Clip(img, clip);
        if (clip.Width <= 0 || clip.Height <= 0 || string.IsNullOrEmpty(text)) return;
        using (Font f = MakeFont(family, size, bold)) using (Graphics g = Graphics.FromImage(img))
            Draw(g, text, f, renderer, x, y, Color.FromArgb(255, Color.FromArgb(fg)), clip);
    }
    static Bitmap Canvas(int w, int h, int bg) {
        Bitmap b = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) g.Clear(Color.FromArgb(255, Color.FromArgb(bg)));
        return b;
    }

    // The font Composer drew `original` with inside `region`: every candidate family, size (points), weight and
    // renderer draws the same string; candidates whose ink box differs in height (or in width, unless the
    // original is clipped at the right) are dropped, the rest are drawn at the aligned origin and compared pixel
    // by pixel. Returns the best match with the origin that puts the replacement on the original's baseline.
    public static FontMatch Match(Bitmap img, Rectangle region, string original, string[] families, float minPt, float maxPt, float step, int thr) {
        region = Clip(img, region);
        if (region.Width < 2 || region.Height < 2 || string.IsNullOrEmpty(original)) return null;
        int w = region.Width, h = region.Height;
        int[] px = Read(img, region); int bg = Mode(px); int fg = InkColor(px, bg);
        int[] box = InkBox(px, w, h, bg, thr); if (box == null) return null;
        int bw = box[2] - box[0] + 1, bh = box[3] - box[1] + 1;
        bool clipped = box[2] >= w - 3;
        Color fgc = Color.FromArgb(255, Color.FromArgb(fg));
        TextFormatFlags mf = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine;
        FontMatch best = null;
        foreach (string fam in families) foreach (bool bold in new bool[] { false, true })
        for (int k = 0; ; k++) {
            float s = minPt + k * step; if (s > maxPt + 0.001f) break;
            for (int ren = 0; ren < 3; ren++) {
                using (Font f = MakeFont(fam, s, bold)) {
                    Size m = TextRenderer.MeasureText(original, f, new Size(int.MaxValue, int.MaxValue), mf);
                    int cw = m.Width + 40, ch = m.Height + 20;
                    int[] pb;
                    using (Bitmap probe = Canvas(cw, ch, bg)) {
                        using (Graphics g = Graphics.FromImage(probe)) Draw(g, original, f, ren, 10, 10, fgc, new Rectangle(0, 0, cw, ch));
                        pb = InkBox(Read(probe, new Rectangle(0, 0, cw, ch)), cw, ch, bg, thr);
                    }
                    if (pb == null) continue;
                    int pw = pb[2] - pb[0] + 1, ph = pb[3] - pb[1] + 1;
                    if (Math.Abs(ph - bh) > 2) continue;
                    if (!clipped && Math.Abs(pw - bw) > Math.Max(3, bw / 12)) continue;
                    if (clipped && pw < bw - 2) continue;
                    int ox = region.X + box[0] - (pb[0] - 10), oy = region.Y + box[1] - (pb[1] - 10);
                    double score;
                    using (Bitmap test = Canvas(w, h, bg)) {
                        using (Graphics g = Graphics.FromImage(test)) Draw(g, original, f, ren, ox - region.X, oy - region.Y, fgc, new Rectangle(0, 0, w, h));
                        int[] tp = Read(test, new Rectangle(0, 0, w, h));
                        long sad = 0; for (int i = 0; i < tp.Length; i++) sad += Dist(tp[i], px[i]);
                        score = (double)sad / tp.Length;
                    }
                    if (best == null || score < best.Score) {
                        best = new FontMatch(); best.Family = fam; best.Size = s; best.Bold = bold; best.Renderer = ren;
                        best.OriginX = ox; best.OriginY = oy; best.OffsetX = ox - region.X; best.OffsetY = oy - region.Y;
                        best.Score = score; best.Background = bg; best.Foreground = fg;
                    }
                }
            }
        }
        return best;
    }
}
}
'@
}

# ---- Basics -------------------------------------------------------------------------------------------------

function Initialize-Shots {
    # Folders raw\ (never uploaded), doc\ (finished) and hold\ (finished but not cleared) under -Root.
    param([string]$Root = 'C:\c4-hue\shots')
    $script:ShotRoot = $Root
    foreach ($d in 'raw', 'doc', 'hold') { $p = Join-Path $Root $d; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null } }
    $script:ShotFonts = @{}
    Get-Item $Root
}

function New-ShotRect { param([double]$X, [double]$Y, [double]$W, [double]$H) New-Object System.Drawing.Rectangle ([int]$X), ([int]$Y), ([int]$W), ([int]$H) }

function ConvertTo-ShotRect {
    # [int[]] x,y,w,h or a UIA BoundingRectangle -> System.Drawing.Rectangle (empty when unusable).
    param($Value)
    if ($null -eq $Value) { return [System.Drawing.Rectangle]::Empty }
    if ($Value -is [System.Drawing.Rectangle]) { return $Value }
    if ($Value -is [array]) { return (New-ShotRect $Value[0] $Value[1] $Value[2] $Value[3]) }
    if ($Value.IsEmpty -or [double]::IsInfinity($Value.X) -or [double]::IsNaN($Value.X)) { return [System.Drawing.Rectangle]::Empty }
    New-ShotRect $Value.X $Value.Y $Value.Width $Value.Height
}

function Get-ShotBounds {
    # Screen rectangle of a UIA element; a window's visible frame (without the invisible resize borders).
    param([Parameter(Mandatory)]$Element)
    $c = $Element.Current
    $isWin = ($c.ControlType -eq [System.Windows.Automation.ControlType]::Window -or $c.ControlType -eq [System.Windows.Automation.ControlType]::Menu -or $c.ClassName -eq '#32768')
    if ($isWin -and $c.NativeWindowHandle -ne 0) {
        $f = [C4.Shots]::FrameBounds([IntPtr]$c.NativeWindowHandle)
        if ($f) { return (ConvertTo-ShotRect $f) }
    }
    ConvertTo-ShotRect $c.BoundingRectangle
}

function Get-ShotVisiblePart {
    # The part of $Rect not under $Cover: $Rect, Empty, or the largest strip left over.
    param([System.Drawing.Rectangle]$Rect, [System.Drawing.Rectangle]$Cover)
    $i = [System.Drawing.Rectangle]::Intersect($Rect, $Cover)
    if ($i.IsEmpty) { return $Rect }
    if ($i.Equals($Rect)) { return [System.Drawing.Rectangle]::Empty }
    $strips = @(
        (New-ShotRect $Rect.X $Rect.Y ($i.X - $Rect.X) $Rect.Height),
        (New-ShotRect $i.Right $Rect.Y ($Rect.Right - $i.Right) $Rect.Height),
        (New-ShotRect $Rect.X $Rect.Y $Rect.Width ($i.Y - $Rect.Y)),
        (New-ShotRect $Rect.X $i.Bottom $Rect.Width ($Rect.Bottom - $i.Bottom))
    ) | Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 } | Sort-Object { $_.Width * $_.Height } -Descending
    if ($strips) { return @($strips)[0] }
    [System.Drawing.Rectangle]::Empty
}

function Test-ComposerForeground {
    # $true when the foreground window belongs to Composer's process (its main window, a dialog, a list or a menu).
    $fg = [C4.Native]::GetForegroundWindow(); $procId = [uint32]0
    [void][C4.Native]::GetWindowThreadProcessId($fg, [ref]$procId)
    ($procId -eq [uint32](Get-ComposerProcess).Id)
}

function Get-ShotForbiddenZones {
    # Parts of the main window no picture may show: the title bar (project name), the status bar (controller
    # address, Director status) and the System Design tree (the house's inventory).
    $main = Get-ComposerWindow
    $f = ConvertTo-ShotRect ([C4.Shots]::FrameBounds((Get-ComposerMainHandle)))
    $menuTop = $f.Y + [System.Windows.Forms.SystemInformation]::CaptionHeight + 8
    $barFound = $false
    $barCond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuBar)
    foreach ($b in $main.FindAll($script:ShotScope::Children, $barCond)) {
        $r = ConvertTo-ShotRect $b.Current.BoundingRectangle
        if (-not $r.IsEmpty -and $r.Y -gt $f.Y -and $r.Y -lt $f.Y + 80) { $menuTop = $r.Y; $barFound = $true }
    }
    if (-not $barFound) {
        # Composer's menu bar is a native menu UI Automation does not show; its first item's top ends the title bar
        # (a maximized window has no top border, so caption height + 8 would reach 8 px into the menu bar)
        $nt = Get-ShotNativeMenuTop
        if ($null -ne $nt -and $nt -gt $f.Y -and $nt -lt $f.Y + 80) { $menuTop = $nt }
    }
    $zones = @([pscustomobject]@{ Name = 'the title bar'; Rect = (New-ShotRect $f.X $f.Y $f.Width ($menuTop - $f.Y)) })
    # the status bar: the real bar's top (2 px of margin) when UI Automation shows it, else the bottom 34 px
    $status = [System.Drawing.Rectangle]::Empty
    foreach ($e in @(Find-ComposerElements -Class 'msctls_statusbar32' -Root $main) + @(Find-ComposerElements -Name 'Director Status*' -Root $main) + @(Find-ComposerElements -Name 'Connected to*' -Root $main)) {
        $r = ConvertTo-ShotRect $e.Current.BoundingRectangle
        if ($r.IsEmpty -or $r.Y -lt $f.Y + $f.Height / 2) { continue }
        $band = New-ShotRect $f.X ($r.Y - 2) $f.Width ($f.Bottom - $r.Y + 2)
        $status = if ($status.IsEmpty) { $band } else { [System.Drawing.Rectangle]::Union($status, $band) }
    }
    if ($status.IsEmpty) { $status = New-ShotRect $f.X ($f.Bottom - 34) $f.Width 34 }
    $zones += [pscustomobject]@{ Name = 'the status bar'; Rect = $status }
    $nav = Find-ComposerElements -Name 'System Design' -Class 'Window.8' -Root $main | Where-Object { $_.Current.BoundingRectangle.Height -gt 100 } | Select-Object -First 1
    if ($nav) { $zones += [pscustomobject]@{ Name = 'the System Design tree'; Rect = (ConvertTo-ShotRect $nav.Current.BoundingRectangle) } }
    $zones
}

function Read-ShotBitmap {
    # A 24-bit working copy of a PNG, without keeping the file locked.
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $ms = New-Object System.IO.MemoryStream (, $bytes)
    $src = [System.Drawing.Bitmap]::FromStream($ms)
    try { [C4.Shots]::Copy24($src, (New-ShotRect 0 0 $src.Width $src.Height)) } finally { $src.Dispose(); $ms.Dispose() }
}

function New-ShotLayer {
    # One window-level piece of a shot, bottom first: an element subtree, or the drop-down list of a combo box.
    param($Element, [IntPtr]$ListHwnd = 0)
    if ($ListHwnd -ne [IntPtr]::Zero) {
        return [pscustomobject]@{ Kind = 'ComboList'; Element = $null; Hwnd = $ListHwnd; Bounds = (ConvertTo-ShotRect ([C4.Shots]::FrameBounds($ListHwnd))) }
    }
    [pscustomobject]@{ Kind = 'Element'; Element = $Element; Hwnd = [IntPtr]$Element.Current.NativeWindowHandle; Bounds = (Get-ShotBounds $Element) }
}

function Save-PaneShot {
    # Capture one pane, dialog or row to <root>\raw\<Name> (CopyFromScreen via Save-RegionShot, so Composer and
    # whatever it has open must be in front) and return the shot: its screen origin and size, a 24-bit working
    # bitmap and its layers. -Element: one or more UIA elements, the crop is their union;
    # -Rect: a screen rectangle instead. Refuses any crop that shows the title bar, status bar or device tree.
    param([Parameter(Mandatory)][string]$Name, $Element, $Rect, [int]$Margin = 0, $Layers)
    if ($Rect) { $crop = ConvertTo-ShotRect $Rect }
    else {
        $crop = [System.Drawing.Rectangle]::Empty
        foreach ($e in @($Element)) { $b = Get-ShotBounds $e; if ($b.IsEmpty) { continue }; $crop = if ($crop.IsEmpty) { $b } else { [System.Drawing.Rectangle]::Union($crop, $b) } }
    }
    if ($crop.IsEmpty) { throw "Save-PaneShot ${Name}: nothing to crop" }
    if ($Margin -gt 0) { $crop = New-ShotRect ($crop.X - $Margin) ($crop.Y - $Margin) ($crop.Width + 2 * $Margin) ($crop.Height + 2 * $Margin) }
    if (-not $Layers) { $Layers = @(foreach ($e in @($Element)) { New-ShotLayer -Element $e }) }
    # what of the crop belongs to the main window (not covered by a dialog, list or menu on top) must avoid the zones
    $exposed = $crop
    foreach ($l in @($Layers)) {
        $top = ($l.Kind -eq 'ComboList') -or ($l.Element -and ($l.Element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -or $l.Element.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu -or $l.Element.Current.ClassName -eq '#32768'))   # a native popup menu shows as a Pane (round 46b)
        if ($top) { $exposed = Get-ShotVisiblePart -Rect $exposed -Cover $l.Bounds }
    }
    foreach ($z in Get-ShotForbiddenZones) {
        if (-not $exposed.IsEmpty -and [System.Drawing.Rectangle]::Intersect($exposed, $z.Rect).Width -gt 0 -and [System.Drawing.Rectangle]::Intersect($exposed, $z.Rect).Height -gt 0) {
            throw "Refusing ${Name}: the crop $crop would show $($z.Name)"
        }
    }
    if (-not (Test-ComposerForeground)) { throw "Refusing ${Name}: Composer is not in the foreground (run the row's setup again)" }
    $raw = Join-Path $script:ShotRoot ('raw\' + $Name)
    [void](Save-RegionShot -Path $raw -X $crop.X -Y $crop.Y -W $crop.Width -H $crop.Height)
    [pscustomobject]@{ Name = $Name; X = $crop.X; Y = $crop.Y; W = $crop.Width; H = $crop.Height; Bitmap = (Read-ShotBitmap $raw)
        Layers = @($Layers); Regions = @(); Static = @(); Notes = (New-Object System.Collections.ArrayList); Problems = (New-Object System.Collections.ArrayList); RawPath = $raw }
}

# ---- Finding things in Composer (read only) ------------------------------------------------------------------

function Get-ShotPropertiesPage {
    $pg = Find-ComposerElements -Name 'Properties' -Class 'Window.8' | Where-Object { $_.Current.BoundingRectangle.Height -gt 100 } | Select-Object -First 1
    if (-not $pg) { throw "Properties page not found (is the Properties tab selected?)" }
    $pg
}

function Get-ShotPropertyRow {
    # The label, value controls and buttons of one row of the Properties page (pairing as Get-ComposerProperties).
    param([Parameter(Mandatory)][string]$Label)
    $pg = Get-ShotPropertiesPage
    $lbl = Find-ComposerElements -Class 'EDIT' -Name ([WildcardPattern]::Escape($Label)) -Root $pg | Where-Object { $_.Current.Name -eq $Label } | Select-Object -First 1
    if (-not $lbl) { throw "Property '$Label' not found" }
    $ly = [int]$lbl.Current.BoundingRectangle.Y
    $split = [int]$pg.Current.BoundingRectangle.X + 180
    $vals = @(Find-ComposerElements -Root $pg | Where-Object { $c = $_.Current
        ($c.ClassName -like '*EDIT*' -or $c.ClassName -like '*COMBOBOX*' -or $c.ClassName -like '*BUTTON*') -and
        [int]$c.BoundingRectangle.X -ge $split -and [math]::Abs([int]$c.BoundingRectangle.Y - $ly) -le 10 })
    [pscustomobject]@{ Page = $pg; Label = $lbl; Values = $vals
        Combo   = ($vals | Where-Object { $_.Current.ClassName -like '*COMBOBOX*' } | Select-Object -First 1)
        Edit    = ($vals | Where-Object { $_.Current.ClassName -like '*EDIT*' } | Select-Object -First 1)
        Buttons = @($vals | Where-Object { $_.Current.ClassName -like '*BUTTON*' }) }
}

function Get-ShotDialog {
    # An open Composer dialog by title; a nested one (the Select picker) is found under -Parent.
    param([Parameter(Mandatory)][string]$Name, $Parent)
    if (-not $Parent) { $Parent = $script:ShotA::FromHandle((Get-ComposerMainHandle)) }
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    $all = @($Parent.FindAll($script:ShotScope::Descendants, $cond) | Where-Object { $_.Current.Name -eq $Name })
    if ($all.Count -eq 0) { throw "Dialog '$Name' is not open" }
    $all[-1]
}

if (-not ('C4.ShotMenu' -as [type])) {
Add-Type -Namespace C4 -Name ShotMenu -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hwnd);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hmenu);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr hmenu, uint item, System.Text.StringBuilder sb, int max, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr hwnd, IntPtr hmenu, uint item, out RECT r);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
'@
}

function Get-ShotNativeMenuItems {
    # The items of a native menu as {Text; Label; Accel; Rect (System.Drawing.Rectangle, screen)}: the open popup
    # -PopupHwnd (a #32768 window; its HMENU through MN_GETHMENU), or with -Bar Composer's menu bar. Separators skipped.
    param([IntPtr]$PopupHwnd = [IntPtr]::Zero, [switch]$Bar)
    if ($Bar) { $owner = Get-ComposerMainHandle; $hm = [C4.ShotMenu]::GetMenu($owner) }
    else { $owner = [IntPtr]::Zero; $hm = [C4.ShotMenu]::SendMessage($PopupHwnd, 0x01E1, [IntPtr]::Zero, [IntPtr]::Zero) }   # MN_GETHMENU
    if ($hm -eq [IntPtr]::Zero) { return @() }
    $n = [C4.ShotMenu]::GetMenuItemCount($hm)
    for ($i = 0; $i -lt $n; $i++) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][C4.ShotMenu]::GetMenuString($hm, [uint32]$i, $sb, 256, 0x400)           # MF_BYPOSITION
        $text = $sb.ToString(); if (-not $text.Trim()) { continue }
        $r = New-Object C4.ShotMenu+RECT
        if (-not [C4.ShotMenu]::GetMenuItemRect($owner, $hm, [uint32]$i, [ref]$r)) { continue }
        $parts = $text -split "`t", 2
        [pscustomobject]@{ Text = $text; Label = ($parts[0] -replace '&', ''); Accel = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
            Rect = (New-ShotRect $r.Left $r.Top ($r.Right - $r.Left) ($r.Bottom - $r.Top)) }
    }
}

function Get-ShotNativeMenuTop {
    # Screen Y of Composer's native menu bar (its first item), or $null.
    $hwnd = Get-ComposerMainHandle
    $hm = [C4.ShotMenu]::GetMenu($hwnd)
    if ($hm -eq [IntPtr]::Zero -or [C4.ShotMenu]::GetMenuItemCount($hm) -lt 1) { return $null }
    $r = New-Object C4.ShotMenu+RECT
    if (-not [C4.ShotMenu]::GetMenuItemRect($hwnd, $hm, [uint32]0, [ref]$r)) { return $null }
    $r.Top
}

function Get-ShotMenuBarItem {
    # A top-level menu (File, Driver, ...) of Composer's menu bar. Composer's menu bar is a native Win32 menu that
    # UI Automation does not expose (round 46b), so when no UIA MenuItem matches, the item is read with GetMenu /
    # GetMenuString / GetMenuItemRect and returned as a stand-in with .Current.Name, .BoundingRectangle, .ControlType.
    param([Parameter(Mandatory)][string]$Name)
    $main = Get-ComposerWindow
    $f = ConvertTo-ShotRect ([C4.Shots]::FrameBounds((Get-ComposerMainHandle)))
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $item = $main.FindAll($script:ShotScope::Descendants, $cond) | Where-Object { $_.Current.Name -replace '&', '' -eq $Name -and $_.Current.BoundingRectangle.Y -lt $f.Y + 90 } | Select-Object -First 1
    if ($item) { return $item }
    $hwnd = Get-ComposerMainHandle
    $hm = [C4.ShotMenu]::GetMenu($hwnd)
    if ($hm -ne [IntPtr]::Zero) {
        $n = [C4.ShotMenu]::GetMenuItemCount($hm)
        for ($i = 0; $i -lt $n; $i++) {
            $sb = New-Object System.Text.StringBuilder 128
            [void][C4.ShotMenu]::GetMenuString($hm, [uint32]$i, $sb, 128, 0x400)        # MF_BYPOSITION
            if (($sb.ToString() -replace '&', '') -ne $Name) { continue }
            $r = New-Object C4.ShotMenu+RECT
            if (-not [C4.ShotMenu]::GetMenuItemRect($hwnd, $hm, [uint32]$i, [ref]$r)) { break }
            $rect = New-Object System.Windows.Rect ([double]$r.Left), ([double]$r.Top), ([double]($r.Right - $r.Left)), ([double]($r.Bottom - $r.Top))
            $cur = [pscustomobject]@{ Name = $sb.ToString(); BoundingRectangle = $rect; ControlType = [System.Windows.Automation.ControlType]::MenuItem; NativeWindowHandle = 0; ClassName = 'NativeMenuItem' }
            return [pscustomobject]@{ Current = $cur }
        }
    }
    throw "Menu '$Name' not found in Composer's menu bar"
}

function Get-ShotMenuPopup {
    # The open drop-down menu of Composer's process (a native #32768 window, or any Menu element), or $null.
    $procId = [int](Get-ComposerProcess).Id
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ProcessIdProperty, $procId)
    $pop = $script:ShotA::RootElement.FindAll($script:ShotScope::Children, $cond) | Where-Object {
        ($_.Current.ClassName -eq '#32768' -or $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) -and
        [C4.Shots]::IsWindowVisible([IntPtr]$_.Current.NativeWindowHandle) } | Select-Object -First 1
    if ($pop) { return $pop }
    # Composer's native popup menu is a visible #32768 window of its process that UI Automation does not list under
    # the desktop (round 46b): find it with EnumWindows and wrap it with FromHandle.
    $found = New-Object System.Collections.ArrayList
    $cb = [C4.ShotMenu+EnumProc]{ param($h, $l)
        $sb = New-Object System.Text.StringBuilder 64; [void][C4.ShotMenu]::GetClassName($h, $sb, 64)
        if ($sb.ToString() -eq '#32768' -and [C4.ShotMenu]::IsWindowVisible($h)) {
            $p = [uint32]0; [void][C4.ShotMenu]::GetWindowThreadProcessId($h, [ref]$p)
            if ([int]$p -eq $procId) { [void]$found.Add($h) }
        }
        $true }
    [void][C4.ShotMenu]::EnumWindows($cb, [IntPtr]::Zero)
    foreach ($h in $found) { try { return $script:ShotA::FromHandle($h) } catch { } }
    $null
}

function Get-ShotMenuBar {
    $cond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuBar)
    (Get-ComposerWindow).FindAll($script:ShotScope::Children, $cond) | Select-Object -First 1
}

# ---- The texts inside a shot -------------------------------------------------------------------------------------

function New-ShotRegion {
    param([int]$Layer, [string]$Source, [string]$Class, [string]$Name, [System.Drawing.Rectangle]$Screen,
          [System.Drawing.Rectangle]$Fill = [System.Drawing.Rectangle]::Empty, [System.Drawing.Rectangle]$ClipScreen = [System.Drawing.Rectangle]::Empty,
          [int]$Row = -1, [int]$Column = 0, [long]$List = 0, [bool]$Selected = $false)
    [pscustomobject]@{ Index = -1; Layer = $Layer; Source = $Source; Class = $Class; Name = $Name; Screen = $Screen
        FillScreen = $(if ($Fill.IsEmpty) { $Screen } else { $Fill }); ClipScreen = $(if ($ClipScreen.IsEmpty) { $Screen } else { $ClipScreen })
        Row = $Row; Column = $Column; List = $List; Selected = $Selected
        Rect = [System.Drawing.Rectangle]::Empty; Fill = [System.Drawing.Rectangle]::Empty; Clip = [System.Drawing.Rectangle]::Empty
        Visibility = 'Visible'; Label = $null; IsLabel = $false; Decision = $null; Final = $null; ListBackground = $null }
}

function Get-ShotClassName { param([string]$ClassName) ($ClassName -replace 'WindowsForms10\.', '' -replace '\.app\.0\.\S+', '') }

function Add-ShotListViewRegions {
    # The visible rows of a SysListView32 (every column), read with the list-view messages.
    param([IntPtr]$Hwnd, [int]$Layer, [System.Collections.ArrayList]$Out)
    $count = [C4.ListView]::GetCount($Hwnd); if ($count -le 0) { return }
    $top = [C4.ListView]::GetTopIndex($Hwnd); $per = [C4.ListView]::GetCountPerPage($Hwnd)
    $client = ConvertTo-ShotRect ([C4.Shots]::ClientBounds($Hwnd))
    $cols = [C4.Shots]::ListColumnCount($Hwnd)
    $last = [Math]::Min($count - 1, $top + $per)
    for ($i = $top; $i -le $last; $i++) {
        $rb = ConvertTo-ShotRect ([C4.Shots]::ListItemRect($Hwnd, $i, 0, 0))
        if ($rb.Y -ge $client.Bottom) { break }
        $sel = (([C4.ListView]::GetState($Hwnd, $i) -band 2) -ne 0)
        $fill = [System.Drawing.Rectangle]::Intersect($rb, $client)
        for ($j = 0; $j -lt $cols; $j++) {
            $text = [C4.ListView]::GetText($Hwnd, $i, $j)
            if (-not $text) { continue }
            $lr = [System.Drawing.Rectangle]::Intersect((ConvertTo-ShotRect ([C4.Shots]::ListItemRect($Hwnd, $i, $j, 2))), $client)
            if ($lr.IsEmpty) { continue }
            $src = if ($j -eq 0) { 'ListItem' } else { 'ListSubItem' }
            $f = if ($j -eq 0) { $fill } else { $lr }
            [void]$Out.Add((New-ShotRegion -Layer $Layer -Source $src -Class 'SysListView32' -Name $text -Screen $lr -Fill $f -ClipScreen $lr -Row ($i - $top) -Column $j -List $Hwnd.ToInt64() -Selected $sel))
        }
    }
}

function Add-ShotComboListRegions {
    # The visible rows of a dropped combo list: texts through MSAA (Composer.psm1), geometry from the list box.
    param([IntPtr]$Hwnd, [int]$Layer, [System.Collections.ArrayList]$Out)
    $names = @(Get-ComboListItemsMsaa -ListHwnd $Hwnd | ForEach-Object { $_.Text })
    $count = [C4.Shots]::ListBoxCount($Hwnd); if ($count -le 0) { $count = $names.Count }
    $top = [Math]::Max(0, [C4.Shots]::ListBoxTopIndex($Hwnd)); $ih = [C4.Shots]::ListBoxItemHeight($Hwnd); $sel = [C4.Shots]::ListBoxCurSel($Hwnd)
    if ($ih -le 0) { throw "The drop-down list reports no item height" }
    $client = ConvertTo-ShotRect ([C4.Shots]::ClientBounds($Hwnd))
    for ($k = 0; ($top + $k) -lt $count; $k++) {
        $y = $client.Y + $k * $ih
        if ($y -ge $client.Bottom) { break }
        $i = $top + $k
        $text = if ($i -lt $names.Count) { [string]$names[$i] } else { '' }
        if (-not $text) { continue }
        $row = New-ShotRect $client.X $y $client.Width ([Math]::Min($ih, $client.Bottom - $y))
        [void]$Out.Add((New-ShotRegion -Layer $Layer -Source 'ComboItem' -Class 'ComboLBox' -Name $text -Screen $row -Fill $row -ClipScreen $row -Row $k -List $Hwnd.ToInt64() -Selected ($i -eq $sel)))
    }
}

function Add-ShotElementRegions {
    # Every named leaf under $Root that touches the crop; list views, combo boxes and window titles specially.
    param($Root, [int]$Layer, [System.Collections.ArrayList]$Out, [System.Drawing.Rectangle]$Crop)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $el = $stack.Pop()
        try { $c = $el.Current } catch { continue }
        $r = ConvertTo-ShotRect $c.BoundingRectangle
        if (-not [object]::ReferenceEquals($el, $Root) -and ($r.IsEmpty -or -not $r.IntersectsWith($Crop))) { continue }
        $cls = Get-ShotClassName ([string]$c.ClassName)
        $name = [string]$c.Name
        $h = [IntPtr]$c.NativeWindowHandle
        if ($cls -like '*SysListView32*' -and $h -ne [IntPtr]::Zero) { Add-ShotListViewRegions -Hwnd $h -Layer $Layer -Out $Out; continue }
        if ($cls -like '*COMBOBOX*' -and $h -ne [IntPtr]::Zero) {
            $p = [C4.Shots]::ComboParts($h)
            $face = if ($p) { New-ShotRect $p[0] $p[1] $p[2] $p[3] } else { $r }
            $text = if ($name) { $name } else { [C4.ListView]::GetWindowText($h) }
            if ($text) { [void]$Out.Add((New-ShotRegion -Layer $Layer -Source 'ComboFace' -Class $cls -Name $text -Screen $face)) }
            continue
        }
        if ($c.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $name) {
            $fb = Get-ShotBounds $el
            [void]$Out.Add((New-ShotRegion -Layer $Layer -Source 'Title' -Class $cls -Name $name -Screen (New-ShotRect $fb.X $fb.Y $fb.Width ([Math]::Min(30, $fb.Height)))))
        }
        $child = $script:ShotWalker.GetFirstChild($el)
        if ($child) {
            # a named container: not painted, but checked (a pane title or a device name may be drawn from it)
            if ($name.Trim() -and $c.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
                [void]$Out.Add((New-ShotRegion -Layer $Layer -Source 'Container' -Class $cls -Name $name -Screen $r))
            }
            while ($child) { $stack.Push($child); $child = $script:ShotWalker.GetNextSibling($child) }
            continue
        }
        if ($name.Trim() -and $c.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
            [void]$Out.Add((New-ShotRegion -Layer $Layer -Source 'UIA' -Class $cls -Name $name -Screen $r))
        }
    }
}

function Get-ShotLayerVisible {
    # The part of a screen rectangle inside the crop and not under a layer above $Layer.
    param($Shot, [System.Drawing.Rectangle]$Rect, [int]$Layer)
    $vis = [System.Drawing.Rectangle]::Intersect($Rect, (New-ShotRect $Shot.X $Shot.Y $Shot.W $Shot.H))
    for ($j = $Layer + 1; $j -lt $Shot.Layers.Count -and -not $vis.IsEmpty; $j++) { $vis = Get-ShotVisiblePart -Rect $vis -Cover $Shot.Layers[$j].Bounds }
    $vis
}

function ConvertTo-ShotImageRect {
    param($Shot, [System.Drawing.Rectangle]$Rect)
    if ($Rect.IsEmpty) { return [System.Drawing.Rectangle]::Empty }
    [System.Drawing.Rectangle]::Intersect((New-ShotRect ($Rect.X - $Shot.X) ($Rect.Y - $Shot.Y) $Rect.Width $Rect.Height), (New-ShotRect 0 0 $Shot.W $Shot.H))
}

function Get-TextRegions {
    # Every text the shot can show: its original (house data, kept in memory only), where it is in the image
    # (Rect), the area to clear (Fill: a whole list row), where new text may be drawn (Clip), whether a higher
    # layer hides it, and for a property or parameter value the label of its row. Numbered top to bottom.
    param([Parameter(Mandatory)]$Shot)
    $crop = New-ShotRect $Shot.X $Shot.Y $Shot.W $Shot.H
    $out = New-Object System.Collections.ArrayList
    for ($li = 0; $li -lt $Shot.Layers.Count; $li++) {
        $l = $Shot.Layers[$li]
        if ($l.Kind -eq 'ComboList') { Add-ShotComboListRegions -Hwnd $l.Hwnd -Layer $li -Out $out }
        else {
            $n0 = $out.Count
            Add-ShotElementRegions -Root $l.Element -Layer $li -Out $out -Crop $crop
            # a native popup menu that UI Automation shows without items (round 46b): its items from the menu itself
            if ($out.Count -eq $n0 -and $l.Element -and $l.Element.Current.ClassName -eq '#32768') {
                foreach ($ni in Get-ShotNativeMenuItems -PopupHwnd $l.Hwnd) {
                    [void]$out.Add((New-ShotRegion -Layer $li -Source 'UIA' -Class 'MenuItem' -Name $ni.Label -Screen $ni.Rect))
                    if ($ni.Accel) { [void]$out.Add((New-ShotRegion -Layer $li -Source 'UIA' -Class 'MenuItemAccel' -Name $ni.Accel -Screen $ni.Rect)) }
                }
            }
        }
    }
    # Composer's native menu bar, when it is in the crop and no UI Automation layer showed it: below every layer
    if (-not ($Shot.Layers | Where-Object { $_.Element -and $_.Element.Current.ControlType -eq [System.Windows.Automation.ControlType]::MenuBar })) {
        foreach ($ni in Get-ShotNativeMenuItems -Bar) {
            if ($ni.Rect.IntersectsWith($crop)) { [void]$out.Add((New-ShotRegion -Layer -1 -Source 'UIA' -Class 'MenuBarItem' -Name $ni.Label -Screen $ni.Rect)) }
        }
    }
    foreach ($r in $out) {
        $vis = Get-ShotLayerVisible -Shot $Shot -Rect $r.Screen -Layer $r.Layer
        if ($vis.IsEmpty) { $r.Visibility = 'Hidden' } elseif (-not $vis.Equals($r.Screen)) { $r.Visibility = 'Partial' }
        $r.Rect = ConvertTo-ShotImageRect $Shot $vis
        $r.Fill = ConvertTo-ShotImageRect $Shot (Get-ShotLayerVisible -Shot $Shot -Rect $r.FillScreen -Layer $r.Layer)
        $r.Clip = ConvertTo-ShotImageRect $Shot (Get-ShotLayerVisible -Shot $Shot -Rect $r.ClipScreen -Layer $r.Layer)
        if ($r.Rect.IsEmpty -and $r.Visibility -ne 'Hidden') { $r.Visibility = 'Outside' }
    }
    # a value (edit or combo box) and the edit on its left in the same row: the label
    $labels = @($out | Where-Object { $_.Source -eq 'UIA' -and $_.Class -like '*EDIT*' })
    foreach ($v in @($out | Where-Object { ($_.Source -eq 'UIA' -and $_.Class -like '*EDIT*') -or $_.Source -eq 'ComboFace' })) {
        $best = $null
        foreach ($l in $labels) {
            if ([object]::ReferenceEquals($l, $v) -or $l.Screen.Right -gt $v.Screen.X + 2 -or [Math]::Abs($l.Screen.Y - $v.Screen.Y) -gt 8) { continue }
            if (-not $best -or $l.Screen.X -gt $best.Screen.X) { $best = $l }
        }
        if ($best) { $v.Label = $best.Name; $best.IsLabel = $true }
    }
    $i = 0
    $sorted = @($out | Sort-Object { $_.Screen.Y }, { $_.Screen.X })
    foreach ($r in $sorted) { $r.Index = $i; $i++ }
    $Shot.Regions = $sorted
    $sorted
}

# ---- Painting over a text ----------------------------------------------------------------------------------------

function ConvertTo-ShotFont {
    # A plan's font ({Family; Size; Bold; Renderer; OffsetX; OffsetY}) as a C4.FontMatch.
    param($Spec)
    $m = New-Object C4.FontMatch
    $m.Family = if ($Spec.Family) { [string]$Spec.Family } else { 'Segoe UI' }
    $m.Size = if ($Spec.Size) { [single]$Spec.Size } else { [single]9 }
    $m.Bold = [bool]$Spec.Bold
    $m.Renderer = if ($null -ne $Spec.Renderer) { [int]$Spec.Renderer } else { 0 }
    $m.OffsetX = if ($null -ne $Spec.OffsetX) { [int]$Spec.OffsetX } else { 2 }
    $m.OffsetY = if ($null -ne $Spec.OffsetY) { [int]$Spec.OffsetY } else { 2 }
    $m.Score = -1
    $m
}

function Set-TextReplacement {
    # Paint over one text of a shot: clear it with the background sampled under it, then draw -Text in the font
    # Composer used for it, measured on the original (C4.Shots.Match tries Segoe UI, Microsoft Sans Serif and
    # Tahoma, regular and bold, 7 to 11 pt, GDI and GDI+ ClearTypeGridFit / AntiAliasGridFit, and keeps the
    # closest), left-aligned on the original's baseline and clipped where Composer clips. A region without text
    # of its own (an empty box) reuses the font and offsets measured on a region of the same kind. -Blank only
    # clears (a list row the neutral list does not need gets the list's own background). -Font forces a font.
    param([Parameter(Mandatory)]$Shot, $Region, $Rect, [string]$Text = '', [string]$Original, [switch]$Blank, $Font, $Clip)
    $img = $Shot.Bitmap
    if ($Region) {
        if (-not $Rect) { $Rect = $Region.Rect }
        if (-not $Clip) { $Clip = $Region.Clip }
        if (-not $PSBoundParameters.ContainsKey('Original')) { $Original = $Region.Name }
    }
    $Rect = ConvertTo-ShotRect $Rect
    $Clip = if ($Clip) { ConvertTo-ShotRect $Clip } else { $Rect }
    if ($Clip.IsEmpty) { $Clip = $Rect }
    if ($Rect.IsEmpty) { throw "Set-TextReplacement: nothing visible to paint (region $(if ($Region) { $Region.Index } else { '-' }))" }
    if ($Original -and $Original.Trim()) { [void]$script:ShotReplaced.Add($Original.Trim()) }
    $p = [C4.Shots]::Probe($img, $Rect, $script:ShotInk)          # hasInk, background, ink colour, x0, y0, x1, y1
    if (-not $p) { throw "Set-TextReplacement: the region lies outside the picture" }
    if ($Blank) {
        $area = if ($Region -and -not $Region.Fill.IsEmpty) { $Region.Fill } else { $Rect }
        $bg = if ($Region -and $null -ne $Region.ListBackground) { [int]$Region.ListBackground } else { $p[1] }
        [C4.Shots]::Fill($img, $area, $bg)
        if ($Region) { $Region.Decision = 'Blanked'; $Region.Final = '' }
        return
    }
    $class = if ($Region) { $Region.Class } else { 'rect' }
    $key = '{0}|{1}|{2}|{3}' -f $class, $Rect.Height, $p[1], $p[2]
    $m = $null; $here = $false
    if ($Font) { $m = ConvertTo-ShotFont $Font }
    elseif ($p[0] -eq 1 -and $Original) {
        $m = [C4.Shots]::Match($img, $Rect, $Original, [string[]]$script:ShotFamilies, [single]7, [single]11, [single]0.25, $script:ShotInk)
        if ($m) { $here = $true; $script:ShotFonts[$key] = $m; $script:ShotFonts["$class|$($Rect.Height)"] = $m; $script:ShotFonts["$class|any"] = $m }
    }
    if (-not $m) { $m = $script:ShotFonts[$key] }
    if (-not $m) { $m = $script:ShotFonts["$class|$($Rect.Height)"] }
    if (-not $m) { $m = $script:ShotFonts["$class|any"] }     # e.g. the last list row, cut at the bottom of the list
    if (-not $m) { throw "No font for region $(if ($Region) { $Region.Index } else { '-' }) ($class): paint a region of the same kind that has text first, or give -Font" }
    if ($here) { $ox = $m.OriginX; $oy = $m.OriginY } else { $ox = $Rect.X + $m.OffsetX; $oy = $Rect.Y + $m.OffsetY }
    $fg = if ($p[0] -eq 1) { $p[2] } else { $m.Foreground }
    if ($p[0] -eq 1) {
        # the old ink box grown by 2 px, to the right end of the clip so a clipped long text goes too
        $x1 = [Math]::Max($Clip.X, $p[3] - 2); $y1 = [Math]::Max($Rect.Y, $p[4] - 2)
        $x2 = [Math]::Min($Clip.Right, $Rect.Right); $y2 = [Math]::Min($Rect.Bottom, $p[6] + 3)
        if ($x2 -gt $x1 -and $y2 -gt $y1) { [C4.Shots]::Fill($img, (New-ShotRect $x1 $y1 ($x2 - $x1) ($y2 - $y1)), $p[1]) }
    }
    [C4.Shots]::Text($img, $Text, $m.Family, $m.Size, $m.Bold, $m.Renderer, $ox, $oy, $fg, $Clip)
    if ($Region) {
        $Region.Decision = 'Replaced'; $Region.Final = $Text
        $how = if ($here) { 'measured, score ' + [Math]::Round($m.Score, 1) } elseif ($Font) { 'from the plan' } else { 'reused' }
        $Region | Add-Member -Force NoteProperty Font ('{0} {1} pt{2}, renderer {3}, {4}' -f $m.Family, $m.Size, $(if ($m.Bold) { ' bold' } else { '' }), $m.Renderer, $how)
    }
}

function Clear-ShotScrollBars {
    # Paint a list's scroll bars over with its background: a neutral list shorter than the visible rows has none.
    param([Parameter(Mandatory)]$Shot, [Parameter(Mandatory)][IntPtr]$Hwnd)
    $client = ConvertTo-ShotImageRect $Shot (ConvertTo-ShotRect ([C4.Shots]::ClientBounds($Hwnd)))
    if ($client.IsEmpty) { return }
    $bg = ([C4.Shots]::Probe($Shot.Bitmap, $client, $script:ShotInk))[1]
    $v = [C4.Shots]::ScrollBar($Hwnd, $true); $h = [C4.Shots]::ScrollBar($Hwnd, $false)
    foreach ($sb in @($v, $h)) { if ($sb) { [C4.Shots]::Fill($Shot.Bitmap, (ConvertTo-ShotImageRect $Shot (ConvertTo-ShotRect $sb)), $bg) } }
    if ($v -and $h) { [C4.Shots]::Fill($Shot.Bitmap, (ConvertTo-ShotImageRect $Shot (New-ShotRect $v[0] $h[1] $v[2] $h[3])), $bg) }
    if ($v -or $h) { [void]$Shot.Notes.Add('scroll bars of the list painted over with its background') }
}

function Set-ShotBottom {
    # Cut the picture above image row -Y (row -Y - 1 becomes the last), drawing a dropped list's bottom border
    # there in -BorderColor from -X1 to -X2: a neutral list shorter than the house's then ends where it should.
    param([Parameter(Mandatory)]$Shot, [Parameter(Mandatory)][int]$Y, [int]$X1 = -1, [int]$X2 = -1, $BorderColor)
    if ($Y -le 1 -or $Y -ge $Shot.H) { return }
    if ($X1 -ge 0 -and $X2 -gt $X1 -and $null -ne $BorderColor) { [C4.Shots]::Fill($Shot.Bitmap, (New-ShotRect $X1 ($Y - 1) ($X2 - $X1) 1), [int]$BorderColor) }
    $new = [C4.Shots]::Copy24($Shot.Bitmap, (New-ShotRect 0 0 $Shot.W $Y))
    $Shot.Bitmap.Dispose(); $Shot.Bitmap = $new; $Shot.H = $Y
    $keep = New-ShotRect 0 0 $Shot.W $Y
    foreach ($r in $Shot.Regions) {
        if ($r.Rect.IsEmpty) { continue }
        if ($r.Rect.Y -ge $Y) { $r.Visibility = 'Cut'; $r.Rect = [System.Drawing.Rectangle]::Empty }
        elseif ($r.Rect.Bottom -gt $Y) { $r.Rect = [System.Drawing.Rectangle]::Intersect($r.Rect, $keep) }
    }
    [void]$Shot.Notes.Add("picture cut below the last row of the neutral list (now $($Shot.W) x $Y)")
}

function Save-ShotResult {
    # Write the finished PNG to doc\ when every visible text was replaced, blanked or reviewed as safe and no
    # house term or identifier is left in it; otherwise to hold\ with the reasons. Deny details (the house terms
    # that matched) go to raw\<name>.deny.txt only.
    param([Parameter(Mandatory)]$Shot)
    $reasons = New-Object System.Collections.ArrayList
    $detail = New-Object System.Collections.ArrayList
    foreach ($r in $Shot.Regions) {
        if ($r.Visibility -in 'Hidden', 'Cut', 'Outside') { continue }
        $final = switch ($r.Decision) { 'Kept' { $r.Name } 'Replaced' { $r.Final } 'Blanked' { '' } default { $r.Name } }
        $hits = @(Test-ShotText $final)
        if ($r.Source -eq 'Container') {
            if ($hits.Count) { [void]$reasons.Add("region $($r.Index): a container named with $($hits -join ', ')"); [void]$detail.Add("region $($r.Index): $final") }
            continue
        }
        if (-not $r.Decision -or $r.Decision -eq 'Unreviewed') {
            [void]$reasons.Add("region $($r.Index): text not covered by the plan ($($r.Source) $($r.Class)$(if ($r.Label) { ", row '" + $r.Label + "'" }))")
            [void]$detail.Add("region $($r.Index) unreviewed: $($r.Name)")
            continue
        }
        if ($r.Decision -eq 'Hold') { [void]$reasons.Add("region $($r.Index): $($r.Final)"); continue }
        if ($hits.Count) { [void]$reasons.Add("region $($r.Index): $($hits -join ', ')"); [void]$detail.Add("region $($r.Index): $final") }
    }
    foreach ($n in @($Shot.Problems)) { if ($n) { [void]$reasons.Add($n) } }
    $dir = if ($reasons.Count) { 'hold' } else { 'doc' }
    foreach ($d in 'doc', 'hold') { foreach ($f in $Shot.Name, [IO.Path]::ChangeExtension($Shot.Name, '.txt')) {
        $old = Join-Path $script:ShotRoot ($d + '\' + $f); if (Test-Path $old) { Remove-Item $old -Force } } }
    $path = Join-Path $script:ShotRoot ($dir + '\' + $Shot.Name)
    $Shot.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $denyFile = Join-Path $script:ShotRoot ('raw\' + [IO.Path]::GetFileNameWithoutExtension($Shot.Name) + '.deny.txt')
    if ($detail.Count) { [IO.File]::WriteAllLines($denyFile, [string[]]$detail) } elseif (Test-Path $denyFile) { Remove-Item $denyFile -Force }
    $Shot | Add-Member -Force NoteProperty OutPath $path
    $Shot | Add-Member -Force NoteProperty Reasons @($reasons)
    [pscustomobject]@{ Name = $Shot.Name; Folder = $dir; Path = $path; Reasons = @($reasons) }
}

# ---- What must never be in a picture -------------------------------------------------------------------------------

function Get-ShotTokens { param([string]$Text) if (-not $Text) { return @() }; @([regex]::Split($Text.ToLowerInvariant(), '[^a-z0-9]+') | Where-Object { $_ }) }

function Add-ShotNeutral {
    # Words of the neutral texts and of the texts reviewed as safe. A house name made only of such words is not a
    # finding: the neutral set reuses common words (Kitchen, Living Room, Hue Bridge) that a house has too.
    param([string[]]$Texts)
    foreach ($t in $Texts) { foreach ($w in Get-ShotTokens $t) { [void]$script:ShotNeutral.Add($w) } }
}

function Get-ShotNamePieces {
    # The names inside a list text ("Name [Room] #12 (...)", "Room: Scene", "A -> B (...)"): Name, Room, Scene, A, B.
    param([string]$Text)
    if (-not $Text) { return @() }
    $sep = '\s*(?:\[|\]|:\s|' + [regex]::Escape($script:ShotChars.Arrow) + '|\(|\)|#\d+|,|' + [regex]::Escape($script:ShotChars.LowComma) + ')\s*'
    @([regex]::Split($Text, $sep) | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 4 })
}

function Get-HouseTerms {
    # The house's own names, kept in memory only: every row of the System Design tree (floors, rooms, devices),
    # the project name from the title bar, the addresses in the status bar, and -Extra (default: raw\deny-extra.txt,
    # one term per line, which stays on this VM). Run it once with the System Design view showing. Each original
    # painted over during the session is added as it is painted (Set-TextReplacement).
    param([string[]]$Extra)
    $n0 = $script:ShotDenyTerms.Count
    try { foreach ($d in Get-ComposerDevices) { if ($d.Name -and $d.Name.Trim()) { [void]$script:ShotDenyTerms.Add($d.Name.Trim()) } } }
    catch { Write-Warning "System Design tree not readable ($($_.Exception.Message)); show the System Design view and run Get-HouseTerms again" }
    $title = [string](Get-ComposerWindow).Current.Name
    $i = $title.LastIndexOf(' - ')
    if ($i -ge 0) { $proj = ($title.Substring($i + 3) -replace '\s*\((Local|Remote)\)\s*$', '').Trim(); if ($proj) { [void]$script:ShotDenyTerms.Add($proj) } }
    foreach ($e in Find-ComposerElements -Name 'Connected to*') {
        foreach ($m in [regex]::Matches([string]$e.Current.Name, '\d{1,3}(?:\.\d{1,3}){3}')) { [void]$script:ShotDenyTerms.Add($m.Value) }
    }
    $file = Join-Path $script:ShotRoot 'raw\deny-extra.txt'
    if (-not $Extra -and (Test-Path $file)) { $Extra = Get-Content -Encoding UTF8 $file }
    foreach ($t in @($Extra)) { if ($t -and $t.Trim()) { [void]$script:ShotDenyTerms.Add($t.Trim()) } }
    "House terms: $($script:ShotDenyTerms.Count) ($($script:ShotDenyTerms.Count - $n0) new), kept in memory only"
}

function Get-ShotDenyPhrases {
    # The house terms and the originals painted over (with the names inside list texts) as token phrases, without
    # those made only of neutral words; rebuilt when one of the three sets has grown.
    $sig = '{0}/{1}/{2}' -f $script:ShotDenyTerms.Count, $script:ShotReplaced.Count, $script:ShotNeutral.Count
    if ($script:ShotDenySig -eq $sig) { return $script:ShotDenyPhrases }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in @($script:ShotDenyTerms) + @($script:ShotReplaced) + @($script:ShotReplaced | ForEach-Object { Get-ShotNamePieces $_ })) {
        $tok = @(Get-ShotTokens $t)
        if ($tok.Count -eq 0 -or ($tok -join '').Length -lt 4) { continue }
        if (@($tok | Where-Object { -not $script:ShotNeutral.Contains($_) }).Count -eq 0) { continue }
        [void]$set.Add(' ' + ($tok -join ' ') + ' ')
    }
    $script:ShotDenyPhrases = @($set); $script:ShotDenySig = $sig
    $script:ShotDenyPhrases
}

function Test-ShotText {
    # Why a text must not be published, as short reasons that never quote the house's data: a house name
    # (Get-HouseTerms, or an original painted over this session), an address that is not a placeholder, a
    # bridge id other than the placeholder, a Hue resource id, a device number, a Hue scene id or a light number
    # outside the neutral set (docs/screenshots-plan.md, "The neutral example set").
    param([string]$Text)
    if (-not $Text) { return @() }
    $why = New-Object System.Collections.ArrayList
    $hay = ' ' + ((Get-ShotTokens $Text) -join ' ') + ' '
    foreach ($ph in Get-ShotDenyPhrases) { if ($hay.Contains($ph)) { [void]$why.Add('a house name'); break } }
    foreach ($m in [regex]::Matches($Text, '\b\d{1,3}(?:\.\d{1,3}){3}\b')) {
        $a = $m.Value
        if ($a -notmatch '^0{0,2}10\.0{1,3}\.0{0,2}2\.0{0,2}143$' -and $a -notmatch '^192\.0{1,3}\.0{0,2}2\.\d{1,3}$' -and
            $a -notmatch '^198\.51\.100\.\d{1,3}$' -and $a -notmatch '^203\.0\.113\.\d{1,3}$') { [void]$why.Add('an address that is not a placeholder') }
    }
    foreach ($m in [regex]::Matches($Text, '(?i)\b[0-9a-f]{6}fffe[0-9a-f]{6}\b')) { if ($m.Value -ne '001788fffe123abc') { [void]$why.Add('a bridge id') } }
    $rid = '(?i)\b([0-9a-f]{8})(?:' + [regex]::Escape($script:ShotChars.Ellipsis) + '|\.\.\.|-[0-9a-f]{4}-)'
    foreach ($m in [regex]::Matches($Text, $rid)) { if ($m.Groups[1].Value.ToLowerInvariant() -notin '1a2b3c4d', '5e6f7a8b', '0f3a2b1c') { [void]$why.Add('a Hue resource id') } }
    foreach ($m in [regex]::Matches($Text, '(?i)\bdevices? (\d{1,9})\b')) { if ([long]$m.Groups[1].Value -notin 1201..1206) { [void]$why.Add('a device number') } }
    foreach ($m in [regex]::Matches($Text, '#([A-Za-z0-9]{12,20})\b')) { if ($m.Groups[1].Value -cne 'AbCdEfGhIjKlMnOp') { [void]$why.Add('a Hue scene id') } }
    foreach ($m in [regex]::Matches($Text, '#(\d{1,9})\b')) { if ([long]$m.Groups[1].Value -notin 1..8) { [void]$why.Add('a light number') } }
    @($why | Select-Object -Unique)
}

function Get-ShotOcrText {
    # The lines Windows' built-in text recognition (Windows.Media.Ocr) reads in a PNG, upscaled first because UI
    # text is small; $null when the recogniser is not available. A cross-check of the ledger, not a substitute for
    # looking at the picture.
    param([Parameter(Mandatory)][string]$Path, [int]$Scale = 3)
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $winrt = { param([string]$Name)
            foreach ($asm in 'Windows.Foundation', 'Windows.Storage', 'Windows.Storage.Streams', 'Windows.Graphics', 'Windows.Media') {
                $t = [Type]::GetType("$Name, $asm, ContentType=WindowsRuntime"); if ($t) { return $t } }
            $null }
        $tOcr = & $winrt 'Windows.Media.Ocr.OcrEngine'; $tRes = & $winrt 'Windows.Media.Ocr.OcrResult'
        $tFile = & $winrt 'Windows.Storage.StorageFile'; $tMode = & $winrt 'Windows.Storage.FileAccessMode'
        $tStream = & $winrt 'Windows.Storage.Streams.IRandomAccessStream'
        $tDec = & $winrt 'Windows.Graphics.Imaging.BitmapDecoder'; $tSoft = & $winrt 'Windows.Graphics.Imaging.SoftwareBitmap'
        if (-not ($tOcr -and $tRes -and $tFile -and $tMode -and $tStream -and $tDec -and $tSoft)) { return $null }
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $await = { param($Op, [Type]$Type) $task = $asTask.MakeGenericMethod($Type).Invoke($null, @($Op)); [void]$task.Wait(-1); $task.Result }
        $src = Read-ShotBitmap $Path
        $maxDim = 2600; try { if ($tOcr::MaxImageDimension) { $maxDim = [int]$tOcr::MaxImageDimension } } catch { }
        $s = [Math]::Max(1, [Math]::Min($Scale, [Math]::Floor($maxDim / [Math]::Max($src.Width, $src.Height))))
        $big = New-Object System.Drawing.Bitmap ([int]($src.Width * $s)), ([int]($src.Height * $s))
        $g = [System.Drawing.Graphics]::FromImage($big); $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $big.Width, $big.Height); $g.Dispose(); $src.Dispose()
        $tmp = Join-Path $script:ShotRoot ('raw\ocr-' + [IO.Path]::GetFileName($Path))
        $big.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $big.Dispose()
        $file = & $await ($tFile::GetFileFromPathAsync($tmp)) $tFile
        $stream = & $await ($file.OpenAsync($tMode::Read)) $tStream
        $dec = & $await ($tDec::CreateAsync($stream)) $tDec
        $soft = & $await ($dec.GetSoftwareBitmapAsync()) $tSoft
        $engine = $tOcr::TryCreateFromUserProfileLanguages()
        if (-not $engine) { $stream.Dispose(); return $null }
        $res = & $await ($engine.RecognizeAsync($soft)) $tRes
        $stream.Dispose()
        @($res.Lines | ForEach-Object { $_.Text })
    } catch { Write-Warning "OCR not available: $($_.Exception.Message)"; $null }
}

function Export-ShotTexts {
    # The final check's list of every text the finished PNG shows: each region with what it shows now (replaced,
    # kept as reviewed, blanked; hidden and cut-off ones counted), the texts the plan declares drawn without UI
    # Automation (tab headers, column headers, pane titles), the notes, the hold reasons and, with -Ocr, what
    # Windows' text recognition reads in the PNG. Never prints an original that was painted over or left
    # unreviewed, nor a line that trips Test-ShotText. Written next to the PNG as <name>.txt and returned.
    param([Parameter(Mandatory)]$Shot, [switch]$Ocr)
    $lines = New-Object System.Collections.ArrayList
    $folder = if ($Shot.OutPath) { Split-Path (Split-Path $Shot.OutPath) -Leaf } else { 'not saved' }
    [void]$lines.Add("== $($Shot.Name)  $($Shot.W) x $($Shot.H)  [$folder]")
    $hidden = 0
    foreach ($r in $Shot.Regions) {
        if ($r.Visibility -in 'Hidden', 'Cut', 'Outside') { $hidden++; continue }
        if ($r.Source -eq 'Container') { continue }
        switch ($r.Decision) {
            'Replaced' { $fnt = if ($r.PSObject.Properties['Font'] -and $r.Font) { "   [font: $($r.Font)]" } else { '' }   # A4: font and match score (round 46b)
                         [void]$lines.Add(('  [{0,2}] replaced  {1}{2}' -f $r.Index, $r.Final, $fnt)) }
            'Kept'     { $why = @(Test-ShotText $r.Name)
                         if ($why.Count) { [void]$lines.Add(('  [{0,2}] kept      (withheld: {1})' -f $r.Index, ($why -join ', '))) }
                         else { [void]$lines.Add(('  [{0,2}] kept      {1}' -f $r.Index, $r.Name)) } }
            'Blanked'  { [void]$lines.Add(('  [{0,2}] blanked' -f $r.Index)) }
            'Hold'     { [void]$lines.Add(('  [{0,2}] HOLD      {1}' -f $r.Index, $r.Final)) }
            default    { [void]$lines.Add(('  [{0,2}] UNREVIEWED {1} {2} (not printed)' -f $r.Index, $r.Source, $r.Class)) }
        }
    }
    if ($hidden) { [void]$lines.Add("  ($hidden texts under a dialog or list, or cut off: not in the picture)") }
    foreach ($s in @($Shot.Static)) { if ($s) { [void]$lines.Add("  [static]  $s") } }
    foreach ($n in @($Shot.Notes)) { [void]$lines.Add("  note: $n") }
    foreach ($n in @($Shot.Reasons)) { [void]$lines.Add("  HOLD: $n") }
    if ($Ocr -and $Shot.OutPath) {
        $read = Get-ShotOcrText -Path $Shot.OutPath
        if ($null -eq $read) { [void]$lines.Add('  ocr: not available on this machine') }
        else { foreach ($t in $read) { $why = @(Test-ShotText $t); if ($why.Count) { [void]$lines.Add("  [ocr] (line withheld: $($why -join ', '))") } else { [void]$lines.Add("  [ocr] $t") } } }
    }
    if ($Shot.OutPath) { [IO.File]::WriteAllLines([IO.Path]::ChangeExtension($Shot.OutPath, '.txt'), [string[]]$lines, (New-Object System.Text.UTF8Encoding $true)) }
    $lines
}

# ---- Steps of a plan row: read, open, cancel (EditValue and RunAction only when the plan allows them) ----------------

function Resolve-ShotName {
    # A plan text with its {PLACEHOLDERS} replaced from -Devices (the house's device names never enter the plan).
    param([string]$Text, [hashtable]$Devices)
    if (-not $Text -or $Text -notmatch '\{[A-Z_]+\}') { return $Text }
    foreach ($m in [regex]::Matches($Text, '\{([A-Z_]+)\}')) {
        $k = $m.Groups[1].Value
        if (-not $Devices -or -not $Devices.ContainsKey($k)) { throw "The plan needs -Devices @{ $k = '<device name>' }" }
        $Text = $Text.Replace($m.Value, [string]$Devices[$k])
    }
    $Text
}

function Hide-ShotDevices {
    # A message with every -Devices value turned back into its placeholder, so a report never names a device.
    param([string]$Text, [hashtable]$Devices)
    if (-not $Text -or -not $Devices) { return $Text }
    foreach ($k in $Devices.Keys) { $v = [string]$Devices[$k]; if ($v) { $Text = $Text.Replace($v, '{' + $k + '}') } }
    $Text
}

function Open-ShotPropertyList {
    # Drop the list of a property's combo box (Room Mappings, Recall As) with a click on its button; nothing is chosen.
    param([Parameter(Mandatory)][string]$Label)
    $row = Get-ShotPropertyRow -Label $Label
    if (-not $row.Combo) { throw "Property '$Label' has no drop-down list" }
    $h = [IntPtr]$row.Combo.Current.NativeWindowHandle
    $p = [C4.Shots]::ComboParts($h); if (-not $p) { throw "No combo box information for '$Label'" }
    if ($p[8] -ne 0 -and [C4.Shots]::IsWindowVisible([IntPtr]$p[8])) { return [IntPtr]$p[8] }
    Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($p[4] + $p[6] / 2)) -Y ([int]($p[5] + $p[7] / 2))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 3000) {
        $p = [C4.Shots]::ComboParts($h)
        if ($p -and $p[8] -ne 0 -and [C4.Shots]::IsWindowVisible([IntPtr]$p[8])) { Move-MouseAway; Start-Sleep -Milliseconds 300; return [IntPtr]$p[8] }
        Start-Sleep -Milliseconds 150
    }
    throw "The list of '$Label' did not open"
}

function Close-ShotPropertyList {
    # Close a dropped property list with Escape, the manual's way (nothing changes), sent only to that combo box;
    # a Set button left waiting in the row is answered with its Cancel.
    param([Parameter(Mandatory)][string]$Label)
    $row = Get-ShotPropertyRow -Label $Label
    if (-not $row.Combo) { return }
    $h = [IntPtr]$row.Combo.Current.NativeWindowHandle
    $p = [C4.Shots]::ComboParts($h)
    if ($p -and $p[8] -ne 0 -and [C4.Shots]::IsWindowVisible([IntPtr]$p[8])) {
        $target = (Get-ComposerFocus).FocusHwnd
        if ($target -ne $h -and [C4.Win]::GetAncestor($target, 1) -ne $h) { throw "Refusing Escape: the focus is not on the '$Label' list; stop and report (rule 5)" }
        Send-KeysTo -ExpectedHwnd $target -Keys '{ESC}' -DelayMs 400
    }
    Start-Sleep -Milliseconds 300
    $row = Get-ShotPropertyRow -Label $Label
    if ($row.Buttons | Where-Object { $_.Current.Name -eq 'Set' }) {
        $cancel = $row.Buttons | Where-Object { $_.Current.Name -eq 'Cancel' } | Select-Object -First 1
        if (-not $cancel) { throw "A Set button waits in '$Label' and it has no Cancel: stop and report" }
        $r = $cancel.Current.BoundingRectangle
        Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2))
        Start-Sleep -Milliseconds 500; Move-MouseAway
    }
}

function Edit-ShotPropertyValue {
    # Type -Text into a property's value so that Composer shows the row's Set and Cancel buttons, and leave it so for
    # the picture. Nothing reaches Director before Set, which this never clicks; CancelEdit undoes the typing.
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Text)
    $row = Get-ShotPropertyRow -Label $Label
    if (-not $row.Edit) { throw "Property '$Label' has no text field" }
    $h = [IntPtr]$row.Edit.Current.NativeWindowHandle; $r = $row.Edit.Current.BoundingRectangle
    $script:ShotEdit = [pscustomobject]@{ Label = $Label; Before = [C4.ListView]::GetWindowText($h) }
    Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($r.X + $r.Width - 10)) -Y ([int]($r.Y + $r.Height / 2))
    $f = $null
    for ($try = 0; $try -lt 6; $try++) { $f = Get-ComposerFocus; if ($f.FocusHwnd -eq $h) { break }; Start-Sleep -Milliseconds 300 }
    if ($f.FocusHwnd -ne $h -or $f.MenuActive) { throw "The value of '$Label' did not take the focus" }
    Send-KeysTo -ExpectedHwnd $h -Keys '{HOME}+{END}' -DelayMs 150
    Send-KeysTo -ExpectedHwnd $h -Keys ($Text -replace '([+^%~(){}\[\]])', '{$1}') -DelayMs 400
    # Composer shows the row's Set and Cancel only once the edit is ended with Enter (round 46b); Enter does not send
    # anything to Director, only Set does, which this never clicks.
    Send-KeysTo -ExpectedHwnd $h -Keys '{ENTER}' -DelayMs 500
    Move-MouseAway
    if (-not ((Get-ShotPropertyRow -Label $Label).Buttons | Where-Object { $_.Current.Name -eq 'Set' })) { throw "No Set button appeared in '$Label' (is the typed value the old one?)" }
}

function Undo-ShotPropertyEdit {
    # Click the row's Cancel (never Set) and check that the value reads as before.
    param([Parameter(Mandatory)][string]$Label)
    $row = Get-ShotPropertyRow -Label $Label
    $cancel = $row.Buttons | Where-Object { $_.Current.Name -eq 'Cancel' } | Select-Object -First 1
    if ($cancel) {
        $r = $cancel.Current.BoundingRectangle
        Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2))
        Start-Sleep -Milliseconds 600; Move-MouseAway
    }
    $row = Get-ShotPropertyRow -Label $Label
    if ($row.Buttons | Where-Object { $_.Current.Name -eq 'Set' }) { throw "The Set button of '$Label' is still there: stop and report (rule 3)" }
    if ($script:ShotEdit -and $script:ShotEdit.Label -eq $Label -and $row.Edit) {
        $now = [C4.ListView]::GetWindowText([IntPtr]$row.Edit.Current.NativeWindowHandle)
        if ($now -ne $script:ShotEdit.Before) { throw "'$Label' reads '$now' instead of '$($script:ShotEdit.Before)': stop and report" }
    }
    $script:ShotEdit = $null
}

function Open-ShotMenu {
    # Open a menu of the menu bar with a click (never ALT) and rest the pointer on the item like -Hover, which the
    # menu then shows highlighted. Nothing is chosen.
    param([Parameter(Mandatory)][string]$Name, [string]$Hover)
    $item = Get-ShotMenuBarItem -Name $Name
    $r = $item.Current.BoundingRectangle
    Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2))
    $pop = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $pop -and $sw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 200; $pop = Get-ShotMenuPopup }
    if (-not $pop) { throw "The '$Name' menu did not open" }
    if ($Hover) {
        $cond = New-Object System.Windows.Automation.PropertyCondition($script:ShotA::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
        $hv = $pop.FindAll($script:ShotScope::Descendants, $cond) | Where-Object { ($_.Current.Name -replace '&', '') -like $Hover } | Select-Object -First 1
        if ($hv) { $hr = $hv.Current.BoundingRectangle; $hx = [int]($hr.X + $hr.Width / 2); $hy = [int]($hr.Y + $hr.Height / 2) }
        else {
            # a native popup that UI Automation shows as an empty pane (round 46b): the item from the menu itself
            $ni = Get-ShotNativeMenuItems -PopupHwnd ([IntPtr]$pop.Current.NativeWindowHandle) | Where-Object { $_.Label -like $Hover } | Select-Object -First 1
            if (-not $ni) { throw "No item like '$Hover' in the '$Name' menu" }
            $hx = [int]($ni.Rect.X + $ni.Rect.Width / 2); $hy = [int]($ni.Rect.Y + $ni.Rect.Height / 2)
        }
        [void][C4.Native]::SetCursorPos($hx, $hy)
        [C4.Native]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [C4.Native]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)   # a real move, for the highlight
        Start-Sleep -Milliseconds 500
    }
    $pop
}

function Close-ShotMenu {
    # Close the open menu with a second click on its title (no keys while a menu is active, rule 5).
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-ComposerFocus).MenuActive -and -not (Get-ShotMenuPopup)) { return }
    $r = (Get-ShotMenuBarItem -Name $Name).Current.BoundingRectangle
    Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2))
    Start-Sleep -Milliseconds 500
    if ((Get-ComposerFocus).MenuActive -or (Get-ShotMenuPopup)) { throw "The '$Name' menu is still open: stop and report (rule 3)" }
    Move-MouseAway
}

function Select-ShotView {
    # Switch Composer's view with its button at the lower left (System Design, Connections).
    param([Parameter(Mandatory)][string]$Name)
    $f = ConvertTo-ShotRect ([C4.Shots]::FrameBounds((Get-ComposerMainHandle)))
    $btn = Find-ComposerElements -Name ([WildcardPattern]::Escape($Name)) | Where-Object {
        $b = $_.Current.BoundingRectangle
        $_.Current.Name -eq $Name -and $b.Height -gt 10 -and $b.Height -lt 45 -and $b.Y -gt ($f.Y + $f.Height / 2) -and $b.X -lt ($f.X + $f.Width / 3) } | Select-Object -First 1
    if ($btn) {
        $r = $btn.Current.BoundingRectangle
        $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    } else {
        # Composer draws its view buttons without UI Automation names (round 46b): a fixed stack under the left
        # navigator pane, 28 px apart, in this order, the first centred 20 px below the pane.
        $order = @('System Design', 'Connections', 'Media', 'Agents', 'Programming')
        $idx = [array]::IndexOf($order, $Name)
        if ($idx -lt 0) { throw "View button '$Name' not found" }
        $pane = Find-ComposerElements -Class 'Window.8' | Where-Object { $b = $_.Current.BoundingRectangle
            -not $b.IsEmpty -and $b.X -lt ($f.X + 20) -and $b.Y -gt ($f.Y + 50) -and $b.Y -lt ($f.Y + 100) -and $b.Height -gt 300 -and $b.Width -gt 250 -and $b.Width -lt 450 } |
            Sort-Object { $_.Current.BoundingRectangle.Height } -Descending | Select-Object -First 1
        if (-not $pane) { throw "View button '$Name' not found (no navigator pane to measure from)" }
        $pr = $pane.Current.BoundingRectangle
        $x = [int]($pr.X + 75); $y = [int]($pr.Bottom + 20 + 28 * $idx)
    }
    Invoke-SafeClick -Hwnd (Get-ComposerMainHandle) -X $x -Y $y
    Start-Sleep -Milliseconds 1500; Move-MouseAway
}

function Close-ShotDialogs {
    # Cancel the Select picker and the Action Parameter List, innermost first; any other dialog stops the run.
    for ($i = 0; $i -lt 4; $i++) {
        $d = Get-ComposerDialog
        if (-not $d) { return }
        $n = $d.Current.Name
        if ($n -ne 'Select' -and $n -ne 'Action Parameter List') { throw "Unexpected dialog '$n' is open: stop and report (rule 3)" }
        if (-not (Close-ComposerDialog -Button 'Cancel')) { throw "Dialog '$n' did not close on Cancel: stop and report" }
        Start-Sleep -Milliseconds 300
    }
    if (Get-ComposerDialog) { throw "A dialog is still open after four Cancels: stop and report" }
}

function Invoke-ShotStep {
    # One setup or teardown step of a plan row (docs/screenshots-plan.md, "Steps").
    param([Parameter(Mandatory)]$Step, $Plan, [hashtable]$Devices)
    $name = Resolve-ShotName ([string]$Step.Name) $Devices
    switch ([string]$Step.Do) {
        'Device'        { [void](Select-ComposerDevice -Name $name); Start-Sleep -Milliseconds 600 }
        'Tab'           { Select-ComposerTab -Name $name
                          $page = $script:ShotWalker.GetFirstChild((Get-ComposerTabControl))
                          if (-not $page -or $page.Current.Name -ne $name) { throw "Tab '$name' did not open (rule 12: select the device again)" } }
        'Action'        { $d = Invoke-ComposerAction -Name $name
                          if (-not $d -or $d.Current.Name -ne 'Action Parameter List') { throw "Action '$name' opened no Action Parameter List" } }
        'Picker'        { if (-not (Open-ComposerPicker -Label ([string]$Step.Label))) { throw "The '$($Step.Label)' picker did not open" }; Start-Sleep -Milliseconds 400 }
        'DropList'      { [void](Open-ShotPropertyList -Label ([string]$Step.Label)) }
        'CloseList'     { Close-ShotPropertyList -Label ([string]$Step.Label) }
        'EditValue'     { if (-not $Plan.AllowEditCancel) { throw 'EditValue needs "AllowEditCancel": true in the plan' }
                          Edit-ShotPropertyValue -Label ([string]$Step.Label) -Text ([string]$Step.Text) }
        'CancelEdit'    { Undo-ShotPropertyEdit -Label ([string]$Step.Label) }
        'RunAction'     { if (-not $Plan.AllowRunAction) {
                              if ($Step.Optional) { Write-Host "    (RunAction $name skipped: the plan does not allow it)"; return }
                              throw 'RunAction needs "AllowRunAction": true in the plan' }
                          $d = Invoke-ComposerAction -Name $name -TimeoutMs 2500
                          if ($d) { Close-ShotDialogs; throw "Action '$name' opened a dialog (cancelled): stop and report" }
                          Start-Sleep -Milliseconds $(if ($Step.WaitMs) { [int]$Step.WaitMs } else { 3000 }) }
        'Menu'          { [void](Open-ShotMenu -Name $name -Hover ([string]$Step.Hover)) }
        'CloseMenu'     { Close-ShotMenu -Name $name }
        'View'          { Select-ShotView -Name $name }
        'CancelDialogs' { Close-ShotDialogs }
        'Wait'          { Start-Sleep -Milliseconds ([int]$Step.Ms) }
        default         { throw "Unknown step '$($Step.Do)'" }
    }
}

# ---- Running a plan ---------------------------------------------------------------------------------------------------

function New-ShotFromCrop {
    # The layers and crop of a plan row's picture (docs/screenshots-plan.md, "Crops"), captured with Save-PaneShot.
    param([Parameter(Mandatory)]$Row)
    $c = $Row.Crop
    $margin = if ($null -ne $c.Margin) { [int]$c.Margin } else { 0 }
    switch ([string]$c.Kind) {
        'TabControl' {
            $tab = Get-ComposerTabControl; if (-not $tab) { throw "Tab control not found" }
            return (Save-PaneShot -Name $Row.Name -Element $tab -Margin $margin -Layers @(New-ShotLayer -Element $tab))
        }
        'Dialog' {
            $apl = Get-ShotDialog -Name 'Action Parameter List'
            $layers = @(New-ShotLayer -Element $apl)
            $sel = $null; try { $sel = Get-ShotDialog -Name 'Select' -Parent $apl } catch { }
            if ($sel) { $layers += New-ShotLayer -Element $sel }
            $shot = Save-PaneShot -Name $Row.Name -Element $apl -Margin $margin -Layers $layers
            if ($sel -and -not $layers[0].Bounds.Contains($layers[1].Bounds)) { [void]$shot.Problems.Add('the Select picker reaches outside its dialog, so the crop cuts it: move the dialog and run the row again') }
            return $shot
        }
        'PropertyRow' {
            $m = if ($null -ne $c.Margin) { $margin } else { 6 }
            $pr = Get-ShotPropertyRow -Label ([string]$c.Label)
            return (Save-PaneShot -Name $Row.Name -Element (@($pr.Label) + @($pr.Values)) -Margin $m -Layers @(New-ShotLayer -Element $pr.Page))
        }
        'PropertyList' {
            $m = if ($null -ne $c.Margin) { $margin } else { 6 }
            $pr = Get-ShotPropertyRow -Label ([string]$c.Label)
            if (-not $pr.Combo) { throw "'$($c.Label)' has no drop-down list" }
            $p = [C4.Shots]::ComboParts([IntPtr]$pr.Combo.Current.NativeWindowHandle)
            if (-not $p -or $p[8] -eq 0 -or -not [C4.Shots]::IsWindowVisible([IntPtr]$p[8])) { throw "The list of '$($c.Label)' is not open (DropList first)" }
            $ll = New-ShotLayer -ListHwnd ([IntPtr]$p[8])
            $u = [System.Drawing.Rectangle]::Union([System.Drawing.Rectangle]::Union((Get-ShotBounds $pr.Label), (Get-ShotBounds $pr.Combo)), $ll.Bounds)
            $u = New-ShotRect ($u.X - $m) ($u.Y - $m) ($u.Width + 2 * $m) ($u.Height + 2 * $m)
            return (Save-PaneShot -Name $Row.Name -Rect $u -Layers @((New-ShotLayer -Element $pr.Page), $ll))
        }
        'Element' {
            $want = [string]$c.Name
            $e = Find-ComposerElements -Name ([WildcardPattern]::Escape($want)) | Where-Object { $_.Current.Name -eq $want } |
                Sort-Object { $_.Current.BoundingRectangle.Width * $_.Current.BoundingRectangle.Height } -Descending | Select-Object -First 1
            if (-not $e) { throw "Element '$want' not found" }
            return (Save-PaneShot -Name $Row.Name -Element $e -Margin $margin -Layers @(New-ShotLayer -Element $e))
        }
        'Menu' {
            $bar = Get-ShotMenuBarItem -Name ([string]$c.Menu); $pop = Get-ShotMenuPopup
            if (-not $pop) { throw "No menu is open (Menu step first)" }
            $pb = Get-ShotBounds $pop; $bb = Get-ShotBounds $bar
            $rect = New-ShotRect $pb.X $bb.Y $pb.Width ($pb.Bottom - $bb.Y)
            $layers = @(); $mb = Get-ShotMenuBar
            if ($mb) { $layers += New-ShotLayer -Element $mb }
            $layers += New-ShotLayer -Element $pop
            return (Save-PaneShot -Name $Row.Name -Rect $rect -Layers $layers)
        }
        default { throw "Unknown crop kind '$($c.Kind)'" }
    }
}

function Set-ShotValue {
    # Apply one plan value to a region: '@keep' (reviewed as safe), '@blank', '@hold', or the neutral text to paint.
    param($Shot, $Region, [string]$Spec)
    switch ($Spec) {
        '@keep'  { $Region.Decision = 'Kept' }
        '@blank' { Set-TextReplacement -Shot $Shot -Region $Region -Blank }
        '@hold'  { $Region.Decision = 'Hold'; $Region.Final = "the plan holds this text for a decision (row '$($Region.Label)')" }
        default  { Set-TextReplacement -Shot $Shot -Region $Region -Text $Spec }
    }
}

function Resolve-ShotRow {
    # Decide every region of a row's picture: list rows from Items in order (rows beyond them blanked, or with
    # "Rest": "Truncate" the picture cut below them), values by their row label from Values, exact texts from
    # Texts, everything else Kept when the plan reviewed it as safe (Keep, KeepPatterns) and Unreviewed otherwise,
    # which sends the picture to hold\.
    param([Parameter(Mandatory)]$Shot, [Parameter(Mandatory)]$Row, $Plan, [hashtable]$Devices)
    $keep = New-Object 'System.Collections.Generic.HashSet[string]' ($script:ShotCmp)
    foreach ($k in @($Plan.Keep) + @($Row.Keep)) { if ($k) { [void]$keep.Add(([string]$k).Trim()) } }
    $keepRx = @(@($Plan.KeepPatterns) + @($Row.KeepPatterns) | Where-Object { $_ })
    $values = @{}
    if ($Row.Values) { foreach ($p in $Row.Values.PSObject.Properties) { $values[$p.Name] = [string]$p.Value } }
    $texts = @{}; $textKey = @{}
    if ($Row.Texts) { foreach ($p in $Row.Texts.PSObject.Properties) { $k = Resolve-ShotName $p.Name $Devices; $texts[$k] = [string]$p.Value; $textKey[$k] = $p.Name } }
    $items = $null; if ($null -ne $Row.Items) { $items = @($Row.Items | ForEach-Object { [string]$_ }) }
    $rest = if ($Row.Rest) { [string]$Row.Rest } else { 'Blank' }
    $Shot.Static = @($Row.Static | Where-Object { $_ })
    $listBg = @{}
    foreach ($r in $Shot.Regions) {
        if (-not $r.List) { continue }
        if (-not $listBg.ContainsKey($r.List)) {
            $cb = ConvertTo-ShotImageRect $Shot (ConvertTo-ShotRect ([C4.Shots]::ClientBounds([IntPtr]$r.List)))
            $listBg[$r.List] = if ($cb.IsEmpty) { $null } else { ([C4.Shots]::Probe($Shot.Bitmap, $cb, $script:ShotInk))[1] }
        }
        $r.ListBackground = $listBg[$r.List]
    }
    # One font per list (round 46b): every row is measured, and the best match (lowest score) paints all of that
    # list's rows; measuring row by row gave a list of mixed faces and weights.
    $listFont = @{}
    if ($null -ne $items) {
        $best = @{}; $bestRow = @{}
        foreach ($r in $Shot.Regions) {
            if ($r.Visibility -in 'Hidden', 'Cut', 'Outside' -or -not $r.List -or $r.Source -notin 'ListItem', 'ComboItem' -or $r.Column -ne 0 -or $r.Rect.IsEmpty) { continue }
            $nm = ([string]$r.Name).Trim(); if (-not $nm) { continue }
            $pr = [C4.Shots]::Probe($Shot.Bitmap, $r.Rect, $script:ShotInk); if (-not $pr -or $pr[0] -ne 1) { continue }
            $m = [C4.Shots]::Match($Shot.Bitmap, $r.Rect, $nm, [string[]]$script:ShotFamilies, [single]7, [single]11, [single]0.25, $script:ShotInk)
            if ($m -and (-not $best.ContainsKey($r.List) -or $m.Score -lt $best[$r.List].Score)) { $best[$r.List] = $m; $bestRow[$r.List] = $r.Row }
        }
        foreach ($k in @($best.Keys)) {
            $m = $best[$k]
            $listFont[$k] = [pscustomobject]@{ Family = $m.Family; Size = $m.Size; Bold = $m.Bold; Renderer = $m.Renderer; OffsetX = $m.OffsetX; OffsetY = $m.OffsetY }
            [void]$Shot.Notes.Add(('list font {0} {1} pt{2}, renderer {3}: measured on row {4}, score {5}' -f $m.Family, $m.Size, $(if ($m.Bold) { ' bold' } else { '' }), $m.Renderer, $bestRow[$k], [Math]::Round($m.Score, 1)))
        }
    }
    $found = @{}
    foreach ($r in $Shot.Regions) {
        if ($r.Visibility -in 'Hidden', 'Cut', 'Outside') { continue }
        if ($r.Source -eq 'Container') { $r.Decision = 'Container'; if ($texts.ContainsKey(([string]$r.Name).Trim())) { $found[([string]$r.Name).Trim()] = 'container' }; continue }
        $name = ([string]$r.Name).Trim()
        try {
            if ($null -ne $items -and $r.Source -in 'ListItem', 'ComboItem' -and $r.Column -eq 0) {
                if ($r.Row -lt $items.Count) {
                    if ($r.List -and $listFont.ContainsKey($r.List)) { Set-TextReplacement -Shot $Shot -Region $r -Text $items[$r.Row] -Font $listFont[$r.List] }
                    else { Set-TextReplacement -Shot $Shot -Region $r -Text $items[$r.Row] }
                }
                else { Set-TextReplacement -Shot $Shot -Region $r -Blank }   # with Truncate the cut below removes the row too
                continue
            }
            if ($texts.ContainsKey($name)) { Set-ShotValue -Shot $Shot -Region $r -Spec $texts[$name]; $found[$name] = 'painted'; continue }
            if ($r.Label -and $values.ContainsKey($r.Label)) { Set-ShotValue -Shot $Shot -Region $r -Spec $values[$r.Label]; continue }
            if ($keep.Contains($name) -or @($keepRx | Where-Object { $name -match $_ }).Count -gt 0) { $r.Decision = 'Kept'; continue }
            $r.Decision = 'Unreviewed'
        } catch { $r.Decision = 'Hold'; $r.Final = 'could not paint: ' + (Hide-ShotDevices $_.Exception.Message $Devices) }
    }
    foreach ($k in $texts.Keys) {
        if (-not $found.ContainsKey($k)) { [void]$Shot.Problems.Add("the text $($textKey[$k]) was expected but is not in the picture's texts: check the crop, or paint it with Set-TextReplacement -Rect") }
        elseif ($found[$k] -eq 'container') { [void]$Shot.Problems.Add("the text $($textKey[$k]) is drawn by a container: locate it (Get-ShotRegionTable) and paint it with Set-TextReplacement -Rect") }
    }
    if ($Row.ClearScrollbars) {
        foreach ($h in @($Shot.Regions | Where-Object { $_.Source -eq 'ListItem' -and $_.List } | ForEach-Object { $_.List } | Select-Object -Unique)) { Clear-ShotScrollBars -Shot $Shot -Hwnd ([IntPtr]$h) }
    }
    if ($rest -eq 'Truncate' -and $null -ne $items) {
        $first = $Shot.Regions | Where-Object { $_.Source -eq 'ComboItem' -and $_.Row -eq $items.Count -and -not $_.Rect.IsEmpty } | Select-Object -First 1
        $layer = $Shot.Layers | Where-Object { $_.Kind -eq 'ComboList' } | Select-Object -First 1
        if ($first -and $layer) {
            $lb = ConvertTo-ShotImageRect $Shot $layer.Bounds
            $border = [C4.Shots]::Pixel($Shot.Bitmap, $lb.X, $first.Rect.Y - 1)
            Set-ShotBottom -Shot $Shot -Y ($first.Rect.Y + 1) -X1 $lb.X -X2 $lb.Right -BorderColor $border
        }
    }
}

function Invoke-ShotPlan {
    # Run a plan (JSON; docs/screenshots-plan.md has it and Export-ShotPlanFromDoc extracts it): for each row its setup
    # steps, the crop, every text decided and painted, the PNG to doc\ or hold\ with its ledger, and always its teardown
    # steps; the window title and tree row count are checked after every row (rule 6); then a summary. -Devices maps
    # the plan's {PLACEHOLDERS} to the house's device names, on the command line only; -Only runs some rows by file name.
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Devices = @{}, [string[]]$Only, [switch]$Ocr)
    $plan = (Get-Content -Raw -Encoding UTF8 $Path) | ConvertFrom-Json
    if ($plan.Root) { [void](Initialize-Shots -Root ([string]$plan.Root)) } else { [void](Initialize-Shots -Root $script:ShotRoot) }
    $words = @($plan.Keep) + @($plan.NeutralWords)
    foreach ($row in $plan.Shots) {
        $words += @($row.Keep) + @($row.Items) + @($row.Static)
        foreach ($o in @($row.Values, $row.Texts)) { if ($o) { $words += @($o.PSObject.Properties | ForEach-Object { [string]$_.Value }) } }
    }
    Add-ShotNeutral -Texts ([string[]]@($words | Where-Object { $_ -and ([string]$_) -notlike '@*' }))
    if ($script:ShotDenyTerms.Count -eq 0) { Get-HouseTerms | Write-Host }
    $base = $null; try { $base = Get-ComposerBaseline } catch { Write-Warning 'No baseline (is the System Design view showing?); rule 6 is not checked' }
    $summary = @()
    foreach ($row in $plan.Shots) {
        if ($Only -and $Only -notcontains $row.Name) { continue }
        if ($row.Skip) { $summary += [pscustomobject]@{ Name = $row.Name; Folder = 'skipped'; Reasons = @([string]$row.Skip) }; continue }
        Write-Host "--- $($row.Name)"
        $shot = $null; $err = $null
        try {
            if (-not (Get-ComposerDialog)) { [void](Show-Composer) }
            foreach ($s in @($row.Setup)) { if ($s) { Invoke-ShotStep -Step $s -Plan $plan -Devices $Devices } }
            $shot = New-ShotFromCrop -Row $row
            [void](Get-TextRegions -Shot $shot)
            Resolve-ShotRow -Shot $shot -Row $row -Plan $plan -Devices $Devices
        } catch { $err = Hide-ShotDevices $_.Exception.Message $Devices }
        finally {
            foreach ($s in @($row.Teardown)) {
                if (-not $s) { continue }
                try { Invoke-ShotStep -Step $s -Plan $plan -Devices $Devices } catch { $err = (@($err, ('teardown: ' + (Hide-ShotDevices $_.Exception.Message $Devices))) | Where-Object { $_ }) -join '; ' }
            }
        }
        if ($shot) {
            if ($err) { [void]$shot.Problems.Add("error: $err") }
            $res = Save-ShotResult -Shot $shot
            Export-ShotTexts -Shot $shot -Ocr:$Ocr | Write-Host
            $summary += $res
            $shot.Bitmap.Dispose()
        } else {
            $summary += [pscustomobject]@{ Name = $row.Name; Folder = 'failed'; Reasons = @($err) }
            Write-Host "    failed: $err"
        }
        if ($base) {
            try { $chk = Assert-ComposerUnchanged -Baseline $base; if (-not $chk.Ok) { Write-Warning "Window title or tree row count changed after $($row.Name): stop and report (rule 6)"; break } }
            catch { Write-Warning "Rule 6 check not possible after $($row.Name) (view?): $($_.Exception.Message)" }
        }
        if ($err -match 'stop and report') { Write-Warning 'Stopping the plan (rule 3).'; break }
    }
    $summary | Format-Table Name, Folder, @{ n = 'Reasons'; e = { $_.Reasons -join '; ' } } -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    $summary
}

function Export-ShotPlanFromDoc {
    # Write the JSON plan that follows the line <!-- shot-plan --> in docs/screenshots-plan.md to -Out (UTF-8).
    param([Parameter(Mandatory)][string]$Markdown, [Parameter(Mandatory)][string]$Out)
    $md = Get-Content -Raw -Encoding UTF8 $Markdown
    $m = [regex]::Match($md, '<!-- shot-plan -->\s*```json\s*(.*?)```', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { throw "No JSON block after '<!-- shot-plan -->' in $Markdown" }
    $json = $m.Groups[1].Value
    $null = $json | ConvertFrom-Json
    [IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false))
    Get-Item $Out
}

function Get-ShotRegionTable {
    # The regions of a shot as a table, for working on a row by hand. Without -Originals the house's texts are
    # not shown (only what the picture shows now); with it they are printed here only: never paste them into a report.
    param([Parameter(Mandatory)]$Shot, [switch]$Originals)
    foreach ($r in $Shot.Regions) {
        $shown = switch ($r.Decision) { 'Replaced' { $r.Final } 'Kept' { $r.Name } 'Blanked' { '' } default { '(not shown)' } }
        $o = [ordered]@{ Index = $r.Index; Source = $r.Source; Class = $r.Class; Row = $r.Row; Label = $r.Label; Visibility = $r.Visibility
            Decision = $r.Decision; Rect = ('{0},{1} {2}x{3}' -f $r.Rect.X, $r.Rect.Y, $r.Rect.Width, $r.Rect.Height); Shows = $shown }
        if ($Originals) { $o.Original = $r.Name }
        [pscustomobject]$o
    }
}
