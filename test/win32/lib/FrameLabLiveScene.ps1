# FrameLabLiveScene (T2397) - the T2373 frame lab's live scene for one matrix
# cell: a solid backdrop behind the app, the scene scorer's edges and cards
# derived from the cell's real geometry, calibrated on the cell's still frame,
# and the bridge that turns the scorer's records into the cell's numbers.
#
# WHY A BACKDROP. GfsSceneScorer (lib\FrameLabScene.ps1, T2394) finds the
# window's right and bottom edges by scanning in from a solid colour behind the
# window until that colour stops. On the user's real desktop what is behind
# the window is whatever they left there - a wallpaper, another app - and a
# scan through it finds nothing it can trust. So every cell puts a borderless
# window of ONE colour over the capture rect, directly BELOW the app in the
# z-order, never activated and never topmost. Show-FrameLabBackdrop.
#
# WHAT THE SCENE IS. New-FrameLabCellSceneSpec reads the geometry the launcher
# measured (physical pixels: the window rect, every pane's content rect and
# the card index it runs, the sidebar edge) and decides, with no pixels:
#
#   edges  window-right / window-bottom, only where the capture rect leaves
#          backdrop beyond them (a frame-right capture has none below the
#          window, so its bottom is fixed, which it is); one divider edge per
#          pane with a neighbour to its right (v:<pane>) or below (h:<pane>),
#          scanned from inside that pane for the divider's colour; the sidebar
#          edge, scanned leftward from inside the first column. Every edge is
#          located on every frame - in a ratio split an inner divider moves
#          when the window does, so "fixed" is only ever said of a side that
#          really cannot move. The divider the gesture grabs is named
#          'divider', the name the catalogue's Track uses.
#   cards  one per pane, each side riding the edge it touches or fixed.
#
# New-FrameLabCellScene then reads the colours off the still frame (divider,
# sidebar edge, each pane's padding), refuses colours a card also uses, builds
# the scorer, calibrates it, and requires every edge to have been found where
# the geometry says it is. A refusal is the cell's verdict - `incomplete` -
# never a pass: Invoke-FrameLabCell's Scene hook.
#
# NOT MODELLED (T2398): interactions that move the window as a whole
# (caption-dblclick, aero-snap, maximize-button) and the triggers whose edge
# is not one of these (banner, hero, tab-switch, split-close). Their spec says
# so in Unsupported and the cell reads incomplete with that reason.
#
# Acceptance: test\win32\frame-lab-live-scene.ps1.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

. (Join-Path $PSScriptRoot 'FrameLabScene.ps1')

# A mid green: 32 from every palette level on every channel (the palette is a
# 0x20/0x60/0xA0/0xE0 grid), and far from black, white and the dark themes.
$script:FrameLabBackdropColor = 0x40C080

# How far apart two rects may be and still be neighbours (a divider, a border).
$script:FrameLabSceneGap = 16

# The interactions whose scene this file can build.
$script:FrameLabSceneSupported = @('frame-right', 'frame-bottom', 'frame-corner', 'divider', 'sidebar-edge', 'blade-glide')

$script:FrameLabBackdropSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

