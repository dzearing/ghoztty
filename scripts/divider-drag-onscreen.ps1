# On-screen meter for the divider (splitter) drag rate (tracker T2608).
#
# The user's report (2026-11-01, half of T2603): "pane resize is slow too".
# test\win32\drag-perf.ps1 measured the divider drag at 15.5 ms per move on
# both win-v1.51.5 and the build after it, but it runs on the BACKGROUND test
# desktop, where DWM composes nothing: a present there never waits for a
# vblank, so a frame wait that costs a whole refresh on the user's screen
# costs nothing in the bench. This runs the same drag where the compositor
# paces presents - the INPUT desktop - so the two numbers can be compared.
#
# How it stays out of the user's way: the app runs as a GHOST window
# (GHOZTTY_DEBUG_GHOST=bottom, debug builds only, the same knob
# resize-sync-onscreen.ps1 and comp-present-onscreen.ps1 film with): opaque, a
# tool window that never activates, at the bottom of the z-order. The drag is
# POSTED mouse messages to that window, never SendInput, so the user's
# pointer and keyboard are untouched. F asserts the ghost never took the
# foreground.
#
# The oracle is the app's own line, printed at button-up under GHOZTTY_PERF
# (`Window.reportDragCost`): ticks, mean_us per move, mean_wait_us (the frame
# wait inside it), waits_total and resizes_max. On top of it this script
# times the drag from outside - the wall clock from the first posted move to
# the app having handled the last one - which is the rate the user's pointer
# would actually see the divider move at (moves/s).
#
# For each -Exe (default: this tree's zig-out and a win-v1.51.5 build copied
# to zig-out-v1515 - the kill helper only touches builds under this repo, so a
# build from another worktree is copied in, never run from there: `git
# worktree add <dir> win-v1.51.5`, build it -Doptimize=Debug, copy its
# zig-out\bin), each -Desktop (input, background) and each pane
# count, it runs -Repeats drags and prints the median. The table at the end
# is the answer: if the input-desktop cost per move is the background cost
# plus a frame or more, the bench was blind to it.
#
#   powershell -NoProfile -File scripts\divider-drag-onscreen.ps1
#   powershell -NoProfile -File scripts\divider-drag-onscreen.ps1 -Exe zig-out\bin\ghoztty.exe -Desktops input
#
# A fullscreen app (game, presentation) changes what DWM composes behind it,
# so the input-desktop rows would not be representative: they are SKIPPED
# with the reason, and the background rows still run.

param(
    [string[]]$Exe = @(
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\ghoztty.exe'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out-v1515\bin\ghoztty.exe')),
    [ValidateSet('input', 'background')][string[]]$Desktops = @('input', 'background'),
    [int[]]$PaneCounts = @(2, 4),
    # Moves per drag, pixels per move, and the gap between posted moves. 4 ms
    # is a 250 Hz mouse: faster than the app can take them, so the drag's
    # wall clock is set by the app, not by this script.
    [int]$Moves = 40,
    [int]$StepPx = 2,
    [int]$StepMs = 4,
    [int]$Repeats = 3,
    [string]$OutDir
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$repo = Split-Path $PSScriptRoot -Parent
# The kill helper scopes by absolute path; a relative -Exe reads as outside it.
$Exe = @($Exe | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $repo $_ } })
$testLib = Join-Path $repo 'test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
. (Join-Path $testLib 'OccludedDisplay.ps1')   # T2650: a film of an occluded display is skipped, never scored
. (Join-Path $testLib 'BuildMode.ps1')
. (Join-Path $testLib 'UserPresence.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("ghoztty-divider-onscreen\" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_PERF'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DdWin {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
    static IntPtr LP(int x, int y) { return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)); }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    // Wait until `watch`'s right edge is within 1 px of `want`; the elapsed
    // microseconds since `sw` started, or -1 after `timeoutMs`.
    static long Reach(IntPtr watch, int want, System.Diagnostics.Stopwatch sw, int timeoutMs) {
        long limit = sw.ElapsedMilliseconds + timeoutMs;
        while (sw.ElapsedMilliseconds < limit) {
            RECT r; GetWindowRect(watch, out r);
            if (Math.Abs(r.R - want) <= 1)
                return sw.ElapsedTicks * 1000000L / System.Diagnostics.Stopwatch.Frequency;
            System.Threading.Thread.SpinWait(2000);
        }
        return -1;
    }
    // One divider drag: down at (x,y) client, `moves` posted moves of `dx` px
    // out, then the same back, `stepMs` apart, then up. Returns the wall clock
    // in microseconds from the first outward move to `watch` (the pane left
    // of the divider) having reached the outward end - posted moves are not
    // coalesced and a sent message jumps the posted queue, so the pane's own
    // edge is the only honest "the app has handled them all" signal - or -1
    // when it never got there.
    public static long Drag(IntPtr h, IntPtr watch, int x, int y, int moves, int dx, int stepMs) {
        const uint DOWN = 0x0201, UP = 0x0202, MOVE = 0x0200;
        IntPtr MK = (IntPtr)1;
        RECT r0; GetWindowRect(watch, out r0);
        PostMessage(h, DOWN, MK, LP(x, y));
        System.Threading.Thread.Sleep(150);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 1; i <= moves; i++) {
            PostMessage(h, MOVE, MK, LP(x + i * dx, y));
            long due = (long)i * stepMs;
            while (sw.ElapsedMilliseconds < due) System.Threading.Thread.Sleep(1);
        }
        long us = Reach(watch, r0.R + moves * dx, sw, 5000);
        var back = System.Diagnostics.Stopwatch.StartNew();
        for (int i = moves - 1; i >= 0; i--) {
            PostMessage(h, MOVE, MK, LP(x + i * dx, y));
            long due = (long)(moves - i) * stepMs;
            while (back.ElapsedMilliseconds < due) System.Threading.Thread.Sleep(1);
        }
        Reach(watch, r0.R, back, 5000);
        PostMessage(h, UP, IntPtr.Zero, LP(x, y));
        return us;
    }
}
'@

