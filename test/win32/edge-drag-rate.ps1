# @timing-sensitive - it measures wall-clock cost, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2603 acceptance: how fast a WINDOW-EDGE drag can go - the UI thread's cost
# of one step - with and without T2578's pre-layout, on one build.
#
# THE REPORT (user, 2026-11-01, on 1.51.6): "resize feels slower", then
# "resizing a pane or the window both are slow and chonky". Every resize change
# before it was accepted on FILM bad-frame counts (resize-sync-onscreen.ps1);
# none of them measured how many steps per second a drag can deliver, so a
# frame-correctness fix could trade responsiveness away and nothing would say.
# drag-perf.ps1 already clocks a divider drag; this is the window edge's half.
#
# THE ORACLE. Under GHOZTTY_PERF the app times each edge step from its
# WM_WINDOWPOSCHANGING (before T2578's pre-layout runs) to the end of its
# WM_SIZE pass, and prints at WM_EXITSIZEMOVE:
#
#   window drag steps=.. prelayouts=.. mean_prelayout_us=.. mean_size_us=..
#               mean_us=.. fps=..
#
# plus the divider drag's full `window drag ticks=...` cost line. That is the
# time the size loop is held between a pointer move and the next one, which is
# the rate the frame edge can follow the pointer at.
#
# THE DRAGS. Steps are posted to the window's own thread (SWP_ASYNCWINDOWPOS,
# where a real drag's size loop calls SetWindowPos) inside a WM_ENTERSIZEMOVE /
# WM_EXITSIZEMOVE pair, from a thread on the background test desktop. Right
# edge, growing then shrinking, in two scenes: three terminals in a row, and a
# terminal beside a viewer. Each in two modes: `prelayout` (the shipped path)
# and `noprelayout` (GHOZTTY_RESIZE_NOPRELAYOUT, T2578 off).
#
# WHAT IS ASSERTED:
#   A. The oracle is live: every drag printed a summary, and its step count is
#      most of the steps posted (a step that never reached WM_SIZE is not a step).
#   B. The pre-layout really ran on growing steps in `prelayout` mode and never
#      in `noprelayout` - otherwise the comparison below compares nothing.
#   C. THE BUDGET: a growing step costs no more than -GrowBudgetPct of the same
#      step without the pre-layout (T2578 may keep its in-sync grow only if it
#      costs no rate), and every drag holds -MinFps or better.
# Numbers for every drag go to $env:TEMP\ghoztty-edge-drag-rate\<stamp>\report.txt.
#
# -NegativeControl sets the budget to 50 percent, which the shipped pre-layout
# cannot meet: C must go red.
#
# -Burst (T2666) measures GHOZTTY_RESIZE_BURST against the shipped pre-layout,
# both under GHOZTTY_RESIZE_TRACE: each pane's new-size frame is held before
# its swap and released with the others at the end of WM_WINDOWPOSCHANGING.
# What a film decides (whether content and frame share a compose) needs the
# lit input desktop; what this proves off it is that the hold works and costs
# nothing a user would feel:
#   E. burst lays out shrinking steps too (T2580's shrink), frames really were
#      held (`swap-held`), every burst that held anything was released and
#      settled, and no pane hit the renderer's hold timeout (every step's
#      frame is released, not timed out), and a burst step costs no more than
#      -BurstBudgetPct of the shipped step and holds -MinFps.
#
# -ContentArms (T2609 step 1) measures instead WHERE a step's time goes: the
# shipped path in three arms of GHOZTTY_RESIZE_NO_CONTENT (src/apprt/win32/
# resize_content.zig) - `content` (`0`: every step resizes the terminals),
# `held` (the default since T2623: the grids hold, no frame wait) and `empty`
# (a pane's resize does nothing; the floor) - and prints each drag's stage
# breakdown from the `window drag ticks=` line. Only A is asserted, plus D:
# the content-free arms really skipped the content (no frame waits). It never
# stamps the guard.
#
# -ReleaseSandbox runs a release build (-ExePath, e.g. a ReleaseFast
# `--prefix zig-out-perf`) under all three isolating knobs (lib\Isolation.ps1),
# because a Debug build's own pixel loops inflate the very stages being
# compared. It never stamps the guard either.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) - no foreground
# stolen. Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\edge-drag-rate.ps1
param(
    [string]$ExePath,
    [int]$Steps = 40,
    [int]$StepPx = 10,
    [int]$StepMs = 8,
    [int]$GrowBudgetPct = 125,
    [int]$MinFps = 30,
    [switch]$NegativeControl,
    [switch]$ContentArms,
[switch]$Burst,
[int]$BurstBudgetPct = 150,
    [switch]$ReleaseSandbox,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if ($NegativeControl) { $GrowBudgetPct = 50 }

if ($ReleaseSandbox) {
    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'edgerate' -ReleaseSandbox)
} else {
    $env:GHOZTTY_PIPE_SUFFIX = "-edgerate$PID"
}

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe -Allow:$ReleaseSandbox | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-edge-drag-rate\$stamp"
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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class EdgeRate {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr res);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool SetThreadDesktop(IntPtr d);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
    static bool Send(IntPtr h, uint msg) {
        IntPtr res;
        return SendMessageTimeout(h, msg, IntPtr.Zero, IntPtr.Zero, 0x0002, 10000, out res) != IntPtr.Zero;
    }
    // One right-edge drag of `steps` posted steps `stepMs` apart, `dw` px each,
    // run on a thread attached to `desk`. Returns the ms from the first step to
    // the last one landing, or -1 when the last never landed.
    public static long Drag(string desk, IntPtr h, int steps, int dw, int stepMs) {
        long result = -2;
        var t = new Thread(delegate() {
            IntPtr d = OpenDesktop(desk, 0, false, 0x01FF);
            if (d == IntPtr.Zero || !SetThreadDesktop(d)) { result = -3; return; }
            try {
                const uint NOZ = 0x0004, NOACT = 0x0010, NOMOVE = 0x0002, ASYNC = 0x4000;
                RECT r; GetWindowRect(h, out r);
                int w = r.R - r.L, hh = r.B - r.T;
                Send(h, 0x0231); // WM_ENTERSIZEMOVE
                var sw = System.Diagnostics.Stopwatch.StartNew();
                for (int i = 1; i <= steps; i++) {
                    SetWindowPos(h, IntPtr.Zero, 0, 0, w + dw * i, hh, NOZ | NOACT | NOMOVE | ASYNC);
                    long due = (long)i * stepMs;
                    while (sw.ElapsedMilliseconds < due) Thread.Sleep(1);
                }
                result = -1;
                while (sw.ElapsedMilliseconds < 20000) {
                    RECT n; GetWindowRect(h, out n);
                    if (n.R - n.L == w + dw * steps) { result = sw.ElapsedMilliseconds; break; }
                    Thread.Sleep(1);
                }
                Send(h, 0x0232); // WM_EXITSIZEMOVE
            } finally { CloseDesktop(d); }
        });
        t.Start();
        t.Join();
        return result;
    }
}
'@

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Get-RateSamples([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'window drag steps=(\d+) prelayouts=(\d+) mean_prelayout_us=(\d+) mean_size_us=(\d+) mean_us=(\d+) fps=(\d+)') {
            $out += [pscustomobject]@{
                Steps = [int]$Matches[1]; Prelayouts = [int]$Matches[2]
                PrelayoutUs = [int]$Matches[3]; SizeUs = [int]$Matches[4]
                MeanUs = [int]$Matches[5]; Fps = [int]$Matches[6]
            }
        }
    }
    return @($out)
}

