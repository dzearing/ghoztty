# T2328 acceptance: a strip holds still while another pane collapses onto the
# stack (T2312, Mac 760272563 `aStripStaysPutWhenAnotherCollapsesOntoIt`).
#
# THE CLAIM. A pane collapsing onto a stack lands between the run and the strip
# that was nearest it. That strip gains its reach under the newcomer
# (`pane_stack_layout.Metrics.blade_tuck`, 12 DIP) - but only once the glide is
# over: until then it is held at the length it had, by its OUTER edge
# (`pane_stack_slide.Slide.shownStrip`, `Window.shownStripTab`). Reaching out
# at once put 12 DIP of its band in the gutter ahead of the arriving card.
#
# Layout: P | (s1 | (s2 | s3)) at 1500 DIP, four on show. Per side:
#   trailing - drag the s2|s3 divider right until s3 folds into a strip, then
#              the s1|s2 divider right until s2 folds onto it;
#   leading  - drag the P|s1 divider left until P folds, then the s1|s2
#              divider left until s1 folds onto it.
# The glide is stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`). Mac samples the
# first strip's `placedTab` every 4 ms; the Windows translation reads the debug
# build's `stack strip shown` oracle (`Window.logShownStrips`), which logs on
# every glide tick where each strip is drawn and where the layout has it.
#
# Claims, per side:
#   H0) setup: the first pane folds into a strip, then the second folds too
#   H1) mid-glide, while the layout has already given the first strip its
#       reach (the laid tab is longer than it was - at least one such tick),
#       the first strip's OUTER edge never moves and it never shows longer
#       than it did before the collapse: none of its band is in the gutter
#       ahead of the arriving card
#   H2) once the glide has landed, the first strip reaches 12 DIP under the
#       newcomer (the T2283 layout) from the same outer edge
#
# -NegativeControl runs the app with GHOZTTY_TEST_NO_STRIP_HOLD=1 (debug build
# only: no strip is held, the answer before T2312) and keeps H1 as written: it
# MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-strip-hold.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [ValidateSet('flat', 'elevated')][string]$PaneStyle = 'flat',
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-pane-stack-strip-hold-$PID"
$script:errlog = $null
$slideMs = 2000
$minDip = 225

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle")

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errlog
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

function Get-Panes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}
function Get-LogLength { return @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue).Count }

# Press at screen x0, move to x1 in steps, release, and wait for the glide the
# fold started to land: the oracle's `when=settled` line after the release.
function Drag-Divider([IntPtr]$top, [int]$x0, [int]$x1, [int]$y) {
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150  # settle: the press must be taken as a divider grab before the first move arrives
    $steps = 8
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($x0 + ($x1 - $x0) * $i / $steps)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 300  # settle: the last move must lay out (and fold) before the release ends the drag
    $mark = Get-LogLength
    [void](Send-TestMouse -Window $top -Target $top -X $x1 -Y $y -Action up -HoldMs 0)
    $deadline = (Get-Date).AddMilliseconds($slideMs * 4 + 5000)
    do {
        $landed = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $mark |
                Where-Object { $_ -match 'stack strip shown when=settled' }).Count -gt 0
        if ($landed) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
}

# The `stack strip shown` oracle lines (Window.logShownStrips) for pane
# window $hwnd, from log line $from on.
function Get-Shown([int]$from, [int64]$hwnd) {
    $hex = '{0:x}' -f $hwnd
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'stack strip shown when=(\w+) hwnd=([0-9a-f]+) leads=(\w+) left=(-?\d+) top=(-?\d+) right=(-?\d+) bottom=(-?\d+) laid_left=(-?\d+) laid_right=(-?\d+)') {
            if ($Matches[2] -ne $hex) { continue }
            $out += [pscustomobject]@{
                When = $Matches[1]; Leads = ($Matches[3] -eq 'true')
                Left = [int]$Matches[4]; Right = [int]$Matches[6]
                LaidLeft = [int]$Matches[8]; LaidRight = [int]$Matches[9]
            }
        }
    }
    return $out
}

