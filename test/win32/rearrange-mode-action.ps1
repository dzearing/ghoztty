# T1524 acceptance: a bound `toggle_rearrange_mode` puts the window IN the
# mode, and the tab strip appears because it is a drop target.
#
# THE DEFECT. `origin/main` (b18ee2d77) added `toggle_rearrange_mode` to the
# shared core - the action, the palette entry, the default chord. The win32
# frontend had no arm for it, so the command sat in the palette and the menu
# doing nothing: the app claimed the chord from every pane and showed the user
# silence. T1524 is the plumbing half - the mode itself, and the one behavior
# the action's own doc comment names: the tab strip is forced visible while
# the mode is on, because that is where you drop a pane to move it to another
# tab. The pane headers and the drag are T1525.
#
# ORACLE. Geometry, not pixels, for the same reason hero-mode.ps1 uses it: the
# strip occupies real client space, so a pane's TOP in client coordinates sits
# lower by the bar height while the strip is up. The app is launched with
# `--window-show-tab-bar=never`, which is the setting that hides the strip
# unconditionally - so a strip that appears can only have come from the mode,
# and the "it goes back" claim has an exact number to return to.
#
# Three claims:
#   A) from a focused TERMINAL, the chord enters the mode and the strip appears
#   B) pressing it again leaves, and the strip goes back where it was
#   C) from a focused VIEWER, the chord answers too
#      (Window.performViewerBindingAction, the T682 forwarding path)
#
# The chord is a CUSTOM keybind (`--keybind=ctrl+shift+f9=...`) rather than the
# shipped ctrl+shift+period: this script is scoring the ACTION, and the default
# binding's existence is held by a unit test in `src/config/Config.zig` so the
# two questions cannot be confused for one another.
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1524 regression.
#
# -NegativeControl inverts claim A to "the chord does nothing" - the pre-T1524
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-mode-action.ps1
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
# Isolate the IPC endpoint: the app inherits this through CreateProcessW and so
# does every `& $exe +...` below, so the user's own instance is never touched.
$env:GHOZTTY_PIPE_SUFFIX = "-rearrange$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-mode-action-stderr.log'

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