# The `window drag ticks=` stage breakdown, one per drag (T2609).
function Get-CostSamples([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'window drag ticks=(\d+) mean_us=(\d+) max_us=(\d+) mean_wait_us=(\d+) .*waits_total=(\d+) .*mean_layout_us=(\d+) mean_place_us=(\d+) mean_paint_us=(\d+) mean_overlay_us=(\d+) mean_resize_us=(\d+)') {
            $out += [pscustomobject]@{
                Ticks = [int]$Matches[1]; MeanUs = [int]$Matches[2]; MaxUs = [int]$Matches[3]
                WaitUs = [int]$Matches[4]; Waits = [int]$Matches[5]; LayoutUs = [int]$Matches[6]
                PlaceUs = [int]$Matches[7]; PaintUs = [int]$Matches[8]; OverlayUs = [int]$Matches[9]
                ResizeUs = [int]$Matches[10]
            }
        }
    }
    return @($out)
}

# One drag; the summary it printed, with the wall clock the drag took.
function Invoke-EdgeDrag([IntPtr]$top, [string]$log, [int]$dw) {
    $before = @(Get-RateSamples $log).Count
    $wall = [EdgeRate]::Drag($script:deskName, $top, $Steps, $dw, $StepMs)
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 250
        $all = @(Get-RateSamples $log)
        if ($all.Count -gt $before) {
            $s = $all[$all.Count - 1]
            Add-Member -InputObject $s -NotePropertyName WallMs -NotePropertyValue $wall -Force
            $c = @(Get-CostSamples $log)
            $cost = if ($c.Count -gt 0) { $c[$c.Count - 1] } else { $null }
            Add-Member -InputObject $s -NotePropertyName Cost -NotePropertyValue $cost -Force
            return $s
        }
    }
    return $null
}

