# T1846 acceptance: dragging the pane sidebar's edge on Windows (Mac
# 7855941f7, PaneSidebarChrome.resizeHandle). The pinned panel's trailing
# edge resizes it between 180 and 380 DIP and never unpins it however far it
# is pushed; pulling the mini rail's edge out past 120 DIP pins it open; and
# the width is ONE preference shared by every window.
#
# Layout: one window, first pane P plus `+split right` -> s1. Every drag is a
# posted press / moves / release on the sidebar window itself (screen
# coordinates, as the other sidebar harnesses drive it). What it checks:
#
#   1. The rail's edge: a 40 DIP pull does nothing (still the 68 DIP rail, no
#      pin in the log); pulled on past 120 DIP it pins, the column becomes
#      the panel, and the release leaves it where the pointer is (the 180
#      minimum, since the drag measured from the rail's 44 DIP card).
#   2. The pinned panel's edge follows the pointer: +100 DIP -> 280, and the
#      grid's first pane starts right after the new column.
#   3. Pulled far right it stops at 380; pushed far left it stops at 180 and
#      STAYS PINNED (Mac dropped the old 140 DIP unpin-on-drag).
#   4. A press on the edge band is not a click: nothing is focused or
#      stashed, and the pin is still pinned.
#   5. One preference for every window: a second window opened now starts at
#      the last width, and dragging the first window's edge resizes the
#      second's panel too.
#   6. The edge drags the open card as well: unpinned, the card opened over
#      the grid takes the dragged width (its window grows with it).
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

