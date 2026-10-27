# T2109 acceptance: a pane tucked into a stack shows as a titled strip, the
# strip is named by the pane's banner title (live on +set-banner), and a click
# on the strip brings that pane on show and focuses it.
#
# THE CLAIM. T2108 made a row that cannot fit at 300 DIP a pane show a run and
# TUCK the rest - hidden, with nothing painted where they were. The window now
# paints each tucked pane's strip (`Window.paintStackStrips`, Mac
# `PaneStackTabView`): the pane's own background darkened (Mac's 35% toward
# black at 82% on a dark theme, `pane_stack_strip.stripRgb`) down the card's
# leading edge, with the pane's name along it - the banner's title first
# (`pane_sidebar.paneLabel`, T2085).
#
# Layout: P | (s1 | (s2 | s3)) at 760 DIP wide, the T2108 shape: two on show,
# two tucked.
#
# Claims:
#   D1) every tucked pane's leading edge is painted in the strip colour the
#       default background (#282c34) gives, a band at least 8 DIP wide; its
#       leading corners are the card's rounded curve in the elevated style and
#       square in the flat one, its trailing corner square in both (T2121)
#       T2160: with -Glass (glass panes on, the elevated style) the strip is
#       laid over the tucked card's glass sheet, so the desk tints it: each
#       strip reads the colour the desk beside it predicts, and the opaque
#       colour would not be
#   D7) T2121: hovering a strip lightens its card's scrim - 45% to 20% - so the
#       strip reads the lighter colour, and goes back when the pointer leaves
#   D2) the strip's label follows the banner title: a long `## ...` title set
#       with +set-banner runs further down the strip than a short one
#   D3) a click on a tucked pane's strip brings that pane on show (its window
#       visible), keeps two on show, and focuses it (+list --json)
#   D4) T2120: a strip pressed and dragged over the middle of a card on show
#       does nothing - same tree order, same focus (a press that travelled is
#       not the D3 click)
#   D5) T2120: a strip dropped in a gap between two other items of its row
#       moves the pane there (tree order from +list), same HWND
#   D6) T2120: a strip dropped at the screen's right edge opens a window of
#       its own over the right half of the work area, holding that pane
#   D8) T2282 (Mac 8aedaae61, `aStripWithABannerIsTheSameGlassTopToBottom`),
#       -Glass only: a tucked pane that carries a banner shows no banner card
#       over its strip, and the strip is the same glass where the card would
#       be as further down - each row reads the glass strip the desk beside
#       it predicts. A glass pane's sheet is thinner under its banner card
#       (T2255); left behind on a strip, that patch was a pale rectangle at
#       its top. On Windows the thinned sheet lives only inside the banner's
#       own popup, so it goes wherever the banner goes. The positive control
#       after D3: the same pane brought on show shows its banner popup again,
#       so the class filter can see one.
#
# The elevated leg pins `macos-pane-glass=false` (its default is on), so it
# keeps checking the opaque colour; -Glass is the glass leg (T2160).
#
# -NegativeControl inverts D1 to "the leading edge is NOT the strip colour" -
# the answer before T2109, when nothing was painted there - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-strip.ps1
#   powershell -NoProfile -File test\win32\pane-stack-strip.ps1 -PaneStyle elevated
#   powershell -NoProfile -File test\win32\pane-stack-strip.ps1 -Glass
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [ValidateSet('flat', 'elevated')][string]$PaneStyle = 'flat',
    [switch]$Glass,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-pane-stack-strip-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\HoverCapture.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

# Glass panes exist only in the elevated style (`Window.paneGlass`).
if ($Glass) { $PaneStyle = 'elevated' }
$appArgs = @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle", "--macos-pane-glass=$(([string][bool]$Glass).ToLower())")

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

function Get-Panes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
function Walk-Focused($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal.name }
        return $null
    }
    $l = Walk-Focused $node.left
    if ($null -ne $l) { return $l }
    return Walk-Focused $node.right
}
function Focused-Pane-Name {
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if (-not $tab.selected) { continue }
        return (Walk-Focused $tab.splits)
    }
    return $null
}

