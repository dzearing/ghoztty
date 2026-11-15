# T3125 acceptance: a viewer pane minimized into a strip stays minimized when
# its page focuses itself.
#
# THE CLAIM. Mac a7fe3e9f8: a page focusing an element - an autofocus field
# after a live reload or a navigation, a script's focus() - made WebKit take
# first responder, and focus brings a blade back out. Mac now refuses page
# focus while the pane is a blade. On Windows a page's focus reaches the app
# through WebView2's `GotFocus` (T1809), which makes the pane its tab's active
# pane; `Window.adoptsFocus` (T2127) refuses that for a strip the tab has not
# chosen, and the layout only brings out the tab's chosen pane. This script is
# the outside-in proof that the guard holds for the page-driven path.
#
# Layout: P | v1 | s2 | s3 | s4 across an 1800 DIP window, v1 a viewer of an
# HTML page that focuses its input on load and every 300 ms after. The s3|s4
# divider is dragged left until two panes are on show, so v1 folds into a
# strip. Then:
#   A) precondition: s3 and s4 on show, P, v1 and s2 strips
#   B) the caret on s3 (a click; it is on show, so nothing moves)
#   C) the page keeps calling focus() for 4 s: every strip is still a strip
#      and s3 still holds the caret
#   D) the page is rewritten on disk (live reload, a fresh autofocus): same
#   E) informational: how many times the page's focus reached the app
#      ("page got focus" in the app's log) and how many the guard refused
#
# -NegativeControl inverts claim C to "a strip came on show while the page
# focused itself" and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\blade-page-focus.ps1
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
$root = Join-Path $env:TEMP "ghoztty-blade-page-focus-$PID"

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