// A borderless window of one colour, on its own thread with its own pump.
// WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW: it never takes the foreground and never
// shows in the taskbar or Alt+Tab. Placed BELOW the given window, never
// topmost. Physical pixels (its thread is per-monitor aware v2).
public sealed class GflBackdrop : IDisposable {
    delegate IntPtr WndProcFn(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX {
        public uint cbSize, style; public WndProcFn lpfnWndProc; public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct PAINTSTRUCT { public IntPtr hdc; public int erase; public RECT rc; public int restore, incUpdate; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] r; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern ushort RegisterClassExW(ref WNDCLASSEX c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int c);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT p);
    [DllImport("user32.dll")] static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT p);
    [DllImport("user32.dll")] static extern int FillRect(IntPtr dc, ref RECT r, IntPtr brush);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr d);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint c);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);

    const uint WS_POPUP = 0x80000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_NOOWNERZORDER = 0x200;
    const uint WM_DESTROY = 0x2, WM_CLOSE = 0x10, WM_PAINT = 0xF, WM_ERASEBKGND = 0x14, WM_PRINTCLIENT = 0x318;
    const uint WM_MOUSEACTIVATE = 0x21, WM_NCHITTEST = 0x84;
    static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    const string ClassName = "GhozttyFrameLabBackdrop";
    static WndProcFn proc;                 // held: the class outlives any one window
    static bool registered;
    static readonly object regGate = new object();

    public IntPtr Hwnd;
    public int Color;                      // 0xRRGGBB
    public string Error = "";
    IntPtr brush, desk;
    Thread th;

    static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l) {
        switch (m) {
            case WM_MOUSEACTIVATE: return new IntPtr(3);        // MA_NOACTIVATE
            case WM_NCHITTEST: return new IntPtr(-1);           // HTTRANSPARENT
            case WM_ERASEBKGND: return new IntPtr(1);
            case WM_PAINT: {
                PAINTSTRUCT ps; IntPtr dc = BeginPaint(h, out ps);
                Fill(h, dc); EndPaint(h, ref ps); return IntPtr.Zero;
            }
            case WM_PRINTCLIENT: Fill(h, w); return IntPtr.Zero;
            case WM_CLOSE: DestroyWindow(h); return IntPtr.Zero;
            case WM_DESTROY: PostQuitMessage(0); return IntPtr.Zero;
        }
        return DefWindowProcW(h, m, w, l);
    }

    static readonly System.Collections.Generic.Dictionary<long, IntPtr> brushes = new System.Collections.Generic.Dictionary<long, IntPtr>();
    static void Fill(IntPtr h, IntPtr dc) {
        IntPtr b; lock (brushes) { if (!brushes.TryGetValue(h.ToInt64(), out b)) return; }
        RECT r; GetClientRect(h, out r); FillRect(dc, ref r, b);
    }

    // desktop: null = the thread's own (the input desktop); a name = that
    // desktop (the test desktop). below: the window to sit directly under,
    // IntPtr.Zero = the bottom of the z-order. show false creates it hidden.
    public static GflBackdrop Open(string desktop, int color, int x, int y, int w, int h, IntPtr below, bool show) {
        var b = new GflBackdrop();
        b.Color = color;
        var ready = new ManualResetEvent(false);
        b.th = new Thread(() => {
            try {
                if (!string.IsNullOrEmpty(desktop)) {
                    b.desk = OpenDesktopW(desktop, 0, false, 0x10000000);
                    if (b.desk == IntPtr.Zero || !SetThreadDesktop(b.desk)) { b.Error = "desktop '" + desktop + "': " + Marshal.GetLastWin32Error(); return; }
                }
                SetThreadDpiAwarenessContext(new IntPtr(-4));
                IntPtr inst = GetModuleHandleW(null);
                lock (regGate) {
                    if (!registered) {
                        proc = Proc;
                        var wc = new WNDCLASSEX();
                        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
                        wc.lpfnWndProc = proc; wc.hInstance = inst; wc.lpszClassName = ClassName;
                        if (RegisterClassExW(ref wc) == 0 && Marshal.GetLastWin32Error() != 1410) { b.Error = "RegisterClassExW: " + Marshal.GetLastWin32Error(); return; }
                        registered = true;
                    }
                }
                uint bgr = (uint)(((color & 0xFF) << 16) | (color & 0xFF00) | ((color >> 16) & 0xFF));
                b.brush = CreateSolidBrush(bgr);
                b.Hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, ClassName, "ghoztty-frame-lab-backdrop", WS_POPUP, x, y, w, h, IntPtr.Zero, IntPtr.Zero, inst, IntPtr.Zero);
                if (b.Hwnd == IntPtr.Zero) { b.Error = "CreateWindowExW: " + Marshal.GetLastWin32Error(); return; }
                lock (brushes) brushes[b.Hwnd.ToInt64()] = b.brush;
                b.Place(below, x, y, w, h, show);
            } catch (Exception e) { b.Error = e.Message; return; }
            finally { ready.Set(); }
            MSG msg;
            while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
        });
        b.th.IsBackground = true;
        b.th.SetApartmentState(ApartmentState.STA);
        b.th.Start();
        ready.WaitOne();
        return b;
    }

    // Directly under `below` (or the bottom), at x,y,w,h; never activated.
    public bool Place(IntPtr below, int x, int y, int w, int h, bool show) {
        uint f = SWP_NOACTIVATE | SWP_NOOWNERZORDER | (show ? SWP_SHOWWINDOW : 0);
        bool ok = SetWindowPos(Hwnd, below == IntPtr.Zero ? HWND_BOTTOM : below, x, y, w, h, f);
        if (!ok) Error = "SetWindowPos: " + Marshal.GetLastWin32Error();
        return ok;
    }

    // Read-backs for the acceptance test: nothing here needs a screen.
    [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr h, int i);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    public static int ExStyle(IntPtr h) { return GetWindowLongW(h, -20); }
    public static int Style(IntPtr h) { return GetWindowLongW(h, -16); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    // The window directly below h in the z-order.
    public static IntPtr Below(IntPtr h) { return GetWindow(h, 2); }
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R - r.L, r.B - r.T }; }
    // The client as the window paints it (WM_PRINTCLIENT), one pixel, 0xRRGGBB.
    public int PrintPixel(int x, int y) {
        int[] r = Rect(Hwnd);
        using (var bmp = new System.Drawing.Bitmap(Math.Max(1, r[2]), Math.Max(1, r[3])))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            g.Clear(System.Drawing.Color.Black);
            IntPtr dc = g.GetHdc();
            try { SendMessageW(Hwnd, WM_PRINTCLIENT, dc, new IntPtr(4)); } finally { g.ReleaseHdc(dc); }
            return bmp.GetPixel(x, y).ToArgb() & 0xFFFFFF;
        }
    }

    public void Dispose() {
        if (Hwnd != IntPtr.Zero) {
            PostMessageW(Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            if (th != null) th.Join(2000);
            lock (brushes) brushes.Remove(Hwnd.ToInt64());
            Hwnd = IntPtr.Zero;
        }
        if (brush != IntPtr.Zero) { DeleteObject(brush); brush = IntPtr.Zero; }
        if (desk != IntPtr.Zero) { CloseDesktop(desk); desk = IntPtr.Zero; }
    }
}
'@

