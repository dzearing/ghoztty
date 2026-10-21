# T2110 acceptance: every focus path brings a pane tucked behind a stack's run
# on show - a `ghoztty://focus/<name>` link (the IPC `focus` the CLI and the
# palette's jump share), goto_split, and a click on a pane sidebar row.
#
# THE CLAIM. T2108 made a row too narrow for all its panes show a run and TUCK
# the rest (their windows hidden); T2109 brought one back from its strip. On
# Mac every focus path goes through `PaneStackState.noteFocus` before the
# relayout, so focusing a tucked pane by any route slides it on show. Before
# T2110 only the strip click re-laid the row out: the others moved focus into
# a hidden pane - keys went to a terminal nobody could see - and the row did
# not change until something else re-laid it out. `Window.showFocusedPane`
# now runs the layout when the focused pane is tucked.
#
# Layout: P | (s1 | (s2 | s3)) at 900 DIP wide, the T2108 shape: two on show,
# two tucked.
#
# Claims:
#   F1) a `ghoztty://focus/<name>` link at a tucked pane puts it on show,
#       keeps two on show, and focuses it (+list --json)
#   F2) goto_split:previous to the row's first pane, then goto_split:next to
#       its last (neither wraps), always lands on a pane on show - and at
#       least one move landed on a pane that was tucked (so the walk actually
#       crossed into the stack)
#   F3) with the sidebar pinned, a click on a tucked pane's row puts it on
#       show and focuses it
#
# -NegativeControl inverts F1 to "the linked pane is still tucked" - the answer
# before T2110 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-focus.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-focus-$PID"

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

# goto_split:previous/next on chords a terminal does not otherwise claim, so
# the walk does not depend on the platform default (ctrl+super+[ / ]).
$appArgs = @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle",
    '--keybind=ctrl+shift+f8=goto_split:previous', '--keybind=ctrl+shift+f9=goto_split:next')

function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

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

function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
# Every leaf of the selected tab, left to right (tree order): name, id, focus.
function Get-Leaves {
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            [void]$out.Add([pscustomobject]@{ Name = [string]$node.terminal.name; Id = [string]$node.terminal.id; Focused = [bool]$node.terminal.focused })
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
    if (-not $f[0].Name -or $f[0].Name -eq $f[0].Id) { return 'P' }
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
    $all = @(Get-Panes $top)
    $map = @{}
    for ($i = 0; $i -lt $all.Count -and $i -lt $script:names.Count; $i++) { $map[$script:names[$i]] = $all[$i] }
    return $map
}
function Get-TuckedNames([IntPtr]$top) {
    $m = Get-Named $top
    return @($script:names | Where-Object { $m.ContainsKey($_) -and -not $m[$_].Visible })
}

