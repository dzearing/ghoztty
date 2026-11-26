# T1879 acceptance: another window's row in the all-windows sidebar is a drag
# source (Mac `PaneSidebarRow` `followsPointer: !isForeign`: not a list drag,
# carried with a preview), and another window's GROUP in the expanded outline
# is a join target (Mac `windowGroups` / `.joinWindow`, the header ringed with
# the accent while targeted - `PaneSidebarWindowHeader.isDropTarget`).
#
# Layout: window A "zeta" (P), wB "Bravo" (b1 + b2), wC "Charlie" (c1). All
# in A's sidebar, expanded, all-windows on, every group unfolded:
#
#   A. b2's row (B's, so foreign in A) pressed and carried onto Charlie's
#      header: the drag is B's (`row drag start ... foreign=1`), Charlie's
#      header rings (`pane sidebar join tile=on`, and the header's pixels
#      change), and the release moves b2 - the same HWND - into window C
#      (`pane drop join window other=true`). The ring comes off with the drag.
#   B. One of Charlie's rows (foreign again) carried into A's own GRID, beside
#      P: the pane - the same HWND - is now A's, and P is still A's (a split,
#      not a swap that sent P away).
#   C. (T2329, Mac b7de64ce8) A renamed Alpha so it sorts first; A's own row
#      dragged: mid-drag the outline opens the drag-only stash well under A's
#      last pane (`tray=<x>,<y>`), the head below moves down one row and
#      nothing above it moves; released on the well (`tray hot=1`) the pane
#      is stashed and the line reads `tray=-` again.
#   D. With that pane stashed, a drag of A's stashed row opens no well
#      (`tray=-` on every mid-drag line); Escape cancels it.
#
# Geometry comes from the `pane sidebar outline` log line (A's, `win=`).
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl never presses a row and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-foreign-drag.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1879-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1879')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale, [MidpointRounding]::AwayFromZero) }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to $Ms.
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    if ($hit) {
        Start-Sleep -Milliseconds 300
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    }
    return $hit
}
# Parse a `pane sidebar outline` line: heads and items, client coordinates.
function Read-Outline([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=(\S*) ') { return $null }
    $o = @{ Raw = $Line; Mode = $Matches[1]; Heads = @(); Items = @(); Chev = @() }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PWU])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    if ($Line -match ' chev=(\S*)') { foreach ($c in ($Matches[1] -split ';' | Where-Object { $_ })) { $xy = $c -split ','; $o.Chev += , @{ X = [int]$xy[0]; Y = [int]$xy[1] } } }
    return $o
}
function Head($o, [int]$Group) { $o.Heads | Where-Object { $_.Kind -eq 'W' -and $_.Group -eq $Group } | Select-Object -First 1 }
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
# The HWNDs of the terminals a top-level window holds.
function Get-TermHwnds($w) { @(Get-TestChildWindows -Window ([IntPtr]$w) -Class 'GhozttyTerminal' | ForEach-Object { [int64]$_.Hwnd }) }
# A header's pixels across its middle row, from a synchronous capture.
function Get-HeadRow($sb, $head) {
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        # The header's whole band, every other pixel: the ring is a 2 DIP
        # stroke round the pill, so some row of it crosses the band.
        $px = @()
        $y0 = [math]::Max(0, $head.Y - (Px 18)); $y1 = [math]::Min($shot.Bitmap.Height - 1, $head.Y + (Px 18))
        for ($y = $y0; $y -le $y1; $y += 1) {
            for ($x = 0; $x -lt $shot.Bitmap.Width; $x += 2) { $px += $shot.Bitmap.GetPixel($x, $y).ToArgb() }
        }
        Close-TestWindowPixels -Shot $shot
        return ($px -join ',')
    } catch { "  head capture failed: $($_.Exception.Message)" | Out-Host; return $null }
}
# The group index of a window in the all-windows order (the `order=` names).
function Get-GroupOf([string]$Name) {
    $g = Wait-Log 'pane sidebar all-windows groups=' 0 1000
    if ($g -notmatch ' order=(.*)$') { return -1 }
    $names = @($Matches[1] -split '\|')
    for ($k = 0; $k -lt $names.Count; $k++) { if ($names[$k] -eq $Name) { return $k } }
    return -1
}
# Press a row in A's sidebar and travel past the drag threshold on it (the row
# holds the press until then); from there the pane's own window has the
# capture, so later moves go to IT, in screen coordinates (-Client).
function Start-RowDrag($top, $sb, $row) {
    $x = $sb.Left + $row.X; $y = $sb.Top + $row.Y
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y $y -Action down -Client
    $ok = $ok -and (Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y ($y + (Px 14)) -Action move -Client)
    Start-Sleep -Milliseconds 250
    return $ok
}
function Move-Drag($owner, [int]$X, [int]$Y, [string]$Action) {
    return Send-TestMouse -Window ([IntPtr]$owner) -Target ([IntPtr]$owner) -X $X -Y $Y -Action $Action -Client
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1879'

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
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 900))
    Start-Sleep -Milliseconds 600

    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=Bravo") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: b2 split in wB ($(Get-CliErr))" ((Invoke-Cli "+split --target=b1 --direction=right --name=b2") -eq 0)
    Start-Sleep -Milliseconds 700
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1 --title=Charlie") -eq 0)
    Start-Sleep -Milliseconds 1200

    # Which top-level is which: A is $top; B holds two terminals, C one.
    $others = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { [int64]$_.Hwnd -ne [int64]$top })
    $wB = $others | Where-Object { @(Get-TermHwnds $_.Hwnd).Count -eq 2 } | Select-Object -First 1
    $wC = $others | Where-Object { @(Get-TermHwnds $_.Hwnd).Count -eq 1 } | Select-Object -First 1
    Assert "setup: three windows, B with two panes and C with one" ($null -ne $wB -and $null -ne $wC)
    if ($null -eq $wB -or $null -eq $wC) { return }
    $hB = [int64]$wB.Hwnd; $hC = [int64]$wC.Hwnd
    $termsA0 = @(Get-TermHwnds $top)

    Assert "setup: A is the active window" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 500
    $sb = Get-Sidebar $top
    Assert "setup: A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    Assert "setup: all-windows toggle clicked" (ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "setup: the all-windows scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark))
    Assert "setup: three groups listed (log)" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 ' $mark))
    Start-Sleep -Milliseconds 500
    $aLine = "pane sidebar outline mode=expanded .* win=$([int64]$top)$"
    # Every window opens folded (T2408): unfold each by its chevron.
    for ($gi = 0; $gi -lt 3; $gi++) {
        $o = Read-Outline (Wait-Log $aLine 0 1000)
        $k = -1
        if ($o) { for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'W' -and $o.Heads[$j].Group -eq $gi) { $k = $j } } }
        $mark = Get-LogCount
        if ($k -ge 0 -and $k -lt $o.Chev.Count) { [void](ClickAt $top $sb $o.Chev[$k]) }
        [void](Wait-Log 'pane sidebar unfold' $mark 2000)
    }
    Start-Sleep -Milliseconds 600
    $gB = Get-GroupOf 'Bravo'; $gC = Get-GroupOf 'Charlie'
    $o = Read-Outline (Wait-Log $aLine 0 1000)
    $bRows = if ($o) { @($o.Items | Where-Object { $_.Group -eq $gB }) } else { @() }
    $cHead = if ($o) { Head $o $gC } else { $null }
    Assert "setup: A's outline lists Bravo's two rows and Charlie's header (B=g$gB, C=g$gC)" ($bRows.Count -eq 2 -and $null -ne $cHead)

    "== A: another window's row carried onto a third window's group joins it (T1879)"
    if ($bRows.Count -eq 2 -and $cHead) {
        $row = $bRows[1]
        $termsB0 = @(Get-TermHwnds $hB)
        $termsC0 = @(Get-TermHwnds $hC)
        $bare = Get-HeadRow $sb $cHead
        $mark = Get-LogCount
        if ($NegativeControl) {
            "  NEGATIVE CONTROL: no row is pressed - this run MUST fail"
        } else {
            Assert "A: press and travel on Bravo's row delivered" (Start-RowDrag $top $sb $row)
        }
        Assert "A: the foreign row started its window's drag (log)" ($null -ne (Wait-Log 'pane sidebar row drag start .* foreign=1' $mark 2000))
        $hx = $sb.Left + $cHead.X; $hy = $sb.Top + $cHead.Y
        [void](Move-Drag $hB ($hx + (Px 6)) ($hy - (Px 20)) 'move')
        Start-Sleep -Milliseconds 150
        Assert "A: move onto Charlie's header delivered" (Move-Drag $hB $hx $hy 'move')
        Assert "A: Charlie's header rings as the join target (log)" ($null -ne (Wait-Log 'pane sidebar join tile=on' $mark 2000))
        Start-Sleep -Milliseconds 300
        $ringed = Get-HeadRow $sb $cHead
        $mark2 = Get-LogCount
        [void](Move-Drag $hB $hx $hy 'up')
        Assert "A: the release joins Charlie's window (log)" ($null -ne (Wait-Log 'pane drop join window other=true' $mark2 3000))
        Assert "A: the ring comes off with the drag (log)" ($null -ne (Wait-Log 'pane sidebar join tile=off' $mark2 2000))
        Assert "A: the header is painted differently while ringed (pixels)" ($null -ne $ringed -and $null -ne $bare -and $ringed -ne $bare)
        Start-Sleep -Milliseconds 1000
        $termsB1 = @(Get-TermHwnds $hB)
        $termsC1 = @(Get-TermHwnds $hC)
        $moved = @($termsB0 | Where-Object { $termsB1 -notcontains $_ })
        Assert "A: one pane left Bravo ($($termsB0.Count) -> $($termsB1.Count))" ($moved.Count -eq 1 -and $termsB1.Count -eq 1)
        Assert "A: ...and is the same HWND inside Charlie, so its shell came with it" ($moved.Count -eq 1 -and $termsC1 -contains $moved[0] -and $termsC1.Count -eq ($termsC0.Count + 1))
    }

    "== B: another window's row carried into this window's grid comes here (T1879)"
    Assert "setup: A is the active window again" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    $o = Read-Outline (Wait-Log $aLine 0 1000)
    $cRows = if ($o) { @($o.Items | Where-Object { $_.Group -eq $gC }) } else { @() }
    $pBox = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible) | Select-Object -First 1
    Assert "setup: Charlie lists a row in A's outline and A shows P" ($cRows.Count -ge 1 -and $null -ne $pBox)
    if ($cRows.Count -ge 1 -and $pBox) {
        $termsC0 = @(Get-TermHwnds $hC)
        $mark = Get-LogCount
        if (-not $NegativeControl) {
            Assert "B: press and travel on Charlie's row delivered" (Start-RowDrag $top $sb $cRows[0])
        }
        Assert "B: the foreign row started its window's drag (log)" ($null -ne (Wait-Log 'pane sidebar row drag start .* foreign=1' $mark 2000))
        # Toward P's right edge, mid-height: a split of P, not a swap.
        $dx = $pBox.Left + [int]($pBox.Width * 0.85); $dy = $pBox.Top + [int]($pBox.Height / 2)
        [void](Move-Drag $hC ($dx - (Px 30)) $dy 'move')
        Start-Sleep -Milliseconds 150
        Assert "B: move onto A's grid delivered" (Move-Drag $hC $dx $dy 'move')
        Start-Sleep -Milliseconds 400
        [void](Move-Drag $hC $dx $dy 'up')
        Start-Sleep -Milliseconds 1200
        $termsA1 = @(Get-TermHwnds $top)
        $termsC1 = @(Get-TermHwnds $hC)
        $came = @($termsC0 | Where-Object { $termsC1 -notcontains $_ })
        Assert "B: one pane left Charlie ($($termsC0.Count) -> $($termsC1.Count))" ($came.Count -eq 1)
        Assert "B: ...and is the same HWND, now in A" ($came.Count -eq 1 -and $termsA1 -contains $came[0])
        Assert "B: P is still A's (a split beside it, not a swap)" (@($termsA0 | Where-Object { $termsA1 -contains $_ }).Count -eq $termsA0.Count)
    }

    "== C: a drag opens this window's empty stash well under its last pane, and the release closes it (T2329)"
    # A now holds P and the pane B brought in, nothing stashed. Renamed so it
    # sorts FIRST: the well opens under A's last pane, and only a group laid
    # out below it shows the rows opening to make room.
    $mark = Get-LogCount
    Assert "setup: window A renamed Alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=Alpha") -eq 0)
    [void](Wait-Log 'pane sidebar all-windows groups=' $mark 2000)
    Assert "setup: A is the active window again" (Set-TestActiveWindow -Window $top)
    $sb = Get-Sidebar $top
    $gA = Get-GroupOf 'Alpha'
    # The relaid outline after the rename (Wait-Log re-reads once it lands).
    $o0 = Read-Outline (Wait-Log $aLine $mark 3000)
    $aRows = @(if ($o0) { $o0.Items | Where-Object { $_.Group -eq $gA -and $_.Sec -eq 'g' } | Sort-Object { $_.Y } })
    $below0 = if ($o0 -and $aRows.Count -gt 0) { $o0.Heads | Where-Object { $_.Kind -eq 'W' -and $_.Group -ne $gA -and $_.Y -gt $aRows[-1].Y } | Sort-Object { $_.Y } | Select-Object -First 1 } else { $null }
    Assert "setup: A's group (g$gA) lists two grid rows and a window head below them" ($aRows.Count -eq 2 -and $null -ne $below0)
    Assert "C: at rest the outline carries no well (tray=-)" ($o0 -and $o0.Raw -match ' tray=- ')
    $visA0 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible).Count
    if ($aRows.Count -eq 2 -and $below0) {
        $mark = Get-LogCount
        if (-not $NegativeControl) {
            Assert "C: press and travel on A's own first row delivered" (Start-RowDrag $top $sb $aRows[0])
        }
        Assert "C: A's own row started a drag (log)" ($null -ne (Wait-Log 'pane sidebar row drag start item=\d+ section=grid$' $mark 2000))
        $dLine = Wait-Log "pane sidebar outline .* tray=\d+,\d+ win=$([int64]$top)$" $mark 2000
        $o1 = Read-Outline $dLine
        $tx = $null; $ty = $null
        if ($dLine -match ' tray=(\d+),(\d+) ') { $tx = [int]$Matches[1]; $ty = [int]$Matches[2] }
        Assert "C: mid-drag the outline reports the well (tray=$tx,$ty)" ($null -ne $ty)
        Assert "C: ...under A's last pane, in its column (last row y=$($aRows[-1].Y), x=$($aRows[-1].X))" ($null -ne $ty -and $ty -gt $aRows[-1].Y -and [math]::Abs($tx - $aRows[-1].X) -le (Px 2))
        $below1 = if ($o1) { Head $o1 $below0.Group } else { $null }
        $grow = if ($below1) { $below1.Y - $below0.Y } else { 0 }
        Assert "C: ...and the window head below it sits one row lower (moved $grow px)" ($grow -ge (Px 20) -and $grow -le (Px 80))
        Assert "C: ...and above it nothing moved (A's first row y=$($aRows[0].Y))" ($o1 -and @($o1.Items | Where-Object { $_.Group -eq $gA -and $_.Y -eq $aRows[0].Y }).Count -ge 1)
        # Onto the well: the stash target lights, and the release stashes.
        $wx = $sb.Left + $tx; $wy = $sb.Top + $ty
        [void](Move-Drag $top $wx ($wy - (Px 12)) 'move')
        Assert "C: move onto the well delivered" (Move-Drag $top $wx $wy 'move')
        Assert "C: the well lights as the stash target (log)" ($null -ne (Wait-Log 'pane sidebar tray hot=1' $mark 2000))
        $mark2 = Get-LogCount
        [void](Move-Drag $top $wx $wy 'up')
        Assert "C: the release stashes the pane (log)" ($null -ne (Wait-Log 'pane drop stashed index=' $mark2 3000))
        $deadline = (Get-Date).AddSeconds(3)
        do {
            $visA1 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible).Count
            if ($visA1 -lt $visA0) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        Assert "C: ...one of A's panes left the screen ($visA0 -> $visA1)" ($visA1 -eq ($visA0 - 1))
        $o2 = Read-Outline (Wait-Log $aLine $mark2 2000)
        Assert "C: after release the outline reads tray=-" ($o2 -and $o2.Raw -match ' tray=- ')
        # @() OUTSIDE the if: a one-element result unrolls to the hashtable,
        # whose .Count is its key count.
        $sRows = @(if ($o2) { $o2.Items | Where-Object { $_.Group -eq $gA -and $_.Sec -eq 's' } })
        if ($sRows.Count -ne 1) { "  (after release: $(if ($o2) { $o2.Raw } else { 'no outline line' }))" }
        Assert "C: ...and A's group now lists the pane as stashed" ($sRows.Count -eq 1)
        $below2 = if ($o2) { Head $o2 $below0.Group } else { $null }
        "  (head below A: rest y=$($below0.Y), mid-drag y=$($below1.Y), after release y=$($below2.Y))"
        Assert "C: ...and the head below is no longer pushed down by a well" ($below2 -and $below2.Y -lt $below1.Y)

        "== D: no well while this window already stashes a pane (T2329)"
        if ($sRows.Count -eq 1) {
            $mark = Get-LogCount
            if (-not $NegativeControl) {
                Assert "D: press and travel on A's stashed row delivered" (Start-RowDrag $top $sb $sRows[0])
            }
            Assert "D: the stashed row started a drag (log)" ($null -ne (Wait-Log 'pane sidebar row drag start item=\d+ section=stashed$' $mark 2000))
            Assert "D: the drag armed A's sidebar (log)" ($null -ne (Wait-Log 'pane drag sidebars armed=' $mark 2000))
            $dl = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $mark | Where-Object { $_ -match "pane sidebar outline .* win=$([int64]$top)$" })
            Assert "D: mid-drag A's outline still reads tray=- ($($dl.Count) line(s))" ($dl.Count -ge 1 -and @($dl | Where-Object { $_ -notmatch ' tray=- ' }).Count -eq 0)
            $hP = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible) | Select-Object -First 1
            $k = if ($hP) { Send-TestKeys -Window $top -Target ([IntPtr]$hP.Hwnd) -Key Escape } else { $false }
            Assert "D: Escape delivered" $k
            Assert "D: Escape ended it - the held row glides back (log)" ($null -ne (Wait-Log 'pane sidebar row settle from=' $mark 2000))
            $mark3 = Get-LogCount
            [void](Move-Drag $top ($sb.Left + $sRows[0].X) ($sb.Top + $sRows[0].Y + (Px 14)) 'up')
            Assert "D: the release after the cancel drops nothing (log)" ($null -eq (Wait-Log 'pane drop ' $mark3 1000))
            $o3 = Read-Outline (Wait-Log $aLine 0 1000)
            Assert "D: the pane is still stashed afterwards" ($o3 -and @($o3.Items | Where-Object { $_.Group -eq $gA -and $_.Sec -eq 's' }).Count -eq 1)
        }
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
        update -Guard pane-sidebar-foreign-drag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1879' -Path $transcript `
        -Label 'T1879 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
