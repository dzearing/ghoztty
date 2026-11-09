# On-screen oracle for the grid hold during a pane-stack glide (tracker T2513).
#
# T2102 ported Mac's `paneContentFreeze`: when a stack's run changes, the cards
# on show glide to their new slots and a card's content is held at one size
# while it moves, so a terminal is resized at most once, never per frame.
# test\win32\pane-stack-slide.ps1 proves that from window rects on the
# background test desktop, which DWM never composes. On the composition
# present path (GHOZTTY_COMP_PRESENT=1) the pane's pixels are a
# DirectComposition visual rather than the window's redirection bitmap, so
# what the user SEES during the glide is a separate question: does each card's
# picture travel with it, whole, at its held size - not blank, not stretched,
# not torn, and actually gliding rather than jumping?
#
# The app runs as a GHOST window on the input desktop (GHOZTTY_DEBUG_GHOST=
# bottom, debug builds only: opaque, never activated, bottom of the z-order -
# the T2488 shape), and ghoztty-comp-spike.exe --film-hwnd records every frame
# DWM composes of it. The person at the desk sees nothing and keeps the
# focus: the strip click is a POSTED message - the real cursor never moves.
#
# Layout: four panes in one row (P | g1 | g2 | g3), each painted with its own
# solid colour block (palette 1/2/4/5 forced to pure red/green/blue/magenta),
# then the window narrowed to 760 DIP so two are on show and two are tucked
# (the pane-stack-slide.ps1 shape). A click on the furthest tucked pane's strip
# starts the glide, stretched to -SlideMs.
#
# Per arm (knob ON = GHOZTTY_COMP_PRESENT=1, knob OFF = WGL SwapBuffers), over
# every filmed frame:
#   .5 glide:   some block is seen at 2+ distinct positions strictly between
#               where it started and where it settled (a jump scores 0)
#   .6 whole:   a block on show at both ends of the glide is on screen in
#               every frame (rows of it present >= 90% of its rest height)
#   .7 held:    no block is ever taller, or wider, than its rest size (+2 px):
#               a held card is clipped, never stretched
#   .8 untorn:  in every frame each block's rows share one left edge and one
#               right edge (within 2 px)
#   .F          the ghost never took the foreground
#
# What the film cannot see: a card coming out of (or going into) its strip is
# drawn during the glide by its FACE (StripFace.zig, T2458), a layered popup
# owned by the pane - its own top-level window, which a capture of the main
# window never contains (the bell-fade-onscreen.ps1 caveat). So on the ON and
# OFF arms that card reads as an empty card until it lands live, and it is
# reported but never scored; .6 scores the cards that are live at both ends of
# the glide. In the composition pane tree the face is a picture of the
# window's own tree (T2777), and the TREE arm scores both faces (T2818): .18
# the folding card is on film until its left edge has gone half its width
# toward the strip, .19 the opening card is on film at 2+ places before it
# settles.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms tree -NoFaceComp   # tree.18 and tree.19 must go red
# -NoFaceComp sets GHOZTTY_FACE_COMP=0: the faces stay on their popups.
#
# .20 (T2826, tree arms) reads the app's count of window-region cuts made for
# gliding panes: with the desk on the compositor a gliding pane's window keeps
# its region (at most one cut a pane), instead of one SetWindowRgn per pane
# per frame.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms tree -GlideRegionCut   # tree.20 must go red
#
# .21 (T2828, tree arms) reads the app's count of the glide's ticks: with
# everything on the move declared to the compositor, a tick that lands
# nothing only steps the glide's model and skips the window's layout pass,
# so most of the glide's ticks are quiet. Under -NoDeclare none may be (the
# panes are stepped from the window's thread), which .21 checks instead.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms stall -NoLandingTimer   # stall.21 must go red
# -NoLandingTimer sets GHOZTTY_GLIDE_LANDING_TIMER=0: every tick lays out.
#
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms on
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -NegativeControl   # must go red
#
# TREE (T2571) is ON plus GHOZTTY_COMP_CHROME=1 and GHOZTTY_COMP_PANE_TREE=1:
# each pane's swap chain is a visual of the window's own tree, and the glide
# moves that visual on every frame while the pane's child window stays put
# until the glide lands. The same film scores it - a visual that did not
# travel, or travelled without its picture, fails .5-.8 exactly as a window
# would - and .9 reads the app's own count: child-window moves for the glide
# at most two a pane (the landing, plus a show or hide), against every pane
# on every frame on the ON arm, where .9 is the control (no visual moves).
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms tree
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms tree -NoGlideTree   # tree.9 must go red
# -NoGlideTree sets GHOZTTY_GLIDE_TREE=0: the tree's panes glide by moving
# their windows again, as before T2571.
#
# STALL (T2572) is the TREE arm with the window's thread blocked for -StallMs
# right after the glide's first frame (GHOZTTY_DEBUG_GLIDE_STALL_MS, debug
# builds). The glide is declared to the compositor - each pane visual's whole
# follower path at once - so the cards keep travelling through the stall;
# stepped from the window's thread they freeze for all of it. .10 reads the
# film: the longest stretch of the glide in which the card that travels
# furthest did not move, which must stay under a quarter of the stall.
# Since T2778 the card folding into its strip is declared too - its face's
# card clip, carried frame and fade - and, in the tree, the face is a picture
# of the window's own tree, so the film sees it: .13 scores its longest still
# stretch until it fades out of the film, .14 reads that it was declared.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms stall
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms stall -NoDeclare   # stall.10 must go red
# -NoDeclare sets GHOZTTY_GLIDE_DECLARE=0: the visuals are placed on every
# frame from the window's thread again, as T2571 left them.
#
# UNFOLD (T2779) is the STALL arm with the stall moved
# (GHOZTTY_DEBUG_GLIDE_STALL_AT=unfold): it lands once the card opening out of
# its strip is carrying the frame its pane drew at its new size and that
# content is well in, so the film has seen it before the window's thread
# blocks. Declared, the opening face - its card clip, the frame's place and
# its fade rising in - goes on opening through the stall; stepped, it freezes
# where the stall caught it. .15 scores its longest still stretch from its
# first appearance until it is within 5% of where it settles, .16 reads that
# the opening face was declared with its frame.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms unfold
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms unfold -NoDeclare   # unfold.15 must go red
#
# LIVE (T2822) is the STALL arm with the fold never carrying a frame
# (GHOZTTY_DEBUG_GLIDE_LIVE_FACE=1, debug builds): the folding card is its
# live pane with the strip's face blended over it at Mac's last-120
# collapse. Declared, the pane visual's path and the face's fade go to the
# compositor together and the card folds on through the stall; stepped, it
# freezes. .13 scores the folding card on film, .14 reads that its face was
# declared live.
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms live
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms live -NoDeclare   # live.13 must go red
#
# STRIP (T2851) films a strip that stays a strip and moves (T2417), declared
# to the compositor as a face since T2825, through the same stall. Its own
# layout (Invoke-StripArm): five panes beside the pane sidebar's rail in the
# flat style, so the first is a blade at the grid's leading edge, and a
# posted click on the sidebar's toggle expands it - the grid, blade and all,
# glides right (a second pane folds on the way). The blade is its
# background's stripRgb (-StripBg), read off the first frame beside the rail.
#   .22  the leading (leftmost) blade keeps moving through the stall and
#        never jumps back - a copy left at the start, frozen with the
#        thread, holds it still (T2869)
#   .22b some blade in the band is on the move through the stall - what a
#        declared face does whatever the desk under it shows
#   .22c once at its landing the leading blade stays on screen (T2870)
#   .23  the log names the face's declaration
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms strip
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms strip -NoDeclare   # strip.22b and strip.23 must go red
# As of 2026-11-09 (T2855) the declared arm is red on .22c alone (T2870: the
# leading blade missing for a few frames after its landing). The .22 frozen
# copy (T2869) was the debug stall's own doing: it landed mid-tick, between
# the grid's commit and the sidebar column's declaration, which no real hitch
# can do. It lands at the end of the tick now, and .22 is green.
#
# SIDEBAR (T2855) films the pane sidebar column's declared glide (T2827)
# through the same stall (Invoke-SidebarArm): two panes beside the rail, a
# posted click on the toggle expands it, and the gutter between the sidebar
# card's right edge and the grid's leading card's left edge is measured on
# every frame.
#   .24  the column follows the grid: its visible edge leaves the rail within
#        a quarter of the stall of the grid's first move, and the gutter
#        never opens past its rest width after that
#   .24d the gutter within 2 px of its rest width on every frame - red as of
#        2026-11-09 with or without the stall (T2872: the crossfade starts
#        near-invisible, and its clipped edge drops the card's margin)
#   .24b the leading card keeps moving through the stall
#   .25  the log names the column's declaration
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms sidebar
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms sidebar -NoColumnDeclare   # sidebar.24 and .25 must go red
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms sidebar -NoDeclare         # sidebar.24b and .25 must go red
#
# -NegativeControl sets the slide to 0 ms (the instant re-layout from before
# T2102): .5 must FAIL on every arm.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('on', 'off', 'tree'),
    [int]$SlideMs = 1500,
    [string]$OutDir,
    [switch]$KeepFrames,
    [switch]$NegativeControl,
    [switch]$NoGlideTree,
    [int]$StallMs = 500,
    [switch]$NoDeclare,
    # T2793: the solid card style (--macos-pane-glass=false), whose cards
    # ride their layers whole - fill, rim and edge - so a glide that moves
    # them recomposes no card on the desk. -NoBody keeps the bodies in the
    # desk compose (GHOZTTY_COMP_SHADOWS_NOBODY=1): the stall arm's .17
    # must then go red.
    [switch]$Solid,
    [switch]$NoBody,
    # T2818: GHOZTTY_FACE_COMP=0 keeps a folding or opening card's face on its
    # layered popup, which a window capture never contains - the tree arm's
    # .18/.19 must then go red.
    [switch]$NoFaceComp,
    # T2826: GHOZTTY_GLIDE_REGION_CUT=1 re-cuts a gliding tree pane's window
    # region on every frame, as before - the tree arms' .20 must then go red.
    [switch]$GlideRegionCut,
    # T2828: GHOZTTY_GLIDE_LANDING_TIMER=0 runs the layout pass on every
    # glide tick, as before - the tree arms' .21 must then go red.
    [switch]$NoLandingTimer,
    # T2851: the strip arm's background - the blade is its stripRgb, which
    # has to be a colour no other chrome in the filmed band uses.
    [string]$StripBg = '#0060c0',
    # T2855: GHOZTTY_SIDEBAR_COLUMN_DECLARE=0 steps the sidebar column while
    # the grid beside it stays declared (the T2827 regression) - the sidebar
    # arm's .24 must then go red.
    [switch]$NoColumnDeclare
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
. (Join-Path $testLib 'OccludedDisplay.ps1')   # T2650: a film of an occluded display is skipped, never scored
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