function Import-FrameLabBackdrop {
    if ('GflBackdrop' -as [type]) { return }
    Add-Type -TypeDefinition $script:FrameLabBackdropSource -ReferencedAssemblies System.Drawing
}

<#
Is -Color safe as the backdrop? It must be at least -MinDistance away (on its
most distant channel) from every card colour, every colour a card must never
use, and every -Other colour (the theme's chrome, the scene's Flash list).
Returns the reasons it is not; empty = safe.
#>
function Test-FrameLabBackdropColor {
    param([int]$Color = $script:FrameLabBackdropColor, [int[]]$Other = @(), [int]$MinDistance = 32)
    $against = @()
    for ($i = 1; $i -le 9; $i++) {
        $c = Get-FrameLabCardColors -Index $i
        $against += , @("card $i Bg", $c.Bg); $against += , @("card $i Ring", $c.Ring); $against += , @("card $i Glyph", $c.Glyph)
    }
    foreach ($f in $script:FrameLabCardForbidden) { $against += , @(('forbidden 0x{0:X6}' -f $f), $f) }
    foreach ($o in $Other) { $against += , @(('0x{0:X6}' -f $o), $o) }
    $why = @()
    foreach ($a in $against) {
        $d = Get-FrameLabColorDistance $Color $a[1]
        if ($d -lt $MinDistance) { $why += ('backdrop 0x{0:X6} is {1} from {2} (needs {3})' -f $Color, $d, $a[0], $MinDistance) }
    }
    return , $why
}

# The larger per-channel difference: what GhozttyFrameScore.Near compares.
function Get-FrameLabColorDistance([int]$A, [int]$B) {
    $m = 0
    foreach ($s in 16, 8, 0) { $d = [math]::Abs((($A -shr $s) -band 255) - (($B -shr $s) -band 255)); if ($d -gt $m) { $m = $d } }
    return $m
}

