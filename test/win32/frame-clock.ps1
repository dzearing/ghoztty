# @timing-sensitive - it measures frame intervals, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2365 acceptance: every animation steps on ONE vsync-aligned frame clock,
# and its ticks land a display frame apart instead of 16-or-31 ms.
#
# THE REPORT THIS EXISTS FOR (user, 2026-10-27): blade collapse works "but
# it's JANKY. it doesn't smoothly glide like a video game smooth 60fps. it
# stutters and jitters as if it didn't know what animation meant."
#
# THE MECHANISM. Every animation used to own a 16 ms SetTimer. Windows rounds
# that to its 15.6 ms tick and only generates WM_TIMER when the queue is
# otherwise empty: measured on the user's 60 Hz box, half the ticks landed at
# 31 ms. The motion maths was already wall-clock correct; it was SAMPLED
# unevenly, and an uneven sample shown on the next vsync is judder.
# `FrameClock.zig` now blocks a worker on the compositor's clock and posts one
# coalesced frame per vblank; the UI thread hands each subscribed animation
# the WM_TIMER it already handled.
#
# THE ORACLE. Under GHOZTTY_PERF the app prints one line per finished
# animation run (`FrameClock.report`):
#
#   frame clock id=0x4647 ticks=.. intervals=.. mean_us=.. max_us=..
#               doubled=.. period_us=.. cost_mean_us=.. cost_max_us=.. source=..
#
# `doubled` counts intervals longer than 1.5 display periods - a frame the
# animation skipped. The arithmetic is pure and asserted in every lane by
# src/apprt/win32/frame_clock.zig. GHOZTTY_FRAME_CLOCK=settimer drives the
# SAME dispatch from the old 16 ms WM_TIMER, so the clock this replaced is
# measured on this build, this box and this minute.
#
# TWO SUBSCRIBERS are measured in each mode, because a skipped frame has two
# possible causes and only one of them is the clock:
#   - the PROBE (0x1b, GHOZTTY_FRAME_CLOCK_PROBE=<delay>,<duration>), a
#     subscriber whose tick does nothing: its intervals are the clock's own
#     cadence. This is what B and C judge.
#   - the focused-pane GLOW (0x4647, 250 ms per focus change), a real
#     animation a named `+split --focus` moves with no input at all. A tick
#     that overruns the frame makes the next vblank find a frame still in
#     flight, so the glow's skips also count its own paint cost (measured
#     2026-10-27: ~15.5 ms of a 16.4 ms period, T2370). It is REPORTED, and
#     asserted only to beat the old clock (E) and to fit a frame (D).
#
# WHAT IS ASSERTED:
#   A. The oracle is live in both modes: probe and glow runs were reported
#      with enough intervals to judge, the default mode is on a vblank source
#      (compositor, or the high-resolution timer where it is missing), and the
#      legacy mode really ran the old cadence.
#   B. THE DEFECT: on the frame clock, at most 5% of the probe's intervals
#      skip a frame and its mean interval is the display period +/- 2 ms.
#   C. The oracle can tell the clocks apart: the legacy 16 ms WM_TIMER made
#      the probe skip more frames than the frame clock did. Without C, B
#      passes on a box whose timer happens to be smooth, or on an oracle that
#      always says 0.
#   D. A glow tick fits in a frame: its mean handler cost is under one period.
#   E. What the user sees: the glow itself skipped fewer frames on the frame
#      clock than on the 16 ms WM_TIMER.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) - no foreground
# stolen, no input sent.
#
# -NegativeControl inverts assertion B and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\frame-clock.ps1
param(
    [string]$ExePath,
    [int]$FocusChanges = 12,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-frameclock$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$GLOW_ID = '4647'
$PROBE_ID = '1b'   # msg_timer.frame_clock_probe

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-frame-clock\$stamp"
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

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# Every `frame clock ...` run the app has reported for animation $id.
function Get-FrameRuns([string]$log, [string]$id) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match ('frame clock id=0x([0-9a-f]+) ticks=(\d+) intervals=(\d+) mean_us=(\d+) ' +
                'max_us=(\d+) doubled=(\d+) period_us=(\d+) cost_mean_us=(\d+) cost_max_us=(\d+) ' +
                'source=(\w+)')) {
            if ($Matches[1] -ne $id) { continue }
            $out += [pscustomobject]@{
                Ticks = [int]$Matches[2]; Intervals = [int]$Matches[3]
                MeanUs = [int]$Matches[4]; MaxUs = [int]$Matches[5]
                Doubled = [int]$Matches[6]; PeriodUs = [int]$Matches[7]
                CostMeanUs = [int]$Matches[8]; CostMaxUs = [int]$Matches[9]
                Source = $Matches[10]
            }
        }
    }
    return $out
}

