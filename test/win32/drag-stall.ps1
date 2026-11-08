# @timing-sensitive - it measures frame-by-frame motion against a stalled UI thread, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2770 acceptance: a divider drag keeps moving through a UI-thread stall.
#
# THE DEFECT. Since T2769 a divider drag in the composition tree writes the
# pane visuals before its layout pass - on the window's own thread. Anything
# that blocks that thread (a slow paint, a handler that takes half a second)
# froze the edge under the hand until it came back.
#
# THE FIX. While a divider drag is live a composition thread
# (src/apprt/win32/CompDragThread.zig) wakes on the compositor clock, reads
# the cursor, extrapolates the dragged gutter from the model the window
# thread published at its last move (comp_drag.zig), and writes and commits
# the moving visuals itself, under a device lock the window thread shares.
#
# THE ORACLE. At button-up the app prints (GHOZTTY_PERF):
#
#   divider drag thread ticks=.. writes=.. ticks_in_stall=.. writes_in_stall=..
#                       clamped=.. lag_p95_us=.. lag_max_us=..
#
# `GHOZTTY_DEBUG_DRAG_STALL_MS` blocks the window thread at the drag's 6th
# move with a flag up, so the thread counts the frames it woke for inside the
# stall and the ones it wrote a new position in. The test desktop has no
# cursor, so `GHOZTTY_DEBUG_DRAG_CURSOR_FILE` points the thread at a file this
# script keeps writing the pointer's screen position into - from a thread of
# its own, on the same time-based path the posted moves follow, so the
# "cursor" keeps moving while the posted moves sit in the stalled queue.
#
# ARMS.
#   thread    : stall -StallMs, thread on. Every frame inside the stall writes.
#   off       : stall -StallMs, GHOZTTY_COMP_DRAG_THREAD=0. No thread at all:
#               nobody can move the edge until the window thread is back.
#   frozen    : stall -StallMs, thread on, but the pointer never leaves the
#               grab point - the oracle's own negative: an edge that does
#               not move must score zero writes in the stall.
#   nostall   : no stall, thread on: the thread's cursor-to-commit lag, held
#               under 8 ms (half a frame), the window-thread path's own
#               figure from the same drag's comp line recorded beside it.
#
#   powershell -NoProfile -File test\win32\drag-stall.ps1            # -StallMs 500
#   powershell -NoProfile -File test\win32\drag-stall.ps1 -StallMs 50
param(
    [string]$ExePath,
    [int]$StallMs = 500,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-dragstall$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-drag-stall\$stamp-$PID"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Rep([string]$m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; $host.UI.WriteErrorLine("FAIL  $label"); "FAIL  $label" | Out-File -Append $report }
}

$knobs = 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_PERF', 'GHOZTTY_COMP_DRAG_THREAD',
'GHOZTTY_DEBUG_DRAG_STALL_MS', 'GHOZTTY_DEBUG_DRAG_CURSOR_FILE'
# The pointer the composition thread reads (GHOZTTY_DEBUG_DRAG_CURSOR_FILE),
# written on its own .NET thread every 2 ms along the drag's path.
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
using System.Diagnostics;
public static class T2770CursorWriter {
    static Thread th;
    static volatile bool stop;
    public static volatile int Writes, Fails;
    public static Stopwatch Clock = new Stopwatch();
    public static void Start(string file, int x0, int y0, double speed, int halfMs, double holdTo) {
        stop = false; Writes = 0; Fails = 0; Clock.Reset();
        var ready = new ManualResetEvent(false);
        th = new Thread(() => {
            Clock.Start();
            ready.Set();
            string last = "";
            while (!stop && Clock.ElapsedMilliseconds < 2 * halfMs + 300) {
                double ms = Clock.Elapsed.TotalMilliseconds;
                int d = ms < holdTo ? 0 : ms <= halfMs ? (int)(speed * ms / 1000.0) : (int)(speed * Math.Max(0, 2 * halfMs - ms) / 1000.0);
                string line = (x0 + d) + " " + y0;
                if (line != last) {
                    try { File.WriteAllText(file, line); last = line; Writes++; } catch { Fails++; }
                }
                double next = ms + 2;
                while (!stop && Clock.Elapsed.TotalMilliseconds < next) Thread.SpinWait(64);
            }
        });
        th.IsBackground = true;
        th.Priority = ThreadPriority.AboveNormal;
        th.Start();
        ready.WaitOne(5000);
    }
    public static void Join() {
        stop = true;
        if (th != null) { th.Join(3000); th = null; }
    }
}
"@
function Clear-Knobs { foreach ($k in $knobs) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

function Get-ThreadLines([string]$log) {
    $out = @()
    if (-not (Test-Path $log)) { return @() }
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match ('divider drag thread ticks=(\d+) writes=(\d+) ticks_in_stall=(\d+) ' +
                'writes_in_stall=(\d+) clamped=(\d+) lag_p95_us=(\d+) lag_max_us=(\d+)')) {
            $out += [pscustomobject]@{
                Ticks = [int]$Matches[1]; Writes = [int]$Matches[2]
                TicksInStall = [int]$Matches[3]; WritesInStall = [int]$Matches[4]
                Clamped = [int]$Matches[5]; LagP95 = [int]$Matches[6]; LagMax = [int]$Matches[7]
            }
        }
    }
    return @($out)
}

