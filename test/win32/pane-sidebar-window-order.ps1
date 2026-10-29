# T2337 + T2338 acceptance: the all-windows sidebar list reorders by drag
# (Mac b07b7fa0b / c4dbe30be / 9a1f14230 / 97afdaf5a / 379a352ef,
# `PaneSidebarItemDrag`, `PaneSidebarCrossDrop`). A project header drags
# among the top level; a window row drags anywhere in the list (T2338) - into
# a group, out of one, or among its own group's windows. It reorders the LIST
# only, the order is every window's and it is persisted; a window that
# changes group is retitled `<project>: <name>` / `<name>`.
#
# Layout: window A "solo", windows B "proj: wt-1" and C "proj: wt-2", window
# D "zz: one". Name order: solo, then proj (wt-1, wt-2), then zz - ungrouped
# windows lead every group (T2421, Mac 6bd2962eb). Everything is driven in
# A's expanded all-windows list by posted mouse messages; positions come from
# the `pane sidebar outline` log line, the order from `pane sidebar
# all-windows ... order=`.
#
#   1. The proj header dragged below zz: every group folds for the drag
#      (headers only), the held header logs its moves, the drop saves the
#      order and the folds come back. Order: solo | zz/one | proj/wt-1 |
#      proj/wt-2. No top-level window moved.
#   1b. (T2421) The zz header dragged above solo: a group stops below the
#      lone windows, so its index never reaches 0 and the drop moves nothing.
#   2. wt-2 dragged above wt-1, right under the proj header (every window
#      folds for it; the drag reads the whole list as rows): it stays in
#      proj, no join outline. solo | zz/one | proj/wt-2 | proj/wt-1.
#   3. (T2421) solo, a lone window, dragged past the last group's end: the
#      groups' band, so it lands at the end of the lone windows - where it
#      already is. Nothing moves, nothing is retitled.
#   4. Escape cancels: wt-1 dragged up to the top, Escape, and the order
#      holds.
#   5. Shared: B, activated, lists the same order.
#   6. Persisted: the order file names both groups and the four windows.
#   7. Relaunched with session restore, the windows come back with their ids
#      and the list keeps the dragged order (zz before proj, wt-2 before wt-1
#      - not the name order).
#   8. solo dragged into proj, between wt-2 and wt-1 (T2338): proj's header
#      is outlined while it would join, and on the drop solo is retitled
#      "proj: solo" (+list) and lands there: zz/one | proj/wt-2 | proj/solo |
#      proj/wt-1.
#   9. wt-1, proj's last window, dragged out past the end: retitled "wt-1"
#      (+list) and, below a group, it lands at the end of the lone windows -
#      the top of the list (T2421): wt-1 | zz/one | proj/wt-2 | proj/solo.
#  10. With twelve windows (T2423, Mac 6bd2962eb), a drag start redraws the
#      window in use alone: the `item drag lifted` line counts no other
#      sidebar redrawn and all eleven left to catch up, inside 80 ms. Another
#      window, activated, catches up then.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground. -NegativeControl deletes the order file before the
# relaunch, so section 7 MUST fail, and activates no other window in section
# 10, so its catch-up check MUST fail too.
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
# With -TargetFrom, $toY is worked out once the drag has started, from the
# heads as the drag laid them out (it folds every window, which moves them):
# the scriptblock gets those heads and returns the y. $Dir is the threshold
# move's direction then (+1 down, -1 up).
function Invoke-HeadDrag($top, $sb, $from, [int]$toY, [switch]$Cancel, [scriptblock]$TargetFrom, [int]$Dir = 1) {
    $x = $sb.Left + $from.X
    $mark = Get-LogCount
    $sign = if ($TargetFrom) { $Dir } else { [math]::Sign($toY - $from.Y) }
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $from.Y) -Action down
    $ok = $ok -and (Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($sb.Top + $from.Y + $sign * (Px 10)) -Action move)
    Start-Sleep -Milliseconds 300
    if ($TargetFrom) {
        [void](Wait-Log 'pane sidebar item drag start' $mark 2000)
        Start-Sleep -Milliseconds 200
        $laid = Get-Heads $mark
        $toY = [int](& $TargetFrom $laid)
        Write-Host "  (drag laid out: $(($laid | ForEach-Object { '{0}@{1}' -f $_.Kind, $_.Y }) -join ' '); to y $toY)"
    }
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
# Every title `+list --json` reports - each window's and each tab's.
function Get-ListTitles {
    [void](Invoke-Cli '+list --json')
    $raw = Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    # A debug build's window titles carry a ` [DEBUG]` mark.
    return @([regex]::Matches($raw, '"title"\s*:\s*"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace ' \[DEBUG\]$', '' })
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
    Assert "setup: window D opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --name=d1 --title=`"zz: one`"") -eq 0)
    Start-Sleep -Milliseconds 1500
    $tops = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow')
    Assert "setup: four windows ($($tops.Count))" ($tops.Count -eq 4)
    foreach ($t in $tops) { [void](Set-TestWindowSize -Window ([IntPtr]$t.Hwnd) -Width (Px 1100) -Height (Px 800)) }
    $topB = @($tops | Where-Object { [IntPtr]$_.Hwnd -ne $topA }) | Select-Object -First 1
    $topB = [IntPtr]$topB.Hwnd

    $mark = Get-LogCount
    $sb = Open-AllWindows $topA
    Assert "setup: A's all-windows list is up" ($null -ne $sb)
    Assert "the list starts in name order, the lone window first (T2421)" ((Get-Order $mark) -eq 'solo|proj/wt-1|proj/wt-2|zz/one')
    $rectsBefore = Get-TopRects $script:app.Pid

    "== 1: the proj header dragged below zz"
    $heads = Get-Heads $mark
    Assert "outline: W solo, P proj, W wt-1, W wt-2, P zz, W one ($(($heads | ForEach-Object { $_.Kind }) -join ''))" ((($heads | ForEach-Object { $_.Kind }) -join '') -eq 'WPWWPW')
    if ($heads.Count -ge 6) {
        $mark = Get-LogCount
        $ok = Invoke-HeadDrag $topA $sb $heads[1] ($heads[5].Y + (Px 80))
        Assert "drag delivered" $ok
        Assert "a group drag started among the top level's three items" ($null -ne (Wait-Log 'pane sidebar item drag start kind=project key=project:proj siblings=3 source=1' $mark))
        $during = Get-LogLines $mark 'pane sidebar outline mode=expanded' | Select-Object -First 1
        Assert "every group folded for the drag: three heads left ($during)" ($during -match ' heads=W\d+@[-\d,]+;P\d+@[-\d,]+;P\d+@[-\d,]+; ')
        Assert "the held header followed the pointer" (@(Get-LogLines $mark 'pane sidebar item held top=').Count -ge 2)
        Assert "its index moved past zz" ($null -ne (Wait-Log 'pane sidebar item drag target=2' $mark))
        Assert "the drop landed it at 2" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=1 to=2' $mark))
        Assert "the order was saved" ($null -ne (Wait-Log 'pane sidebar window order saved keys=' $mark))
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        $o = Wait-Order 'solo|zz/one|proj/wt-1|proj/wt-2' $mark
        Assert "order: solo | zz/one | proj/wt-1 | proj/wt-2 ($o)" ($o -eq 'solo|zz/one|proj/wt-1|proj/wt-2')
        $after = Get-Heads $mark
        Assert "the folds came back: six heads again ($(($after | ForEach-Object { $_.Kind }) -join ''))" ((($after | ForEach-Object { $_.Kind }) -join '') -eq 'WPWPWW')
    }
    Assert "no window moved on screen" ((Get-TopRects $script:app.Pid) -eq $rectsBefore)

    "== 1b: the zz header dragged above solo stops below it (T2421)"
    $heads = Get-Heads 0
    if ($heads.Count -ge 6) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[1] ([math]::Max(0, $heads[0].Y - (Px 40))))
        Assert "a group drag of zz from 1" ($null -ne (Wait-Log 'pane sidebar item drag start kind=project key=project:zz siblings=3 source=1' $mark))
        Assert "the held header followed the pointer up" (@(Get-LogLines $mark 'pane sidebar item held top=').Count -ge 2)
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        Assert "its index never went above the lone window" (@(Get-LogLines $mark 'pane sidebar item drag target=0').Count -eq 0)
        Assert "the drop moved nothing" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=1 to=1' $mark))
        Assert "nothing was saved" (@(Get-LogLines $mark 'pane sidebar window order saved').Count -eq 0)
        Assert "the order held" ((Get-Order $mark) -eq 'solo|zz/one|proj/wt-1|proj/wt-2')
    }

    "== 2: wt-2 dragged above wt-1, right under the proj header"
    $heads = Get-Heads 0
    if ($heads.Count -ge 6) {
        $mark = Get-LogCount
        # Its pointer 6px above wt-1's middle: its top above wt-1's, below
        # the header's middle - the slot right under the header.
        [void](Invoke-HeadDrag $topA $sb $heads[5] 0 -Dir -1 -TargetFrom { param($h) $h[4].Y - (Px 6) })
        Assert "a window drag over the whole list's six rows" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ rows=6 source=5' $mark))
        Assert "every window folded for it" ($null -ne (Wait-Log 'pane sidebar all-windows groups=4 .* folded=4 ' $mark))
        Assert "it would land first in proj" ($null -ne (Wait-Log 'pane sidebar item drag dest=group:proj@0' $mark))
        Assert "landed in the slot under the header" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=5 to=4' $mark))
        Assert "its own group: no join outline" (@(Get-LogLines $mark 'pane sidebar item drag join=proj').Count -eq 0)
        Assert "and no retitle" (@(Get-LogLines $mark 'pane sidebar window regrouped').Count -eq 0)
        $o = Wait-Order 'solo|zz/one|proj/wt-2|proj/wt-1' $mark
        Assert "order: solo | zz/one | proj/wt-2 | proj/wt-1 ($o)" ($o -eq 'solo|zz/one|proj/wt-2|proj/wt-1')
        Assert "and solo is open again once it settled" ($null -ne (Wait-Log 'pane sidebar all-windows groups=4 .* folded=3 ' $mark))
    }

    "== 3: solo dragged past the last group's end stays with the lone windows (T2421)"
    $heads = Get-Heads 0
    if ($heads.Count -ge 6) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[0] ($heads[5].Y + (Px 80)))
        Assert "a window drag over the six rows, from the first" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ rows=6 source=0' $mark))
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        $dests = @(Get-LogLines $mark 'pane sidebar item drag dest=')
        $last = if ($dests.Count) { $dests[$dests.Count - 1] } else { '' }
        Assert "below the groups it lands at the end of the lone windows: top@0 ($last)" ($last -match 'dest=top@0$')
        Assert "where it already was: nothing moved" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=0 to=0' $mark))
        Assert "nothing was saved" (@(Get-LogLines $mark 'pane sidebar window order saved').Count -eq 0)
        Assert "no retitle: it was lone and stays lone" (@(Get-LogLines $mark 'pane sidebar window regrouped').Count -eq 0)
        Assert "the order held" ((Get-Order $mark) -eq 'solo|zz/one|proj/wt-2|proj/wt-1')
    }

    "== 4: Escape cancels a drag"
    $heads = Get-Heads 0
    if ($heads.Count -ge 6) {
        $mark = Get-LogCount
        [void](Invoke-HeadDrag $topA $sb $heads[5] ([math]::Max(0, $heads[0].Y - (Px 40))) -Cancel)
        Assert "the drag reached the top" ($null -ne (Wait-Log 'pane sidebar item drag target=0' $mark))
        Assert "Escape ended it without a move" ($null -ne (Wait-Log 'pane sidebar item drag end commit=false from=5 to=5' $mark))
        Assert "nothing was saved" (@(Get-LogLines $mark 'pane sidebar window order saved').Count -eq 0)
        Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
        Assert "the order held" ((Get-Order $mark) -eq 'solo|zz/one|proj/wt-2|proj/wt-1')
    }

    "== 5: B lists the same order once activated"
    $mark = Get-LogCount
    [void](Set-TestActiveWindow -Window $topB)
    Start-Sleep -Milliseconds 800
    Assert "B caught up" ($null -ne (Wait-Log "pane sidebar catch up window=$([int64]$topB) all_windows=true" $mark))
    $o = Wait-Order 'solo|zz/one|proj/wt-2|proj/wt-1' $mark
    Assert "B's list: solo | zz/one | proj/wt-2 | proj/wt-1 ($o)" ($o -eq 'solo|zz/one|proj/wt-2|proj/wt-1')

    "== 6: the order is stored"
    $stored = if (Test-Path $orderFile) { @(Get-Content $orderFile) } else { @() }
    "  (stored: $($stored -join ' '))"
    Assert "the file names both groups" (($stored -contains 'project:proj') -and ($stored -contains 'project:zz'))
    # The three a drag placed (solo, wt-1, wt-2); zz's only window was never
    # placed, so its key is not written - it follows its group by name.
    Assert "and the three windows a drag placed, by id" (@($stored | Where-Object { $_ -match '^window:[0-9A-Fa-f-]{36}$' }).Count -eq 3)

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
    Assert "four windows restored ($($tops.Count))" ($tops.Count -eq 4)
    if ($top -ne [IntPtr]::Zero) {
        $mark = Get-LogCount
        $sb2 = Open-AllWindows $top
        Assert "the restored window's all-windows list is up" ($null -ne $sb2)
        $o = Wait-Order 'solo|zz/one|proj/wt-2|proj/wt-1' $mark
        Assert "the list keeps the dragged order, not the name order ($o)" ($o -eq 'solo|zz/one|proj/wt-2|proj/wt-1')

        "== 8: solo dragged into proj, between wt-2 and wt-1"
        $heads = Get-Heads $mark
        "  (heads: $(($heads | ForEach-Object { $_.Kind }) -join ''))"
        if ($heads.Count -ge 6) {
            $mark = Get-LogCount
            # Its pointer 6px above wt-2's middle: with solo gone from the top
            # the rows close up by one, so that is past wt-2, short of wt-1.
            [void](Invoke-HeadDrag $top $sb2 $heads[0] 0 -Dir 1 -TargetFrom { param($h) $h[4].Y - (Px 6) })
            Assert "a window drag over the six rows, from the first" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ rows=6 source=0' $mark))
            Assert "it would land in proj at 1" ($null -ne (Wait-Log 'pane sidebar item drag dest=group:proj@1' $mark))
            Assert "proj's header says it would join" ($null -ne (Wait-Log 'pane sidebar item drag join=proj' $mark))
            # The outline is logged once a drag, and on its way down from the
            # top solo passes over zz first, so the line may name zz.
            Assert "the join outline was drawn" ($null -ne (Wait-Log 'pane sidebar join outline drawn project=(proj|zz)$' $mark))
            Assert "retitled proj: solo" ($null -ne (Wait-Log 'pane sidebar window regrouped from= to=proj title=proj: solo$' $mark))
            $o = Wait-Order 'zz/one|proj/wt-2|proj/solo|proj/wt-1' $mark
            Assert "order: zz/one | proj/wt-2 | proj/solo | proj/wt-1 ($o)" ($o -eq 'zz/one|proj/wt-2|proj/solo|proj/wt-1')
            $titles = Get-ListTitles
            "  (+list titles: $($titles -join ' | '))"
            Assert "+list names it proj: solo" ($titles -contains 'proj: solo')
            Assert "+list no longer has a bare solo" (-not ($titles -contains 'solo'))
        }

        "== 9: wt-1 dragged out of proj, past the end, lands on top (T2421)"
        $heads = Get-Heads 0
        if ($heads.Count -ge 6) {
            $mark = Get-LogCount
            [void](Invoke-HeadDrag $top $sb2 $heads[5] ($heads[5].Y + (Px 80)))
            Assert "a window drag from the last of six rows" ($null -ne (Wait-Log 'pane sidebar item drag start kind=window key=window:\S+ rows=6 source=5' $mark))
            Assert "it settled" ($null -ne (Wait-Log 'pane sidebar item drag settled' $mark))
            $dests = @(Get-LogLines $mark 'pane sidebar item drag dest=')
            $last = if ($dests.Count) { $dests[$dests.Count - 1] } else { '' }
            Assert "the lower half past the group: the top level, at the end of the (no) lone windows ($last)" ($last -match 'dest=top@0$')
            Assert "it lands in the first slot" ($null -ne (Wait-Log 'pane sidebar item drag end commit=true from=5 to=0' $mark))
            Assert "retitled wt-1" ($null -ne (Wait-Log 'pane sidebar window regrouped from=proj to= title=wt-1$' $mark))
            $o = Wait-Order 'wt-1|zz/one|proj/wt-2|proj/solo' $mark
            Assert "order: wt-1 | zz/one | proj/wt-2 | proj/solo ($o)" ($o -eq 'wt-1|zz/one|proj/wt-2|proj/solo')
            $titles = Get-ListTitles
            "  (+list titles: $($titles -join ' | '))"
            Assert "+list names it wt-1" ($titles -contains 'wt-1')
            Assert "+list no longer has proj: wt-1" (-not ($titles -contains 'proj: wt-1'))
        }
    }

    "== 10: with twelve windows, a drag start redraws only the window in use (T2423)"
    if ($top -ne [IntPtr]::Zero -and $null -ne $sb2) {
        # Four windows already (A-D): eight more make twelve.
        $extra = 12 - @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow').Count
        for ($i = 1; $i -le $extra; $i++) {
            [void](Invoke-Cli "+new-window --name=x$i --title=`"extra $i`"")
        }
        Start-Sleep -Milliseconds 2500
        $tops = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow')
        Assert "setup: twelve windows ($($tops.Count))" ($tops.Count -eq 12)
        $mark = Get-LogCount
        [void](Set-TestActiveWindow -Window $top)
        Start-Sleep -Milliseconds 600
        # Its list lays out again - the scope off and back on - so the newest
        # outline line is its own.
        $sb2 = Get-Sidebar $top
        $off = Get-LogCount
        [void](ClickAt $top $sb2 (Get-ScopeCenter $sb2))
        [void](Wait-Log 'pane sidebar scope all_windows=false' $off)
        Start-Sleep -Milliseconds 600
        $mark = Get-LogCount
        [void](ClickAt $top $sb2 (Get-ScopeCenter $sb2))
        [void](Wait-Log 'pane sidebar scope all_windows=true' $mark)
        Start-Sleep -Milliseconds 800
        $sb2 = Get-Sidebar $top
        $all = Get-Heads $mark
        $heads = @($all | Where-Object { $_.Kind -eq 'W' })
        if ($heads.Count -ge 1 -and $null -ne $sb2) {
            $mark = Get-LogCount
            [void](Invoke-HeadDrag $top $sb2 $heads[0] ($heads[0].Y + (Px 40)) -Cancel)
            $lift = Wait-Log 'pane sidebar item drag lifted ' $mark
            "  ($lift)"
            $ok = $lift -match 'lifted us=(\d+) redrawn=(\d+) others_redrawn=(\d+) others=(\d+) others_behind=(\d+)'
            Assert "the lift was logged" $ok
            if ($ok) {
                $us = [int64]$Matches[1]; $redrawn = [int]$Matches[2]; $othersRedrawn = [int]$Matches[3]
                $others = [int]$Matches[4]; $behind = [int]$Matches[5]
                Assert "eleven other windows have a sidebar ($others)" ($others -eq 11)
                Assert "the lift redrew this window's list once ($redrawn)" ($redrawn -eq 1)
                Assert "and no other window's ($othersRedrawn)" ($othersRedrawn -eq 0)
                Assert "every other window is left to catch up when next activated ($behind)" ($behind -eq 11)
                # Mac's stall was 0.4-1.3 s with 20 windows; a debug build
                # lifts well inside a fifth of that.
                Assert "the lift took under 80 ms ($([math]::Round($us / 1000.0, 1)) ms)" ($us -lt 80000)
            }
            Assert "Escape let it go" ($null -ne (Wait-Log 'pane sidebar item drag end commit=false' $mark))
            $other = @($tops | Where-Object { [IntPtr]$_.Hwnd -ne $top }) | Select-Object -Last 1
            $mark = Get-LogCount
            if ($NegativeControl) {
                "  NEGATIVE CONTROL: no other window is activated - the catch-up check MUST fail"
            } else {
                [void](Set-TestActiveWindow -Window ([IntPtr]$other.Hwnd))
            }
            Start-Sleep -Milliseconds 800
            Assert "another window, activated, caught up then" ($null -ne (Wait-Log "pane sidebar catch up window=$([int64]$other.Hwnd) all_windows=true" $mark 2500))
        } else {
            $last = @(Get-LogLines $mark '.') | Select-Object -Last 12
            foreach ($ln in $last) { "  (log: $($ln.Substring(0, [math]::Min(240, $ln.Length))))" }
            "  (log lines since mark: $((Get-LogCount) - $mark); app alive: $($null -ne (Get-Process -Id $script:app.Pid -ErrorAction SilentlyContinue)))"
            Assert "setup: the twelve-window list has window rows ($($heads.Count))" $false
        }
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