# One side: a fresh app, four on show, two collapses. Asserts H0-H2.
function Test-Side([string]$side) {
    $leading = $side -eq 'leading'
    $script:errlog = Join-Path $root "app-stderr-$side.log"
    Say "== $side`: P | s1 | s2 | s3 at 1500 DIP, slide $slideMs ms"
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Start-Sleep -Milliseconds 800  # settle: the first DPI reading after the window opens can still change; the loop below confirms it
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    [void](Wait-Shown $top 1)
    & $exe +split --direction=right --name=s1 | Out-Null
    [void](Wait-Shown $top 2)
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    [void](Wait-Shown $top 3)
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c = @(Wait-Shown $top 4)
    if ($c.Count -ne 4) { Write-TestAssertedNothing -Reason "$side`: four panes never came up on show (got $($c.Count))" }
    # Four on show and the same columns twice running: the splits have laid out.
    $deadline = (Get-Date).AddSeconds(10)
    $was = ''
    do {
        Start-Sleep -Milliseconds 300
        $c = @(Get-VisiblePanes $top)
        $now = Format-Cols $c
        if ($c.Count -eq 4 -and $now -eq $was) { break }
        $was = $now
    } while ((Get-Date) -lt $deadline)
    $y = [int](($c[0].Top + $c[0].Bottom) / 2)
    $off = Get-TestChromeDip -Dip 100 -Scale $scale
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c))

    # The first collapse: the outer pane folds into a strip.
    $first = if ($leading) { $c[0] } else { $c[3] }
    if ($leading) { $x0 = [int](($c[0].Right + $c[1].Left) / 2); $x1 = [int]($c[0].Left + $off) }
    else { $x0 = [int](($c[2].Right + $c[3].Left) / 2); $x1 = [int]($c[3].Right - $off) }
    Say "      fold the $side pane: drag $x0 -> $x1"
    Drag-Divider $top $x0 $x1 $y
    $v = @(Get-VisiblePanes $top)
    $me = @(Get-Panes $top | Where-Object { $_.Hwnd -eq $first.Hwnd })
    Say ("      after the first fold: {0}" -f (Format-Cols (Get-Panes $top)))
    Assert ($me.Count -eq 1 -and -not $me[0].Visible -and $v.Count -eq 3) "H0 $side`: the first pane folds into a strip, three on show ($($v.Count))"
    $settled0 = @(Get-Shown 0 ([int64]$first.Hwnd) | Where-Object { $_.When -eq 'settled' })
    if ($v.Count -ne 3 -or $settled0.Count -eq 0) {
        Assert $false "H0 $side`: the first strip's settled place is logged ($($settled0.Count) lines)"
        foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
        Stop-RepoInstances
        return
    }
    $before = $settled0[-1]
    $beforeLen = $before.Right - $before.Left
    $outer0 = if ($leading) { $before.Left } else { $before.Right }
    Say ("      first strip settled at {0}-{1} ({2} px)" -f $before.Left, $before.Right, $beforeLen)

    # The second collapse: the pane beside it folds onto the stack.
    $second = if ($leading) { $v[0] } else { $v[2] }
    if ($leading) { $x0 = [int](($v[0].Right + $v[1].Left) / 2); $x1 = [int]($v[0].Left + $off) }
    else { $x0 = [int](($v[1].Right + $v[2].Left) / 2); $x1 = [int]($v[2].Right - $off) }
    $mark = Get-LogLength
    Say "      fold the next pane onto it: drag $x0 -> $x1"
    Drag-Divider $top $x0 $x1 $y
    $after = @(Get-Panes $top)
    $me2 = @($after | Where-Object { $_.Hwnd -eq $second.Hwnd })
    Say ("      after the second fold: {0}" -f (Format-Cols $after))
    Assert ($me2.Count -eq 1 -and -not $me2[0].Visible -and @($after | Where-Object Visible).Count -eq 2) "H0 $side`: the second pane folds onto the stack, two on show"

    $rows = @(Get-Shown $mark ([int64]$first.Hwnd))
    $glide = @($rows | Where-Object { $_.When -eq 'glide' })
    $reaching = @($glide | Where-Object { ($_.LaidRight - $_.LaidLeft) -gt $beforeLen + 1 })
    $moved = @($reaching | Where-Object { $o = if ($leading) { $_.Left } else { $_.Right }; [math]::Abs($o - $outer0) -gt 0 })
    $longer = @($reaching | Where-Object { ($_.Right - $_.Left) -gt $beforeLen })
    $shownSet = @($reaching | ForEach-Object { "$($_.Left)-$($_.Right)" } | Sort-Object -Unique)
    Say ("      {0} glide ticks for the first strip, {1} with the layout's reach given; shown at {2}" -f $glide.Count, $reaching.Count, ($shownSet -join ', '))
    if ($reaching.Count -gt 0) { Say ("      laid at {0}-{1}" -f $reaching[-1].LaidLeft, $reaching[-1].LaidRight) }
    Assert ($reaching.Count -ge 1) "H1 $side`: precondition - the layout gave the first strip its reach mid-glide on $($reaching.Count) ticks (need 1+)"
    Assert ($reaching.Count -ge 1 -and $moved.Count -eq 0) "H1 $side`: the first strip's outer edge stays at $outer0 on every tick ($($moved.Count) of $($reaching.Count) moved)"
    Assert ($reaching.Count -ge 1 -and $longer.Count -eq 0) "H1 $side`: no more of it shows than the $beforeLen px it showed before ($($longer.Count) of $($reaching.Count) ticks longer)"

    $settled = @($rows | Where-Object { $_.When -eq 'settled' })
    if ($settled.Count -eq 0) {
        Assert $false "H2 $side`: the glide landed and logged the first strip's place"
    } else {
        $s = $settled[-1]
        $len = $s.Right - $s.Left
        $tuck = Get-TestChromeDip -Dip 12 -Scale $scale
        $outer = if ($leading) { $s.Left } else { $s.Right }
        Say ("      first strip landed at {0}-{1} ({2} px; reach {3} px)" -f $s.Left, $s.Right, $len, ($len - $beforeLen))
        Assert ([math]::Abs(($len - $beforeLen) - $tuck) -le 1 -and $outer -eq $outer0) "H2 $side`: landed, it reaches 12 DIP ($tuck px) under the newcomer from the same outer edge (+$($len - $beforeLen) px, edge $outer)"
    }
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Stop-RepoInstances
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$savedNoHold = $env:GHOZTTY_TEST_NO_STRIP_HOLD
$env:GHOZTTY_PIPE_SUFFIX = "-striphold$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"
if ($NegativeControl) { $env:GHOZTTY_TEST_NO_STRIP_HOLD = '1' }
else { Remove-Item env:GHOZTTY_TEST_NO_STRIP_HOLD -ErrorAction SilentlyContinue }

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: GHOZTTY_TEST_NO_STRIP_HOLD=1 (no strip is held) - H1 MUST fail'
    }
    Test-Side 'trailing'
    Test-Side 'leading'
    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($null -ne $savedSlide) { $env:GHOZTTY_STACK_SLIDE_MS = $savedSlide }
    else { Remove-Item env:GHOZTTY_STACK_SLIDE_MS -ErrorAction SilentlyContinue }
    if ($null -ne $savedNoHold) { $env:GHOZTTY_TEST_NO_STRIP_HOLD = $savedNoHold }
    else { Remove-Item env:GHOZTTY_TEST_NO_STRIP_HOLD -ErrorAction SilentlyContinue }
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl -and $PaneStyle -eq 'flat') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-stack-strip-hold -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2328 PANE STACK STRIP HOLD' -Pass $script:pass -Fail $script:fail
