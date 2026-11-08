# FrameLabDriver (T2395) - the T2373 frame lab's LIVE driver: the -Driver
# hashtable Invoke-FrameLabCell (FrameLabCatalogue.ps1) runs one matrix cell
# through, and the run that turns a set of cells into a results JSON and an
# HTML report.
#
# Every other frame-lab file is pure or proves itself against fakes. This one
# launches the debug zig-out build on the user's real screen, moves the user's
# real pointer and photographs what DWM composes - frame-lab.ps1's declared
# input-desktop exception - so everything it does is gated on nobody being at
# the box (lib\UserPresence.ps1), checked again before every cell.
#
# PER CELL (New-FrameLabLiveDriver):
#
#   Launch   an isolated profile (its own IPC pipe, its own LOCALAPPDATA with
#            the sidebar's new-window default seeded), a config for the theme,
#            lib\lab-card.ps1 in every pane: the first from the command line,
#            the rest by +split -e, then +rearrange to an even grid (2x2, 3x3).
#            The window is placed topmost and never activated, and its geometry
#            is read back in physical pixels: the DWM frame, the work area, a
#            caption point, every pane's content rect (row-major, so pane n
#            runs card n), the divider the gesture grabs, the sidebar edge.
#   Scene    a one-colour backdrop directly under the window over the
#            gesture's capture rect (FrameLabLiveScene.ps1), a still frame, and
#            the cell's scene calibrated on it. Its scorer goes to the
#            measurement capture.
#   Play     the gesture at 1 kHz through SendInput, gated on presence.
#   Score    Get-FrameLabSceneScore, plus the PNG of every failing frame for
#            the report's filmstrip.
#   Close    the backdrop and the app (by pid - only the process it started).
#
# DPI. The matrix's DPI axis is a monitor setting. The lab NEVER changes the
# user's display scaling: a cell at a DPI the monitor is not at is Blocked with
# the reason, and the monitor's own DPI is always a matrix value (on a box at
# 125% the 100/150/200 axis would otherwise block every cell).
#
# PRESENCE AND THE LAB'S OWN INPUT. GetLastInputInfo counts injected input, so
# after one cell plays, the next cell's presence check would read the lab's own
# pointer as a person. Get-FrameLabPresence discounts input that is no later
# than the lab's last send (Resolve-FrameLabOwnInput), and only that: input
# after it is a person, and the cell is skipped.
#
# Acceptance: the pure parts in frame-lab.ps1 section A, the live run in its
# section D.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Set-StrictMode -Off

foreach ($lib in 'ChromeGeometry', 'UserPresence', 'OccludedDisplay', 'FrameLabCatalogue', 'FrameLabLiveScene', 'FrameLabReport', 'FrameCapture') {
    . (Join-Path $PSScriptRoot "$lib.ps1")
}

$script:FrameLabDriverSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Geometry reads and placement for the lab's window, always in physical
// pixels: every call runs under a per-monitor-aware-v2 thread context.
public static class GflWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public uint cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int n);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);

    static IntPtr Aware() { return SetThreadDpiAwarenessContext(new IntPtr(-4)); }
    static void Restore(IntPtr old) { if (old != IntPtr.Zero) SetThreadDpiAwarenessContext(old); }
    static string Cls(IntPtr h) { var b = new StringBuilder(256); GetClassNameW(h, b, 256); return b.ToString(); }

    // The first visible top-level window of pid with class cls.
    public static IntPtr FindTop(int pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The window's visible frame (DWM extended frame bounds): x, y, w, h.
    public static int[] Frame(IntPtr h) {
        var old = Aware();
        try {
            RECT r;
            if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
            return new int[] { r.L, r.T, r.R - r.L, r.B - r.T };
        } finally { Restore(old); }
    }

    // The work area of the monitor the window (or, for Zero, the primary) is on.
    public static int[] WorkArea(IntPtr h) {
        var old = Aware();
        try {
            IntPtr m = h == IntPtr.Zero ? MonitorFromPoint(new POINT(), 1) : MonitorFromWindow(h, 2);
            var mi = new MONITORINFO(); mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
            GetMonitorInfo(m, ref mi);
            return new int[] { mi.rcWork.L, mi.rcWork.T, mi.rcWork.R - mi.rcWork.L, mi.rcWork.B - mi.rcWork.T };
        } finally { Restore(old); }
    }

    // The primary monitor's effective DPI (96 = 100%).
    public static int PrimaryDpi() {
        uint x, y;
        IntPtr m = MonitorFromPoint(new POINT(), 1);
        return GetDpiForMonitor(m, 0, out x, out y) == 0 ? (int)x : 0;
    }

    public static int WindowDpi(IntPtr h) { return (int)GetDpiForWindow(h); }

    // Placed at x,y,w,h (physical), topmost, never activated.
    public static bool Place(IntPtr h, int x, int y, int w, int hh) {
        var old = Aware();
        try { return SetWindowPos(h, new IntPtr(-1), x, y, w, hh, 0x0010 | 0x0040); }
        finally { Restore(old); }
    }

    // T2398: maximize (SW_MAXIMIZE) or restore (SW_RESTORE) the window, for
    // a maximizing cell's maximized still frame; and whether it is maximized.
    public static bool Maximize(IntPtr h, bool on) { ShowWindow(h, on ? 3 : 9); return IsZoomed(h) == on; }
    public static bool Zoomed(IntPtr h) { return IsZoomed(h); }

    // T2784: who has the keyboard (a key-chord trigger goes there).
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    public static IntPtr Foreground() { return GetForegroundWindow(); }

    // Every VISIBLE descendant of class cls: "hwnd:x,y,w,h", its client rect on
    // the screen.
    public static string[] Children(IntPtr parent, string cls) {
        var list = new List<string>();
        var old = Aware();
        try {
            EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
                if (IsWindowVisible(h) && Cls(h) == cls) {
                    RECT r; GetClientRect(h, out r);
                    var p = new POINT(); ClientToScreen(h, ref p);
                    list.Add(string.Format("{0}:{1},{2},{3},{4}", h.ToInt64(), p.X, p.Y, r.R - r.L, r.B - r.T));
                }
                return true;
            }, IntPtr.Zero);
        } finally { Restore(old); }
        return list.ToArray();
    }
}
'@

