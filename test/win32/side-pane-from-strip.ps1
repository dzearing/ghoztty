# T2925 acceptance: a side pane split off a strip the user minimized leaves
# the strips minimized.
#
# THE CLAIM. Mac 251a1a1dc (`BaseTerminalController.backgroundSplitAnchor`):
# a split that leaves the caret where it is (an agent's `+split`, a side pane)
# anchored at a pane the user minimized in a collapsed row goes in beside the
# pane on show nearest that anchor. The new pane is FEATURED (T2257) so it
# comes on show, and a row's run is contiguous, so landing beyond a strip it
# pulled that strip - and every strip between it and the run - back out with
# it. Only the user brings a minimized pane back out. The win32 port is
# `Window.backgroundSplitAnchor`, called by `insertPaneAsSplit` when the split
# is in the background.
#
# Layout (stack-collapse-carry.ps1's): P | s1 | s2 | s3 | s4 at 1500 DIP, the
# P|s1 divider dragged right until two panes are on show, so the row is
# PINNED (collapsed by hand) with s2, s3, s4 as strips on the right edge - the
# user's repro, "the manager minimized on the right". Then, from s4 (the far
# strip), without --focus:
#
#   A) +split --direction=right --name=side (a terminal: an agent's +split)
#        A1) +list reports s2, s3, s4 still minimized
#        A2) side is on show
#        A3) the caret has not moved
#   B) +split --view --direction=right --name=view (a viewer side pane)
#        B1) s2, s3, s4 still minimized
#        B2) view is on show
#        B3) the caret has not moved
#
# -NegativeControl inverts A1 to "a strip came back out" - the answer before
# T2925 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\side-pane-from-strip.ps1
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

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-side-pane-from-strip-$PID"

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

$appArgs = @('--config-default-files=false', '--session-persistence=false')

function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
}
function Get-AllPanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
}

