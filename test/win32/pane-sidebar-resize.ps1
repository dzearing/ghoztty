# T1846 acceptance: dragging the pane sidebar's edge on Windows (Mac
# 7855941f7, PaneSidebarChrome.resizeHandle; T2299, Mac 543489bca
# PaneSidebarState.edgeDrag/edgeGrip). The expanded panel's trailing edge
# resizes it between 180 and 380 DIP, stops at 180 when pushed a little under
# it and tucks back into the rail when pushed well under 120; the rail comes
# out once pulled past the panel's 180 minimum; both ways within one drag; the
# grip is the gutter beside the card in both modes, never the rail's tiles;
# and the width is ONE preference shared by every window.
#
# Layout: one window, first pane P plus `+split right` -> s1. Every drag is a
# posted press / moves / release on the sidebar window itself (screen
# coordinates, as the other sidebar harnesses drive it). What it checks:
#
#   1. The rail's grip is its gutter (the card's 12 DIP trailing margin): a
#      press just inside the card's edge is a tile's, not a drag. From the
#      gutter a 40 DIP pull, and a pull to 152 DIP (past 120, short of the
#      panel), leave the rail alone; one drag out to 200 and back to 92 comes
#      out and tucks back in; a pull to 200 leaves the panel there.
#   2. The expanded panel's edge follows the pointer: +80 DIP -> 280, and the
#      grid's first pane starts right after the new column.
#   3. Pulled far right it stops at 380; pushed to 150 it stops at 180 and
#      stays expanded; pushed on to 100 it tucks into the 76 DIP rail.
#   4. A press on the edge band is not a click: nothing is focused or
#      stashed, and the panel is still expanded.
#   5. One preference for every window: a second window opened now starts at
#      the last width, and dragging the first window's edge resizes the
#      second's panel too - once the second is activated (T2336: only the
#      window in use redraws as the width moves, Mac 9a1f14230).
#   6. (T2289) Collapsing with the toggle and expanding again comes back at
#      the dragged width - the width is the panel's, not lost with the rail.
#   2b. T2265 (Mac a81db68f9 + 5e4f30144): the flat grip shows the split
#      dividers' accent gutter bar - hovered, then at full strength while
#      dragged - and letting go leaves none lit.
#   2c. T2359: every tick of the edge drag relays the grid out on the live
#      path - each resized pane waits for a frame at its new size, as a
#      divider drag's do (`window resize cause=sidebar ... sync=`) - and the
#      drag reports its cost (`sidebar drag ticks=`) when it lets go.
#   7. T2265, elevated: the expanded panel resizes from the GUTTER beside it
#      (the grid's margin, the window's own pixels), not from a band inside
#      the panel; the gutter lights its bar on hover and while dragged, and
#      none is left lit after the release. T2299: the rail too - a press
#      inside its card is not a drag, and its gutter pulls it out.
#
# The app runs on a background desktop throughout and never takes the user's
# foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl drags by 0 DIP in step 2 and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-resize.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1846-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1846')
# Section 2c reads the drag's cost line, which the app prints only under this.
# It adds timers, not behavior.
$env:GHOZTTY_PERF = '1'
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }
function Near([int]$A, [int]$B) { [math]::Abs($A - $B) -le 2 }
# The expanded column (T2290, Mac 0a547522d): the rail's card at the panel's
# width, in the rail's own insets - 12 DIP either side flat, the panes' 10 DIP
# leading and none trailing elevated - summed from the rounded parts the way
# the layout does.
function FlatColumn([double]$Dip) { (Px 12) + (Px $Dip) + (Px 12) }
function ElevColumn([double]$Dip) { (Px 10) + (Px $Dip) }

# The collapse/expand toggle (T2289): the rail's first item and the panel
# header's first item on the same pixels (pane-sidebar.ps1's
# Get-ToggleCenter), flat insets.
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}

