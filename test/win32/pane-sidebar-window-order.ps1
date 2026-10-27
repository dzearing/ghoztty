# T2337 acceptance: the all-windows sidebar list reorders by drag (Mac
# b07b7fa0b / c4dbe30be / 9a1f14230 / 97afdaf5a, `PaneSidebarItemDrag`). A
# window row drags among its siblings - its project's windows, or the top
# level for a lone window - and a project header among the top level. It
# reorders the LIST only, the order is every window's and it is persisted.
#
# Layout: window A "solo", windows B "proj: wt-1" and C "proj: wt-2". Name
# order: proj (wt-1, wt-2), then solo. Everything is driven in A's expanded
# all-windows list by posted mouse messages; positions come from the
# `pane sidebar outline` log line, the order from `pane sidebar all-windows
# ... order=`.
#
#   1. The proj header dragged below solo: every group folds for the drag
#      (one header), the held header logs its moves, the drop saves the order
#      and the folds come back. Order: solo | proj/wt-1 | proj/wt-2. No
#      top-level window moved.
#   2. wt-1 dragged below wt-2 inside the group (every window folds for it):
#      solo | proj/wt-2 | proj/wt-1.
#   3. solo, a lone window, dragged below the group: proj/wt-2 | proj/wt-1 |
#      solo.
#   4. Escape cancels: solo dragged back up, Escape, and the order holds.
#   5. Shared: B, activated, lists the same order.
#   6. Persisted: the order file names the group and the three windows.
#   7. Relaunched with session restore, the windows come back with their ids
#      and the list keeps the dragged order (wt-2 before wt-1 - not the name
#      order).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground. -NegativeControl deletes the order file before the
# relaunch, so section 7 MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-window-order.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2337-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2337')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

$fakeLocal = Join-Path $tmp 'local'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeLocal 'ghoztty') | Out-Null
$orderFile = Join-Path $fakeLocal 'ghoztty\pane_sidebar_order-debug'
$manifest = Get-GhozttySessionLayoutPath -Root $fakeLocal
$script:errlog = Join-Path $tmp 'app-stderr.log'