function Import-FrameLabDriver {
    if ('GflWin' -as [type]) { return }
    Add-Type -TypeDefinition $script:FrameLabDriverSource
}

# ---- pure: what a cell's launch is ------------------------------------------

<# The config lines for a theme: flat, elevated (solid cards) or glass. #>
function Get-FrameLabThemeConfig([string]$Theme) {
    switch ($Theme) {
        'flat'     { return , @('macos-pane-style = flat') }
        'elevated' { return , @('macos-pane-style = elevated', 'macos-pane-glass = false') }
        'glass'    { return , @('macos-pane-style = elevated', 'macos-pane-glass = true') }
    }
    throw "Get-FrameLabThemeConfig: unknown theme '$Theme'"
}

<#
The sidebar's new-window default, as the debug build reads it from
%LOCALAPPDATA%\ghoztty\pane_sidebar-debug: "<expanded> <hidden> <width DIP>
<all windows>". The scope is pinned to "this window" (T2564 made all windows
the launch default), so a cell's frames do not change with that default.
#>
function Get-FrameLabSidebarPref([string]$Sidebar) {
    switch ($Sidebar) {
        'expanded' { return '1 0 240 0' }
        'rail'     { return '0 0 240 0' }
        'hidden'   { return '0 1 240 0' }
    }
    throw "Get-FrameLabSidebarPref: unknown sidebar '$Sidebar'"
}

<#
How -Panes (1, 4 or 9: a k x k grid) is built. Pane n (row-major, 1-based)
is named p<n> and runs card n. p1 is the window's first pane (addressed by its
pane id, which the launcher substitutes for 'p1'). Columns are split off p1
first, then each column's rows; the splits leave the sizes uneven, so the
plan ends in a +rearrange layout that makes every column and row equal.
Returns K, Splits (@{ From; Direction; Name; Index }) and Layout ($null for 1).
#>
function Get-FrameLabGridPlan([int]$Panes) {
    $k = [int][math]::Round([math]::Sqrt($Panes))
    if ($k * $k -ne $Panes -or $k -lt 1) { throw "Get-FrameLabGridPlan: -Panes must be a square (1, 4, 9), got $Panes" }
    $name = { param($r, $c) "p$($r * $k + $c + 1)" }
    $splits = @()
    for ($c = 1; $c -lt $k; $c++) {
        $splits += [pscustomobject]@{ From = (& $name 0 ($c - 1)); Direction = 'right'; Name = (& $name 0 $c); Index = $c + 1 }
    }
    for ($c = 0; $c -lt $k; $c++) {
        for ($r = 1; $r -lt $k; $r++) {
            $splits += [pscustomobject]@{ From = (& $name ($r - 1) $c); Direction = 'down'; Name = (& $name $r $c); Index = $r * $k + $c + 1 }
        }
    }
    $layout = $null
    if ($k -gt 1) {
        # Equal shares: the first of n children takes 100/n percent.
        $chain = $null
        $chain = {
            param([object[]]$Nodes, [string]$Dir)
            if ($Nodes.Count -eq 1) { return $Nodes[0] }
            $rest = & $chain @($Nodes | Select-Object -Skip 1) $Dir
            return [ordered]@{ direction = $Dir; ratio = [math]::Round(100.0 / $Nodes.Count, 4); left = $Nodes[0]; right = $rest }
        }
        $cols = @()
        for ($c = 0; $c -lt $k; $c++) {
            $rows = @()
            for ($r = 0; $r -lt $k; $r++) { $rows += , ([ordered]@{ pane = (& $name $r $c) }) }
            $cols += , (& $chain $rows 'vertical')
        }
        $layout = (& $chain $cols 'horizontal') | ConvertTo-Json -Depth 20 -Compress
    }
    [pscustomobject]@{ K = $k; Splits = $splits; Layout = $layout }
}

<#
The matrix as this box can run it: the monitor's own DPI is always a DPI
value, and every cell at another DPI is Blocked (never a display-scaling
change). -MonitorDpi is a percentage (125 for 120 dpi).
#>
function Get-FrameLabLiveMatrix {
    param(
        [Parameter(Mandatory = $true)][int]$MonitorDpi,
        [string[]]$Interaction,
        [int[]]$Panes,
        [string[]]$Theme,
        [int[]]$Dpi,
        [string[]]$Sidebar,
        [int[]]$StallMs
    )
    $a = @{}
    # Bound, not truthy: -StallMs 0 is a value.
    foreach ($k in 'Interaction', 'Panes', 'Theme', 'Sidebar', 'StallMs') {
        if ($PSBoundParameters.ContainsKey($k)) { $a[$k] = Get-Variable -Name $k -ValueOnly }
    }
    $d = @(if ($PSBoundParameters.ContainsKey('Dpi')) { $Dpi } else { $script:FrameLabMatrixAxes.Dpi })
    if ($MonitorDpi -notin $d) { $d += $MonitorDpi }
    $a.Dpi = $d
    foreach ($c in @(Get-FrameLabMatrix @a)) {
        $why = @($c.Blocked)
        if ($c.Dpi -ne $MonitorDpi) { $why += "the monitor is at $MonitorDpi% and the lab never changes the display scaling" }
        if ($script:FrameLabLiveTriggerGaps.ContainsKey($c.Interaction)) { $why += $script:FrameLabLiveTriggerGaps[$c.Interaction] }
        if ($c.Interaction -in $script:FrameLabAddsPane -and (Get-FrameLabSpareCard $c.Panes) -eq 0) {
            $why += "the pane $($c.Interaction) adds needs a card no start pane runs, and $($c.Panes) panes use the palette's nine"
        }
        $c.Blocked = (@($why | Where-Object { $_ }) -join '; ')
        $c
    }
}

