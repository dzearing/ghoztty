# T2278 acceptance: every pane has its own hue in the pane sidebar, its icon
# is drawn in it, and hovering its row tints the pane itself (Mac
# PaneSidebarState.swift `PaneSidebarHue` / `PaneSidebarHover`,
# PaneSidebarRow.swift `iconColor` / `PaneSidebarHoverTint`; Mac 075d787d1,
# dc2bbab6b, 75dc046e3).
#
# Layout: P, then `+split right` -> s1, then `+split right` -> s2, in the
# elevated style, sidebar pinned. Tree order is P, s1, s2 (index 0, 1, 2), and
# so is the panes' left-to-right order and the rows' top-to-bottom order.
#
#   1. The rows are drawn in their panes' hues: in the sidebar's own pixels
#      (synchronous WM_PRINTCLIENT), s1's icon band holds ink of hue(1) and
#      none of hue(2), and s2's holds hue(2) - a yellow-green and a magenta -
#      where before T2278 every icon was the neutral text ink.
#   2. Hovering s1's row hands the tint to index 1 in exactly Mac's colour
#      (HSB hue(1), 0.42, 1 on a dark theme - log), and a GhozttyHoverTint
#      popup is shown OWNED BY s1's pane window and glued to its rect, cut to
#      the pane's rounded card (region: its corners are outside).
#   3. A background desktop has no real cursor, so the leave TrackMouseEvent
#      owes arrives right after the move: the tint fades back out (log
#      `fade done alpha=0`) and the popup is hidden - the leave path.
#   4. Hovering s2's row tints s2 in hue(2), not s1.
#
# The colours, the pixels of the wash and rim, and the 0.12 s / 0.2 s easeOut
# fades are unit-tested in src\apprt\win32\pane_hue.zig. NOT covered here:
# what the tint LOOKS like on screen - a layered popup on a background desktop
# cannot be photographed (CopyFromScreen is dead there).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the tint on the WRONG pane (P) and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-hue.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2278-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2278')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
Add-Type -AssemblyName System.Drawing

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left) }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The first line matching $Pattern logged after line $Skip, waiting up to $Ms.
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip |
                Where-Object { $_ -match $Pattern }) | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Wait-Until([scriptblock]$Cond, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $false
}

# The latest `pane sidebar rows` line: each row's center in the column's
# client coordinates, top to bottom.
function Get-Rows {
    $line = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar rows ' }) | Select-Object -Last 1
    if (-not $line -or $line -notmatch 'mode=(\w+) heads=\S* items=(\S*) ') { return $null }
    $o = @{ Mode = $Matches[1]; Items = @() }
    foreach ($i in ($Matches[2] -split ';' | Where-Object { $_ })) {
        if ($i -match '^g\d+([gs])@(-?\d+),(-?\d+)#(\S+)$') { $o.Items += , @{ X = [int]$Matches[2]; Y = [int]$Matches[3]; Id = $Matches[4] } }
    }
    $o.Items = @($o.Items | Sort-Object { $_.Y })
    return $o
}
function Get-RailPinCenter($sb) {
    $margin = Px 12; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}

