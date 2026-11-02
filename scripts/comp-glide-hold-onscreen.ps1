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
# window never contains (the bell-fade-onscreen.ps1 caveat). So that card reads
# as an empty card until it lands live, on BOTH paths, and it is reported but
# never scored; .6 scores the cards that are live at both ends of the glide.
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
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms stall
#   powershell -NoProfile -File scripts\comp-glide-hold-onscreen.ps1 -Arms stall -NoDeclare   # stall.10 must go red
# -NoDeclare sets GHOZTTY_GLIDE_DECLARE=0: the visuals are placed on every
# frame from the window's thread again, as T2571 left them.
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
    [switch]$NoDeclare
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
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
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_GLIDE_TREE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_STACK_SLIDE_MS', 'GHOZTTY_DEBUG_GLIDE_STALL_MS', 'GHOZTTY_GLIDE_DECLARE'
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
        foreach ($f in $rows) {
            $b = $f.B[$k]
            if ($b.Rows -eq 0) { if ($on0 -and $on1) { $missing++ }; continue }
            $seen++
            if ($on0 -and $on1 -and $b.Rows -lt [Math]::Floor(0.9 * $restH)) { $missing++ }
            $w = $b.RightMax - $b.LeftMin + 1
            if ($b.Rows -gt $restH + 2 -or $w -gt $restW + 2) { $heldBad += "$($colourNames[$k]) f$($f.I) ${w}x$($b.Rows) vs rest ${restW}x$restH" }
            # Torn: rows disagree on an edge. A card's clip is a straight
            # vertical line, so occlusion moves an edge for every row at once.
            if (($b.LeftMax - $b.LeftMin) -gt 2 -or ($b.RightMax - $b.RightMin) -gt 2) {
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
    if ($arm -eq 'stall') { Score-Stall $arm $rows }
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
}

$onLine = 'pane presents through a composition swap chain'

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'compglide')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

try {
    foreach ($arm in $Arms) {
        $comp = $arm -in 'on', 'tree', 'stall'
        $isTree = $arm -in 'tree', 'stall'
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=$(if ($comp) { '1' } else { 'unset' }) PANE_TREE=$(if ($isTree) { '1' } else { 'unset' }), slide $SlideMs ms$(if ($arm -eq 'stall') { ", stall $StallMs ms, declare $(if ($NoDeclare) { 'off' } else { 'on' })" }))"
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
        if ($comp) { $env:GHOZTTY_COMP_PRESENT = '1' } else { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
        foreach ($k in 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE') {
            if ($isTree) { Set-Item "env:$k" '1' } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        }
        if ($NoGlideTree) { $env:GHOZTTY_GLIDE_TREE = '0' } else { Remove-Item env:GHOZTTY_GLIDE_TREE -ErrorAction SilentlyContinue }
        if ($arm -eq 'stall') { $env:GHOZTTY_DEBUG_GLIDE_STALL_MS = "$StallMs" } else { Remove-Item env:GHOZTTY_DEBUG_GLIDE_STALL_MS -ErrorAction SilentlyContinue }
        if ($NoDeclare) { $env:GHOZTTY_GLIDE_DECLARE = '0' } else { Remove-Item env:GHOZTTY_GLIDE_DECLARE -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#000000',
            '--palette=1=#ff0000', '--palette=2=#00ff00', '--palette=4=#0000ff', '--palette=5=#ff00ff',
            '--command=powershell.exe -NoLogo -NoProfile', "--title=t2513-$arm") -StdErr $err
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

        # T2572: the panes' paths went to the compositor (none under -NoDeclare).
        if ($arm -eq 'stall') {
            $dec = [regex]::Matches((Read-Text $err), 'pane visual glide declared').Count
            Assert "$arm.11 the glide was handed to the compositor ($dec pane path(s) declared)" ($dec -ge 1)
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
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