function Get-CompLine([string]$log) {
    if (-not (Test-Path $log)) { return $null }
    $last = $null
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'divider drag comp commits=(\d+) mean_commit_us=(\d+) max_commit_us=(\d+)') {
            $last = [pscustomobject]@{ Commits = [int]$Matches[1]; MeanUs = [int]$Matches[2]; MaxUs = [int]$Matches[3] }
        }
    }
    return $last
}

# The pointer's path, in px from the grab point, at t ms: out at $speed px/s
# for $halfMs, then back.
$speed = 300.0
$halfMs = 900
function PathAt([double]$ms, [double]$holdTo = -1) {
    # The frozen arm holds the pointer still at the grab point until $holdTo.
    if ($ms -lt $holdTo) { return 0 }
    if ($ms -le $halfMs) { return [int]($speed * $ms / 1000.0) }
    $back = [math]::Max(0, 2 * $halfMs - $ms)
    return [int]($speed * $back / 1000.0)
}

# One arm: a fresh instance, one split, one drag of the root divider along the
# path. Returns @{ Thread = <line or $null>; Comp = <line>; Started = <n> }.
function Invoke-Arm([string]$arm) {
    $log = Join-Path $outDir "$arm-stderr.log"
    $cursorFile = Join-Path $outDir "$arm-cursor.txt"
    Kill-RepoInstances
    Clear-Knobs
    $env:GHOZTTY_COMP_PANE_TREE = '1'
    $env:GHOZTTY_COMP_CHROME = '1'
    $env:GHOZTTY_PERF = '1'
    $env:GHOZTTY_DEBUG_DRAG_CURSOR_FILE = $cursorFile
    if ($arm -ne 'nostall') { $env:GHOZTTY_DEBUG_DRAG_STALL_MS = "$StallMs" }
    if ($arm -eq 'off') { $env:GHOZTTY_COMP_DRAG_THREAD = '0' }
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw "no window for arm $arm" }
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 800)
        Start-Sleep -Milliseconds 800
        & $exe +split --direction=right 2>&1 | Out-Null
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 250
            if (@(Get-VisiblePanes ([IntPtr]$top)).Count -ge 2) { break }
        }
        Start-Sleep -Milliseconds 600
        $panes = @(Get-VisiblePanes ([IntPtr]$top) | Sort-Object Left)
        if ($panes.Count -lt 2) { throw "arm ${arm}: the split never showed two panes" }
        $x0 = [int](($panes[0].Right + $panes[1].Left) / 2)
        $y0 = [int](($panes[0].Top + $panes[0].Bottom) / 2)
        Set-Content -LiteralPath $cursorFile -Value "$x0 $y0" -Encoding ascii

        [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y0 -Action down -HoldMs 0)
        Start-Sleep -Milliseconds 120

        # The cursor-file writer: a compiled thread of its own, so it keeps the
        # "cursor" moving while a posted move waits behind the stall. (A
        # PowerShell runspace was tried first: it came up hundreds of ms late
        # and was starved at random, and a cursor that did not move scored as
        # a thread that did not write.) The frozen arm never leaves the grab
        # point, posted moves and cursor alike.
        $holdTo = if ($arm -eq 'frozen') { 1e9 } else { -1 }
        [T2770CursorWriter]::Start($cursorFile, $x0, $y0, $speed, $halfMs, $holdTo)
        $clock = [T2770CursorWriter]::Clock

        # The posted moves on the same path until the path is done. One may
        # block for the whole stall; the next one picks the path up where the
        # clock says it is.
        while ($clock.ElapsedMilliseconds -lt (2 * $halfMs)) {
            $d = PathAt $clock.ElapsedMilliseconds $holdTo
            [void](Send-TestMouse -Window $top -Target $top -X ($x0 + $d) -Y $y0 -Action move -HoldMs 0)
            Start-Sleep -Milliseconds 10
        }
        [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y0 -Action up -HoldMs 0)
        [T2770CursorWriter]::Join()
        Rep ("  {0,-8} cursor writer: {1} writes, {2} collisions" -f $arm, [T2770CursorWriter]::Writes, [T2770CursorWriter]::Fails)

        $th = $null; $comp = $null
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 250
            $comp = Get-CompLine $log
            $lines = @(Get-ThreadLines $log)
            if ($lines.Count -gt 0) { $th = $lines[$lines.Count - 1] }
            if ($null -ne $comp -and ($arm -eq 'off' -or $null -ne $th)) { break }
        }
        $started = @(Select-String -LiteralPath $log -Pattern 'divider drag composition thread started' -ErrorAction SilentlyContinue).Count
        $stalls = @(Select-String -LiteralPath $log -Pattern "drag debug stall ms=$StallMs" -ErrorAction SilentlyContinue).Count
        # Why a stall tick wrote nothing (same travel / no model / dead / no cursor).
        $skips = @(Select-String -LiteralPath $log -Pattern 'divider drag thread stall skips (.*)$' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Matches[0].Groups[1].Value }) | Select-Object -Last 1
        return @{ Thread = $th; Comp = $comp; Started = $started; Stalls = $stalls; Lines = @(Get-ThreadLines $log).Count; Skips = $skips }
    } finally {
        [T2770CursorWriter]::Join()
        Kill-RepoInstances
        Clear-Knobs
    }
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Rep "T2770 drag through a UI-thread stall, $stamp"
    Rep "  exe: $exe   stall: $StallMs ms   path: $speed px/s out and back, $halfMs ms each way"
    $r = @{}
    foreach ($arm in 'thread', 'off', 'frozen', 'nostall') {
        $r[$arm] = Invoke-Arm $arm
        $t = $r[$arm].Thread; $c = $r[$arm].Comp
        Rep ("  {0,-8} thread: {1}   comp: {2}   started={3} stalls={4}" -f $arm,
            $(if ($t) { "ticks=$($t.Ticks) writes=$($t.Writes) in_stall=$($t.WritesInStall)/$($t.TicksInStall) clamped=$($t.Clamped) lag_p95=$($t.LagP95)us max=$($t.LagMax)us" } else { 'none' }),
            $(if ($c) { "commits=$($c.Commits) mean=$($c.MeanUs)us max=$($c.MaxUs)us" } else { 'none' }),
            $r[$arm].Started, $r[$arm].Stalls)
        if ($r[$arm].Skips) { Rep ("  {0,-8} stall skips: {1}" -f $arm, $r[$arm].Skips) }
    }
    Rep ''
    $th = $r['thread'].Thread
    $stalled = ($StallMs -gt 0)
    if ($stalled) {
        Assert ($r['thread'].Stalls -ge 1 -and $r['off'].Stalls -ge 1) "the seam stalled the window thread $StallMs ms in the thread and off arms"
        # At least 60% of the stall's frames at 60 Hz woke the thread, and
        # every frame of it but two (the stall's edges) wrote a new position.
        $minTicks = [math]::Floor(0.6 * $StallMs / 16.7)
        $adv = ($null -ne $th -and $th.TicksInStall -ge $minTicks -and $th.WritesInStall -ge ($th.TicksInStall - 2) -and $th.WritesInStall -gt 0)
        if ($NegativeControl) { $adv = -not $adv }
        Assert $adv ("thread on: the edge kept advancing through the stall - " +
            "$(if ($th) { "$($th.WritesInStall) writes in $($th.TicksInStall) frames inside it" } else { 'no thread line' }) (want >= $minTicks frames, all but 2 writing)")
    }
    Assert ($null -eq $r['off'].Thread -and $r['off'].Started -eq 0 -and $null -ne $r['off'].Comp) `
    ("thread off: no composition thread at all (started=$($r['off'].Started)), the T2769 window-thread path alone " +
        "($(if ($r['off'].Comp) { "$($r['off'].Comp.Commits) commits" } else { 'no comp line' })) - nobody to move the edge in a stall")
    if ($stalled) {
        $fz = $r['frozen'].Thread
        Assert ($null -ne $fz -and $fz.TicksInStall -gt 0 -and $fz.WritesInStall -le 1) `
        ("the oracle can go red: with the cursor held still through the stall the thread wrote " +
            "$(if ($fz) { "$($fz.WritesInStall) times in $($fz.TicksInStall) frames" } else { '(no line)' })")
    }
    $ns = $r['nostall'].Thread
    $nc = $r['nostall'].Comp
    # The bar is half a 60 Hz frame (T2770 measured 0.7-4.4 ms p95 in a debug
    # build; T2814 owns finding where the worst of it goes). The window-thread figure beside
    # it is that path's best case - from the move's start, not counting the
    # time the move waited in the queue behind the pass before it.
    $lagOk = ($null -ne $ns -and $ns.Writes -gt 0 -and $ns.LagP95 -lt 8000)
    if ($NegativeControl) { $lagOk = -not $lagOk }
    Assert $lagOk ("no stall: cursor-to-commit p95 under half a frame (8 ms) " +
        "($(if ($ns) { "$($ns.LagP95)us p95, $($ns.LagMax)us max over $($ns.Writes) writes" } else { 'no line' }); " +
        "the window-thread path in the same drag: $(if ($nc) { "$($nc.MeanUs)us mean, $($nc.MaxUs)us max" } else { 'no comp line' }))")
    $life = $true
    foreach ($arm in 'thread', 'frozen', 'nostall') { if ($r[$arm].Started -ne 1 -or $r[$arm].Lines -ne 1) { $life = $false } }
    Assert $life ("one thread per drag, stopped at button-up: started/line counts " +
        (($('thread', 'frozen', 'nostall') | ForEach-Object { "$_ $($r[$_].Started)/$($r[$_].Lines)" }) -join ', '))
    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Clear-Knobs
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and $StallMs -eq 500) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard drag-stall -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