function Wait-Panes([IntPtr]$top, [string]$class, [int]$want) {
    for ($t = 0; $t -lt 60; $t++) {
        if (@(Get-TestChildWindows -Window $top -Class $class | Where-Object Visible).Count -ge $want) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# One instance per scene and mode; returns @{ grow = sample; shrink = sample }.
function Measure-Scene([string]$scene, [string]$mode) {
    $log = Join-Path $outDir "$scene-$mode-stderr.log"
    Kill-RepoInstances
    $env:GHOZTTY_PERF = '1'
    if ($mode -eq 'noprelayout') { $env:GHOZTTY_RESIZE_NOPRELAYOUT = '1' }
    else { Remove-Item env:GHOZTTY_RESIZE_NOPRELAYOUT -ErrorAction SilentlyContinue }
    if ($mode -eq 'burst') { $env:GHOZTTY_RESIZE_BURST = '1' }
    else { Remove-Item env:GHOZTTY_RESIZE_BURST -ErrorAction SilentlyContinue }
    # Both -Burst arms trace, so the rate compares like with like.
    if ($Burst) { $env:GHOZTTY_RESIZE_TRACE = '1' }
    switch ($mode) {
        'held' { $env:GHOZTTY_RESIZE_NO_CONTENT = '1' }
        'empty' { $env:GHOZTTY_RESIZE_NO_CONTENT = 'empty' }
        # Held is the default since T2623; the old per-step resize is `0`.
        'content' { $env:GHOZTTY_RESIZE_NO_CONTENT = '0' }
        default { Remove-Item env:GHOZTTY_RESIZE_NO_CONTENT -ErrorAction SilentlyContinue }
    }
    $res = @{}
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -AllowReleaseBuild:$ReleaseSandbox -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw "no window for $scene/$mode" }
        $top = [IntPtr]$top
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1100 -Height 800)
        Start-Sleep -Milliseconds 800
        if ($scene -eq 'row3') {
            & $exe +split --direction=right 2>&1 | Out-Null
            [void](Wait-Panes $top 'GhozttyTerminal' 2)
            & $exe +split --direction=right 2>&1 | Out-Null
            [void](Wait-Panes $top 'GhozttyTerminal' 3)
        } else {
            $page = Join-Path $outDir 'page.md'
            Set-Content -Path $page -Value "# Edge drag`n`nA page for the viewer pane.`n" -Encoding ascii
            & $exe +split --direction=right "--view=$page" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 2500
        }
        Start-Sleep -Milliseconds 800
        $res.grow = Invoke-EdgeDrag $top $log $StepPx
        Start-Sleep -Milliseconds 500
        $res.shrink = Invoke-EdgeDrag $top $log (-$StepPx)
    } finally {
        Kill-RepoInstances
        Remove-Item env:GHOZTTY_RESIZE_NOPRELAYOUT -ErrorAction SilentlyContinue
        Remove-Item env:GHOZTTY_RESIZE_NO_CONTENT -ErrorAction SilentlyContinue
        Remove-Item env:GHOZTTY_RESIZE_BURST -ErrorAction SilentlyContinue
        Remove-Item env:GHOZTTY_RESIZE_TRACE -ErrorAction SilentlyContinue
    }
    $res.log = $log
    return $res
}

