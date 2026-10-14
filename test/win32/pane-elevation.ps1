# T1831 acceptance: the elevated pane style (Mac `macos-pane-style`, main
# 91ba7c08c / fe3f7c8da) - every pane is a raised rounded card on the "ocean"
# desk, with ONE spacing (10 DIP) for the window margin and the pane gap, and
# the gap is still the divider.
#
# What is asserted, and how:
#
#   GEOMETRY. The pane child sits margin + rim-inset inside the content area's
#   right and bottom edges (the left edge belongs to the pane sidebar's column
#   and the top to the chrome, so those two are not where the margin is
#   measured), and two panes split down are gap + 2 x rim-inset apart.
#
#   THE DESK. A PrintWindow of the top-level window (the parent's own paint;
#   the OpenGL panes come back as a flat fill) reads the right margin and the
#   middle of the gap as the ocean desk on this dark theme: a dark blue-teal,
#   blue above red, never the black terminal and never a divider gray.
#
#   THE CARD SHAPE. The window manager says which points of the pane's child
#   window it paints through (`Get-TestWindowRegionHits`): the square corner is
#   cut away, the centre is not. Flat panes have no region at all.
#
#   THE DIVIDER. A posted drag that starts in the middle of the gap moves the
#   split - the gap is the grab band, edge to edge.
#
#   FLAT. `--macos-pane-style=flat` is the classic geometry byte for byte: no
#   margin, the 2 DIP band, no region.
#
#   LIVE RELOAD. A config file flipped from flat to elevated and reloaded
#   (ctrl+shift+,) re-lays the open window out as cards, as on Mac.
#
#   GLASS (T1833). `macos-pane-glass` (default on) makes each pane a glass
#   sheet: 40% of the terminal background over the desk. The pane's OWN
#   pixels are read through the debug `capture-pane` IPC (lib\PaneCapture.ps1;
#   PrintWindow returns the GL child as a flat fill): on a black terminal the
#   blank bottom of the pane is the desk's blue-over-red, and its two ends
#   differ because the gradient does. The pane's right edge is checked against
#   the desk in the margin beside it, mixed the way the renderer mixes - 60%
#   of the desk, in linear light - so the pane and its card meet without a
#   seam. `--macos-pane-glass=false` and a translucent window
#   (`background-opacity` below 1)
#   keep the solid black pane.
#
#   TRANSLUCENT DESK (T1852). At `background-opacity = 0.5` the desk is
#   blitted premultiplied at half strength; toggled opaque on the same window
#   it reads full strength.
#
#   FOCUS GLOW (T1834). Of two cards, only the focused one lights the desk
#   just past its edge, and a goto_split moves the light to the other card.
#
# Runs on a background desktop (test/win32/lib/TestDesktop.ps1): nothing here
# takes the user's foreground, which is asserted at the end.
#
# -NegativeControl inverts the elevated-margin assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-elevation.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-elevtest$PID"
$conf = Join-Path $env:TEMP "ghoztty-pane-elevation-$PID.conf"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\WindowComposite.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# Zig's @round is half-away-from-zero; .NET's default is banker's.
function Round-Away([double]$v) { [int][math]::Round($v, [MidpointRounding]::AwayFromZero) }

# pane_elevation.zig mirrored: the margin/gap, and the rim inset.
function Get-MarginPx([double]$scale) { [math]::Max((Round-Away (10.0 * $scale)), 1) }
function Get-InsetPx([double]$scale) { [math]::Max([int][math]::Ceiling(0.5 * $scale), 1) }
# split_geometry.bandPx: the flat band.
function Get-BandPx([double]$scale) { [math]::Max((Round-Away (2.0 * $scale)), 2) }

# The ocean desk on a dark theme: dark, blue above red, and neither the black
# terminal nor a neutral divider gray.
function Test-DeskPixel($c) {
    if ($null -eq $c) { return $false }
    $sum = $c.R + $c.G + $c.B
    return ($c.B -gt $c.R + 12) -and ($sum -gt 45) -and ($sum -lt 3 * 140)
}

function Start-Gui([string]$label, [string[]]$extraArgs, [switch]$Split) {
    Kill-RepoInstances
    # persistence: off - every caller passes $common (--session-persistence=false);
    # a restored layout would seed panes whose geometry this script did not make.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $extraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) "$label window is NOT enumerable on the interactive desktop"
    if ($Split) {
        & $exe +split --direction=down | Out-Null
        Start-Sleep -Milliseconds 900
    }
    $panes = @(Get-Panes $top)
    $want = if ($Split) { 2 } else { 1 }
    Assert ($panes.Count -eq $want) "$label setup: $want visible pane(s) (saw $($panes.Count))"
    if ($panes.Count -ne $want) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    $scale = (Get-TestWindowDpi -Window $top) / 96.0
    [pscustomobject]@{ App = $app; Top = $top; Panes = $panes; Scale = $scale }
}

# A glass pane over desk colour $c on a black terminal: 60% of the desk,
# mixed in linear light (pane_elevation.glassMix, and the renderer's own
# background-image blend under the default linear alpha-blending).
function Get-GlassExpect($c) {
    $out = @()
    foreach ($v in @($c.R, $c.G, $c.B)) {
        $x = $v / 255.0
        $lin = if ($x -le 0.04045) { $x / 12.92 } else { [math]::Pow(($x + 0.055) / 1.055, 2.4) }
        $l = $lin * 0.6
        $sr = if ($l -le 0.0031308) { $l * 12.92 } else { 1.055 * [math]::Pow($l, 1 / 2.4) - 0.055 }
        $out += [int][math]::Round($sr * 255)
    }
    return $out
}

