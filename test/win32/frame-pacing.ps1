# frame-pacing.ps1 - T1737 acceptance: a terminal pane's frame pacing is
# MEASURED, and T1423's hero-mode before/after is taken with it.
#
# The probe: every frame a pane puts on screen is timestamped where the frame
# is reported shown (`Surface.markFrameShown`, both present paths), and the
# debug-only `frame-pacing` IPC action reads the intervals back (count, mean,
# p50/p95/p99/max, frames over 2x the median, a histogram) together with how
# many hero thumbnail captures that pane's renderer committed over the same
# window. Release builds answer `unknown action`.
#
# Two launches on the background test desktop, identical except for one knob:
#   paced    - the shipped T1423 behaviour: interaction holds every capture.
#   unpaced  - GHOZTTY_HERO_SNAP_UNPACED=1 (debug only): the window never
#              hears about interaction, so the carousel captures every tile,
#              the hero included, every 150ms heartbeat - pre-T1423.
# In each: a cmd hero pane printing as fast as it can (so it redraws
# continuously), a second pane behind it in the carousel, hero mode on, then
#   G. a ~3s wheel gesture in the hero pane, probe reset at its start and read
#      at its end;
#   Q. the same window of time with no input at all.
#
# Scored (the probe's own trustworthiness, and the pacing it exists to see):
#   - the hero pane redraws continuously: >= 30 intervals over the gesture,
#     median under 100 ms;
#   - the probe tells panes apart: the hidden carousel pane, printing one line
#     a second, records under a third of the hero's frames;
#   - reset forgets: a reading straight after a reset holds a handful of
#     frames, not the gesture's;
#   - paced: the hero's renderer committed <= 1 capture during the gesture,
#     and captures resumed (>= 3) in the quiet window;
#   - unpaced: >= 8 captures rode the hero's frames during the gesture (the
#     A/B arm is real - without it the comparison means nothing).
# The frame-time numbers themselves (p95/p99/max/long, both arms) are
# REPORTED, not thresholded: they are the measurement T1423 could not take,
# and the box's load decides them more than either arm does.
#
# -NegativeControl runs the PACED arm with the unpaced knob set, and must FAIL
# the paced capture assertion: the oracle can tell the two behaviours apart.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-framepacing$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
# T1511: arms the run, so an unwound body neither prints a pass nor stamps.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

function Get-Panes([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    return , @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | ForEach-Object {
        [pscustomobject]@{
            Hwnd = $_.Hwnd; Visible = $_.Visible
            Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
            Width = $_.Width; Height = $_.Height
        }
    })
}

# One probe call. Returns the response's data object, or $null (and says why).
function Invoke-Pacing([string]$target, [switch]$Reset) {
    $a = @("--target=$target")
    if ($Reset) { $a += '--reset' }
    $resp = Invoke-GhozttyIpc -Action 'frame-pacing' -Arguments $a
    if ($null -eq $resp) { Write-Host "  frame-pacing $target : no answer on the pipe"; return $null }
    if (-not $resp.success) { Write-Host "  frame-pacing $target : $($resp.error)"; return $null }
    return $resp.data
}

function Format-Reading($r) {
    if ($null -eq $r) { return '(no reading)' }
    return ('frames={0} intervals={1} mean={2:N1}ms p50={3:N1}ms p95={4:N1}ms p99={5:N1}ms max={6:N1}ms long={7} captures={8}' -f
        $r.frames, $r.intervals, ($r.mean_us / 1000.0), ($r.p50_us / 1000.0), ($r.p95_us / 1000.0),
        ($r.p99_us / 1000.0), ($r.max_us / 1000.0), $r.long, $r.captures)
}

# A wheel gesture in the hero pane: the T1423 shape (hero-mode.ps1 phase 1b),
# alternating notches so the viewport stays near the live bottom.
function Invoke-HeroGesture([IntPtr]$top, $hero, [int]$count) {
    $c = Get-TestWindowRect -Window $top -Client
    $hx = [int]($c.Left + $hero.Left + 40); $hy = [int]($c.Top + $hero.Top + 40)
    for ($g = 0; $g -lt $count; $g++) {
        $d = if ($g % 2 -eq 0) { 120 } else { -120 }
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$hero.Hwnd) -X $hx -Y $hy -Action wheel -Delta $d)
        Start-Sleep -Milliseconds 90
    }
}