$td = New-TestDesktop -Interactive:$Interactive
$script:deskName = $td.Name
$all = @{}
try {
    Rep "T2603 window-edge drag rate, $stamp"
    Rep "  exe:   $exe"
    Rep "  $Steps steps of $StepPx px, posted $StepMs ms apart; budget: grow <= $GrowBudgetPct% of no-prelayout, >= $MinFps fps"
    Rep ''
    $modes = if ($ContentArms) { @('content', 'held', 'empty') } elseif ($Burst) { @('burst', 'prelayout') } else { @('prelayout', 'noprelayout') }
    foreach ($scene in 'row3', 'viewer') {
        foreach ($mode in $modes) {
            $r = Measure-Scene $scene $mode
            $all["$scene/$mode"] = $r
            foreach ($dir in 'grow', 'shrink') {
                $s = $r[$dir]
                if ($null -eq $s) { Rep ("  {0,-7} {1,-12} {2,-6} NO SAMPLE" -f $scene, $mode, $dir); continue }
                Rep ("  {0,-7} {1,-12} {2,-6} steps={3,-3} mean={4,6}us prelayout={5,6}us ({6} ran) size={7,6}us ~{8,4} fps  wall={9} ms" -f
                    $scene, $mode, $dir, $s.Steps, $s.MeanUs, $s.PrelayoutUs, $s.Prelayouts, $s.SizeUs, $s.Fps, $s.WallMs)
                if ($ContentArms -and $null -ne $s.Cost) {
                    $c = $s.Cost
                    Rep ("  {0,-7} {1,-12} {2,-6}   stages: wait={3}us ({4} waits) layout={5}us place={6}us paint={7}us overlay={8}us resize={9}us max={10}us" -f
                        $scene, $mode, $dir, $c.WaitUs, $c.Waits, $c.LayoutUs, $c.PlaceUs, $c.PaintUs, $c.OverlayUs, $c.ResizeUs, $c.MaxUs)
                }
            }
        }
    }
    Rep ''
    $samples = @($all.Values | ForEach-Object { $_.grow; $_.shrink })
    $live = @($samples | Where-Object { $null -ne $_ })
    $want = 4 * $modes.Count
    Assert ($live.Count -eq $want) "A. every drag printed a window drag summary ($($live.Count)/$want)"
    $short = @($live | Where-Object { $_.Steps -lt [int]($Steps / 2) })
    Assert ($live.Count -gt 0 -and $short.Count -eq 0) "A. every drag reached WM_SIZE for most of its $Steps steps (fewest: $(($live | Measure-Object Steps -Minimum).Minimum))"
    if ($ContentArms) {
        foreach ($scene in 'row3', 'viewer') {
            foreach ($mode in 'held', 'empty') {
                $g = $all["$scene/$mode"].grow
                # Held (T2623) still tells the renderer its new view - a few
                # microseconds, the grid held - and waits for nothing; empty
                # does not even do that.
                $ok = $null -ne $g -and $null -ne $g.Cost -and $g.Cost.Waits -eq 0 -and
                    ($mode -eq 'held' -or $g.Cost.ResizeUs -eq 0)
                Assert $ok "D. $scene/$mode kept the terminals out of the drag (waits=$($g.Cost.Waits) resize=$($g.Cost.ResizeUs)us)"
            }
        }
    }
    if ($Burst) {
        foreach ($scene in 'row3', 'viewer') {
            $b = $all["$scene/burst"]; $p = $all["$scene/prelayout"]
            if ($null -eq $b.shrink -or $null -eq $b.grow -or $null -eq $p.grow) { Assert $false "E. $scene has burst and shipped samples"; continue }
            Assert ($b.shrink.Prelayouts -gt 0 -and $p.shrink.Prelayouts -eq 0) `
                "E. $scene burst lays shrinking steps out too ($($b.shrink.Prelayouts) burst, $($p.shrink.Prelayouts) shipped)"
            $text = if (Test-Path $b.log) { Get-Content $b.log } else { @() }
            $held = @($text | Select-String -SimpleMatch 'swap-held').Count
            $rel = @($text | Select-String -SimpleMatch 'resize trace burst-release').Count
            $set = @($text | Select-String -SimpleMatch 'resize trace burst-settled').Count
            Rep ("  {0,-7} burst trace: swap-held={1} burst-release={2} burst-settled={3}" -f $scene, $held, $rel, $set)
            Assert ($held -gt 0) "E. $scene frames were held for the burst (swap-held=$held)"
            $tout = @($text | Select-String -SimpleMatch 'swap-hold-timeout').Count
            Assert ($tout -eq 0) "E. $scene no held frame ran out the renderer's hold timeout ($tout did)"
            Assert ($rel -gt 0 -and $rel -eq $set) "E. $scene every burst was released and settled ($rel released, $set settled)"
            $ptext = if (Test-Path $p.log) { Get-Content $p.log } else { @() }
            Assert (@($ptext | Select-String -SimpleMatch 'swap-held').Count -eq 0) "E. $scene the shipped path holds nothing (negative control for the trace)"
            foreach ($dir in 'grow', 'shrink') {
                $limit = [int]([Math]::Max($p.$dir.MeanUs, 1) * $BurstBudgetPct / 100)
                Assert ($b.$dir.MeanUs -le $limit -and $b.$dir.Fps -ge $MinFps) `
                    "E. $scene a burst $dir step costs $($b.$dir.MeanUs)us at $($b.$dir.Fps) fps, budget ${limit}us ($BurstBudgetPct% of $($p.$dir.MeanUs)us) and $MinFps fps"
            }
        }
    }
    foreach ($scene in @(if (-not $ContentArms -and -not $Burst) { 'row3', 'viewer' })) {
        $on = $all["$scene/prelayout"]; $off = $all["$scene/noprelayout"]
        if ($null -eq $on.grow -or $null -eq $off.grow) { Assert $false "B/C. $scene has both grow samples"; continue }
        Assert ($on.grow.Prelayouts -gt 0 -and $off.grow.Prelayouts -eq 0) `
            "B. $scene the pre-layout ran on growing steps only when on ($($on.grow.Prelayouts) on, $($off.grow.Prelayouts) off)"
        $limit = [int]($off.grow.MeanUs * $GrowBudgetPct / 100)
        Assert ($on.grow.MeanUs -le $limit) `
            "C. $scene a growing step costs $($on.grow.MeanUs)us with the pre-layout, budget ${limit}us ($GrowBudgetPct% of $($off.grow.MeanUs)us without)"
    }
    $shipped = if ($ContentArms) { '*/content' } else { '*/prelayout' }
    $slow = @($all.GetEnumerator() | Where-Object { $_.Key -like $shipped } | ForEach-Object { $_.Value.grow; $_.Value.shrink } | Where-Object { $null -ne $_ -and $_.Fps -lt $MinFps })
    Assert ($slow.Count -eq 0) "C. every shipped-path drag holds $MinFps fps or better ($($slow.Count) below)"
    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and -not $ContentArms -and -not $Burst -and -not $ReleaseSandbox -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard edge-drag-rate -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
