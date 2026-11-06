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
#   G. T2372 - the glides the user complained about, driven one after another
#      on one frame-clock instance (Measure-Glides): hero slide, banner
#      collapse, sidebar toggle, stack glide. G1: each one ran on the clock
#      and reported. G2: each one's mean tick cost fits in a display period.
#      Each row also prints its skipped-frame share.
#   H. T2724 - a failed compositor wait is not the end of the compositor.
#      The background test desktop is occluded, so the compositor refuses
#      the wait (0xC01E0006) and the clock falls back to its timer. H1: the
#      fallback steps at the display's period as DWM reports it (read here
#      independently, DwmGetCompositionTimingInfo), not a fixed 60 Hz. H2:
#      the compositor is tried again after the fallback, rather than never.
#      On a desktop whose compositor never fails, H records that the clock
#      stayed on it.
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
    [int]$GlideRepeats = 6,
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
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
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

# ---- T2372: the glides themselves ------------------------------------------
# The `frame clock` runs for timer $id on a window of class $class, reported
# after line $from of $log. The class is on the line since T2372, because a
# banner's collapse, a fade and a scrollbar all subscribe as id 1.
function Get-GlideRuns([string]$log, [int]$from, [string]$id, [string]$class) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
    for ($i = $from; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match ('frame clock id=0x([0-9a-f]+) ticks=(\d+) intervals=(\d+) mean_us=(\d+) ' +
                'max_us=(\d+) doubled=(\d+) period_us=(\d+) cost_mean_us=(\d+) cost_max_us=(\d+) ' +
                'source=(\w+) class=(\S+)')) {
            if ($Matches[1] -ne $id -or $Matches[11] -ne $class) { continue }
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

function Get-LineCount([string]$log) {
    if (-not (Test-Path $log)) { return 0 }
    return @(Get-Content $log -ErrorAction SilentlyContinue).Count
}

# One instance on the frame clock, four glides driven in turn with no real
# input (keys and clicks are posted to the background desktop's windows):
#   hero    - hero mode on four panes, the selection moved down and up
#             (Window 0x4841, the carousel slide)
#   banner  - a three-line banner on s1, clicked collapsed and expanded
#             (BannerOverlay 0x1 card resize, 0x2 the frozen copy's glide)
#   sidebar - the pane sidebar's collapse/expand toggle clicked; the column
#             follows the grid's glide (T2406), so its frames are the
#             Window's 0x534C, plus PaneSidebar 0x5 when it runs alone
#   stack   - P | s1 | s2 | s3 at 760 DIP (two on show), the focus moved
#             to either end so the run changes (Window 0x534C)
# Returns one summed row per glide subscriber.
function Measure-Glides([int]$repeats) {
    $log = Join-Path $outDir 'glides-stderr.log'
    Kill-RepoInstances
    Remove-Item env:GHOZTTY_FRAME_CLOCK -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_FRAME_CLOCK_PROBE -ErrorAction SilentlyContinue
    $env:GHOZTTY_PERF = '1'
    $rows = @()
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false',
        '--macos-pane-style=flat')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw 'no window for the glide instance' }
        Start-Sleep -Milliseconds 800
        $dpi = [int](Get-TestWindowDpi -Window $top)
        if ($dpi -le 0) { $dpi = 96 }
        $scale = $dpi / 96.0
        $px = { param([double]$d) Get-TestChromeDip -Dip $d -Scale $scale }
        [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (& $px 1500) -Height (& $px 700))
        Start-Sleep -Milliseconds 1500
        & $exe +split --direction=right --name=s1 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        & $exe +split --pane=s1 --direction=right --name=s2 2>&1 | Out-Null
        Start-Sleep -Milliseconds 800
        & $exe +split --pane=s2 --direction=right --name=s3 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1500
        $panes = { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible) }
        Rep ("  glide setup: dpi $dpi, {0} panes on show" -f @(& $panes).Count)

        # -- hero ---------------------------------------------------------
        $mark = Get-LineCount $log
        $first = @(& $panes | Sort-Object Left)[0]
        if ($first) {
            [void](Send-TestKeys -Window $top -Target ([IntPtr]$first.Hwnd) -Modifiers ctrl, shift -Key Space)
            # Every tile needs a snapshot before a swap can slide (Window.heroSlide).
            Start-Sleep -Milliseconds 2500
            for ($i = 0; $i -lt $repeats; $i++) {
                $v = @(& $panes)
                if ($v.Count -ne 1) { break }
                $key = if ($i % 2 -eq 0) { 'Down' } else { 'Up' }
                [void](Send-TestKeys -Window $top -Target ([IntPtr]$v[0].Hwnd) -Modifiers ctrl, alt -Key $key)
                Start-Sleep -Milliseconds 900
            }
            $v = @(& $panes)
            if ($v.Count -eq 1) {
                [void](Send-TestKeys -Window $top -Target ([IntPtr]$v[0].Hwnd) -Modifiers ctrl, shift -Key Space)
            }
            Start-Sleep -Milliseconds 1200
        }
        $rows += Sum-Runs 'hero' 'slide' @(Get-GlideRuns $log $mark '4841' 'GhozttyWindow')

        # -- banner -------------------------------------------------------
        $mark = Get-LineCount $log
        & $exe +set-banner --target=s1 "head\nrow2\nrow3" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
        for ($i = 0; $i -lt $repeats; $i++) {
            $ov = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyBannerOverlay' |
                Where-Object Visible) | Select-Object -First 1
            if (-not $ov) { break }
            $y = $ov.Top + [math]::Min([int]($ov.Height / 2), (& $px 12))
            [void](Send-TestMouse -Window $top -Target ([IntPtr]$ov.Hwnd) -X ($ov.Left + [int]($ov.Width / 2)) -Y $y)
            Start-Sleep -Milliseconds 900
        }
        $rows += Sum-Runs 'banner' 'card' @(Get-GlideRuns $log $mark '1' 'GhozttyBannerOverlay')
        $rows += Sum-Runs 'banner' 'copy' @(Get-GlideRuns $log $mark '2' 'GhozttyBannerOverlay')

        # -- sidebar ------------------------------------------------------
        $mark = Get-LineCount $log
        for ($i = 0; $i -lt $repeats; $i++) {
            $sb = @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1
            if (-not $sb -or -not $sb.Visible) { break }
            # The collapse/expand toggle (pane-sidebar-glide.ps1's geometry, T2289).
            $inset = [int][math]::Truncate(((& $px 52) - (& $px 28)) / 2)
            $c = (& $px 12) + $inset + [int]((& $px 28) / 2)
            [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $c) -Y ($sb.Top + $c))
            Start-Sleep -Milliseconds 1100
        }
        $rows += Sum-Runs 'sidebar' 'grid' @(Get-GlideRuns $log $mark '534c' 'GhozttyWindow')
        $rows += Sum-Runs 'sidebar' 'column' @(Get-GlideRuns $log $mark '5' 'GhozttyPaneSidebar')

        # -- stack --------------------------------------------------------
        [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (& $px 760) -Height (& $px 700))
        Start-Sleep -Milliseconds 1500
        $mark = Get-LineCount $log
        Rep ("  stack setup: {0} panes on show at 760 DIP" -f @(& $panes).Count)
        for ($i = 0; $i -lt $repeats; $i++) {
            # P is the unnamed first pane; s1 is next to it, so s1 / s3 are the
            # two ends a named link can reach and each one changes the run.
            $name = if ($i % 2 -eq 0) { 's3' } else { 's1' }
            # A named +split that exists is focused (the IPC focus a
            # ghoztty://focus link shares), which brings a tucked pane on show.
            & $exe +split --name=$name --focus 2>&1 | Out-Null
            Start-Sleep -Milliseconds 1100
        }
        $rows += Sum-Runs 'stack' 'glide' @(Get-GlideRuns $log $mark '534c' 'GhozttyWindow')
    }
    finally {
        Kill-RepoInstances
    }
    return $rows
}