# The pane's own pixels (capture-pane), sampled where the shell draws
# nothing: the bottom tenth, near each end. Returns $null with the reason
# printed when the capture is unavailable.
function Get-GlassSamples([IntPtr]$top, [string]$label, [int]$Index = 0) {
    $targets = @()
    for ($t = 0; $t -lt 20 -and $targets.Count -le $Index; $t++) {
        $targets = @(Get-TestWindowPaneTargets -Window $top -Exe $exe)
        if ($targets.Count -le $Index) { Start-Sleep -Milliseconds 300 }
    }
    if ($targets.Count -le $Index) { Write-Host "      $label`: the window listed no terminal pane #$Index"; return $null }
    $shot = $null
    for ($t = 0; $t -lt 20 -and $null -eq $shot; $t++) {
        $shot = Get-TestPaneCapture -Target $targets[$Index]
        if ($null -eq $shot) { Start-Sleep -Milliseconds 300 }
    }
    if ($null -eq $shot) { Write-Host "      $label`: capture failed: $(Get-LastPaneCaptureError)"; return $null }
    try {
        $y = [int]($shot.Height * 0.9)
        $l = $shot.Bitmap.GetPixel([int]($shot.Width * 0.1), $y)
        $r = $shot.Bitmap.GetPixel([int]($shot.Width * 0.9), $y)
        $e = $shot.Bitmap.GetPixel($shot.Width - 3, [int]($shot.Height / 2))
        Write-Host "      $label`: pane $($shot.Width)x$($shot.Height) bottom-left=$($l.R),$($l.G),$($l.B) bottom-right=$($r.R),$($r.G),$($r.B) right-edge=$($e.R),$($e.G),$($e.B)"
        return [pscustomobject]@{ Left = $l; Right = $r; Edge = $e; EdgeY = [int]($shot.Height / 2) }
    } finally { Close-TestPaneCapture $shot }
}

# The desk seen through a glass pane on a black terminal: 60% of the desk,
# so dimmer than Test-DeskPixel's margin - but never the terminal black, and
# still blue above red.
function Test-GlassPixel($c) {
    if ($null -eq $c) { return $false }
    return (($c.R + $c.G + $c.B) -ge 24) -and ($c.B -ge $c.R + 4)
}

function Get-ColorDistance($a, $b) {
    return [math]::Abs($a.R - $b.R) + [math]::Abs($a.G - $b.G) + [math]::Abs($a.B - $b.B)
}

