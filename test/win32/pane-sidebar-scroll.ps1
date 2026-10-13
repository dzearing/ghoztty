# T1878 acceptance: the Windows pane sidebar scrolls. A list taller than the
# column used to run off the bottom with no way to reach the rest; Mac's list
# is a ScrollView, and in the all-windows scope its project headers are
# STICKY (b4a3216cc) - pinned at the top while their windows scroll under.
#
# Layout: one short window with two grid panes (P + p1) and twelve stashed
# ones (s1..s12, split off p1 and stashed - a stash takes no grid room, so the
# list grows without the grid shrinking to nothing). What it checks:
#
#   1. Pinned, the list overflows: the rows line reports a scroll range, the
#      last row sits below the viewport, and fewer rows carry a tip than
#      exist (a row out of view has none).
#   2. The wheel scrolls: the offset moves, every row moves up by it, and
#      the last row comes into view.
#   3. A click on that row - past the fold before the scroll - lands on it:
#      its pane is restored.
#   4. Focus moving to a row scrolled out of view scrolls it back in.
#   5. The overlay thumb drags: pressed and pulled to the bottom, the list
#      is at its end.
#   6. All windows, as a project: scrolled into the project's rows, its
#      header is pinned to the viewport's top (sticky), and a click on the
#      pinned header is the header's (it folds the project).
#   7. Unpinned, the rail's tiles scroll with the wheel too.
#
# Geometry comes from the `pane sidebar rows` / `outline` log lines (rows,
# heads, and since T1878 `scroll=<offset>/<max> view=<top>,<bottom>
# sticky=<head>`): a background desktop cannot be photographed row by row.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl never sends the wheel in section 2 and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-scroll.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1878-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1878')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to
# $Ms for one to appear (and a further 300 ms for later ones to settle).
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