<#
One cell per pointer interaction, at the monitor's DPI: the smallest layout
each applies to (a divider needs a split: 4 panes), flat, sidebar expanded,
no stall - plus one cell at a DPI the monitor is not at, which must read
Blocked. What "one live verdict per pointer interaction" runs.
#>
function Get-FrameLabSmokeCells([int]$MonitorDpi) {
    $cells = @()
    foreach ($i in @(Get-FrameLabInteractions | Where-Object { $_.Kind -eq 'pointer' })) {
        $p = $(if ($i.Needs -contains 'split') { 4 } else { 1 })
        $cells += @(Get-FrameLabLiveMatrix -MonitorDpi $MonitorDpi -Interaction $i.Name -Panes $p -Theme flat -Sidebar expanded -StallMs 0 -Dpi $MonitorDpi)[0]
    }
    $other = @(@(100, 150, 200) | Where-Object { $_ -ne $MonitorDpi })[0]
    $cells += @(Get-FrameLabLiveMatrix -MonitorDpi $MonitorDpi -Interaction 'frame-right' -Panes 1 -Theme flat -Sidebar expanded -StallMs 0 -Dpi $other |
            Where-Object { $_.Dpi -eq $other })[0]
    # Unrolled: callers wrap the call in @(), which would nest a `, $cells`.
    return $cells
}

<#
The panes of a launched window in card order. -Rects are content rects
(@{ X; Y; W; H }) in any order; they are sorted into rows (a row is every rect
whose top is within -RowTol of the row's first) and each row left to right,
so on an even grid rect n is pane n and runs card n.
#>
function Get-FrameLabPaneOrder {
    param([Parameter(Mandatory = $true)][object[]]$Rects, [int]$RowTol = 8)
    $left = @($Rects | Sort-Object { [int]$_.Y }, { [int]$_.X })
    $out = @(); $n = 0
    while ($left.Count) {
        $top = [int]$left[0].Y
        $row = @($left | Where-Object { [math]::Abs([int]$_.Y - $top) -le $RowTol } | Sort-Object { [int]$_.X })
        $left = @($left | Where-Object { [math]::Abs([int]$_.Y - $top) -gt $RowTol })
        foreach ($r in $row) {
            $n++
            # Hwnd (T2784): what ties a pane to its card once the pane set
            # changes and position no longer says which card is where.
            $out += [pscustomobject]@{ Name = "p$n"; Index = $n; X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.W; H = [int]$r.H; Hwnd = [long]$r.Hwnd }
        }
    }
    return , $out
}

<#
The panes of one of a pane-set cell's OTHER states (T2784: hero, the second
tab, the split), each named by the card it runs. -Rects carry Hwnd; -Known maps
the start's pane hwnds to their card index; a pane the start did not have is
the one the trigger added and runs card -NewIndex (0 = the cell adds none).
Returns Panes (Name p<card>, Index = card) and Problems: a pane nobody can
name, or more than one new pane, would calibrate against the wrong card.
#>
function Get-FrameLabStatePanes {
    param([Parameter(Mandatory = $true)][object[]]$Rects, [Parameter(Mandatory = $true)][hashtable]$Known, [int]$NewIndex = 0)
    $panes = @(); $problems = @(); $new = 0
    foreach ($r in $Rects) {
        $h = [long]$r.Hwnd
        if ($Known.ContainsKey($h)) { $i = [int]$Known[$h] }
        elseif ($NewIndex -gt 0 -and $new -eq 0) { $i = $NewIndex; $new++ }
        else {
            $problems += $(if ($NewIndex -gt 0) { "more than one pane appeared (hwnd $h too); only one runs card $NewIndex" } else { "a pane appeared (hwnd $h) the start did not have, and this cell adds none" })
            continue
        }
        $panes += [pscustomobject]@{ Name = "p$i"; Index = $i; X = [int]$r.X; Y = [int]$r.Y; W = [int]$r.W; H = [int]$r.H; Hwnd = $h }
    }
    if (-not $panes.Count) { $problems += 'no pane on show in this state' }
    [pscustomobject]@{ Panes = @($panes | Sort-Object Index); Problems = $problems }
}

