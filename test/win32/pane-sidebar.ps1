# T1828 acceptance: the pane sidebar on Windows (Mac 597a193cc,
# docs/design/pane-sidebar.md). A column left of the split grid that lists
# every pane of the active tab - pinned as a flat panel, unpinned as the
# mini rail - where a click focuses a pane or restores a stashed one, a row's
# hover button stashes or restores, and ctrl+shift+s hides it outright.
#
# Layout: the first pane P, then `+split right` -> s1. What it checks:
#
#   1. Default (Mac's default): the mini rail is up - a visible
#      GhozttyPaneSidebar child at the client's left edge, 68 DIP wide, and
#      the grid starts right after it (P's left edge == the rail's right).
#      It paints real content (a synchronous WM_PRINTCLIENT capture is not
#      one flat fill).
#   2. +stash s1, then a click on s1's rail tile restores it and puts it
#      back on screen.
#   3. The pin turns the rail into the 240 DIP panel and the grid moves over
#      by exactly the difference; the panel paints content too.
#   4. The first row's hover button stashes P (a grid pane); a click on the
#      stashed tile in the rail brings it back.
#   5. ctrl+shift+s hides the sidebar: no column, the grid starts at the
#      client's left edge. Again shows it.
#   6. Pinned, a window narrower than 720 DIP shows the rail, not the panel.
#   7. (T1842) Unpinning leaves the card OPEN over the grid, the way Mac's
#      does: a GhozttyPaneSidebarCard popup owned by the window opens at the
#      column's top-left, as wide as the panel plus the rail's margins and as
#      tall as the column, clipped to the column plus a rounded card (the
#      trailing margin shows the grid), while the column stays the 68 DIP
#      rail and no pane moves. The pointer is not on it - the real cursor is
#      on another desktop - so it contracts after Mac's grace period, and the
#      log says which way each transition went.
#   8. (T1842) A pointer on the rail's card arms Mac's 100 ms intent timer,
#      and one in the rail's margin does not. The OPEN itself cannot be shown
#      from a background desktop: a posted move's hover is cleared by the
#      WM_MOUSELEAVE the first pump delivers (T233), and the timer re-checks
#      the real pointer (Mac's pointerIsOverCard), which is elsewhere. The
#      open/close rules are unit-tested in pane_sidebar_hover.zig; the open
#      path itself is section 7's.
#   9. (T1842) Every tile and the pin carries a tooltip, and a tile's names
#      its pane, then the click hint (Mac's .help); the open card's rows,
#      row buttons and pin carry theirs. Scored from the `pane sidebar tips`
#      log line: comctl32 tooltips are never shown on a background desktop.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects NO sidebar in step 1 and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1828-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1828')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    return , $out.ToArray()
}
function Test-StashedId([string]$Id) {
    foreach ($l in (Get-Leaves)) {
        if ($l.id -eq $Id -or $l.name -eq $Id) {
            return ($l.PSObject.Properties.Name -contains 'stashed') -and ($l.stashed -eq $true)
        }
    }
    return $false
}
function Wait-Stashed([string]$Id, [bool]$Want, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if ((Test-StashedId $Id) -eq $Want) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }

