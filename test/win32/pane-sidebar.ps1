# T1828 acceptance: the pane sidebar on Windows (Mac 597a193cc,
# docs/design/pane-sidebar.md). A column left of the split grid that lists
# every pane of the active tab - expanded as a flat panel, collapsed as the
# mini rail - where a click focuses a pane or restores a stashed one, a row's
# hover button stashes or restores, and ctrl+shift+s hides it outright.
#
# Layout: the first pane P, then `+split right` -> s1. What it checks:
#
#   1. Default (Mac's default): the mini rail is up - a visible
#      GhozttyPaneSidebar child at the client's left edge, 76 DIP wide, and
#      the grid starts right after it (P's left edge == the rail's right).
#      It paints real content (a synchronous WM_PRINTCLIENT capture is not
#      one flat fill).
#   2. +stash s1, then a click on s1's rail tile restores it and puts it
#      back on screen.
#   3. The toggle turns the rail into the 240 DIP panel and the grid moves
#      over by exactly the difference; the panel paints content too.
#  3b. (T2276, Mac 543489bca) With nothing stashed and no drag live, the
#      empty tray is still laid out: a painted dashed well below the last
#      row, with NO STASHED caption over it in either mode (T2313, Mac
#      82b9c5501 - the well's own text says what it is; the `tray=` field of
#      the rows line, `cap=0`). Step 4 checks it gives way to
#      the stashed row once P is stashed.
#   4. The first row's hover button stashes P (a grid pane); a click on the
#      stashed tile in the rail brings it back.
#   5. ctrl+shift+s hides the sidebar: no column, the grid starts at the
#      client's left edge. Again shows it.
#   6. Expanded, a window narrower than 720 DIP shows the rail, not the panel.
#   7. (T2289, Mac e77422577/dc2bbab6b) The toggle never moves: the panel's
#      header logs its toggle at the very pixels the rail's does, and a click
#      there collapses straight back to the 76 DIP rail - no card opens over
#      the grid, and no pane moves past the rail.
#   8. (T2289) No hover-open: a pointer resting on the rail's tiles opens
#      nothing - no GhozttyPaneSidebarCard popup, no width change, no open
#      in the log.
#   9. (T2289) In a window too narrow for the panel the rail's toggle is off:
#      its tip says "Too narrow to expand", a click is refused (log) and the
#      column stays the rail, then and after the window is widened again.
#  9b. (T1842) Every tile and the toggle carries a tooltip, and a tile's
#      names its pane, then the click hint (Mac's .help); the toggle's says
#      what a click does. Scored from the `pane sidebar tips` log line:
#      comctl32 tooltips are never shown on a background desktop.
#  10. (T2085, Mac f9e99a860) A banner's title names its pane: `## Fix login`
#      on P makes its row (and its tile's tip) read "Fix login" with the
#      subtitle left to the directory; a banner with no title gives the pane
#      title back and becomes the subtitle; a one-line bold banner is a title
#      too; clearing restores the row exactly. Scored from the `pane sidebar
#      text` log line - drawn text cannot be read back off a background desktop.
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
# The expanded column (T2290, Mac 0a547522d): the rail's card at the panel's
# width, in the rail's own 12 DIP insets (flat style), summed from the rounded
# parts the way the layout does.
function PanelColumn([double]$Dip) { (Px 12) + (Px $Dip) + (Px 12) }

