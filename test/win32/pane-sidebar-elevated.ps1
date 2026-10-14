# T1850 acceptance: the pane sidebar in the elevated pane style (Mac main
# 91ba7c08c + 557e4f978). Mac runs the window's gradient desk UNDER the
# sidebar: the pinned panel is translucent over it with no rule against the
# grid, and the mini rail takes the panes' own 10 DIP margin leading, top and
# bottom and none trailing - the grid's margin is the gap on that side - so
# the gutters either side of the rail are equal.
#
# What is asserted, and how (a PrintWindow of the top-level window, which
# carries the sidebar's own GDI paint; the OpenGL panes come back flat):
#
#   1. RAIL GEOMETRY. The column is 10 + 44 DIP (Mac 54), and the first pane
#      starts one grid margin (plus the card's rim) after it: the rail's card
#      is flush with the column, so rail-to-pane equals edge-to-rail.
#   2. THE DESK UNDER THE RAIL. The rail's leading inset is the ocean desk,
#      not the terminal background; the card itself is the card material, not
#      the desk; and just inside the column's trailing edge the colour meets
#      the grid margin beside it without a seam.
#   3. THE PINNED PANEL. Pinned, the column is the 240 DIP panel; its empty
#      lower part lets the desk show through (blue over red on a black
#      terminal), and just inside its trailing edge it is exactly the glass
#      mix of the desk in the margin beside it - 38% terminal background, then
#      the card's 6% wash - and there is no divider rule at that edge.
#   4. Unpinning brings the 54 DIP rail back.
#   5. GLASS (T1887, Mac ec71db251 / 733b03e58). With glass panes on (the
#      default) the unpinned card is Mac's lighter glass sheet: the rail's
#      card is the desk under 30% terminal background (step 2 checks it
#      against the desk at the same height), and the card the unpin opens is
#      see-through - it is a layered window, whose pixels cannot be read back
#      off the test desktop, so it logs the alpha it handed the window manager
#      low in its empty middle (30% tint, plus the grounding shade: 70-100).
#      A second launch with --macos-pane-glass=false keeps the opaque card:
#      the rail is card material, not the desk, and the open card's middle is
#      alpha 255.
#   7. BESIDE THE TAB STRIP (T1900, Mac 3ac40dc8b). With glass panes and the
#      strip showing, the sidebar's column runs the window's height: it starts
#      at the client's top, its card running up beside the tabs, and the strip
#      starts at the column's edge (the published band, not a re-derivation).
#      The tabs sit one 10 DIP gap above the panes. Up there the column only
#      draws - WM_NCHITTEST on it is HTTRANSPARENT and the window answers
#      HTCAPTION, so the stretch drags the window - while the rail's pin, now
#      a strip's height lower, still pins; the strip follows the 240 DIP panel.
#      Solid panes keep the column under the chrome and the strip full width.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the flat style's 68 DIP rail in step 1 and MUST
# fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-elevated.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1850-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1850')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
Add-Type -AssemblyName System.Drawing

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible) }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
# Zig's @round is half-away-from-zero; .NET's default is banker's.
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale, [MidpointRounding]::AwayFromZero) }
# pane_elevation.zig: the margin/gap, and the card's rim inset.
function Get-MarginPx { [math]::Max((Px 10), 1) }
function Get-InsetPx { [math]::Max([int][math]::Ceiling(0.5 * $script:scale), 1) }