# pane_hue.zig's numbers, recomputed: the hue of tree index $i, and its dark
# theme colour (HSB h, 0.42, 1) as [r, g, b].
function Get-Hue([int]$i) { $h = (0.58 + $i * 0.61803398875) % 1.0; if ($h -lt 0) { $h += 1 }; return $h }
function Get-DarkHueRgb([int]$i) {
    $h = Get-Hue $i; $s = 0.42; $b = 1.0
    $c = $b * $s; $hp = $h * 6; $x = $c * (1 - [math]::Abs(($hp % 2) - 1)); $m = $b - $c
    $r = 0; $g = 0; $bl = 0
    if ($hp -lt 1) { $r = $c; $g = $x } elseif ($hp -lt 2) { $r = $x; $g = $c } elseif ($hp -lt 3) { $g = $c; $bl = $x }
    elseif ($hp -lt 4) { $g = $x; $bl = $c } elseif ($hp -lt 5) { $r = $x; $bl = $c } else { $r = $c; $bl = $x }
    return @([int][math]::Floor(($r + $m) * 255 + 0.5), [int][math]::Floor(($g + $m) * 255 + 0.5), [int][math]::Floor(($bl + $m) * 255 + 0.5))
}
# How many pixels of one row's icon band carry hue $h: saturated enough to be
# ink rather than a grey, within 0.03 of it around the wheel. The band is the
# row's own height (16 DIP either side of its center) and the leading 48 DIP,
# where the icon sits - so a hue found there is THAT row's icon, not another
# row's or the accent bar's.
function Get-HuePixelCount($shot, [double]$h, $row) {
    $bmp = $shot.Bitmap
    $y0 = [math]::Max(0, $row.Y - (Px 16)); $y1 = [math]::Min($bmp.Height, $row.Y + (Px 16))
    $x1 = [math]::Min($bmp.Width, (Px 48))
    $n = 0
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = 0; $x -lt $x1; $x++) {
            $p = $bmp.GetPixel($x, $y)
            if ($p.GetSaturation() -lt 0.25 -or $p.GetBrightness() -lt 0.35) { continue }
            $d = [math]::Abs($p.GetHue() / 360.0 - $h)
            if ([math]::Min($d, 1 - $d) -lt 0.03) { $n++ }
        }
    }
    return $n
}