# Sum the runs of one subscriber into one row, and print it.
function Sum-Runs([string]$mode, [string]$what, [object[]]$runs) {
    $sum = [pscustomobject]@{
        Mode = $mode; What = $what; Runs = $runs.Count
        Intervals = 0; Doubled = 0; MeanUs = 0; MaxUs = 0; PeriodUs = 0
        CostMeanUs = 0; CostMaxUs = 0; Sources = ''
    }
    if ($runs.Count -gt 0) {
        $iv = ($runs | Measure-Object -Property Intervals -Sum).Sum
        $sum.Intervals = $iv
        $sum.Doubled = ($runs | Measure-Object -Property Doubled -Sum).Sum
        if ($iv -gt 0) {
            $w = 0; foreach ($r in $runs) { $w += [int64]$r.MeanUs * $r.Intervals }
            $sum.MeanUs = [int]($w / $iv)
        }
        $sum.MaxUs = ($runs | Measure-Object -Property MaxUs -Maximum).Maximum
        $sum.PeriodUs = ($runs | Measure-Object -Property PeriodUs -Minimum).Minimum
        $sum.CostMeanUs = [int](($runs | Measure-Object -Property CostMeanUs -Average).Average)
        $sum.CostMaxUs = ($runs | Measure-Object -Property CostMaxUs -Maximum).Maximum
        $sum.Sources = (@($runs | ForEach-Object Source | Sort-Object -Unique) -join ',')
    }
    $fmt = ('  {0,-9} {1,-5} runs={2,-3} intervals={3,-4} doubled={4,-4} mean={5,6}us max={6,6}us ' +
        'period={7,6}us cost mean={8,6}us max={9,6}us source={10}')
    Rep ($fmt -f $mode, $what, $sum.Runs, $sum.Intervals, $sum.Doubled, $sum.MeanUs, $sum.MaxUs,
        $sum.PeriodUs, $sum.CostMeanUs, $sum.CostMaxUs, $sum.Sources)
    return $sum
}

# One instance under one clock. First the probe runs alone on an idle window
# (the clock's own cadence); then two named panes, and the focus handed back
# and forth so the glow fades $changes times.
function Measure-Clock([string]$mode, [int]$changes) {
    $log = Join-Path $outDir "$mode-stderr.log"
    Kill-RepoInstances
    if ($mode -eq 'settimer') { $env:GHOZTTY_FRAME_CLOCK = 'settimer' }
    else { Remove-Item env:GHOZTTY_FRAME_CLOCK -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PERF = '1'
    # Start once the window has settled; run 4 s (about 240 frames at 60 Hz).
    $env:GHOZTTY_FRAME_CLOCK_PROBE = '2500,4000'

    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw "no window for the $mode instance" }
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 800)
        # Wait for the probe's report rather than guessing at its end.
        for ($t = 0; $t -lt 60; $t++) {
            Start-Sleep -Milliseconds 250
            if (@(Get-FrameRuns $log $PROBE_ID).Count -ge 1) { break }
        }

        & $exe +split --direction=right --name=fca --focus 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        & $exe +split --direction=down --name=fcb --focus 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
        for ($i = 0; $i -lt $changes; $i++) {
            $name = if ($i % 2 -eq 0) { 'fca' } else { 'fcb' }
            & $exe +split --name=$name --focus 2>&1 | Out-Null
            # The fade is 250 ms; let it finish and report before the next.
            Start-Sleep -Milliseconds 450
        }
        Start-Sleep -Milliseconds 500
    }
    finally {
        Kill-RepoInstances
        Remove-Item env:GHOZTTY_FRAME_CLOCK_PROBE -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Probe = Sum-Runs $mode 'probe' @(Get-FrameRuns $log $PROBE_ID)
        Glow  = Sum-Runs $mode 'glow' @(Get-FrameRuns $log $GLOW_ID)
    }
}