# The pin, for the "still pinned" checks: a 28 DIP square sm (4) from the
# panel's trailing edge, centered 18 DIP down (pane-sidebar.ps1's Get-PinCenter).
function Get-PinCenter($sb) {
    return @{ X = $sb.Right - (Px 4) - [int]((Px 28) / 2); Y = $sb.Top + (Px 18) }
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

    "== 1: the rail's edge pins once pulled past 120 DIP, and not before"
    $sb = Get-Sidebar $top
    Assert "setup: the 68 DIP rail is up ($($sb.Width))" ($null -ne $sb -and (Near $sb.Width (Px 68)))
    if ($null -eq $sb) { return }
    # The rail card's trailing edge: 12 DIP margin + 44 DIP card.
    $ex = $sb.Left + (Px 56); $ey = $sb.Top + (Px 300)
    $from = Get-LogCount
    $ok = Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(20, 40)
    Assert "the press reached the rail" $ok
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "a 40 DIP pull leaves the rail alone ($($sb.Width))" (Near $sb.Width (Px 68))
    Assert "the drag ran (log: edge drag start surface=rail mode=mini from=44)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag start surface=rail mode=mini from=44' }).Count -ge 1)
    Assert "and pinned nothing" (@($lines | Where-Object { $_ -match 'edge drag pinned' }).Count -eq 0)
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd $ex $ey @(40, 80, 90))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "pulled past 120 it pinned (log)" (@($lines | Where-Object { $_ -match 'pane sidebar edge drag pinned' }).Count -eq 1)
    Assert "the column is the panel at the 180 minimum ($($sb.Width) vs $(Px 180))" (Near $sb.Width (Px 180))
    Assert "the drag ended pinned (log)" (@($lines | Where-Object { $_ -match 'edge drag end pinned=true width=180' }).Count -eq 1)

    "== 2: the pinned panel's edge follows the pointer"
    $step = if ($NegativeControl) { 0 } else { 100 }
    if ($NegativeControl) { "  NEGATIVE CONTROL: dragging by 0 DIP - this run MUST fail" }
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(($step / 2), $step))
    $sb = Get-Sidebar $top
    Assert "+100 DIP -> 280 ($($sb.Width) vs $(Px 280))" (Near $sb.Width (Px 280))
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid starts right after the new column (P.left $($p.Left), panel.right $($sb.Right))" ($p.Left -ge $sb.Right -and $p.Left - $sb.Right -le (Px 4))

    "== 3: it stops at 380 and at 180, and never unpins"
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(200, 500))
    $sb = Get-Sidebar $top
    Assert "far right stops at 380 ($($sb.Width) vs $(Px 380))" (Near $sb.Width (Px 380))
    $from = Get-LogCount
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(-150, -300, -360))
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "far left stops at 180 ($($sb.Width) vs $(Px 180)), not the 68 rail" (Near $sb.Width (Px 180))
    Assert "and it is still pinned (log)" (@($lines | Where-Object { $_ -match 'edge drag end pinned=true width=180' }).Count -eq 1)

    "== 4: a press on the edge is not a click on the row under it"
    $from = Get-LogCount
    $r = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-PanelEdgeX $sb) -Y $ey -Action click
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top
    $lines = Get-LogSince $from
    Assert "the click was delivered" $r
    Assert "it started and ended a drag of nothing (log)" (@($lines | Where-Object { $_ -match 'edge drag end pinned=true width=180' }).Count -eq 1)
    Assert "the panel kept its width ($($sb.Width))" (Near $sb.Width (Px 180))

    "== 5: one width for every window"
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(60, 120))
    $sb = Get-Sidebar $top
    Assert "window A's panel is at 300 ($($sb.Width))" (Near $sb.Width (Px 300))
    Assert "setup: window B opened" ((Invoke-Cli "+new-window --target=t1846b --name=b1") -eq 0)
    Start-Sleep -Milliseconds 1500
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { [IntPtr]$_.Hwnd -ne $top })
    $top2 = if ($tops.Count -ge 1) { [IntPtr]$tops[0].Hwnd } else { [IntPtr]::Zero }
    Assert "setup: a second window opened" ($top2 -ne [IntPtr]::Zero)
    if ($top2 -eq [IntPtr]::Zero) { return }
    [void](Set-TestWindowSize -Window $top2 -Width (Px 1000) -Height (Px 600))
    Start-Sleep -Milliseconds 700
    $sb2 = Get-Sidebar $top2
    Assert "the new window starts pinned at the last width ($($sb2.Width) vs $(Px 300))" ($null -ne $sb2 -and (Near $sb2.Width (Px 300)))
    [void](Invoke-EdgeDrag $top $sb.Hwnd (Get-PanelEdgeX $sb) $ey @(-40, -80))
    Start-Sleep -Milliseconds 300
    $sb = Get-Sidebar $top
    $sb2 = Get-Sidebar $top2
    Assert "window A's panel moved to 220 ($($sb.Width))" (Near $sb.Width (Px 220))
    Assert "and window B's followed it ($($sb2.Width) vs $(Px 220))" ($null -ne $sb2 -and (Near $sb2.Width (Px 220)))

    "== 6: the open card's edge drags the same width"
    $pin = Get-PinCenter $sb
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $pin.X -Y $pin.Y -Action click)   # unpin: the card opens
    $card = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard'
    Assert "unpinning opened the card" ($card -ne [IntPtr]::Zero)
    if ($card -ne [IntPtr]::Zero) {
        $cr = Get-TestWindowRect -Window $card
        # The card window is margin + panel + margin; its card's trailing edge
        # sits one margin in from the window's right.
        $cx = $cr.Right - (Px 12) - 1; $cy = $cr.Top + (Px 300)
        $from = Get-LogCount
        $down = Send-TestMouse -Window $top -Target $card -X $cx -Y $cy -Action down
        foreach ($s in @(30, 60)) {
            [void](Send-TestMouse -Window $top -Target $card -X ($cx + (Px $s)) -Y $cy -Action move)
            Start-Sleep -Milliseconds 120
        }
        [void](Send-TestMouse -Window $top -Target $card -X ($cx + (Px 60)) -Y $cy -Action up)
        Start-Sleep -Milliseconds 400
        $lines = Get-LogSince $from
        $cr2 = Get-TestWindowRect -Window $card
        Assert "the press reached the card" $down
        Assert "the card's drag ran (log: surface=card)" (@($lines | Where-Object { $_ -match 'edge drag start surface=card mode=mini from=220' }).Count -ge 1)
        Assert "the card grew by 60 DIP ($($cr.Width) -> $($cr2.Width))" (Near ($cr2.Width - $cr.Width) (Px 60))
        Assert "and stayed unpinned (log)" (@($lines | Where-Object { $_ -match 'edge drag end pinned=false width=280' }).Count -eq 1)
    }

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