<#
The card a pane the trigger ADDS runs (T2784: split-close's new pane, the
tab-switch cell's second tab): the first index the start leaves free, 0 when
a 9-pane start has used the palette's nine. Pure.
#>
function Get-FrameLabSpareCard([int]$Panes) {
    if ($Panes -ge 9) { return 0 }
    return $Panes + 1
}

<# An argv as one command line for the config's `command` (quoted where it has spaces). Pure. #>
function Format-FrameLabCommandLine([string[]]$Argv) {
    (@($Argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
}

<#
Trigger interactions the live driver cannot fire yet, and why: their plans
need geometry the launcher does not measure. Their cells are Blocked naming
the task, never run into a driver error.
#>
$script:FrameLabLiveTriggerGaps = @{
    'maximize-button' = 'the launcher does not measure Geometry.MaximizeButton yet (T2823)'
    'blade-glide'     = 'the launcher does not measure the sidebar toggle and its other-mode edge yet (T2823)'
}

# The pane-set triggers that ADD a pane, so need a spare card (T2784).
$script:FrameLabAddsPane = @('split-close', 'tab-switch')
# The triggers that send key chords, so need the lab window in the foreground.
$script:FrameLabKeyTriggers = @('hero', 'tab-switch')

<# One step of a trigger plan as a plan of its own, fired at once (a state still's round trip). Pure. #>
function Get-FrameLabTriggerStep($Plan, [int]$Index) {
    $s = $Plan.Steps[$Index]
    $one = [pscustomobject]@{ Action = $s.Action; AtMs = 0.0; Label = $s.Label; X = $s.X; Y = $s.Y; Chord = $s.Chord; Args = $s.Args }
    [pscustomobject]@{ Name = $Plan.Name; Steps = @($one); Axis = 'none'; Track = ''; CaptureRect = $Plan.CaptureRect; Glides = @(); DurationMs = 0 }
}

<#
The geometry a gesture and a scene need, from what the launcher read back
(all physical px): -Window @{X;Y;W;H} (the DWM frame), -Monitor (work area),
-Panes (Get-FrameLabPaneOrder's), -Sidebar @{X;Y;W;H} or $null, -Scale
(dpi / 96), -Mode the sidebar's (expanded/rail/hidden).

  Caption   a point in the caption band clear of the tabs (the right third,
            short of the three caption buttons)
  Divider   between pane 1 and its right-hand neighbour, when there is one
  Sidebar   its draggable edge: the gutter's middle when there is a gutter
            between it and the first pane, else just inside its trailing
            edge (2 px expanded, 6 DIP on the rail - the card's margin)
#>
function New-FrameLabLiveGeometry {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)]$Monitor,
        [Parameter(Mandatory = $true)][object[]]$Panes,
        $Sidebar = $null,
        [double]$Scale = 1.0,
        [string]$Mode = 'expanded'
    )
    $w = [pscustomobject]@{ X = [int]$Window.X; Y = [int]$Window.Y; W = [int]$Window.W; H = [int]$Window.H }
    $geo = [ordered]@{
        Window   = $w
        Monitor  = [pscustomobject]@{ X = [int]$Monitor.X; Y = [int]$Monitor.Y; W = [int]$Monitor.W; H = [int]$Monitor.H }
        Caption  = $w.Y + (Get-TestChromeDip 10 $Scale)
        CaptionX = $w.X + $w.W - (Get-TestChromeDip (3 * 46 + 60) $Scale)
        Panes    = @($Panes)
        Divider  = $null
        Sidebar  = $null
    }
    $p1 = @($Panes | Where-Object { $_.Index -eq 1 })[0]
    if ($p1) {
        $right = @($Panes | Where-Object { $_.X -gt $p1.X + $p1.W - 2 -and $_.Y -lt $p1.Y + $p1.H -and $_.Y + $_.H -gt $p1.Y } | Sort-Object X)
        if ($right.Count) {
            $geo.Divider = [pscustomobject]@{ X = [int](($p1.X + $p1.W + $right[0].X) / 2); Y0 = $p1.Y; Y1 = $p1.Y + $p1.H }
        }
    }
    if ($Sidebar -and $Mode -ne 'hidden' -and $Panes.Count) {
        $sr = [int]$Sidebar.X + [int]$Sidebar.W
        $firstX = ($Panes | Measure-Object -Property X -Minimum).Minimum
        $gap = $firstX - $sr
        $edge = $(if ($gap -ge 4) { $sr + [int]($gap / 2) } elseif ($Mode -eq 'rail') { $sr - (Get-TestChromeDip 6 $Scale) } else { $sr - 2 })
        $geo.Sidebar = [pscustomobject]@{ EdgeX = $edge; Y0 = [int]$Sidebar.Y; Y1 = [int]$Sidebar.Y + [int]$Sidebar.H }
    }
    return [pscustomobject]$geo
}

<#
Is the session's last input the lab's own? -LastInputTick is GetLastInputInfo's
tick, -OwnTick the tick read right after the lab's last send (0 = the lab has
sent nothing). Own when the last input is no later than OwnTick + SlackMs
(unsigned, so the 49.7-day wrap reads right). Pure.
#>
function Resolve-FrameLabOwnInput([uint32]$LastInputTick, [uint32]$OwnTick, [int]$SlackMs = 250) {
    if ($OwnTick -eq 0) { return $false }
    $after = [uint32](([int64]$LastInputTick - [int64]$OwnTick + 4294967296) % 4294967296)
    # A difference past half the range is "before", not "4 billion ms after".
    return ($after -le $SlackMs -or $after -ge 2147483648)
}

$script:FrameLabOwnTick = [uint32]0
$script:FrameLabIdleAtStart = -1.0
$script:FrameLabStartTick = [uint32]0

# Call right after the lab's own input ends (a play, a fire).
function Set-FrameLabOwnInput {
    Import-FrameLabTrigger
    $script:FrameLabOwnTick = [GltKeys]::LastInputTick()
}

<#
Presence for the lab: Get-UserPresence, except that input the lab itself sent
is not a person. When the only signal is recent input and that input is the
lab's own, the idle time is the one measured when the lab started plus the
time since - which is exactly how long ago a person last touched the box.
#>
function Get-FrameLabPresence {
    $p = Get-UserPresence
    if (-not $p.Present -or $p.Forced) { return $p }
    Import-FrameLabTrigger
    $last = [GltKeys]::LastInputTick()
    if (-not (Resolve-FrameLabOwnInput $last $script:FrameLabOwnTick)) { return $p }
    if ($script:FrameLabIdleAtStart -lt 0) { return $p }
    $now = [uint32]([int64][Environment]::TickCount -band 0xFFFFFFFFL)
    $elapsed = [double](([int64]$now - [int64]$script:FrameLabStartTick + 4294967296) % 4294967296) / 1000.0
    $r = Get-UserPresence -IdleSecondsOverride ($script:FrameLabIdleAtStart + $elapsed)
    [pscustomobject]@{ Present = $r.Present; Reason = "$($r.Reason) (the last input is the lab's own)"; Forced = $false }
}

# Record the start of a live lab run: the idle time a person left it at.
function Start-FrameLabPresenceClock {
    $idleMs = [GhozttyUserPresence]::IdleMs()
    $script:FrameLabIdleAtStart = $(if ($idleMs -ge 0) { $idleMs / 1000.0 } else { -1 })
    $script:FrameLabStartTick = [uint32]([int64][Environment]::TickCount -band 0xFFFFFFFFL)
}

# ---- live: the driver hashtable ---------------------------------------------

# A window's size per pane count, in DIP: room for every pane's card and, at
# nine, no pane near the width where the grid would fold it into a strip.
$script:FrameLabWindowDip = @{ 1 = @(900, 600); 4 = @(1200, 800); 9 = @(1500, 1000) }

function Invoke-FrameLabCli {
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return $out.Trim()
}

# The top-level window's first pane id and target name, from +list --json.
function Get-FrameLabFirstPaneId([string]$Exe, [IntPtr]$Top) {
    $raw = Get-GhozttyListRaw -Exe $Exe
    $j = try { $raw | ConvertFrom-Json } catch { $null }
    if ($null -eq $j -or -not $j.success) { return $null }
    foreach ($w in @($j.data.windows | ForEach-Object { $_ })) {
        if ([string]$w.id -ne [string]$Top.ToInt64()) { continue }
        $n = @($w.tabs | ForEach-Object { $_ })[0].splits
        while ($n -and $n.type -ne 'leaf') { $n = $n.left }
        if ($n) { return [pscustomobject]@{ PaneId = [string]$n.terminal.id; Target = [string]$w.target } }
    }
    return $null
}

# A GfcFrame kept by a capture, as the scorer's FsFrame (pixels shared).
function ConvertTo-FrameLabFsFrame($Kept) {
    $f = New-Object FsFrame 0, 0
    $f.W = $Kept.W; $f.H = $Kept.H; $f.Px = $Kept.Px
    return $f
}

function ConvertFrom-FrameLabChildRect([string]$Row) {
    $hw, $r = $Row -split ':'
    $c = $r -split ','
    [pscustomobject]@{ X = [int]$c[0]; Y = [int]$c[1]; W = [int]$c[2]; H = [int]$c[3]; Hwnd = [long]$hw }
}

# A pane's command: lib\lab-card.ps1 drawing card -Index, reporting to -Out.
function Get-FrameLabCardArgv([int]$Index, [string]$Out) {
    $a = @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:FrameLabLive.Card, '-Index', [string]$Index, '-Out', $Out)
    if ($script:FrameLabLive.Busy) { $a += '-Busy' }
    return , $a
}