# The ocean desk on a dark theme: dark, blue above red, and neither the black
# terminal nor a neutral gray (pane-elevation.ps1's oracle).
function Test-DeskPixel($c) {
    if ($null -eq $c) { return $false }
    $sum = $c.R + $c.G + $c.B
    return ($c.B -gt $c.R + 12) -and ($sum -gt 45) -and ($sum -lt 3 * 140)
}
function Get-ColorDistance($a, $b) {
    return [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
}
function Fmt($c) { if ($null -eq $c) { 'null' } else { "$($c.R),$($c.G),$($c.B)" } }

# The rail's pin (pane_sidebar.zig layoutMini) with the elevated insets.
function Get-RailPinCenter($sb) {
    $m = Get-MarginPx; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $m + $inset + [int]($tile / 2); Y = $sb.Top + $m + $inset + [int]($tile / 2) }
}
# The pinned panel's pin: 28 DIP, sm (4) from the trailing edge, 18 DIP down.
function Get-PanelPinCenter($sb) {
    return @{ X = $sb.Right - (Px 4) - [int]((Px 28) / 2); Y = $sb.Top + (Px 18) }
}
function Click($top, $target, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $pt.X -Y $pt.Y -Action click
}
function Wait-SidebarWidth($top, [int]$Want, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $sb = Get-Sidebar $top
        if ($null -ne $sb -and [math]::Abs($sb.Width - $Want) -le 1) { return $sb }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return (Get-Sidebar $top)
}
# A PrintWindow of the top-level window; $null (with the reason) when the
# capture came back empty.
function Get-Shot($top, [string]$Name) {
    $shot = Get-TestWindowPixels -Window $top -Sync
    $distinct = Get-TestDistinctColors -Shot $shot
    if ($distinct -lt 4) {
        Close-TestWindowPixels $shot
        "  capture for $Name came back empty ($distinct colors)"
        return $null
    }
    try { $shot.Bitmap.Save((Join-Path $env:TEMP "t1850-$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
    return $shot
}

# The open card's first present logs what it sent (PaneSidebar.presentCard):
# the line carries `glass=<bool> interior_alpha=<n>`.
function Get-GlassLine([string]$Log, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $line = $null
    do {
        $line = @(Get-Content $Log -ErrorAction SilentlyContinue | Select-Object -Skip $Skip |
            Where-Object { $_ -match 'pane sidebar card glass=' }) | Select-Object -Last 1
        if ($line) { break }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $line
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1850'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $errlog = Join-Path $tmp 'app-stderr.log'
    # The default style is elevated; a black terminal makes the desk the only
    # blue thing in the window.
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -Arguments @('--config-default-files=false',
        '--session-persistence=false', '--background=#000000', '--unfocused-split-opacity=1')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    $m = Get-MarginPx; $i = Get-InsetPx
    "  (window dpi $dpi, scale $($script:scale), margin $m, rim $i)"
    # Wide enough for the pinned panel (>= 720 DIP).
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800

    "== 1: the rail is 10 + 44 DIP, and the rail-to-pane gutter is the edge-to-rail one"
    $sb = Get-Sidebar $top
    Assert "a GhozttyPaneSidebar child exists and is visible" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $railW = (Get-MarginPx) + (Px 44)
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: expecting the flat style's 68 DIP rail - this run MUST fail"
        $railW = Px 68
    }
    Assert "the rail column is Mac's elevated 54 DIP ($($sb.Width) vs $railW)" ([math]::Abs($sb.Width - $railW) -le 1)
    $panes = @(Get-Panes $top)
    Assert "setup: one visible pane ($($panes.Count))" ($panes.Count -eq 1)
    if ($panes.Count -lt 1) { return }
    $p = $panes[0]
    $gutter = $p.Left - $sb.Right - $i
    Assert "the pane starts one grid margin after the rail ($gutter vs $m)" ($gutter -eq $m)

    "== 2: the desk runs under the rail"
    $shot = Get-Shot $top 'rail'
    Assert "the window capture has content" ($null -ne $shot)
    if ($null -ne $shot) {
        try {
            $midY = [int](($sb.Top + $sb.Bottom) / 2)
            $lead = Get-TestPixel -Shot $shot -X ($sb.Left + [int][math]::Floor($m / 2)) -Y $midY
            $cardY = $sb.Bottom - (Px 60)
            $card = Get-TestPixel -Shot $shot -X ($sb.Left + $m + (Px 22)) -Y $cardY
            $deskAtCard = Get-TestPixel -Shot $shot -X ($sb.Left + [int][math]::Floor($m / 2)) -Y $cardY
            $y = $sb.Top + 2
            $inCol = Get-TestPixel -Shot $shot -X ($sb.Right - 2) -Y $y
            $inGrid = Get-TestPixel -Shot $shot -X ($sb.Right + 1) -Y $y
            "  leading inset=$(Fmt $lead) card=$(Fmt $card) column-edge=$(Fmt $inCol) grid-margin=$(Fmt $inGrid)"
            Assert "the rail's leading inset is the ocean desk, not the terminal background" (Test-DeskPixel $lead)
            # Glass (T1887): black at 30% over the desk, then the card's sheen
            # and grounding shade (a few levels either way) - and no wash.
            $want = $null
            if ($null -ne $deskAtCard) {
                $want = [pscustomobject]@{ R = [int]($deskAtCard.R * 0.7); G = [int]($deskAtCard.G * 0.7); B = [int]($deskAtCard.B * 0.7) }
            }
            $dg = if ($null -ne $want -and $null -ne $card) { Get-ColorDistance $card $want } else { 999 }
            "  desk beside the card=$(Fmt $deskAtCard) glass expected=$(Fmt $want) (distance $dg)"
            Assert "the rail's card is the desk under 30% terminal background - glass, no wash (distance $dg)" ($dg -le 15)
            Assert "the desk shows through the rail's card (blue over red)" ($null -ne $card -and $card.B -ge $card.R + 6)
            Assert "the column's top inset is the desk too" (Test-DeskPixel $inCol)
            $d = Get-ColorDistance $inCol $inGrid
            Assert "the column meets the grid margin without a seam (distance $d)" ($d -le 24)
        } finally { Close-TestWindowPixels $shot }
    }

    "== 3: pinned, the panel is translucent over the desk, with no rule"
    $r = Click $top $sb.Hwnd (Get-RailPinCenter $sb)
    Assert "pin click delivered" $r
    $sb = Wait-SidebarWidth $top (Px 240)
    Assert "the pinned panel is 240 DIP ($($sb.Width) vs $(Px 240))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 240)) -le 1)
    Start-Sleep -Milliseconds 500
    $p = (@(Get-Panes $top))[0]
    $gutter = $p.Left - $sb.Right - $i
    Assert "the pane starts one grid margin after the panel ($gutter vs $m)" ($gutter -eq $m)
    $shot = Get-Shot $top 'panel'
    Assert "the window capture has content" ($null -ne $shot)
    if ($null -ne $shot) {
        try {
            $y = $sb.Bottom - (Px 24)
            $panel = Get-TestPixel -Shot $shot -X ($sb.Left + [int]($sb.Width / 2)) -Y $y
            $edge = Get-TestPixel -Shot $shot -X ($sb.Right - 1) -Y $y
            $inner = Get-TestPixel -Shot $shot -X ($sb.Right - (Px 8)) -Y $y
            $desk = Get-TestPixel -Shot $shot -X ($sb.Right + 1) -Y $y
            "  panel=$(Fmt $panel) trailing-edge=$(Fmt $edge) inside-edge=$(Fmt $inner) margin-desk=$(Fmt $desk)"
            Assert "the desk shows through the panel (blue over red)" ($null -ne $panel -and $panel.B -ge $panel.R + 6)
            # banner_card.glassPanel over the desk a few pixels away: black at
            # 38%, then the card's 6% white wash (a dark terminal).
            $want = $null
            if ($null -ne $desk) {
                $f = { param($v) [int][math]::Round(($v * 0.62) * 0.94 + 255 * 0.06) }
                $want = [pscustomobject]@{ R = (& $f $desk.R); G = (& $f $desk.G); B = (& $f $desk.B) }
            }
            $dg = if ($null -ne $want -and $null -ne $inner) { Get-ColorDistance $inner $want } else { 999 }
            "  glass expected beside the desk=$(Fmt $want) (distance $dg)"
            Assert "the panel is the terminal background at 38% plus the wash over the desk (distance $dg)" ($dg -le 9)
            $d = Get-ColorDistance $edge $inner
            Assert "no divider rule at the panel's trailing edge (distance $d)" ($d -le 12)
        } finally { Close-TestWindowPixels $shot }
    }

    "== 4: unpinning brings the 54 DIP rail back"
    $logBefore = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-PanelPinCenter $sb))
    $sb = Wait-SidebarWidth $top $railW
    Assert "back to the rail ($($sb.Width))" ($null -ne $sb -and [math]::Abs($sb.Width - $railW) -le 1)

    "== 5: the card the unpin opens is a see-through glass sheet (T1887)"
    $gl = Get-GlassLine $errlog $logBefore; "  $gl"
    $gm = [regex]::Match([string]$gl, 'glass=(\w+) interior_alpha=(\d+)')
    Assert "the open card logged its layer" $gm.Success
    if ($gm.Success) {
        Assert "the open card is glass" ($gm.Groups[1].Value -eq 'true')
        $ia = [int]$gm.Groups[2].Value
        Assert "its empty middle lets the panes through at Mac's 30% tint (alpha $ia of 255, want 70-100)" ($ia -ge 70 -and $ia -le 100)
    }
    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)

    "== 7: beside the tab strip the column runs the window's height (T1900)"
    $errlog3 = Join-Path $tmp 'app-stderr-strip.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog3 -Arguments @('--config-default-files=false',
        '--session-persistence=false', '--background=#000000', '--unfocused-split-opacity=1',
        '--window-show-tab-bar=always')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: strip top window not found"; $script:failures++; return }
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $cr = Get-TestWindowRect -Window $top -Client
    $sb = Get-Sidebar $top
    $regions = Get-TestStripRegions -Window $top -Exe $Exe
    $p = (@(Get-Panes $top))[0]
    Assert "setup: a sidebar, a strip and a pane" ($null -ne $sb -and $null -ne $regions -and $null -ne $p)
    if ($null -eq $sb -or $null -eq $regions -or $null -eq $p) { return }
    $colRight = $sb.Right - $cr.Left
    $wantTop = $cr.Top
    if ($NegativeControl) { $wantTop = $cr.Top + $regions.Band.Bottom }
    "  column top=$($sb.Top - $cr.Top) right=$colRight; band left=$($regions.Band.Left) bottom=$($regions.Band.Bottom); first tab=$($regions.Tabs[0].Left)"
    Assert "the column starts at the client's top, beside the strip ($($sb.Top - $cr.Top))" ($sb.Top -eq $wantTop)
    Assert "the strip starts at the column's edge (band $($regions.Band.Left) vs $colRight + $(Px 4))" ($regions.Band.Left -eq $colRight + (Px 4))
    Assert "the first tab sits right of the column ($($regions.Tabs[0].Left) >= $colRight)" ($null -ne $regions.Tabs[0] -and $regions.Tabs[0].Left -ge $colRight)
    $gap = ($p.Top - $i) - ($cr.Top + $regions.Band.Bottom)
    Assert "the tabs sit one 10 DIP gap above the panes ($gap vs $m)" ($gap -eq $m)
    # The strip's row of the column: a drag handle, not a sidebar click.
    $hx = $sb.Left + [int]($sb.Width / 2); $hy = $cr.Top + [int]($regions.Band.Bottom / 2)
    $lp = [IntPtr](([int64]($hy -band 0xFFFF) -shl 16) -bor [int64]($hx -band 0xFFFF))
    $hitCol = [int](Invoke-TestMessage -Window ([IntPtr]$sb.Hwnd) -Message 0x0084 -LParam $lp)
    $hitWin = [int](Invoke-TestMessage -Window $top -Message 0x0084 -LParam $lp)
    Assert "the column is click-through beside the strip (HTTRANSPARENT, got $hitCol)" ($hitCol -eq -1)
    Assert "the window answers HTCAPTION there, so it drags (got $hitWin)" ($hitWin -eq 2)
    $shot = Get-Shot $top 'beside-strip'
    Assert "the strip window capture has content" ($null -ne $shot)
    if ($null -ne $shot) {
        try {
            # Halfway down the strip's row: the rail's card is there, with the
            # desk in the column's leading inset. Not section 2's 30% formula:
            # this high up the card's sheen lifts it, so the question is only
            # whether the card's material is drawn here at all - without the
            # reach this pixel is the strip's own glass, the desk a few pixels
            # from the inset sample.
            $card = Get-TestPixel -Shot $shot -X ($sb.Left + $m + (Px 22)) -Y $hy
            $lead = Get-TestPixel -Shot $shot -X ($sb.Left + [int][math]::Floor($m / 2)) -Y $hy
            $dg = if ($null -ne $lead -and $null -ne $card) { Get-ColorDistance $card $lead } else { 0 }
            "  beside the strip: leading inset=$(Fmt $lead) card=$(Fmt $card) (distance $dg)"
            Assert "the column's leading inset beside the strip is the desk" (Test-DeskPixel $lead)
            Assert "the rail's card runs up beside the strip: its glass, not the bare desk (distance $dg)" ($dg -ge 15 -and $card.B -ge $card.R + 6)
        } finally { Close-TestWindowPixels $shot }
    }
    # The pin is a strip's height lower than in section 3, and still pins.
    $reach = $regions.Band.Bottom
    $pin = Get-RailPinCenter $sb
    $pin.Y += $reach
    [void](Click $top $sb.Hwnd $pin)
    $sb = Wait-SidebarWidth $top (Px 240)
    Assert "the rail's pin, below the strip's row, still pins ($($sb.Width) vs $(Px 240))" ($null -ne $sb -and [math]::Abs($sb.Width - (Px 240)) -le 1)
    Start-Sleep -Milliseconds 500
    $regions = Get-TestStripRegions -Window $top -Exe $Exe
    $colRight = $sb.Right - $cr.Left
    Assert "the strip follows the pinned panel's edge (band $($regions.Band.Left) vs $colRight + $(Px 4))" ($null -ne $regions -and $regions.Band.Left -eq $colRight + (Px 4))
    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)

    "== 6: --macos-pane-glass=false keeps the opaque card"
    $errlog2 = Join-Path $tmp 'app-stderr-solid.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog2 -Arguments @('--config-default-files=false',
        '--session-persistence=false', '--background=#000000', '--unfocused-split-opacity=1', '--macos-pane-glass=false',
        '--window-show-tab-bar=always')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: second top window not found"; $script:failures++; return }
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    # T1900: solid panes keep the column under the chrome, the strip full width.
    $cr = Get-TestWindowRect -Window $top -Client
    $regions = Get-TestStripRegions -Window $top -Exe $Exe
    if ($null -ne $sb -and $null -ne $regions) {
        Assert "solid: the column starts under the strip ($($sb.Top - $cr.Top) vs $($regions.Band.Bottom))" ($sb.Top - $cr.Top -eq $regions.Band.Bottom)
        Assert "solid: the strip starts at the window's edge (band $($regions.Band.Left))" ($regions.Band.Left -eq (Px 4))
    } else { Assert "solid: a sidebar and a strip" $false }
    $shot = Get-Shot $top 'rail-solid'
    Assert "the solid window capture has content" ($null -ne $shot)
    if ($null -ne $shot -and $null -ne $sb) {
        try {
            $card = Get-TestPixel -Shot $shot -X ($sb.Left + (Get-MarginPx) + (Px 22)) -Y ($sb.Bottom - (Px 60))
            "  solid rail card=$(Fmt $card)"
            Assert "the rail's card is the card material, not the desk" (-not (Test-DeskPixel $card))
        } finally { Close-TestWindowPixels $shot }
    }
    [void](Click $top $sb.Hwnd (Get-RailPinCenter $sb))
    $sb = Wait-SidebarWidth $top (Px 240)
    Start-Sleep -Milliseconds 500
    $logBefore = @(Get-Content $errlog2 -ErrorAction SilentlyContinue).Count
    [void](Click $top $sb.Hwnd (Get-PanelPinCenter $sb))
    $gl = Get-GlassLine $errlog2 $logBefore; "  $gl"
    $gm = [regex]::Match([string]$gl, 'glass=(\w+) interior_alpha=(\d+)')
    Assert "the solid open card logged its layer" $gm.Success
    if ($gm.Success) {
        Assert "the open card is not glass ($($gm.Groups[1].Value))" ($gm.Groups[1].Value -eq 'false')
        Assert "its middle is opaque (alpha $($gm.Groups[2].Value))" ([int]$gm.Groups[2].Value -eq 255)
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
        update -Guard pane-sidebar-elevated -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1850' -Path $transcript `
        -Label 'T1850 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
