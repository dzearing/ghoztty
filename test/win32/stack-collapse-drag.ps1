# T2124/T2263 acceptance: dragging a divider far enough that the panes past
# it no longer fit at their minimums folds the outermost into a strip, going
# on folds the one after it, and dragging back unfolds them in reverse; a
# stack's edge grip is a gutter like any other.
#
# THE CLAIM. Before T2124 the win32 divider drag only ever moved ratios: a
# pane pushed into its 300 DIP minimum stopped there and nothing folded. Mac
# a81db68f9 (T2263) makes every gutter of a row one rule: the row is a
# function of where the gutter is (`pane_stack_layout.dragged`). Its side
# folds its outermost pane as soon as it cannot hold them all at their
# minimums - no 48 DIP threshold any more - and a strip comes out only when
# its own gutter is dragged INTO the run, the other side giving way.
#
# Layout: P | s1 | s2 across a 1500 DIP window (each ~490 DIP). The root
# divider (P's right edge) is dragged right:
#   A) to ~1000 DIP - past 1500 - 600, s2 folds: two panes on show,
#      and the caret, which was in s2, moves to s1 (the pane still on show)
#   B) on to ~1420 DIP - s1 folds too: one pane on show
#   C) back to ~1000 DIP - s1 unfolds: two on show again
#   D) back to the start - s2 unfolds: three on show, P's edge where it began
#   E) dragged to ~1000 DIP and RELEASED: the fold sticks after the drag ends
#   F) the stack's trailing edge grip pushed OUTWARD leaves s2 a strip (the
#      old rule brought it back), and pulled 400 DIP INTO the run brings s2
#      back: three on show again
#
# -NegativeControl inverts claim A to "three panes stay on show" - the
# pre-T2124 answer - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stack-collapse-drag.ps1
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
$root = Join-Path $env:TEMP "ghoztty-stack-collapse-drag-$PID"

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

function Wait-Columns([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}

# The name of the focused pane in +list --json, or '' when none reads focused.
function Get-FocusedPane {
    $raw = (& $exe +list --json 2>$null) -join "`n"
    if (-not $raw) { return '' }
    try { $j = $raw | ConvertFrom-Json } catch { return '' }
    $found = @(Find-FocusedLeaf $j)
    if ($found.Count -gt 0) { return [string]$found[0].name }
    return ''
}

# Pane leaves sit at any depth of a tab's split tree; a leaf is the object
# carrying both `focused` and `tty` (a window carries `focused` too).
function Find-FocusedLeaf($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Array]) { foreach ($n in $node) { Find-FocusedLeaf $n }; return }
    if ($node -isnot [System.Management.Automation.PSCustomObject]) { return }
    $names = @($node.PSObject.Properties | ForEach-Object { $_.Name })
    if (($names -contains 'focused') -and ($names -contains 'tty') -and $node.focused -eq $true) { $node; return }
    foreach ($p in $node.PSObject.Properties) { Find-FocusedLeaf $p.Value }
}

