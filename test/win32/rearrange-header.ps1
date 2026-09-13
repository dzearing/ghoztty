# T1530 acceptance: every pane grows a HEADER while rearrange mode is on, and
# the header takes real layout space at the top of the pane.
#
# THE DEFECT. T1524 gave the win32 app the mode itself: the action is handled,
# the tab strip comes up because it is a drop target. What the mode is FOR is
# still invisible - a user turns it on and nothing about the panes changes, so
# there is no grip to grab and nothing that says which pane is about to move.
# Mac (b18ee2d77) grows a 24pt band at the very top of every pane: a drag grip,
# the pane title, and a pop-out button. T1530 is that band.
#
# ORACLE. Geometry, not pixels - the same choice rearrange-mode-action.ps1 and
# hero-mode.ps1 make, and here it is the STRONGER oracle rather than the cheap
# one: Mac's header takes real layout space above the terminal ("which is why
# entering the mode resizes every terminal in the window"), so a header that
# exists is a pane child window whose top moved DOWN and whose height shrank by
# the same number. A band merely painted over the terminal - the bug this shape
# would hide - moves nothing, and reads here as a failure.
#
# The strip is pinned UP for the whole run (`--window-show-tab-bar=always`), so
# the chrome above the panes never moves and every pixel of movement measured
# below belongs to the header. That is the deliberate difference from
# rearrange-mode-action.ps1, which pins the strip DOWN to measure the strip.
#
# Four claims:
#   A) entering the mode moves EVERY pane down, by the same amount
#   B) the amount is the 24 DIP band at this monitor's scale, not some number
#   C) each pane keeps its width and loses exactly the header off its height
#   D) Escape leaves the mode and every pane goes back where it was
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1530 regression.
#
# -NegativeControl inverts claim A to "the panes do not move" - the pre-T1530
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-header.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rhdr$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-header-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Every terminal leaf of the top window, in the window's CLIENT coordinates,
# ordered top-down so the same pane is index 0 in every sample.
#
# Unary comma on the return: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null.
function Get-PaneBoxes([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    $all = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd
                Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
                Width = $_.Width; Height = $_.Height
            }
        })
    return , @($all | Sort-Object Top)
}

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "the panes do not move" - this run MUST fail'
    }

    # Mandatory per launch (T158): a persisted session would restore the last
    # run's panes over the ones this script builds itself.
    #
    # `window-show-tab-bar=always` is this oracle's baseline: the strip is UP
    # whatever the mode does, so it can never contribute a pixel to the
    # movement measured below.
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--session-persistence=false',
            '--window-show-tab-bar=always',
            '--keybind=ctrl+shift+f9=toggle_rearrange_mode')
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    $appPid = [int]$app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top window not found'
    }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
        'GUI is NOT enumerable on the interactive desktop'

    # Two panes, stacked, so the claim "EVERY pane grows one" has more than one
    # pane to be true of - and so the lower pane proves the band is per-pane
    # rather than one strip under the chrome.
    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 1200
    $before = Get-PaneBoxes $top
    Assert ($before.Count -eq 2) "setup: two terminal panes (got $($before.Count))"
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }

    # The band Mac states in points, at this monitor's scale - the number
    # claim B checks the measured movement against.
    $dpi = Get-TestWindowDpi -Window $top
    $expected = [int][math]::Round(24.0 * ($dpi / 96.0))
    Write-Host "      monitor dpi = $dpi, expected header band = $expected px"
    foreach ($p in $before) { Write-Host "      before: top=$($p.Top) h=$($p.Height) w=$($p.Width)" }

    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without this a "no header" verdict cannot be told from dead
    # input.
    $haveLog = (Test-Path $errlog)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1530 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # --- Enter the mode -----------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Assert $r 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash on entering the mode'

    $during = Get-PaneBoxes $top
    Assert ($during.Count -eq 2) "both panes stay visible in the mode (got $($during.Count))"
    if ($during.Count -ne 2) { Write-TestAssertedNothing -Reason 'a pane vanished on entering the mode' }
    foreach ($p in $during) { Write-Host "      during: top=$($p.Top) h=$($p.Height) w=$($p.Width)" }

    # --- Claim A: every pane moved down, by the same amount -----------------
    $deltas = @()
    for ($i = 0; $i -lt 2; $i++) { $deltas += ($during[$i].Top - $before[$i].Top) }
    if ($NegativeControl) {
        Assert (($deltas | Where-Object { $_ -ne 0 }).Count -eq 0) `
            'NEGATIVE: no pane moved (pre-T1530 behavior)'
    } else {
        Assert (($deltas | Where-Object { $_ -le 0 }).Count -eq 0) `
            "A: EVERY pane moved down for its own header - deltas $($deltas -join ', ') px"
        Assert (($deltas | Select-Object -Unique).Count -eq 1) `
            "A: by the SAME amount, so one pane did not get a taller band than another"
    }

    # --- Claim B: the amount is the 24 DIP band -----------------------------
    # +-1 px of tolerance, and no more: the band is computed by rounding 24 DIP
    # once, so a number that is merely "close" is a different band.
    $d0 = [int]$deltas[0]
    Assert ([math]::Abs($d0 - $expected) -le 1) `
        "B: the band is the 24 DIP header - measured $d0 px, expected $expected px"

    # --- Claim C: the header comes out of the pane's height, not its width ---
    for ($i = 0; $i -lt 2; $i++) {
        Assert ($during[$i].Width -eq $before[$i].Width) `
            "C: pane $i keeps its width ($($before[$i].Width) px)"
        $lost = $before[$i].Height - $during[$i].Height
        Assert ([math]::Abs($lost - $d0) -le 1) `
            "C: pane $i lost exactly the band off its height ($lost px)"
    }

    # --- Claim D: Escape leaves, and the panes go back -----------------------
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Key Escape
    Assert $r 'D: Escape delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D: no crash on Escape'
    # Polled, not sampled once: leaving the mode is a relayout, and the app
    # places its panes on its own message loop's schedule. A single read 1.5s
    # later caught a window mid-relayout on one run in three and reported a
    # correct app as broken. The assertion is unchanged - the rects must be
    # EXACTLY the ones the run started with - only the deadline is generous.
    $after = @()
    $back = $false
    for ($t = 0; $t -lt 25 -and -not $back; $t++) {
        $after = Get-PaneBoxes $top
        if ($after.Count -eq 2) {
            $back = $true
            for ($i = 0; $i -lt 2; $i++) {
                if ($after[$i].Top -ne $before[$i].Top) { $back = $false }
                if ($after[$i].Height -ne $before[$i].Height) { $back = $false }
            }
        }
        if (-not $back) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($after.Count -eq 2) "D: both panes still there (got $($after.Count))"
    foreach ($p in $after) { Write-Host "      after:  top=$($p.Top) h=$($p.Height) w=$($p.Width)" }
    Assert $back 'D: Escape left the mode - every pane is back where it started'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # Remove-TestDesktop does the killing, not a Stop-Process here: it reads the
    # corpses for the postmortem FIRST and marks the pids it is about to kill as
    # ours, so a deliberate teardown is not reported as `CRASHED - 0xFFFFFFFF`.
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been checked against the code as it now stands?". Never
# under -NegativeControl: that run is red on purpose.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard rearrange-header -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1530 REARRANGE PANE HEADER' -Pass $script:pass -Fail $script:fail