# One edge drag on window $target: press at ($x0, $y), move by each of $steps
# (DIP, cumulative from the press), release at the last.
function Invoke-EdgeDrag($top, $target, [int]$x0, [int]$y, [double[]]$steps) {
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x0 -Y $y -Action down
    $x = $x0
    foreach ($s in $steps) {
        $x = $x0 + (Px $s)
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action move)
        Start-Sleep -Milliseconds 120
    }
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action up)
    Start-Sleep -Milliseconds 500
    return $ok
}
# The pinned panel's edge band is the last grab width inside the column.
function Get-PanelEdgeX($sb) { $sb.Right - 2 }
function Get-LogSince([int]$From) { @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The strengths a log slice names for one bar, in order (`<prefix> (\w+)`).
function Get-BarStates([string[]]$Lines, [string]$Prefix) {
    @($Lines | ForEach-Object { if ($_ -match "$Prefix (\w+)") { $Matches[1] } })
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1846'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    # Wide enough for the pinned panel (>= 720 DIP).
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 600
    $hP = (@(Get-Panes $top))[0].Hwnd
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 900
    Assert "setup: two visible panes" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 2)

    "== 1: the rail's gutter brings it out once the panel fits, and tucks it back (T2299)"
    $sb = Get-Sidebar $top
    Assert "setup: the 76 DIP rail is up ($($sb.Width))" ($null -ne $sb -and (Near $sb.Width (Px 76)))
    if ($null -eq $sb) { return }
    $ey = $sb.Top + (Px 300)
    # Just inside the rail card's trailing edge (12 DIP margin + 52 DIP
    # card) is the card's - a tile's, never the grip (Mac 543489bca).
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd ($sb.Left + (Px 64) - 2) $ey @(40, 160))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "a press inside the rail card is not a drag (log)" (@($lines | Where-Object { $_ -match 'edge drag start' }).Count -eq 0)
    Assert "and the rail stayed ($($sb.Width))" (Near $sb.Width (Px 76))
    # The gutter: the card's 12 DIP trailing margin, never past the column
    # where a pane may be (T2125).
    $ex = $sb.Right - (Px 6)
    $from = Get-LogCount
    $ok = Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(20, 40)
    Assert "the press reached the rail" $ok
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "a 40 DIP pull leaves the rail alone ($($sb.Width))" (Near $sb.Width (Px 76))
    Assert "the drag ran (log: edge drag start surface=rail mode=mini from=52)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag start surface=rail mode=mini from=52' }).Count -ge 1)
    Assert "and expanded nothing" (@($lines | Where-Object { $_ -match 'edge drag expanded' }).Count -eq 0)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(60, 100))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "past 120 but short of the panel's 180 it is still the rail ($($sb.Width))" (Near $sb.Width (Px 76))
    Assert "and expanded nothing (log)" (@($lines | Where-Object { $_ -match 'edge drag expanded' }).Count -eq 0)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(80, 148, 100, 40))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "one drag came out (log: expanded=true)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag expanded=true' }).Count -eq 1)
    Assert "and tucked back in (log: expanded=false)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag expanded=false' }).Count -eq 1)
    Assert "it let go as the rail ($($sb.Width))" (Near $sb.Width (Px 76))
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(40, 100, 148))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "pulled past 180 it expanded (log)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag expanded=true' }).Count -eq 1)
    Assert "the column is the panel where the pointer is, 200 ($($sb.Width) vs $(Px 200))" (Near $sb.Width (FlatColumn 200))
    Assert "the drag ended expanded (log)" (@($lines | Where-Object { $_ -match 'edge drag end expanded=true width=200' }).Count -eq 1)

    "== 2: the expanded panel's edge follows the pointer"
    $step = if ($NegativeControl) { 0 } else { 80 }
    if ($NegativeControl) { "  NEGATIVE CONTROL: dragging by 0 DIP - this run MUST fail" }
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(($step / 2), $step))
    $sb = Get-Sidebar $top
    Assert "+80 DIP -> 280 ($($sb.Width) vs $(Px 280))" (Near $sb.Width (FlatColumn 280))
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid starts right after the new column (P.left $($p.Left), panel.right $($sb.Right))" ($p.Left -ge $sb.Right -and $p.Left - $sb.Right -le (Px 4))

    "== 2b: the flat grip shows Mac's accent gutter bar (T2265)"
    $from = Get-LogCount
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-PanelEdgeX $sb) -Y $ey -Action move)
    Start-Sleep -Milliseconds 400
    $lines = Get-LogSince $from
    Assert "hovering the grip lights its bar (log: edge hover=rail)" (@($lines | Where-Object { $_ -match 'pane sidebar edge hover=rail' }).Count -ge 1)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(10, 0))
    $lines = Get-LogSince $from
    $bars = @(Get-BarStates $lines 'pane sidebar edge bar')
    Assert "dragging it shows the bar at full strength (painted: $($bars -join ','))" ($bars -contains 'drag')
    Assert "letting go leaves no bar lit (last painted: $(if ($bars.Count) { $bars[-1] }))" ($bars.Count -gt 0 -and $bars[-1] -eq 'none')
    $sb = Get-Sidebar $top
    Assert "a there-and-back drag kept the width ($($sb.Width) vs $(Px 280))" (Near $sb.Width (FlatColumn 280))

    "== 2c: each tick of the drag relays the grid out on the live path (T2359)"
    $steps = if ($NegativeControl) { @(0, 0, 0) } else { @(-20, -40, -60, -40, -20, 0) }
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey $steps)
    $lines = Get-LogSince $from
    $passes = @($lines | ForEach-Object {
        if ($_ -match 'window resize cause=sidebar panes=(\d+) sync=(\d+) fresh=(\d+)') {
            [pscustomobject]@{ Panes = [int]$Matches[1]; Sync = [int]$Matches[2]; Fresh = [int]$Matches[3] }
        } })
    $resized = @($passes | Where-Object { $_.Panes -gt 0 })
    $unguarded = @($resized | Where-Object { $_.Sync + $_.Fresh -lt $_.Panes })
    Assert "the drag ran a layout pass per width change ($($passes.Count) passes)" ($passes.Count -ge 4)
    Assert "and they resized panes ($($resized.Count) of $($passes.Count))" ($resized.Count -ge 4)
    Assert "every resized pane waited for its frame (unguarded: $(($unguarded | ForEach-Object { "panes=$($_.Panes) sync=$($_.Sync)" }) -join '; '))" ($resized.Count -gt 0 -and $unguarded.Count -eq 0)
    $cost = @($lines | Where-Object { $_ -match 'sidebar drag ticks=(\d+) mean_us=(\d+) max_us=(\d+)' } | Select-Object -Last 1)
    $ticks = if ($cost.Count -eq 1 -and $cost[0] -match 'sidebar drag ticks=(\d+) mean_us=(\d+) max_us=(\d+)') { [int]$Matches[1] } else { 0 }
    if ($cost.Count -eq 1) { "  (cost: $(($cost[0] -replace '^.*(sidebar drag ticks=\S+ mean_us=\S+ max_us=\S+ mean_wait_us=\S+).*$', '$1')))" }
    Assert "the drag reported its cost on release ($ticks ticks)" ($ticks -ge 4)
    $sb = Get-Sidebar $top
    Assert "and came back to 280 ($($sb.Width) vs $(Px 280))" (Near $sb.Width (FlatColumn 280))

    "== 3: it stops at 380 and at 180, and tucks into the rail well under that (T2299)"
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(200, 500))
    $sb = Get-Sidebar $top
    Assert "far right stops at 380 ($($sb.Width) vs $(Px 380))" (Near $sb.Width (FlatColumn 380))
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(-150, -230))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "pushed to 150 it stops at 180 ($($sb.Width) vs $(Px 180)), not the 76 rail" (Near $sb.Width (FlatColumn 180))
    Assert "and it is still expanded (log)" (@($lines | Where-Object { $_ -match 'edge drag end expanded=true width=180' }).Count -eq 1)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(-30, -80))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "pushed on to 100 it tucks into the rail ($($sb.Width) vs $(Px 76))" ($null -ne $sb -and (Near $sb.Width (Px 76)))
    Assert "the drag ended as the rail (log)" (@($lines | Where-Object { $_ -match 'edge drag end expanded=false' }).Count -eq 1)
    # Out again from the rail's gutter, for the sections after this.
    [void](Invoke-EdgeDrag $top $sb.Hwnd ($sb.Right - (Px 6)) $ey @(80, 148))
    $sb = Get-Sidebar $top
    Assert "the rail's gutter brought it back out at 200 ($($sb.Width))" ($null -ne $sb -and (Near $sb.Width (FlatColumn 200)))

    "== 4: a press on the edge is not a click on the row under it"
    $from = Get-LogCount
    $r = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-PanelEdgeX $sb) -Y $ey -Action click
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "the click was delivered" $r
    Assert "it started and ended a drag of nothing (log)" (@($lines | Where-Object { $_ -match 'edge drag end expanded=true width=200' }).Count -eq 1)
    Assert "the panel kept its width ($($sb.Width))" (Near $sb.Width (FlatColumn 200))

    "== 5: one width for every window"
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(50, 100))
    $sb = Get-Sidebar $top
    Assert "window A's panel is at 300 ($($sb.Width))" (Near $sb.Width (FlatColumn 300))
    Assert "setup: window B opened" ((Invoke-Cli "+new-window --target=t1846b --name=b1") -eq 0)
    Start-Sleep -Milliseconds 1500
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { [IntPtr]$_.Hwnd -ne $top })
    $top2 = if ($tops.Count -ge 1) { [IntPtr]$tops[0].Hwnd } else { [IntPtr]::Zero }
    Assert "setup: a second window opened" ($top2 -ne [IntPtr]::Zero)
    if ($top2 -eq [IntPtr]::Zero) { return }
    [void](Set-TestWindowSize -Window $top2 -Width (Px 1000) -Height (Px 600))
    Start-Sleep -Milliseconds 700
    $sb2 = Get-Sidebar $top2
    Assert "the new window starts expanded at the last width ($($sb2.Width) vs $(Px 300))" ($null -ne $sb2 -and (Near $sb2.Width (FlatColumn 300)))
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(-40, -80))
    Start-Sleep -Milliseconds 300
    $sb = Get-Sidebar $top
    $sb2 = Get-Sidebar $top2
    Assert "window A's panel moved to 220 ($($sb.Width))" (Near $sb.Width (FlatColumn 220))
    # T2336 (Mac 9a1f14230): only the window in use redraws as the width
    # moves; B, in the background, takes it when it is next activated.
    Assert "window B's is untouched while in the background ($($sb2.Width) vs $(Px 300))" ($null -ne $sb2 -and (Near $sb2.Width (FlatColumn 300)))
    Assert "setup: window B activated" (Set-TestActiveWindow -Window $top2)
    Start-Sleep -Milliseconds 700
    $sb2 = Get-Sidebar $top2
    Assert "and once activated, window B's followed it ($($sb2.Width) vs $(Px 220))" ($null -ne $sb2 -and (Near $sb2.Width (FlatColumn 220)))
    Assert "setup: window A active again" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 400

    "== 6: collapsing and expanding keeps the dragged width (T2289)"
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-ToggleCenter $sb).X -Y (Get-ToggleCenter $sb).Y -Action click)
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "the toggle collapsed it to the rail ($($sb.Width) vs $(Px 76))" ($null -ne $sb -and (Near $sb.Width (Px 76)))
    Assert "no card opened over the grid" ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard' -AllowHidden) -eq [IntPtr]::Zero)
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-ToggleCenter $sb).X -Y (Get-ToggleCenter $sb).Y -Action click)
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "expanded again at the dragged 220 ($($sb.Width) vs $(Px 220))" ($null -ne $sb -and (Near $sb.Width (FlatColumn 220)))
    Assert "no crash (flat)" (-not ($app.Process -and $app.Process.HasExited))

    "== 7: elevated, the expanded panel resizes from the gutter beside it (T2265)"
    $launched += $script:GhozttyTestDesktopPids
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    $script:errlog = Join-Path $tmp 'app-stderr-elevated.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=elevated')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: elevated top window not found"; $script:failures++; return }
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 600
    $hP = (@(Get-Panes $top))[0].Hwnd
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 900
    $sb = Get-Sidebar $top
    Assert "setup: the elevated rail is up ($($sb.Width) vs $(Px 62))" ($null -ne $sb -and (Near $sb.Width (Px 62)))
    if ($null -eq $sb) { return }
    # The elevated rail's card: a 10 DIP leading margin, the 52 DIP card,
    # no trailing inset - the card ends at the column, and its grip is the
    # grid's 10 DIP margin beyond it, the window's pixels (T2299, Mac
    # 543489bca `edgeGrip`).
    $ey = $sb.Top + (Px 300)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd ($sb.Right - 2) $ey @(80, 148))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "a press inside the elevated rail's card is not a drag (log)" (@($lines | Where-Object { $_ -match 'edge drag start' }).Count -eq 0)
    Assert "and the rail stayed ($($sb.Width) vs $(Px 62))" (Near $sb.Width (Px 62))
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $top ($sb.Right + [int]((Px 10) / 2)) $ey @(80, 148))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "the rail's gutter drags it (log: edge drag start surface=rail mode=mini from=52)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag start surface=rail mode=mini from=52' }).Count -eq 1)
    Assert "pulled out to 200 it expands there ($($sb.Width) vs $(ElevColumn 200))" (Near $sb.Width (ElevColumn 200))
    $from = Get-LogCount
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Right - 2) -Y $ey -Action click)
    Start-Sleep -Milliseconds 400
    $lines = Get-LogSince $from
    Assert "a press just inside the panel's edge is not a drag any more (Mac pinnedEdgeGrip)" (@($lines | Where-Object { $_ -match 'edge drag start' }).Count -eq 0)
    # The gutter: the grid's 10 DIP margin, right of the panel.
    $gx = $sb.Right + [int]((Px 10) / 2)
    $from = Get-LogCount
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $ey -Action move)
    Start-Sleep -Milliseconds 400
    $lines = Get-LogSince $from
    Assert "hovering the gutter lights its bar (log: sidebar edge hover=true)" (@($lines | Where-Object { $_ -match 'sidebar edge hover=true' }).Count -ge 1)
    $step = if ($NegativeControl) { 0 } else { 80 }
    $from = Get-LogCount
    $ok = Invoke-EdgeDrag $top $top $gx $ey @(($step / 2), $step)
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    $bars = @(Get-BarStates $lines 'gutter bar sidebar_edge')
    Assert "the press reached the gutter" $ok
    Assert "the gutter drags the panel (log: edge drag start surface=rail mode=expanded from=200)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag start surface=rail mode=expanded from=200' }).Count -eq 1)
    Assert "+80 DIP -> 280 ($($sb.Width) vs $(Px 280))" (Near $sb.Width (ElevColumn 280))
    Assert "the dragged gutter shows the bar at full strength (painted: $($bars -join ','))" ($bars -contains 'drag')
    $last = @($lines | Where-Object { $_ -match 'gutter bar ' } | Select-Object -Last 1)
    Assert "letting go leaves no bar lit (last: $last)" ($last.Count -eq 1 -and $last[0] -match 'gutter bar none')
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid keeps its margin beside the new panel (P.left $($p.Left), panel.right $($sb.Right))" ($p.Left - $sb.Right -ge (Px 10) - 1 -and $p.Left - $sb.Right -le (Px 14))

    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-resize -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1846' -Path $transcript `
        -Label 'T1846 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