# T2185: the pane popups (the unfocused dim wash is the one that leaked) that
# are on screen but reach outside the window. A folded pane is held at its
# last width, which runs past the window's right edge, and a popup is not
# clipped by the window the way the pane child is.
function Get-StrayPopups([int]$procId, [IntPtr]$top) {
    $w = Get-TestWindowRect -Window $top
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyDimOverlay' | Where-Object {
            $_.Visible -and ($_.Left -lt $w.Left -or $_.Top -lt $w.Top -or $_.Right -gt $w.Right -or $_.Bottom -gt $w.Bottom)
        })
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

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackfold$PID"

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
        Say 'NEGATIVE CONTROL: claim A is inverted to "three panes stay on show" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2 ----------------------------------------------------
    Say '== setup: P | s1 | s2'
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    # --focus: s2 holds the caret, so the fold has to move it (claim A).
    & $exe +split --pane=s1 --direction=right --name=s2 --focus | Out-Null
    $c3 = @(Wait-Columns $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count))" }
    Start-Sleep -Milliseconds 600
    $c3 = @(Get-VisiblePanes $top)
    Say ("      columns: {0}" -f (($c3 | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
    $focus0 = Get-FocusedPane
    Say "      focused before the drag: '$focus0'"

    # The grid's own span on screen: from P's left edge to s2's right edge.
    $gridLeft = $c3[0].Left
    $gridW = $c3[2].Right - $c3[0].Left
    $pRight0 = $c3[0].Right
    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    # Positions as fractions of the grid, so DPI and chrome do not matter:
    # 1000/1500 is past the fold point (~900/1500); 1420/1500 folds s1 too.
    $xFold1 = [int]($gridLeft + $gridW * 1000 / 1500)
    $xFold2 = [int]($gridLeft + $gridW * 1420 / 1500)

    # ---- A-D: one drag out and back ------------------------------------------
    Say '== drag the root divider right, on, and back'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    Move-To $top $x0 $xFold1 $y
    $a = @(Get-VisiblePanes $top)
    $focusA = Get-FocusedPane
    Say ("      at fold 1: {0} on show ({1}); focused '{2}'" -f $a.Count, (($a | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '), $focusA)
    if ($NegativeControl) {
        Assert ($a.Count -eq 3) "NEGATIVE: three panes stay on show past the minimum (got $($a.Count))"
    } else {
        Assert ($a.Count -eq 2) "A: past the trailing minimum, s2 folds - two panes on show (got $($a.Count))"
    }
    # The last split made s2 the focused pane; it is the one that folds.
    Assert ($focus0 -eq 's2') "A: precondition - s2 had the caret before the drag ('$focus0')"
    Assert ($focusA -eq 's1') "A: the caret left the folded pane for s1, the nearest on show ('$focusA')"
    $strayA = @(Get-StrayPopups $app.Pid $top)
    Assert ($strayA.Count -eq 0) ("A: no pane popup reaches outside the window while folded (T2185; got {0}: {1})" -f $strayA.Count, (($strayA | ForEach-Object { "$($_.Class) $($_.Left)-$($_.Right)" }) -join ' | '))

    Move-To $top $xFold1 $xFold2 $y
    $b = @(Get-VisiblePanes $top)
    Say "      at fold 2: $($b.Count) on show"
    Assert ($b.Count -eq 1) "B: going on, s1 folds too - one pane on show (got $($b.Count))"

    Move-To $top $xFold2 $xFold1 $y
    $c = @(Get-VisiblePanes $top)
    Say "      back at fold 1: $($c.Count) on show"
    Assert ($c.Count -eq 2) "C: coming back, s1 unfolds first - two on show (got $($c.Count))"

    Move-To $top $xFold1 $x0 $y
    $d = @(Get-VisiblePanes $top)
    Say ("      back at the start: {0} on show ({1})" -f $d.Count, (($d | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
    Assert ($d.Count -eq 3) "D: all the way back, s2 unfolds - three on show (got $($d.Count))"
    if ($d.Count -eq 3) {
        Assert ([math]::Abs($d[0].Right - $pRight0) -le 2) "D: P's edge is back where the drag began ($($d[0].Right) vs $pRight0)"
    }
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 400

    # ---- E: a fold sticks after the drag ends ---------------------------------
    Say '== drag to fold 1 and release'
    $now = @(Get-VisiblePanes $top)
    $x0 = [int](($now[0].Right + $now[1].Left) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    Move-To $top $x0 $xFold1 $y
    [void](Send-TestMouse -Window $top -Target $top -X $xFold1 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 800
    $e = @(Get-VisiblePanes $top)
    Say ("      after release: {0} on show ({1})" -f $e.Count, (($e | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
    Assert ($e.Count -eq 2) "E: the fold sticks once the drag is released - two on show (got $($e.Count))"
    # The caret is in s1, so the folded s2 is unfocused: its wash is the one
    # that used to land past the window's right edge, over the desktop.
    $strayE = @(Get-StrayPopups $app.Pid $top)
    Assert ($strayE.Count -eq 0) ("E: no pane popup reaches outside the window after the release (T2185; got {0}: {1})" -f $strayE.Count, (($strayE | ForEach-Object { "$($_.Class) $($_.Left)-$($_.Right)" }) -join ' | '))

    # ---- F: the edge grip is a gutter like any other (T2263) -------------------
    if ($e.Count -eq 2) {
        # The grip sits in the gutter just past the last card on show.
        $gx = $e[1].Right + [math]::Max(1, (Get-TestChromeDip -Dip 1 -Scale $scale))
        Say '== push the run''s trailing edge grip outward'
        # Outward only squeezes s2's side further: it stays a strip. Under the
        # old rule (Mac 2811a3043) this pull past 48 DIP brought s2 back.
        $push = Get-TestChromeDip -Dip 100 -Scale $scale
        [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $y -Action down -HoldMs 0)
        Start-Sleep -Milliseconds 150
        Move-To $top $gx ($gx + $push) $y
        [void](Send-TestMouse -Window $top -Target $top -X ($gx + $push) -Y $y -Action up -HoldMs 0)
        Start-Sleep -Milliseconds 800
        $f0 = @(Get-VisiblePanes $top)
        Say "      after the outward push: $($f0.Count) on show"
        Assert ($f0.Count -eq 2) "F: the edge grip pushed outward leaves s2 a strip - two on show (got $($f0.Count))"

        Say '== pull the run''s trailing edge grip into the run'
        # Into the run, past where s2 fits at its minimum (about 1200/1500):
        # the strip comes out, the panes before it giving way.
        $now = @(Get-VisiblePanes $top)
        if ($now.Count -eq 2) { $gx = $now[1].Right + [math]::Max(1, (Get-TestChromeDip -Dip 1 -Scale $scale)) }
        $pull = Get-TestChromeDip -Dip 400 -Scale $scale
        [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $y -Action down -HoldMs 0)
        Start-Sleep -Milliseconds 150
        Move-To $top $gx ($gx - $pull) $y
        [void](Send-TestMouse -Window $top -Target $top -X ($gx - $pull) -Y $y -Action up -HoldMs 0)
        Start-Sleep -Milliseconds 800
        $f = @(Get-VisiblePanes $top)
        Say ("      after the grip pull: {0} on show ({1})" -f $f.Count, (($f | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
        Assert ($f.Count -eq 3) "F: the edge grip pulled into the run brings s2 back - three on show (got $($f.Count))"
    } else {
        Assert $false 'F: not reached (E left the wrong number of panes)'
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
        update -Guard stack-collapse-drag -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2124 STACK COLLAPSE DRAG' -Pass $script:pass -Fail $script:fail