# The display period DWM reports, in us, read the way FrameClock.zig reads it
# (rateRefresh at offsets 4/8 of the 292-byte packed DWM_TIMING_INFO).
function Get-DwmPeriodUs {
    if (-not ('FcDwm' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FcDwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, byte[] info);
}
"@
    }
    $buf = New-Object byte[] 292
    [BitConverter]::GetBytes([uint32]292).CopyTo($buf, 0)
    if ([FcDwm]::DwmGetCompositionTimingInfo([IntPtr]::Zero, $buf) -lt 0) { return 0 }
    $num = [BitConverter]::ToUInt32($buf, 4); $den = [BitConverter]::ToUInt32($buf, 8)
    if ($num -eq 0) { return 0 }
    return [int]([double]$den * 1000000 / $num)
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

    # ---- H. a failed compositor wait is retried, at the display's rate (T2724)
    $vlog = Join-Path $outDir 'vsync-stderr.log'
    $vlines = @(Get-Content $vlog -ErrorAction SilentlyContinue)
    $fails = @($vlines | Where-Object { $_ -match 'compositor clock wait failed \((\w+)\); falling back to a timer at period_us=(\d+)' })
    $retries = @($vlines | Where-Object { $_ -match 'frame clock retrying the compositor clock' })
    $dwmUs = Get-DwmPeriodUs
    Rep ("  compositor waits failed $($fails.Count) time(s), retried $($retries.Count); " +
        "DWM reports a ${dwmUs}us refresh period")
    if ($fails.Count -gt 0) {
        [void]($fails[0] -match 'period_us=(\d+)')
        $fbUs = [int]$Matches[1]
        Assert ($dwmUs -gt 0 -and [math]::Abs($fbUs - $dwmUs) -le 50) `
        ("H1: the timer fallback steps at the display's period: ${fbUs}us against DWM's ${dwmUs}us " +
            "(60 Hz would be 16666us)")
        Assert ($retries.Count -ge 1) `
        ("H2: the compositor clock was tried again after the fallback ($($retries.Count) retries, " +
            "$($fails.Count) failures)")
    }
    else {
        Assert ($vp.Sources -eq 'compositor') `
        ("H: the compositor clock never failed on this desktop and the probe stayed on it (source=$($vp.Sources))")
    }

    # ---- G. the glides users watch (T2372) --------------------------------
    Rep ''
    Rep "glides on the frame clock - $GlideRepeats of each"
    $glides = @(Measure-Glides $GlideRepeats)
    $by = @{}; foreach ($g in $glides) { $by["$($g.Mode)/$($g.What)"] = $g }
    # G1. Each glide was driven and reported: the oracle reaches it.
    foreach ($k in 'hero/slide', 'banner/card', 'stack/glide') {
        Assert ($by[$k].Runs -ge 1 -and $by[$k].Intervals -ge 5) `
        ("G1: the $k glide ran on the frame clock and reported ($($by[$k].Runs) runs, $($by[$k].Intervals) intervals)")
    }
    $sbRuns = $by['sidebar/grid'].Runs + $by['sidebar/column'].Runs
    Assert ($sbRuns -ge 1) ("G1: the sidebar toggle glided on the frame clock " +
        "($($by['sidebar/grid'].Runs) grid runs, $($by['sidebar/column'].Runs) column runs)")
    # G2. Every glide's tick fits in a frame: mean handler cost under one
    # display period. A tick that does not fit cannot be smooth on any clock.
    foreach ($g in $glides) {
        if ($g.Runs -eq 0) { continue }
        Assert ($g.CostMeanUs -lt $g.PeriodUs) `
        ("G2: a $($g.Mode) $($g.What) tick fits in a frame: mean cost $($g.CostMeanUs)us " +
            "(max $($g.CostMaxUs)us) against a $($g.PeriodUs)us period; " +
            "$($g.Doubled)/$($g.Intervals) intervals skipped a frame ($(Pct (Share $g))%)")
    }
    $periods = @($glides | Where-Object Runs | ForEach-Object PeriodUs)
    if ($periods.Count) {
        Rep ("  measured display period on this desktop: {0}us (the user's panel is 120 Hz = 8333us; " +
            "the hidden test desktop composes at its own rate)" -f ($periods | Measure-Object -Minimum).Minimum)
    }

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