# Wait until every card in -Outs has drawn and none has changed for SettleMs.
# Returns the last reading ('<none>' marks a card that never drew).
function Wait-FrameLabCardsQuiet([string[]]$Outs, [int]$SettleMs, [int]$TimeoutS = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    $quietSince = Get-Date; $last = ''
    do {
        Start-Sleep -Milliseconds 200
        $now = (@($Outs | ForEach-Object { if (Test-Path $_) { [string](Get-Content $_ -Raw -ErrorAction SilentlyContinue) } else { '<none>' } }) -join '|')
        if ($now -ne $last -or $now -match '<none>') { $last = $now; $quietSince = Get-Date }
    } while (((Get-Date) - $quietSince).TotalMilliseconds -lt $SettleMs -and (Get-Date) -lt $deadline)
    return $last
}

# The visible panes of the lab window, each with its hwnd (physical px).
function Get-FrameLabPaneRects([IntPtr]$Top) {
    , @([GflWin]::Children($Top, 'GhozttyTerminal') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ })
}

<#
Fire a trigger plan live (T2784): presence-gated (the lab's own earlier input
is not a person), IPC through the debug build. Input the lab sent is recorded
as its own, so the next presence check does not read it as somebody.
#>
function Invoke-FrameLabLiveTrigger($Plan) {
    $r = Invoke-FrameLabTrigger -Plan $Plan -Presence (Get-FrameLabPresence) -Cli $script:FrameLabLive.Exe
    if (-not $r.Skipped -and @($r.Stamps | Where-Object { $_.Action -ne 'ipc' }).Count) { Set-FrameLabOwnInput }
    return $r
}

<#
Bring the lab window to the foreground for a key-chord cell: one click on the
caption point (clear of the tabs and the buttons). The window is placed
never-activated, and a chord goes to whatever has the keyboard. Returns '' or
why it could not.
#>
function Enter-FrameLabForeground($Launched) {
    $g = $Launched.Geometry
    $click = [pscustomobject]@{ Action = 'click'; AtMs = 0.0; Label = 'activate'; X = [int]$g.CaptionX; Y = [int]$g.Caption; Chord = ''; Args = @() }
    $r = Invoke-FrameLabLiveTrigger ([pscustomobject]@{ Name = 'activate'; Steps = @($click); Axis = 'none'; Track = ''; CaptureRect = $g.Window; Glides = @(); DurationMs = 0 })
    if ($r.Skipped) { return "activate: $($r.SkipReason)" }
    if ($r.Aborted) { return "activate: $($r.AbortReason)" }
    Start-Sleep -Milliseconds 300
    if ([GflWin]::Foreground() -ne $Launched.Top) { return 'the lab window did not take the foreground after a caption click, so a key chord would go elsewhere' }
    return ''
}

