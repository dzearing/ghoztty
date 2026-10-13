# T1839 acceptance: dragging a divider beside a STASHED pane holds every
# other visible divider where it was, and leaves the stashed pane's slot alone.
#
# THE CLAIM. A divider drag pins every other boundary to its absolute pixel
# (T533, `split_resize.plan`). Since T1827 a split whose side is all stashed is
# laid out COLLAPSED - the visible side takes the whole range - but the drag
# used to solve against the full tree, as if the stashed pane still took room.
# So the visible nested divider slid under a pointer that never touched it, and
# the hidden split's ratio was re-planned, moving the slot the stashed pane
# returns to. T1839 snapshots the collapsed split as a pass-through.
#
# Layout: P, then `+split right` -> s1, then off s1 -> s2, then off s2 -> s3:
# P | (s1 | (s2 | s3)). Stash s1: on screen that reads P | s2 | s3, and the
# s2|s3 divider lives inside a split the stash collapsed.
#
# Claims:
#   A) after the stash, three panes are on screen in three columns
#   B) dragging the ROOT divider (P's right edge) out and back moves P's edge
#      and holds s3's left edge - the visible nested divider - within 1px at
#      every sampled tick
#   C) +restore puts s1 back at the same share of the right-hand region it had
#      before the stash: the collapsed split's ratio was not re-planned
#
# -NegativeControl inverts claim B to "s3's edge moved during the drag" - the
# answer the full-tree solve gives - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stash-divider-drag.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    # Flat by default, the style with the thinnest band. The solver uses the
    # flat band in both styles; -PaneStyle elevated measured the same 1px hold
    # on 2026-10-12 (T1888), so that run does not stamp the guard but is
    # expected to pass too.
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
$root = Join-Path $env:TEMP "ghoztty-stash-divider-drag-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', "--macos-pane-style=$PaneStyle")

function Start-App {
    # persistence: on (default) - harmless here (a throwaway $env:LOCALAPPDATA)
    # and it keeps the panes on agent sessions, the shape users run.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
}

# Wait until exactly `$n` pane HWNDs are visible, side by side.
function Wait-Columns([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}

# s1's share of the right-hand region (s1's left edge to the last pane's right
# edge) - the quantity the collapsed split's ratio decides.
function Get-S1Share($cols) {
    $region = $cols[$cols.Count - 1].Right - $cols[1].Left
    if ($region -le 0) { return -1 }
    return ($cols[1].Right - $cols[1].Left) / [double]$region
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stashdrag$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
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
        Say 'NEGATIVE CONTROL: claim B is inverted to "s3''s edge moved during the drag" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) -----------------------------------------
    Say '== setup: P | (s1 | (s2 | s3))'
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    # A window wide enough that four columns are all well clear of the clamp.
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width 1600 -Height 700)
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Columns $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four columns never came up (got $($c4.Count))" }
    Start-Sleep -Milliseconds 600
    $c4 = @(Get-VisiblePanes $top)
    $shareBefore = Get-S1Share $c4
    Say ("      columns: {0}" -f (($c4 | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))

    # ---- A: stash s1 -----------------------------------------------------------
    Say '== stash s1'
    & $exe +stash --target=s1 | Out-Null
    $c3 = @(Wait-Columns $top 3)
    Assert ($c3.Count -eq 3) "A: three panes on screen after stashing s1 (got $($c3.Count))"
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason 'the stash never collapsed to three columns' }
    Start-Sleep -Milliseconds 500
    $c3 = @(Get-VisiblePanes $top)
    Say ("      columns: {0}" -f (($c3 | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
    $pRight0 = $c3[0].Right
    $s3Left0 = $c3[2].Left

    # ---- B: drag the root divider out and back ---------------------------------
    Say '== drag the root divider (P | s2) out and back'
    # SCREEN coordinates; Send-TestMouse converts per target (drag-perf.ps1).
    $x = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    $samples = New-Object System.Collections.ArrayList
    $steps = 16
    for ($i = 1; $i -le $steps; $i++) {
        $dx = if ($i -le ($steps / 2)) { $i * 15 } else { ($steps - $i) * 15 }
        [void](Send-TestMouse -Window $top -Target $top -X ($x + $dx) -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 90
        $now = @(Get-VisiblePanes $top)
        if ($now.Count -eq 3) {
            [void]$samples.Add([pscustomobject]@{ Dx = $dx; PRight = $now[0].Right; S3Left = $now[2].Left })
        }
    }
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 400

    $maxP = 0; $maxS3 = 0
    foreach ($s in $samples) {
        $maxP = [math]::Max($maxP, [math]::Abs($s.PRight - $pRight0))
        $maxS3 = [math]::Max($maxS3, [math]::Abs($s.S3Left - $s3Left0))
    }
    Say ("      {0} ticks sampled; P edge moved up to {1}px, s3 edge up to {2}px" -f $samples.Count, $maxP, $maxS3)
    Say ("      ticks (dx:P/s3): {0}" -f (($samples | ForEach-Object { "$($_.Dx):$($_.PRight - $pRight0)/$($_.S3Left - $s3Left0)" }) -join ' '))
    Assert ($samples.Count -ge ($steps - 2)) "B: the drag was sampled at nearly every tick ($($samples.Count) of $steps)"
    Assert ($maxP -ge 60) "B: the drag actually moved the root divider ($maxP px) - the positive control"
    if ($NegativeControl) {
        Assert ($maxS3 -gt 1) "NEGATIVE: s3's edge moved during the drag ($maxS3 px)"
    } else {
        Assert ($maxS3 -le 1) "B: s3's edge (the visible nested divider) held within 1px through the drag ($maxS3 px)"
    }

    # ---- C: restore s1 into its old slot ---------------------------------------
    Say '== restore s1'
    & $exe +restore --target=s1 | Out-Null
    $c4b = @(Wait-Columns $top 4)
    Assert ($c4b.Count -eq 4) "C: four columns after +restore (got $($c4b.Count))"
    if ($c4b.Count -eq 4) {
        Start-Sleep -Milliseconds 500
        $c4b = @(Get-VisiblePanes $top)
        $shareAfter = Get-S1Share $c4b
        Say ("      s1 share of the right region: before {0:N3}, after {1:N3}" -f $shareBefore, $shareAfter)
        Assert ($shareBefore -gt 0.1 -and [math]::Abs($shareAfter - $shareBefore) -le 0.02) `
            'C: s1 came back at the share of the right region it left at (its split was not re-planned)'
    }

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

if ($script:fail -eq 0 -and -not $NegativeControl -and $PaneStyle -eq 'flat') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard stash-divider-drag -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T1839 STASH DIVIDER DRAG' -Pass $script:pass -Fail $script:fail