# The client rect in SCREEN coordinates (Get-TestChildWindows reports screen).
function Get-ClientScreen([IntPtr]$top) {
    Get-TestWindowRect -Window $top -Client
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$common = @('--config-default-files=false', '--background=#000000',
    '--unfocused-split-opacity=1', '--session-persistence=false')

try {

# ---------------------------------------------------------------------------
# Run 1: the default style is elevated.
# ---------------------------------------------------------------------------
$g = Start-Gui 'elevated' $common
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
$p = $g.Panes[0]
$cs = Get-ClientScreen $top
$rightGap = [int]($cs.Right - $p.Right)
$bottomGap = [int]($cs.Bottom - $p.Bottom)
Write-Host "      scale=$($g.Scale) margin=$m inset=$i pane=($($p.Left),$($p.Top),$($p.Right),$($p.Bottom)) right-gap=$rightGap bottom-gap=$bottomGap"
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the pane runs to the window edge - this run MUST fail'
    Assert ($rightGap -eq 0) 'elevated: the pane runs edge to edge (negative control)'
} else {
    Assert ($rightGap -eq $m + $i) "elevated: the pane sits margin+rim ($($m + $i)px) inside the right edge"
}
Assert ($bottomGap -eq $m + $i) "elevated: the pane sits margin+rim ($($m + $i)px) inside the bottom edge"

# The card shape: the child window's square corners are cut away.
$pw = $p.Right - $p.Left; $ph = $p.Bottom - $p.Top
$hits = Get-TestWindowRegionHits -Window ([IntPtr]$p.Hwnd) -Points @(0, 0, ($pw - 1), ($ph - 1), [int]($pw / 2), [int]($ph / 2))
Assert ($null -ne $hits) 'elevated: the pane child has a window region (rounded card)'
if ($null -ne $hits) {
    Assert ((-not $hits[0]) -and (-not $hits[1])) 'elevated: the top-left and bottom-right corners are cut away'
    Assert $hits[2] 'elevated: the pane centre is inside the region'
}

# The desk: the right margin, halfway down the pane.
$shot = Get-TestWindowPixels -Window $top -Sync
try {
    $distinct = Get-TestDistinctColors -Shot $shot
    if ($distinct -lt 4) {
        $script:skipped++; Write-Host "SKIP  elevated desk probe: empty capture ($distinct colors)"
    } else {
        $mx = [int]($p.Right + [math]::Floor(($m + $i) / 2))
        $my = [int](($p.Top + $p.Bottom) / 2)
        $c = Get-TestPixel -Shot $shot -X $mx -Y $my
        Write-Host "      right-margin pixel ($mx,$my) = $($c.R),$($c.G),$($c.B)"
        Assert (Test-DeskPixel $c) 'elevated: the right margin is the ocean desk'
    }
} finally { Close-TestWindowPixels $shot }

# Split it: two cards, gap + 2 x rim apart, the gap is the desk and the divider.
& $exe +split --direction=down | Out-Null
Start-Sleep -Milliseconds 900
$panes = @(Get-Panes $top)
Assert ($panes.Count -eq 2) 'elevated: split down gives 2 visible panes'
if ($panes.Count -eq 2) {
    $A = $panes | Sort-Object Top | Select-Object -First 1
    $B = $panes | Sort-Object Top | Select-Object -Last 1
    $gap = [int]($B.Top - $A.Bottom)
    Write-Host "      pane gap = $gap (expected $($m + 2 * $i))"
    Assert ($gap -eq $m + 2 * $i) 'elevated: the panes are one spacing (+ both rims) apart'
    Assert ($A.Left -eq $B.Left -and $A.Right -eq $B.Right) 'elevated: both cards share their left and right edges'

    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        $gx = [int](($A.Left + $A.Right) / 2)
        $gy = [int](($A.Bottom + $B.Top) / 2)
        $c = Get-TestPixel -Shot $shot -X $gx -Y $gy
        Write-Host "      mid-gap pixel ($gx,$gy) = $($c.R),$($c.G),$($c.B)"
        if ((Get-TestDistinctColors -Shot $shot) -lt 4) {
            $script:skipped++; Write-Host 'SKIP  gap probe: empty capture'
        } else {
            Assert (Test-DeskPixel $c) 'elevated: the gap between the cards is the desk, not a divider line'
        }
    } finally { Close-TestWindowPixels $shot }

    # The gap is the grab band: a drag from its middle moves the split.
    $h0 = $A.Bottom - $A.Top
    $gx = [int](($A.Left + $A.Right) / 2)
    $gy = [int](($A.Bottom + $B.Top) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $gy -Action down)
    for ($k = 1; $k -le 8; $k++) {
        [void](Send-TestMouse -Window $top -Target $top -X $gx -Y ($gy + 8 * $k) -Action move)
    }
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y ($gy + 64) -Action up)
    Start-Sleep -Milliseconds 400
    $A2 = Get-Panes $top | Sort-Object Top | Select-Object -First 1
    $grew = ($A2.Bottom - $A2.Top) - $h0
    Write-Host "      drag from mid-gap: top pane grew $grew px (asked 64)"
    Assert ([math]::Abs($grew - 64) -le 6) 'elevated: a drag from the middle of the gap moves the divider'
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'elevated: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 1b: glass panes (T1833) - the default.
# ---------------------------------------------------------------------------
$g = Start-Gui 'glass' $common
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$p = $g.Panes[0]
$i = Get-InsetPx $g.Scale
Start-Sleep -Milliseconds 800
$gs = Get-GlassSamples $top 'glass'
if ($null -eq $gs) {
    $script:skipped++; Write-Host 'SKIP  glass probes: no pane capture'
} else {
    Assert (Test-GlassPixel $gs.Left) 'glass: the blank bottom-left of a black pane is the desk showing through'
    Assert (Test-GlassPixel $gs.Right) 'glass: so is the bottom-right'
    Assert ((Get-ColorDistance $gs.Left $gs.Right) -ge 6) 'glass: the two ends differ - the gradient runs through the pane'
    # The seam: the pane's right edge against 60% of the desk just outside
    # the card, at the same height (the margin's desk, past the rim).
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        $mx = [int]($p.Right + $i + 2)
        $my = [int]($p.Top + $gs.EdgeY)
        $d = Get-TestPixel -Shot $shot -X $mx -Y $my
        if ($null -eq $d -or -not (Test-DeskPixel $d)) {
            $script:skipped++; Write-Host "SKIP  glass seam: no desk pixel beside the pane ($mx,$my)"
        } else {
            $want = Get-GlassExpect $d
            $diff = [math]::Abs($gs.Edge.R - $want[0]) + [math]::Abs($gs.Edge.G - $want[1]) + [math]::Abs($gs.Edge.B - $want[2])
            Write-Host "      desk beside the pane ($mx,$my) = $($d.R),$($d.G),$($d.B); glass over it = $($want -join ','); pane edge off by $diff"
            Assert ($diff -le 12) 'glass: the pane edge is 40% black over the desk beside it, in linear light - no seam'
        }
    } finally { Close-TestWindowPixels $shot }
}
# A pane a split creates is glass too, and so is the one it halved - the
# new terminal's renderer comes up after the paint that placed it, so this
# is the case where a backdrop could be missed.
& $exe +split --direction=down | Out-Null
Start-Sleep -Milliseconds 1500
foreach ($ix in 0, 1) {
    $ss = Get-GlassSamples $top "glass split #$ix" -Index $ix
    if ($null -eq $ss) {
        $script:skipped++; Write-Host "SKIP  glass split #$ix probe: no pane capture"
    } else {
        Assert ((Test-GlassPixel $ss.Left) -and (Test-GlassPixel $ss.Right)) "glass: after a split, pane #$ix shows the desk through it"
    }
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'glass: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

foreach ($case in @(
        @{ Label = 'solid'; Args = @('--macos-pane-glass=false'); Why = '--macos-pane-glass=false' },
        @{ Label = 'translucent'; Args = @('--background-opacity=0.85'); Why = 'a translucent window' })) {
    $g = Start-Gui $case.Label ($common + $case.Args)
    $launched += $script:GhozttyTestDesktopPids
    Start-Sleep -Milliseconds 800
    $gs = Get-GlassSamples $g.Top $case.Label
    if ($null -eq $gs) {
        $script:skipped++; Write-Host "SKIP  $($case.Label) probe: no pane capture"
    } else {
        $black = [pscustomobject]@{ R = 0; G = 0; B = 0 }
        Assert (((Get-ColorDistance $gs.Left $black) -le 6) -and ((Get-ColorDistance $gs.Right $black) -le 6)) "$($case.Label): $($case.Why) keeps the pane the solid terminal black"
    }
    Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Run 1b1: the bands above a glass pane are glass too (T1884; Mac 8174d96fc
# drops the banner strip's base fill, and its header is `.regularMaterial`
# over the card). One window per mode, black terminal, rearrange mode on and a
# banner set. Probed:
#   HEADER - the parent's own paint (WM_PRINTCLIENT), mid-band, three
#     quarters across: solid, it is the chrome bar colour; glass,
#     it is 70% of that bar over the sheet over the desk beside the card, and
#     so no longer the bar.
#   BANNER - the strip's own paint: the margin round its floating card is the
#     pane's black solid, or on glass the sheet over the desk beside it (60%
#     of the desk); and the card itself carries the desk's blue through it.
# ---------------------------------------------------------------------------
function ConvertTo-Lin([double]$v) { $x = $v / 255.0; if ($x -le 0.04045) { $x / 12.92 } else { [math]::Pow(($x + 0.055) / 1.055, 2.4) } }
function ConvertTo-Srgb([double]$l) { $s = if ($l -le 0.0031308) { $l * 12.92 } else { 1.055 * [math]::Pow($l, 1 / 2.4) - 0.055 }; [int][math]::Round([math]::Min([math]::Max($s, 0), 1) * 255) }
# pane_elevation.glassHeadMix on a black terminal: the sheet (60% of the desk),
# then the band's colour at HEAD_MATERIAL (0.7) over it, in linear light.
function Get-GlassHeadExpect($desk, $bar) {
    $sheet = Get-GlassExpect $desk
    $out = @()
    $bc = @($bar.R, $bar.G, $bar.B)
    for ($k = 0; $k -lt 3; $k++) { $out += ConvertTo-Srgb (0.3 * (ConvertTo-Lin $sheet[$k]) + 0.7 * (ConvertTo-Lin $bc[$k])) }
    return $out
}
function Get-ExpectDistance($c, $want) { [math]::Abs($c.R - $want[0]) + [math]::Abs($c.G - $want[1]) + [math]::Abs($c.B - $want[2]) }

function Get-BandProbes([string]$label, [string[]]$extra) {
    $g = Start-Gui $label ($common + $extra + @('--keybind=ctrl+shift+f9=toggle_rearrange_mode'))
    $script:launched += $script:GhozttyTestDesktopPids
    $top = $g.Top
    $i = Get-InsetPx $g.Scale
    $p0 = $g.Panes[0]
    Start-Sleep -Milliseconds 600
    $sent = Send-TestKeys -Window $top -Target ([IntPtr]$p0.Hwnd) -Modifiers ctrl, shift -Key f9
    Assert $sent "$label`: toggle_rearrange_mode delivered"
    $p1 = $null
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 200
        $p1 = @(Get-Panes $top)[0]
        if ($p1.Top -gt $p0.Top) { break }
    }
    Assert ($p1.Top -gt $p0.Top) "$label`: rearrange mode grew a header band above the pane ($($p0.Top) -> $($p1.Top))"
    $r = [pscustomobject]@{ Head = $null; HeadDesk = $null; Margin = $null; MarginDesk = $null; Card = $null }
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        if ((Get-TestDistinctColors -Shot $shot) -ge 4) {
            # Half a 24 DIP band above the pane, three quarters across it: past
            # the title, short of the pop-out button. Not measured from the
            # pane's old top - entering the mode moves the card too.
            $hy = [int]$p1.Top - (Round-Away (12 * $g.Scale))
            $r.Head = Get-TestPixel -Shot $shot -X ([int]($p1.Right - ($p1.Right - $p1.Left) * 0.25)) -Y $hy
            $r.HeadDesk = Get-TestPixel -Shot $shot -X ([int]$p1.Right + $i + 2) -Y $hy
        }
    } finally { Close-TestWindowPixels $shot }
    # The pane's own id is the banner's target (`--target` is required).
    $targets = @(Get-TestWindowPaneTargets -Window $top -Exe $exe)
    Assert ($targets.Count -ge 1) "$label`: the window lists its pane"
    if ($targets.Count -ge 1) { & $exe +set-banner "--target=$($targets[0])" 'T1884 glass band probe' | Out-Null }
    $ov = $null
    for ($t = 0; $t -lt 20 -and $null -eq $ov; $t++) {
        Start-Sleep -Milliseconds 200
        $ov = @(Get-TestWindows -ProcessId $g.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible) | Select-Object -First 1
    }
    Assert ($null -ne $ov) "$label`: the banner strip is up"
    if ($null -ne $ov) {
        Start-Sleep -Milliseconds 500
        $my = [int](($ov.Top + $ov.Bottom) / 2)
        $os = Get-TestWindowPixels -Window ([IntPtr]$ov.Hwnd) -Sync
        try {
            $r.Margin = Get-TestPixel -Shot $os -X ([int]$ov.Right - 3) -Y $my
            # Low in the card, past the sheen, short of the bottom shade.
            $r.Card = Get-TestPixel -Shot $os -X ([int]($ov.Left + ($ov.Right - $ov.Left) * 0.5)) -Y ([int]($ov.Top + ($ov.Bottom - $ov.Top) * 0.62))
        } finally { Close-TestWindowPixels $os }
        $ts = Get-TestWindowPixels -Window $top -Sync
        try { $r.MarginDesk = Get-TestPixel -Shot $ts -X ([int]$ov.Right + $i + 2) -Y $my } finally { Close-TestWindowPixels $ts }
    }
    foreach ($k in 'Head', 'HeadDesk', 'Margin', 'MarginDesk', 'Card') {
        $c = $r.$k
        if ($null -ne $c) { Write-Host "      $label $k = $($c.R),$($c.G),$($c.B)" }
    }
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) "$label`: no crash"
    Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
    return $r
}

