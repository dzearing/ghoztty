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
# WINDOW-MOVING CELLS (T2398): caption-dblclick, aero-snap and maximize-button
# move the window as a whole, so its four sides are all edges - window-left and
# window-top scanned in from the backdrop too - and every one of them is OPEN:
# the capture is the work area, and a window that fills it (maximized, or
# snapped against a side) has no backdrop beyond it, so a line that starts on
# the window puts the edge on the boundary. Every other edge is CARRIED by
# window-left/window-top, so a divider is still scanned from inside its pane
# after the window has moved, and every card side that touches no divider
# rides the window edge on that side. A frame whose four sides are all on the
# boundary is MAXIMIZED; a maximized window has no border and its caption need
# not be the restored height, so its cards ride on offsets calibrated from a
# second still frame of the window maximized (-MaximizedStill). A maximizing
# cell without one is refused, and Get-FrameLabSceneScore -ExpectMaximized
# fails a run in which the window never showed maximized at all.
#
# BANNER (T2727): the banner pushes one pane's top down - the trigger plan's
# Target, Geometry.Target. Its top is the 'pane-top' edge: scanned UPWARD in
# the pane's left padding column (the theme background, never a card colour)
# from near its bottom until the padding colour stops, which is the banner's
# bottom while it shows and the chrome above the pane while it does not. A
# still frame whose chrome above the pane is the padding colour is refused:
# nothing there would stop the scan.
#
# PANE-SET TRIGGERS (T2727): hero, tab-switch and split-close change which
# panes are on screen mid-run, so one calibrated scene cannot describe every
# frame. New-FrameLabCellScene takes -States: one still frame (and its
# geometry) per OTHER pane set the run shows, each calibrated into its own
# scorer on the cell scorer's States. A frame is scored against the pane set
# the run starts on and then each state; the first that passes it is the
# frame's state, and a frame no state passes fails (Get-FrameLabSceneScore
# -ExpectStates also fails a run whose pane set never changed). A pane-set
# cell without states is refused, as is a state still that is the start's.
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
$script:FrameLabSceneSupported = @('frame-right', 'frame-bottom', 'frame-corner', 'divider', 'sidebar-edge', 'blade-glide', 'caption-dblclick', 'aero-snap', 'maximize-button', 'banner', 'hero', 'tab-switch', 'split-close')

# The triggers that change the pane set mid-run (T2727): scored against one
# calibrated state per pane set.
$script:FrameLabScenePaneSet = @('hero', 'tab-switch', 'split-close')