# One launch, one arm. Returns @{ Gesture; Quiet; Hidden; AfterReset } readings.
function Invoke-Arm([string]$arm, [bool]$unpaced) {
    Kill-RepoInstances
    $errlog = Join-Path $env:TEMP "ghoztty-frame-pacing-$arm-$PID.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    if ($unpaced) { $env:GHOZTTY_HERO_SNAP_UNPACED = '1' } else { Remove-Item Env:GHOZTTY_HERO_SNAP_UNPACED -ErrorAction SilentlyContinue }
    try {
        $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
            '--config-default-files=false', '--session-persistence=false', '--command=cmd.exe')
    } finally {
        Remove-Item Env:GHOZTTY_HERO_SNAP_UNPACED -ErrorAction SilentlyContinue
    }
    $gpid = [int]$app.Pid
    $script:launched += $gpid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { throw "$arm : GUI died at launch" }
    $top = Wait-TestWindow -ProcessId $gpid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { throw "$arm : top window not found" }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestDesktopLeak -ProcessId $gpid)) "$arm : GUI is NOT enumerable on the interactive desktop"

    $win = (& $exe +list --json | ConvertFrom-Json).data.windows[0].target
    & $exe +split --direction=down --name=paceb | Out-Null
    Start-Sleep -Milliseconds 1000
    & $exe +send-keys --target=paceb 'ping -t 127.0.0.1' Enter | Out-Null
    $panes = Get-Panes $top
    if ($panes.Count -ne 2) { throw "$arm : expected 2 panes, got $($panes.Count)" }
    $first = ($panes | Sort-Object Top, Left | Select-Object -First 1)
    # Hero on over the FIRST pane, then start its flood: `for /L` with a zero
    # step never ends, and `@echo` prints as fast as cmd can.
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$first.Hwnd) -Modifiers @('ctrl', 'shift') -Key 'Space')
    Start-Sleep -Milliseconds 900
    $vis = @((Get-Panes $top) | Where-Object Visible)
    if ($vis.Count -ne 1) { throw "$arm : hero mode did not turn on ($($vis.Count) visible panes)" }
    $hero = $vis[0]
    & $exe +send-keys --target=$win 'for /L %i in (0,0,1) do @echo frame-pacing %i' Enter | Out-Null
    # Let the carousel settle into its cadence.
    Start-Sleep -Milliseconds 1500

    # Reset forgets: read straight back.
    [void](Invoke-Pacing $win -Reset)
    $afterReset = Invoke-Pacing $win

    # G: the gesture window.
    [void](Invoke-Pacing $win -Reset)
    [void](Invoke-Pacing 'paceb' -Reset)
    Invoke-HeroGesture $top $hero 32
    $gesture = Invoke-Pacing $win
    $hidden = Invoke-Pacing 'paceb'

    # Q: the same length of time, nobody touching anything.
    Start-Sleep -Milliseconds 700
    [void](Invoke-Pacing $win -Reset)
    Start-Sleep -Milliseconds 3000
    $quiet = Invoke-Pacing $win

    Assert (-not ($app.Process -and $app.Process.HasExited)) "$arm : no crash through the arm"
    if ($unpaced -and -not (Select-String -Path $errlog -Pattern 'hero snap pacing DISABLED' -Quiet)) {
        Write-Host "  note: $arm launch never logged the unpaced knob"
    }
    Kill-RepoInstances
    return @{ Gesture = $gesture; Quiet = $quiet; Hidden = $hidden; AfterReset = $afterReset }
}

Kill-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:launched = @()
$paced = $null; $unpaced = $null

try {
    # A release build has no probe: say so instead of scoring nothing as red.
    $paced = Invoke-Arm 'paced' ([bool]$NegativeControl)
    $g = $paced.Gesture
    if ($null -eq $g) {
        Assert $false 'paced: the frame-pacing probe answered (debug build required)'
    } else {
        Write-Host "  paced    gesture : $(Format-Reading $g)"
        Write-Host "  paced    quiet   : $(Format-Reading $paced.Quiet)"
        Write-Host "  paced    hidden  : $(Format-Reading $paced.Hidden)"
        Assert ($g.intervals -ge 30 -and $g.p50_us -gt 0 -and $g.p50_us -lt 100000) `
            "probe: the flooding hero pane redraws continuously ($($g.intervals) intervals, median $([math]::Round($g.p50_us / 1000.0, 1)) ms)"
        $h = $paced.Hidden
        Assert ($null -ne $h -and $h.frames -lt [math]::Max(1, [int]($g.frames / 3))) `
            "probe: it tells panes apart - the one-line-a-second carousel pane drew $(if ($h) { $h.frames }) frames to the hero's $($g.frames)"
        $ar = $paced.AfterReset
        Assert ($null -ne $ar -and $ar.frames -lt 10 -and $ar.frames -lt $g.frames) `
            "probe: a reset forgets (a reading straight after one held $(if ($ar) { $ar.frames }) frames)"
        Assert ($g.captures -le 1) `
            "paced: the hero's renderer committed at most one thumbnail capture during the gesture ($($g.captures))"
        Assert ($null -ne $paced.Quiet -and $paced.Quiet.captures -ge 3) `
            "paced: captures resumed once the window was quiet ($(if ($paced.Quiet) { $paced.Quiet.captures }) in 3s)"
    }

    if (-not $NegativeControl) {
        $unpaced = Invoke-Arm 'unpaced' $true
        $u = $unpaced.Gesture
        if ($null -eq $u) {
            Assert $false 'unpaced: the frame-pacing probe answered'
        } else {
            Write-Host "  unpaced  gesture : $(Format-Reading $u)"
            Write-Host "  unpaced  quiet   : $(Format-Reading $unpaced.Quiet)"
            Assert ($u.captures -ge 8) `
                "unpaced: captures rode the hero's frames through the gesture ($($u.captures), floor 8) - the A/B arm is real"
            Assert ($u.intervals -ge 30) "unpaced: the hero pane redrew continuously too ($($u.intervals) intervals)"
            if ($g) {
                Write-Host ('  T1423 before/after (hero frames during a gesture): p95 {0:N1} -> {1:N1} ms, p99 {2:N1} -> {3:N1} ms, max {4:N1} -> {5:N1} ms, long {6} -> {7}, captures {8} -> {9}' -f
                    ($u.p95_us / 1000.0), ($g.p95_us / 1000.0), ($u.p99_us / 1000.0), ($g.p99_us / 1000.0),
                    ($u.max_us / 1000.0), ($g.max_us / 1000.0), $u.long, $g.long, $u.captures, $g.captures)
            }
        }
    }
} catch {
    # T1511: the foreground-leak checks below are part of this run, so this try
    # scores its own throw rather than ending in Complete-TestBody.
    $script:fail++
    Write-Host "FAIL  the run threw and did not finish its sections: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Remove-Item Env:GHOZTTY_HERO_SNAP_UNPACED -ErrorAction SilentlyContinue
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @(@($script:launched) + @(Get-TestLaunchedPids) | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039/T1511: before the stamp
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-pacing -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'FRAME-PACING'
