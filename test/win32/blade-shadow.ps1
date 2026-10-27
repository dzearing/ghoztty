# T2307 acceptance: each tucked pane's strip casts a blade shadow on the next
# strip out - leaning away from the run - so a stack of strips reads as blades
# laid over one another rather than one flat bar.
#
# THE CLAIM. Mac (5a9a2e2a4, afc64dc53) gives every strip a tight, strong
# shadow (radius 5, 60% black on a dark theme) offset 3 pt AWAY from the run,
# cut to the strip's own sides. Until T2307 the Windows desk laid the bands
# with no shadow at all, so two strips side by side were one undivided colour.
# `PaneDesk.paint` now casts `blade_shadow.paint` before each band, bottom
# first, so it lands on the band already down beside it.
#
# Layout: P | (s1 | (s2 | s3)) at 680 DIP in the elevated style (glass off),
# focus on P: two on show, s2 and s3 tucked into strips to the right of the
# run - s2 beside the run, s3 outside it.
#
# Claims:
#   B1) the inner strip's own face is the plain strip colour: its shadow is
#       not laid over itself
#   B2) on the outer strip, just past the inner strip's edge, the colour is
#       clearly darker than the outer strip's own face further out: the inner
#       strip's shadow lands on it (the measured edge sits where the inner
#       strip's visible 36 DIP end)
#   B3) the outer strip's face further out is the plain strip colour again:
#       a tight blade shadow, not a wash over the whole strip
#
# Held by the blade_shadow / pane_elevation unit tests instead: the lean's
# direction on its own (the gutter on the run side of the inner strip also
# carries the run card's drop shadow, so a pixel there cannot tell the two
# apart), and the mid-glide half - the shadow fading in with the collapse,
# the card's own fading out - since a glide is a quarter-second animation
# this harness cannot hold still.
#
# -NegativeControl inverts B2 to "the outer strip is NOT darker beside the
# inner one" - the answer before T2307 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\blade-shadow.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

# A window with room for two of the four panes at the 225 DIP minimum, not
# three (pane-stack-grid.ps1 claim B), and the strip's thickness (Mac
# `PaneLayout.Metrics.peek`).
$narrowDip = 680
$peekDip = 36

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-blade-shadow-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false', '--macos-pane-style=elevated', '--macos-pane-glass=false')

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
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