# The sidebar's `pane sidebar rows` log line (pane-sidebar-actions.ps1).
function Get-Rows {
    $line = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar rows ' }) | Select-Object -Last 1
    if (-not $line -or $line -notmatch 'mode=(\w+) heads=\S* items=(\S*) rules=\d+') { return $null }
    $o = @{ Mode = $Matches[1]; Items = @() }
    foreach ($i in ($Matches[2] -split ';' | Where-Object { $_ })) {
        if ($i -match '^g\d+([gs])@(-?\d+),(-?\d+)#(\S+)$') { $o.Items += , @{ Sec = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3]; Id = $Matches[4] } }
    }
    return $o
}
function Wait-Rows([scriptblock]$Cond, [int]$Ms = 5000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $r = Get-Rows
        if ($r -and (& $Cond $r)) { return $r }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return Get-Rows
}
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Get-MiniPinCenter {
    $margin = Px 12; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackfocus$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$script:errlog = Join-Path $root 'app-stderr.log'

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: F1 is inverted to "the linked pane is still tucked" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at 900 DIP -------------------------------
    Say '== setup: P | (s1 | (s2 | s3)), 900 DIP wide'
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
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show (got $($c4.Count))" }
    $leaves = @(Get-Leaves)
    # An unnamed pane is listed under its id; the first one is P here.
    $script:names = @($leaves | ForEach-Object { if ($_.Name -and $_.Name -ne $_.Id) { $_.Name } else { 'P' } })
    $ids = @{}
    for ($i = 0; $i -lt $leaves.Count; $i++) { $ids[$script:names[$i]] = $leaves[$i].Id }
    Say ("      tree order: {0}" -f ($script:names -join ', '))
    if ($script:names.Count -ne 4) { Write-TestAssertedNothing -Reason "+list did not name four panes ($($script:names.Count))" }
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Px 900) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $shown = @(Wait-Shown $top 2)
    Start-Sleep -Milliseconds 600
    Say ("      dpi {0}; panes: {1}" -f $dpi, (Format-Cols (Get-Panes $top)))
    if ($shown.Count -ne 2) { Write-TestAssertedNothing -Reason "the 900 DIP row never settled on two on show (got $($shown.Count))" }

    # ---- F1: a ghoztty://focus link ---------------------------------------------
    Say '== F1: ghoztty://focus link at a tucked pane'
    $tucked = @(Get-TuckedNames $top)
    $target = @($tucked | Where-Object { $_ -ne 'P' }) | Select-Object -First 1
    if (-not $target) { Write-TestAssertedNothing -Reason 'no named pane was tucked' }
    Say "      tucked: $($tucked -join ', '); linking to $target"
    # The debug build's scheme (url-scheme.ps1): the activation is a client
    # that forwards a `focus` over the run's pipe and exits.
    $link = "ghoztty-debug://focus/$target"
    & $exe $link 2>&1 | Out-Null
    $focused = Wait-Focused $target
    Start-Sleep -Milliseconds 900
    $m = Get-Named $top
    Say ("      panes: {0}" -f (Format-Cols (Get-Panes $top)))
    if ($NegativeControl) {
        Assert (-not $m[$target].Visible) "NEGATIVE: the linked pane ($target) is still tucked"
    } else {
        Assert ($m[$target].Visible) "F1: the linked pane ($target) is on show"
    }
    Assert (@(Get-VisiblePanes $top).Count -eq 2) "F1: still two on show ($(@(Get-VisiblePanes $top).Count))"
    Assert ($focused -eq $target) "F1: the linked pane has focus (+list says '$focused')"

    # ---- F2: goto_split along the row ------------------------------------------
    Say '== F2: goto_split:previous to the first pane, then :next to the last'
    $crossed = 0
    $allShown = $true
    $moves = 0
    foreach ($key in @('F8', 'F9')) {
        for ($k = 0; $k -lt 5; $k++) {
            $from = Focused-Pane-Name
            $tuckedBefore = @(Get-TuckedNames $top)
            $m = Get-Named $top
            $fromPane = $m[$from]
            if ($null -eq $fromPane) { $allShown = $false; Say "      (no window for focused '$from')"; break }
            [void](Send-TestKeys -Window $top -Target ([IntPtr]$fromPane.Hwnd) -Key $key -Modifiers ctrl, shift)
            $deadline = (Get-Date).AddSeconds(3)
            do {
                Start-Sleep -Milliseconds 200
                $to = Focused-Pane-Name
            } while ($to -eq $from -and (Get-Date) -lt $deadline)
            # The row's end: neither direction wraps (SplitTree `previous`/`next`).
            if ($to -eq $from) { Say "      $key at $from`: the row's end"; break }
            $moves++
            Start-Sleep -Milliseconds 700
            $m = Get-Named $top
            $onShow = ($null -ne $m[$to]) -and $m[$to].Visible
            $wasTucked = $tuckedBefore -contains $to
            if ($wasTucked) { $crossed++ }
            Say ("      {0} {1} -> {2}: {3}{4}" -f $key, $from, $to, $(if ($onShow) { 'on show' } else { 'TUCKED' }), $(if ($wasTucked) { ' (was tucked)' } else { '' }))
            if (-not $onShow) { $allShown = $false }
        }
    }
    Assert ($moves -ge 4) "F2: the walk moved focus along the row ($moves moves)"
    Assert $allShown 'F2: every goto_split landed on a pane on show'
    Assert ($crossed -gt 0) "F2: the walk crossed into a tucked pane at least once ($crossed)"
    Assert (@(Get-VisiblePanes $top).Count -eq 2) "F2: still two on show ($(@(Get-VisiblePanes $top).Count))"

    # ---- F3: a sidebar row ------------------------------------------------------
    Say '== F3: pane sidebar row'
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { Write-TestAssertedNothing -Reason 'no pane sidebar' }
    # Pin: the panel lays out the rows. Column client coordinates from the
    # mini layout's pin tile, offset by the column's place in the window.
    $pin = Get-MiniPinCenter
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pin.X) -Y ($sb.Top + $pin.Y) -Action move)
    Start-Sleep -Milliseconds 120
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pin.X) -Y ($sb.Top + $pin.Y) -Button left -Action click)
    $rows = Wait-Rows { param($r) $r.Mode -eq 'expanded' -and $r.Items.Count -eq 4 }
    $sb = Get-Sidebar $top
    if ($null -eq $rows -or $rows.Items.Count -ne 4) { Write-TestAssertedNothing -Reason "the pinned sidebar never listed four rows ($(if ($rows) { $rows.Items.Count } else { 'none' }))" }
    Start-Sleep -Milliseconds 900
    $tucked = @(Get-TuckedNames $top)
    Say ("      panes: {0}; tucked: {1}" -f (Format-Cols (Get-Panes $top)), ($tucked -join ', '))
    $target = $tucked | Select-Object -First 1
    if (-not $target) { Write-TestAssertedNothing -Reason 'nothing tucked with the sidebar pinned' }
    $row = $rows.Items | Where-Object { $_.Id -eq $ids[$target] } | Select-Object -First 1
    if ($null -eq $row) { Write-TestAssertedNothing -Reason "no sidebar row for $target ($($ids[$target]))" }
    # The row's center as the app's own `pane sidebar rows` line reports it.
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $row.X) -Y ($sb.Top + $row.Y) -Action move)
    Start-Sleep -Milliseconds 120
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $row.X) -Y ($sb.Top + $row.Y) -Button left -Action click)
    $focused = Wait-Focused $target
    Start-Sleep -Milliseconds 900
    $m = Get-Named $top
    Say ("      clicked {0}'s row; panes: {1}" -f $target, (Format-Cols (Get-Panes $top)))
    Assert ($m[$target].Visible) "F3: the clicked row's pane ($target) is on show"
    Assert ($focused -eq $target) "F3: it has focus (+list says '$focused')"

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
        update -Guard pane-stack-focus -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2110 PANE STACK FOCUS' -Pass $script:pass -Fail $script:fail