$Exe = [System.IO.Path]::GetFullPath($Exe)
$Spike = [System.IO.Path]::GetFullPath($Spike)
if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug"; exit 2 }
if ($NegativeControl) { $SlideMs = 0; "NEGATIVE CONTROL: the slide is 0 ms (an instant re-layout) - .5 MUST fail" }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-glide-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_GLIDE_TREE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_STACK_SLIDE_MS', 'GHOZTTY_DEBUG_GLIDE_STALL_MS', 'GHOZTTY_GLIDE_DECLARE', 'GHOZTTY_DEBUG_GLIDE_STALL_AT', 'GHOZTTY_FACE_COMP', 'GHOZTTY_DEBUG_GLIDE_LIVE_FACE', 'GHOZTTY_GLIDE_REGION_CUT', 'GHOZTTY_GLIDE_LANDING_TIMER', 'GHOZTTY_SIDEBAR_COLUMN_DECLARE', 'GHOZTTY_SIDEBAR_COLUMN_MS'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GhWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    static string Cls(IntPtr h) { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString(); }
    public static IntPtr[] TopLevel(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == cls) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    // "hwnd left top right bottom visible" per pane window.
    public static string[] Panes(IntPtr top) {
        var list = new List<string>();
        EnumChildWindows(top, (h, l) => {
            if (Cls(h) == "GhozttyTerminal") {
                RECT r; GetWindowRect(h, out r);
                list.Add(((long)h) + " " + r.Left + " " + r.Top + " " + r.Right + " " + r.Bottom + " " + (IsWindowVisible(h) ? 1 : 0));
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    // Size without activating, without touching the z-order (the ghost stays
    // at the bottom).
    public static bool Size(IntPtr h, int w, int ht) {
        return SetWindowPos(h, IntPtr.Zero, 0, 0, w, ht, 0x0002 | 0x0004 | 0x0010); // NOMOVE|NOZORDER|NOACTIVATE
    }
    // T2851: the first visible child window of a class ("hwnd left top right
    // bottom"), or null.
    public static string Child(IntPtr top, string cls) {
        string found = null;
        EnumChildWindows(top, (h, l) => {
            if (found == null && IsWindowVisible(h) && Cls(h) == cls) {
                RECT r; GetWindowRect(h, out r);
                found = ((long)h) + " " + r.Left + " " + r.Top + " " + r.Right + " " + r.Bottom;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // A left click posted straight to a child window at its CLIENT point.
    public static void ClickClient(IntPtr h, int cx, int cy) {
        IntPtr lp = (IntPtr)(((cy & 0xFFFF) << 16) | (cx & 0xFFFF));
        PostMessageW(h, 0x0200, IntPtr.Zero, lp);
        System.Threading.Thread.Sleep(20);
        PostMessageW(h, 0x0201, (IntPtr)1, lp);
        System.Threading.Thread.Sleep(40);
        PostMessageW(h, 0x0202, IntPtr.Zero, lp);
    }
    // A left click at a SCREEN point, posted: no SetCursorPos, no input
    // attachment, nothing the person at the desk can feel.
    public static void Click(IntPtr top, int sx, int sy) {
        var p = new POINT(); p.X = sx; p.Y = sy;
        ScreenToClient(top, ref p);
        IntPtr lp = (IntPtr)(((p.Y & 0xFFFF) << 16) | (p.X & 0xFFFF));
        PostMessageW(top, 0x0200, IntPtr.Zero, lp);          // WM_MOUSEMOVE
        System.Threading.Thread.Sleep(20);
        PostMessageW(top, 0x0201, (IntPtr)1, lp);            // WM_LBUTTONDOWN, MK_LBUTTON
        System.Threading.Thread.Sleep(40);
        PostMessageW(top, 0x0202, IntPtr.Zero, lp);          // WM_LBUTTONUP
    }
}
public static class Blocks {
    // Which block colour a pixel is, or -1: 0 red, 1 green, 2 blue, 3 magenta.
    // Pure primaries over a black pane, with room for the unfocused dim and
    // a card's shadow to darken them.
    static int Kind(int r, int g, int b) {
        if (r > 110 && g < 60 && b < 60) return 0;
        if (g > 110 && r < 60 && b < 60) return 1;
        if (b > 110 && r < 60 && g < 60) return 2;
        if (r > 110 && b > 110 && g < 60) return 3;
        return -1;
    }
    // Per colour: rows present, top, bottom, min/max of each row's left and
    // right edge, bbox left/right, pixel count. 4 x 9 ints.
    public static int[] Score(byte[] px, int stride, int w, int h) {
        var o = new int[36];
        for (int k = 0; k < 4; k++) {
            o[k * 9 + 1] = int.MaxValue; o[k * 9 + 3] = int.MaxValue; o[k * 9 + 5] = int.MaxValue;
            o[k * 9 + 7] = int.MaxValue;
        }
        var rl = new int[4]; var rr = new int[4];
        for (int y = 0; y < h; y++) {
            for (int k = 0; k < 4; k++) { rl[k] = -1; rr[k] = -1; }
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                int k = Kind(px[i + 2], px[i + 1], px[i]);
                if (k < 0) continue;
                if (rl[k] < 0) rl[k] = x;
                rr[k] = x;
                o[k * 9 + 8]++;
            }
            for (int k = 0; k < 4; k++) {
                if (rl[k] < 0 || rr[k] - rl[k] < 4) continue;
                int b = k * 9;
                o[b]++;
                o[b + 1] = Math.Min(o[b + 1], y); o[b + 2] = Math.Max(o[b + 2], y);
                o[b + 3] = Math.Min(o[b + 3], rl[k]); o[b + 4] = Math.Max(o[b + 4], rl[k]);
                o[b + 5] = Math.Min(o[b + 5], rr[k]); o[b + 6] = Math.Max(o[b + 6], rr[k]);
            }
        }
        return o;
    }
    // T2851: the blades in a band of rows (y0..y1) - a column is a blade's
    // when 60%+ of the band's pixels in it are within `tol` of (r,g,b) (the
    // name's ink is the rest); a run of 3+ such columns is a blade. Returns
    // each blade's left edge, left to right.
    public static int[] Runs(byte[] px, int stride, int w, int h, int r, int g, int b, int tol, int y0, int y1) {
        y0 = Math.Max(0, y0); y1 = Math.Min(h, y1);
        int need = (int)Math.Ceiling(0.6 * (y1 - y0));
        var lefts = new List<int>();
        int run = 0;
        for (int x = 0; x <= w; x++) {
            int n = 0;
            if (x < w) {
                for (int y = y0; y < y1; y++) {
                    int i = y * stride + x * 4;
                    if (Math.Abs(px[i + 2] - r) <= tol && Math.Abs(px[i + 1] - g) <= tol && Math.Abs(px[i] - b) <= tol) n++;
                }
            }
            if (x < w && n >= need) { run++; continue; }
            if (run >= 3) lefts.Add(x - run);
            run = 0;
        }
        return lefts.ToArray();
    }
    // T2855: is column x of a band (y0..y1) the background (r,g,b)? 90% of
    // its pixels within `tol`.
    static bool Bg(byte[] px, int stride, int x, int r, int g, int b, int tol, int y0, int y1) {
        int n = 0, need = (int)Math.Ceiling(0.9 * (y1 - y0));
        for (int y = y0; y < y1; y++) {
            int i = y * stride + x * 4;
            if (Math.Abs(px[i + 2] - r) <= tol && Math.Abs(px[i + 1] - g) <= tol && Math.Abs(px[i] - b) <= tol) n++;
        }
        return n >= need;
    }
    // T2855: the sidebar card's right edge in a band of rows: from xStart
    // (inside the card) rightwards, the first of `minRun`+ background
    // columns in a row. -1 when the band never meets the background.
    public static int CardEdge(byte[] px, int stride, int w, int h, int r, int g, int b, int tol, int y0, int y1, int xStart, int minRun) {
        y0 = Math.Max(0, y0); y1 = Math.Min(h, y1);
        int run = 0;
        for (int x = Math.Max(0, xStart); x < w; x++) {
            if (Bg(px, stride, x, r, g, b, tol, y0, y1)) { run++; if (run >= minRun) return x - run + 1; }
            else run = 0;
        }
        return -1;
    }
    // T2855: the leftmost column at or right of xStart holding ink - a
    // pixel at least `delta` (summed over r,g,b) off the background - in a
    // band of rows: the pane's prompt, which rides the pane's left edge.
    public static int Ink(byte[] px, int stride, int w, int h, int r, int g, int b, int delta, int y0, int y1, int xStart) {
        y0 = Math.Max(0, y0); y1 = Math.Min(h, y1);
        for (int x = Math.Max(0, xStart); x < w; x++) {
            for (int y = y0; y < y1; y++) {
                int i = y * stride + x * 4;
                if (Math.Abs(px[i + 2] - r) + Math.Abs(px[i + 1] - g) + Math.Abs(px[i] - b) >= delta) return x;
            }
        }
        return -1;
    }
}
'@

$colourNames = 'red', 'green', 'blue', 'magenta'
$consoleColours = 'DarkRed', 'DarkGreen', 'DarkBlue', 'DarkMagenta'

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}
function Wait-Log($path, $pattern, $ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Get-Panes([IntPtr]$top) {
    return @([GhWin]::Panes($top) | ForEach-Object {
            $f = $_ -split ' '
            [pscustomobject]@{ Hwnd = [int64]$f[0]; Left = [int]$f[1]; Top = [int]$f[2]; Right = [int]$f[3]; Bottom = [int]$f[4]; Visible = ($f[5] -eq '1') }
        } | Sort-Object Left)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$ms = 15000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        $v = @(Get-Panes $top | Where-Object Visible)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return @(Get-Panes $top | Where-Object Visible)
}
# Paint a pane's block: cls, then 8 rows of 16 coloured cells near the top,
# one row and two cells in so the card's rounded corner never clips it.
function Paint($target, $flag, [int]$k) {
    $c = $consoleColours[$k]
    # argv-audit: a fixed command with no double quote and no trailing backslash survives a native argv; $c is a console colour name
    $r =(& $Exe +send-keys "--$flag=$target" "cls; ''; 1..8 | % { Write-Host '  ' -NoNewline; Write-Host (' ' * 16) -BackgroundColor $c }" Enter 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { "  send-keys $target -> exit $LASTEXITCODE $r" }
}

function Measure-Frame($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        $s = [Blocks]::Score($bytes, $stride, $bmp.Width, $bmp.Height)
        $out = @()
        for ($k = 0; $k -lt 4; $k++) {
            $b = $k * 9
            $out += [pscustomobject]@{
                Rows = $s[$b]; Top = $s[$b + 1]; Bottom = $s[$b + 2]
                LeftMin = $s[$b + 3]; LeftMax = $s[$b + 4]; RightMin = $s[$b + 5]; RightMax = $s[$b + 6]
                Count = $s[$b + 8]
            }
        }
        return , $out
    } finally { $bmp.Dispose() }
}

function Score-Film($arm, $fdir) {
    $rows = @(Get-Content (Join-Path $fdir 'frames.txt') | Where-Object { $_ -match '^\d' } | ForEach-Object {
            $p = $_ -split ' '
            [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; B = (Measure-Frame (Join-Path $fdir ('f{0:d4}.bmp' -f [int]$p[0]))) }
        })
    Assert "$arm.4 the film has frames ($($rows.Count))" ($rows.Count -ge 5)
    if ($rows.Count -lt 5) { return }
    $first = $rows[0]; $last = $rows[$rows.Count - 1]
    $glideBest = 0; $glideWho = ''
    $wholeBad = @(); $heldBad = @(); $tornBad = @()
    for ($k = 0; $k -lt 4; $k++) {
        $a = $first.B[$k]; $z = $last.B[$k]
        $on0 = $a.Rows -gt 0; $on1 = $z.Rows -gt 0
        # Rest size: from whichever end has the block on show.
        $ref = if ($on0) { $a } else { $z }
        if ($ref.Rows -eq 0) { "    $($colourNames[$k]): never on show"; continue }
        $restH = $ref.Rows
        $restW = $ref.RightMax - $ref.LeftMin + 1
        $positions = @{}
        $lo = $null; $hi = $null
        if ($on0 -and $on1) { $lo = [Math]::Min($a.RightMax, $z.RightMax); $hi = [Math]::Max($a.RightMax, $z.RightMax) }
        $seen = 0; $missing = 0
        $seenAt = @($rows | Where-Object { $_.B[$k].Rows -gt 0 } | ForEach-Object { $_.I })
        $firstSeen = if ($on0) { -1 } else { $seenAt[0] }
        $lastSeen = if ($on1) { -1 } else { $seenAt[-1] }
        foreach ($f in $rows) {
            $b = $f.B[$k]
            if ($b.Rows -eq 0) { if ($on0 -and $on1) { $missing++ }; continue }
            $seen++
            if ($on0 -and $on1 -and $b.Rows -lt [Math]::Floor(0.9 * $restH)) { $missing++ }
            $w = $b.RightMax - $b.LeftMin + 1
            if ($b.Rows -gt $restH + 2 -or $w -gt $restW + 2) { $heldBad += "$($colourNames[$k]) f$($f.I) ${w}x$($b.Rows) vs rest ${restW}x$restH" }
            # Torn: rows disagree on an edge. A card's clip is a straight
            # vertical line, so occlusion moves an edge for every row at once.
            # A card coming out of (or going into) its strip is judged only
            # while it is whole (90% of its rest rows, the .6 bar): its face
            # fades the block in over the glass band, whose gradient puts a
            # half-strength block across the pure-colour threshold row by row
            # (T2779: green 113 at its top, 109 at its foot), and a block
            # caught there is partly detected, not torn. Its faintest frame -
            # the first an opening card is seen in, the last a folding one is
            # - is never judged either: in the tree its face is on film from
            # content_alpha's first step (T2818), and that step's block sits
            # on the threshold along its edge too (green f14 right 159..168,
            # one run in three).
            $faint = (-not ($on0 -and $on1)) -and ($f.I -eq $firstSeen -or $f.I -eq $lastSeen)
            $judged = (($on0 -and $on1) -or $b.Rows -ge [Math]::Floor(0.9 * $restH)) -and -not $faint
            if ($judged -and (($b.LeftMax - $b.LeftMin) -gt 2 -or ($b.RightMax - $b.RightMin) -gt 2)) {
                $tornBad += "$($colourNames[$k]) f$($f.I) left $($b.LeftMin)..$($b.LeftMax) right $($b.RightMin)..$($b.RightMax)"
            }
            if ($null -ne $lo -and $b.RightMax -gt $lo -and $b.RightMax -lt $hi) { $positions[$b.RightMax] = $true }
        }
        # A block that came on show (or went) has one settled end: count its
        # positions on the way from the first frame it appears in.
        if (-not ($on0 -and $on1)) {
            $endRight = if ($on1) { $z.RightMax } else { $a.RightMax }
            foreach ($f in $rows) {
                $b = $f.B[$k]
                if ($b.Rows -gt 0 -and $b.RightMax -ne $endRight) { $positions[$b.RightMax] = $true }
            }
        }
        if ($missing -gt 0) { $wholeBad += "$($colourNames[$k]) missing or cut short in $missing frame(s)" }
        $travel = if ($on0 -and $on1) { $hi - $lo } else { -1 }
        "    $($colourNames[$k]): start=$(if ($on0) { "$($a.LeftMin)-$($a.RightMax)" } else { 'tucked' }) end=$(if ($on1) { "$($z.LeftMin)-$($z.RightMax)" } else { 'tucked' }) rest=${restW}x$restH seen=$seen/$($rows.Count) travel=$travel positions_on_the_way=$($positions.Count)"
        if (($travel -lt 0 -or $travel -gt 40) -and $positions.Count -gt $glideBest) { $glideBest = $positions.Count; $glideWho = $colourNames[$k] }
    }
    Assert "$arm.5 glide: a card is seen at $glideBest positions on the way ($glideWho; need 2+) - it slides, it does not jump" ($glideBest -ge 2)
    Assert "$arm.6 whole: every card on show at both ends is on screen in every frame$(if ($wholeBad) { ': ' + ($wholeBad -join '; ') })" ($wholeBad.Count -eq 0)
    Assert "$arm.7 held: no card's picture is ever larger than its rest size (clipped, never stretched)$(if ($heldBad) { ': ' + (($heldBad | Select-Object -First 4) -join '; ') + " ($($heldBad.Count))" })" ($heldBad.Count -eq 0)
    Assert "$arm.8 untorn: every card's rows share one left and one right edge in every frame$(if ($tornBad) { ': ' + (($tornBad | Select-Object -First 4) -join '; ') + " ($($tornBad.Count))" })" ($tornBad.Count -eq 0)
    if ($arm -eq 'tree') { Score-TreeFaces $arm $rows }
    if ($arm -in 'stall', 'live') { Score-Stall $arm $rows }
    if ($arm -eq 'unfold') { Score-StallUnfold $arm $rows ($StallMs / 4.0) }
}

# T2572: the card that travels furthest, frame by frame - the longest gap in
# the film's own clock between two frames that show it somewhere new, from
# its first move to where it settles. WGC delivers a frame only when the
# window's picture changes, so a frozen glide is a gap, not a run of
# identical frames.
function Score-Stall($arm, $rows) {
    # The LEFT edge: the right one also takes the card's new width when the
    # glide lands (a pane held at its old size, resized once at the end).
    $best = -1; $bestK = -1
    for ($k = 0; $k -lt 4; $k++) {
        $a = $rows[0].B[$k]; $z = $rows[$rows.Count - 1].B[$k]
        if ($a.Rows -eq 0 -or $z.Rows -eq 0) { continue }
        $d = [Math]::Abs($z.LeftMin - $a.LeftMin)
        if ($d -gt $best) { $best = $d; $bestK = $k }
    }
    if ($bestK -lt 0 -or $best -le 40) { Assert "$arm.10 a card travels far enough to time ($best px)" $false; return }
    # Timed while 5% of the way is still to go: the follower's last pixels
    # come a few apart in time by design (each frame closes a share of what
    # is left), which is a slow glide, not a stalled one.
    $endLeft = $rows[$rows.Count - 1].B[$bestK].LeftMin
    $near = [Math]::Max(2, [int](0.05 * $best))
    $prev = $rows[0].B[$bestK].LeftMin
    $lastMoveT = $null; $gap = 0.0; $gapAt = ''; $moves = 0
    foreach ($f in $rows) {
        $r = $f.B[$bestK].LeftMin
        if ($f.B[$bestK].Rows -eq 0 -or $r -eq $prev) { continue }
        if ($null -ne $lastMoveT -and ($f.T - $lastMoveT) -gt $gap) { $gap = $f.T - $lastMoveT; $gapAt = "f$($f.I)" }
        $lastMoveT = $f.T; $prev = $r; $moves++
        if ([Math]::Abs($r - $endLeft) -le $near) { break }
    }
    $limit = $StallMs / 4.0
    $t0 = $rows[0].T
    "    trace ($($colourNames[$bestK]) ms:left-right): " + (($rows | ForEach-Object { $b = $_.B[$bestK]; "$([Math]::Round($_.T - $t0)):$($b.LeftMin)-$($b.RightMax)" }) -join ' ')
    "    stall:$($colourNames[$bestK]) travels $best px in $moves moves; longest still stretch $([Math]::Round($gap)) ms (ending $gapAt), stall $StallMs ms"
    Assert "$arm.10 through a $StallMs ms stall the glide keeps moving: longest still stretch $([Math]::Round($gap)) ms (need < $limit)" ($moves -ge 2 -and $gap -lt $limit)
    Score-StallFace $arm $rows $limit
}

# T2778: the card folding into its strip, through the same stall. In the
# composition pane tree its face is a picture in the window's own tree, so
# the film sees it: the carried frame (the card's block) cut to the card,
# fading as the card narrows. Every change of the block counts as a move -
# an edge, and the frame it fades out of the film - from the first frame to
# that one; a face stepped from the window's thread holds still for the
# whole stall.
function Score-StallFace($arm, $rows, $limit) {
    $fk = -1
    for ($k = 0; $k -lt 4; $k++) {
        if ($rows[0].B[$k].Rows -gt 0 -and $rows[$rows.Count - 1].B[$k].Rows -eq 0) { $fk = $k; break }
    }
    if ($fk -lt 0) { Assert "$arm.13 a card folds into its strip on film (none on show at the start and gone at the end)" $false; return }
    $prev = $rows[0].B[$fk]
    # Timed from its first move: the film opens on the card at rest before
    # the click, which is not a stall.
    $lastT = $null; $gap = 0.0; $gapAt = ''; $moves = 0
    foreach ($f in $rows) {
        $b = $f.B[$fk]
        $gone = $b.Rows -eq 0
        if (-not $gone -and $b.LeftMin -eq $prev.LeftMin -and $b.RightMax -eq $prev.RightMax) { continue }
        if ($null -ne $lastT -and ($f.T - $lastT) -gt $gap) { $gap = $f.T - $lastT; $gapAt = "f$($f.I)" }
        $lastT = $f.T; $prev = $b; $moves++
        if ($gone) { break }
    }
    $t0 = $rows[0].T
    "    face trace ($($colourNames[$fk]) ms:left-right): " + (($rows | ForEach-Object { $b = $_.B[$fk]; "$([Math]::Round($_.T - $t0)):$($b.LeftMin)-$($b.RightMax)" }) -join ' ')
    "    face:$($colourNames[$fk]) $moves moves until it left the film; longest still stretch $([Math]::Round($gap)) ms (ending $gapAt)"
    Assert "$arm.13 through the stall the folding card's face keeps folding: longest still stretch $([Math]::Round($gap)) ms (need < $limit)" ($moves -ge 2 -and $gap -lt $limit)
}

# T2818: the folding and the opening card in the composition pane tree,
# with no stall. Their faces are pictures in the window's own tree (T2777),
# so the film sees them - a face left on its layered popup is never in a
# window capture (T2561), and its card reads empty (opening) or gone
# (folding) for the whole glide. Each card's block is counted at the
# distinct places it is seen strictly on the way: the folding one between
# its rest place and leaving the film, the opening one between first showing
# and where it settles. Two or more is a face the film saw travel.
function Score-TreeFaces($arm, $rows) {
    $first = $rows[0]; $last = $rows[$rows.Count - 1]
    $fk = -1; $uk = -1
    for ($k = 0; $k -lt 4; $k++) {
        if ($first.B[$k].Rows -gt 0 -and $last.B[$k].Rows -eq 0 -and $fk -lt 0) { $fk = $k }
        if ($first.B[$k].Rows -eq 0 -and $last.B[$k].Rows -gt 0 -and $uk -lt 0) { $uk = $k }
    }
    $t0 = $first.T
    foreach ($pair in @(@($fk, 'fold', '.18', 'the folding card''s face is on film as it folds'), @($uk, 'unfold', '.19', 'the opening card''s face is on film as it opens'))) {
        $k = $pair[0]; $what = $pair[1]; $id = $pair[2]; $claim = $pair[3]
        if ($k -lt 0) { Assert "$arm$id a card ${what}s on film (none found)" $false; continue }
        $rest = if ($what -eq 'fold') { $first.B[$k] } else { $last.B[$k] }
        $places = @{}
        $far = 0
        foreach ($f in $rows) {
            $b = $f.B[$k]
            if ($b.Rows -eq 0) { continue }
            if ($b.LeftMin -eq $rest.LeftMin -and $b.RightMax -eq $rest.RightMax) { continue }
            $places["$($b.LeftMin)-$($b.RightMax)"] = $true
            $far = [Math]::Max($far, [Math]::Abs($b.LeftMin - $rest.LeftMin))
        }
        $restW = $rest.RightMax - $rest.LeftMin + 1
        "    $what trace ($($colourNames[$k]) ms:left-right): " + (($rows | ForEach-Object { $b = $_.B[$k]; if ($b.Rows -gt 0) { "$([Math]::Round($_.T - $t0)):$($b.LeftMin)-$($b.RightMax)" } else { "$([Math]::Round($_.T - $t0)):-" } }) -join ' ')
        if ($what -eq 'fold') {
            # The pane's own picture moves a frame or two before its face
            # takes over: under a popup face it leaves the film after 18 of 192
            # px, a face in the tree folds on to the strip (171 of 192).
            Assert "$arm$id ${claim}: seen at $($places.Count) place(s), its left edge $far of $restW px on the way to the strip ($($colourNames[$k]); need 2+ places and half its width)" ($places.Count -ge 2 -and 2 * $far -ge $restW)
        } else {
            Assert "$arm$id ${claim}: seen at $($places.Count) place(s) on the way ($($colourNames[$k]); need 2+)" ($places.Count -ge 2)
        }
    }
}

# T2779: the card opening out of its strip, through a stall that lands once
# its content is well in (GHOZTTY_DEBUG_GLIDE_STALL_AT=unfold). Its block is
# not on show at the start and is at the end; every change of its edges is a
# move, timed from its first appearance until both edges are within 5% of
# where they settle (the follower's last pixels come slowly by design). A
# face stepped from the window's thread holds still for the whole stall.
function Score-StallUnfold($arm, $rows, $limit) {
    $uk = -1
    for ($k = 0; $k -lt 4; $k++) {
        if ($rows[0].B[$k].Rows -eq 0 -and $rows[$rows.Count - 1].B[$k].Rows -gt 0) { $uk = $k; break }
    }
    if ($uk -lt 0) { Assert "$arm.15 a card opens out of its strip on film (not on show at the start, on show at the end)" $false; return }
    $z = $rows[$rows.Count - 1].B[$uk]
    $firstI = -1
    for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].B[$uk].Rows -gt 0) { $firstI = $i; break } }
    $a = $rows[$firstI].B[$uk]
    $travel = [Math]::Max([Math]::Abs($z.LeftMin - $a.LeftMin), [Math]::Abs($z.RightMax - $a.RightMax))
    $near = [Math]::Max(2, [int](0.05 * $travel))
    $prev = $a; $lastT = $rows[$firstI].T; $gap = 0.0; $gapAt = ''; $moves = 0
    for ($i = $firstI + 1; $i -lt $rows.Count; $i++) {
        $f = $rows[$i]; $b = $f.B[$uk]
        if ($b.Rows -eq 0 -or ($b.LeftMin -eq $prev.LeftMin -and $b.RightMax -eq $prev.RightMax)) { continue }
        if (($f.T - $lastT) -gt $gap) { $gap = $f.T - $lastT; $gapAt = "f$($f.I)" }
        $lastT = $f.T; $prev = $b; $moves++
        if ([Math]::Abs($b.LeftMin - $z.LeftMin) -le $near -and [Math]::Abs($b.RightMax - $z.RightMax) -le $near) { break }
    }
    $t0 = $rows[0].T
    "    unfold trace ($($colourNames[$uk]) ms:left-right): " + (($rows | ForEach-Object { $b = $_.B[$uk]; "$([Math]::Round($_.T - $t0)):$($b.LeftMin)-$($b.RightMax)" }) -join ' ')
    "    unfold:$($colourNames[$uk]) first on film at $($a.LeftMin)-$($a.RightMax), settles at $($z.LeftMin)-$($z.RightMax); $moves moves; longest still stretch $([Math]::Round($gap)) ms (ending $gapAt)"
    Assert "$arm.15 through the stall the opening card's face keeps opening: longest still stretch $([Math]::Round($gap)) ms (need < $limit)" ($moves -ge 2 -and $travel -gt 40 -and $gap -lt $limit)
}

$onLine = 'pane presents through a composition swap chain'

function Read-Bmp($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $o = [pscustomobject]@{ Px = $bytes; Stride = $data.Stride; W = $bmp.Width; H = $bmp.Height }
        $bmp.UnlockBits($data)
        return $o
    } finally { $bmp.Dispose() }
}

# T2851: a strip that stays a strip and moves (T2417/T2825), filmed through a
# stall. Five panes beside the pane sidebar's rail in the flat style, so the
# first is tucked into a blade at the grid's leading edge (the
# pane-sidebar-glide.ps1 section 6 shape); a posted click on the sidebar's
# toggle expands it and the grid - blade and all - glides right. The blade is
# a band of `pane_stack_strip.stripRgb` of the background, read off the first
# frame just right of the rail; its leading edge is followed frame by frame.
#   .22 through the stall the blade keeps moving: its longest still stretch,
#       from its first move until within 5% of where it lands, stays under a
#       quarter of the stall (stepped from the window's thread it holds for
#       all of it - -NoDeclare must go red here)
#   .23 the blade was declared to the compositor as a face (the log)
function Invoke-StripArm($arm, $dir, $err) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        '--window-width=100', '--window-height=30', "--background=$StripBg",
        '--command=powershell.exe -NoLogo -NoProfile', "--title=t2851-$arm",
        '--macos-pane-style=flat') -StdErr $err
    $top = $null
    for ($t = 0; $t -lt 100 -and -not $top; $t++) {
        $w = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
        if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
    }
    Assert "$arm.0 the ghost window came up" ($null -ne $top)
    if (-not $top) { return }
    $name = "gl$arm"
    & $Exe +new-window "--target=$name" 2>$null | Out-Null
    $hw = $null
    for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
        $hw = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
        if (-not $hw) { Start-Sleep -Milliseconds 200 }
    }
    Assert "$arm.1 the named window came up" ($null -ne $hw)
    if (-not $hw) { return }
    $scale = [Math]::Max(1, [GhWin]::GetDpiForWindow($hw)) / 96.0
    [void][GhWin]::Size($hw, [int](1100 * $scale), [int](700 * $scale))
    Start-Sleep -Milliseconds 1500
    $prev = $name
    for ($k = 1; $k -le 4; $k++) {
        $flag = if ($k -eq 1) { '--target' } else { '--pane' }
        & $Exe +split "$flag=$prev" '--direction=right' "--name=$name-$k" 2>$null | Out-Null
        Start-Sleep -Milliseconds 1000
        $prev = "$name-$k"
    }
    Start-Sleep -Milliseconds 1500
    $all = @(Get-Panes $hw)
    "  panes: $(($all | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(tucked)' })" }) -join ' | ')"
    $sbRow = [GhWin]::Child($hw, 'GhozttyPaneSidebar')
    $okSetup = ($all.Count -eq 5 -and -not $all[0].Visible -and $null -ne $sbRow)
    Assert "$arm.2 five panes beside the rail, the first tucked into a blade at the grid's leading edge" $okSetup
    if (-not $okSetup) { return }
    Assert "$arm.3t every pane went into the window tree (adopts=5)" (Wait-Log $err 'adopted into the window tree \(adopts=5\)' 15000)
    $sbf = $sbRow -split ' '
    $sbH = [IntPtr][int64]$sbf[0]; $sbLeft = [int]$sbf[1]; $sbTop = [int]$sbf[2]; $sbRight = [int]$sbf[3]
    $wr = New-Object GhWin+RECT
    [void][GhWin]::GetWindowRect($hw, [ref]$wr)

    $fdir = Join-Path $dir 'film'
    $filmErr = Join-Path $dir 'film.txt'
    $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$($SlideMs + 1500)") `
        -NoNewWindow -PassThru -RedirectStandardError $filmErr
    $ready = $false
    for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
    Assert "$arm.3a the film started" $ready
    Start-Sleep -Milliseconds 300
    # The toggle (T2289, pane-sidebar-glide.ps1 Get-ToggleCenter): the rail's
    # 12 DIP margin, the 52 DIP card's inset to its 28 DIP tile, the tile's middle.
    $tc = [int][Math]::Round((12 + 12 + 14) * $scale)
    [GhWin]::ClickClient($sbH, $tc, $tc)
    [void]$fp.WaitForExit(60000)
    $filmOut = (Read-Text $filmErr).Trim()
    "  $filmOut"
    Assert "$arm.3b the film finished" ($filmOut -match '^FILM ok')
    $sbAfter = [GhWin]::Child($hw, 'GhozttyPaneSidebar')
    $grew = $false
    if ($sbAfter) { $f2 = $sbAfter -split ' '; $grew = ([int]$f2[3] - [int]$f2[1]) -gt ($sbRight - $sbLeft) + 40 }
    Assert "$arm.3c the sidebar expanded ($sbRow -> $sbAfter)" $grew

    $rows = @(Get-Content (Join-Path $fdir 'frames.txt') -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d' } | ForEach-Object {
            $p = $_ -split ' '
            [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; Path = (Join-Path $fdir ('f{0:d4}.bmp' -f [int]$p[0])) }
        })
    Assert "$arm.4 the film has frames ($($rows.Count))" ($rows.Count -ge 5)
    if ($rows.Count -lt 5) { return }
    # Window rect -> frame: the film is the window's own picture, so a screen
    # point maps by the window's origin, scaled if the frame is not 1:1.
    $f0 = Read-Bmp $rows[0].Path
    $kx = $f0.W / [double]($wr.Right - $wr.Left); $ky = $f0.H / [double]($wr.Bottom - $wr.Top)
    $railX = [int](($sbRight - $wr.Left) * $kx)
    $y0 = [int](($sbTop - $wr.Top + 0.35 * ($wr.Bottom - $sbTop)) * $ky); $y1 = [int](($sbTop - $wr.Top + 0.65 * ($wr.Bottom - $sbTop)) * $ky)
    $sx = $railX + [int][Math]::Round(6 * $scale); $sy = [int](($y0 + $y1) / 2)
    $i = $sy * $f0.Stride + $sx * 4
    $sr = $f0.Px[$i + 2]; $sg = $f0.Px[$i + 1]; $sbb = $f0.Px[$i]
    "  frame $($f0.W)x$($f0.H) for window $($wr.Right - $wr.Left)x$($wr.Bottom - $wr.Top); rail edge at x=$railX; blade colour at ($sx,$sy) = $sr,$sg,$sbb"
    $edges = @(foreach ($r in $rows) {
            $b = if ($r -eq $rows[0]) { $f0 } else { Read-Bmp $r.Path }
            $runs = @([Blocks]::Runs($b.Px, $b.Stride, $b.W, $b.H, $sr, $sg, $sbb, 10, $y0, $y1))
            [pscustomobject]@{ I = $r.I; T = $r.T; X = $(if ($runs.Count -gt 0) { $runs[0] } else { -1 }); Set = ($runs -join ',') }
        })
    $t0 = $edges[0].T
    "    blade trace (ms:lefts): " + (($edges | ForEach-Object { "$([Math]::Round($_.T - $t0)):$(if ($_.Set) { $_.Set } else { '-' })" }) -join ' ')
    $a = $edges[0].X; $z = $edges[$edges.Count - 1].X
    $okRest = $a -ge 0 -and [Math]::Abs($a - $railX) -le [int](20 * $scale)
    Assert "$arm.2c the blade is found on the first frame at the rail's edge (left $a, rail $railX)" $okRest
    $travel = $z - $a
    if (-not $okRest -or $z -lt 0 -or $travel -le 40) { Assert "$arm.22 the blade travels far enough to time ($a -> $z)" $false; return }
    $near = [Math]::Max(2, [int](0.05 * $travel))
    $limit = $StallMs / 4.0
    # .22 the LEADING edge - the leftmost blade on screen, which is what the
    # user reads as where the grid starts. A copy of the blade left behind at
    # its start (a desk the stalled thread never repainted), or a blade gone
    # from the screen, holds it still or throws it back, and both are on film.
    $prevX = $a; $lastT = $null; $gap = 0.0; $gapAt = ''; $moves = 0; $back = @()
    foreach ($e in $edges) {
        if ($e.X -lt 0 -or $e.X -eq $prevX) { continue }
        if ($e.X -lt $prevX) { $back += "f$($e.I) $prevX->$($e.X)" }
        if ($null -ne $lastT -and ($e.T - $lastT) -gt $gap) { $gap = $e.T - $lastT; $gapAt = "f$($e.I)" }
        $lastT = $e.T; $prevX = $e.X; $moves++
        if ([Math]::Abs($e.X - $z) -le $near) { break }
    }
    # The leading edge after it first reached its landing: a blade that
    # leaves the screen before the landing is painted reads as the next one.
    $arrived = $false; $gone = @()
    foreach ($e in $edges) {
        if (-not $arrived) { $arrived = [Math]::Abs($e.X - $z) -le $near; continue }
        if ($e.X -lt 0 -or $e.X -gt $z + $near) { $gone += $e }
    }
    "    leading blade travels $travel px in $moves moves; longest still stretch $([Math]::Round($gap)) ms (ending $gapAt), stall $StallMs ms; went back $($back.Count)x$(if ($back) { ' (' + (($back | Select-Object -First 3) -join '; ') + ')' })"
    Assert "$arm.22 through a $StallMs ms stall the leading blade keeps moving: longest still stretch $([Math]::Round($gap)) ms (need < $limit), never back ($($back.Count))" ($moves -ge 2 -and $gap -lt $limit -and $back.Count -eq 0)
    $goneMs = if ($gone.Count) { [Math]::Round($gone[-1].T - $gone[0].T) } else { 0 }
    Assert "$arm.22c once at its landing the leading blade stays on screen ($($gone.Count) frame(s) without it$(if ($gone.Count) { ", f$($gone[0].I)-f$($gone[-1].I), $goneMs ms" }))" ($gone.Count -eq 0)
    # .22b ANY blade on the move: the band's set of blades changes - one
    # declared to the compositor moves on through the stall whatever the
    # desk under it shows; a stepped one freezes with the thread. Timed from
    # the glide's first change over the stall's span and half as much again (the
    # stall lands on the glide's first tick); the follower's slow tail after
    # that is not the stall's.
    $prevSet = $edges[0].Set; $lastT = $null; $gapB = 0.0; $gapBAt = ''; $changes = 0; $tEnd = $null
    foreach ($e in $edges) {
        if ($null -ne $tEnd -and $e.T -gt $tEnd) {
            # Still since the last change, up to the window's end, counts too.
            if (($tEnd - $lastT) -gt $gapB) { $gapB = $tEnd - $lastT; $gapBAt = "the window's end" }
            break
        }
        if ($e.Set -eq $prevSet) { continue }
        if ($null -eq $tEnd) { $tEnd = $e.T + 1.5 * $StallMs }
        if ($null -ne $lastT -and ($e.T - $lastT) -gt $gapB) { $gapB = $e.T - $lastT; $gapBAt = "f$($e.I)" }
        $lastT = $e.T; $prevSet = $e.Set; $changes++
    }
    "    the band's blades change $changes times in the $(1.5 * $StallMs) ms from the glide's first change; longest still stretch $([Math]::Round($gapB)) ms (ending $gapBAt)"
    Assert "$arm.22b through the stall a blade is on the move: longest still stretch of the band $([Math]::Round($gapB)) ms (need < $limit)" ($changes -ge 2 -and $gapB -lt $limit)

    $text = Read-Text $err
    $stalled = [regex]::Matches($text, 'stack glide debug stall ms=').Count
    Assert "$arm.22a the stall landed in the glide ($stalled)" ($stalled -ge 1)
    $faces = [regex]::Matches($text, 'stack strip face declared').Count
    Assert "$arm.23 the blade was handed to the compositor as a face ($faces declaration(s))" ($faces -ge 1)
    $fgPid = [uint32]0
    [void][GhWin]::GetWindowThreadProcessId([GhWin]::GetForegroundWindow(), [ref]$fgPid)
    Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
    if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    return
}

