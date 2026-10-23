# T2187 acceptance: unfolding a folded pane SLIDES it into view - nothing
# covers it on the way in.
#
# THE CLAIM. T2102 slid the cards when a stack's run changed, and held every
# pane that changes size at its OLD size until the slide ended (so no terminal
# is resized mid-slide). When a fold comes undone the run GROWS: the pane
# beside the returning one shrinks to make room, and held at its old, wider
# size it lay over the returning pane's whole path. Pane windows clip their
# siblings, so the returning pane was hidden for the entire slide and appeared
# in one frame at the end - the user's "the expand is instant, not smooth like
# on mac". Mac gives a shrinking card its new size at once and holds only its
# content (`PaneCardView.apply`); Windows now cuts the held pane window to its
# new card with a window region for the slide.
#
# Layout: P | s1 | s2 across a 1500 DIP window; the root divider is dragged
# right and released past the fold point, so s2 folds into a strip at the
# row's right edge (the stack-collapse-drag.ps1 gesture). The slide is
# stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`) so the sampler sees it.
#
# Claims, after a click on s2's strip:
#   U1) s2 is seen at two or more positions strictly between its strip and its
#       slot: it slides
#   U2) in every sample with s2 on show mid-slide, the strip of s2 just inside
#       its leading edge is covered by NO other pane: no other pane window
#       holds that point inside its region (a window with no region is all
#       region). And there were such samples to judge.
#   U3) it settles: three on show, s2 among them
#
# -NegativeControl judges U2 by the pane WINDOWS alone, ignoring their
# regions - the pre-T2187 answer, where a held pane showed all of itself - and
# MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-unfold.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-unfold-$PID"
$slideMs = 2000

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

# Move the held pointer to screen x in a few steps, then settle.
function Move-To([IntPtr]$top, [int]$fromX, [int]$toX, [int]$y) {
    $steps = 6
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($fromX + ($toX - $fromX) * $i / $steps)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 400
}

# Whether pane window $q shows screen point ($x, $y): inside its rect and,
# when it has a region, inside that. -NegativeControl ignores the region.
function Test-Shows($q, [int]$x, [int]$y) {
    if ($x -lt $q.Left -or $x -ge $q.Right -or $y -lt $q.Top -or $y -ge $q.Bottom) { return $false }
    if ($NegativeControl) { return $true }
    $hits = Get-TestWindowRegionHits -Window ([IntPtr]$q.Hwnd) -Points @(($x - $q.Left), ($y - $q.Top))
    if ($null -eq $hits) { return $true }
    return [bool]$hits[0]
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_PIPE_SUFFIX = "-stackunfold$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"

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
        Say 'NEGATIVE CONTROL: U2 is judged by the pane windows alone (regions ignored) - this run MUST fail'
    }

    # ---- setup: P | s1 | s2, then fold s2 ------------------------------------
    Say "== setup: P | s1 | s2, 1500 DIP wide, slide $slideMs ms"
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count))" }
    Start-Sleep -Milliseconds 600
    $c3 = @(Get-VisiblePanes $top)
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c3))
    $s2 = $c3[2]
    $gridLeft = $c3[0].Left
    $gridW = $c3[2].Right - $c3[0].Left
    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    $xFold = [int]($gridLeft + $gridW * 1000 / 1500)

    Say '== fold s2: drag the root divider past the fold point and release'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    Move-To $top $x0 $xFold $y
    [void](Send-TestMouse -Window $top -Target $top -X $xFold -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds ($slideMs + 800)
    $folded = @(Get-Panes $top)
    Say ("      folded: {0}" -f (Format-Cols $folded))
    $me = @($folded | Where-Object { $_.Hwnd -eq $s2.Hwnd })
    if ($me.Count -ne 1 -or $me[0].Visible -or @($folded | Where-Object Visible).Count -ne 2) {
        Write-TestAssertedNothing -Reason 's2 never folded into a strip (two on show, s2 hidden)'
    }
    $p = $me[0]
    $startLeft = $p.Left

    # ---- the click on s2's strip, then sample until the motion is over ------
    Say '== click s2''s strip and watch'
    $minStrip = [int][math]::Floor(8 * $scale)
    [void](Send-TestMouse -Window $top -X ($p.Left + [int]($minStrip / 2)) -Y $y)
    $samples = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt ($slideMs + 1200)) {
        $snap = @(Get-Panes $top)
        # Judge the cover NOW, while the regions are the ones of this frame.
        $mine = @($snap | Where-Object { $_.Hwnd -eq $p.Hwnd })
        $covered = $null
        if ($mine.Count -eq 1 -and $mine[0].Visible) {
            $px = $mine[0].Left + (Get-TestChromeDip -Dip 4 -Scale $scale)
            $covered = @($snap | Where-Object { $_.Hwnd -ne $p.Hwnd -and $_.Visible -and (Test-Shows $_ $px $y) }).Count -gt 0
        }
        $samples.Add([pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Panes = $snap; Covered = $covered })
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 300
    $after = @(Get-Panes $top)
    $meAfter = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })
    $endLeft = if ($meAfter.Count -eq 1) { $meAfter[0].Left } else { $startLeft }
    Say ("      {0} samples; s2 went {1} -> {2}; settled: {3}" -f $samples.Count, $startLeft, $endLeft, (Format-Cols $after))

    # ---- U1: it slid --------------------------------------------------------
    $lo = [math]::Min($startLeft, $endLeft)
    $hi = [math]::Max($startLeft, $endLeft)
    $between = @{}
    $judged = 0
    $coveredAt = @()
    foreach ($s in $samples) {
        $q = @($s.Panes | Where-Object { $_.Hwnd -eq $p.Hwnd })
        if ($q.Count -ne 1 -or -not $q[0].Visible) { continue }
        if ($q[0].Left -le $lo -or $q[0].Left -ge $hi) { continue }
        $between[[int]$q[0].Left] = $true
        $judged++
        if ($s.Covered) { $coveredAt += "$($s.Ms)ms@$($q[0].Left)" }
    }
    Say ("      positions strictly between: {0}" -f (($between.Keys | Sort-Object) -join ', '))
    Assert ($hi - $lo -gt (Get-TestChromeDip -Dip 40 -Scale $scale)) "U1: s2 moves a real distance ($lo..$hi px)"
    Assert ($between.Count -ge 2) "U1: s2 is seen at $($between.Count) positions on the way (need 2+): it slides"

    # ---- U2: nothing covers it on the way -----------------------------------
    if ($coveredAt.Count -gt 0) { Say ("      covered at: {0}" -f ($coveredAt -join ', ')) }
    Assert ($judged -ge 2) "U2: precondition - $judged mid-slide samples to judge (need 2+)"
    Assert ($judged -ge 2 -and $coveredAt.Count -eq 0) "U2: no other pane covers s2's leading edge in any of $judged mid-slide samples ($($coveredAt.Count) covered)"

    # ---- U3: settled --------------------------------------------------------
    $shown = @($after | Where-Object Visible)
    Assert ($shown.Count -eq 3) "U3: three on show after the unfold ($($shown.Count))"
    Assert ($meAfter.Count -eq 1 -and $meAfter[0].Visible) 'U3: s2 is on show'

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
        update -Guard pane-stack-unfold -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2187 PANE STACK UNFOLD' -Pass $script:pass -Fail $script:fail