<#
Put the backdrop up: -Rect (screen, physical px) directly under -Below (the
app's top-level window). -Desktop names a desktop other than the input one
(the test desktop); -Hidden creates it without showing it. Close it with
.Dispose(). Throws when the window could not be made.
#>
function Show-FrameLabBackdrop {
    param(
        [Parameter(Mandatory = $true)]$Rect,
        [IntPtr]$Below = [IntPtr]::Zero,
        [int]$Color = $script:FrameLabBackdropColor,
        [string]$Desktop,
        [switch]$Hidden
    )
    Import-FrameLabBackdrop
    $b = [GflBackdrop]::Open($Desktop, $Color, [int]$Rect.X, [int]$Rect.Y, [int]$Rect.W, [int]$Rect.H, $Below, -not $Hidden)
    if ($b.Hwnd -eq [IntPtr]::Zero) { throw "Show-FrameLabBackdrop: $($b.Error)" }
    return $b
}

function Get-FrameLabSpanLines([int]$A, [int]$B, [int]$Count = 3) {
    $len = $B - $A
    return , [int[]]@(1..$Count | ForEach-Object { $A + [int][math]::Floor($len * $_ / ($Count + 1)) })
}

<#
What the cell's scene is, from geometry alone (no pixels). -Geometry (screen,
physical px):

  Window   @{ X; Y; W; H }
  Panes    @( @{ Name; Index; X; Y; W; H } )   content rects, and the card index each runs
  Divider  @{ X; Y0; Y1 }                       the divider the gesture grabs (divider cells)
  Sidebar  @{ EdgeX; Y0; Y1 }                   the sidebar's draggable edge, when there is one