# Every `divider drag ...` line printed so far, as key=value hashtables.
function Get-DragLines([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -notmatch 'divider drag (ticks=.*)$') { continue }
        $h = @{}
        foreach ($kv in ($Matches[1] -split '\s+')) {
            $p = $kv -split '=', 2
            if ($p.Count -eq 2) { $h[$p[0]] = $p[1] }
        }
        $out += , $h
    }
    return $out
}

function Get-Median([double[]]$v) {
    $s = @($v | Sort-Object)
    if ($s.Count -eq 0) { return 0 }
    return $s[[int][Math]::Floor(($s.Count - 1) / 2)]
}

function Measure-Build([string]$exe, [string]$desk) {
    $tag = Split-Path (Split-Path (Split-Path $exe -Parent) -Parent) -Leaf
    $runDir = Join-Path $OutDir "$tag-$desk"
    New-Item -ItemType Directory -Force $runDir | Out-Null
    $log = Join-Path $runDir 'stderr.txt'
    $rows = @()
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 600)
    [void](Set-GhozttyTestIsolation -Tag 'ddos' -Quiet)
    Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
    $td = if ($desk -eq 'input') { New-TestDesktop -Interactive } else { New-TestDesktop }
    try {
        $env:LOCALAPPDATA = $runDir
        $env:GHOZTTY_PERF = '1'
        if ($desk -eq 'input') {
            $env:GHOZTTY_DEBUG_GHOST = 'bottom'
            # A ghost sits under the user's windows; without this the app
            # parks its renderer as occluded (T1951) and presents nothing.
            $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        } else {
            Remove-Item env:GHOZTTY_DEBUG_GHOST, env:GHOZTTY_TEST_NO_OCCLUSION -ErrorAction SilentlyContinue
        }
        $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
            '--config-default-files=false', '--background=#101014', '--session-persistence=false')
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        Assert "$tag/$desk.0 the window came up" ($top -ne [IntPtr]::Zero)
        if ($top -eq [IntPtr]::Zero) { return $rows }
        $top = [IntPtr]$top
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1400 -Height 900)
        Start-Sleep -Milliseconds 1500

        $have = 1
        foreach ($want in ($PaneCounts | Sort-Object)) {
            while ($have -lt $want) {
                $dir = if ($have -eq 1) { 'right' } elseif ($have % 2 -eq 0) { 'down' } else { 'right' }
                & $exe +split --direction=$dir 2>&1 | Out-Null
                $have++
                for ($t = 0; $t -lt 40; $t++) {
                    Start-Sleep -Milliseconds 250
                    if (@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible).Count -ge $have) { break }
                }
            }
            Start-Sleep -Milliseconds 1500
            $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
            if ($panes.Count -lt 2) { Assert "$tag/$desk/$want.1 split into panes ($($panes.Count))" $false; continue }
            # The ROOT divider: the one vertical boundary every pane sits wholly
            # on one side of. Where +split nests the extra panes depends on
            # which pane has focus, so it is found, not assumed.
            $grabX = $null
            foreach ($l in @($panes | ForEach-Object { $_.Left } | Sort-Object -Unique | Select-Object -Skip 1)) {
                if (@($panes | Where-Object { $_.Right -gt $l -and $_.Left -lt $l }).Count -eq 0) {
                    $leftEdge = (@($panes | Where-Object { $_.Right -le $l } | ForEach-Object { $_.Right }) | Measure-Object -Maximum).Maximum
                    $grabX = [int](($leftEdge + $l) / 2)
                    $watch = [IntPtr]@($panes | Where-Object { $_.Right -eq $leftEdge })[0].Hwnd
                    break
                }
            }
            if ($null -eq $grabX) { Assert "$tag/$desk/$want.1 a root divider spans the window" $false; continue }
            $pt = New-Object DdWin+POINT
            $pt.X = $grabX
            $pt.Y = [int](((@($panes | ForEach-Object { $_.Top }) | Measure-Object -Minimum).Minimum +
                    (@($panes | ForEach-Object { $_.Bottom }) | Measure-Object -Maximum).Maximum) / 2)
            [void][DdWin]::ScreenToClient($top, [ref]$pt)
            Write-Host ("  panes: " + (($panes | ForEach-Object { "{0},{1}-{2},{3}" -f $_.Left, $_.Top, $_.Right, $_.Bottom }) -join '  ') + "  grab client $($pt.X),$($pt.Y)")

            $walls = @(); $means = @(); $waits = @(); $ticks = @(); $wt = @(); $resizes = @()
            for ($r = 1; $r -le $Repeats; $r++) {
                $before = @(Get-DragLines $log).Count
                $wall = [DdWin]::Drag($top, $watch, $pt.X, $pt.Y, $Moves, $StepPx, $StepMs)
                if ($wall -lt 0) { Write-Host "  $tag/$desk/$want drag $r`: the pane edge never reached the end of the drag" }
                $line = $null
                for ($t = 0; $t -lt 40 -and -not $line; $t++) {
                    Start-Sleep -Milliseconds 250
                    $all = @(Get-DragLines $log)
                    if ($all.Count -gt $before) { $line = $all[$all.Count - 1] }
                }
                if (-not $line) { Write-Host "  $tag/$desk/$want drag $r`: NO SAMPLE"; continue }
                if ($wall -gt 0) { $walls += $wall }; $means += [double]$line['mean_us']; $waits += [double]$line['mean_wait_us']
                $ticks += [double]$line['ticks']; $wt += [double]$line['waits_total']; $resizes += [double]$line['resizes_max']
                Start-Sleep -Milliseconds 600
            }
            Assert "$tag/$desk/$want.2 every drag printed its cost line ($($means.Count)/$Repeats)" ($means.Count -eq $Repeats)
            Assert "$tag/$desk/$want.3 the divider followed every drag to its end ($($walls.Count)/$Repeats)" ($walls.Count -eq $Repeats)
            if ($means.Count -eq 0) { continue }
            $wall = Get-Median $walls
            $tk = Get-Median $ticks
            $row = [pscustomobject]@{
                Build = $tag; Desktop = $desk; Panes = $want
                Ticks = $tk
                MeanMs = [Math]::Round((Get-Median $means) / 1000, 2)
                WaitMs = [Math]::Round((Get-Median $waits) / 1000, 2)
                WaitsTotal = Get-Median $wt
                ResizesMax = Get-Median $resizes
                # What the pointer sees: moves the app handled per second of
                # drag, posted faster than it can take them.
                MovesPerSec = if ($wall -gt 0) { [Math]::Round($Moves * 1e6 / $wall, 0) } else { 0 }
            }
            $rows += $row
            Write-Host ("  {0,-16} {1,-10} panes={2} ticks={3,-3} mean={4,6} ms wait={5,6} ms waits={6,-3} resizes_max={7,-2} moves/s={8}" -f `
                $row.Build, $row.Desktop, $row.Panes, $row.Ticks, $row.MeanMs, $row.WaitMs, $row.WaitsTotal, $row.ResizesMax, $row.MovesPerSec)
        }
        if ($desk -eq 'input') {
            $fgPid = [uint32]0
            [void][DdWin]::GetWindowThreadProcessId([DdWin]::GetForegroundWindow(), [ref]$fgPid)
            Assert "$tag/$desk.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
        }
    } finally {
        [void](Stop-RepoGhoztty -Exe $exe -SettleMs 600)
        Remove-TestDesktop | Out-Null
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    return $rows
}

$all = @()
try {
    foreach ($desk in $Desktops) {
        if ($desk -eq 'input') {
            $p = Get-UserPresence
            if ($p.Present -and $p.Reason -match 'fullscreen|Direct3D|presentation|covers') {
                "SKIP input desktop: $($p.Reason) - DWM is not composing the desktop the way it does for a drag"
                continue
            }
        }
        foreach ($e in $Exe) {
            if (-not (Test-Path $e)) { "SKIP $e`: not built"; continue }
            "== $e on the $desk desktop"
            $all += @(Measure-Build $e $desk | Where-Object { $_ -is [pscustomobject] -and $_.Build })
        }
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

''
'SUMMARY (median of {0} drags, {1} moves of {2} px posted every {3} ms)' -f $Repeats, $Moves, $StepPx, $StepMs
$all | Format-Table Build, Desktop, Panes, Ticks, MeanMs, WaitMs, WaitsTotal, ResizesMax, MovesPerSec -AutoSize | Out-String -Width 200
$all | ConvertTo-Json | Set-Content -Encoding ascii (Join-Path $OutDir 'summary.json')
"  results in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