# Hover row $Index; returns the tint log line for it.
function Invoke-RowHover($top, $sb, $rows, [int]$Index) {
    $r = $rows.Items[$Index]
    $from = Get-LogCount
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $r.X) -Y ($sb.Top + $r.Y) -Action move)
    return @{ From = $from; Line = (Wait-Log 'pane sidebar hover tint index=(\d+) rgb=(\d+),(\d+),(\d+)' $from) }
}
function Get-Tints($appPid) { @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyHoverTint' -AllowHidden) }
# The tint covering $pane: the popup laid exactly over the pane's rect. (Not
# by owner: a popup created with a CHILD window as its owner is owned by that
# child's top-level window, so every tint reports the GhozttyWindow.)
function Find-TintFor($appPid, $pane) {
    foreach ($t in (Get-Tints $appPid)) {
        if ($t.Left -eq $pane.Left -and $t.Top -eq $pane.Top -and $t.Width -eq $pane.Width -and $t.Height -eq $pane.Height) { return $t }
    }
    return $null
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2278'

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
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=elevated', '--background=#1e1e1e')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1300) -Height (Px 700))
    Start-Sleep -Milliseconds 600

    Assert "setup: +split s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1") -eq 0)
    Start-Sleep -Milliseconds 900
    Assert "setup: +split s2 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s2") -eq 0)
    Start-Sleep -Milliseconds 1200
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { "  SETUP FAIL: no sidebar"; $script:failures++; return }
    $pin = Get-RailPinCenter $sb
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $pin.X -Y $pin.Y -Action click)
    $null = Wait-Until { $r = Get-Rows; $r -and $r.Mode -eq 'expanded' -and $r.Items.Count -eq 3 } 5000
    # Expanding glides (T2291): the rows line is logged as the mode flips,
    # while the column and the panes are still on their way. Read the
    # geometry once they all hold still.
    $shape = { (@(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') + @(Get-Panes $top) | ForEach-Object { "$($_.Left),$($_.Width)" }) -join ';' }
    $null = Wait-Until { $a = & $shape; Start-Sleep -Milliseconds 120; $a -eq (& $shape) }
    $rows = Get-Rows
    $sb = Get-Sidebar $top
    $panes = @(Get-Panes $top)
    Assert "setup: pinned, three rows" ($null -ne $rows -and $rows.Mode -eq 'expanded' -and $rows.Items.Count -eq 3)
    Assert "setup: three panes on show beside it" ($panes.Count -eq 3)
    if ($null -eq $rows -or $rows.Items.Count -ne 3 -or $panes.Count -ne 3) { return }

    "== 1: each row's icon is drawn in its pane's hue"
    $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
    $n1 = Get-HuePixelCount $shot (Get-Hue 1) $rows.Items[1]
    $n2 = Get-HuePixelCount $shot (Get-Hue 2) $rows.Items[2]
    $cross = Get-HuePixelCount $shot (Get-Hue 2) $rows.Items[1]
    Close-TestWindowPixels -Shot $shot
    "  (s1 icon band: $n1 px in hue(1), $cross in hue(2); s2 icon band: $n2 px in hue(2))"
    Assert "s1's icon is drawn in s1's hue (yellow-green)" ($n1 -ge 6)
    Assert "s2's icon is drawn in s2's hue (magenta)" ($n2 -ge 6)
    Assert "and not in s2's: each row carries its own pane's hue" ($cross -eq 0)

    "== 2: hovering s1's row tints s1 in its hue"
    $want = if ($NegativeControl) { 0 } else { 1 }
    $h = Invoke-RowHover $top $sb $rows 1
    Assert "the hover hands the tint to index 1 (log: $($h.Line))" ($h.Line -match 'index=1 ')
    $exp = Get-DarkHueRgb 1
    $ok = $false
    if ($h.Line -match 'rgb=(\d+),(\d+),(\d+)') {
        $ok = ([math]::Abs([int]$Matches[1] - $exp[0]) -le 1) -and ([math]::Abs([int]$Matches[2] - $exp[1]) -le 1) -and ([math]::Abs([int]$Matches[3] - $exp[2]) -le 1)
    }
    Assert "in Mac's colour for index 1 on a dark theme (expected $($exp -join ','))" $ok
    Assert "the tint popup was shown (log)" ($null -ne (Wait-Log 'hover tint shown ' $h.From))
    $tints = @(Get-Tints $app.Pid)
    "  (tint popups: $(@($tints | ForEach-Object { "$($_.Left),$($_.Top) $($_.Width)x$($_.Height) vis=$($_.Visible)" }) -join '; '))"
    Assert "exactly one tint popup so far" ($tints.Count -eq 1)
    $tint = Find-TintFor $app.Pid $panes[$want]
    Assert "it is laid exactly over s1's pane" ($null -ne $tint)
    if ($tint) {
        $pr = $panes[$want]
        Assert "owned by the pane's window (the popup's owner resolves to the top level)" ([int64](Get-TestWindowOwner -Window ([IntPtr]$tint.Hwnd)) -eq [int64]$top)
        $hits = Get-TestWindowRegionHits -Window ([IntPtr]$tint.Hwnd) -Points @(0, 0, ($tint.Width - 1), ($tint.Height - 1), [int]($tint.Width / 2), [int]($tint.Height / 2))
        Assert "cut to the rounded card: corners outside, middle inside" ($null -ne $hits -and -not $hits[0] -and -not $hits[1] -and $hits[2])
        # No z-order sandwich probe: the cursor-less leave (section 3) has
        # usually hidden the popup by now, and a hidden overlay has no place
        # in the z-order to check. Its placement is the shared
        # healOverlayZOrderAfterMove path every pane overlay uses.
    }
    Assert "no other pane has a tint popup yet" ($null -eq (Find-TintFor $app.Pid $panes[0]) -and $null -eq (Find-TintFor $app.Pid $panes[2]))

    "== 3: the pointer leaves - the tint fades back out"
    Assert "the fade-out finishes at alpha 0 (log)" ($null -ne (Wait-Log 'hover tint fade done alpha=0 ' $h.From 3000))
    Assert "and the popup is hidden" (Wait-Until { $t = Find-TintFor $app.Pid $panes[1]; $t -and -not $t.Visible } 3000)

    "== 4: hovering s2's row tints s2, in its own hue"
    $h2 = Invoke-RowHover $top $sb $rows 2
    Assert "the tint goes to index 2 (log: $($h2.Line))" ($h2.Line -match 'index=2 ')
    $exp2 = Get-DarkHueRgb 2
    Assert "in index 2's colour (expected $($exp2 -join ','))" ($h2.Line -match "rgb=$($exp2[0]),$($exp2[1]),$($exp2[2])$" -or ($h2.Line -match 'rgb=(\d+),(\d+),(\d+)' -and ([math]::Abs([int]$Matches[1] - $exp2[0]) -le 1) -and ([math]::Abs([int]$Matches[2] - $exp2[1]) -le 1) -and ([math]::Abs([int]$Matches[3] - $exp2[2]) -le 1)))
    Assert "s2's pane has its own tint popup" (Wait-Until { $null -ne (Find-TintFor $app.Pid $panes[2]) } 2000)

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
        update -Guard pane-sidebar-hue -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2278' -Path $transcript `
        -Label 'T2278 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