# Every leaf of the selected tab, in tree order: name, id, focused, minimized.
function Get-Leaves {
    $out = New-Object System.Collections.ArrayList
    $raw = (& $exe +list --json 2>$null) -join "`n"
    try { $doc = $raw | ConvertFrom-Json } catch { return @() }
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $t = $node.terminal
            $n = [string]$t.name
            if (-not $n -or $n -eq [string]$t.id) { $n = 'P' }
            [void]$out.Add([pscustomobject]@{
                    Name = $n; Id = [string]$t.id
                    Focused = [bool]$t.focused; Minimized = ($t.minimized -eq $true)
                })
            return
        }
        & $walk $node.left
        & $walk $node.right
    }
    foreach ($w in @($doc.data.windows | ForEach-Object { $_ })) {
        foreach ($tab in @($w.tabs | ForEach-Object { $_ })) { if ($tab.selected) { & $walk $tab.splits } }
    }
    return $out.ToArray()
}
function Format-Leaves($leaves) {
    return (($leaves | ForEach-Object {
                "$($_.Name)$(if ($_.Focused) { '*' })$(if ($_.Minimized) { '(min)' })"
            }) -join ' | ')
}
function Minimized-Names($leaves) {
    return (@($leaves | Where-Object Minimized | ForEach-Object Name | Sort-Object) -join ',')
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
$env:GHOZTTY_PIPE_SUFFIX = "-sidestrip$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$script:errlog = Join-Path $root 'app-stderr.log'
$doc = Join-Path $root 'side.md'
Set-Content -Path $doc -Value "# side pane`n`nT2925" -Encoding ascii

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: A1 is inverted to "a strip came back out" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2 | s3 | s4 at 1500 DIP -----------------------------
    Say '== setup: P | s1 | s2 | s3 | s4, 1500 DIP wide'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments $appArgs
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
    # The scripted splits are featured until the next change of focus (T2257):
    # move the focus away and back, as a click would, so the layout is the
    # focus history's.
    $first = @(Get-Leaves)[0]
    $link = 'ghoztty-debug://focus/s1'; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $link = "ghoztty-debug://focus/$($first.Id)"; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1800
    Say ("      dpi {0}; leaves: {1}" -f $dpi, (Format-Leaves @(Get-Leaves)))

    # ---- collapse by hand: drag the P|s1 divider right to two on show --------
    Say '== drag the P|s1 divider right until two panes are on show, and release'
    $all = @(Get-AllPanes $top)
    $v = @(Get-VisiblePanes $top)
    if ($v.Count -lt 3) { Write-TestAssertedNothing -Reason "fewer than three panes on show before the drag ($($v.Count))" }
    $gridRight = ($all | Measure-Object -Property Right -Maximum).Maximum
    $x = [int](($v[0].Right + $v[1].Left) / 2)
    $y = [int](($v[0].Top + $v[0].Bottom) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
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
    Start-Sleep -Milliseconds 1200
    $collapsed = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $collapsed))
    $minimized = Minimized-Names $collapsed
    if ($minimized -ne 's2,s3,s4') {
        Write-TestAssertedNothing -Reason "the drag never left s2, s3, s4 as strips (minimized: '$minimized'; $(Format-Leaves $collapsed))"
    }
    $caret = @($collapsed | Where-Object Focused) | Select-Object -First 1
    if ($null -eq $caret) { Write-TestAssertedNothing -Reason "no pane holds the caret ($(Format-Leaves $collapsed))" }
    Say "      strips: $minimized; caret: $($caret.Name)"

    # ---- A: an agent's +split off the far strip ---------------------------------
    Say '== A: +split off s4 (a strip), right, without --focus'
    $out = (& $exe +split --pane=s4 --direction=right --name=side 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
    Say "      reply: $out"
    $ok = Wait-Until { @(Get-Leaves | Where-Object { $_.Name -eq 'side' }).Count -eq 1 } 10
    Start-Sleep -Milliseconds 1500
    $a = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $a))
    $side = @($a | Where-Object { $_.Name -eq 'side' }) | Select-Object -First 1
    if ($null -eq $side) { Write-TestAssertedNothing -Reason "the side pane never appeared in +list ($out)" }
    $minA = @($a | Where-Object { $_.Minimized -and $_.Name -ne 'side' } | ForEach-Object Name | Sort-Object) -join ','
    if ($NegativeControl) {
        Assert ($minA -ne 's2,s3,s4') "NEGATIVE: a strip came back out (minimized: '$minA')"
    } else {
        Assert ($minA -eq 's2,s3,s4') "A1: s2, s3, s4 stay minimized (minimized: '$minA')"
    }
    Assert (-not $side.Minimized) 'A2: the side pane is on show'
    $fA = @($a | Where-Object Focused) | Select-Object -First 1
    Assert ($null -ne $fA -and $fA.Id -eq $caret.Id) "A3: the caret stays on $($caret.Name) ($(Format-Leaves $a))"

    # ---- B: a viewer side pane off the same strip -------------------------------
    Say '== B: +split --view off s4 (still a strip), right, without --focus'
    $out = (& $exe +split --pane=s4 --direction=right --name=view "--view=$doc" 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
    Say "      reply: $out"
    $ok = Wait-Until { @(Get-Leaves | Where-Object { $_.Name -eq 'view' }).Count -eq 1 } 10
    Start-Sleep -Milliseconds 1500
    $b = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $b))
    $view = @($b | Where-Object { $_.Name -eq 'view' }) | Select-Object -First 1
    if ($null -eq $view) { Write-TestAssertedNothing -Reason "the viewer side pane never appeared in +list ($out)" }
    $minB = @($b | Where-Object { $_.Minimized -and @('s2', 's3', 's4') -contains $_.Name } | ForEach-Object Name | Sort-Object) -join ','
    Assert ($minB -eq 's2,s3,s4') "B1: s2, s3, s4 stay minimized (of them minimized: '$minB')"
    Assert (-not $view.Minimized) 'B2: the viewer side pane is on show'
    $fB = @($b | Where-Object Focused) | Select-Object -First 1
    Assert ($null -ne $fB -and $fB.Id -eq $caret.Id) "B3: the caret stays on $($caret.Name) ($(Format-Leaves $b))"

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
        update -Guard side-pane-from-strip -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2925 SIDE PANE FROM STRIP' -Pass $script:pass -Fail $script:fail