# The ones that move the window as a whole (T2398), and of those the ones that
# maximize it (they need a maximized still frame).
$script:FrameLabSceneWindowMoving = @('caption-dblclick', 'aero-snap', 'maximize-button')
$script:FrameLabSceneMaximizing = @('caption-dblclick', 'maximize-button')

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
        $unsupported += "the scene for '$Interaction' is not modelled: no interaction by that name has a scene"
    }
    $moving = $Interaction -in $script:FrameLabSceneWindowMoving
    $panes = @($Geometry.Panes | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Index = [int]$_.Index; X = [int]$_.X - $cx; Y = [int]$_.Y - $cy; R = [int]$_.X + [int]$_.W - $cx; B = [int]$_.Y + [int]$_.H - $cy }
    })
    if ($panes.Count -eq 0) { $unsupported += 'the geometry has no panes' }
    $edges = New-Object System.Collections.ArrayList
    $anchor = @{}
    foreach ($p in $panes) { $anchor[$p.Name] = @('', '', '', '') }
    $WR = $wr - $cx; $WB = $wb - $cy
    $WX = [int]$w.X - $cx; $WY = [int]$w.Y - $cy
    # Carried by the window's own left and top when it moves as a whole.
    $carX = $(if ($moving) { 'window-left' } else { $null }); $carY = $(if ($moving) { 'window-top' } else { $null })

    # A window-moving cell: window-left and window-top first (every other edge
    # is carried by them), and backdrop on every side of the window at the
    # start, or nothing tells the still frame's window from one that fills the
    # work area.
    if ($moving -and $panes.Count) {
        $short = @()
        if ($WX -lt 8) { $short += 'left' }; if ($WY -lt 8) { $short += 'top' }
        if ($cw - $WR -lt 8) { $short += 'right' }; if ($ch - $WB -lt 8) { $short += 'bottom' }
        if ($short.Count) { $unsupported += "a window-moving cell needs backdrop on every side of the window at the start; the capture leaves none beyond its $($short -join ', ')" }
        $y0 = ($panes | Measure-Object -Property Y -Minimum).Minimum; $y1 = ($panes | Measure-Object -Property B -Maximum).Maximum
        $x0 = ($panes | Measure-Object -Property X -Minimum).Minimum; $x1 = ($panes | Measure-Object -Property R -Maximum).Maximum
        [void]$edges.Add([pscustomobject]@{ Name = 'window-left'; Kind = 'window-left'; Vertical = $true; Lines = (Get-FrameLabSpanLines $y0 $y1); From = 0; To = $cw - 1; Backdrop = $true; Expect = $WX; Open = $true; Probe = $null })
        [void]$edges.Add([pscustomobject]@{ Name = 'window-top'; Kind = 'window-top'; Vertical = $false; Lines = (Get-FrameLabSpanLines $x0 $x1); From = 0; To = $ch - 1; Backdrop = $true; Expect = $WY; Open = $true; CarryX = 'window-left'; Probe = $null })
    }

    # Backdrop edges: only where the capture rect leaves backdrop beyond the window.
    $touchR = @($panes | Where-Object { $WR - $_.R -le $Gap })
    $touchB = @($panes | Where-Object { $WB - $_.B -le $Gap })
    if ($cw - $WR -ge 8 -and $touchR.Count) {
        $y0 = ($touchR | Measure-Object -Property Y -Minimum).Minimum; $y1 = ($touchR | Measure-Object -Property B -Maximum).Maximum
        [void]$edges.Add([pscustomobject]@{ Name = 'window-right'; Kind = 'window-right'; Vertical = $true; Lines = (Get-FrameLabSpanLines $y0 $y1); From = $cw - 1; To = 0; Backdrop = $true; Expect = $WR; Open = $moving; CarryY = $carY; Probe = $null })
        foreach ($p in $touchR) { $anchor[$p.Name][2] = 'window-right' }
    }
    if ($ch - $WB -ge 8 -and $touchB.Count) {
        $x0 = ($touchB | Measure-Object -Property X -Minimum).Minimum; $x1 = ($touchB | Measure-Object -Property R -Maximum).Maximum
        [void]$edges.Add([pscustomobject]@{ Name = 'window-bottom'; Kind = 'window-bottom'; Vertical = $false; Lines = (Get-FrameLabSpanLines $x0 $x1); From = $ch - 1; To = 0; Backdrop = $true; Expect = $WB; Open = $moving; CarryX = $carX; Probe = $null })
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
            [void]$edges.Add([pscustomobject]@{ Name = $n; Kind = 'divider'; Vertical = $true; Lines = (Get-FrameLabSpanLines $a.Y $a.B); From = $a.X + 1; To = $cw - 1; Backdrop = $false; Expect = $a.R; ProbeTo = [int](($right | Measure-Object -Property X -Minimum).Minimum); Probe = @{ X = $a.R; Y = [int](($a.Y + $a.B) / 2) } })
            $anchor[$a.Name][2] = $n
            foreach ($b in $right) { if (-not $anchor[$b.Name][0]) { $anchor[$b.Name][0] = $n } }
            if ($null -ne $grab -and [math]::Abs($a.R - $grab) -lt $best) { $best = [math]::Abs($a.R - $grab); $grabName = $n }
        }
        $below = @($panes | Where-Object { $_ -ne $a -and $_.Y - $a.B -ge 0 -and $_.Y - $a.B -le $Gap -and $_.X -lt $a.R -and $_.R -gt $a.X })
        if ($below.Count) {
            $n = "h:$($a.Name)"
            [void]$edges.Add([pscustomobject]@{ Name = $n; Kind = 'divider'; Vertical = $false; Lines = (Get-FrameLabSpanLines $a.X $a.R); From = $a.Y + 1; To = $ch - 1; Backdrop = $false; Expect = $a.B; ProbeTo = [int](($below | Measure-Object -Property Y -Minimum).Minimum); Probe = @{ X = [int](($a.X + $a.R) / 2); Y = $a.B } })
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

    # The banner's pane top (T2727): the pane the trigger targets, scanned up
    # its left padding column. The scan's lines are measured on the still
    # frame (New-FrameLabCellScene), where the padding's width can be read.
    if ($Interaction -eq 'banner') {
        $tn = [string]$Geometry.Target
        $tp = @($panes | Where-Object { $_.Name -eq $tn })
        if (-not $tn) { $unsupported += 'a banner cell needs Geometry.Target, the pane the banner is set on' }
        elseif (-not $tp.Count) { $unsupported += "a banner cell whose target '$tn' is not one of the geometry's panes" }
        else {
            $p = $tp[0]
            [void]$edges.Add([pscustomobject]@{ Name = 'pane-top'; Kind = 'pane-top'; Vertical = $false; Lines = @($p.X); From = $p.B - 2; To = 0; Backdrop = $false; Until = $true; PadColumn = $true; Expect = $p.Y; Probe = @{ X = $p.X; Y = [int](($p.Y + $p.B) / 2) } })
            $anchor[$p.Name][1] = 'pane-top'
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
            [void]$edges.Add([pscustomobject]@{ Name = 'sidebar-edge'; Kind = 'sidebar-edge'; Vertical = $true; Lines = (Get-FrameLabSpanLines $y0 $y1); From = $from; To = [math]::Max(0, [int]$w.X - $cx); Backdrop = $false; SkipPadding = $true; Expect = $p0.X; Probe = @{ X = $p0.X - 1; Y = [int](($p0.Y + $p0.B) / 2) } })
            foreach ($p in $first) { $anchor[$p.Name][0] = 'sidebar-edge' }
        } elseif ($Interaction -in 'sidebar-edge', 'blade-glide') {
            $unsupported += 'a sidebar cell whose geometry puts no pane against the sidebar edge'
        }
    } elseif ($Interaction -in 'sidebar-edge', 'blade-glide') {
        $unsupported += 'a sidebar cell with no sidebar in its geometry'
    }

    if ($moving) {
        # The window moves as a whole: the dividers and the sidebar edge are
        # scanned where they are after the window has moved - and resized, so
        # the map runs over the window's left..right and top..bottom (a ratio
        # split scales with the window; a scan that started inside a pane
        # stays inside it) - and a
        # card side touching no divider rides the window edge on its side (the
        # caption above the top row is part of that side's offset).
        foreach ($e in $edges) {
            if ($e.Kind -in 'divider', 'sidebar-edge') {
                $e | Add-Member -Force -NotePropertyName CarryX -NotePropertyValue $carX
                $e | Add-Member -Force -NotePropertyName CarryY -NotePropertyValue $carY
                $e | Add-Member -Force -NotePropertyName CarryX2 -NotePropertyValue 'window-right'
                $e | Add-Member -Force -NotePropertyName CarryY2 -NotePropertyValue 'window-bottom'
            }
        }
        $have = @($edges | ForEach-Object { $_.Name })
        $side = @('window-left', 'window-top', 'window-right', 'window-bottom')
        foreach ($k in @($anchor.Keys)) {
            for ($s = 0; $s -lt 4; $s++) { if (-not $anchor[$k][$s] -and $have -contains $side[$s]) { $anchor[$k][$s] = $side[$s] } }
        }
    }

    $cards = @($panes | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Index = $_.Index; Anchor = [string[]]$anchor[$_.Name]; PadProbe = @{ X = $_.X; Y = $_.Y }; Pane = $_ }
    })
    [pscustomobject]@{
        Interaction = $Interaction; Edges = @($edges); Cards = $cards; Unsupported = $unsupported; Capture = $CaptureRect
        Moving = $moving; Maximizes = ($Interaction -in $script:FrameLabSceneMaximizing)
        PaneSet = ($Interaction -in $script:FrameLabScenePaneSet)
    }
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
        [int]$Tol = 8,
        # T2398: an FsFrame of the same capture rect with the window maximized
        # (and settled). A maximizing cell is refused without one.
        $MaximizedStill,
        # T2727: a pane-set cell's other pane sets, each @{ Name; Geometry;
        # Still } - the geometry the launcher measured in that state and a
        # settled FsFrame of the same capture rect. Refused without one.
        [object[]]$States = @(),
        # Internal: this scene IS one of a pane-set cell's states.
        [switch]$AsState
    )
    Import-FrameLabScene
    $why = @()
    $maxes = [bool]$Spec.Maximizes
    $paneSet = [bool]$Spec.PaneSet -and -not $AsState
    $fail = { param($r) [pscustomobject]@{ Ok = $false; Scorer = $null; Reasons = @($r); Delta = @{}; Maximizes = $maxes; PaneSet = $paneSet } }
    if (@($Spec.Unsupported).Count) { return & $fail @($Spec.Unsupported) }
    $px = { param($x, $y) if ($x -lt 0 -or $y -lt 0 -or $x -ge $Still.W -or $y -ge $Still.H) { -1 } else { $Still.At([int]$x, [int]$y) } }
    $cardColors = @()
    foreach ($c in $Spec.Cards) { $k = Get-FrameLabCardColors -Index $c.Index; $cardColors += $k.Bg, $k.Ring, $k.Glyph }

    $edges = @()
    foreach ($e in $Spec.Edges) {
        if ($e.Backdrop) { $col = $Backdrop }
        else {
            $col = & $px $e.Probe.X $e.Probe.Y
            if ($col -lt 0) { $why += "edge $($e.Name): its colour probe $($e.Probe.X),$($e.Probe.Y) is outside the still frame"; continue }
            # The real app (T2395's first live run): a pane's content rect ends
            # in a strip of background where the grid does not fill it, and the
            # divider line sits inside the gap past it. So a divider's colour is
            # the first pixel across the gap that is NOT the colour at the
            # pane's edge, and that is where it must read; a gap of one colour
            # throughout is the divider itself (the synthetic scenes).
            $v0 = $(if ($e.Vertical) { $e.Probe.X } else { $e.Probe.Y })
            $inside = $(if ($e.Vertical) { & $px ($v0 - 1) $e.Probe.Y } else { & $px $e.Probe.X ($v0 - 1) })
            if ($null -ne $e.ProbeTo -and $e.ProbeTo -gt $v0 -and $inside -ge 0 -and (Get-FrameLabColorDistance $inside $col) -le $Tol) {
                for ($v = $v0 + 1; $v -lt $e.ProbeTo; $v++) {
                    $c2 = $(if ($e.Vertical) { & $px $v $e.Probe.Y } else { & $px $e.Probe.X $v })
                    if ($c2 -ge 0 -and (Get-FrameLabColorDistance $c2 $col) -gt $Tol) { $col = $c2; $e.Expect = $v; break }
                }
            }
            # The banner's pane top (T2727): the scan runs up the padding
            # column, so the padding must be there to scan and something that
            # is not padding must sit above the pane to stop it. Its lines
            # are spread across the padding's width, measured here.
            if ($e.PadColumn) {
                $above = & $px $e.Probe.X ($e.Expect - 1)
                if ($above -lt 0 -or (Get-FrameLabColorDistance $above $col) -le $Tol) { $why += ('edge {0}: the chrome above the pane (0x{1:X6}) is its padding colour 0x{2:X6}, so nothing would stop the scan at the pane''s top' -f $e.Name, $above, $col); continue }
                $pw = 0
                while ($pw -lt 64 -and (Get-FrameLabColorDistance (& $px ($e.Probe.X + $pw) $e.Probe.Y) $col) -le $Tol) { $pw++ }
                $e.Lines = [int[]]@(0..2 | ForEach-Object { $e.Probe.X + [int][math]::Floor($_ * ($pw - 1) / 2) })
            }
            # The sidebar edge's colour is the window background, which is
            # also the padding strip at the first pane's right: start the
            # leftward scan inside the card, past that strip and a cell's slack.
            if ($e.SkipPadding) {
                $y = [int]$e.Lines[0]; $f = [int]$e.From
                while ($f -gt [int]$e.Expect -and (Get-FrameLabColorDistance (& $px $f $y) $col) -le $Tol) { $f-- }
                $e.From = [math]::Max([int]$e.Expect + 1, $f - 24)
            }
            $clash = @($cardColors | Where-Object { (Get-FrameLabColorDistance $col $_) -le $Tol })
            if ($clash.Count) { $why += ('edge {0}: its colour 0x{1:X6} is a card colour, so a scan cannot tell it from the card' -f $e.Name, $col); continue }
        }
        $edges += New-FrameLabSceneEdge -Name $e.Name -Kind $e.Kind -Lines $e.Lines -From $e.From -To $e.To -Color $col -Backdrop:$e.Backdrop -Until:([bool]$e.Until) -Vertical:$e.Vertical -Tol $Tol `
            -Open:([bool]$e.Open) -CarryX ([string]$e.CarryX) -CarryY ([string]$e.CarryY) -CarryX2 ([string]$e.CarryX2) -CarryY2 ([string]$e.CarryY2)
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
    if ($why.Count) { return & $fail $why }

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
    # A maximized frame's panes sit at their own offsets (no border, maybe
    # another caption height): measured on the maximized still, or refused.
    if ($maxes -and $why.Count -eq 0) {
        if ($null -eq $MaximizedStill) { $why += 'the cell maximizes the window and no maximized still frame was given: its maximized frames could not be scored' }
        else { $why += @($s.CalibrateMaximized($MaximizedStill)) }
    }
    # A pane-set cell (T2727): every other pane set calibrated into its own
    # scorer. A state whose still the start's scene already passes is not
    # another pane set, and scoring against it would pass anything.
    if ($paneSet -and $why.Count -eq 0) {
        if (@($States).Count -eq 0) { $why += "the cell changes the pane set mid-run ($($Spec.Interaction)) and no still frame of the other pane set was given: its frames could not be scored" }
        foreach ($st in @($States)) {
            $sn = [string]$st.Name
            if ($null -eq $st.Still -or $null -eq $st.Geometry) { $why += "state ${sn}: it needs both Geometry and Still"; continue }
            if ($st.Still.W -ne $Still.W -or $st.Still.H -ne $Still.H) { $why += "state ${sn}: its still frame is $($st.Still.W)x$($st.Still.H), the cell's $($Still.W)x$($Still.H)"; continue }
            $sspec = New-FrameLabCellSceneSpec -Interaction $Spec.Interaction -Geometry $st.Geometry -CaptureRect $Spec.Capture
            $ss = New-FrameLabCellScene -Spec $sspec -Still $st.Still -Backdrop $Backdrop -Flash $Flash -ExpectTol $ExpectTol -Tol $Tol -AsState
            if (-not $ss.Ok) { $why += @($ss.Reasons | ForEach-Object { "state ${sn}: $_" }); continue }
            $m = 0
            if (-not $s.Evaluate($st.Still, [ref]$m).Failing) { $why += "state ${sn}: its still frame already scores clean against the pane set the run starts on - it is not another pane set"; continue }
            $ss.Scorer.StateName = $sn
            $s.States.Add($ss.Scorer)
        }
    }
    [pscustomobject]@{ Ok = ($why.Count -eq 0); Scorer = $(if ($why.Count -eq 0) { $s } else { $null }); Reasons = $why; Delta = $delta; Maximizes = $maxes; PaneSet = $paneSet }
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
(FsMotion, or $null for a bleed-only gesture), MotionMisses and
MaximizedFrames (how many scored frames showed the window maximized) and
StateFrames (how many passed as another pane set, T2727).

-ExpectMaximized (T2398, a maximizing cell): a run in which no frame showed
the window maximized never did what the cell is about, and that is a miss -
never a clean pass over frames of a window that only sat there.
#>
function Get-FrameLabSceneScore {
    param(
        [Parameter(Mandatory = $true)]$Scorer,
        [Parameter(Mandatory = $true)]$Capture,
        [Parameter(Mandatory = $true)]$Gesture,
        $Played,
        [hashtable]$Delta = @{},
        [switch]$ExpectMaximized,
        # T2727: a pane-set cell - a run in which no frame showed another pane
        # set never did what the cell is about.
        [switch]$ExpectStates
    )
    $sup = @{}
    foreach ($t in @($Capture.Timeline)) { if ($t.Superseded) { $sup[[long]$t.Index] = $true } }
    $recs = @($Scorer.Records | Where-Object { -not $sup.ContainsKey([long]$_.Index) })
    $failing = @($recs | Where-Object { $_.Failing })
    $frames = @($failing | ForEach-Object { [pscustomobject]@{ Index = $_.Index; Classes = $_.Classes(); Findings = @($_.Findings) } })
    $maxed = @($recs | Where-Object { $_.Maximized }).Count
    $stated = @($recs | Where-Object { $_.State -gt 0 -and -not $_.Failing }).Count
    $out = [ordered]@{ BleedFrames = $failing.Count; Frames = $frames; Motion = $null; MotionMisses = @(); Scored = $recs.Count; MaximizedFrames = $maxed; StateFrames = $stated }
    if ($ExpectMaximized -and $maxed -eq 0) { $out.MotionMisses = @("the window never showed maximized on any of the $($recs.Count) scored frame(s): the interaction did not happen") }
    if ($ExpectStates -and $stated -eq 0) { $out.MotionMisses = @("no scored frame showed another pane set ($($recs.Count) scored): the interaction did not happen") }
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