# Parse a `pane sidebar rows` or `pane sidebar outline` line: heads, items
# (with the pane id after `#` on a rows line), and the scroll state.
function Read-Geometry([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=(\S*) rules=') { return $null }
    $o = @{ Mode = $Matches[1]; Heads = @(); Items = @(); Scroll = -1; Max = -1; Top = 0; Bottom = 0; Sticky = '-' }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)(?:#(.+))?$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4]; Id = $Matches[5] } }
    }
    if ($Line -match ' scroll=(-?\d+)/(-?\d+) view=(-?\d+),(-?\d+) sticky=(\S+)') {
        $o.Scroll = [int]$Matches[1]; $o.Max = [int]$Matches[2]; $o.Top = [int]$Matches[3]; $o.Bottom = [int]$Matches[4]; $o.Sticky = $Matches[5]
    }
    return $o
}
function InView($o, $it) { $it.Y -ge $o.Top -and $it.Y -lt $o.Bottom }
function RowById($o, [string]$Id) { $o.Items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
function WheelAt($top, $sb, $pt, [int]$Delta) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action wheel -Delta $Delta
}
function Get-PinCenter($sb, [string]$Mode) {
    if ($Mode -eq 'mini') {
        $margin = Px 12; $card = Px 44; $tile = Px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
    }
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = Px 18 }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - 2 * ((Px 28) + (Px 2)) - [int]((Px 28) / 2); Y = Px 18 }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1878'

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
    [void](Set-TestWindowSize -Window $top -Width (Px 1000) -Height (Px 460))
    Start-Sleep -Milliseconds 600

    # P + p1 in the grid, s1..s12 stashed.
    Assert "setup: p1 split ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=p1") -eq 0)
    Start-Sleep -Milliseconds 600
    $made = 0
    for ($k = 1; $k -le 12; $k++) {
        if ((Invoke-Cli "+split --target=p1 --direction=down --name=s$k") -ne 0) { continue }
        Start-Sleep -Milliseconds 350
        if ((Invoke-Cli "+stash --target=s$k") -eq 0) { $made++ }
        Start-Sleep -Milliseconds 250
    }
    Assert "setup: twelve panes split and stashed ($made)" ($made -eq 12)
    Assert "setup: s12 reads stashed" (Wait-Stashed 's12' $true)

    "== 1: pinned, a long list overflows the panel"
    $sb = Get-Sidebar $top
    Assert "the window has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-PinCenter $sb 'mini'))
    $o = Read-Geometry (Wait-Log 'pane sidebar rows mode=expanded' $mark)
    $sb = Get-Sidebar $top
    Assert "the pinned panel logged its rows with a scroll state" ($null -ne $o -and $o.Max -ge 0)
    if ($null -eq $o) { return }
    "  rows=$($o.Items.Count) scroll=$($o.Scroll)/$($o.Max) view=$($o.Top),$($o.Bottom)"
    Assert "fourteen rows" ($o.Items.Count -eq 14)
    Assert "the list can scroll (max $($o.Max) > 0) and starts at the top" ($o.Max -gt 0 -and $o.Scroll -eq 0)
    $last = $o.Items[$o.Items.Count - 1]
    Assert "the last row ($($last.Id)) is past the fold (y $($last.Y) >= $($o.Bottom))" (-not (InView $o $last))
    $tips = Wait-Log 'pane sidebar tips view=' $mark 2000
    "  $tips"
    Assert "only the rows in view carry a tip" ($tips -match 'view=(\d+),\d+ rail=(\d+)' -and [int]$Matches[1] -gt 0 -and [int]$Matches[1] -lt ([int]$Matches[2] - 1))

    "== 2: the wheel scrolls the rows"
    $mid = @{ X = [int]($sb.Width / 2); Y = [int](($o.Top + $o.Bottom) / 2) }
    $mark = Get-LogCount
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: the wheel is never sent - this run MUST fail"
    } else {
        Assert "wheel delivered" (WheelAt $top $sb $mid -2400)
    }
    $line = Wait-Log 'pane sidebar rows mode=expanded' $mark 3000
    $o2 = Read-Geometry $line
    Assert "the wheel moved the offset (log)" ($null -ne (Wait-Log 'pane sidebar scroll surface=rail offset=' $mark 500))
    Assert "scrolled to the end ($(if ($o2) { "$($o2.Scroll)/$($o2.Max)" }))" ($null -ne $o2 -and $o2.Scroll -gt 0 -and $o2.Scroll -eq $o2.Max)
    if ($null -eq $o2) { return }
    $last2 = RowById $o2 $last.Id
    Assert "every row moved up by the offset" ($null -ne $last2 -and $last2.Y -eq ($last.Y - $o2.Scroll) -and $o2.Items[0].Y -eq ($o.Items[0].Y - $o2.Scroll))
    Assert "the last row is in view now" ($null -ne $last2 -and (InView $o2 $last2))
    $first2 = $o2.Items[0]
    Assert "the first row scrolled out of view" (-not (InView $o2 $first2))

    "== 3: a click lands on the row that was past the fold"
    $mark = Get-LogCount
    if ($last2) { [void](ClickAt $top $sb $last2) }
    Assert "$($last.Id) was restored by the click" (Wait-Stashed $last.Id $false)

    "== 4: focus moving to a row out of view scrolls it in"
    # p1 is focused first (a reveal of its own if need be), then the list
    # goes back to the end, which takes p1's row out of view; focusing the
    # restored pane - now a grid row near the top - must bring it back.
    [void](Invoke-Cli "+split --name=p1 --focus")
    Start-Sleep -Milliseconds 500
    $mark = Get-LogCount
    [void](WheelAt $top $sb $mid -2400)
    $o3 = Read-Geometry (Wait-Log 'pane sidebar rows mode=expanded' $mark 3000)
    $row = if ($o3) { RowById $o3 $last.Id } else { $null }
    Assert "back at the end, the restored row is out of view" ($null -ne $row -and -not (InView $o3 $row))
    $mark = Get-LogCount
    Assert "focus moved to $($last.Id) ($(Get-CliErr))" ((Invoke-Cli "+split --name=$($last.Id) --focus") -eq 0)
    Assert "the sidebar revealed it (log)" ($null -ne (Wait-Log 'pane sidebar reveal surface=rail' $mark 3000))
    $o4 = Read-Geometry (Wait-Log 'pane sidebar rows mode=expanded' $mark 3000)
    $row = if ($o4) { RowById $o4 $last.Id } else { $null }
    Assert "the focused row is in view ($(if ($o4) { "scroll $($o4.Scroll)" }))" ($null -ne $row -and (InView $o4 $row))

    "== 5: the overlay thumb drags"
    $mark = Get-LogCount
    [void](WheelAt $top $sb $mid 2400)
    $o5 = Read-Geometry (Wait-Log 'pane sidebar rows mode=expanded' $mark 3000)
    Assert "the wheel took the list back to the top" ($null -ne $o5 -and $o5.Scroll -eq 0)
    $thumbX = $sb.Width - (Px 4)
    $mark = Get-LogCount
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $thumbX) -Y ($sb.Top + $o5.Top + (Px 5)) -Action down)
    Start-Sleep -Milliseconds 100
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $thumbX) -Y ($sb.Top + [int](($o5.Top + $o5.Bottom) / 2)) -Action move)
    Start-Sleep -Milliseconds 100
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $thumbX) -Y ($sb.Top + $o5.Bottom - 2) -Action move)
    Start-Sleep -Milliseconds 100
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $thumbX) -Y ($sb.Top + $o5.Bottom - 2) -Action up)
    Assert "the press took the thumb, not the resize edge (log)" ($null -ne (Wait-Log 'pane sidebar thumb drag start surface=rail' $mark 2000))
    Assert "no edge drag started" ($null -eq (Wait-Log 'pane sidebar edge drag start' $mark 300))
    $o6 = Read-Geometry (Wait-Log 'pane sidebar rows mode=expanded' $mark 3000)
    Assert "pulled to the bottom, the list is at its end ($(if ($o6) { "$($o6.Scroll)/$($o6.Max)" }))" ($null -ne $o6 -and $o6.Max -gt 0 -and $o6.Scroll -eq $o6.Max)

    "== 6: all windows, the project header sticks"
    Assert "setup: this window renamed 'proj: alpha' ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=`"proj: alpha`"") -eq 0)
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=`"proj: beta`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    $mark = Get-LogCount
    [void](WheelAt $top $sb $mid 2400)
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "the all-windows scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark 2000))
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $g"
    $o7 = Read-Geometry (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    $proj = if ($o7) { $o7.Heads | Where-Object Kind -eq 'P' | Select-Object -First 1 } else { $null }
    Assert "the outline has a project head first" ($null -ne $proj -and $o7.Heads[0].Kind -eq 'P')
    Assert "the outline can scroll ($(if ($o7) { $o7.Max }))" ($null -ne $o7 -and $o7.Max -gt 0 -and $o7.Sticky -eq '-')
    $mark = Get-LogCount
    [void](WheelAt $top $sb $mid -240)
    $o8 = Read-Geometry (Wait-Log 'pane sidebar outline mode=expanded' $mark 3000)
    $proj8 = if ($o8) { $o8.Heads | Where-Object Kind -eq 'P' | Select-Object -First 1 } else { $null }
    "  scroll=$(if ($o8) { "$($o8.Scroll)/$($o8.Max) view=$($o8.Top),$($o8.Bottom) sticky=$($o8.Sticky)" }) P@$(if ($proj8) { "$($proj8.X),$($proj8.Y)" })"
    Assert "scrolled into the project, its head is the sticky one" ($null -ne $o8 -and $o8.Scroll -gt 0 -and $o8.Sticky -eq '0')
    Assert "the pinned head sits at the viewport's top" ($null -ne $proj8 -and $proj8.Y -gt $o8.Top -and $proj8.Y -lt ($o8.Top + (Px 30)))
    # The window head under the project moved up by the whole offset; the
    # project's own head did not (it is held at the top).
    Assert "the rows under it moved while it stayed" ($null -ne $proj -and $null -ne $proj8 -and $o7.Heads.Count -ge 2 -and $o8.Heads[1].Y -eq ($o7.Heads[1].Y - $o8.Scroll) -and $proj8.Y -gt ($proj.Y - $o8.Scroll))
    $mark = Get-LogCount
    if ($proj8) { [void](ClickAt $top $sb @{ X = $proj8.X; Y = $proj8.Y }) }
    Assert "a click on the pinned head is the head's: the project folded (log)" ($null -ne (Wait-Log 'pane sidebar fold' $mark 2000))
    # Unfold, so the rail below lists every pane.
    $o9 = Read-Geometry (Wait-Log 'pane sidebar outline mode=expanded' $mark 2000)
    $p9 = if ($o9) { $o9.Heads | Where-Object Kind -eq 'P' | Select-Object -First 1 } else { $null }
    $mark = Get-LogCount
    if ($p9) { [void](ClickAt $top $sb @{ X = $p9.X; Y = $p9.Y }) }
    Assert "...and a second click unfolds it (log)" ($null -ne (Wait-Log 'pane sidebar unfold' $mark 2000))

    "== 7: unpinned, the rail's tiles scroll"
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-PinCenter $sb 'expanded'))
    $r1 = Read-Geometry (Wait-Log 'pane sidebar outline mode=mini' $mark 3000)
    $sb = Get-Sidebar $top
    Assert "the rail logged its tiles with a scroll range ($(if ($r1) { "$($r1.Items.Count) tiles, max $($r1.Max)" }))" ($null -ne $r1 -and $r1.Items.Count -ge 14 -and $r1.Max -gt 0)
    Start-Sleep -Milliseconds 1200   # let the unpin's open card contract
    $mark = Get-LogCount
    $railPt = @{ X = (Px 12) + (Px 22); Y = [int](($r1.Top + $r1.Bottom) / 2) }
    [void](WheelAt $top $sb $railPt -2400)
    $r2 = Read-Geometry (Wait-Log 'pane sidebar outline mode=mini' $mark 3000)
    Assert "the wheel scrolled the rail to its end ($(if ($r2) { "$($r2.Scroll)/$($r2.Max)" }))" ($null -ne $r2 -and $r2.Scroll -gt 0 -and $r2.Scroll -eq $r2.Max)
    $lastTile = if ($r2) { $r2.Items[$r2.Items.Count - 1] } else { $null }
    Assert "the last tile is in view" ($null -ne $lastTile -and (InView $r2 $lastTile))

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
        update -Guard pane-sidebar-scroll -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1878' -Path $transcript `
        -Label 'T1878 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
