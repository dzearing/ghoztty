# T2119 acceptance: a row collapsed by hand stays collapsed across a tree
# change - a pane on show closed, the close undone, a pane on show split - and
# the caret never lands on a strip.
#
# THE CLAIM. T2083 carries a collapse over a change in the window's rows
# (`PaneStackState.rowsDidChange` from `noteRows` at layout time) and puts the
# caret after a close on a pane on show (`paneOnShow`); T2126 saves the stack
# state with a parked pane so undo brings the row back as it was. Both landed
# with unit tests only, because Windows could not collapse a row by hand until
# T2124 wired the divider drag. Mac: 2811a3043.
#
# Layout: P | s1 | s2 | s3 | s4 across a 1500 DIP window. The P|s1 divider is
# dragged right until two panes are on show and released, so the row is
# PINNED (collapsed by hand), not merely too narrow. Then:
#   A) precondition: two on show (P, s1), three strips (s2, s3, s4)
#   B) +close s1 (it has the caret): s2, s3, s4 are still strips - nothing
#      unfolds into the space s1 left - and the caret is on P, a pane on show
#   C) ctrl+shift+z: s1 is back on show and every pane's window is where it
#      was before the close, strips included
#   D) +split P right: the new pane is on show and s2, s3, s4 are still strips
#   E) T2142: P, on show, dragged by its rearrange header onto the middle of
#      s2's strip swaps with it and stays folded there: P and s2 trade tree
#      places, P is a strip, s2 is on show and has the caret, and as many
#      panes are strips as before (Mac `aPaneDroppedOnAStripTakesItsPlace`)
#
# -NegativeControl inverts claim B to "a strip came on show when s1 closed" -
# the answer before T2083, when a close re-laid the row out from scratch - and
# MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stack-collapse-carry.ps1
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
$root = Join-Path $env:TEMP "ghoztty-stack-collapse-carry-$PID"

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

# A long undo, so a slow box cannot run it out between B and C.
$appArgs = @('--config-default-files=false', '--session-persistence=false', '--undo-timeout=60s',
    "--macos-pane-style=$PaneStyle",
    # E drags a pane on show by its rearrange header (T1531's chord).
    '--keybind=ctrl+shift+f9=toggle_rearrange_mode')

function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-Panes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $script:parked -notcontains $_.Hwnd } | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
}
function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
# Every leaf of the selected tab, left to right (tree order): name, id, focus.
function Get-Leaves {
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $n = [string]$node.terminal.name
            if (-not $n -or $n -eq [string]$node.terminal.id) { $n = 'P' }
            [void]$out.Add([pscustomobject]@{ Name = $n; Id = [string]$node.terminal.id; Focused = [bool]$node.terminal.focused })
            return
        }
        & $walk $node.left
        & $walk $node.right
    }
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if ($tab.selected) { & $walk $tab.splits }
    }
    return $out.ToArray()
}
function Focused-Pane-Name {
    $f = @(Get-Leaves | Where-Object Focused)
    if ($f.Count -eq 0) { return $null }
    return $f[0].Name
}
function Wait-Focused([string]$name, [int]$ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        $f = Focused-Pane-Name
        if ($f -eq $name) { return $f }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return Focused-Pane-Name
}

