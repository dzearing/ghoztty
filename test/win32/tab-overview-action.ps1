# T708 acceptance: a bound `toggle_tab_overview` opens the pane overview.
#
# THE DEFECT. App.zig's `.toggle_tab_overview` arm returned true and did
# nothing, so a user who bound the action got silence from every pane while
# the app CLAIMED the chord (T682 made it reachable from a focused viewer too,
# which only widened the silence). Win32 already ships the overview under
# another name: hero mode - a full-window carousel of every pane in the tab
# with the selected one blown up beside it. T708 routes the action there, on
# both seats.
#
# ORACLE. Hero mode is read the way hero-mode.ps1 and hero-viewer-tile.ps1
# read it, off window geometry rather than pixels: hero ON is EXACTLY ONE
# visible leaf, filling ~75% of the client width on the left, with every
# hidden leaf sized to the same rect (T58). Hero OFF is both leaves visible.
# The chord is a CUSTOM keybind (`--keybind=ctrl+shift+f8=toggle_tab_overview`)
# because the action ships with no default binding - which is the user's
# situation exactly, and it also keeps this script from accidentally scoring
# the ctrl+shift+space path that already has coverage.
#
# Three claims:
#   A) from a focused TERMINAL, the chord enters the overview  (App.zig arm)
#   B) pressing it again leaves                                 (it is a TOGGLE)
#   C) from a focused VIEWER, the chord enters the overview too
#      (Window.performViewerBindingAction, the T682 forwarding path - it used
#      to bounce through the App no-op and die there)
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T708 regression.
#
# -NegativeControl inverts claim A to "the chord does nothing" - the pre-T708
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\tab-overview-action.ps1
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
$env:GHOZTTY_PIPE_SUFFIX = "-taboverview$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-tab-overview-action-stderr.log'

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
# coordinates - the viewer leaf matters here, so `GhozttyTerminal` alone (what
# hero-mode.ps1 enumerates) would be blind to half of claim C.
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

# "Is the overview open?" - the geometric reading of hero mode (T58), returned
# as the hero leaf or $null so callers can also say WHICH pane is the hero.
function Get-HeroLeaf([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    $leaves = Get-Leaves $top
    $visible = @($leaves | Where-Object Visible)
    if ($visible.Count -ne 1) { return $null }
    $hero = $visible[0]
    if ($hero.Left -gt 2) { return $null }
    if ($hero.Width -lt [int](0.6 * $c.Width)) { return $null }
    # Every hidden leaf is sized to the hero rect, which is what tells hero
    # mode from a zoom (a zoom leaves the others at their tree rects).
    foreach ($p in @($leaves | Where-Object { -not $_.Visible })) {
        if ($p.Left -ne $hero.Left -or $p.Top -ne $hero.Top -or
            $p.Right -ne $hero.Right -or $p.Bottom -ne $hero.Bottom) { return $null }
    }
    return $hero
}

# The viewed document for claim C. Real markdown so the pane takes the
# file-mode path with zero network.
$md = Join-Path $env:TEMP 'ghoztty-tab-overview-action.md'

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue
Set-Content -Path $md -Encoding ascii -Value @'
# Tab overview fixture

Body text, enough that the viewer pane has something real to render while it
is a tile in the overview.

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
    # run's panes over the two this script builds itself.
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--session-persistence=false',
            '--keybind=ctrl+shift+f8=toggle_tab_overview')
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
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without this a "no overview" verdict cannot be told from dead
    # input.
    $haveLog = (Test-Path $errlog)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T708 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # --- Claim A: the bound action opens the overview -----------------------
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F8
    Assert $r 'A: ctrl+shift+f8 (toggle_tab_overview) delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash on the overview chord'
    $hero = Get-HeroLeaf $top
    if ($NegativeControl) {
        Assert ($null -eq $hero) 'NEGATIVE: the bound action does nothing (pre-T708 behavior)'
    } else {
        Assert ($null -ne $hero) 'A: the overview is OPEN - one visible leaf at the hero rect, the rest hero-sized behind it'
    }
    if ($hero) { Assert ($hero.Kind -eq 'GhozttyTerminal') 'A: the focused terminal is the hero pane' }

    # --- Claim B: it is a toggle -------------------------------------------
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F8
    Assert $r 'B: second ctrl+shift+f8 delivered'
    Start-Sleep -Milliseconds 1500
    $visible = @((Get-Leaves $top) | Where-Object Visible)
    Assert ($visible.Count -eq 2) "B: the overview CLOSED again - both leaves visible (got $($visible.Count))"

    # --- Claim C: the same chord answers from a focused VIEWER --------------
    # The viewer forwarding path (T682) used to route this through the App
    # no-op; a focused viewer therefore swallowed the chord into its page.
    & $exe +split --direction=right "--view=$md" | Out-Null
    Start-Sleep -Seconds 3
    # A viewer chord is injected at the viewer's CHROMIUM input child, not at
    # the GhozttyViewer host: that is the window with the keyboard focus, and
    # the accelerator handler the app registers is Chromium's (hero-nav.ps1
    # arm E has the same recipe).
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

        # POSITIVE CONTROL for this arm: a chord that was ALREADY forwarded
        # and already means something - `toggle_hero_mode` itself - works from
        # this viewer. Without it, a dead subject chord below could be dead
        # injection into Chromium rather than a T708 verdict.
        Assert (Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key Space) `
            'C CONTROL: ctrl+shift+space injected at the viewer'
        Start-Sleep -Milliseconds 1500
        Assert ($null -ne (Get-HeroLeaf $top)) 'C CONTROL: toggle_hero_mode already answers from a focused viewer'
        Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key Space | Out-Null
        Start-Sleep -Milliseconds 1500
        Assert ($null -eq (Get-HeroLeaf $top)) 'C CONTROL: and back out again, so the subject starts from a closed overview'

        Focus-TestWindow -Window $top -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 300
        $r = Send-TestViewerChord -Window $top -Target $chrome -Modifiers ctrl, shift -Key F8
        Assert $r 'C: ctrl+shift+f8 injected at the focused viewer'
        Start-Sleep -Milliseconds 1800
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'C: no crash on the viewer chord'
        $hero = Get-HeroLeaf $top
        Assert ($null -ne $hero) 'C: the overview is OPEN from a focused viewer'
        if ($hero) {
            Assert ($hero.Kind -eq 'GhozttyViewer') 'C: the focused VIEWER is the hero pane'
        }
    }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($appPid -ne 0) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Stop-RepoInstances
    if ($td) { Remove-TestDesktop -Desktop $td }
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
        update -Guard tab-overview-action -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T708 TAB OVERVIEW ACTION' -Pass $script:pass -Fail $script:fail