# Mac's strip over a pane of background `bg`, as `pane_stack_strip.stripRgb`
# resolves it: 35% toward black (dark theme), laid at 82% over the pane under
# the card's scrim - black at 45%, lightened to 20% while the strip is hovered
# (T2121). Rounded half away from zero, as Zig's @round is.
function Get-ExpectedStrip([int[]]$bg, [switch]$Hovered) {
    $scrim = if ($Hovered) { 0.2 } else { 0.45 }
    $aw = [MidpointRounding]::AwayFromZero
    return @($bg | ForEach-Object {
        $base = [math]::Round($_ * 0.65, $aw)
        $under = [math]::Round($_ * (1 - $scrim), $aw)
        [int][math]::Round($under * 0.18 + $base * 0.82, $aw)
    })
}
# T2160: the strip on a glass pane over desk pixel `desk`, as
# `pane_stack_strip.GlassLut` resolves it - the tucked card's sheet, which is
# every pane's since T2281 (`GLASS_TINT` 40% of the background over the desk,
# in linear light, quantised to 4096 steps as `pane_elevation.mixChannel` is;
# T2086's thinner, faded unfocused sheet is gone with Mac 9da9618f8), then
# the scrim and the 82% strip over that. Each channel alone.
function ConvertTo-Linear([double]$c) {
    $c = $c / 255.0
    if ($c -le 0.04045) { return $c / 12.92 }
    return [math]::Pow(($c + 0.055) / 1.055, 2.4)
}
function ConvertTo-Srgb([double]$l) {
    $aw = [MidpointRounding]::AwayFromZero
    # Double literals: [math]::Max(0, $l) binds the Int32 overload and
    # truncates the light to 0.
    $l = [math]::Round([math]::Min(1.0, [math]::Max(0.0, $l)) * 4095, $aw) / 4095
    $c = if ($l -le 0.0031308) { $l * 12.92 } else { 1.055 * [math]::Pow($l, 1 / 2.4) - 0.055 }
    return [int][math]::Round([math]::Min(1.0, [math]::Max(0.0, $c)) * 255, $aw)
}
function Get-ExpectedGlassStrip([int[]]$bg, $desk, [switch]$Hovered) {
    if ($null -eq $desk) { return $null }
    $aw = [MidpointRounding]::AwayFromZero
    $t = 0.4
    $scrim = if ($Hovered) { 0.2 } else { 0.45 }
    $d = @([int]$desk.R, [int]$desk.G, [int]$desk.B)
    $out = @()
    for ($i = 0; $i -lt 3; $i++) {
        $m = ConvertTo-Srgb ((ConvertTo-Linear $d[$i]) * (1 - $t) + (ConvertTo-Linear $bg[$i]) * $t)
        $sheet = $m
        $base = [math]::Round($bg[$i] * 0.65, $aw)
        $under = [math]::Round($sheet * (1 - $scrim), $aw)
        $out += [int][math]::Round($under * 0.18 + $base * 0.82, $aw)
    }
    return $out
}
# The desk beside tucked pane `$p` at row `$y`: in the gap before its strip.
function Get-DeskBeside($shot, $p, [int]$y) {
    return Get-TestPixel -Shot $shot -X ($p.Left - [int][math]::Floor(4 * $script:scale)) -Y $y
}

function Test-Near($c, [int[]]$rgb, [int]$tol = 4) {
    if ($null -eq $c) { return $false }
    return ([math]::Abs($c.R - $rgb[0]) -le $tol -and [math]::Abs($c.G - $rgb[1]) -le $tol -and [math]::Abs($c.B - $rgb[2]) -le $tol)
}

function Get-Shot([IntPtr]$top) { return Get-TestWindowPixels -Window $top -Sync }

# The strip of tucked pane `$p` in `$shot`: its width along a row near the top
# of the card (above where any label is), and the strip colour there. The row
# is read from past the leading corner's curve (`$script:cornerPx`, the card
# radius in the elevated style, T2121), so the desk showing round it is not
# taken for the strip's end.
#
# On glass (T2160) the strip is within a few levels of the desk's dark top,
# so the width is read on a row near the strip's foot instead, where the desk
# beyond it is far off the strip colour; the colour is still the top row's.
function Measure-Strip($shot, $p) {
    $y = $p.Top + 4
    $x0 = $p.Left + $script:cornerPx + 2
    $c0 = Get-TestPixel -Shot $shot -X $x0 -Y $y
    $wy = if ($Glass) { $p.Bottom - $script:cornerPx - 4 } else { $y }
    $cw = Get-TestPixel -Shot $shot -X $x0 -Y $wy
    $w = 0
    if ($null -ne $cw) {
        $rgb = @([int]$cw.R, [int]$cw.G, [int]$cw.B)
        $x = $x0
        while ($x -lt $p.Right -and (Test-Near (Get-TestPixel -Shot $shot -X $x -Y $wy) $rgb 6)) { $x++ }
        $w = $x - $p.Left
    }
    return [pscustomobject]@{ Color = $c0; Width = $w }
}

