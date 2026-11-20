# T3280 acceptance: a click in a viewer on show never brings out a viewer
# folded into a strip beside it.
#
# THE CLAIM. Mac 084136b2f: every viewer's mouse monitor claimed a click by
# its bounds alone, and a viewer minimized into a blade stays mounted at full
# size under the pane on show, so a click in that pane (a link, any text)
# focused the blade, and focusing a blade brings it out. On Windows a strip's
# pane is a HIDDEN child window - it is not under the pane on show at all, so
# the OS delivers a click to the window it lands on and the strip never sees
# it. This script is the outside-in proof, with clicks posted straight into
# the shown viewer's Chromium input window (what a real click reaches; the
# split-dim-viewer.ps1 2c precedent).
#
# Layout: P | s2 | v1 | w3 | s4 across an 1800 DIP window; v1 and w3 viewers
# of HTML pages (w3's has a big link and plain text). The w3|s4 divider is
# dragged left until two panes are on show, so v1 - the leading blade right
# beside w3 - folds into a strip. Then:
#   A) precondition: w3 and s4 on show, P, s2 and v1 strips
#   B) the caret on s4 (a click; it is on show, so nothing moves)
#   C) a click on w3's LINK: w3 takes the caret (the click really landed) and
#      every strip stays a strip, sampled for 2 s after
#   D) the caret back on s4, then a click on w3's plain TEXT: same
#
# -NegativeControl inverts claim C to "a strip came on show after the link
# click" and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\blade-click-neighbour.ps1
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
$root = Join-Path $env:TEMP "ghoztty-blade-click-$PID"

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

