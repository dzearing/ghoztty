# T1844 acceptance: panes drag INTO and OUT OF the pane sidebar on Windows
# (Mac 597a193cc, docs/design/pane-sidebar.md "Drop resolution"). The sidebar
# is a new drop target (`.stash`) and its rows a new drag source on the one
# pane-drag machinery the rearrange drags already use.
#
# THE DEFECT. T1828 landed the sidebar as a list: a click focuses or restores,
# a row's button stashes or restores. Nothing dragged. A row could not be
# picked up, and the sidebar was not a target, so a pane could not be dragged
# into the stash, out of it into the grid, or into another window's stash.
#
# ORACLE. Pane STATE and IDENTITY, not pixels: `+list --json` says which panes
# are stashed, the child terminal HWNDs say which panes are on screen and in
# which window (the same handle, so the shell came with it), the drop preview
# is a real top-level window (`GhozttyDropHighlight`) whose rect is compared
# against the sidebar column, and the app's own log names the stash index a
# drop landed at. The drags are POSTED mouse messages, as in every rearrange
# script: the press and the first travelled move go to the sidebar (the row
# is the drag source), and once the drag is live the window holds the capture,
# so every later move and the release go to the window in its client space.
#
# Layout: P, then `+split right` s1 and s2 - three panes, the mini rail up.
#   A) dragging s2's rail tile onto the rail STASHES it: the drag shows the
#      preview over the sidebar (the empty "Drop to stash" slot, since nothing
#      was stashed), and the release stashes s2 with the grid down to two
#   B) with s1 stashed too, dragging s1's tile below s2's REORDERS the stash:
#      s1 lands at index 1, both still stashed
#   C) dragging the last pane on screen onto the sidebar is REFUSED: no
#      preview, and nothing is stashed
#   D) Escape mid-drag CANCELS a drag that started from the sidebar (no
#      rearrange mode): the preview goes and the pane stays stashed
#   E) dragging a stashed tile onto the grid RESTORES it there in one step:
#      the same HWND is back on screen and +list no longer says stashed
#   F) dragging a pane onto ANOTHER window's rail moves it there and stashes
#      it in one step: the same HWND is now that window's child, stashed, and
#      that window still shows only its own pane
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects claim A's release NOT to stash and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-drag.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1844-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1844')
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
function Get-VisiblePanes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible) }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }
function Test-Child($top, [int64]$Hwnd) {
    foreach ($p in (Get-Panes $top)) { if ([int64]$p.Hwnd -eq $Hwnd) { return $true } }
    return $false
}
function Test-VisibleChild($top, [int64]$Hwnd) {
    foreach ($p in (Get-VisiblePanes $top)) { if ([int64]$p.Hwnd -eq $Hwnd) { return $true } }
    return $false
}

# The rail's tile centers, from pane_sidebar.zig's numbers (layoutMini) - the
# same model pane-sidebar.ps1 scores its clicks with.
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