$solidBands = Get-BandProbes 'solid bands' @('--macos-pane-glass=false')
$glassBands = Get-BandProbes 'glass bands' @()
$black = [pscustomobject]@{ R = 0; G = 0; B = 0 }
if ($null -eq $solidBands.Margin -or $null -eq $solidBands.Head) {
    $script:skipped++; Write-Host 'SKIP  solid band probes: no capture'
} else {
    Assert ((Get-ColorDistance $solidBands.Margin $black) -le 3) 'solid bands: the margin round the banner card is the black pane background'
}
if ($null -eq $glassBands.Margin -or $null -eq $glassBands.MarginDesk -or -not (Test-DeskPixel $glassBands.MarginDesk)) {
    $script:skipped++; Write-Host 'SKIP  glass banner probes: no capture or no desk beside the strip'
} else {
    $want = Get-GlassExpect $glassBands.MarginDesk
    $d = Get-ExpectDistance $glassBands.Margin $want
    Write-Host "      glass banner margin vs the sheet over the desk beside it ($($want -join ',')): off by $d"
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the banner margin is the black pane - this run MUST fail'
        Assert ((Get-ColorDistance $glassBands.Margin $black) -le 3) 'glass bands: the banner margin is solid black (negative control)'
    } else {
        Assert (Test-GlassPixel $glassBands.Margin) 'glass bands: the margin round the banner card is the desk through glass, not the black pane'
    }
    Assert ($d -le 12) 'glass bands: the banner margin is the same sheet the pane is - no seam against the desk beside it'
    if ($null -ne $glassBands.Card -and $null -ne $solidBands.Card) {
        Assert (($glassBands.Card.B -ge $glassBands.Card.R + 4) -and ((Get-ColorDistance $glassBands.Card $solidBands.Card) -ge 6)) 'glass bands: the banner card is a wash over the glass, so the desk tints it'
    }
}
if ($null -eq $glassBands.Head -or $null -eq $solidBands.Head -or $null -eq $glassBands.HeadDesk -or -not (Test-DeskPixel $glassBands.HeadDesk)) {
    $script:skipped++; Write-Host 'SKIP  glass header probes: no capture or no desk beside the band'
} else {
    # The bar is mostly what the material is, so on a dark desk the glass
    # band sits only a few levels off the bar: the claim is that it matches
    # the glass model and is NEARER to it than to the opaque bar - which can
    # only be told apart when the model itself is off the bar.
    $bar = $solidBands.Head
    $want = Get-GlassHeadExpect $glassBands.HeadDesk $bar
    $sep = Get-ExpectDistance $bar $want
    $dm = Get-ExpectDistance $glassBands.Head $want
    $db = Get-ColorDistance $glassBands.Head $bar
    Write-Host "      glass header: model (70% bar over the sheet over the desk beside it) = $($want -join ','), bar = $($bar.R),$($bar.G),$($bar.B); off the model by $dm, off the bar by $db (model-to-bar $sep)"
    if ($sep -lt 3) {
        $script:skipped++; Write-Host "SKIP  glass header: this desk is within $sep of the bar - glass and solid cannot be told apart here"
    } else {
        Assert ($dm -le 6) 'glass bands: the rearrange header is the bar as a material over the glass sheet'
        Assert ($dm -lt $db) 'glass bands: the rearrange header is nearer the glass model than the opaque bar'
    }
}