# Every leaf of the active tab, both kinds, in the top window's CLIENT
# coordinates. The viewer leaf matters for claim C, so `GhozttyTerminal` alone
# would be blind to half of it.
#
# Unary comma on the return: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null.
function Get-Leaves([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    $all = @()
    foreach ($cls in @('GhozttyTerminal', 'GhozttyViewer')) {
        $all += @(Get-TestChildWindows -Window $top -Class $cls | ForEach-Object {
            [pscustomobject]@{
                Hwnd = $_.Hwnd; Kind = $cls; Visible = $_.Visible
                Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
                Right = $_.Right - $c.Left; Bottom = $_.Bottom - $c.Top
                Width = $_.Width; Height = $_.Height
            }
        })
    }
    return , @($all)
}

# The top edge of the highest visible leaf, in client coordinates. That is the
# bottom of the chrome, and the strip is the part of the chrome this test
# moves. $null when there are no visible leaves at all (a state every caller
# below treats as "could not read it", not as a verdict).
function Get-ContentTop([IntPtr]$top) {
    $visible = @((Get-Leaves $top) | Where-Object Visible)
    if ($visible.Count -eq 0) { return $null }
    return ([int](($visible | Measure-Object -Property Top -Minimum).Minimum))
}

# The viewed document for claim C. Real markdown so the pane takes the
# file-mode path with zero network.
$md = Join-Path $env:TEMP 'ghoztty-rearrange-mode-action.md'

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue
Set-Content -Path $md -Encoding ascii -Value @'
# Rearrange fixture

Body text, enough that the viewer pane has something real to render while the
window is in rearrange mode.

- first bullet
- second bullet
'@

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "the chord does nothing" - this run MUST fail'
    }

    # Mandatory per launch (T158): a persisted session would restore the last
    # run's panes over the ones this script builds itself.
    #
    # `window-show-tab-bar=never` is the oracle's baseline: the strip is hidden
    # whatever the tab count, so anything that raises it came from the mode.
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--session-persistence=false',
            '--window-show-tab-bar=never',
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

    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 1200
    $terms = @((Get-Leaves $top) | Where-Object { $_.Kind -eq 'GhozttyTerminal' })
    Assert ($terms.Count -eq 2) "setup: two terminal leaves (got $($terms.Count))"
    if ($terms.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }

    $baseline = Get-ContentTop $top
    if ($null -eq $baseline) { Write-TestAssertedNothing -Reason 'no visible leaf to measure the chrome against' }
    Write-Host "      baseline content top = $baseline px (strip hidden by window-show-tab-bar=never)"
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without this a "no mode" verdict cannot be told from dead
    # input.
    $haveLog = (Test-Path $errlog)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1524 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # --- Claim A: the bound action enters the mode --------------------------
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Assert $r 'A: ctrl+shift+f9 (toggle_rearrange_mode) delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash on the rearrange chord'
    $inMode = Get-ContentTop $top
    Assert ($null -ne $inMode) 'A: the panes are still readable after the chord'
    if ($NegativeControl) {
        Assert ($inMode -eq $baseline) 'NEGATIVE: the bound action does nothing (pre-T1524 behavior)'
    } else {
        Assert ($null -ne $inMode -and $inMode -gt $baseline) `
            "A: the tab strip is UP - content top moved $baseline -> $inMode px"
    }
    # Both panes are still there: the mode rearranges panes, it does not hide
    # any of them (that is hero mode, and the two are exclusive).
    $visible = @((Get-Leaves $top) | Where-Object Visible)
    Assert ($visible.Count -eq 2) "A: both panes stay visible in the mode (got $($visible.Count))"

    # --- Claim B: it is a toggle -------------------------------------------
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Assert $r 'B: second ctrl+shift+f9 delivered'
    Start-Sleep -Milliseconds 1500
    $after = Get-ContentTop $top
    Assert ($after -eq $baseline) `
        "B: the strip went back to what the config asked for - content top $after px (baseline $baseline)"

    # --- Claim C: the same chord answers from a focused VIEWER --------------
    & $exe +split --direction=right "--view=$md" | Out-Null
    Start-Sleep -Seconds 3
    # A viewer chord is injected at the viewer's CHROMIUM input child, not at
    # the GhozttyViewer host: that is the window with the keyboard focus, and
    # the accelerator handler the app registers is Chromium's.
    $chrome = [IntPtr]::Zero
    $viewHost = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
        foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
            $widget = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*' |
                Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
            if ($widget.Count -ge 1) {
                $chrome = [IntPtr][int64]$widget[0].Hwnd
                $viewHost = [IntPtr][int64]$h.Hwnd
            }
        }
        if ($chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($chrome -ne [IntPtr]::Zero) 'C setup: the viewer leaf and its Chromium input child are up'
    if ($chrome -ne [IntPtr]::Zero) {
        Focus-TestWindow -Window $top -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 400
        $preC = Get-ContentTop $top

        # POSITIVE CONTROL for this arm: a chord that was ALREADY forwarded
        # and already means something - toggle_hero_mode - answers from this
        # viewer. Without it, a dead subject chord below could be dead
        # injection into Chromium rather than a T1524 verdict.
        Assert (Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key Space) `
            'C CONTROL: ctrl+shift+space injected at the viewer'
        Start-Sleep -Milliseconds 1500
        Assert (@((Get-Leaves $top) | Where-Object Visible).Count -eq 1) `
            'C CONTROL: toggle_hero_mode already answers from a focused viewer'
        Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key Space | Out-Null
        Start-Sleep -Milliseconds 1500
        Assert (@((Get-Leaves $top) | Where-Object Visible).Count -eq 3) `
            'C CONTROL: and back out again, so the subject starts from a plain window'

        Focus-TestWindow -Window $top -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 300
        $r = Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key F9
        Assert $r 'C: ctrl+shift+f9 injected at the focused viewer'
        Start-Sleep -Milliseconds 1800
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'C: no crash on the viewer chord'
        $inModeC = Get-ContentTop $top
        Assert ($null -ne $inModeC -and $null -ne $preC -and $inModeC -gt $preC) `
            "C: the mode answers from a focused viewer - content top moved $preC -> $inModeC px"
    }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # Remove-TestDesktop does the killing, not a Stop-Process here: it reads the
    # corpses for the postmortem FIRST and marks the pids it is about to kill as
    # ours, so a deliberate teardown is not reported as `CRASHED - 0xFFFFFFFF`.
    # Killing $appPid by hand ahead of it produced exactly that false verdict on
    # an all-green run, which is the kind of noise that trains a reader to skip
    # the block that exists to catch a real crash.
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
    Remove-Item $md -Force -ErrorAction SilentlyContinue
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
        update -Guard rearrange-mode-action -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1524 REARRANGE MODE ACTION' -Pass $script:pass -Fail $script:fail