# The visible drop preview's screen rect, or $null when none is up.
function Get-PreviewRect([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyDropHighlight' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    $p = $w[0]
    return [pscustomobject]@{ Left = $p.Left; Top = $p.Top; Right = $p.Left + $p.Width; Bottom = $p.Top + $p.Height }
}

# A drag that starts on a sidebar tile: the press and a move past the drag
# threshold go to the SIDEBAR (the row is the source and holds the press);
# from then on the window owns the capture, so the moves go to it, in its
# client space (-Client), wherever on screen they are.
function Start-TileDrag($top, $sb, $from) {
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $from.X -Y $from.Y -Action down -Client
    $ok = $ok -and (Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $from.X -Y ($from.Y + (Px 14)) -Action move -Client)
    Start-Sleep -Milliseconds 250
    return $ok
}
function Move-Drag($top, [int]$X, [int]$Y, [string]$Action) {
    return Send-TestMouse -Window $top -Target $top -X $X -Y $Y -Action $Action -Client
}
function Get-LogLines([int]$Skip, [string]$Pattern) {
    return @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern })
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# Evidence for a red run: which named panes +list says are stashed.
function Show-State([string]$Label) {
    # Assigned, never piped: Get-Leaves returns a unary-comma array.
    $leaves = Get-Leaves
    $parts = @($leaves | ForEach-Object {
            $st = if (($_.PSObject.Properties.Name -contains 'stashed') -and $_.stashed -eq $true) { 'stashed' } else { 'shown' }
            '{0}={1}' -f $_.name, $st
        })
    $vis = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyWindow' | ForEach-Object {
            $w = $_.Hwnd
            '{0}:[{1}]' -f $w, ((@(Get-VisiblePanes ([IntPtr]$w) | ForEach-Object { $_.Hwnd })) -join ',')
        })
    '  ({0}: {1} | visible {2} | P={3} s1={4} s2={5})' -f $Label, ($parts -join ' '), ($vis -join ' '), $hP, $h1, $h2
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1844'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    # Flat panes, as pane-sidebar.ps1 runs: the tile model assumes the rail's
    # column starts at the client edge.
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    $script:appPid = $app.Pid
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowPos -Window $top -X 20 -Y 20 -Width (Px 1000) -Height (Px 700))
    Start-Sleep -Milliseconds 600

    $hP = (@(Get-Panes $top))[0].Hwnd
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 900
    $h1 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP } | Select-Object -First 1).Hwnd
    # Split s1, not the focused pane (a CLI split leaves focus on P), so
    # the screen order is P | s1 | s2 - the order the tiles are scored in.
    [void](Invoke-Cli "+split --pane=s1 --direction=right --name=s2")
    Start-Sleep -Milliseconds 900
    $h2 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP -and $_.Hwnd -ne $h1 } | Select-Object -First 1).Hwnd
    Assert "setup: three visible panes" (@(Get-VisiblePanes $top).Count -eq 3 -and $h1 -and $h2)
    $byLeft = @(Get-VisiblePanes $top | Sort-Object Left | ForEach-Object { [int64]$_.Hwnd })
    Assert "setup: screen order is P | s1 | s2 (the tile order scored below)" ($byLeft.Count -eq 3 -and $byLeft[0] -eq [int64]$hP -and $byLeft[1] -eq [int64]$h1 -and $byLeft[2] -eq [int64]$h2)
    $sb = Get-Sidebar $top
    Assert "setup: the mini rail is up" ($null -ne $sb -and $sb.Visible -and [math]::Abs($sb.Width - (Px 68)) -le 1)
    if ($null -eq $sb) { return }
    # Grid panes are listed in SCREEN order: P, s1, s2.

    "== A: dragging s2's tile onto the rail stashes it"
    $logA = Get-LogCount
    $from = Get-TileCenter $sb 2 3
    $dropY = $sb.Top + [int]($sb.Height * 0.8)
    $dropX = $sb.Left + [int]($sb.Width / 2)
    Assert "A: press and travel on s2's tile delivered" (Start-TileDrag $top $sb $from)
    Assert "A: the row handed its pane to the window's drag (log)" (@(Get-LogLines $logA 'pane sidebar row drag start item=2 section=grid').Count -ge 1)
    Assert "A: move onto the rail delivered" (Move-Drag $top $dropX $dropY 'move')
    Start-Sleep -Milliseconds 400
    $pv = Get-PreviewRect $app.Pid
    if ($pv) { "  (preview $($pv.Left),$($pv.Top)-$($pv.Right),$($pv.Bottom); rail $($sb.Left)..$($sb.Left + $sb.Width))" }
    Assert "A: the drop is previewed ON the sidebar (the empty drop slot)" ($null -ne $pv -and $pv.Left -ge $sb.Left -and $pv.Right -le ($sb.Left + $sb.Width) -and $pv.Top -ge $sb.Top)
    # Evidence, not an oracle: the rail mid-drag, showing the empty slot.
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $png = Join-Path $env:TEMP 't1844-drop-slot.png'
        $shot.Bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        Close-TestWindowPixels -Shot $shot
        "  (the rail mid-drag: $png)"
    } catch { "  (capture failed: $($_.Exception.Message))" }
    Assert "A: release delivered" (Move-Drag $top $dropX $dropY 'up')
    Start-Sleep -Milliseconds 700
    Assert "A: the preview is gone after the release" ($null -eq (Get-PreviewRect $app.Pid))
    $stashedA = Wait-Stashed 's2' $true
    if ($NegativeControl) {
        Assert "NEGATIVE: s2 is NOT stashed by the drop (pre-T1844 behavior)" (-not $stashedA)
    } else {
        Assert "A: s2 is stashed (+list)" $stashedA
    }
    Assert "A: the grid is down to two panes, and s2's handle is still a child (still running)" (@(Get-VisiblePanes $top).Count -eq 2 -and (Test-Child $top $h2))
    Assert "A: the drop names index 0 (log)" (@(Get-LogLines $logA 'pane drop stashed index=0 ').Count -ge 1)

    Show-State "before B"
    "== B: dragging s1's tile below s2's reorders the stash"
    Assert "+stash s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+stash --target=s1") -eq 0)
    Assert "B: s1 stashed" (Wait-Stashed 's1' $true)
    Start-Sleep -Milliseconds 500
    # Rail now: P (grid), then the stash newest first: s1, s2.
    $sb = Get-Sidebar $top
    $logB = Get-LogCount
    $from = Get-TileCenter $sb 1 1
    $below = Get-TileCenter $sb 2 1
    Assert "B: press and travel on s1's tile delivered" (Start-TileDrag $top $sb $from)
    Assert "B: move below s2's tile delivered" (Move-Drag $top $below.X ($below.Y + (Px 20)) 'move')
    Start-Sleep -Milliseconds 300
    Assert "B: the reorder is previewed" ($null -ne (Get-PreviewRect $app.Pid))
    Assert "B: release delivered" (Move-Drag $top $below.X ($below.Y + (Px 20)) 'up')
    Start-Sleep -Milliseconds 600
    $lineB = Get-LogLines $logB 'pane drop stashed index=' | Select-Object -Last 1
    "  $lineB"
    Assert "B: s1 landed at stash index 1, below s2 (log)" ($null -ne $lineB -and $lineB -match 'stash_index=1 stashed=2')
    Assert "B: both still stashed" ((Test-StashedId 's1') -and (Test-StashedId 's2'))

    Show-State "before C"
    "== C: the last pane on screen cannot be dragged into the stash"
    $logC = Get-LogCount
    $from = Get-TileCenter $sb 0 1
    Assert "C: press and travel on P's tile delivered" (Start-TileDrag $top $sb $from)
    Assert "C: move onto the rail delivered" (Move-Drag $top $dropX $dropY 'move')
    Start-Sleep -Milliseconds 300
    Assert "C: nothing is previewed for a refused stash" ($null -eq (Get-PreviewRect $app.Pid))
    Assert "C: release delivered" (Move-Drag $top $dropX $dropY 'up')
    Start-Sleep -Milliseconds 500
    Assert "C: P is still on screen" (Test-VisibleChild $top $hP)
    Assert "C: no stash happened (log)" (@(Get-LogLines $logC 'pane drop stashed').Count -eq 0)

    Show-State "before D"
    "== D: Escape mid-drag cancels a sidebar drag"
    $pBox = (@(Get-VisiblePanes $top))[0]
    $cx = $pBox.Left + [int]($pBox.Width / 2); $cy = $pBox.Top + [int]($pBox.Height / 2)
    $from = Get-TileCenter $sb 1 1
    Assert "D: press and travel on a stashed tile delivered" (Start-TileDrag $top $sb $from)
    Assert "D: move onto P's center delivered" (Move-Drag $top $cx $cy 'move')
    Start-Sleep -Milliseconds 300
    Assert "D: the drop onto the grid is previewed" ($null -ne (Get-PreviewRect $app.Pid))
    $k = Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Key Escape
    Start-Sleep -Milliseconds 400
    Assert "D: Escape delivered" $k
    Assert "D: Escape took the preview away" ($null -eq (Get-PreviewRect $app.Pid))
    [void](Move-Drag $top $cx $cy 'up')
    Start-Sleep -Milliseconds 500
    Assert "D: nothing was restored - both still stashed" ((Test-StashedId 's1') -and (Test-StashedId 's2'))
    Assert "D: one pane on screen" (@(Get-VisiblePanes $top).Count -eq 1)

    Show-State "before E"
    "== E: dragging a stashed tile onto the grid restores it there"
    # Stash order: s2 (top), s1. Tile 1 is s2.
    $from = Get-TileCenter $sb 1 1
    # P's right edge zone, clear of the window's edge band: a split.
    $rx = $pBox.Left + $pBox.Width - (Px 90); $ry = $cy
    Assert "E: press and travel on s2's tile delivered" (Start-TileDrag $top $sb $from)
    Assert "E: move onto P's right edge delivered" (Move-Drag $top $rx $ry 'move')
    Start-Sleep -Milliseconds 300
    Assert "E: the restore is previewed over the grid" ($null -ne (Get-PreviewRect $app.Pid))
    Assert "E: release delivered" (Move-Drag $top $rx $ry 'up')
    Start-Sleep -Milliseconds 700
    Assert "E: s2 is no longer stashed (+list)" (Wait-Stashed 's2' $false)
    Assert "E: the SAME handle is back on screen" (Test-VisibleChild $top $h2)
    Assert "E: two panes on screen, s1 still stashed" (@(Get-VisiblePanes $top).Count -eq 2 -and (Test-StashedId 's1'))

    Show-State "before F"
    "== F: dragging a pane onto ANOTHER window's rail moves it there, stashed"
    $wasThere = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
    [void](Invoke-Cli "+new-window")
    Start-Sleep -Milliseconds 2000
    $b = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { $wasThere -notcontains [int64]$_.Hwnd }) | Select-Object -First 1
    Assert "F: a second window opened" ($null -ne $b)
    if ($null -eq $b) { return }
    $bTop = [IntPtr][int64]$b.Hwnd
    [void](Set-TestWindowPos -Window $bTop -X ((Px 1000) + 60) -Y 20 -Width (Px 800) -Height (Px 700))
    Start-Sleep -Milliseconds 900
    $bOwn = (@(Get-Panes $bTop))[0].Hwnd
    $bSb = Get-Sidebar $bTop
    Assert "F: the other window shows its rail" ($null -ne $bSb -and $bSb.Visible)
    if ($null -eq $bSb) { return }
    # Window A's rail: P, s2 (grid, screen order), then s1. Drag s2's tile.
    $sb = Get-Sidebar $top
    $logF = Get-LogCount
    $from = Get-TileCenter $sb 1 2
    $fx = $bSb.Left + [int]($bSb.Width / 2); $fy = $bSb.Top + [int]($bSb.Height * 0.7)
    Assert "F: press and travel on s2's tile delivered" (Start-TileDrag $top $sb $from)
    Assert "F: move onto the other window's rail delivered" (Move-Drag $top $fx $fy 'move')
    Start-Sleep -Milliseconds 400
    $pv = Get-PreviewRect $app.Pid
    Assert "F: the drop is previewed on THAT window's sidebar" ($null -ne $pv -and $pv.Left -ge $bSb.Left -and $pv.Right -le ($bSb.Left + $bSb.Width))
    Assert "F: release delivered" (Move-Drag $top $fx $fy 'up')
    Start-Sleep -Milliseconds 1200
    Assert "F: s2's SAME handle is now a child of the other window" (Test-Child $bTop $h2)
    Assert "F: and no longer of the source window" (-not (Test-Child $top $h2))
    Assert "F: it arrived stashed (+list)" (Wait-Stashed 's2' $true)
    Assert "F: the other window still shows only its own pane" (@(Get-VisiblePanes $bTop).Count -eq 1 -and (Test-VisibleChild $bTop $bOwn))
    Assert "F: the source window kept P on screen" (Test-VisibleChild $top $hP)
    Assert "F: the drop was a stash into another window (log)" (@(Get-LogLines $logF 'pane drop stashed into another window').Count -ge 1)

    Show-State "end"
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
        update -Guard pane-sidebar-drag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1844' -Path $transcript `
        -Label 'T1844 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