# The rail's geometry, from pane_sidebar.zig's numbers (layoutMini): the pin
# at the top of the card, then one 28 DIP tile per pane with a 4 DIP gap, and
# an extra 4 between the grid and stashed groups. Returns the tile's SCREEN
# center for item $Index, given how many items are in the grid section.
function Get-TileCenter($sb, [int]$Index, [int]$GridCount) {
    $margin = Px 12; $card = Px 44; $tile = Px 28; $gap = Px 4; $group = Px 8
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    $pinTop = $margin + $inset
    $y = $pinTop + $tile + $group
    for ($i = 0; $i -lt $Index; $i++) {
        $y += $tile + $gap
        if (($i + 1) -eq $GridCount -and $GridCount -gt 0) { $y += $group - $gap }
    }
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $y + [int]($tile / 2) }
}
function Get-PinCenter($sb, [string]$Mode) {
    if ($Mode -eq 'mini') {
        $margin = Px 12; $card = Px 44; $tile = Px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
    }
    # Expanded: a 28 DIP square, sm (4) from the trailing edge, centered in
    # a header band at least 36 DIP tall - its center is 18 DIP down.
    return @{ X = $sb.Right - (Px 4) - [int]((Px 28) / 2); Y = $sb.Top + (Px 18) }
}
function Click($top, $target, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $pt.X -Y $pt.Y -Action click
}
function Save-Shot($sb, [string]$Name) {
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $path = Join-Path $env:TEMP "t1828-$Name.png"
        $shot.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $c = Get-TestCaptureContent -Shot $shot
        Close-TestWindowPixels -Shot $shot
        "  (saved $path; distinct=$($c.Distinct) top=$([math]::Round($c.TopShare,2)))"
        return $c
    } catch {
        "  capture failed: $($_.Exception.Message)"
        return $null
    }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1828'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    # T1831: the grid-edge oracles assume flush flat panes; the elevated default adds a grid margin (pane-elevation.ps1 covers that).
    $errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"

    # Wide enough for the pinned panel (>= 720 DIP), so step 3 tests the pin
    # and not the narrow fallback.
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 600

    $leaves = Get-Leaves
    $pId0 = if ($leaves.Count -ge 1) { $leaves[0].id } else { '' }
    Assert "setup: +list --json answers with the first pane" ($pId0 -ne '')
    $hP = (@(Get-Panes $top))[0].Hwnd
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 900
    $h1 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP } | Select-Object -First 1).Hwnd
    Assert "setup: two visible panes" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 2 -and $h1)

    "== 1: the mini rail is up by default, and the grid starts beside it"
    $sb = Get-Sidebar $top
    if ($NegativeControl) { "  NEGATIVE CONTROL: expecting NO sidebar - this run MUST fail"; $sb = $null }
    Assert "a GhozttyPaneSidebar child exists and is visible" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $client = Get-TestWindowRect -Window $top -Client
    Assert "it sits at the client's left edge ($($sb.Left) vs $($client.Left))" ([math]::Abs($sb.Left - $client.Left) -le 1)
    Assert "it is the 68 DIP rail ($($sb.Width) vs $(Px 68))" ([math]::Abs($sb.Width - (Px 68)) -le 1)
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid starts right after the rail (P.left $($p.Left), rail.right $($sb.Right))" ($p.Left -ge $sb.Right -and $p.Left - $sb.Right -le (Px 4))
    $c = Save-Shot $sb 'rail'
    Assert "the rail paints content, not one flat fill" ($null -ne $c -and $c.Distinct -ge 3)

    "== 2: a click on a stashed tile restores the pane"
    Assert "+stash s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+stash --target=s1") -eq 0)
    Assert "s1 is stashed" (Wait-Stashed 's1' $true)
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top
    [void](Save-Shot $sb 'rail-stashed')
    # Roster: P (grid), s1 (stashed).
    $r = Click $top $sb.Hwnd (Get-TileCenter $sb 1 1)
    Assert "tile click delivered" $r
    Assert "clicking s1's tile restored it" (Wait-Stashed 's1' $false)
    Start-Sleep -Milliseconds 400
    Assert "s1 is back on screen" (@(Get-Panes $top | Where-Object { $_.Hwnd -eq $h1 -and $_.Visible }).Count -eq 1)

    "== 3: the pin opens the panel and the grid moves over"
    $railW = $sb.Width
    $r = Click $top $sb.Hwnd (Get-PinCenter $sb 'mini')
    Assert "pin click delivered" $r
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "the pinned panel is 240 DIP ($($sb.Width) vs $(Px 240))" ([math]::Abs($sb.Width - (Px 240)) -le 1)
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid starts right after the panel (P.left $($p.Left), panel.right $($sb.Right))" ($p.Left -ge $sb.Right -and $p.Left - $sb.Right -le (Px 4))
    $c = Save-Shot $sb 'panel'
    Assert "the panel paints content, not one flat fill" ($null -ne $c -and $c.Distinct -ge 3)

    "== 4: a row's hover button stashes, a rail tile restores"
    # Row 0 is P. Its compact button: 20 DIP, sm (4) from the row's trailing
    # edge, which is the 8 DIP fill inset in from the panel's; the button is
    # centered in the row, whose middle is at least 16 DIP below the header.
    $bx = $sb.Right - (Px 8) - (Px 4) - [int]((Px 20) / 2)
    $by = $sb.Top + (Px 36) + (Px 16)
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $bx -Y $by -Action move)
    Start-Sleep -Milliseconds 200
    $r = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $bx -Y $by -Action click
    Assert "row button click delivered" $r
    Assert "P is stashed by its row's button" (Wait-Stashed $pId0 $true)
    Start-Sleep -Milliseconds 400
    Assert "s1 holds the screen alone" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 1)
    # Back to the rail, where the stashed tile is at a computable spot.
    $sb = Get-Sidebar $top
    [void](Click $top $sb.Hwnd (Get-PinCenter $sb 'expanded'))
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "unpinned back to the rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 68)) -le 1)
    # Roster now: s1 (grid), P (stashed).
    [void](Click $top $sb.Hwnd (Get-TileCenter $sb 1 1))
    Assert "clicking P's tile restored it" (Wait-Stashed $pId0 $false)

    "== 5: ctrl+shift+s hides and shows the sidebar"
    Assert "focus P for the chord" (Focus-TestWindow -Window $top -Child ([IntPtr]$hP))
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl,shift -Key S
    Assert "ctrl+shift+s delivered" $r
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "the sidebar is hidden" ($null -eq $sb -or -not $sb.Visible)
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    $client = Get-TestWindowRect -Window $top -Client
    Assert "the grid starts at the client's left edge ($($p.Left) vs $($client.Left))" ($p.Left - $client.Left -le (Px 4))
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl,shift -Key S)
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "a second ctrl+shift+s shows it again" ($null -ne $sb -and $sb.Visible)

    "== 6: pinned in a narrow window, the rail stands in for the panel"
    [void](Click $top $sb.Hwnd (Get-PinCenter $sb 'mini'))
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "pinned again ($($sb.Width))" ([math]::Abs($sb.Width - (Px 240)) -le 1)
    [void](Set-TestWindowSize -Window $top -Width (Px 600) -Height (Px 600))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "under 720 DIP the column is the rail ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 68)) -le 1)
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "wide again, the panel comes back ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 240)) -le 1)

    "== 7: unpinning leaves the card open over the grid; it contracts when the pointer is not on it"
    $pBefore = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-PinCenter $sb 'expanded'))
    $openLine = $null; $closeLine = $null
    $deadline = (Get-Date).AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $new = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
        $openLine = $new | Where-Object { $_ -match 'pane sidebar card open reason=unpin' } | Select-Object -First 1
        $closeLine = $new | Where-Object { $_ -match 'pane sidebar card close reason=left' } | Select-Object -First 1
    } while ((-not $openLine -or -not $closeLine) -and (Get-Date) -lt $deadline)
    "  $openLine"
    "  $closeLine"
    Assert "unpinning opened the card (log)" ($null -ne $openLine)
    $sb = Get-Sidebar $top
    Assert "the column is the 68 DIP rail again ($($sb.Width))" ([math]::Abs($sb.Width - (Px 68)) -le 1)
    if ($openLine -match 'column=(-?\d+),(-?\d+),(-?\d+),(-?\d+) card=(-?\d+),(-?\d+),(-?\d+),(-?\d+)') {
        $col = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        $crd = @([int]$Matches[5], [int]$Matches[6], [int]$Matches[7], [int]$Matches[8])
        $wantW = (Px 12) + (Px 240) + (Px 12)
        Assert "the card opened at the column's top-left ($($crd[0]),$($crd[1]) vs $($col[0]),$($col[1]))" ($crd[0] -eq $col[0] -and $crd[1] -eq $col[1])
        Assert "the card is the panel's width plus the rail's margins ($($crd[2] - $crd[0]) vs $wantW)" ([math]::Abs(($crd[2] - $crd[0]) - $wantW) -le 1)
        Assert "the card is as tall as the column" (($crd[3] - $crd[1]) -eq ($col[3] - $col[1]))
        Assert "while open, the column stayed the rail ($($col[2] - $col[0]) vs $(Px 68))" ([math]::Abs(($col[2] - $col[0]) - (Px 68)) -le 1)
    } else {
        Assert "the open line carries the column and card rects" $false
    }
    $pAfter = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid sits beside the rail, not under the card (P.left $($pAfter.Left), rail.right $($sb.Right))" ($pAfter.Left -ge $sb.Right -and $pAfter.Left - $sb.Right -le (Px 4))
    $card = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard' -AllowHidden
    Assert "the card is a GhozttyPaneSidebarCard popup of this process" ($card -ne [IntPtr]::Zero)
    if ($card -ne [IntPtr]::Zero) {
        $cr = Get-TestWindowRect -Window $card
        $m = Px 12
        $midY = [int]($cr.Height / 2)
        # T1865: the card is a per-pixel-alpha layer, not a region-clipped
        # popup - a region is a 1-bit edge and cut the card's shadow off at
        # the card. So: no region, and clicks follow the card's SHAPE through
        # its hit test. The column and the card's middle are the card's; the
        # trailing margin (where the shadow falls) and the rounded-off
        # top-right corner pass through to the pane underneath.
        Assert "the card is a layered window (per-pixel alpha, WS_EX_LAYERED)" (((Get-TestWindowStyle -Window $card -ExStyle) -band 0x00080000) -ne 0)
        Assert "the card has no window region (its shape is its alpha)" ($null -eq (Get-TestWindowRegionHits -Window $card -Points @(0, 0)))
        $pts = @(
            @{ Name = 'the column strip is the card''s'; X = [int]((Px 68) / 2); Y = 2; Want = 1 },
            @{ Name = 'the card''s middle is the card''s'; X = [int]($cr.Width / 2); Y = $midY; Want = 1 },
            @{ Name = 'the trailing margin passes the click to the grid'; X = ($cr.Width - [int]($m / 2)); Y = $midY; Want = -1 },
            @{ Name = 'the card''s rounded top-right corner passes it too'; X = ($cr.Width - $m - 1); Y = $m; Want = -1 })
        foreach ($p in $pts) {
            $route = Get-TestMouseRoute -Window $top -Target $card -X ($cr.Left + $p.X) -Y ($cr.Top + $p.Y)
            Assert "$($p.Name) (hit $($route.Code), want $($p.Want))" ($route.Code -eq $p.Want)
        }
    }
    Assert "with the pointer elsewhere it contracted after the grace period (log)" ($null -ne $closeLine)
    Start-Sleep -Milliseconds 300
    $cardTop = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard'
    Assert "the card is hidden once contracted" ($cardTop -eq [IntPtr]::Zero)

    "== 7b: a press held on the open card keeps it open past the grace period; letting go off it closes it"
    $sb = Get-Sidebar $top
    [void](Click $top $sb.Hwnd (Get-PinCenter $sb 'mini'))   # pin
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-PinCenter $sb 'expanded'))   # unpin: the card opens
    # The press lands on the open card's header caption - no control there -
    # and must beat the 280 ms grace period that the open started, so it is
    # the very next thing this script does.
    $hx = $sb.Left + (Px 12) + (Px 40); $hy = $sb.Top + (Px 12) + (Px 18)
    $card = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard'
    $down = $false
    if ($card -ne [IntPtr]::Zero) { $down = Send-TestMouse -Window $top -Target $card -X $hx -Y $hy -Action down }
    Assert "the press reached the open card" $down
    Start-Sleep -Milliseconds 900
    $new = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
    $closedEarly = @($new | Where-Object { $_ -match 'pane sidebar card close' }).Count
    Assert "held: no close after 3x the grace period ($closedEarly)" ($closedEarly -eq 0)
    Assert "held: the card is still on screen" ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard') -ne [IntPtr]::Zero)
    # T1865: the card is layered, and a layered window's pixels cannot be
    # read back off the test desktop (readonly-badge.ps1's CAPTURE LIMIT), so
    # the card logs what it handed the window manager on its first present:
    # solid pixels with real content, and partial-alpha ones - the
    # antialiased edge and the shadow that falls on the grid.
    $layerLine = $new | Where-Object { $_ -match 'pane sidebar card layer \d+x\d+ solid=' } | Select-Object -Last 1
    "  $layerLine"
    $lm = [regex]::Match([string]$layerLine, 'layer (\d+)x(\d+) solid=(\d+) partial=(\d+) distinct=(\d+)')
    Assert "the open card presented a layer (log)" $lm.Success
    if ($lm.Success) {
        $lw = [int]$lm.Groups[1].Value; $lh = [int]$lm.Groups[2].Value
        $solid = [int]$lm.Groups[3].Value; $partial = [int]$lm.Groups[4].Value
        Assert "the open card paints content, not one flat fill (distinct=$($lm.Groups[5].Value))" ([int]$lm.Groups[5].Value -ge 3)
        Assert "the column and the card are solid ($solid)" ($solid -gt (Px 68) * $lh)
        # The shadow runs down the card's whole trailing edge and along its
        # bottom: at least a few pixels deep over the card's height.
        Assert "the shadow and the antialiased edge are partial alpha ($partial over a ${lh}px card)" ($partial -ge 2 * $lh)
        Assert "and the rest of the margin is clear ($($lw * $lh - $solid - $partial) clear)" (($solid + $partial) -lt $lw * $lh)
    }
    # Let go in the trailing margin - off the card.
    $cr = Get-TestWindowRect -Window $card
    if ($card -ne [IntPtr]::Zero) { [void](Send-TestMouse -Window $top -Target $card -X ($cr.Right - (Px 4)) -Y $hy -Action up) }
    $closeLine = $null
    $deadline = (Get-Date).AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 100
        $closeLine = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore | Where-Object { $_ -match 'pane sidebar card close reason=left' }) | Select-Object -First 1
    } while (-not $closeLine -and (Get-Date) -lt $deadline)
    Assert "let go off the card, it contracted (log)" ($null -ne $closeLine)

    "== 8: a pointer on the rail's card arms the intent timer; the margin does not"
    $sb = Get-Sidebar $top
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    # The rail's top margin (above the card): not the card.
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + (Px 34)) -Y ($sb.Top + (Px 4)) -Action move)
    Start-Sleep -Milliseconds 400
    $armedMargin = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore | Where-Object { $_ -match 'pane sidebar hover-open armed' }).Count
    Assert "a pointer in the rail's margin arms nothing ($armedMargin)" ($armedMargin -eq 0)
    $t = Get-TileCenter $sb 0 2
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $t.X -Y $t.Y -Action move)
    Start-Sleep -Milliseconds 400
    $armed = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore | Where-Object { $_ -match 'pane sidebar hover-open armed delay=100ms' })
    Assert "a pointer on the rail's card armed Mac's 100 ms intent timer ($($armed.Count))" ($armed.Count -ge 1)
    $opened = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore | Where-Object { $_ -match 'pane sidebar card open reason=hover' }).Count
    Assert "the timer re-checked the REAL pointer (elsewhere) and opened nothing ($opened)" ($opened -eq 0)

    "== 9: tooltips on every tile and the pin; a tile's names its pane"
    $tips = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar tips ' })
    $railTips = $tips | Where-Object { $_ -match 'rail=3 card=0 mode=mini tile0=' } | Select-Object -Last 1
    "  $railTips"
    Assert "the rail registered the pin and both tiles (rail=3)" ($null -ne $railTips)
    Assert "a tile's tip is the pane's title, then 'Click to focus'" ($null -ne $railTips -and $railTips -match 'tile0=\S.*\|Click to focus$')
    $cardTips = $tips | Where-Object { $_ -match 'card=3' } | Select-Object -First 1
    "  $cardTips"
    Assert "the open card registered its pin and both rows (card=3)" ($null -ne $cardTips)

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
        update -Guard pane-sidebar -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1828' -Path $transcript `
        -Label 'T1828 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