# Terminals and the viewer, left to right. A tucked card keeps its slot's place.
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
function Count-Log([string]$pattern) {
    if (-not (Test-Path $script:errLog)) { return 0 }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($script:errLog, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $sr.Close()
    } catch { return 0 }
    return ([regex]::Matches($text, [regex]::Escape($pattern))).Count
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

function Write-Page([string]$path, [string]$stamp) {
    $html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>blade page focus $stamp</title></head>
<body>
<p>T3125 fixture ${stamp} - this page grabs focus on load and every 300 ms.</p>
<input id="f" autofocus value="focus me">
<script>
  const f = document.getElementById('f');
  f.focus();
  setInterval(function () { window.focus(); f.focus(); }, 300);
</script>
</body></html>
"@
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-bladefocus$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$page = Join-Path $root 'focus-page.html'
Write-Page $page 'v1'
$script:errLog = Join-Path $root 'app-stderr.log'

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim C is inverted to "a strip came on show while the page focused itself" - this run MUST fail'
    }

    # ---- setup: P | v1 | s2 | s3 | s4 at 1800 DIP -------------------------------
    Say '== setup: P | v1(viewer) | s2 | s3 | s4, 1800 DIP wide'
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
    & $exe +split --direction=right --name=v1 "--view=$page" | Out-Null
    Start-Sleep -Milliseconds 1500
    & $exe +split --pane=v1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s3 --direction=right --name=s4 | Out-Null
    $ok = Wait-Until { @(Get-Leaves).Count -eq 5 -and @(Get-Panes $top).Count -eq 5 } 15
    if (-not $ok) { Write-TestAssertedNothing -Reason "five panes never appeared (+list $(@(Get-Leaves).Count), windows $(@(Get-Panes $top).Count))" }
    Start-Sleep -Milliseconds 1500
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; tree order: {1}; panes: {2}" -f $dpi, ((Get-Leaves | ForEach-Object Name) -join ', '), (Format-Cols $all))
    # The log E reads is really captured: the viewer's GotFocus subscription
    # line is a debug line every viewer writes once. Without it E's counts
    # would read 0 whether or not the page's focus reached the app.
    $registered = Count-Log 'got-focus handler registered'
    Assert ($registered -gt 0) "S: the app's debug log is captured (the viewer's GotFocus handler registered $registered time(s))"
    $gotOnShow = Count-Log 'page got focus'
    Say "      page got focus $gotOnShow time(s) while the viewer was on show"

    # ---- collapse by hand: drag the s3|s4 divider left to two on show --------
    Say '== drag the s3|s4 divider left until two panes are on show, and release'
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
    $shownA = @(Get-ShownNames $top)
    $tuckedA = @(Get-TuckedNames $top)
    Say ("      on show: {0}; strips: {1}" -f ($shownA -join ', '), ($tuckedA -join ', '))
    Assert (($shownA -join ',') -eq 's3,s4') "A: s3 and s4 on show after the drag ($($shownA -join ','))"
    Assert (($tuckedA -join ',') -eq 'P,s2,v1') "A: P, v1, s2 folded into strips ($($tuckedA -join ','))"
    if (($tuckedA -join ',') -ne 'P,s2,v1') { Write-TestAssertedNothing -Reason 'the drag never folded the viewer into a strip' }

    # ---- B: the caret on s3 -------------------------------------------------------
    Say '== B: the caret on s3'
    $s3 = (Get-Named $top)['s3']
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$s3.Hwnd) -X ([int](($s3.Left + $s3.Right) / 2)) -Y ([int](($s3.Top + $s3.Bottom) / 2)) -Button left -Action click)
    $fB = Wait-Focused 's3'
    Start-Sleep -Milliseconds 700
    Assert ($fB -eq 's3') "B: s3 holds the caret ('$fB')"
    $tuckedB = @(Get-TuckedNames $top)
    Assert (($tuckedB -join ',') -eq 'P,s2,v1') "B: focusing a pane on show moved no strip ($($tuckedB -join ','))"
    $gotBefore = Count-Log 'page got focus'
    $refusedBefore = Count-Log 'stale focus on a folded strip'

    # ---- C: the page keeps focusing itself ---------------------------------------
    Say '== C: the folded viewer page calls focus() every 300 ms for 4 s'
    $outC = Watch-Strips $top @('P', 's2', 'v1') 4
    $tuckedC = @(Get-TuckedNames $top)
    Say ("      strips now: {0}; other shapes seen: {1}" -f ($tuckedC -join ', '), $(if ($outC.Count) { $outC -join ' / ' } else { 'none' }))
    if ($NegativeControl) {
        Assert ($outC.Count -gt 0) "NEGATIVE: a strip came on show while the page focused itself (seen: $($outC -join ' / '))"
    } else {
        Assert ($outC.Count -eq 0 -and ($tuckedC -join ',') -eq 'P,s2,v1') "C: every strip stayed a strip while the page focused itself ($($tuckedC -join ','))"
    }
    $fC = Focused-Pane-Name
    Assert ($fC -eq 's3') "C: s3 still holds the caret ('$fC')"

    # ---- D: live reload brings a fresh autofocus --------------------------------
    Say '== D: rewrite the page on disk (live reload, autofocus again)'
    Write-Page $page 'v2'
    $outD = Watch-Strips $top @('P', 's2', 'v1') 4
    $tuckedD = @(Get-TuckedNames $top)
    Say ("      strips now: {0}; other shapes seen: {1}" -f ($tuckedD -join ', '), $(if ($outD.Count) { $outD -join ' / ' } else { 'none' }))
    Assert ($outD.Count -eq 0 -and ($tuckedD -join ',') -eq 'P,s2,v1') "D: every strip stayed a strip through the live reload ($($tuckedD -join ','))"
    $fD = Focused-Pane-Name
    Assert ($fD -eq 's3') "D: s3 still holds the caret after the reload ('$fD')"

    # ---- E: what reached the app ------------------------------------------------
    $got = (Count-Log 'page got focus') - $gotBefore
    $refused = (Count-Log 'stale focus on a folded strip') - $refusedBefore
    Say "      E (info): while folded, the page's focus reached the app $got time(s); the T2127 guard refused $refused"

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
        update -Guard blade-page-focus -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T3125 BLADE PAGE FOCUS' -Pass $script:pass -Fail $script:fail