# Terminals and viewers, left to right. A tucked card keeps its slot's place.
function Get-Panes([IntPtr]$top) {
    $all = @()
    foreach ($cls in @('GhozttyTerminal', 'GhozttyViewer')) {
        $all += @(Get-TestChildWindows -Window $top -Class $cls)
    }
    return @($all | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
}
function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
# Every leaf of the selected tab, left to right (tree order): name, focus.
function Get-Leaves {
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $n = [string]$node.terminal.name
            if (-not $n -or $n -eq [string]$node.terminal.id) { $n = 'P' }
            [void]$out.Add([pscustomobject]@{ Name = $n; Focused = [bool]$node.terminal.focused })
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
# Sample the strips several times over a window: a strip that comes out for a
# moment and folds again is still the defect.
function Watch-Strips([IntPtr]$top, [string[]]$expect, [int]$Seconds) {
    $seen = @()
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $t = (@(Get-TuckedNames $top) -join ',')
        if ($t -ne ($expect -join ',')) { $seen += $t }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return , @($seen | Select-Object -Unique)
}
# The Chromium window a real click into the viewer lands on: RenderWidgetHost,
# else WidgetWin_1 (split-dim-viewer.ps1 2c, T1809).
function Find-ChromeInput([IntPtr]$viewHwnd) {
    for ($t = 0; $t -lt 50; $t++) {
        $kids = @(Get-TestChildWindows -Window $viewHwnd -Class '*')
        $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_RenderWidgetHostHWND' })
        if ($widget.Count -lt 1) { $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' }) }
        if ($widget.Count -ge 1) { return [IntPtr][int64]$widget[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}
# A click at the pane's horizontal middle, $fy of the way down it.
function Click-Pane([IntPtr]$top, $pane, [IntPtr]$target, [double]$fy = 0.5) {
    $x = [int](($pane.Left + $pane.Right) / 2)
    $y = [int]($pane.Top + ($pane.Bottom - $pane.Top) * $fy)
    [void](Send-TestMouse -Window $top -Target $target -X $x -Y $y -Button left -Action click)
}

function Write-Page([string]$path, [string]$body) {
    $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>blade click</title>
<style>body{margin:0;font:16px sans-serif} a.big{display:block;height:45vh;background:#ddeeff} p{height:45vh;margin:0}</style>
</head><body>$body</body></html>
"@
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-bladeclick$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$pageV1 = Join-Path $root 'blade.html'
$pageW3 = Join-Path $root 'neighbour.html'
Write-Page $pageV1 '<p>T3280 fixture - the leading blade.</p>'
Write-Page $pageW3 '<a class="big" id="a" href="#clicked">T3280 fixture - a link to click</a><p id="t">Plain text to click. Plain text to click.</p><div id="clicked"></div>'
$script:errLog = Join-Path $root 'app-stderr.log'

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim C is inverted to "a strip came on show after the link click" - this run MUST fail'
    }

    # ---- setup: P | s2 | v1 | w3 | s4 at 1800 DIP --------------------------------
    Say '== setup: P | s2 | v1(viewer) | w3(viewer) | s4, 1800 DIP wide'
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
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
    & $exe +split --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=v1 "--view=$pageV1" | Out-Null
    Start-Sleep -Milliseconds 1500
    & $exe +split --pane=v1 --direction=right --name=w3 "--view=$pageW3" | Out-Null
    Start-Sleep -Milliseconds 1500
    & $exe +split --pane=w3 --direction=right --name=s4 | Out-Null
    $ok = Wait-Until { @(Get-Leaves).Count -eq 5 -and @(Get-Panes $top).Count -eq 5 } 15
    if (-not $ok) { Write-TestAssertedNothing -Reason "five panes never appeared (+list $(@(Get-Leaves).Count), windows $(@(Get-Panes $top).Count))" }
    Start-Sleep -Milliseconds 1500
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; tree order: {1}; panes: {2}" -f $dpi, ((Get-Leaves | ForEach-Object Name) -join ', '), (Format-Cols $all))

    # ---- collapse by hand: drag the w3|s4 divider left to two on show --------
    Say '== drag the w3|s4 divider left until two panes are on show, and release'
    $v = @(Get-VisiblePanes $top)
    if ($v.Count -ne 5) { Write-TestAssertedNothing -Reason "not all five panes on show before the drag ($($v.Count))" }
    $gridLeft = $all[0].Left
    $x = [int](($v[3].Right + $v[4].Left) / 2)
    $y = [int](($v[3].Top + $v[3].Bottom) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
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
    $want = @('P', 's2', 'v1')
    $shownA = @(Get-ShownNames $top)
    $tuckedA = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}" -f ($shownA -join ', '), ($tuckedA -join ', '))
    Assert (($shownA -join ',') -eq 's4,w3') "A: w3 and s4 on show after the drag ($($shownA -join ','))"
    Assert (($tuckedA -join ',') -eq ($want -join ',')) "A: P, s2, v1 folded into strips ($($tuckedA -join ','))"
    if (($tuckedA -join ',') -ne ($want -join ',')) { Write-TestAssertedNothing -Reason 'the drag never folded the viewer into a strip' }

    $named = Get-Named $top
    $w3 = $named['w3']
    $s4 = $named['s4']
    $chrome = Find-ChromeInput ([IntPtr][int64]$w3.Hwnd)
    Assert ($chrome -ne [IntPtr]::Zero) "A: w3's Chromium input window is up"
    if ($chrome -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason "w3's Chromium input window never appeared" }

    # ---- B: the caret on s4 -------------------------------------------------------
    Say '== B: the caret on s4'
    Click-Pane $top $s4 ([IntPtr][int64]$s4.Hwnd)
    $fB = Wait-Focused 's4'
    Start-Sleep -Milliseconds 500
    Assert ($fB -eq 's4') "B: s4 holds the caret ('$fB')"
    $tuckedB = @(Get-TuckedNames $top)
    Assert (($tuckedB -join ',') -eq ($want -join ',')) "B: focusing a pane on show moved no strip ($($tuckedB -join ','))"

    # ---- C: a click on w3's link ------------------------------------------------
    Say '== C: a click on the link in w3 (the viewer beside the v1 blade)'
    Click-Pane $top $w3 $chrome 0.2
    $fC = Wait-Focused 'w3'
    $outC = Watch-Strips $top $want 2
    $tuckedC = @(Get-TuckedNames $top)
    Say ("      caret: {0}; strips now: {1}; other shapes seen: {2}" -f $fC, ($tuckedC -join ', '), $(if ($outC.Count) { $outC -join ' / ' } else { 'none' }))
    Assert ($fC -eq 'w3') "C: the link click landed - w3 took the caret ('$fC')"
    if ($NegativeControl) {
        Assert ($outC.Count -gt 0) "NEGATIVE: a strip came on show after the link click (seen: $($outC -join ' / '))"
    } else {
        Assert ($outC.Count -eq 0 -and ($tuckedC -join ',') -eq ($want -join ',')) "C: every strip stayed a strip after the link click ($($tuckedC -join ','))"
    }

    # ---- D: back to s4, then a click on w3's text --------------------------------
    Say '== D: the caret back on s4, then a click on plain text in w3'
    Click-Pane $top $s4 ([IntPtr][int64]$s4.Hwnd)
    $fD0 = Wait-Focused 's4'
    Assert ($fD0 -eq 's4') "D: s4 took the caret back ('$fD0')"
    Click-Pane $top $w3 $chrome 0.7
    $fD = Wait-Focused 'w3'
    $outD = Watch-Strips $top $want 2
    $tuckedD = @(Get-TuckedNames $top)
    Say ("      caret: {0}; strips now: {1}; other shapes seen: {2}" -f $fD, ($tuckedD -join ', '), $(if ($outD.Count) { $outD -join ' / ' } else { 'none' }))
    Assert ($fD -eq 'w3') "D: the text click landed - w3 took the caret ('$fD')"
    Assert ($outD.Count -eq 0 -and ($tuckedD -join ',') -eq ($want -join ',')) "D: every strip stayed a strip after the text click ($($tuckedD -join ','))"
    $shownD = @(Get-ShownNames $top)
    Assert (($shownD -join ',') -eq 's4,w3') "D: w3 and s4 still the panes on show ($($shownD -join ','))"

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
        update -Guard blade-click-neighbour -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T3280 BLADE CLICK NEIGHBOUR' -Pass $script:pass -Fail $script:fail