# T2855: the pane sidebar column's declared glide (T2827), filmed through a
# stall. Two panes beside the rail in the flat style (pane-sidebar-glide.ps1
# section 7's shape), the panes' background a colour nothing else in the
# band uses (-StripBg); a posted click on the toggle expands the sidebar and
# the grid glides right with the column's edge on the same follower. Each
# frame, the sidebar card's right edge (in a band of rows at mid-height, where
# its lighter fill meets the background) and the leading pane's prompt (its
# leftmost ink on the first cell row - a flat pane is the background colour,
# so the prompt is what rides its left edge) are found.
#   .24  the column follows the grid: its card's edge leaves the rail within
#        a quarter of the stall of the grid's first move, and the gutter then
#        never opens past its rest width - a column stepped from the stalled
#        thread freezes while the declared grid glides on
#        (-NoColumnDeclare must go red here)
#   .24d the gutter within 2 px of its rest width on every frame (T2872)
#   .24b the leading card keeps moving through the stall (-NoDeclare, which
#        steps both, must go red here: frozen together, the gutter holds)
#   .25  the log names the column's declaration
function Invoke-SidebarArm($arm, $dir, $err) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        '--window-width=100', '--window-height=30', "--background=$StripBg",
        '--command=powershell.exe -NoLogo -NoProfile', "--title=t2855-$arm",
        '--macos-pane-style=flat') -StdErr $err
    $top = $null
    for ($t = 0; $t -lt 100 -and -not $top; $t++) {
        $w = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
        if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
    }
    Assert "$arm.0 the ghost window came up" ($null -ne $top)
    if (-not $top) { return }
    $name = "gl$arm"
    & $Exe +new-window "--target=$name" 2>$null | Out-Null
    $hw = $null
    for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
        $hw = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
        if (-not $hw) { Start-Sleep -Milliseconds 200 }
    }
    Assert "$arm.1 the named window came up" ($null -ne $hw)
    if (-not $hw) { return }
    $scale = [Math]::Max(1, [GhWin]::GetDpiForWindow($hw)) / 96.0
    [void][GhWin]::Size($hw, [int](1100 * $scale), [int](700 * $scale))
    Start-Sleep -Milliseconds 1500
    & $Exe +split "--target=$name" '--direction=right' "--name=$name-1" 2>$null | Out-Null
    Start-Sleep -Milliseconds 1500
    $all = @(Get-Panes $hw | Where-Object { $_.Visible } | Sort-Object Left)
    "  panes: $(($all | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | ')"
    $sbRow = [GhWin]::Child($hw, 'GhozttyPaneSidebar')
    $okSetup = ($all.Count -eq 2 -and $null -ne $sbRow)
    Assert "$arm.2 two panes beside the rail" $okSetup
    if (-not $okSetup) { return }
    Assert "$arm.3t both panes went into the window tree (adopts=2)" (Wait-Log $err 'adopted into the window tree \(adopts=2\)' 15000)
    $sbf = $sbRow -split ' '
    $sbH = [IntPtr][int64]$sbf[0]; $sbLeft = [int]$sbf[1]; $sbTop = [int]$sbf[2]; $sbRight = [int]$sbf[3]
    $leadLeft = $all[0].Left
    $wr = New-Object GhWin+RECT
    [void][GhWin]::GetWindowRect($hw, [ref]$wr)

    $fdir = Join-Path $dir 'film'
    $filmErr = Join-Path $dir 'film.txt'
    $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$($SlideMs + 1500)") `
        -NoNewWindow -PassThru -RedirectStandardError $filmErr
    $ready = $false
    for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
    Assert "$arm.3a the film started" $ready
    Start-Sleep -Milliseconds 300
    # The toggle: the rail's 12 DIP margin, the card's inset to its 28 DIP
    # tile, the tile's middle (the strip arm's point).
    $tc = [int][Math]::Round((12 + 12 + 14) * $scale)
    [GhWin]::ClickClient($sbH, $tc, $tc)
    [void]$fp.WaitForExit(60000)
    $filmOut = (Read-Text $filmErr).Trim()
    "  $filmOut"
    Assert "$arm.3b the film finished" ($filmOut -match '^FILM ok')
    $sbAfter = [GhWin]::Child($hw, 'GhozttyPaneSidebar')
    $grew = $false
    if ($sbAfter) { $f2 = $sbAfter -split ' '; $grew = ([int]$f2[3] - [int]$f2[1]) -gt ($sbRight - $sbLeft) + 40 }
    Assert "$arm.3c the sidebar expanded ($sbRow -> $sbAfter)" $grew

    $rows = @(Get-Content (Join-Path $fdir 'frames.txt') -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d' } | ForEach-Object {
            $p = $_ -split ' '
            [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; Path = (Join-Path $fdir ('f{0:d4}.bmp' -f [int]$p[0])) }
        })
    Assert "$arm.4 the film has frames ($($rows.Count))" ($rows.Count -ge 5)
    if ($rows.Count -lt 5) { return }
    $f0 = Read-Bmp $rows[0].Path
    $kx = $f0.W / [double]($wr.Right - $wr.Left); $ky = $f0.H / [double]($wr.Bottom - $wr.Top)
    $railX = [int](($sbRight - $wr.Left) * $kx)
    $leadX = [int](($leadLeft - $wr.Left) * $kx)
    $cardIn = [int](($sbLeft - $wr.Left) * $kx + 30 * $scale)
    # The card's edge is read in a band at mid-height (blank there, both in
    # the card and in the pane); the pane's edge by its prompt, on the first
    # cell row. Flat panes are the window's background, so the prompt is the
    # one thing on film that rides the leading card's left edge.
    $y0 = [int](($sbTop - $wr.Top + 0.40 * ($wr.Bottom - $sbTop)) * $ky); $y1 = [int](($sbTop - $wr.Top + 0.60 * ($wr.Bottom - $sbTop)) * $ky)
    $ty0 = [int](($all[0].Top - $wr.Top) * $ky); $ty1 = $ty0 + [int](32 * $scale)
    $bx = $leadX + [int](300 * $scale); $sy = [int](($y0 + $y1) / 2)
    $i = $sy * $f0.Stride + $bx * 4; $br = $f0.Px[$i + 2]; $bg = $f0.Px[$i + 1]; $bb = $f0.Px[$i]
    "  frame $($f0.W)x$($f0.H) for window $($wr.Right - $wr.Left)x$($wr.Bottom - $wr.Top); rail window edge x=$railX, leading pane x=$leadX; background $br,$bg,$bb at x=$bx; card band y=$y0..$y1 from x=$cardIn, prompt band y=$ty0..$ty1"
    $minRun = [int](8 * $scale)
    $meas = @(foreach ($r in $rows) {
            $b = if ($r -eq $rows[0]) { $f0 } else { Read-Bmp $r.Path }
            $e = [Blocks]::CardEdge($b.Px, $b.Stride, $b.W, $b.H, $br, $bg, $bb, 6, $y0, $y1, $cardIn, $minRun)
            $l = if ($e -ge 0) { [Blocks]::Ink($b.Px, $b.Stride, $b.W, $b.H, $br, $bg, $bb, 150, $ty0, $ty1, $e) } else { -1 }
            [pscustomobject]@{ I = $r.I; T = $r.T; E = $e; L = $l; Gap = $(if ($e -ge 0 -and $l -ge 0) { $l - $e } else { -1 }) }
        })
    $t0 = $meas[0].T
    "    gutter trace (ms:card|prompt=gap): " + (($meas | ForEach-Object { "$([Math]::Round($_.T - $t0)):$($_.E)|$($_.L)=$($_.Gap)" }) -join ' ')
    $rest = $meas[0].Gap; $a = $meas[0].L; $z = $meas[-1].L
    $okRest = $a -ge 0 -and $rest -gt 0 -and [Math]::Abs($a - $leadX) -le [int](40 * $scale) -and [Math]::Abs($meas[0].E - $railX) -le [int](24 * $scale)
    Assert "$arm.2c the gutter is found on the first frame (card edge $($meas[0].E) by the rail's $railX, prompt at $a in the pane from $leadX, $rest px apart)" $okRest
    $travel = $z - $a
    if (-not $okRest -or $z -lt 0 -or $travel -le 40) { Assert "$arm.24 the card travels far enough to score ($a -> $z)" $false; return }
    $near = [Math]::Max(2, [int](0.02 * $travel))
    # The glide: from the first frame the card has left its rest to the first
    # at its landing. Every frame in it is scored, the stall's included.
    $glide = @(); $started = $false
    foreach ($m in $meas) {
        if (-not $started) { $started = $m.L -ge 0 -and $m.L -ne $a }
        if (-not $started) { continue }
        $glide += $m
        if ($m.L -ge 0 -and [Math]::Abs($m.L - $z) -le $near) { break }
    }
    $e0 = $meas[0].E; $limit = [Math]::Max(100.0, $StallMs / 4.0)
    # .24 the column follows the grid through the stall: its visible edge
    # leaves the rail within a quarter of the stall of the grid's first move,
    # and from there to the landing the gutter never opens past its rest
    # width (2 px) nor closes to nothing. A column stepped from the stalled
    # thread holds at the rail for all of the stall while the declared grid
    # glides on, the gutter opening by the grid's travel.
    $leave = @($glide | Where-Object { $_.E -gt $e0 + 2 }) | Select-Object -First 1
    $lagMs = if ($leave -and $glide.Count) { [Math]::Round($leave.T - $glide[0].T) } else { -1 }
    $after = if ($leave) { @($glide | Where-Object { $_.T -ge $leave.T }) } else { @() }
    $open = @($after | Where-Object { $_.Gap -lt 1 -or $_.Gap -gt $rest + 2 })
    $widest = 0; foreach ($m in $glide) { $widest = [Math]::Max($widest, $m.Gap) }
    "    the card travels $travel px over $($glide.Count) frame(s); the column's edge leaves the rail $lagMs ms after the grid$(if ($leave) { " (f$($leave.I))" }); widest gutter $widest px against $rest at rest; after it leaves, $($open.Count) frame(s) open past rest or shut$(if ($open) { ' (' + (($open | Select-Object -First 4 | ForEach-Object { "f$($_.I) $($_.Gap)" }) -join '; ') + ')' })"
    Assert "$arm.24 through a $StallMs ms stall the column follows the grid: its edge leaves the rail $lagMs ms after the grid's first move (need 0..$limit), and the gutter never opens past its rest $rest px + 2 after that ($($open.Count) of $($after.Count) frame(s))" ($null -ne $leave -and $lagMs -ge 0 -and $lagMs -lt $limit -and $after.Count -ge 3 -and $open.Count -eq 0)
    # .24d the literal claim: within 2 px of its rest width on every frame of
    # the glide, both ways - the crossfade's fade-in and its clipped edge
    # count against it (T2855's filing).
    $off = @($glide | Where-Object { $_.Gap -lt 0 -or [Math]::Abs($_.Gap - $rest) -gt 2 })
    $worst = 0; foreach ($m in $glide) { if ($m.Gap -ge 0) { $worst = [Math]::Max($worst, [Math]::Abs($m.Gap - $rest)) } }
    Assert "$arm.24d the gutter is within 2 px of its rest $rest px on every frame of the glide (off on $($off.Count) of $($glide.Count), worst $worst px$(if ($off) { '; first ' + (($off | Select-Object -First 3 | ForEach-Object { "f$($_.I) $($_.Gap)" }) -join ', ') }))" ($glide.Count -ge 3 -and $off.Count -eq 0)
    # .24b the card keeps moving: its longest still stretch, from its first
    # move to its landing, under a quarter of the stall.
    $prevX = $a; $lastT = $null; $gap = 0.0; $gapAt = ''; $moves = 0
    foreach ($m in $glide) {
        if ($m.L -lt 0 -or $m.L -eq $prevX) { continue }
        if ($null -ne $lastT -and ($m.T - $lastT) -gt $gap) { $gap = $m.T - $lastT; $gapAt = "f$($m.I)" }
        $lastT = $m.T; $prevX = $m.L; $moves++
    }
    Assert "$arm.24b through the stall the leading card keeps moving: longest still stretch $([Math]::Round($gap)) ms (ending $gapAt; need < $limit), $moves moves" ($moves -ge 2 -and $gap -lt $limit)

    $text = Read-Text $err
    $stalled = [regex]::Matches($text, 'stack glide debug stall ms=').Count
    Assert "$arm.24a the stall landed in the glide ($stalled)" ($stalled -ge 1)
    $decl = [regex]::Matches($text, 'pane sidebar column declared from=').Count
    Assert "$arm.25 the column was handed to the compositor ($decl declaration(s))" ($decl -ge 1)
    $fgPid = [uint32]0
    [void][GhWin]::GetWindowThreadProcessId([GhWin]::GetForegroundWindow(), [ref]$fgPid)
    Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
    if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    return
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'compglide')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