# The panes by name: tree order is left to right, and a tucked card keeps its
# slot's place (pane-stack-strip.ps1's mapping). The names are re-read from
# +list every time, since B-D change the tree.
function Get-Named([IntPtr]$top) {
    $names = @(Get-Leaves | ForEach-Object { $_.Name })
    $all = @(Get-Panes $top)
    $map = @{}
    if ($all.Count -ne $names.Count) {
        Say ("      (+list names {0} panes, the window has {1})" -f $names.Count, $all.Count)
    }
    for ($i = 0; $i -lt $all.Count -and $i -lt $names.Count; $i++) { $map[$names[$i]] = $all[$i] }
    return $map
}
function Get-TuckedNames([IntPtr]$top) {
    $m = Get-Named $top
    return @($m.Keys | Where-Object { -not $m[$_].Visible } | Sort-Object)
}
function Get-ShownNames([IntPtr]$top) {
    $m = Get-Named $top
    return @($m.Keys | Where-Object { $m[$_].Visible } | Sort-Object)
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
function Wait-Until([scriptblock]$Probe, [int]$Seconds = 6) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Every pane's place and visibility, by name: the row "as it was".
function Get-RowShape([IntPtr]$top) {
    $m = Get-Named $top
    return (@($m.Keys | Sort-Object | ForEach-Object {
                $p = $m[$_]
                '{0}={1},{2},{3}{4}' -f $_, $p.Left, $p.Width, $p.Height, $(if ($p.Visible) { '' } else { ',strip' })
            }) -join ' ')
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackcarry$PID"
$script:parked = @()

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
        Say 'NEGATIVE CONTROL: claim B is inverted to "a strip came on show when s1 closed" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2 | s3 | s4 at 1500 DIP -------------------------------
    Say '== setup: P | s1 | s2 | s3 | s4, 1500 DIP wide'
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
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
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Px 1500) -Height (Px 700))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s3 --direction=right --name=s4 | Out-Null
    $ok = Wait-Until { @(Get-Leaves).Count -eq 5 } 15
    if (-not $ok) { Write-TestAssertedNothing -Reason "+list never named five panes ($(@(Get-Leaves).Count))" }
    # A scripted split keeps the caret where it was and is FEATURED until the
    # next change of focus (T2257, Mac 71da9a680): it comes on show ahead of
    # the focused pane where the row has no room. This layout is about the
    # focus history, so the focus moves away and back, as a click would.
    $listed = ((& $exe +list --json 2>$null) -join "`n") | ConvertFrom-Json
    $node = @($listed.data.windows[0].tabs | Where-Object { $_.selected })[0].splits
    while ($null -ne $node -and $node.type -ne 'leaf') { $node = $node.left }
    $firstPane = if ($null -ne $node) { [string]$node.terminal.id } else { '' }
    if (-not $firstPane) { Write-TestAssertedNothing -Reason '+list named no first pane to give the focus back to' }
    $link = 'ghoztty-debug://focus/s1'; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $link = "ghoztty-debug://focus/$firstPane"; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Start-Sleep -Milliseconds 1000
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; tree order: {1}; panes: {2}" -f $dpi, ((Get-Leaves | ForEach-Object Name) -join ', '), (Format-Cols $all))

    # ---- collapse by hand: drag the P|s1 divider right to two on show --------
    Say '== drag the P|s1 divider right until two panes are on show, and release'
    $v = @(Get-VisiblePanes $top)
    if ($v.Count -lt 3) { Write-TestAssertedNothing -Reason "fewer than three panes on show before the drag ($($v.Count))" }
    $gridLeft = $all[0].Left
    $gridRight = ($all | Measure-Object -Property Right -Maximum).Maximum
    $x = [int](($v[0].Right + $v[1].Left) / 2)
    $y = [int](($v[0].Top + $v[0].Bottom) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    # Small steps, so the fold that leaves two on show is the one released on.
    $step = [int](Px 10)
    $limit = $gridRight - [int](Px 20)
    $moves = 0
    while ($x + $step -le $limit) {
        $x += $step
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
        $moves++
        if (($moves % 6) -eq 0) {
            Start-Sleep -Milliseconds 400
            if (@(Get-VisiblePanes $top).Count -le 2) { break }
        }
    }
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 900
    Say ("      released at x={0}; panes: {1}" -f $x, (Format-Cols (Get-Panes $top)))

    # ---- A: the collapsed row ----------------------------------------------------
    $shownA = @(Get-ShownNames $top)
    $tuckedA = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}" -f ($shownA -join ', '), ($tuckedA -join ', '))
    Assert (($shownA -join ',') -eq 'P,s1') "A: P and s1 on show after the drag ($($shownA -join ','))"
    Assert (($tuckedA -join ',') -eq 's2,s3,s4') "A: s2, s3, s4 folded into strips ($($tuckedA -join ','))"
    if (($shownA -join ',') -ne 'P,s1') { Write-TestAssertedNothing -Reason 'the drag never left P and s1 on show' }

    # The caret goes to s1, the pane B closes: its natural successor is a
    # neighbour, and s2 is a strip.
    # A click in s1 (on show) moves only the caret.
    $s1 = (Get-Named $top)['s1']
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$s1.Hwnd) -X ([int](($s1.Left + $s1.Right) / 2)) -Y ([int](($s1.Top + $s1.Bottom) / 2)) -Button left -Action click)
    $fA = Wait-Focused 's1'
    Assert ($fA -eq 's1') "A: s1 holds the caret before the close ('$fA')"
    Start-Sleep -Milliseconds 600
    $before = Get-RowShape $top
    $mBefore = Get-Named $top
    Say "      row before the close: $before"

    # ---- B: close a pane on show -------------------------------------------------
    Say '== B: +close s1'
    $s1Hwnd = $mBefore['s1'].Hwnd
    & $exe +close --target=s1 2>&1 | Out-Null
    $gone = Wait-Until { @(Get-Leaves | Where-Object Name -eq 's1').Count -eq 0 } 8
    Assert $gone 'B: s1 left +list'
    # A parked pane keeps its (hidden) window for the undo; it is not a strip.
    $script:parked = @($s1Hwnd)
    Start-Sleep -Milliseconds 900
    $shownB = @(Get-ShownNames $top)
    $tuckedB = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}; panes: {2}" -f ($shownB -join ', '), ($tuckedB -join ', '), (Format-Cols (Get-Panes $top)))
    if ($NegativeControl) {
        Assert ($tuckedB.Count -lt 3) "NEGATIVE: a strip came on show when s1 closed (strips: $($tuckedB -join ','))"
    } else {
        Assert (($tuckedB -join ',') -eq 's2,s3,s4') "B: s2, s3, s4 are still strips after the close ($($tuckedB -join ','))"
    }
    Assert (($shownB -join ',') -eq 'P') "B: P alone on show, taking s1's space ($($shownB -join ','))"
    $fB = Wait-Focused 'P'
    Assert ($fB -eq 'P') "B: the caret landed on P, a pane on show, not a strip ('$fB')"
    Assert ($shownB -contains $fB) "B: the focused pane is on show ('$fB')"

    # ---- C: undo the close ---------------------------------------------------------
    Say '== C: ctrl+shift+z'
    $hP = (Get-Named $top)['P'].Hwnd
    [void](Focus-TestWindow -Window $top -Child ([IntPtr]$hP))
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl, shift -Key 'Z')
    $back = Wait-Until { @(Get-Leaves | Where-Object Name -eq 's1').Count -eq 1 } 8
    Assert $back 'C: s1 is listed again'
    $script:parked = @()
    Start-Sleep -Milliseconds 1200
    $after = Get-RowShape $top
    Say "      row after the undo:  $after"
    Assert ($after -eq $before) 'C: every pane is back where it was before the close, strips included'
    $shownC = @(Get-ShownNames $top)
    Assert (($shownC -join ',') -eq 'P,s1') "C: P and s1 on show again ($($shownC -join ','))"
    Assert ((@(Get-TuckedNames $top) -join ',') -eq 's2,s3,s4') 'C: s2, s3, s4 are strips again'

    # ---- D: split a pane on show ---------------------------------------------------
    Say '== D: +split P right'
    # The first pane has no name: it is addressed by its id.
    $firstId = (@(Get-Leaves) | Where-Object Name -eq 'P' | Select-Object -First 1).Id
    & $exe +split --pane=$firstId --direction=right --name=n1 2>&1 | Out-Null
    $made = Wait-Until { @(Get-Leaves | Where-Object Name -eq 'n1').Count -eq 1 } 8
    Assert $made 'D: the split made n1'
    Start-Sleep -Milliseconds 1200
    $shownD = @(Get-ShownNames $top)
    $tuckedD = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}; panes: {2}" -f ($shownD -join ', '), ($tuckedD -join ', '), (Format-Cols (Get-Panes $top)))
    Assert ($shownD -contains 'n1') "D: the new pane is on show ($($shownD -join ','))"
    $still = @('s2', 's3', 's4' | Where-Object { $tuckedD -contains $_ })
    Assert ($still.Count -eq 3) "D: s2, s3, s4 are still strips after the split ($($tuckedD -join ','))"
    $fD = Focused-Pane-Name
    Assert ($shownD -contains $fD) "D: the caret is on a pane on show ('$fD')"

    # ---- E: drop a pane on show onto a strip ---------------------------------------
    Say '== E: drag P by its rearrange header onto the middle of s2''s strip'
    $hF = [IntPtr](Get-TestFocusedWindow -Window $top)
    if (-not (Send-TestKeys -Window $top -Target $hF -Modifiers ctrl, shift -Key F9)) {
        Write-TestAssertedNothing -Reason 'the rearrange-mode chord was not delivered'
    }
    Start-Sleep -Milliseconds 1200
    $orderE = @(Get-Leaves | ForEach-Object Name)
    $tuckedE0 = @(Get-TuckedNames $top)
    $mE = Get-Named $top
    $pE = $mE['P']; $s2E = $mE['s2']
    if (-not $pE.Visible -or $s2E.Visible) { Write-TestAssertedNothing -Reason "E needs P on show and s2 a strip (P visible=$($pE.Visible), s2 visible=$($s2E.Visible))" }
    # The header band sits directly above the pane's own window (T1530); a
    # strip is the leading 36 DIP of its tucked card (T2109).
    $gx = $pE.Left + [int](($pE.Right - $pE.Left) / 3)
    $gy = $pE.Top - [int]((Px 24) / 2)
    $sx = $s2E.Left + [int](Px 18)
    $sy = [int](($s2E.Top + $s2E.Bottom) / 2)
    $expectE = @($orderE | ForEach-Object { if ($_ -eq 'P') { 's2' } elseif ($_ -eq 's2') { 'P' } else { $_ } })
    Say ("      tree {0}; header ({1},{2}) -> strip ({3},{4}); expect {5}" -f ($orderE -join ','), $gx, $gy, $sx, $sy, ($expectE -join ','))
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $gy -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 120
    for ($s = 1; $s -le 8; $s++) {
        [void](Send-TestMouse -Window $top -Target $top -X ([int]($gx + ($sx - $gx) * $s / 8)) -Y ([int]($gy + ($sy - $gy) * $s / 8)) -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 150
    [void](Send-TestMouse -Window $top -Target $top -X $sx -Y $sy -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 1200
    $orderE2 = @(Get-Leaves | ForEach-Object Name)
    Assert (($orderE2 -join ',') -eq ($expectE -join ',')) "E: P and s2 traded places (tree $($orderE2 -join ','))"
    $tuckedE = @(Get-TuckedNames $top)
    Say ("      strips: {0}; panes: {1}" -f ($tuckedE -join ', '), (Format-Cols (Get-Panes $top)))
    Assert ($tuckedE -contains 'P') "E: P is folded into s2's place ($($tuckedE -join ','))"
    Assert ($tuckedE -notcontains 's2') "E: s2, which was the strip, is on show ($($tuckedE -join ','))"
    Assert ($tuckedE.Count -eq $tuckedE0.Count) "E: as many strips as before ($($tuckedE.Count) vs $($tuckedE0.Count))"
    $fE = Wait-Focused 's2'
    Assert ($fE -eq 's2') "E: the pane that came out of the strip has the caret ('$fE')"

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
        update -Guard stack-collapse-carry -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2119 STACK COLLAPSE CARRY' -Pass $script:pass -Fail $script:fail