function Share($s) { if ($s.Intervals -eq 0) { return 1.0 } return [double]$s.Doubled / $s.Intervals }
function Pct($x) { return [math]::Round(100 * $x, 1) }

$td = New-TestDesktop -Interactive:$Interactive
try {
    Rep "frame clock (T2365) - $FocusChanges focus changes per mode, exe $exe"

    $vsync = Measure-Clock 'vsync' $FocusChanges
    $legacy = Measure-Clock 'settimer' $FocusChanges
    $vp = $vsync.Probe; $lp = $legacy.Probe; $vg = $vsync.Glow; $lg = $legacy.Glow
    Rep ''

    # ---- A. the oracle is live in both modes ------------------------------
    Assert ($vp.Runs -ge 1 -and $vp.Intervals -ge 100) `
    ("the frame clock reported a probe run ($($vp.Intervals) intervals)")
    Assert ($lp.Runs -ge 1 -and $lp.Intervals -ge 50) `
    ("the legacy 16 ms clock reported a probe run ($($lp.Intervals) intervals)")
    Assert ($vg.Runs -ge [int]($FocusChanges / 2) -and $lg.Runs -ge [int]($FocusChanges / 2)) `
    ("both clocks reported glow runs ($($vg.Runs) and $($lg.Runs) of $FocusChanges focus changes)")
    if ($vp.Intervals -eq 0 -or $lp.Intervals -eq 0) {
        throw 'no frame-clock probe runs at all - GHOZTTY_PERF oracle missing (release build?)'
    }
    Assert ($vp.Sources -match '^(compositor|hrtimer)$') `
    ("the default clock steps on a vblank source, not a WM_TIMER (source=$($vp.Sources))")
    Assert ($lp.Sources -eq 'settimer') `
    ("GHOZTTY_FRAME_CLOCK=settimer really ran the old cadence (source=$($lp.Sources))")

    # ---- B. on the frame clock, ticks land a frame apart ------------------
    $share = Share $vp
    $even = ($share -le 0.05 -and [math]::Abs($vp.MeanUs - $vp.PeriodUs) -le 2000)
    if ($NegativeControl) { $even = -not $even }
    Assert $even ("frame-clock ticks land one display period apart: " +
        "$($vp.Doubled)/$($vp.Intervals) skipped a frame ($(Pct $share)%), " +
        "mean $($vp.MeanUs)us against a $($vp.PeriodUs)us period")

    # ---- C. the oracle tells the two clocks apart -------------------------
    $legacyShare = Share $lp
    Assert ($legacyShare -gt $share) `
    ("the 16 ms WM_TIMER it replaced skipped more frames: " +
        "$($lp.Doubled)/$($lp.Intervals) ($(Pct $legacyShare)%, mean $($lp.MeanUs)us) " +
        "vs $(Pct $share)% on the frame clock")

    # ---- D. a glow tick fits in a frame ------------------------------------
    Assert ($vg.CostMeanUs -lt $vg.PeriodUs) `
    ("a glow tick fits in a frame: mean cost $($vg.CostMeanUs)us (max $($vg.CostMaxUs)us) " +
        "against a $($vg.PeriodUs)us period")

    # ---- E. the animation the user sees -----------------------------------
    Assert ((Share $vg) -lt (Share $lg)) `
    ("the glow itself skips fewer frames on the frame clock: $(Pct (Share $vg))% " +
        "(mean $($vg.MeanUs)us) vs $(Pct (Share $lg))% (mean $($lg.MeanUs)us) on the 16 ms WM_TIMER")

    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_FRAME_CLOCK -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_FRAME_CLOCK_PROBE -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-clock -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