# The colour of the strip of tucked pane `$p` mid-way down it, beside the
# label (which runs down the strip's middle): the pixel 3 px in from its
# trailing edge.
function Get-StripMid($shot, $p, [int]$width) {
    return Get-TestPixel -Shot $shot -X ($p.Left + $width - 3) -Y ($p.Top + [int](($p.Bottom - $p.Top) / 2))
}
function Format-Rgb($c) {
    if ($null -eq $c) { return 'off-capture' }
    return 'rgb({0},{1},{2})' -f $c.R, $c.G, $c.B
}

# How far down the strip its label runs: the rows (first to last) holding a
# pixel well away from the strip colour, within the strip's band.
function Measure-Ink($shot, $p, [int]$width, [int[]]$strip) {
    $first = -1; $last = -1
    for ($y = $p.Top; $y -lt $p.Bottom; $y++) {
        for ($x = $p.Left + 1; $x -lt ($p.Left + $width - 1); $x++) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            if ($null -eq $c) { continue }
            $d = [math]::Abs($c.R - $strip[0]) + [math]::Abs($c.G - $strip[1]) + [math]::Abs($c.B - $strip[2])
            if ($d -gt 90) {
                if ($first -lt 0) { $first = $y }
                $last = $y
                break
            }
        }
    }
    if ($first -lt 0) { return 0 }
    return $last - $first + 1
}

# The row's items as a strip drag sees them (T2120, `Window.bladeGeometry`),
# in tree order: a pane on show is its card, a tucked one its strip. Lead and
# Trail are the item's left and right edges, in screen pixels.
function Get-StripRow([IntPtr]$top, $nameOf) {
    $panes = @(Get-Panes $top)
    $shot = Get-Shot $top
    try {
        $order = Get-LeafOrder
        $out = @()
        foreach ($n in $order) {
            $p = @($panes | Where-Object { $nameOf[$_.Hwnd] -eq $n })[0]
            if ($null -eq $p) { continue }
            $w = if ($p.Visible) { $p.Right - $p.Left } else { (Measure-Strip $shot $p).Width }
            $out += [pscustomobject]@{
                Name = $n; Hwnd = $p.Hwnd; Visible = $p.Visible
                Left = $p.Left; Top = $p.Top; Right = $p.Right; Bottom = $p.Bottom
                StripW = $w; Lead = $p.Left; Trail = $p.Left + $w
            }
        }
        return $out
    } finally { Close-TestWindowPixels -Shot $shot }
}

# The selected tab's panes in tree order, by name ('P' for the first one).
function Get-LeafOrder {
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if (-not $tab.selected) { continue }
        $acc = New-Object System.Collections.ArrayList
        Add-Leaves $tab.splits $acc
        return @($acc)
    }
    return @()
}
function Add-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') {
        # The first pane was never named, so +list names it by its id.
        $n = [string]$node.terminal.name
        [void]$acc.Add($(if ($n -in @('s1', 's2', 's3')) { $n } else { 'P' }))
        return
    }
    Add-Leaves $node.left $acc
    Add-Leaves $node.right $acc
}