# The rail's geometry, from pane_sidebar.zig's numbers (layoutMini, T2279):
# the 28 DIP toggle centred in the 52 DIP card, the header band the same
# clearance below it, then one row per pane - Mac's 41 DIP row, a 37 pill
# centred in it with 2 DIP above and below (T2311), the pill across the card
# less the 8 DIP fill inset - and an 8 DIP
# gap between the grid and stashed groups. Returns the tile's SCREEN center
# for item $Index, given how many items are in the grid section.
function Get-TileCenter($sb, [int]$Index, [int]$GridCount) {
    # The app's own geometry first (T2324: this window's + slot heads the
    # tiles, its height the header's - a font metric no arithmetic here has).
    $rows = Get-RowsLine 'mini'
    if ($null -ne $rows -and $Index -lt $rows.Items.Count) {
        return @{ X = $sb.Left + $rows.Items[$Index].X; Y = $sb.Top + $rows.Items[$Index].Y }
    }
    $margin = Px 12; $card = Px 52; $btn = Px 28; $group = Px 8
    $half = [math]::Max([int][math]::Round(2 * $script:scale, [MidpointRounding]::AwayFromZero), 1); $gap = 2 * $half; $pill = (Px 41) - $gap
    $inset = [int][math]::Truncate(($card - $btn) / 2)
    $y = $margin + $inset + $btn + $inset + $half
    for ($i = 0; $i -lt $Index; $i++) {
        $y += $pill + $gap
        if (($i + 1) -eq $GridCount -and $GridCount -gt 0) { $y += $group - $gap }
    }
    return @{ X = $sb.Left + $margin + [int]($card / 2); Y = $sb.Top + $y + [int]($pill / 2) }
}
# The collapse/expand toggle (T2289): the rail's first item and the panel
# header's first item, on the same pixels in both modes - centered in the
# rail card, the card's inset below its top.
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}
# The newest `pane sidebar rows` geometry line logged in mode $Mode (client
# coordinates): the toggle's center and whether it can expand, and each row.
function Get-RowsLine([string]$Mode) {
    $line = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match "pane sidebar rows mode=$Mode " }) | Select-Object -Last 1
    if ($null -eq $line) { return $null }
    $t = [regex]::Match($line, ' toggle=(-?\d+),(-?\d+) can=(\d)')
    $items = @([regex]::Matches($line, '@(-?\d+),(-?\d+)#') | ForEach-Object { @{ X = [int]$_.Groups[1].Value; Y = [int]$_.Groups[2].Value } })
    return @{
        Line = $line
        Toggle = if ($t.Success) { @{ X = [int]$t.Groups[1].Value; Y = [int]$t.Groups[2].Value } } else { $null }
        Can = if ($t.Success) { [int]$t.Groups[3].Value } else { -1 }
        Items = $items
    }
}
# The empty tray on a rows line (T2276): ` tray=<x>,<y> cap=<0|1>` while
# nothing is stashed, ` tray=-` once something is. Y and the last row's Y are
# client coordinates.
function Get-TrayState($rows) {
    if ($null -eq $rows) { return $null }
    $m = [regex]::Match($rows.Line, ' tray=(-|(-?\d+),(-?\d+) cap=(\d))')
    if (-not $m.Success) { return @{ Present = $false; Raw = 'no tray field'; Cap = -1 } }
    if ($m.Groups[1].Value -eq '-') { return @{ Present = $false; Raw = 'tray=-'; Cap = -1 } }
    $last = if ($rows.Items.Count -gt 0) { $rows.Items[$rows.Items.Count - 1].Y } else { -1 }
    return @{
        Present = $true; Raw = $m.Value.Trim()
        X = [int]$m.Groups[2].Value; Y = [int]$m.Groups[3].Value; Cap = [int]$m.Groups[4].Value
        LastRowY = $last
    }
}
# Distinct colors along the sidebar's client row $Y (a flat fill is 1).
function Get-RowInk($sb, [int]$Y) {
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $seen = @{}
        for ($x = 0; $x -lt $shot.Bitmap.Width; $x++) { $seen[$shot.Bitmap.GetPixel($x, $Y).ToArgb()] = 1 }
        Close-TestWindowPixels -Shot $shot
        return $seen.Count
    } catch { return 0 }
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

    # Wide enough for the expanded panel (>= 720 DIP), so step 3 tests the
    # toggle and not the narrow fallback.
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
    Assert "it is the 76 DIP rail ($($sb.Width) vs $(Px 76))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
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

    "== 3: the toggle expands the panel and the grid moves over"
    $railW = $sb.Width
    $railRows = Get-RowsLine 'mini'
    $r = Click $top $sb.Hwnd (Get-ToggleCenter $sb)
    Assert "toggle click delivered" $r
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "the expanded card is 240 DIP in the rail's insets ($($sb.Width) vs $(PanelColumn 240))" ([math]::Abs($sb.Width - (PanelColumn 240)) -le 1)
    $p = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid starts right after the panel (P.left $($p.Left), panel.right $($sb.Right))" ($p.Left -ge $sb.Right -and $p.Left - $sb.Right -le (Px 4))
    $c = Save-Shot $sb 'panel'
    Assert "the panel paints content, not one flat fill" ($null -ne $c -and $c.Distinct -ge 3)

    "== 3b: with nothing stashed, the empty tray is there at rest (T2276)"
    # Mac 543489bca: the tray is a drop target, so it is always in the list -
    # a dashed well - not only during a drag. Mac 82b9c5501 (T2313): with no
    # STASHED caption over it; the caption comes with the first stashed pane.
    $panelTray = Get-TrayState (Get-RowsLine 'expanded')
    Assert "the panel lays out the empty tray with no drag live ($($panelTray.Raw))" ($null -ne $panelTray -and $panelTray.Present)
    if ($panelTray -and $panelTray.Present) {
        Assert "no STASHED caption is laid out over the empty well (T2313)" ($panelTray.Cap -eq 0)
        Assert "it sits below the last pane row ($($panelTray.Y) vs $($panelTray.LastRowY))" ($panelTray.Y -gt $panelTray.LastRowY)
        $ink = Get-RowInk $sb $panelTray.Y
        Assert "the well paints something (distinct colors across it: $ink)" ($ink -ge 3)
    }
    $railTray = Get-TrayState $railRows
    Assert "the rail lays out the empty tray too, with no caption ($($railTray.Raw))" ($null -ne $railTray -and $railTray.Present -and $railTray.Cap -eq 0)

    "== 4: a row's hover button stashes, a rail tile restores"
    # Row 0 is P. Its stash button: 20 DIP, 4 DIP before the row's x (T2280),
    # which is sm (4) from the row's trailing edge - the 8 DIP fill inset in
    # from the card's, which is the 12 DIP inset in from the column's (T2290);
    # both are centered in the row, whose middle the geometry line names.
    $panelRows = Get-RowsLine 'expanded'
    Assert "setup: the panel logged its rows" ($null -ne $panelRows -and $panelRows.Items.Count -ge 1)
    $bx = $sb.Right - (Px 12) - (Px 8) - (Px 4) - (Px 20) - (Px 4) - [int]((Px 20) / 2)
    $by = $sb.Top + $(if ($null -ne $panelRows -and $panelRows.Items.Count -ge 1) { $panelRows.Items[0].Y } else { (Px 56) + (Px 16) })
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $bx -Y $by -Action move)
    Start-Sleep -Milliseconds 200
    $r = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $bx -Y $by -Action click
    Assert "row button click delivered" $r
    Assert "P is stashed by its row's button" (Wait-Stashed $pId0 $true)
    Start-Sleep -Milliseconds 400
    Assert "s1 holds the screen alone" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 1)
    # The tray holds P now: its rows take the well's place (T2276).
    Start-Sleep -Milliseconds 300
    $heldTray = Get-TrayState (Get-RowsLine 'expanded')
    Assert "with P stashed the empty well is gone ($(if ($heldTray) { $heldTray.Raw }))" ($null -ne $heldTray -and -not $heldTray.Present)
    # Back to the rail, where the stashed tile is at a computable spot.
    $sb = Get-Sidebar $top
    [void](Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "collapsed back to the rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
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

    "== 6: expanded in a narrow window, the rail stands in for the panel"
    [void](Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "expanded again ($($sb.Width))" ([math]::Abs($sb.Width - (PanelColumn 240)) -le 1)
    [void](Set-TestWindowSize -Window $top -Width (Px 600) -Height (Px 600))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "under 720 DIP the column is the rail ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 76)) -le 1)
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "wide again, the panel comes back ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - (PanelColumn 240)) -le 1)

    "== 7: the toggle never moves, and collapsing opens no card over the grid (T2289)"
    $panelRows = Get-RowsLine 'expanded'
    "  rail:  $($railRows.Line)"
    "  panel: $($panelRows.Line)"
    Assert "both geometry lines name the toggle" ($null -ne $railRows -and $null -ne $railRows.Toggle -and $null -ne $panelRows -and $null -ne $panelRows.Toggle)
    if ($null -ne $railRows.Toggle -and $null -ne $panelRows.Toggle) {
        Assert "the panel's toggle is the rail's, to the pixel ($($panelRows.Toggle.X),$($panelRows.Toggle.Y) vs $($railRows.Toggle.X),$($railRows.Toggle.Y))" ($panelRows.Toggle.X -eq $railRows.Toggle.X -and $panelRows.Toggle.Y -eq $railRows.Toggle.Y)
        $want = Get-ToggleCenter $sb
        Assert "...where the script expects it (+-1 px)" ([math]::Abs($sb.Left + $railRows.Toggle.X - $want.X) -le 1 -and [math]::Abs($sb.Top + $railRows.Toggle.Y - $want.Y) -le 1)
        Assert "...and every row sits below it" (@($panelRows.Items | Where-Object { $_.Y -le $panelRows.Toggle.Y }).Count -eq 0)
    }
    Assert "the wide window can expand (can=1)" ($panelRows.Can -eq 1)
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $new = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
    $sb = Get-Sidebar $top
    Assert "the header's toggle collapsed it to the 76 DIP rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
    Assert "...through the one toggle (log: expanded=false cause=header button)" (@($new | Where-Object { $_ -match 'pane sidebar expanded=false cause=header button' }).Count -ge 1)
    Assert "no card opened over the grid (no GhozttyPaneSidebarCard)" ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard' -AllowHidden) -eq [IntPtr]::Zero)
    Assert "...and nothing logged a card (log)" (@($new | Where-Object { $_ -match 'pane sidebar card ' }).Count -eq 0)
    $pAfter = Get-Panes $top | Where-Object { $_.Hwnd -eq $hP }
    Assert "the grid sits beside the rail (P.left $($pAfter.Left), rail.right $($sb.Right))" ($pAfter.Left -ge $sb.Right -and $pAfter.Left - $sb.Right -le (Px 4))

    "== 8: no hover-open - a pointer resting on the rail opens nothing"
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    $t = Get-TileCenter $sb 0 2
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $t.X -Y $t.Y -Action move)
    Start-Sleep -Milliseconds 200
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($t.X + 1) -Y $t.Y -Action move)
    Start-Sleep -Milliseconds 600
    $new = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
    $sb = Get-Sidebar $top
    Assert "the column is still the rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
    Assert "no card window exists" ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard' -AllowHidden) -eq [IntPtr]::Zero)
    Assert "nothing armed or opened (log)" (@($new | Where-Object { $_ -match 'hover-open|pane sidebar card ' }).Count -eq 0)

    "== 9: too narrow for the panel, the rail's toggle is off"
    [void](Set-TestWindowSize -Window $top -Width (Px 600) -Height (Px 600))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "narrow: the rail ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 76)) -le 1)
    $tip = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar tips ' }) | Select-Object -Last 1
    "  $tip"
    Assert "the toggle's tip says why it is off" ($tip -match 'toggle="Too narrow to expand')
    $narrowRows = Get-RowsLine 'mini'
    Assert "the geometry line says it cannot expand (can=0)" ($null -ne $narrowRows -and $narrowRows.Can -eq 0)
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 600
    $new = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logBefore)
    $sb = Get-Sidebar $top
    Assert "a click on the disabled toggle changed nothing ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
    Assert "...and flipped no hidden choice (log: no expanded=true)" (@($new | Where-Object { $_ -match 'pane sidebar expanded=true' }).Count -eq 0)
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    Assert "wide again, still the rail: the dead click did not expand it later ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
    $tip = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar tips ' }) | Select-Object -Last 1
    Assert "...and the toggle is on again (tip)" ($tip -match 'toggle="Expand the sidebar"')

    "== 9b: tooltips on every tile and the toggle; a tile's names its pane"
    $tips = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar tips ' })
    $railTips = $tips | Where-Object { $_ -match 'rail=3 toggle="Expand the sidebar" mode=mini tile0=' } | Select-Object -Last 1
    "  $railTips"
    Assert "the rail registered the toggle and both tiles (rail=3)" ($null -ne $railTips)
    Assert "a tile's tip is the pane's title, then 'Click to focus'" ($null -ne $railTips -and $railTips -match 'tile0=\S.*\|Click to focus$')
    $panelTips = $tips | Where-Object { $_ -match 'rail=3 toggle="Collapse the sidebar to icons" mode=expanded' } | Select-Object -First 1
    "  $panelTips"
    Assert "the panel registered its toggle and both rows, the toggle offering to collapse" ($null -ne $panelTips)

    "== 10: a banner's title names its pane's row and tile (T2085)"
    # Scored from the `pane sidebar text` line (each row's pane id, title and
    # subtitle), logged when any of them changes: text drawn on a background
    # desktop cannot be read back. P is tile 0, so its tip names it too.
    function Get-RowText([string]$Id) {
        $line = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar text ' }) | Select-Object -Last 1
        if ($null -eq $line) { return $null }
        $m = [regex]::Match($line, "#$([regex]::Escape($Id)) title=(?<t>[^;]*?) sub=(?<s>[^;]*);")
        if (-not $m.Success) { return $null }
        return @{ Title = $m.Groups['t'].Value; Sub = $m.Groups['s'].Value }
    }
    function Wait-RowText([string]$Id, [scriptblock]$Want, [int]$Ms = 5000) {
        $deadline = (Get-Date).AddMilliseconds($Ms)
        do {
            $r = Get-RowText $Id
            if ($null -ne $r -and (& $Want $r)) { return $r }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)
        return (Get-RowText $Id)
    }
    $before = Get-RowText $pId0
    "  before: title='$($before.Title)' sub='$($before.Sub)'"
    Assert "P's row is logged with its own title before any banner" ($null -ne $before -and $before.Title -ne '' -and $before.Title -ne 'Fix login')

    [void](Invoke-Cli "+set-banner --target=$pId0 `"## Fix login\n|  |  |\n|---|---|\n| **Status** | Working |`"")
    $titled = Wait-RowText $pId0 { param($r) $r.Title -eq 'Fix login' }
    "  titled: title='$($titled.Title)' sub='$($titled.Sub)'"
    Assert "a '## Fix login' banner names P's row 'Fix login'" ($null -ne $titled -and $titled.Title -eq 'Fix login')
    Assert "the subtitle is not the banner's title or table (the directory takes it)" ($null -ne $titled -and $titled.Sub -notmatch 'Fix login|Status|Working')
    Start-Sleep -Milliseconds 600
    $tip = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar tips ' }) | Select-Object -Last 1
    if ($tip -match ' mode=mini ') {
        Assert "P's rail tile tip names it by the banner title" ($tip -match 'tile0=Fix login\|')
    } else { "  (rail not in mini mode now - tile tip not scored: $tip)" }

    [void](Invoke-Cli "+set-banner --target=$pId0 `"Deploying to staging`"")
    $plain = Wait-RowText $pId0 { param($r) $r.Title -ne 'Fix login' }
    "  untitled: title='$($plain.Title)' sub='$($plain.Sub)'"
    Assert "a banner with no title gives P its own title back" ($null -ne $plain -and $plain.Title -eq $before.Title)
    Assert "...and its first line is the subtitle" ($null -ne $plain -and $plain.Sub -eq 'Deploying to staging')

    [void](Invoke-Cli "+set-banner --target=$pId0 `"**Ship it**`"")
    $bold = Wait-RowText $pId0 { param($r) $r.Title -eq 'Ship it' }
    Assert "a one-line banner opening with a bold run is a title too" ($null -ne $bold -and $bold.Title -eq 'Ship it')

    [void](Invoke-Cli "+set-banner --target=$pId0 --clear")
    $cleared = Wait-RowText $pId0 { param($r) $r.Title -eq $before.Title -and $r.Sub -eq $before.Sub }
    "  cleared: title='$($cleared.Title)' sub='$($cleared.Sub)'"
    Assert "clearing the banner restores P's own title and subtitle" ($null -ne $cleared -and $cleared.Title -eq $before.Title -and $cleared.Sub -eq $before.Sub)

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