function Invoke-Cli([string]$CliArgs) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    } finally { $env:LOCALAPPDATA = $saved }
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    return $hit
}
function Get-LogLines([int]$Skip, [string]$Pattern) {
    return @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern })
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}
# The heads of the newest outline line since $Skip, in list order:
# @{ Kind = 'P'|'W'; X; Y } (client coordinates of the sidebar).
function Get-Heads([int]$Skip) {
    $line = Wait-Log 'pane sidebar outline mode=expanded' $Skip 3000
    $heads = @()
    if ($line -and $line -match ' heads=(\S*)') {
        foreach ($h in ($Matches[1] -split ';' | Where-Object { $_ })) {
            if ($h -match '^([PW])\d+@(-?\d+),(-?\d+)$') { $heads += @{ Kind = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3] } }
        }
    }
    return , $heads
}
# The list's order from the newest all-windows line since $Skip.
function Get-Order([int]$Skip, [int]$Ms = 3000) {
    $line = Wait-Log 'pane sidebar all-windows groups=' $Skip $Ms
    if ($line -and $line -match ' order=(\S*)$') { return $Matches[1] }
    return $null
}
function Wait-Order([string]$Want, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $o = Get-Order $Skip 300
        if ($o -eq $Want) { return $o }
    } while ((Get-Date) -lt $deadline)
    return (Get-Order $Skip 300)
}
# Drag the head at $from (client) to client y $toY in A's sidebar: the press,
# a move past the drag threshold, two steps, then the release - or Escape.
function Invoke-HeadDrag($top, $sb, $from, [int]$toY, [switch]$Cancel) {
    $x = $sb.Left + $from.X
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $from.Y) -Action down
    $ok = $ok -and (Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $from.Y + [math]::Sign($toY - $from.Y) * (Px 10)) -Action move)
    Start-Sleep -Milliseconds 300
    $mid = [int](($from.Y + $toY) / 2)
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $mid) -Action move)
    Start-Sleep -Milliseconds 250
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $toY) -Action move)
    Start-Sleep -Milliseconds 400
    if ($Cancel) {
        $ok = $ok -and (Send-TestKeys -Window $top -Target ([IntPtr]$sb.Hwnd) -Key escape)
        Start-Sleep -Milliseconds 200
    }
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $toY) -Action up)
    Start-Sleep -Milliseconds 900
    return $ok
}
function Get-TopRects([int]$AppPid) {
    return (@(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyWindow' | Sort-Object Hwnd | ForEach-Object { '{0}:{1},{2},{3},{4}' -f $_.Hwnd, $_.Left, $_.Top, $_.Width, $_.Height }) -join ' ')
}
function Launch {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        $a = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=true', '--macos-pane-style=flat')
    } finally { $env:LOCALAPPDATA = $saved }
    $script:app = $a
    Start-Sleep -Seconds 3
    return (Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow')
}
# Turn the expanded all-windows list on in $top's sidebar (expanding it first
# when it is the rail). Returns the sidebar.
function Open-AllWindows($top) {
    [void](Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 500
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { return $null }
    if ($sb.Width -lt (Px 150)) {
        [void](ClickAt $top $sb (Get-ToggleCenter $sb))
        Start-Sleep -Milliseconds 800
        $sb = Get-Sidebar $top
    }
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    [void](Wait-Log 'pane sidebar scope all_windows=true' $mark)
    Start-Sleep -Milliseconds 400
    return (Get-Sidebar $top)
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2337'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $topA = Launch
    if ($topA -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $script:app.Pid))
    $dpi = Get-TestWindowDpi -Window $topA
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $topA -Width (Px 1100) -Height (Px 800))
    Assert "setup: window A titled solo ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=solo") -eq 0)
    Assert "setup: window B opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --name=b1 --title=`"proj: wt-1`"") -eq 0)
    Assert "setup: window C opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --name=c1 --title=`"proj: wt-2`"") -eq 0)
    Start-Sleep -Milliseconds 1500
    $tops = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow')
    Assert "setup: three windows ($($tops.Count))" ($tops.Count -eq 3)
    foreach ($t in $tops) { [void](Set-TestWindowSize -Window ([IntPtr]$t.Hwnd) -Width (Px 1100) -Height (Px 800)) }
    $topB = @($tops | Where-Object { [IntPtr]$_.Hwnd -ne $topA }) | Select-Object -First 1
    $topB = [IntPtr]$topB.Hwnd

    $mark = Get-LogCount
    $sb = Open-AllWindows $topA
    Assert "setup: A's all-windows list is up" ($null -ne $sb)
    Assert "the list starts in name order" ((Get-Order $mark) -eq 'proj/wt-1|proj/wt-2|solo')
    $rectsBefore = Get-TopRects $script:app.Pid

    "== 1: the proj header dragged below solo"
    $heads = Get-Heads $mark
    Assert "outline: P, W wt-1, W wt-2, W solo ($(($heads | ForEach-Object { $_.Kind }) -join ''))" ((($heads | ForEach-Object { $_.Kind }) -join '') -eq 'PWWW')
    if ($heads.Count -ge 4) {
        $mark = Get-LogCount
        $ok = Invoke-HeadDrag $topA $sb $heads[0] ($heads[3].Y + (Px 80))
        Assert "drag delivered" $ok
        Assert "a group drag started among the top level's two items" ($null -ne (Wait-Log 'pane sidebar item drag start kind=project key=project:proj siblings=2 source=0' $mark))
        $during = Get-LogLines $mark 'pane sidebar outline mode=expanded' | Select-Object -First 1
        Assert "every group folded for the drag: two heads left ($during)" ($during -match ' heads=P\d+@[-\d,]+;W\d+@[-\d,]+; ')
        Assert "the held header followed the pointer" (@(Get-LogLines $mark 'pane sidebar item held top=').Count -ge 2)
        Assert "its index moved past solo" ($null -ne (Wait-Log 'pane sidebar item drag target=1' $mark))
        Assert "the drop landed it at 1" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=0 to=1' $mark))
        Assert "the order was saved" ($null -ne (Wait-Log 'pane sidebar window order saved keys=' $mark))
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        $o = Wait-Order 'solo|proj/wt-1|proj/wt-2' $mark
        Assert "order: solo | proj/wt-1 | proj/wt-2 ($o)" ($o -eq 'solo|proj/wt-1|proj/wt-2')
        $after = Get-Heads $mark
        Assert "the folds came back: four heads again ($(($after | ForEach-Object { $_.Kind }) -join ''))" ((($after | ForEach-Object { $_.Kind }) -join '') -eq 'WPWW')
    }
    Assert "no window moved on screen" ((Get-TopRects $script:app.Pid) -eq $rectsBefore)

    "== 2: wt-1 dragged below wt-2 inside its group"
    $heads = Get-Heads 0
    if ($heads.Count -ge 4) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[2] ($heads[3].Y + (Px 80)))
        Assert "a window drag among the group's two windows" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ siblings=2 source=0' $mark))
        Assert "every window folded for it" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .* folded=3 ' $mark))
        Assert "landed at 1" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=0 to=1' $mark))
        $o = Wait-Order 'solo|proj/wt-2|proj/wt-1' $mark
        Assert "order: solo | proj/wt-2 | proj/wt-1 ($o)" ($o -eq 'solo|proj/wt-2|proj/wt-1')
        Assert "and solo is open again once it settled" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .* folded=2 ' $mark))
    }

    "== 3: solo, a lone window, dragged below the group"
    $heads = Get-Heads 0
    if ($heads.Count -ge 4) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[0] ($heads[3].Y + (Px 80)))
        Assert "a window drag among the top level's two items" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ siblings=2 source=0' $mark))
        Assert "landed at 1" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=0 to=1' $mark))
        $o = Wait-Order 'proj/wt-2|proj/wt-1|solo' $mark
        Assert "order: proj/wt-2 | proj/wt-1 | solo ($o)" ($o -eq 'proj/wt-2|proj/wt-1|solo')
    }

    "== 4: Escape cancels a drag"
    $heads = Get-Heads 0
    if ($heads.Count -ge 4) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[3] ([math]::Max(0, $heads[0].Y - (Px 40))) -Cancel)
        Assert "the drag reached the top" ($null -ne (Wait-Log 'pane sidebar item drag target=0' $mark))
        Assert "Escape ended it without a move" ($null -ne (Wait-Log 'pane sidebar item drag end commit=false from=1 to=1' $mark))
        Assert "nothing was saved" (@(Get-LogLines $mark 'pane sidebar window order saved').Count -eq 0)
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        Assert "the order held" ((Get-Order $mark) -eq 'proj/wt-2|proj/wt-1|solo')
    }

    "== 5: B lists the same order once activated"
    $mark = Get-LogCount
    [void](Set-TestActiveWindow -Window $topB)
    Start-Sleep -Milliseconds 800
    Assert "B caught up" ($null -ne (Wait-Log "pane sidebar catch up window=$([int64]$topB) all_windows=true" $mark))
    $o = Wait-Order 'proj/wt-2|proj/wt-1|solo' $mark
    Assert "B's list: proj/wt-2 | proj/wt-1 | solo ($o)" ($o -eq 'proj/wt-2|proj/wt-1|solo')

    "== 6: the order is stored"
    $stored = if (Test-Path $orderFile) { @(Get-Content $orderFile) } else { @() }
    "  (stored: $($stored -join ' '))"
    Assert "the file names the group first" ($stored.Count -ge 1 -and $stored[0] -eq 'project:proj')
    Assert "then three windows by id" (@($stored | Where-Object { $_ -match '^window:[0-9A-Fa-f-]{36}$' }).Count -eq 3)

    "== 7: relaunched with session restore, the dragged order holds"
    $deadline = (Get-Date).AddSeconds(8)
    while (-not ((Test-Path $manifest) -and ((Get-Content $manifest -Raw) -match 'wt-2')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Assert "setup: the session layout records the windows" ((Test-Path $manifest) -and ((Get-Content $manifest -Raw) -match 'wt-2'))
    Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: the order file is deleted - this section MUST fail"
        Remove-Item $orderFile -Force -ErrorAction SilentlyContinue
    }
    $logBefore = Get-LogCount
    $top = Launch
    Assert "relaunched" ($top -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    $tops = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow')
    Assert "three windows restored ($($tops.Count))" ($tops.Count -eq 3)
    if ($top -ne [IntPtr]::Zero) {
        $mark = Get-LogCount
        $sb2 = Open-AllWindows $top
        Assert "the restored window's all-windows list is up" ($null -ne $sb2)
        $o = Wait-Order 'proj/wt-2|proj/wt-1|solo' $mark
        Assert "the list keeps the dragged order, not the name order ($o)" ($o -eq 'proj/wt-2|proj/wt-1|solo')
    }

    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    Assert "no test-desktop app ever became foreground on the interactive desktop" (-not ($fgSeen -contains $script:app.Pid))
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-window-order -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2337' -Path $transcript `
        -Label 'T2337 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