# The strip colour over the default background (#282c34): the pane's own
# background at 65% under the card's 45% black scrim, 82% strip over that
# (`pane_stack_strip.stripRgb`; pane-stack-strip.ps1's Get-ExpectedStrip).
function Get-ExpectedStrip([int[]]$bg) {
    $aw = [MidpointRounding]::AwayFromZero
    return @($bg | ForEach-Object {
        $base = [math]::Round($_ * 0.65, $aw)
        $under = [math]::Round($_ * 0.55, $aw)
        [int][math]::Round($under * 0.18 + $base * 0.82, $aw)
    })
}
function Test-Near($c, [int[]]$rgb, [int]$tol) {
    if ($null -eq $c) { return $false }
    return ([math]::Abs($c.R - $rgb[0]) -le $tol -and [math]::Abs($c.G - $rgb[1]) -le $tol -and [math]::Abs($c.B - $rgb[2]) -le $tol)
}
function Get-Sum($c) { if ($null -eq $c) { return -1 }; return [int]$c.R + [int]$c.G + [int]$c.B }
function Format-Rgb($c) {
    if ($null -eq $c) { return 'off-capture' }
    return 'rgb({0},{1},{2})' -f $c.R, $c.G, $c.B
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-bladeshadow$PID"

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
        Say 'NEGATIVE CONTROL: B2 is inverted to "the outer strip is NOT darker beside the inner one" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at 680 DIP ------------------------------
    Say "== setup: P | (s1 | (s2 | s3)), $narrowDip DIP wide, elevated"
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    # Two DPI readings in a row must agree (pane-stack-grid.ps1's reason).
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $script:scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show (got $($c4.Count))" }
    # A scripted split is featured until the next change of focus (T2257);
    # move the focus away and back to P so the run is P's.
    $listed = ((& $exe +list --json 2>$null) -join "`n") | ConvertFrom-Json
    $node = @($listed.data.windows[0].tabs | Where-Object { $_.selected })[0].splits
    while ($null -ne $node -and $node.type -ne 'leaf') { $node = $node.left }
    $firstPane = if ($null -ne $node) { [string]$node.terminal.id } else { '' }
    if (-not $firstPane) { Write-TestAssertedNothing -Reason '+list named no first pane to give the focus back to' }
    $link = 'ghoztty-debug://focus/s1'; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $link = "ghoztty-debug://focus/$firstPane"; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800

    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $narrowDip -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Milliseconds 800
    $shown = @(Wait-Shown $top 2)
    # Past the glide (a quarter second), so every strip is at rest.
    Start-Sleep -Milliseconds 1200
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; panes: {1}" -f $dpi, (Format-Cols $all))
    if ($shown.Count -ne 2 -or $all.Count -ne 4) { Write-TestAssertedNothing -Reason "the $narrowDip DIP row never settled on two on show of four (got $($shown.Count) of $($all.Count))" }
    $run = @($all | Where-Object Visible)
    $tucked = @($all | Where-Object { -not $_.Visible } | Sort-Object Left)
    $runRight = ($run | Measure-Object -Property Right -Maximum).Maximum
    if ($tucked.Count -ne 2 -or $tucked[0].Left -lt $runRight) {
        Write-TestAssertedNothing -Reason "expected two strips to the right of the run (run ends at $runRight; tucked at $(Format-Cols $tucked))"
    }
    $inner = $tucked[0]

    # ---- B: the row across both strips -----------------------------------------
    $expected = Get-ExpectedStrip @(0x28, 0x2c, 0x34)
    $peek = (Px ($peekDip))
    # Well below the strips' rounded top corners and well above their names,
    # which are centred down their length.
    $y = $inner.Top + (Px (40))
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        # Read the row from just inside the run's right edge out to the
        # window's right edge, for the log.
        $prof = @()
        $x = $runRight - (Px (4))
        $stop = $tucked[1].Left + (Px (3 * $peekDip))
        for (; $x -lt $stop; $x += [math]::Max(1, (Px (2)))) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            if ($null -eq $c) { break }
            $prof += "{0}:{1}" -f $x, (Get-Sum $c)
        }
        Say ("      row y={0} (x:R+G+B): {1}" -f $y, ($prof -join ' '))
        Say ("      expected strip rgb({0}) = {1}" -f ($expected -join ','), (($expected | Measure-Object -Sum).Sum))

        # B1: the inner strip's own face, from past its leading curve to its
        # middle, is the plain strip colour.
        $faceX = $inner.Left + (Px ($peekDip / 2))
        $face = Get-TestPixel -Shot $shot -X $faceX -Y $y
        Assert (Test-Near $face $expected 4) ("B1: the inner strip's face at x={0} is the plain strip colour rgb({1}) (got {2})" -f $faceX, ($expected -join ','), (Format-Rgb $face))

        # Its outer edge: the first pixel past the middle that is no longer
        # the strip colour.
        $edge = $faceX
        while ($edge -lt $stop -and (Test-Near (Get-TestPixel -Shot $shot -X $edge -Y $y) $expected 3)) { $edge++ }
        $edgeOff = $edge - $inner.Left
        Say ("      inner strip's colour ends at x={0}, {1} px from its left ({2:N1} DIP; the peek is {3} px)" -f $edge, $edgeOff, ($edgeOff / $script:scale), $peek)

        # B2: just past it, on the outer strip: darker than the outer face.
        $near = Get-TestPixel -Shot $shot -X ($edge + (Px (1))) -Y $y
        $farX = $edge + (Px (20))
        $far = Get-TestPixel -Shot $shot -X $farX -Y $y
        $drop = (Get-Sum $far) - (Get-Sum $near)
        Say ("      outer strip beside the inner one {0}, its own face at x={1} {2}: {3} levels darker" -f (Format-Rgb $near), $farX, (Format-Rgb $far), $drop)
        if ($NegativeControl) {
            Assert ($drop -lt 12) "NEGATIVE: the outer strip is NOT darker beside the inner one ($drop levels)"
        } else {
            Assert ([math]::Abs($edgeOff - $peek) -le [int][math]::Ceiling(3 * $script:scale)) "B2: the colour change sits at the inner strip's visible end ($edgeOff px vs the $peek px peek)"
            Assert ($drop -ge 12) "B2: the outer strip is clearly darker beside the inner one - its shadow lands there ($drop levels across R+G+B, at least 12)"
        }

        # B3: and the outer strip's face further out is plain strip again.
        Assert (Test-Near $far $expected 4) ("B3: the outer strip's face at x={0} is the plain strip colour (got {1}) - a tight shadow, not a wash" -f $farX, (Format-Rgb $far))
    } finally { Close-TestWindowPixels -Shot $shot }

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

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard blade-shadow -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2307 BLADE SHADOW' -Pass $script:pass -Fail $script:fail