# ---------------------------------------------------------------------------
# Run 1b2: a translucent window's desk takes background-opacity (T1852; Mac
# `PaneDesk` is `.opacity(backgroundOpacity)`). The desk is blitted with its
# own premultiplied alpha, so the window's own WM_PRINTCLIENT paint reads the
# right margin at ~opacity x the opaque desk. Measured on ONE window, toggled
# opaque with toggle_background_opacity, because every new window draws a
# random desk variant. Before T1852 the marker pass made the desk opaque and
# the two reads were equal.
# ---------------------------------------------------------------------------
$g = Start-Gui 'translucent-desk' ($common + @('--background-opacity=0.5', '--keybind=ctrl+alt+f8=toggle_background_opacity'))
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
$p = $g.Panes[0]
$mx = [int]($p.Right + [math]::Floor(($m + $i) / 2))
$my = [int](($p.Top + $p.Bottom) / 2)
function Get-MarginPixel([string]$label) {
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        $c = Get-TestPixel -Shot $shot -X $mx -Y $my
        if ($null -ne $c) { Write-Host "      $label right-margin pixel ($mx,$my) = $($c.R),$($c.G),$($c.B)" }
        return $c
    } finally { Close-TestWindowPixels $shot }
}
Start-Sleep -Milliseconds 600
$tr = Get-MarginPixel 'translucent'
Assert (Send-TestKeys -Window $top -Target ([IntPtr]$p.Hwnd) -Modifiers ctrl, alt -Key f8) 'translucent desk: toggle_background_opacity delivered'
Start-Sleep -Milliseconds 900
$op = Get-MarginPixel 'toggled opaque'
if ($null -eq $tr -or $null -eq $op) {
    $script:skipped++; Write-Host 'SKIP  translucent desk probe: margin pixel off the capture'
} else {
    Assert (Test-DeskPixel $op) 'translucent desk: toggled opaque, the margin is the ocean desk'
    $opSum = $op.R + $op.G + $op.B
    $ratio = if ($opSum -gt 0) { ($tr.R + $tr.G + $tr.B) / $opSum } else { 1 }
    Write-Host ("      translucent/opaque desk ratio = {0:N3} (opacity 0.5)" -f $ratio)
    Assert (($ratio -gt 0.4) -and ($ratio -lt 0.6)) 'translucent desk: at background-opacity 0.5 the desk paints at half strength (premultiplied)'
    $maxDev = [math]::Max([math]::Max([math]::Abs($tr.R - $op.R / 2), [math]::Abs($tr.G - $op.G / 2)), [math]::Abs($tr.B - $op.B / 2))
    Assert ($maxDev -le 3) "translucent desk: every channel is half the opaque desk's (max deviation $maxDev)"
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'translucent desk: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 1c: the focused pane's glow (T1834). Among two cards exactly one lights
# the desk just outside its right edge - measured as that pixel's brightness
# over the desk's at the far side of the margin, past the glow's ~8pt reach,
# so the gradient itself cancels out - and moving focus moves the light.
# ---------------------------------------------------------------------------
$g = Start-Gui 'glow' ($common + '--keybind=ctrl+alt+f9=goto_split:next') -Split
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
function Get-GlowLift($shot, $pane) {
    $cardRight = [int]$pane.Right + $i
    $y = [int](($pane.Top + $pane.Bottom) / 2)
    $near = Get-TestPixel -Shot $shot -X ($cardRight + (Round-Away (3 * $g.Scale))) -Y $y
    $far = Get-TestPixel -Shot $shot -X ($cardRight + $m - 1) -Y $y
    if ($null -eq $near -or $null -eq $far) { return $null }
    return ($near.R + $near.G + $near.B) - ($far.R + $far.G + $far.B)
}
function Get-GlowState([string]$label) {
    $panes = @(Get-Panes $top | Sort-Object Top)
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        if ((Get-TestDistinctColors -Shot $shot) -lt 4) { return $null }
        $lifts = @($panes | ForEach-Object { Get-GlowLift $shot $_ })
    } finally { Close-TestWindowPixels $shot }
    Write-Host "      $label glow lift (near - far, channel sum): top=$($lifts[0]) bottom=$($lifts[1])"
    return [pscustomobject]@{ Panes = $panes; Lifts = $lifts }
}
Start-Sleep -Milliseconds 600
$s1 = Get-GlowState 'before'
if ($null -eq $s1 -or $s1.Lifts.Count -ne 2 -or $null -eq $s1.Lifts[0] -or $null -eq $s1.Lifts[1]) {
    $script:skipped++; Write-Host 'SKIP  glow probes: empty capture'
} else {
    $litIx = if ($s1.Lifts[0] -gt $s1.Lifts[1]) { 0 } else { 1 }
    $dimIx = 1 - $litIx
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting neither card is lit - this run MUST fail'
        Assert ([math]::Abs($s1.Lifts[0] - $s1.Lifts[1]) -lt 15) 'glow: no card stands out (negative control)'
    } else {
        Assert (($s1.Lifts[$litIx] - $s1.Lifts[$dimIx]) -ge 15) 'glow: exactly one of two cards lights the desk beside it'
    }
    Assert ([math]::Abs($s1.Lifts[$dimIx]) -lt 12) 'glow: the other card leaves the desk beside it alone'
    # Move focus to the other pane; after the 250ms fade the light follows.
    Assert (Send-TestKeys -Window $top -Target ([IntPtr]$s1.Panes[$litIx].Hwnd) -Modifiers ctrl, alt -Key f9) 'glow: goto_split chord delivered'
    $moved = $false
    for ($t = 0; $t -lt 10 -and -not $moved; $t++) {
        Start-Sleep -Milliseconds 300
        $s2 = Get-GlowState "after focus move #$t"
        if ($null -ne $s2 -and $s2.Lifts.Count -eq 2) {
            $moved = ($s2.Lifts[$dimIx] - $s2.Lifts[$litIx]) -ge 15
        }
    }
    Assert $moved 'glow: moving focus to the other pane moves the light with it'
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'glow: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: flat is the classic geometry, unchanged.
# ---------------------------------------------------------------------------
$g = Start-Gui 'flat' ($common + '--macos-pane-style=flat') -Split
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1
$cs = Get-ClientScreen $top
$band = Get-BandPx $g.Scale
Assert ([int]($cs.Right - $A.Right) -eq 0) 'flat: the pane runs to the right edge'
Assert ([int]($B.Top - $A.Bottom) -eq $band) "flat: the panes are the classic ${band}px band apart"
$hits = Get-TestWindowRegionHits -Window ([IntPtr]$A.Hwnd) -Points @(0, 0)
Assert ($null -eq $hits) 'flat: the pane child has no window region'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: a live reload flips an open window from flat to elevated.
# ---------------------------------------------------------------------------
Set-Content -Path $conf -Value 'macos-pane-style = flat' -Encoding Ascii
$g = Start-Gui 'reload' ($common + "--config-file=$conf") -Split
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
$cs = Get-ClientScreen $top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
Assert ([int]($cs.Right - $A.Right) -eq 0) 'reload: flat before the reload'
Set-Content -Path $conf -Value 'macos-pane-style = elevated' -Encoding Ascii
Assert (Send-TestKeys -Window $top -Target ([IntPtr]$A.Hwnd) -Modifiers ctrl, shift -Key comma) 'reload: chord delivered'
$flipped = $false
for ($t = 0; $t -lt 25; $t++) {
    Start-Sleep -Milliseconds 200
    $A = Get-Panes $top | Sort-Object Top | Select-Object -First 1
    if ($A -and [int]($cs.Right - $A.Right) -eq $m + $i) { $flipped = $true; break }
}
Assert $flipped 'reload: the open window re-laid out as elevated cards'
# Elevated means glass by default (T1833): the open panes take their desk
# slices on the reload, not only panes made after it.
Start-Sleep -Milliseconds 800
$rs = Get-GlassSamples $top 'reload glass'
if ($null -eq $rs) {
    $script:skipped++; Write-Host 'SKIP  reload glass probe: no pane capture'
} else {
    Assert ((Test-GlassPixel $rs.Left) -and (Test-GlassPixel $rs.Right)) 'reload: the open pane turned to glass with the flip'
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'reload: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 4 (T1851): what sits at the top of a card takes the card's curve.
#
#   HEADER. Rearrange mode puts a header band across the top of each card.
#   Just inside the card's top-left corner - outside its curve - is the desk;
#   one pixel inside the curve is the band's own colour. Before T1851 the band
#   was a plain rectangle, so the corner pixel was the band's colour.
#
#   BANNER. A banner with no header above it is the card's top: its strip (a
#   popup) is cut to the card's corners, and squared again when a header goes
#   above it.
#
#   VIEWER. A viewer's card is the page's colour, not the terminal's: the
#   card's bottom rim row reads as the page, on a terminal chosen to be the
#   opposite of it.
# ---------------------------------------------------------------------------
$hdrArgs = $common + @('--macos-pane-glass=false', '--window-show-tab-bar=always',
    '--keybind=ctrl+shift+f9=toggle_rearrange_mode')
$g = Start-Gui 'corners' $hdrArgs
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$i = Get-InsetPx $g.Scale
$r = [math]::Max((Round-Away (11.0 * $g.Scale)), 2)
$k = $r - $i
$p0 = $g.Panes[0]

# The banner first, with no header: rounded top, square bottom.
$bt = @(Get-TestWindowPaneTargets -Window $top -Exe $exe) | Select-Object -First 1
& $exe +set-banner "--target=$bt" "corner probe" | Out-Null
$ov = $null
for ($t = 0; $t -lt 20 -and $null -eq $ov; $t++) {
    Start-Sleep -Milliseconds 250
    $ov = @(Get-TestWindows -ProcessId $g.App.Pid -Class 'GhozttyBannerOverlay') | Select-Object -First 1
}
Assert ($null -ne $ov) 'banner: the strip is up'
if ($null -ne $ov) {
    $bh = Get-TestWindowRegionHits -Window ([IntPtr]$ov.Hwnd) -Points @(0, 0, ($ov.Width - 1), 0, 0, ($ov.Height - 1), [int]($ov.Width / 2), [int]($ov.Height / 2))
    Assert ($null -ne $bh) 'banner: with no header above it, the strip has a window region'
    if ($null -ne $bh) {
        Assert ((-not $bh[0]) -and (-not $bh[1])) "banner: the strip's top corners are cut to the card's curve"
        Assert ($bh[2] -and $bh[3]) "banner: its bottom corners and centre are kept"
    }
}

# Rearrange mode on: the header goes above the banner.
$before = (Get-Panes $top)[0]
Assert (Send-TestKeys -Window $top -Target ([IntPtr]$before.Hwnd) -Modifiers ctrl, shift -Key f9) 'header: toggle_rearrange_mode delivered'
$after = $null
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 200
    $after = (Get-Panes $top)[0]
    if ($after.Top -gt $before.Top) { break }
}
Assert ($after.Top -gt $before.Top) 'header: the pane moved down for its header'
if ($null -ne $ov) {
    $bh = Get-TestWindowRegionHits -Window ([IntPtr]$ov.Hwnd) -Points @(0, 0)
    Assert ($null -eq $bh) 'banner: under a header the strip is square again (no region)'
}
& $exe +set-banner "--target=$bt" --clear | Out-Null
Start-Sleep -Milliseconds 700
$p = (Get-Panes $top)[0]
# The band starts where the card's inside does: the pane's old top less the
# banner it had, i.e. the top it had before both - $p0.
$bandL = [int]$p.Left; $bandT = [int]$p0.Top; $bandR = [int]$p.Right
$shot = Get-TestWindowPixels -Window $top -Sync
try {
    if ((Get-TestDistinctColors -Shot $shot) -lt 4) {
        $script:skipped++; Write-Host 'SKIP  header corner probes: empty capture'
    } else {
        $bar = Get-TestPixel -Shot $shot -X ([int](($bandL + $bandR) / 2)) -Y ($bandT + 1)
        $corner = Get-TestPixel -Shot $shot -X $bandL -Y $bandT
        $curve = Get-TestPixel -Shot $shot -X ($bandL + $k - 1) -Y ($bandT + $k - 1)
        $rcorner = Get-TestPixel -Shot $shot -X ($bandR - 1) -Y $bandT
        Write-Host "      band ($bandL,$bandT)-($bandR) k=$k bar=$($bar.R),$($bar.G),$($bar.B) corner=$($corner.R),$($corner.G),$($corner.B) right-corner=$($rcorner.R),$($rcorner.G),$($rcorner.B) inside-curve=$($curve.R),$($curve.G),$($curve.B)"
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the band corner is square - this run MUST fail'
            Assert ((Get-ColorDistance $corner $bar) -le 6) 'header: the band corner is the band colour (negative control)'
        } else {
            Assert (Test-DeskPixel $corner) "header: outside the card's curve, the band's top-left corner is the desk"
        }
        Assert (Test-DeskPixel $rcorner) "header: and so is its top-right corner"
        Assert ((Get-ColorDistance $curve $bar) -le 6) "header: just inside the curve is the band's own colour"
    }
} finally { Close-TestWindowPixels $shot }
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'corners: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# The viewer: the page colour follows the OS scheme (viewer.css), so the
# terminal is set to its opposite and the two cannot be confused.
$lightOs = $true
try {
    $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    $lightOs = ($v -ne 0)
} catch { }
$page = if ($lightOs) { [pscustomobject]@{ R = 255; G = 255; B = 255 } } else { [pscustomobject]@{ R = 13; G = 17; B = 23 } }
$term = if ($lightOs) { '--background=#000000' } else { '--background=#ffffff' }
$termRgb = if ($lightOs) { [pscustomobject]@{ R = 0; G = 0; B = 0 } } else { [pscustomobject]@{ R = 255; G = 255; B = 255 } }
$md = Join-Path $env:TEMP "ghoztty-pane-elevation-$PID.md"
Set-Content -Path $md -Value "# Corner probe`n`nA page." -Encoding Ascii
$vArgs = @('--config-default-files=false', $term, '--unfocused-split-opacity=1',
    '--session-persistence=false', '--macos-pane-glass=false')