-CaptureRect is the gesture's (screen px); everything returned is in frame
coordinates (capture-relative). Returns Edges (each with where it must read on
the still frame, Expect, and where its colour is read, Probe - none for a
backdrop edge), Cards (Name, Index, Anchor L T R B, PadProbe) and Unsupported
(why this interaction's scene cannot be built; empty when it can).
#>
function New-FrameLabCellSceneSpec {
    param(
        [Parameter(Mandatory = $true)][string]$Interaction,
        [Parameter(Mandatory = $true)]$Geometry,
        [Parameter(Mandatory = $true)]$CaptureRect,
        [int]$Gap = $script:FrameLabSceneGap
    )
    $cx = [int]$CaptureRect.X; $cy = [int]$CaptureRect.Y; $cw = [int]$CaptureRect.W; $ch = [int]$CaptureRect.H
    $w = $Geometry.Window
    $wr = [int]$w.X + [int]$w.W; $wb = [int]$w.Y + [int]$w.H
    $unsupported = @()
    if ($Interaction -notin $script:FrameLabSceneSupported) {
        $unsupported += "the scene for '$Interaction' is not modelled: it moves the window as a whole or tracks an edge this scene does not build (T2398)"
    }
    $panes = @($Geometry.Panes | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Index = [int]$_.Index; X = [int]$_.X - $cx; Y = [int]$_.Y - $cy; R = [int]$_.X + [int]$_.W - $cx; B = [int]$_.Y + [int]$_.H - $cy }
    })
    if ($panes.Count -eq 0) { $unsupported += 'the geometry has no panes' }
    $edges = New-Object System.Collections.ArrayList
    $anchor = @{}
    foreach ($p in $panes) { $anchor[$p.Name] = @('', '', '', '') }
    $WR = $wr - $cx; $WB = $wb - $cy

    # Backdrop edges: only where the capture rect leaves backdrop beyond the window.
    $touchR = @($panes | Where-Object { $WR - $_.R -le $Gap })
    $touchB = @($panes | Where-Object { $WB - $_.B -le $Gap })
    if ($cw - $WR -ge 8 -and $touchR.Count) {
        $y0 = ($touchR | Measure-Object -Property Y -Minimum).Minimum; $y1 = ($touchR | Measure-Object -Property B -Maximum).Maximum
        [void]$edges.Add([pscustomobject]@{ Name = 'window-right'; Kind = 'window-right'; Vertical = $true; Lines = (Get-FrameLabSpanLines $y0 $y1); From = $cw - 1; To = 0; Backdrop = $true; Expect = $WR; Probe = $null })
        foreach ($p in $touchR) { $anchor[$p.Name][2] = 'window-right' }
    }
    if ($ch - $WB -ge 8 -and $touchB.Count) {
        $x0 = ($touchB | Measure-Object -Property X -Minimum).Minimum; $x1 = ($touchB | Measure-Object -Property R -Maximum).Maximum
        [void]$edges.Add([pscustomobject]@{ Name = 'window-bottom'; Kind = 'window-bottom'; Vertical = $false; Lines = (Get-FrameLabSpanLines $x0 $x1); From = $ch - 1; To = 0; Backdrop = $true; Expect = $WB; Probe = $null })
        foreach ($p in $touchB) { $anchor[$p.Name][3] = 'window-bottom' }
    }

    # Dividers: one edge per pane with a neighbour to its right / below.
    $grab = $null
    if ($Geometry.Divider) { $grab = [int]$Geometry.Divider.X - $cx }
    $best = [int]::MaxValue; $grabName = $null
    foreach ($a in $panes) {
        $right = @($panes | Where-Object { $_ -ne $a -and $_.X - $a.R -ge 0 -and $_.X - $a.R -le $Gap -and $_.Y -lt $a.B -and $_.B -gt $a.Y })
        if ($right.Count) {
            $n = "v:$($a.Name)"
            [void]$edges.Add([pscustomobject]@{ Name = $n; Kind = 'divider'; Vertical = $true; Lines = (Get-FrameLabSpanLines $a.Y $a.B); From = $a.X + 1; To = $cw - 1; Backdrop = $false; Expect = $a.R; Probe = @{ X = $a.R; Y = [int](($a.Y + $a.B) / 2) } })
            $anchor[$a.Name][2] = $n
            foreach ($b in $right) { if (-not $anchor[$b.Name][0]) { $anchor[$b.Name][0] = $n } }
            if ($null -ne $grab -and [math]::Abs($a.R - $grab) -lt $best) { $best = [math]::Abs($a.R - $grab); $grabName = $n }
        }
        $below = @($panes | Where-Object { $_ -ne $a -and $_.Y - $a.B -ge 0 -and $_.Y - $a.B -le $Gap -and $_.X -lt $a.R -and $_.R -gt $a.X })
        if ($below.Count) {
            $n = "h:$($a.Name)"
            [void]$edges.Add([pscustomobject]@{ Name = $n; Kind = 'divider'; Vertical = $false; Lines = (Get-FrameLabSpanLines $a.X $a.R); From = $a.Y + 1; To = $ch - 1; Backdrop = $false; Expect = $a.B; Probe = @{ X = [int](($a.X + $a.R) / 2); Y = $a.B } })
            $anchor[$a.Name][3] = $n
            foreach ($b in $below) { if (-not $anchor[$b.Name][1]) { $anchor[$b.Name][1] = $n } }
        }
    }
    if ($Interaction -eq 'divider') {
        if (-not $grabName -or $best -gt $Gap) { $unsupported += 'a divider cell with no divider in its geometry next to the one the gesture grabs' }
        else {
            foreach ($e in $edges) { if ($e.Name -eq $grabName) { $e.Name = 'divider' } }
            foreach ($k in @($anchor.Keys)) { for ($s = 0; $s -lt 4; $s++) { if ($anchor[$k][$s] -eq $grabName) { $anchor[$k][$s] = 'divider' } } }
        }
    }

    # The sidebar edge, scanned leftward from inside the first column.
    if ($Geometry.Sidebar) {
        $ex = [int]$Geometry.Sidebar.EdgeX - $cx
        $first = @($panes | Where-Object { $_.X - $ex -ge -2 -and $_.X - $ex -le $Gap })
        if ($first.Count) {
            $y0 = ($first | Measure-Object -Property Y -Minimum).Minimum; $y1 = ($first | Measure-Object -Property B -Maximum).Maximum
            $from = ($first | ForEach-Object { $_.R } | Measure-Object -Minimum).Minimum - 2
            $p0 = $first[0]
            [void]$edges.Add([pscustomobject]@{ Name = 'sidebar-edge'; Kind = 'sidebar-edge'; Vertical = $true; Lines = (Get-FrameLabSpanLines $y0 $y1); From = $from; To = [math]::Max(0, [int]$w.X - $cx); Backdrop = $false; Expect = $p0.X; Probe = @{ X = $p0.X - 1; Y = [int](($p0.Y + $p0.B) / 2) } })
            foreach ($p in $first) { $anchor[$p.Name][0] = 'sidebar-edge' }
        } elseif ($Interaction -in 'sidebar-edge', 'blade-glide') {
            $unsupported += 'a sidebar cell whose geometry puts no pane against the sidebar edge'
        }
    } elseif ($Interaction -in 'sidebar-edge', 'blade-glide') {
        $unsupported += 'a sidebar cell with no sidebar in its geometry'
    }

    $cards = @($panes | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Index = $_.Index; Anchor = [string[]]$anchor[$_.Name]; PadProbe = @{ X = $_.X; Y = $_.Y }; Pane = $_ }
    })
    [pscustomobject]@{ Interaction = $Interaction; Edges = @($edges); Cards = $cards; Unsupported = $unsupported; Capture = $CaptureRect }
}