try {
    foreach ($arm in $Arms) {
        $comp = $arm -in 'on', 'tree', 'stall', 'unfold', 'live', 'strip', 'sidebar'
        $isTree = $arm -in 'tree', 'stall', 'unfold', 'live', 'strip', 'sidebar'
        $stalls = $arm -in 'stall', 'unfold', 'live', 'strip', 'sidebar'
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=$(if ($comp) { '1' } else { 'unset' }) PANE_TREE=$(if ($isTree) { '1' } else { 'unset' }), slide $SlideMs ms$(if ($stalls) { ", stall $StallMs ms$(if ($arm -eq 'unfold') { ' once the opening card is in' }), declare $(if ($NoDeclare) { 'off' } else { 'on' })" }))"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        if (Test-Path $dir) { Get-ChildItem $dir -File -Recurse | ForEach-Object { Remove-Item $_.FullName } }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        $env:GHOZTTY_STACK_SLIDE_MS = "$SlideMs"
        if ($comp) { $env:GHOZTTY_COMP_PRESENT = '1' } else { $env:GHOZTTY_COMP_PRESENT = '0' }  # T2514: off is the explicit opt-out now
        foreach ($k in 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE') {
            if ($isTree) { Set-Item "env:$k" '1' } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        }
        if ($NoGlideTree) { $env:GHOZTTY_GLIDE_TREE = '0' } else { Remove-Item env:GHOZTTY_GLIDE_TREE -ErrorAction SilentlyContinue }
        if ($stalls) { $env:GHOZTTY_DEBUG_GLIDE_STALL_MS = "$StallMs" } else { Remove-Item env:GHOZTTY_DEBUG_GLIDE_STALL_MS -ErrorAction SilentlyContinue }
        if ($arm -eq 'unfold') { $env:GHOZTTY_DEBUG_GLIDE_STALL_AT = 'unfold' } else { Remove-Item env:GHOZTTY_DEBUG_GLIDE_STALL_AT -ErrorAction SilentlyContinue }
        if ($arm -eq 'live') { $env:GHOZTTY_DEBUG_GLIDE_LIVE_FACE = '1' } else { Remove-Item env:GHOZTTY_DEBUG_GLIDE_LIVE_FACE -ErrorAction SilentlyContinue }
        if ($NoDeclare) { $env:GHOZTTY_GLIDE_DECLARE = '0' } else { Remove-Item env:GHOZTTY_GLIDE_DECLARE -ErrorAction SilentlyContinue }
        if ($NoFaceComp) { $env:GHOZTTY_FACE_COMP = '0' } else { Remove-Item env:GHOZTTY_FACE_COMP -ErrorAction SilentlyContinue }
        if ($GlideRegionCut) { $env:GHOZTTY_GLIDE_REGION_CUT = '1' } else { Remove-Item env:GHOZTTY_GLIDE_REGION_CUT -ErrorAction SilentlyContinue }
        if ($NoLandingTimer) { $env:GHOZTTY_GLIDE_LANDING_TIMER = '0' } else { Remove-Item env:GHOZTTY_GLIDE_LANDING_TIMER -ErrorAction SilentlyContinue }
        if ($NoBody) { $env:GHOZTTY_COMP_SHADOWS_NOBODY = '1' } else { Remove-Item env:GHOZTTY_COMP_SHADOWS_NOBODY -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        if ($NoColumnDeclare) { $env:GHOZTTY_SIDEBAR_COLUMN_DECLARE = '0' } else { Remove-Item env:GHOZTTY_SIDEBAR_COLUMN_DECLARE -ErrorAction SilentlyContinue }
        if ($arm -eq 'sidebar') { $env:GHOZTTY_SIDEBAR_COLUMN_MS = "$SlideMs" } else { Remove-Item env:GHOZTTY_SIDEBAR_COLUMN_MS -ErrorAction SilentlyContinue }
        if ($arm -eq 'strip') { Invoke-StripArm $arm $dir $err; continue }
        if ($arm -eq 'sidebar') { Invoke-SidebarArm $arm $dir $err; continue }
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#000000',
            '--palette=1=#ff0000', '--palette=2=#00ff00', '--palette=4=#0000ff', '--palette=5=#ff00ff',
            '--command=powershell.exe -NoLogo -NoProfile', "--title=t2513-$arm",
            "--macos-pane-glass=$(if ($Solid) { 'false' } else { 'true' })") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        $name = "gl$arm"
        & $Exe +new-window "--target=$name" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([GhWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        $scale = [Math]::Max(1, [GhWin]::GetDpiForWindow($hw)) / 96.0
        [void][GhWin]::Size($hw, [int](1500 * $scale), [int](700 * $scale))
        Start-Sleep -Milliseconds 1500
        $prev = $name
        for ($k = 1; $k -lt 4; $k++) {
            $flag = if ($k -eq 1) { '--target' } else { '--pane' }
            & $Exe +split "$flag=$prev" '--direction=right' "--name=$name-$k" 2>$null | Out-Null
            Start-Sleep -Milliseconds 1000
            $prev = "$name-$k"
        }
        $four = @(Wait-Shown $hw 4)
        # Every shell has had time to reach its prompt: paint the blocks.
        Start-Sleep -Milliseconds 3000
        Paint $name 'target' 0
        for ($k = 1; $k -lt 4; $k++) { Paint "$name-$k" 'target' $k }
        Start-Sleep -Milliseconds 2000
        Assert "$arm.2 four panes on show at 1500 DIP ($($four.Count))" ($four.Count -eq 4)
        if ($comp) {
            Assert "$arm.3 the panes present through the composition chain" (Wait-Log $err $onLine 15000)
            if ($isTree) { Assert "$arm.3t every pane went into the window tree (adopts=4)" (Wait-Log $err 'adopted into the window tree \(adopts=4\)' 15000) }
        } else {
            Assert "$arm.3 no pane touched the composition path" ((Read-Text $err) -notmatch [regex]::Escape($onLine))
        }
        [void][GhWin]::Size($hw, [int](760 * $scale), [int](700 * $scale))
        $shown = @(Wait-Shown $hw 2)
        Start-Sleep -Milliseconds ([Math]::Max(800, $SlideMs + 500))
        $all = @(Get-Panes $hw)
        "  panes: $(($all | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(tucked)' })" }) -join ' | ')"
        $tucked = @($all | Where-Object { -not $_.Visible })
        if ($shown.Count -ne 2 -or $tucked.Count -lt 1) { Assert "$arm.2b the 760 DIP row settled on two on show and some tucked" $false; continue }
        $p = $tucked[-1]

        $fdir = Join-Path $dir 'film'
        $filmErr = Join-Path $dir 'film.txt'
        $filmMs = $SlideMs + 1500
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$filmMs") `
            -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$arm.3a the film started" $ready
        Start-Sleep -Milliseconds 300
        $strip = [int][Math]::Floor(8 * $scale)
        [GhWin]::Click($hw, $p.Left + [int]($strip / 2), $p.Top + [int](($p.Bottom - $p.Top) / 2))
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$arm.3b the film finished" ($filmOut -match '^FILM ok')
        $after = @(Get-Panes $hw)
        $me = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })
        Assert "$arm.3c the clicked pane came on show" ($me.Count -eq 1 -and $me[0].Visible)

        Score-Film $arm $fdir

        # T2571: what the glide moved, from the pass that landed it.
        $moves = $null
        for ($t = 0; $t -lt 25 -and -not $moves; $t++) {
            $m = [regex]::Matches((Read-Text $err), 'stack glide child moves=(\d+) visual_moves=(\d+) panes=(\d+)')
            if ($m.Count -gt 0) { $moves = $m[$m.Count - 1] } else { Start-Sleep -Milliseconds 200 }
        }
        if (-not $moves) {
            Assert "$arm.9 the glide reported what it moved" $false
        } else {
            $cm = [int]$moves.Groups[1].Value; $vm = [int]$moves.Groups[2].Value; $np = [int]$moves.Groups[3].Value
            "  glide moved: child windows $cm, visuals $vm, panes $np"
            if ($isTree) {
                Assert "$arm.9 the glide moved visuals, not windows: $cm child moves for $np panes (at most $(2 * $np)), $vm visual moves" ($cm -le 2 * $np -and $vm -gt $np)
            } else {
                Assert "$arm.9 control: the window path moves child windows and no visual ($cm child, $vm visual)" ($cm -gt 2 * $np -and $vm -eq 0)
            }
        }

        # T2826: a gliding tree pane's window keeps its region while the desk
        # is on the compositor; the per-frame SetWindowRgn is gone. At most one
        # cut per pane per glide (a desk that fell back to GDI mid-glide).
        if ($isTree -and $moves) {
            $text = Read-Text $err
            $cuts = [regex]::Matches($text, 'pane glide region cut').Count
            $held = [regex]::Matches($text, 'pane glide region held').Count
            "  glide region: $cuts cut(s), $held held, $np panes"
            Assert "$arm.20 a gliding pane's window region is not re-cut per frame ($cuts cuts for $np panes, $held held)" ($cuts -le $np -and $held -ge 1)
        }

        # T2828: the glide's ticks that only stepped its model (everything on
        # the move declared) against those that ran the layout pass.
        if ($isTree -and $moves) {
            $lt = [regex]::Matches((Read-Text $err), 'stack glide landing timer laid=(\d+) quiet=(\d+)')
            if ($lt.Count -eq 0) {
                Assert "$arm.21 the glide reported its ticks" $false
            } else {
                $l = $lt[$lt.Count - 1]
                $laid = [int]$l.Groups[1].Value; $quiet = [int]$l.Groups[2].Value
                "  glide ticks: $laid laid out, $quiet quiet"
                if ($NoDeclare) {
                    Assert "$arm.21 control: a stepped glide lays out on every tick ($laid laid, $quiet quiet)" ($quiet -eq 0 -and $laid -ge 1)
                } else {
                    Assert "$arm.21 most of the glide's ticks skipped the layout pass ($quiet quiet of $($laid + $quiet))" ($quiet -gt $laid)
                }
            }
        }

        # T2572: the panes' paths went to the compositor (none under -NoDeclare).
        if ($arm -eq 'stall') {
            $dec = [regex]::Matches((Read-Text $err), 'pane visual glide declared').Count
            Assert "$arm.11 the glide was handed to the compositor ($dec pane path(s) declared)" ($dec -ge 1)
            # T2741: each card's shadow is a visual that rides its pane's
            # declared path in the same commit, so it travels through the
            # stall with the card instead of staying baked where it started.
            $rode = [regex]::Matches((Read-Text $err), 'pane visual glide declared [^\r\n]*shadow=true').Count
            Assert "$arm.12 the cards' shadows rode the declared paths ($rode of $dec)" ($dec -ge 1 -and $rode -eq $dec)
            # T2778: the folding card's face - its card clip, carried frame
            # and fade - went to the compositor whole too.
            $faces = [regex]::Matches((Read-Text $err), 'strip face glide declared').Count
            Assert "$arm.14 the folding card's face was handed to the compositor ($faces face path(s) declared)" ($faces -ge 1)
            # T2793: the desk's recomposes over the glide - all of them, and
            # those where a card on the desk had moved.
            # With -Solid the cards on show ride whole, so no paint of the
            # glide recomposed the desk because a full-share card moved: the
            # folding and opening cards (share below 1, trading their shadow
            # for the strip's) are what is left of its desk work.
            $dm = [regex]::Matches((Read-Text $err), 'stack glide desk composed=(\d+) card_composed=(\d+) area_permille=(\d+) full_card_moves=(\d+) wholes=(\d+)')
            if ($dm.Count -gt 0) {
                $d = $dm[$dm.Count - 1]
                $full = [int]$d.Groups[4].Value; $wholes = [int]$d.Groups[5].Value
                "  glide desk: composed $($d.Groups[1].Value), card_composed $($d.Groups[2].Value), area_permille $($d.Groups[3].Value), full_card_moves $full, wholes $wholes"
                if ($Solid) {
                    Assert "$arm.17 the cards on show rode whole and the desk never recomposed for one moving ($full full-share card moves, $wholes riding whole at the landing)" ($full -eq 0 -and $wholes -ge 1)
                }
            } else { Assert "$arm.17 the glide reported its desk work" $false }
        }
        # T2822: the folding card's live pane and its face went to the
        # compositor together - the pane's path and the face, declared live.
        if ($arm -eq 'live') {
            $text = Read-Text $err
            $dec = [regex]::Matches($text, 'pane visual glide declared').Count
            Assert "$arm.11 the glide was handed to the compositor ($dec pane path(s) declared)" ($dec -ge 1)
            $lf = [regex]::Matches($text, 'strip face glide declared [^\r\n]*content=false live=true').Count
            $carried = [regex]::Matches($text, 'strip face glide declared [^\r\n]*opening=false content=true').Count
            Assert "$arm.14 the folding card's face was handed to the compositor live, over its pane ($lf live declaration(s), $carried carrying a frame)" ($lf -ge 1 -and $carried -eq 0)
        }
        # T2779: the opening card's face went to the compositor with the frame
        # it lands with, and the stall it was scored through happened.
        if ($arm -eq 'unfold') {
            $text = Read-Text $err
            $stalled = [regex]::Matches($text, 'stack glide debug stall ms=').Count
            Assert "$arm.16a the stall landed once the opening card was in ($stalled)" ($stalled -eq 1)
            $opened = [regex]::Matches($text, 'strip face glide declared [^\r\n]*opening=true content=true').Count
            Assert "$arm.16 the opening card's face was handed to the compositor with its frame ($opened declaration(s))" ($opened -ge 1)
        }

        $fgPid = [uint32]0
        [void][GhWin]::GetWindowThreadProcessId([GhWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
        if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

"  films kept in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
