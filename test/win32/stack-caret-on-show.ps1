# T2127 acceptance: stashing the focused pane of a row collapsed by hand never
# hands the caret to a strip, so no strip comes back out.
#
# THE CLAIM. A close already chose its next pane with `PaneStackState.paneOnShow`
# (T2083), and trash-kill and a viewer's Ctrl+W are closes on Windows. A stash
# was not: it took the neighbour a close would pick, `goto_split:previous`, and
# when that neighbour was a strip of the collapsed row the layout noted it as
# focused and brought it back out - the row unfolded under the user. Mac:
# 2811a3043 ("stash, trash-kill, viewer Cmd-W and window-becomes-key never
# hand the caret to a strip"). Window activation and a stale focus landing on a
# folded strip take the same choice (`Window.caretPaneOnShow`,
# `Window.adoptsFocus`); those are covered by the `none` lane's
# pane_stack_state test "a caret handed back to a folded strip goes to the pane
# on show", since neither can be staged from outside the app.
#
# Layout: P | s1 | s2 | s3 | s4 across an 1800 DIP window, all five on show.
# The s3|s4 divider is dragged left until two panes are on show and released,
# so the row is PINNED (collapsed by hand) with its run at the trailing end.
# Then:
#   A) precondition: s3 and s4 on show, P, s1 and s2 strips
#   B) the caret on s3 (a click; it is on show, so nothing
#      moves). The pane a close or stash picks after s3 is s2, a strip
#   C) +stash s3: no strip comes on show, and the caret lands on s4 - the
#      other pane on show - not on s2
#
# -NegativeControl inverts claim C to "a strip came on show when the focused
# pane was stashed" - the answer before T2127 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stack-caret-on-show.ps1
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
$root = Join-Path $env:TEMP "ghoztty-stack-caret-on-show-$PID"

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

$appArgs = @('--config-default-files=false', '--session-persistence=false',
    "--macos-pane-style=$PaneStyle")

function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

# A stashed pane keeps its (hidden) window and its leaf; it is neither on show
# nor a strip, so it is left out of both lists by window and by name.
function Get-Panes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $script:stashedHwnds -notcontains $_.Hwnd } | Sort-Object Left)
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
            if ($script:stashedNames -notcontains $n) {
                [void]$out.Add([pscustomobject]@{ Name = $n; Id = [string]$node.terminal.id; Focused = [bool]$node.terminal.focused })
            }
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
# slot's place (pane-stack-strip.ps1's mapping).
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
function Wait-Until([scriptblock]$Probe, [int]$Seconds = 6) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackcaret$PID"
$script:stashedHwnds = @()
$script:stashedNames = @()

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
        Say 'NEGATIVE CONTROL: claim C is inverted to "a strip came on show when the focused pane was stashed" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2 | s3 | s4 at 1800 DIP -------------------------------
    Say '== setup: P | s1 | s2 | s3 | s4, 1800 DIP wide'
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
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Px 1800) -Height (Px 700))
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
    Start-Sleep -Milliseconds 1000
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; tree order: {1}; panes: {2}" -f $dpi, ((Get-Leaves | ForEach-Object Name) -join ', '), (Format-Cols $all))

    # ---- collapse by hand: drag the s3|s4 divider left to two on show --------
    Say '== drag the s3|s4 divider left until two panes are on show, and release'
    $v = @(Get-VisiblePanes $top)
    if ($v.Count -ne 5) { Write-TestAssertedNothing -Reason "not all five panes on show before the drag ($($v.Count))" }
    $gridLeft = $all[0].Left
    $x = [int](($v[3].Right + $v[4].Left) / 2)
    $y = [int](($v[3].Top + $v[3].Bottom) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    # Small steps, so the fold that leaves two on show is the one released on.
    $step = [int](Px 10)
    $limit = $gridLeft + [int](Px 20)
    $moves = 0
    while ($x - $step -ge $limit) {
        $x -= $step
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
    Assert (($shownA -join ',') -eq 's3,s4') "A: s3 and s4 on show after the drag ($($shownA -join ','))"
    Assert (($tuckedA -join ',') -eq 'P,s1,s2') "A: P, s1, s2 folded into strips ($($tuckedA -join ','))"
    if (($shownA -join ',') -ne 's3,s4') { Write-TestAssertedNothing -Reason 'the drag never left s3 and s4 on show' }

    # ---- B: the caret on s3, whose predecessor is the strip s2 ---------------
    Say '== B: the caret on s3'
    $lead = 's3'
    $prev = 's2'
    $other = 's4'
    # A click in s3 (on show) moves only the caret.
    $sL = (Get-Named $top)[$lead]
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sL.Hwnd) -X ([int](($sL.Left + $sL.Right) / 2)) -Y ([int](($sL.Top + $sL.Bottom) / 2)) -Button left -Action click)
    $fLead = Wait-Focused $lead
    Start-Sleep -Milliseconds 700
    Assert ($fLead -eq $lead) "B: $lead holds the caret before the stash ('$fLead')"
    $tuckedBefore = @(Get-TuckedNames $top)
    Assert (($tuckedBefore -join ',') -eq 'P,s1,s2') "B: focusing a pane on show moved no strip ($($tuckedBefore -join ','))"

    # ---- C: stash the focused pane ----------------------------------------------
    Say "== C: +stash $lead"
    $leadHwnd = (Get-Named $top)[$lead].Hwnd
    & $exe +stash --target=$lead 2>&1 | Out-Null
    $script:stashedHwnds = @($leadHwnd)
    $script:stashedNames = @($lead)
    [void](Wait-Until { -not (Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $_.Hwnd -eq $leadHwnd -and $_.Visible }) } 8)
    $hidden =-not (Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $_.Hwnd -eq $leadHwnd -and $_.Visible })
    Assert $hidden "C: $lead's window left the screen"
    Start-Sleep -Milliseconds 1200
    $shownC = @(Get-ShownNames $top)
    $tuckedC = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}; panes: {2}" -f ($shownC -join ', '), ($tuckedC -join ', '), (Format-Cols (Get-Panes $top)))
    if ($NegativeControl) {
        Assert ($tuckedC.Count -lt $tuckedBefore.Count) "NEGATIVE: a strip came on show when $lead was stashed (strips: $($tuckedC -join ','))"
    } else {
        Assert (($tuckedC -join ',') -eq ($tuckedBefore -join ',')) "C: every strip is still a strip after the stash ($($tuckedC -join ','))"
    }
    $fC = Wait-Focused $other
    Assert ($fC -eq $other) "C: the caret landed on $other, the other pane on show ('$fC')"
    Assert ($fC -ne $prev) "C: the caret did not land on the strip before $lead ('$fC')"
    Assert ($shownC -contains $fC) "C: the focused pane is on show ('$fC')"

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
        update -Guard stack-caret-on-show -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2127 STACK CARET ON SHOW' -Pass $script:pass -Fail $script:fail