<#
Build and calibrate the cell's scorer on -Still (an FsFrame of the capture
rect, the scene settled). Reads the divider, sidebar-edge and padding colours
off the still frame, refuses a colour a card also uses, calibrates, and
requires every edge to have been located within -ExpectTol of where the
geometry put it. Returns Ok, Scorer, Reasons, and Delta per edge (located
minus geometry on the still frame - a window border or shadow, which the
motion's grab offset must carry).
#>
function New-FrameLabCellScene {
    param(
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)]$Still,
        [int]$Backdrop = $script:FrameLabBackdropColor,
        [int[]]$Flash = @(),
        [int]$ExpectTol = 3,
        [int]$Tol = 8
    )
    Import-FrameLabScene
    $why = @()
    if (@($Spec.Unsupported).Count) { return [pscustomobject]@{ Ok = $false; Scorer = $null; Reasons = @($Spec.Unsupported); Delta = @{} } }
    $px = { param($x, $y) if ($x -lt 0 -or $y -lt 0 -or $x -ge $Still.W -or $y -ge $Still.H) { -1 } else { $Still.At([int]$x, [int]$y) } }
    $cardColors = @()
    foreach ($c in $Spec.Cards) { $k = Get-FrameLabCardColors -Index $c.Index; $cardColors += $k.Bg, $k.Ring, $k.Glyph }

    $edges = @()
    foreach ($e in $Spec.Edges) {
        if ($e.Backdrop) { $col = $Backdrop }
        else {
            $col = & $px $e.Probe.X $e.Probe.Y
            if ($col -lt 0) { $why += "edge $($e.Name): its colour probe $($e.Probe.X),$($e.Probe.Y) is outside the still frame"; continue }
            $clash = @($cardColors | Where-Object { (Get-FrameLabColorDistance $col $_) -le $Tol })
            if ($clash.Count) { $why += ('edge {0}: its colour 0x{1:X6} is a card colour, so a scan cannot tell it from the card' -f $e.Name, $col); continue }
        }
        $edges += New-FrameLabSceneEdge -Name $e.Name -Kind $e.Kind -Lines $e.Lines -From $e.From -To $e.To -Color $col -Backdrop:$e.Backdrop -Vertical:$e.Vertical -Tol $Tol
    }
    $cards = @()
    foreach ($c in $Spec.Cards) {
        $k = Get-FrameLabCardColors -Index $c.Index
        $pad = & $px $c.PadProbe.X $c.PadProbe.Y
        $extra = @()
        if ($pad -ge 0 -and (Get-FrameLabColorDistance $pad $k.Ring) -gt $Tol) {
            if ((Get-FrameLabColorDistance $pad $k.Bg) -le $Tol -or (Get-FrameLabColorDistance $pad $k.Glyph) -le $Tol) { $why += ('card {0}: its padding 0x{1:X6} is one of its own card colours' -f $c.Name, $pad) }
            $extra = @($pad)
        }
        $cards += New-FrameLabSceneCard -Index $c.Index -Anchor $c.Anchor -Extra $extra -Name $c.Name
    }
    if ($why.Count) { return [pscustomobject]@{ Ok = $false; Scorer = $null; Reasons = $why; Delta = @{} } }

    $s = New-Object GfsSceneScorer
    foreach ($e in $edges) { $s.Edges.Add($e) }
    foreach ($c in $cards) { $s.Cards.Add($c) }
    $s.Flash = [int[]]@($Flash + $Backdrop); $s.Tol = $Tol
    $s.GlyphRow = $script:FrameLabGlyphRow; $s.GlyphCol = $script:FrameLabGlyphCol
    $why += @($s.Calibrate($Still))
    $pos = $s.LocateAll($Still)
    $delta = @{}
    for ($i = 0; $i -lt $s.Edges.Count; $i++) {
        $e = @($Spec.Edges | Where-Object { $_.Name -eq $s.Edges[$i].Name })[0]
        if ([double]::IsNaN($pos[$i])) { continue }   # Calibrate already said so
        $d = $pos[$i] - $e.Expect
        $delta[$e.Name] = $d
        if ([math]::Abs($d) -gt $ExpectTol) { $why += "edge $($e.Name) located at $($pos[$i]) on the still frame, $d from where the geometry puts it ($($e.Expect))" }
    }
    [pscustomobject]@{ Ok = ($why.Count -eq 0); Scorer = $(if ($why.Count -eq 0) { $s } else { $null }); Reasons = $why; Delta = $delta }
}