# Press at (x0, y0), travel in steps to (x1, y1), release there.
function Drag-Strip([IntPtr]$top, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y0 -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 120
    for ($s = 1; $s -le 8; $s++) {
        $x = [int]($x0 + ($x1 - $x0) * $s / 8)
        $y = [int]($y0 + ($y1 - $y0) * $s / 8)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 150
    [void](Send-TestMouse -Window $top -Target $top -X $x1 -Y $y1 -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 900
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackstrip$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: D1 is inverted to "the leading edge is NOT the strip colour" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at $rowDip DIP ---------------------------
    # T2295: re-derived from the 225 DIP pane minimum (T2284, Mac afc64dc53) -
    # two cards and two strips fit, three cards (675 DIP) do not. At the old
    # 900 three fit and nothing tucked.
    $rowDip = 760
    Say "== setup: P | (s1 | (s2 | s3)), $rowDip DIP wide"
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    # Two DPI readings in a row must agree (pane-stack-grid.ps1's reason).
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $script:scale = $dpi / 96.0
    # The strip's leading-corner radius: the card's 11 DIP in the elevated
    # style (`pane_elevation.radiusPx`), square in the flat one.
    $script:cornerPx = if ($PaneStyle -eq 'elevated') { [int][math]::Round(11 * $script:scale, [MidpointRounding]::AwayFromZero) } else { 0 }
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show (got $($c4.Count))" }
    # Tree order is left to right, and a tucked card keeps its slot's place.
    $names = @($null, 's1', 's2', 's3')
    # Off the screen's edges: a strip dragged within 12 DIP of one tiles to it
    # (D6), which D4 and D5 must not do by accident.
    [void](Set-TestWindowPos -Window $top -X 200 -Y 60 -Width (Get-TestChromeDip -Dip $rowDip -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Milliseconds 800
    $shown = @(Wait-Shown $top 2)
    Start-Sleep -Milliseconds 600
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; panes: {1}" -f $dpi, (Format-Cols $all))
    if ($shown.Count -ne 2 -or $all.Count -ne 4) { Write-TestAssertedNothing -Reason "the $rowDip DIP row never settled on two on show of four (got $($shown.Count) of $($all.Count))" }
    $tucked = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if (-not $all[$i].Visible) { $tucked += [pscustomobject]@{ Pane = $all[$i]; Name = $names[$i] } }
    }

    # ---- D1: every tucked pane shows its strip ---------------------------------
    Say '== D1: strips painted'
    $expected = Get-ExpectedStrip @(0x28, 0x2c, 0x34)
    $minW = [int][math]::Floor(8 * $script:scale)
    $shot = Get-Shot $top
    $strips = @{}
    try {
        foreach ($t in $tucked) {
            $m = Measure-Strip $shot $t.Pane
            $strips[$t.Pane.Hwnd] = $m
            $got = if ($m.Color) { 'rgb({0},{1},{2})' -f $m.Color.R, $m.Color.G, $m.Color.B } else { 'off-capture' }
            $isStrip = Test-Near $m.Color $expected
            # The colour this strip should read: on glass, its own (T2160).
            $ref = $expected
            if ($Glass -and -not $NegativeControl) {
                # T2160: over the sheet, so the desk beside it predicts it.
                $deskAt = Get-DeskBeside $shot $t.Pane ($t.Pane.Top + 4)
                $glassExp = Get-ExpectedGlassStrip @(0x28, 0x2c, 0x34) $deskAt
                $apart = if ($glassExp) { [math]::Abs($glassExp[0] - $expected[0]) + [math]::Abs($glassExp[1] - $expected[1]) + [math]::Abs($glassExp[2] - $expected[2]) } else { 0 }
                Say ("      glass: desk beside {0} -> expected rgb({1}); opaque would be rgb({2}), {3} levels apart" -f (Format-Rgb $deskAt), ($glassExp -join ','), ($expected -join ','), $apart)
                Assert (Test-Near $m.Color $glassExp 1) ("D1: on glass the tucked pane at x={0} shows the strip over the sheet, rgb({1}) (got {2})" -f $t.Pane.Left, ($glassExp -join ','), $got)
                # The check can tell glass from opaque only where they differ.
                Assert ($apart -ge 4) "D1: the desk there puts the glass strip $apart levels from the opaque one (at least 4, or the check above proves nothing)"
                Assert (-not (Test-Near $m.Color $expected 1)) "D1: and it is not the opaque strip rgb($($expected -join ',')) ($got)"
                if ($glassExp) { $ref = $glassExp }
            } elseif ($NegativeControl) {
                Assert (-not $isStrip) "NEGATIVE: tucked pane at x=$($t.Pane.Left) is NOT the strip colour ($got)"
            } else {
                Assert $isStrip ("D1: tucked pane at x={0} shows the strip colour rgb({1}) (got {2})" -f $t.Pane.Left, ($expected -join ','), $got)
            }
            Assert ($m.Width -ge $minW) "D1: its strip is at least 8 DIP wide ($($m.Width) px, floor $minW px)"
            if ($NegativeControl) { continue }
            # T2121: the leading corners are the card's curve in the elevated
            # style - the desk shows at the very corner - and square in the
            # flat one; the trailing corner is square in both.
            $lead = Get-TestPixel -Shot $shot -X ($t.Pane.Left + 1) -Y ($t.Pane.Top + 1)
            $leadLow = Get-TestPixel -Shot $shot -X ($t.Pane.Left + 1) -Y ($t.Pane.Bottom - 2)
            $trail = Get-TestPixel -Shot $shot -X ($t.Pane.Left + $m.Width - 2) -Y ($t.Pane.Top + 1)
            if ($PaneStyle -eq 'elevated') {
                # Nearer the desk in the gap beside the strip than the strip:
                # the desk's dark top is only a few levels off the strip, so a
                # bare "not the strip colour" would be a coin toss there.
                $gapX = $t.Pane.Left - [int][math]::Floor(4 * $script:scale)
                $deskTop = Get-TestPixel -Shot $shot -X $gapX -Y ($t.Pane.Top + 1)
                $deskLow = Get-TestPixel -Shot $shot -X $gapX -Y ($t.Pane.Bottom - 2)
                $nearDesk = {
                    param($c, $desk)
                    if ($null -eq $c -or $null -eq $desk) { return $false }
                    $dd = [math]::Abs($c.R - $desk.R) + [math]::Abs($c.G - $desk.G) + [math]::Abs($c.B - $desk.B)
                    $ds = [math]::Abs($c.R - $ref[0]) + [math]::Abs($c.G - $ref[1]) + [math]::Abs($c.B - $ref[2])
                    return ($dd -lt $ds)
                }
                Assert ((& $nearDesk $lead $deskTop) -and (& $nearDesk $leadLow $deskLow)) ("D1: its leading corners are rounded - the desk shows there (top {0} vs desk {1}, bottom {2} vs desk {3})" -f (Format-Rgb $lead), (Format-Rgb $deskTop), (Format-Rgb $leadLow), (Format-Rgb $deskLow))
            } else {
                Assert ((Test-Near $lead $expected) -and (Test-Near $leadLow $expected)) ("D1: its leading corners are square in the flat style (top {0}, bottom {1})" -f (Format-Rgb $lead), (Format-Rgb $leadLow))
            }
            Assert (Test-Near $trail $ref $(if ($Glass) { 1 } else { 4 })) "D1: its trailing corner is square ($(Format-Rgb $trail) vs rgb($($ref -join ',')))"
        }
    } finally { Close-TestWindowPixels -Shot $shot }

    # ---- D7: hovering a strip lightens its card's scrim (T2121) ----------------
    if (-not $NegativeControl) {
        Say '== D7: strip hover'
        $h = $tucked[0]
        $hw = $strips[$h.Pane.Hwnd].Width
        $hoverExp = Get-ExpectedStrip @(0x28, 0x2c, 0x34) -Hovered
        $restExp = $expected
        $tol = 1
        $shot = Get-Shot $top
        try {
            $rest = Get-StripMid $shot $h.Pane $hw
            if ($Glass) {
                # T2160: both read over the sheet on the desk at that row.
                $deskMid = Get-DeskBeside $shot $h.Pane ($h.Pane.Top + [int](($h.Pane.Bottom - $h.Pane.Top) / 2))
                $restExp = Get-ExpectedGlassStrip @(0x28, 0x2c, 0x34) $deskMid
                $hoverExp = Get-ExpectedGlassStrip @(0x28, 0x2c, 0x34) $deskMid -Hovered
                # Read straight off the desk beside it, so as tight as the
                # opaque check: 2 would already admit the opaque strip.
                $tol = 1
            }
        } finally { Close-TestWindowPixels -Shot $shot }
        # A posted move cannot be photographed hovered off the input desktop
        # (the leave drains before the paint); `capture-hover` moves, paints
        # and photographs on one stack (T282).
        $my = $h.Pane.Top + [int](($h.Pane.Bottom - $h.Pane.Top) / 2)
        $hot = Get-TestHoverCapture -Hwnd $top -X ($h.Pane.Left + [int]($hw / 2)) -Y ($h.Pane.Top + [int](($h.Pane.Bottom - $h.Pane.Top) / 3))
        $lit = $null
        if ($hot) {
            $lit = $hot.Bitmap.GetPixel($h.Pane.Left + $hw - 3 - $hot.Left, $my - $hot.Top)
            Close-TestHoverCapture $hot
        }
        # Off every strip: over the first pane on show.
        $away = @($all | Where-Object Visible)[0]
        $cold = Get-TestHoverCapture -Hwnd $top -X ($away.Left + [int](($away.Right - $away.Left) / 2)) -Y ($away.Top + [int](($away.Bottom - $away.Top) / 2))
        $back = $null
        if ($cold) {
            $back = $cold.Bitmap.GetPixel($h.Pane.Left + $hw - 3 - $cold.Left, $my - $cold.Top)
            Close-TestHoverCapture $cold
        }
        if ($Glass) { Say ("      glass: desk beside the strip's middle {0}" -f (Format-Rgb $deskMid)) }
        Say ("      at rest {0}, hovered {1} (changed={5}), elsewhere {2}; expected rgb({3}) -> rgb({4}) {6}" -f (Format-Rgb $rest), (Format-Rgb $lit), (Format-Rgb $back), ($restExp -join ','), ($hoverExp -join ','), $(if ($hot) { $hot.Changed }), (Get-LastHoverCaptureError))
        Assert ($null -ne $hot -and $hot.Changed) "D7: hovering the strip changes the frame (changed=$(if ($hot) { $hot.Changed }))"
        Assert (Test-Near $rest $restExp $tol) "D7: at rest the strip is rgb($($restExp -join ',')) ($(Format-Rgb $rest))"
        Assert (Test-Near $lit $hoverExp $tol) "D7: hovered, it lightens to rgb($($hoverExp -join ',')) with its scrim ($(Format-Rgb $lit))"
        Assert ($null -ne $lit -and $null -ne $rest -and ($lit.R + $lit.G + $lit.B) -gt ($rest.R + $rest.G + $rest.B)) 'D7: the hovered strip is lighter than at rest'
        Assert (Test-Near $back $restExp $tol) "D7: hovering a pane on show leaves the strip at rest ($(Format-Rgb $back))"
    }

    # ---- D2: the label follows the banner title --------------------------------
    Say '== D2: strip label from +set-banner'
    $named = @($tucked | Where-Object Name)
    if ($named.Count -eq 0) { Write-TestAssertedNothing -Reason 'no named pane was tucked' }
    $t = $named[0]
    $sw = $strips[$t.Pane.Hwnd].Width
    & $exe +set-banner --target=$($t.Name) '## Ab' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $shot = Get-Shot $top
    try { $shortInk = Measure-Ink $shot $t.Pane $sw $expected } finally { Close-TestWindowPixels -Shot $shot }
    & $exe +set-banner --target=$($t.Name) '## Abcdefghijklmnopqrstuvwxyz banner title' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $shot = Get-Shot $top
    try { $longInk = Measure-Ink $shot $t.Pane $sw $expected } finally { Close-TestWindowPixels -Shot $shot }
    Say "      $($t.Name): ink runs $shortInk px for '## Ab', $longInk px for the long title"
    Assert ($shortInk -gt 0) "D2: the short banner title is drawn on $($t.Name)'s strip ($shortInk px)"
    Assert ($longInk -gt ($shortInk + (Get-TestChromeDip -Dip 40 -Scale $script:scale))) "D2: the long banner title runs further down the strip ($longInk px vs $shortInk px)"

    # ---- D8: a strip with a banner is the same glass top to bottom (T2282) -----
    if ($Glass -and -not $NegativeControl) {
        Say '== D8: a tucked pane with a banner'
        $p8 = $t.Pane
        $cards = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyBannerOverlay' | Where-Object {
                $_.Right -gt $p8.Left -and $_.Left -lt ($p8.Left + $sw) -and $_.Bottom -gt $p8.Top -and $_.Top -lt $p8.Bottom })
        Assert ($cards.Count -eq 0) "D8: no banner card is on show over $($t.Name)'s strip ($($cards.Count))"
        # Mac's two rows, 30 and 150 points below the strip's top - where the
        # card sat, and well clear of it - read beside the label, and held to
        # each other as Mac's are: the strip may change down its length only
        # as much as the desk beside it does. A card or its thinned sheet
        # left on the strip is what moves the top row on its own.
        $x8 = $p8.Left + $sw - 3
        $shot = Get-Shot $top
        try {
            $rows8 = foreach ($dip in 30, 150) {
                $y8 = $p8.Top + (Get-TestChromeDip -Dip $dip -Scale $script:scale)
                [pscustomobject]@{ Dip = $dip; Got = (Get-TestPixel -Shot $shot -X $x8 -Y $y8); Desk = (Get-DeskBeside $shot $p8 $y8) }
            }
        } finally { Close-TestWindowPixels -Shot $shot }
        $a8 = $rows8[0]; $b8 = $rows8[1]
        Say ("      30 DIP down {0} (desk beside {1}); 150 DIP down {2} (desk beside {3})" -f (Format-Rgb $a8.Got), (Format-Rgb $a8.Desk), (Format-Rgb $b8.Got), (Format-Rgb $b8.Desk))
        $same8 = $false
        if ($a8.Got -and $b8.Got -and $a8.Desk -and $b8.Desk) {
            $same8 = $true
            foreach ($ch in 'R', 'G', 'B') {
                $ds = [math]::Abs([int]$a8.Got.$ch - [int]$b8.Got.$ch)
                $dd = [math]::Abs([int]$a8.Desk.$ch - [int]$b8.Desk.$ch)
                if ($ds -gt ($dd + 2)) { $same8 = $false }
            }
        }
        Assert $same8 ("D8: $($t.Name)'s strip is the same glass where its banner card was as 150 DIP down ({0} vs {1})" -f (Format-Rgb $a8.Got), (Format-Rgb $b8.Got))
    }

    # ---- D3: a click on the strip brings the pane on show ----------------------
    Say '== D3: strip click'
    $p = $t.Pane
    $sx = $p.Left + [int]($sw / 2)
    $sy = $p.Top + [int](($p.Bottom - $p.Top) / 2)
    [void](Send-TestMouse -Window $top -X $sx -Y $sy)
    Start-Sleep -Milliseconds 900
    $after = @(Get-Panes $top)
    Say ("      panes: {0}" -f (Format-Cols $after))
    $me = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })
    Assert ($me.Count -eq 1 -and $me[0].Visible) "D3: the clicked pane ($($t.Name)) is on show"
    Assert (@($after | Where-Object Visible).Count -eq 2) "D3: still two on show ($(@($after | Where-Object Visible).Count))"
    $focused = Focused-Pane-Name
    Assert ($focused -eq $t.Name) "D3: the clicked pane has focus (+list says '$focused')"
    if ($Glass -and -not $NegativeControl) {
        # D8's positive control: on show, the pane's banner card is back.
        $mine = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })[0]
        $cards = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyBannerOverlay' | Where-Object {
                $mine -and $_.Right -gt $mine.Left -and $_.Left -lt $mine.Right -and $_.Bottom -gt ($mine.Top - $_.Height) -and $_.Top -lt $mine.Bottom })
        Assert ($cards.Count -eq 1) "D8: brought on show, $($t.Name)'s banner card is on show again ($($cards.Count)) - the D8 probe can see one"
        # And D8's two-row comparison tells a banner from none: the same two
        # rows down this card, from the top of its banner band, differ.
        if ($cards.Count -eq 1) {
            $c8 = $cards[0]
            $shot = Get-Shot $top
            try {
                $hi = Get-TestPixel -Shot $shot -X ($c8.Left + $sw - 3) -Y ($c8.Top + (Get-TestChromeDip -Dip 30 -Scale $script:scale))
                $lo = Get-TestPixel -Shot $shot -X ($c8.Left + $sw - 3) -Y ($c8.Top + (Get-TestChromeDip -Dip 150 -Scale $script:scale))
            } finally { Close-TestWindowPixels -Shot $shot }
            $apart8 = if ($hi -and $lo) { [math]::Abs($hi.R - $lo.R) + [math]::Abs($hi.G - $lo.G) + [math]::Abs($hi.B - $lo.B) } else { 0 }
            Assert ($apart8 -gt 6) ("D8: with its banner on show the two rows differ ({0} vs {1}, {2} levels) - the comparison can see a card" -f (Format-Rgb $hi), (Format-Rgb $lo), $apart8)
        }
    }

    # ---- D4-D6: a strip is a drag source (T2120) -------------------------------
    # Every pane keeps its HWND across a rearrange, so the HWND names it; the
    # tree order is read back from +list.
    $nameOf = @{}
    for ($i = 0; $i -lt $all.Count; $i++) { $nameOf[$all[$i].Hwnd] = if ($names[$i]) { $names[$i] } else { 'P' } }
    $rows = Get-StripRow $top $nameOf
    $d = @($rows | Where-Object { -not $_.Visible })[0]
    if ($null -eq $d) { Write-TestAssertedNothing -Reason 'no pane was tucked after D3' }
    $order0 = Get-LeafOrder
    $focus0 = Focused-Pane-Name
    $midY = $d.Top + [int](($d.Bottom - $d.Top) / 2)
    $px = $d.Left + [int]($d.StripW / 2)
    Say ("      row: {0}; dragging {1}'s strip; tree {2}" -f (($rows | ForEach-Object { "$($_.Name)[$($_.Lead)-$($_.Trail)]" }) -join ' '), $d.Name, ($order0 -join ','))

    Say '== D4: a strip dropped over the middle of a card does nothing'
    $card = @($rows | Where-Object Visible)[0]
    Drag-Strip $top $px $midY ($card.Left + [int](($card.Right - $card.Left) / 2)) $midY
    $order4 = Get-LeafOrder
    Assert (($order4 -join ',') -eq ($order0 -join ',')) "D4: the tree order is unchanged ($($order4 -join ','))"
    Assert (@(Get-Panes $top).Count -eq 4) "D4: still four panes ($(@(Get-Panes $top).Count))"
    $focus4 = Focused-Pane-Name
    Assert ($focus4 -eq $focus0) "D4: a press that travelled is not a click - focus stays on '$focus0' ('$focus4')"

    Say '== D5: a strip dropped in a gap of its row moves there'
    # The slots are the gaps between the OTHER items, plus the two ends; the
    # one where the strip already is changes nothing. Take an inner gap that
    # is not that one.
    $others = @($rows | Where-Object { $_.Hwnd -ne $d.Hwnd })
    $own = [array]::IndexOf(@($rows | ForEach-Object { $_.Hwnd }), $d.Hwnd)
    $k = if ($own -ne 1) { 1 } else { 2 }
    $gapX = [int](($others[$k - 1].Left + $others[$k - 1].StripW + $others[$k].Left) / 2)
    $expect = @($others[0..($k - 1)] | ForEach-Object { $_.Name }) + @($d.Name) + @($others[$k..($others.Count - 1)] | ForEach-Object { $_.Name })
    Say ("      drop at x={0} (between {1} and {2}); expect {3}" -f $gapX, $others[$k - 1].Name, $others[$k].Name, ($expect -join ','))
    Drag-Strip $top $px $midY $gapX $midY
    $order5 = Get-LeafOrder
    Assert (($order5 -join ',') -eq ($expect -join ',')) "D5: $($d.Name) moved between $($others[$k - 1].Name) and $($others[$k].Name) (tree $($order5 -join ','))"
    $after5 = @(Get-Panes $top)
    Assert ($after5.Count -eq 4 -and @($after5 | Where-Object { $_.Hwnd -eq $d.Hwnd }).Count -eq 1) "D5: the same four panes, $($d.Name) still its own window ($($after5.Count))"

    Say '== D6: a strip dropped at a screen edge tiles a window of its own'
    $rows = Get-StripRow $top $nameOf
    $d = @($rows | Where-Object { -not $_.Visible })[0]
    if ($null -eq $d) { Write-TestAssertedNothing -Reason 'no pane was tucked after D5' }
    $wa = Get-TestWorkArea
    $midY = $d.Top + [int](($d.Bottom - $d.Top) / 2)
    Drag-Strip $top ($d.Left + [int]($d.StripW / 2)) $midY ($wa.Right - 3) $midY
    $deadline = (Get-Date).AddSeconds(8)
    do {
        $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')
        if ($tops.Count -ge 2) { break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    Assert ($tops.Count -eq 2) "D6: a second window opened ($($tops.Count))"
    $new = @($tops | Where-Object { $_.Hwnd -ne [int64]$top })[0]
    if ($new) {
        $half = $wa.Left + [int]($wa.Width / 2)
        Say ("      new window {0}-{1}; work area {2}-{3}" -f $new.Left, $new.Right, $wa.Left, $wa.Right)
        $tol = Get-TestChromeDip -Dip 12 -Scale $script:scale
        Assert ([math]::Abs($new.Left - $half) -le $tol -and [math]::Abs($new.Right - $wa.Right) -le $tol) "D6: it covers the right half of the screen ($($new.Left)-$($new.Right) vs $half-$($wa.Right))"
        $moved = @(Get-TestChildWindows -Window ([IntPtr]$new.Hwnd) -Class 'GhozttyTerminal')
        Assert ($moved.Count -eq 1 -and $moved[0].Hwnd -eq $d.Hwnd) "D6: it holds the dragged pane $($d.Name), the same window ($($moved.Count))"
        Assert (@(Get-Panes $top).Count -eq 3) "D6: three panes stay behind ($(@(Get-Panes $top).Count))"
    }

    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl -and $PaneStyle -eq 'flat') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-stack-strip -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2109 PANE STACK STRIP' -Pass $script:pass -Fail $script:fail
