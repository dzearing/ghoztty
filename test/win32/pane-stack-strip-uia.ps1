# T2122 acceptance: a tucked pane's strip is a screen-reader button.
#
# THE CLAIM. Mac's PaneStackTabView is an accessibility button labelled
# 'Tucked pane: <name>', help 'Brings the pane forward', whose press brings the
# pane on show. T2109's win32 strips were pixels the window paints, with no
# presence in any accessibility tree, so a screen-reader user could not find a
# tucked pane at all. The window now answers UI Automation's root question
# (WM_GETOBJECT / UiaRootObjectId) with a provider that lists each strip as a
# child button (strip_uia_provider.zig).
#
# The oracle is a real UIA client (System.Windows.Automation, the managed face
# of the same UIAutomationCore Narrator uses) walking the window's RAW view,
# from a thread bound to the background test desktop (lib\UiaProbe.ps1).
#
# Layout: P | (s1 | (s2 | s3)) at 760 DIP wide, the T2108 shape: two on show,
# two tucked (pane-stack-strip.ps1's setup).
#
# Claims:
#   U1) the window's children carry one Button per tucked pane, AutomationId
#       'TuckedPaneStrip', and none for a pane on show
#   U2) each strip is named 'Tucked pane: <name>', the name its strip shows -
#       a banner title set with +set-banner reaches the accessible name
#   U3) each strip carries Mac's help text 'Brings the pane forward' and
#       offers the Invoke pattern
#   U4) each strip's bounding rectangle is a band inside the window, in screen
#       pixels: narrower than a card, as tall as the row
#   U5) the window's own children are still there: every pane on show is still
#       reachable as its window (the provider adds to the HWND host's tree, it
#       does not replace it)
#   U6) Invoke on a strip brings that pane on show and focuses it (+list
#       --json), and its strip leaves the tree
#
# -NegativeControl inverts U1 to "the window lists NO strip buttons" - the
# answer before T2122 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-strip-uia.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-strip-uia-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\UiaProbe.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false', '--macos-pane-style=flat')

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
function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
function Walk-Focused($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal.name }
        return $null
    }
    $l = Walk-Focused $node.left
    if ($null -ne $l) { return $l }
    return Walk-Focused $node.right
}
function Focused-Pane-Name {
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if (-not $tab.selected) { continue }
        return (Walk-Focused $tab.splits)
    }
    return $null
}
function Get-Strips($dump) {
    return @($dump.Children | Where-Object { $_.AutomationId -eq 'TuckedPaneStrip' })
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stripuia$PID"

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
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: U1 is inverted to "the window lists NO strip buttons" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at 760 DIP ------------------------------
    $rowDip = 760
    Say "== setup: P | (s1 | (s2 | s3)), $rowDip DIP wide"
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
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
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show (got $($c4.Count))" }
    $names = @($null, 's1', 's2', 's3')

    # The window's children before the stack tucks anything: no strips, and
    # the provider's answer is readable at all.
    $dump0 = Get-UiaDump -Window $top -Desktop $td
    if ($dump0.Error) { Write-TestAssertedNothing -Reason "the UIA probe could not read the window: $($dump0.Error)" }
    Say ("      before tucking: {0} children, {1} strip(s)" -f @($dump0.Children).Count, @(Get-Strips $dump0).Count)
    Assert (@(Get-Strips $dump0).Count -eq 0) 'U1: with every pane on show the window lists no strip'

    [void](Set-TestWindowPos -Window $top -X 200 -Y 60 -Width (Get-TestChromeDip -Dip $rowDip -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Milliseconds 800
    $shown = @(Wait-Shown $top 2)
    Start-Sleep -Milliseconds 600
    $all = @(Get-Panes $top)
    if ($shown.Count -ne 2 -or $all.Count -ne 4) { Write-TestAssertedNothing -Reason "the $rowDip DIP row never settled on two on show of four (got $($shown.Count) of $($all.Count))" }
    $tucked = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if (-not $all[$i].Visible) { $tucked += [pscustomobject]@{ Pane = $all[$i]; Name = $names[$i] } }
    }
    $named = @($tucked | Where-Object Name)
    if ($named.Count -eq 0) { Write-TestAssertedNothing -Reason 'no named pane was tucked' }
    $t = $named[0]
    $title = 'uia strip title'
    & $exe +set-banner --target=$($t.Name) "## $title" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900

    # ---- U1..U5 -----------------------------------------------------------------
    Say '== U1-U5: what a screen reader finds'
    $dump = Get-UiaDump -Window $top -Desktop $td
    if ($dump.Error) { Write-TestAssertedNothing -Reason "the UIA probe could not read the window: $($dump.Error)" }
    foreach ($c in @($dump.Children)) {
        Say ("      child: '{0}' type={1} id={2} class={3} invoke={4} at {5},{6} {7}x{8}" -f $c.Name, $c.Type, $c.AutomationId, $c.Class, $c.Invoke, $c.X, $c.Y, $c.W, $c.H)
    }
    $strips = @(Get-Strips $dump)
    if ($NegativeControl) {
        Assert ($strips.Count -eq 0) "U1 (inverted): the window lists no strip buttons (got $($strips.Count))"
    } else {
        Assert ($strips.Count -eq $tucked.Count) "U1: one strip button per tucked pane ($($strips.Count) of $($tucked.Count))"
    }
    $buttons = @($strips | Where-Object { $_.Type -eq 'ControlType.Button' })
    Assert ($strips.Count -gt 0 -and $buttons.Count -eq $strips.Count) "U1: every strip is a Button ($($buttons.Count) of $($strips.Count))"

    $want = "Tucked pane: $title"
    Assert (@($strips | Where-Object { $_.Name -eq $want }).Count -eq 1) "U2: the banner-titled strip is named '$want'"
    $prefixed = @($strips | Where-Object { $_.Name.StartsWith('Tucked pane: ') -and $_.Name.Length -gt 13 })
    Assert ($strips.Count -gt 0 -and $prefixed.Count -eq $strips.Count) "U2: every strip is named 'Tucked pane: <name>' ($($prefixed.Count) of $($strips.Count))"

    $helped = @($strips | Where-Object { $_.Help -eq 'Brings the pane forward' })
    Assert ($strips.Count -gt 0 -and $helped.Count -eq $strips.Count) "U3: every strip's help text is Mac's 'Brings the pane forward' ($($helped.Count) of $($strips.Count))"
    $inv = @($strips | Where-Object Invoke)
    Assert ($strips.Count -gt 0 -and $inv.Count -eq $strips.Count) "U3: every strip offers Invoke ($($inv.Count) of $($strips.Count))"

    $wr = Get-TestWindowRect -Window $top
    $card = Get-TestChromeDip -Dip 225 -Scale $scale
    $inside = @($strips | Where-Object {
        $_.W -gt 0 -and $_.H -gt 0 -and $_.W -lt $card -and
        $_.X -ge $wr.Left -and ($_.X + $_.W) -le $wr.Right -and
        $_.Y -ge $wr.Top -and ($_.Y + $_.H) -le $wr.Bottom -and
        $_.H -gt ($wr.Bottom - $wr.Top) / 2
    })
    Assert ($strips.Count -gt 0 -and $inside.Count -eq $strips.Count) "U4: every strip is a band inside the window, narrower than a card (window $($wr.Left),$($wr.Top)-$($wr.Right),$($wr.Bottom))"

    $paneKids = @($dump.Children | Where-Object { $_.Class -eq 'GhozttyTerminal' })
    Assert ($paneKids.Count -ge $shown.Count) "U5: the panes on show are still the window's children ($($paneKids.Count) terminal children, $($shown.Count) on show)"

    # ---- U6: Invoke brings the pane forward ------------------------------------
    Say '== U6: Invoke'
    $before = Focused-Pane-Name
    $res = Invoke-UiaButton -Window $top -Desktop $td -AutomationId 'TuckedPaneStrip' -Name $want
    Say "      invoke '$want': $res (focus was '$before')"
    Assert ($res -eq 'OK') "U6: the strip's Invoke is accepted ($res)"
    $deadline = (Get-Date).AddSeconds(10)
    $visible = $false
    $focused = $null
    do {
        Start-Sleep -Milliseconds 300
        $visible = [bool](Test-TestWindowVisible -Window $t.Pane.Hwnd)
        $focused = Focused-Pane-Name
    } while ((-not $visible -or $focused -ne $t.Name) -and (Get-Date) -lt $deadline)
    Assert $visible "U6: $($t.Name) is on show after the Invoke"
    Assert ($focused -eq $t.Name) "U6: $($t.Name) is focused after the Invoke (focused '$focused')"
    Start-Sleep -Milliseconds 600
    $after = Get-UiaDump -Window $top -Desktop $td
    $left = @(Get-Strips $after | Where-Object { $_.Name -eq $want })
    Assert ($null -eq $after.Error -and $left.Count -eq 0) "U6: $($t.Name)'s strip left the tree ($(@(Get-Strips $after).Count) strip(s) now)"
    Assert ((@(Get-Strips $after).Count) -eq $tucked.Count) "U6: the row still tucks $($tucked.Count) - another pane took the strip ($(@(Get-Strips $after).Count))"

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
        update -Guard pane-stack-strip-uia -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2122 PANE STACK STRIP UIA' -Pass $script:pass -Fail $script:fail