<#
The cell's numbers from one scored capture: Invoke-FrameLabCell's Score.

  -Scorer   the calibrated GfsSceneScorer the capture ran (its Records)
  -Capture  Stop-FrameCapture's result (Stats, Timeline)
  -Gesture  Get-FrameLabGesture's (Track, Axis, MotionStartMs/EndMs, GrabOffset)
  -Played   the GliResult (its Stamps put the pointer on the capture clock)
  -Delta    New-FrameLabCellScene's Delta (the tracked edge's still-frame offset)

Superseded frames were never on screen and are not counted. Returns
BleedFrames, Frames (each failing frame's Index, Classes, Findings), Motion
(FsMotion, or $null for a bleed-only gesture) and MotionMisses.
#>
function Get-FrameLabSceneScore {
    param(
        [Parameter(Mandatory = $true)]$Scorer,
        [Parameter(Mandatory = $true)]$Capture,
        [Parameter(Mandatory = $true)]$Gesture,
        $Played,
        [hashtable]$Delta = @{}
    )
    $sup = @{}
    foreach ($t in @($Capture.Timeline)) { if ($t.Superseded) { $sup[[long]$t.Index] = $true } }
    $recs = @($Scorer.Records | Where-Object { -not $sup.ContainsKey([long]$_.Index) })
    $failing = @($recs | Where-Object { $_.Failing })
    $frames = @($failing | ForEach-Object { [pscustomobject]@{ Index = $_.Index; Classes = $_.Classes(); Findings = @($_.Findings) } })
    $out = [ordered]@{ BleedFrames = $failing.Count; Frames = $frames; Motion = $null; MotionMisses = @(); Scored = $recs.Count }
    if ($Gesture.Axis -eq 'none' -or -not $Gesture.Track) { return [pscustomobject]$out }
    $k = $Scorer.EdgeIndex($Gesture.Track)
    if ($k -lt 0) { $out.MotionMisses = @("the scene has no '$($Gesture.Track)' edge to measure"); return [pscustomobject]$out }
    $stamps = @($(if ($Played) { $Played.Stamps }))
    if ($stamps.Count -lt 2) { $out.MotionMisses = @('no pointer stamps: the motion has no clock to be measured on'); return [pscustomobject]$out }
    $F = [double]$Capture.Stats.QpcFrequency
    $t0 = $stamps[0].SentQpc
    $time = [double[]]@($recs | ForEach-Object { ($_.Qpc - $t0) * 1000.0 / $F })
    $pos = [double[]]@($recs | ForEach-Object { $_.Edges[$k] })
    $cap = $Gesture.CaptureRect
    $useY = $Gesture.Axis -eq 'y'
    $pt = [double[]]@($stamps | ForEach-Object { ($_.SentQpc - $t0) * 1000.0 / $F })
    $pp = [double[]]@($stamps | ForEach-Object { if ($useY) { $_.Y - $cap.Y } else { $_.X - $cap.X } })
    $d = $(if ($Delta.ContainsKey($Gesture.Track)) { [double]$Delta[$Gesture.Track] } else { 0.0 })
    $period = 1000.0 / [math]::Max(1, $Capture.Stats.RefreshHz)
    # Measure-FrameMotion's offset is EDGE minus pointer (its target is the
    # pointer plus it); the gesture's GrabOffset is pointer minus edge. The
    # located edge sits $d from the geometry's, so it is due at pointer - grab + d.
    $m = Measure-FrameMotion -Time $time -Position $pos -PeriodMs $period -Start $Gesture.MotionStartMs -End $Gesture.MotionEndMs `
        -PointerTime $pt -PointerPosition $pp -GrabOffset ($d - $Gesture.GrabOffset)
    $out.Motion = $m
    $misses = Test-FrameMotionTargets -Motion $m
    $out.MotionMisses = @($misses | Where-Object { $_ })
    return [pscustomobject]$out
}