$g = Start-Gui 'viewer' $vArgs
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$i = Get-InsetPx $g.Scale
& $exe +split --direction=right "--view=$md" | Out-Null
$vw = $null
for ($t = 0; $t -lt 40 -and $null -eq $vw; $t++) {
    Start-Sleep -Milliseconds 250
    $vw = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer' | Where-Object Visible) | Select-Object -First 1
}
Assert ($null -ne $vw) 'viewer: the viewer pane is up'
if ($null -ne $vw) {
    $ok = $false
    $px = $null
    # The page arrives when WebView2 does; the card follows it on the next paint.
    for ($t = 0; $t -lt 40 -and -not $ok; $t++) {
        Start-Sleep -Milliseconds 400
        $shot = Get-TestWindowPixels -Window $top -Sync
        try {
            $px = Get-TestPixel -Shot $shot -X ([int](($vw.Left + $vw.Right) / 2)) -Y ([int]$vw.Bottom + $i - 1)
        } finally { Close-TestWindowPixels $shot }
        # The bottom rim row: the page under half a rim stroke, which the
        # focused card brightens (up to 16%) - near the page, and far from the
        # opposite-coloured terminal.
        if ($null -ne $px) { $ok = ((Get-ColorDistance $px $page) -le 60) -and ((Get-ColorDistance $px $termRgb) -ge 300) }
    }
    if ($null -ne $px) { Write-Host "      viewer card bottom rim ($([int](($vw.Left + $vw.Right) / 2)),$([int]$vw.Bottom + $i - 1)) = $($px.R),$($px.G),$($px.B); page = $($page.R),$($page.G),$($page.B)" }
    Assert $ok "viewer: the card under a viewer is the page's colour, not the terminal's"
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'viewer: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
Remove-Item $md -ErrorAction SilentlyContinue

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $conf -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-elevation -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'PANE ELEVATION ACCEPTANCE'