# The window's geometry as measured now (after a tab, a hero, a split).
function Measure-FrameLabLiveGeometry($Launched, [object[]]$Panes) {
    $top = $Launched.Top
    $fr = [GflWin]::Frame($top)
    $wa = [GflWin]::WorkArea($top)
    $sb = @([GflWin]::Children($top, 'GhozttyPaneSidebar') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ })[0]
    $g = New-FrameLabLiveGeometry -Window @{ X = $fr[0]; Y = $fr[1]; W = $fr[2]; H = $fr[3] } `
        -Monitor @{ X = $wa[0]; Y = $wa[1]; W = $wa[2]; H = $wa[3] } -Panes $Panes -Sidebar $sb -Scale $Launched.Scale -Mode $Launched.Mode
    if ($Launched.Target) { $g | Add-Member -Force -NotePropertyName Target -NotePropertyValue $Launched.Target }
    return $g
}

<#
The live -Driver for Invoke-FrameLabCell (this file's header). -Exe is the
debug zig-out build, -RunDir where every cell's profile, PNGs and still frame
go. The caller has already isolated the IPC endpoint (Set-GhozttyTestIsolation)
and checked nobody is present.
#>
function New-FrameLabLiveDriver {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$RunDir,
        [switch]$Busy,
        [int]$SettleMs = 1500
    )
    Import-FrameLabDriver
    Import-FrameCapture
    Import-FrameLabInput
    $script:FrameLabLive = @{ N = 0; Current = $null; Exe = $Exe; RunDir = $RunDir; Card = (Join-Path $PSScriptRoot 'lab-card.ps1'); Busy = [bool]$Busy; SettleMs = $SettleMs; CellDir = $null }

    $launch = {
        param($Cell)
        $script:FrameLabLive.N++
        $dir = Join-Path $script:FrameLabLive.RunDir ('cell{0:D3}' -f $script:FrameLabLive.N)
        $script:FrameLabLive.CellDir = $dir
        $prof = Join-Path $dir 'profile'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $prof 'ghoztty')
        [IO.File]::WriteAllText((Join-Path $prof 'ghoztty\pane_sidebar-debug'), (Get-FrameLabSidebarPref $Cell.Sidebar))
        $conf = Join-Path $dir 'config'
        $lines = (Get-FrameLabThemeConfig $Cell.Theme) + @('confirm-close-surface = false', 'undo-timeout = 0')
        $outs = @(1..$Cell.Panes | ForEach-Object { Join-Path $dir "card$_.txt" })
        # T2784: a pane the trigger adds (split-close's split, tab-switch's
        # second tab) runs the config's `command` - every surface after the
        # first one - so it draws the spare card and its state can calibrate.
        $spare = 0; $spareOut = ''
        if ($Cell.Interaction -in $script:FrameLabAddsPane) {
            $spare = Get-FrameLabSpareCard $Cell.Panes
            $spareOut = Join-Path $dir "card$spare.txt"
            if ($spare -gt 0) { $lines += 'command = ' + (Format-FrameLabCommandLine (Get-FrameLabCardArgv $spare $spareOut)) }
        }
        [IO.File]::WriteAllText($conf, (($lines -join "`n") + "`n"))

        $savedLocal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $prof
        $env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
        try {
            $argv = @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf", '-e') + (Get-FrameLabCardArgv 1 $outs[0])
            # The app's stderr is kept per cell: the Occluded hook reads it (T2650).
            $proc = Start-Process -FilePath $script:FrameLabLive.Exe -ArgumentList $argv -PassThru -RedirectStandardError (Join-Path $dir 'app.log')
        } finally { $env:LOCALAPPDATA = $savedLocal }
        $launched = @{ Pid = $proc.Id; Top = [IntPtr]::Zero; Geometry = $null; Backdrop = $null; Dir = $dir; Problems = @(); Scale = 1.0
            Mode = $Cell.Sidebar; Target = ''; Known = @{}; Outs = $outs; Spare = $spare; SpareOut = $spareOut }
        # Plain scriptblocks resolve names where they are CALLED (Invoke-
        # FrameLabCell), so the cell in hand is reached through the script's
        # state, never a captured local; GetNewClosure would hide this file's
        # functions from them instead.
        $script:FrameLabLive.Current = $launched
        $launched.Close = {
            $l = $script:FrameLabLive.Current
            if (-not $l) { return }
            if ($l.Backdrop) { try { $l.Backdrop.Dispose() } catch { }; $l.Backdrop = $null }
            try { Stop-Process -Id $l.Pid -Force -ErrorAction Stop } catch { }
            $script:FrameLabLive.Current = $null
            Start-Sleep -Milliseconds 300
        }

        $deadline = (Get-Date).AddSeconds(20)
        while ($launched.Top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
            Start-Sleep -Milliseconds 200
            $launched.Top = [GflWin]::FindTop($proc.Id, 'GhozttyWindow')
        }
        if ($launched.Top -eq [IntPtr]::Zero) { $launched.Problems += 'the app window never appeared'; return $launched }
        $top = $launched.Top
        $scale = [GflWin]::WindowDpi($top) / 96.0
        $work = [GflWin]::WorkArea($top)
        $dip = $script:FrameLabWindowDip[[int]$Cell.Panes]
        $reach = 240 + 48 + 16
        $w = [math]::Min((Get-TestChromeDip $dip[0] $scale), $work[2] - $reach - (Get-TestChromeDip 80 $scale))
        $h = [math]::Min((Get-TestChromeDip $dip[1] $scale), $work[3] - $reach - (Get-TestChromeDip 60 $scale))
        [void][GflWin]::Place($top, $work[0] + (Get-TestChromeDip 80 $scale), $work[1] + (Get-TestChromeDip 60 $scale), $w, $h)
        Start-Sleep -Milliseconds 500

        $launched.Scale = $scale
        $first = $null
        if ($Cell.Panes -gt 1 -or $Cell.Kind -eq 'trigger') {
            $first = Get-FrameLabFirstPaneId $script:FrameLabLive.Exe $top
            if (-not $first) { $launched.Problems += "+list --json did not name the window's first pane"; return $launched }
            # T2784: an IPC trigger (banner, split-close) acts on pane 1, by id.
            $launched.Target = $first.PaneId
        }
        if ($Cell.Panes -gt 1) {
            $plan = Get-FrameLabGridPlan $Cell.Panes
            foreach ($s in $plan.Splits) {
                $from = $(if ($s.From -eq 'p1') { $first.PaneId } else { $s.From })
                $o = Invoke-FrameLabCli $script:FrameLabLive.Exe (@('+split', "--target=$from", "--direction=$($s.Direction)", "--name=$($s.Name)", '-e') + (Get-FrameLabCardArgv $s.Index $outs[$s.Index - 1]))
                if ($o -match '(?i)error|unknown|not found') { $launched.Problems += "+split $($s.Name): $o" }
                Start-Sleep -Milliseconds 250
            }
            $json = $plan.Layout.Replace('"p1"', '"' + $first.PaneId + '"')
            # PS 5.1 passes a native argument's inner quotes through bare: escape them.
            $o = Invoke-FrameLabCli $script:FrameLabLive.Exe @('+rearrange', "--target=$($first.PaneId)", ('--layout=' + $json.Replace('"', '\"')))
            if ($o -match '(?i)error|unknown|not found|invalid') { $launched.Problems += "+rearrange: $o" }
        }

        # Every card has drawn at its pane's settled size: its -Out file exists
        # and none has changed for SettleMs.
        $last = Wait-FrameLabCardsQuiet $outs $script:FrameLabLive.SettleMs
        if ($last -match '<none>') { $launched.Problems += "a card never drew (lab-card -Out): $($last.Trim())" }

        $rects = Get-FrameLabPaneRects $top
        if ($rects.Count -ne $Cell.Panes) { $launched.Problems += "$($rects.Count) pane(s) on show, the cell wants $($Cell.Panes)" }
        $launched.Geometry = Measure-FrameLabLiveGeometry $launched (Get-FrameLabPaneOrder -Rects $rects)

        # T2784: a key-chord cell needs the keyboard; tab-switch also needs
        # its second tab (running the spare card), opened here and switched
        # back from, so the run starts on the first tab with two to switch.
        if (-not @($launched.Problems).Count -and $Cell.Interaction -in $script:FrameLabKeyTriggers) {
            $why = Enter-FrameLabForeground $launched
            if ($why) { $launched.Problems += $why }
            elseif ($Cell.Interaction -eq 'tab-switch') {
                foreach ($chord in 'ctrl+t', 'ctrl+shift+tab') {
                    $k = [pscustomobject]@{ Action = 'keys'; AtMs = 0.0; Label = $chord; X = 0; Y = 0; Chord = $chord; Args = @() }
                    $r = Invoke-FrameLabLiveTrigger ([pscustomobject]@{ Name = 'second tab'; Steps = @($k); Axis = 'none'; Track = ''; CaptureRect = $launched.Geometry.Window; Glides = @(); DurationMs = 0 })
                    if ($r.Skipped -or $r.Aborted) { $launched.Problems += "second tab ($chord): $($r.SkipReason)$($r.AbortReason)"; break }
                    if ($chord -eq 'ctrl+t') {
                        $t = Wait-FrameLabCardsQuiet @($spareOut) $script:FrameLabLive.SettleMs
                        if ($t -match '<none>') { $launched.Problems += "the second tab's card (card $spare) never drew: the config command did not run in the new tab" }
                    }
                }
                [void](Wait-FrameLabCardsQuiet $outs $script:FrameLabLive.SettleMs)
                $rects = Get-FrameLabPaneRects $top
                if ($rects.Count -ne $Cell.Panes) { $launched.Problems += "back on the first tab, $($rects.Count) pane(s) on show, the cell wants $($Cell.Panes)" }
                $launched.Geometry = Measure-FrameLabLiveGeometry $launched (Get-FrameLabPaneOrder -Rects $rects)
            }
        }
        # Which card each pane runs, by hwnd: how a pane-set state is named.
        foreach ($p in @($launched.Geometry.Panes)) { $launched.Known[[long]$p.Hwnd] = [int]$p.Index }
        foreach ($p in @($launched.Geometry.Panes)) {
            $p | Add-Member -Force -NotePropertyName Target -NotePropertyValue $(if ($p.Index -eq 1 -and $launched.Target) { $launched.Target } else { $p.Name })
        }
        # Beside still.png: enough to rebuild the cell's scene offline.
        [IO.File]::WriteAllText((Join-Path $dir 'geometry.json'), ($launched.Geometry | ConvertTo-Json -Depth 6))
        return $launched
    }

    $sceneHook = {
        param($Cell, $Launched, $Gesture)
        $no = { param([string[]]$Why) [pscustomobject]@{ Ok = $false; Scorer = $null; Reasons = @($Why); Delta = @{} } }
        if (@($Launched.Problems).Count) { return & $no @($Launched.Problems | ForEach-Object { "launch: $_" }) }
        $cap = $Gesture.CaptureRect
        $spec = New-FrameLabCellSceneSpec -Interaction $Cell.Interaction -Geometry $Launched.Geometry -CaptureRect $cap
        if (@($spec.Unsupported).Count) { return & $no @($spec.Unsupported) }
        try { $Launched.Backdrop = Show-FrameLabBackdrop -Rect $cap -Below $Launched.Top }
        catch { return & $no @("backdrop: $($_.Exception.Message)") }
        Start-Sleep -Milliseconds 400
        $still = {
            param([string]$Png)
            $s = Start-FrameCapture -X $cap.X -Y $cap.Y -W $cap.W -H $cap.H -SampleEvery 0 -KeepFrames 1
            Start-Sleep -Milliseconds 400
            $res = Stop-FrameCapture -Session $s
            if ($s -is [IDisposable]) { $s.Dispose() }
            $kept = @($res.Kept)
            if (-not $kept.Count -or $null -eq $kept[0].Px) { return $null }
            try { [void][GfcSession]::WritePng($kept[0], (Join-Path $Launched.Dir $Png)) } catch { }
            return (ConvertTo-FrameLabFsFrame $kept[0])
        }
        # A maximizing cell (T2398) needs a still of the window maximized as
        # well: taken FIRST and restored from, so the restored still - the one
        # the geometry is checked against - is of the window the run starts on.
        $sceneArgs = @{ Spec = $spec }
        if ($spec.Maximizes) {
            if (-not [GflWin]::Maximize($Launched.Top, $true)) { return & $no @('the window would not maximize for its maximized still frame') }
            Start-Sleep -Milliseconds $script:FrameLabLive.SettleMs
            $sceneArgs.MaximizedStill = & $still 'still-max.png'
            $back = [GflWin]::Maximize($Launched.Top, $false)
            Start-Sleep -Milliseconds $script:FrameLabLive.SettleMs
            if (-not $back) { return & $no @('the window would not restore after its maximized still frame') }
            if ($null -eq $sceneArgs.MaximizedStill) { return & $no @('the maximized still frame capture delivered no frame') }
        }
        # A pane-set cell (T2784) needs a still of its other pane set: the
        # plan's first step fired, settled, measured and photographed, then
        # its second fired back - so the start's still is of the window the
        # run starts on. Panes keep their card by hwnd; the one the trigger
        # added runs the spare card.
        if ($spec.PaneSet) {
            $r = Invoke-FrameLabLiveTrigger (Get-FrameLabTriggerStep $Gesture 0)
            if ($r.Skipped -or $r.Aborted) { return & $no @("state still, $($Gesture.Steps[0].Label): $($r.SkipReason)$($r.AbortReason)") }
            $outs = @($Launched.Outs) + @($(if ($Launched.Spare -gt 0) { $Launched.SpareOut }))
            [void](Wait-FrameLabCardsQuiet $outs $script:FrameLabLive.SettleMs)
            $sp = Get-FrameLabStatePanes -Rects (Get-FrameLabPaneRects $Launched.Top) -Known $Launched.Known -NewIndex $Launched.Spare
            $sg = Measure-FrameLabLiveGeometry $Launched $sp.Panes
            $ss = & $still 'still-state.png'
            [IO.File]::WriteAllText((Join-Path $Launched.Dir 'geometry-state.json'), ($sg | ConvertTo-Json -Depth 6))
            $r = Invoke-FrameLabLiveTrigger (Get-FrameLabTriggerStep $Gesture 1)
            if ($r.Skipped -or $r.Aborted) { return & $no @("state still, $($Gesture.Steps[1].Label): $($r.SkipReason)$($r.AbortReason)") }
            [void](Wait-FrameLabCardsQuiet $Launched.Outs $script:FrameLabLive.SettleMs)
            if (@($sp.Problems).Count) { return & $no @($sp.Problems | ForEach-Object { "state s1: $_" }) }
            if ($null -eq $ss) { return & $no @('the state still frame capture delivered no frame') }
            $back = Get-FrameLabPaneRects $Launched.Top
            if ($back.Count -ne @($Launched.Geometry.Panes).Count) { return & $no @("after $($Gesture.Steps[1].Label) $($back.Count) pane(s) are on show, the start had $(@($Launched.Geometry.Panes).Count)") }
            $sceneArgs.States = @(@{ Name = 's1'; Geometry = $sg; Still = $ss })
        }
        $sceneArgs.Still = & $still 'still.png'
        if ($null -eq $sceneArgs.Still) { return & $no @('the still frame capture delivered no frame') }
        $scene = New-FrameLabCellScene @sceneArgs
        $Launched.Scene = $scene
        return $scene
    }

    $startCapture = {
        param($Rect, [bool]$Duplication, $Scorer)
        $png = Join-Path $script:FrameLabLive.CellDir $(if ($Duplication) { 'acct' } else { 'frames' })
        $null = New-Item -ItemType Directory -Force -Path $png
        $a = @{ X = [int]$Rect.X; Y = [int]$Rect.Y; W = [int]$Rect.W; H = [int]$Rect.H; PngDir = $png; SampleEvery = 0; Duplication = $Duplication }
        if ($Scorer) { $a.Scorer = $Scorer.AsScorer() }
        return Start-FrameCapture @a
    }

    $stopCapture = {
        param($Session)
        $r = Stop-FrameCapture -Session $Session
        if ($Session -is [IDisposable]) { $Session.Dispose() }
        return $r
    }

    $play = {
        param($Path)
        $r = Invoke-FrameLabInput -Path $Path -Presence (Get-FrameLabPresence)
        if (-not $r.Skipped -and $r.AbortReason -ne 'user-input' -and $r.Sent -gt 0) { Set-FrameLabOwnInput }
        return $r
    }

    $score = {
        param($Capture, $Frames, $Gesture, $Played, $Scene)
        $sc = Get-FrameLabSceneScore -Scorer $Scene.Scorer -Capture $Capture -Gesture $Gesture -Played $Played -Delta $Scene.Delta -ExpectMaximized:([bool]$Scene.Maximizes) -ExpectStates:([bool]$Scene.PaneSet)
        $png = @{}
        foreach ($t in @($Capture.Timeline)) { if ($t.Png) { $png[[long]$t.Index] = [string]$t.Png } }
        $root = $script:FrameLabLive.RunDir.TrimEnd('\') + '\'
        $frames = @(foreach ($f in @($sc.Frames)) {
                $p = $png[[long]$f.Index]
                if ($p -and $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring($root.Length) }
                [pscustomobject]@{
                    Index = $f.Index; Png = $p
                    Findings = @($f.Findings | ForEach-Object {
                            [pscustomobject]@{ Cls = $_.Cls; Target = $_.Target; Detail = $_.Detail; Pixels = $_.Pixels; At = [pscustomobject]@{ X0 = $_.At.X0; Y0 = $_.At.Y0; X1 = $_.At.X1; Y1 = $_.At.Y1 } }
                        })
                }
            })
        return [pscustomobject]@{ BleedFrames = $sc.BleedFrames; Frames = $frames; Motion = $sc.Motion; MotionMisses = @($sc.MotionMisses); Scored = $sc.Scored; MaximizedFrames = $sc.MaximizedFrames; StateFrames = $sc.StateFrames }
    }

    return @{
        Presence     = { Get-FrameLabPresence }
        Launch       = $launch
        Scene        = $sceneHook
        StartCapture = $startCapture
        StopCapture  = $stopCapture
        Play         = $play
        # T2784: the trigger plan, fired once per run (measurement, then
        # accounting), presence-gated like Play. A key-chord cell checks the
        # window still has the keyboard first: a chord sent elsewhere would
        # be a quiet run that never did the interaction.
        Fire         = {
            param($Plan)
            $l = $script:FrameLabLive.Current
            if ($l -and @($Plan.Steps | Where-Object { $_.Action -eq 'keys' }).Count -and [GflWin]::Foreground() -ne $l.Top) {
                return [pscustomobject]@{ Skipped = $false; SkipReason = ''; Aborted = $true; AbortReason = 'the lab window lost the foreground before its key chords'; Stamps = @() }
            }
            Invoke-FrameLabLiveTrigger $Plan
        }
        Score        = $score
        # T2650: the app's own word that the display was occluded (lib\OccludedDisplay.ps1).
        Occluded     = { param($Scene) Get-OccludedDisplayLine -LogPath (Join-Path $Scene.Dir 'app.log') }
    }
}

<#
Run -Cells through the live driver and write what they say: results.json
(gated by Test-FrameLabResults) and report.html, both in -RunDir. Prints one
line per cell. Returns Results, Path, Html, Test and the raw cell results.
#>
function Invoke-FrameLabLiveRun {
    param(
        [Parameter(Mandatory = $true)][object[]]$Cells,
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$RunDir,
        [string]$Commit = '',
        [string]$Note = '',
        [switch]$Busy
    )
    $null = New-Item -ItemType Directory -Force -Path $RunDir
    $driver = New-FrameLabLiveDriver -Exe $Exe -RunDir $RunDir -Busy:$Busy
    $raw = @()
    foreach ($c in $Cells) {
        $t0 = Get-Date
        $r = try { Invoke-FrameLabCell -Cell $c -Driver $driver } catch {
            [pscustomobject]@{ Id = $c.Id; Cell = $c; Gesture = $null; Measure = $null; Accounting = $null; Score = $null
                Verdict = [pscustomobject]@{ Verdict = 'incomplete'; Reasons = @("driver error: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"); SlotGaps = 0 } }
        }
        $raw += $r
        $mo = $(if ($r.Score -and $r.Score.Motion) { ' advance={0:F3} longest={1}' -f $r.Score.Motion.AdvanceRate, $r.Score.Motion.LongestStall } else { '' })
        $bl = $(if ($r.Score) { " bleed=$($r.Score.BleedFrames)" } else { '' })
        Write-Host ('    {0,-11} {1}{2}{3} ({4:F0}s) {5}' -f $r.Verdict.Verdict, $c.Id, $bl, $mo, ((Get-Date) - $t0).TotalSeconds, (@($r.Verdict.Reasons) -join '; '))
    }
    $res = New-FrameLabResults -Cells $raw -Commit $Commit -Note $Note
    $path = Write-FrameLabResults -Results $res -Path (Join-Path $RunDir 'results.json')
    $test = Test-FrameLabResults -Path $path
    $html = Join-Path $RunDir 'report.html'
    $back = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    [void](New-FrameLabReportHtml -Results $back -Path $html -PngRoot $RunDir)
    [pscustomobject]@{ Results = $res; Path = $path; Html = $html; Test = $test; Raw = $raw }
}
