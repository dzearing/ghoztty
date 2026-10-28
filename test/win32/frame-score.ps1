<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameScore.ps1 (T2381) - the scoring half
  of the T2373 frame lab.

.DESCRIPTION
  The lab exists because the resize harnesses judge what the app SAYS it drew;
  this scorer judges what a captured frame SHOWS. A scorer that misses a planted
  defect would make every later lab run a green lie, so each bleed class and
  each motion metric is proved here on synthetic frames, with a planted defect
  it must catch AND a clean or legitimately-messy case it must not flag:

    A. a clean two-pane scene scores nothing, both through a raw frame and
       through a GDI bitmap with anti-aliased glyphs (whose blend pixels are
       shown to really be off-palette, so the blend rule is exercised), and
       rounded corners are excused by the arc mask - the same frame with the
       mask off finds them, so the mask is not a blanket exclusion;
    B. every bleed class B1-B6 is caught when planted, on the pane it was
       planted in and nowhere else (B1 desk patch + one-frame magenta erase,
       B2 stale-small and cut-off content, B3 stretched ring and glyph, B4 a
       divider ahead of its panes, B5 a scrollbar overlay one step behind, B6
       black and noise pixels), and one colour step off the palette is not
       garbage;
    C. the motion metrics read the cases T2373 names: a perfect 120 Hz drag
       (rate 1, no stalls, lag exactly 2 refreshes), ~39 fps (rate ~0.33), a
       planted 3-refresh stall, a planted back-jank (and the negative: a
       lagging edge catching up after the pointer turns is NOT a reversal),
       glide curve deviation, step jitter, timestamp noise, and the targets
       verdict on both sides.

  Pure logic: no exe, no window, no agent. Runs anywhere.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-score.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameScore.ps1')

# ---- the synthetic scene ---------------------------------------------------
# A 400x200 window: two pane cards split by a 10px divider, on a desk. Cells are
# 8x16, so the 1-cell ring is 8px thick on the left/right and 16px top/bottom.
$DESK = 0x203040; $BRUSH = 0x101010; $MAGENTA = 0xFF00FF
$DIV = 0x505050; $SCROLL = 0xC8C8C8
$PANES = @(
    @{ Name = 'left';  Card = @(10, 10, 195, 190);  Bg = 0x2A1F5C; Ring = 0xE0B020; Glyph = 0x40E0D0 },
    @{ Name = 'right'; Card = @(205, 10, 390, 190); Bg = 0x5C1F2A; Ring = 0x20B0E0; Glyph = 0xD0E040 }
)
$RW = 8; $RH = 16; $GW = 40; $GH = 60

function New-Scene([int]$Radius = 0) {
    $s = New-Object FsScene
    $s.Flash = [int[]]@($DESK, $BRUSH, $MAGENTA)
    foreach ($p in $PANES) {
        $r = New-Object FsRegion
        $r.Name = $p.Name
        $r.Card = New-ScoreBox $p.Card[0] $p.Card[1] $p.Card[2] $p.Card[3]
        $r.Bg = $p.Bg; $r.Ring = $p.Ring; $r.Glyph = $p.Glyph
        $r.RingW = $RW; $r.RingH = $RH; $r.GlyphW = $GW; $r.GlyphH = $GH
        $r.Radius = $Radius
        $s.Regions.Add($r)
    }
    return $s
}

# Draw a pane's test card. The CONTENT box is where the app drew the grid,
# which on a good frame is the card itself; -Grow* move its right/bottom edge
# (negative = stale-small, positive = too big and cut off by the card), and the
# uncovered part of the card shows $Under. -RingW/-RingH stretch the ring.
function Add-Card($Frame, $P, [int]$GrowR = 0, [int]$GrowB = 0, [int]$Under = $BRUSH,
                  [int]$RingW = $RW, [int]$RingH = $RH, [int]$GlyphW = $GW, [int]$GlyphH = $GH) {
    $c = $P.Card
    $Frame.Fill((New-ScoreBox $c[0] $c[1] $c[2] $c[3]), $Under)
    $x0 = $c[0]; $y0 = $c[1]; $x1 = $c[2] + $GrowR; $y1 = $c[3] + $GrowB
    # Everything the content draws is clipped to the card, as the HWND clips it.
    $clip = { param($a, $b, $cc, $d, $col)
        $Frame.Fill((New-ScoreBox ([math]::Max($a, $c[0])) ([math]::Max($b, $c[1])) ([math]::Min($cc, $c[2])) ([math]::Min($d, $c[3]))), $col) }
    & $clip $x0 $y0 $x1 $y1 $P.Bg
    & $clip $x0 $y0 $x1 ($y0 + $RingH) $P.Ring
    & $clip $x0 ($y1 - $RingH) $x1 $y1 $P.Ring
    & $clip $x0 $y0 ($x0 + $RingW) $y1 $P.Ring
    & $clip ($x1 - $RingW) $y0 $x1 $y1 $P.Ring
    $gx = [int](($x0 + $x1 - $GlyphW) / 2); $gy = [int](($y0 + $y1 - $GlyphH) / 2)
    & $clip $gx $gy ($gx + $GlyphW) ($gy + $GlyphH) $P.Glyph
}

function New-CleanFrame {
    $f = New-Object FsFrame 400, 200
    $f.Fill((New-ScoreBox 0 0 400 200), $DESK)
    $f.Fill((New-ScoreBox 195 10 205 190), $DIV)
    foreach ($p in $PANES) { Add-Card $f $p }
    return $f
}

function Show($res) { ($res.Findings | ForEach-Object { $_.ToString() }) -join ' | ' }

# Findings of class $Cls, and on which targets.
function Get-Targets($res, $Cls) { @($res.Findings | Where-Object { $_.Cls -eq $Cls } | ForEach-Object { $_.Target } | Sort-Object -Unique) -join ',' }

$bitmaps = @()

try {
    # --- A. a clean scene scores nothing ------------------------------------
    ''
    '-- A. clean frames: nothing found, rings located, anti-alias and corners excused'

    $scene = New-Scene
    $res = Measure-FrameBleed -Frame (New-CleanFrame) -Scene $scene
    Assert 'A1 a clean two-pane frame has no findings' ($res.Findings.Count -eq 0) (Show $res)
    Assert 'A2 both rings are located flush with their cards' `
        ($res.Rings.ContainsKey('left') -and $res.Rings['left'].ToString() -eq '10,10-195,190' -and $res.Rings['right'].ToString() -eq '205,10-390,190') `
        ("left=$($res.Rings['left']) right=$($res.Rings['right'])")

    # The same scene drawn by GDI with an anti-aliased round glyph, read back
    # through ConvertTo-ScoreFrame (the path a capture takes).
    $bmp = New-Object System.Drawing.Bitmap 400, 200, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bitmaps += $bmp
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    function C([int]$rgb) { [System.Drawing.Color]::FromArgb(255, ($rgb -shr 16) -band 255, ($rgb -shr 8) -band 255, $rgb -band 255) }
    $g.Clear((C $DESK))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush (C $DIV)), 195, 10, 10, 180)
    foreach ($p in $PANES) {
        $c = $p.Card; $w = $c[2] - $c[0]; $h = $c[3] - $c[1]
        $g.FillRectangle((New-Object System.Drawing.SolidBrush (C $p.Ring)), $c[0], $c[1], $w, $h)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush (C $p.Bg)), $c[0] + $RW, $c[1] + $RH, $w - 2 * $RW, $h - 2 * $RH)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.FillEllipse((New-Object System.Drawing.SolidBrush (C $p.Glyph)), [single]($c[0] + $w / 2 - 20.3), [single]($c[1] + $h / 2 - 30.3), [single]40.6, [single]60.6)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    }
    $g.Dispose()
    $aa = ConvertTo-ScoreFrame -Bitmap $bmp
    $aaScene = New-Scene; foreach ($r in $aaScene.Regions) { $r.GlyphW = 0 }
    $res = Measure-FrameBleed -Frame $aa -Scene $aaScene
    $offPalette = 0
    foreach ($px in $aa.Px) {
        if ($px -ne $PANES[0].Bg -and $px -ne $PANES[0].Glyph -and $px -ne $PANES[1].Bg -and $px -ne $PANES[1].Glyph -and
            $px -ne $PANES[0].Ring -and $px -ne $PANES[1].Ring -and $px -ne $DESK -and $px -ne $DIV) { $offPalette++ }
    }
    Assert 'A3 the GDI frame really holds anti-alias pixels off every palette colour (so A4 tests the blend rule)' ($offPalette -gt 20) "off-palette=$offPalette"
    Assert 'A4 ...and none of them is scored as garbage or anything else' ($res.Findings.Count -eq 0) (Show $res)

    # Rounded cards: the desk shows in the corners outside the arc.
    $round = New-CleanFrame
    foreach ($p in $PANES) {
        $c = $p.Card
        # Parenthesised: a comma binds tighter than '-' in an array literal.
        foreach ($corner in @(@($c[0], $c[1], 1, 1), @(($c[2] - 1), $c[1], -1, 1), @($c[0], ($c[3] - 1), 1, -1), @(($c[2] - 1), ($c[3] - 1), -1, -1))) {
            for ($i = 0; $i -lt 6; $i++) { for ($j = 0; $j -lt 6 - $i; $j++) {
                $round.Set($corner[0] + $corner[2] * $i, $corner[1] + $corner[3] * $j, $DESK) } }
        }
    }
    $res = Measure-FrameBleed -Frame $round -Scene (New-Scene -Radius 8)
    Assert 'A5 rounded corners (radius 8) showing the desk are excused by the arc mask' ($res.Findings.Count -eq 0) (Show $res)
    $res = Measure-FrameBleed -Frame $round -Scene (New-Scene -Radius 0)
    Assert 'A6 (negative control) the same corners with no mask ARE background flash on both panes' `
        ((Get-Targets $res 'B1') -eq 'left,right') (Show $res)
    # The mask is the arc, not the corner square: desk deep inside the corner
    # square but inside the arc is still caught.
    $deep = New-CleanFrame; $deep.Set(14, 14, $DESK)
    $res = Measure-FrameBleed -Frame $deep -Scene (New-Scene -Radius 8)
    Assert 'A7 a desk pixel inside the corner square but inside the arc is still B1' ((Get-Targets $res 'B1') -eq 'left') (Show $res)

    # --- B. each class caught where it was planted, and only there ---------
    ''
    '-- B. planted defects: each class caught on its own pane'

    $f = New-CleanFrame; $f.Fill((New-ScoreBox 300 100 306 106), $DESK)
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B1a a 6x6 desk patch in the right pane is B1 on the right pane only, 36 px' `
        ($res.Classes() -eq 'B1' -and (Get-Targets $res 'B1') -eq 'right' -and $res.Findings[0].Pixels -eq 36) (Show $res)

    $f = New-CleanFrame; $f.Fill((New-ScoreBox 10 10 195 190), $MAGENTA)
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B1b a one-frame magenta erase of the left pane is B1 there (the T2383 positive-control colour)' `
        ((Get-Targets $res 'B1') -eq 'left' -and -not ((Get-Targets $res 'B1') -match 'right')) (Show $res)

    # Stale small: the grid is 12px narrower than the card; the gap shows the
    # window brush (B1 too) - or, the commoner DWM shape, the pane's own stale bg.
    $f = New-CleanFrame; Add-Card $f $PANES[1] -GrowR -12
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B2a content 12px short of the card, gap showing the brush: B2 (right inset 12) and B1, right pane only' `
        ($res.Classes() -eq 'B1,B2' -and (Get-Targets $res 'B2') -eq 'right' -and (Show $res) -match 'inset 12px from the right') (Show $res)
    $f = New-CleanFrame; Add-Card $f $PANES[1] -GrowR -12 -Under $PANES[1].Bg
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B2b the same gap filled with the pane''s stale background is still B2, with no B1' `
        ($res.Classes() -eq 'B2' -and (Get-Targets $res 'B2') -eq 'right') (Show $res)
    $f = New-CleanFrame; Add-Card $f $PANES[0] -GrowB 20
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B2c content 20px taller than the card (bottom ring cut off) is B2 "missing on the bottom side"' `
        ((Get-Targets $res 'B2') -eq 'left' -and (Show $res) -match 'ring missing on the bottom side') (Show $res)
    $f = New-CleanFrame; Add-Card $f $PANES[1] -GrowR -1
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B2d a 1px inset is inside PosTol and is not B2 (but 2px would be)' ($res.Count('B2') -eq 0) (Show $res)
    $f = New-CleanFrame; Add-Card $f $PANES[1] -GrowR -2
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B2e ...and 2px is' ($res.Count('B2') -ge 1) (Show $res)
    $sl = New-Scene; $sl.Regions[1].Slack = [int[]]@(0, 0, 7, 0)
    $f = New-CleanFrame; Add-Card $f $PANES[1] -GrowR -6 -Under $PANES[1].Bg
    $res = Measure-FrameBleed -Frame $f -Scene $sl
    Assert 'B2f a 6px right inset within a declared 7px cell-remainder slack is not B2' ($res.Count('B2') -eq 0) (Show $res)

    $f = New-CleanFrame; Add-Card $f $PANES[0] -RingW 12 -GlyphW 52
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B3a a ring stretched to 12px and a glyph to 52px wide is B3 on the left pane only' `
        ($res.Classes() -eq 'B3' -and (Get-Targets $res 'B3') -eq 'left' -and (Show $res) -match 'left ring 12px thick' -and (Show $res) -match 'ID glyph 52x60') (Show $res)
    $f = New-CleanFrame; Add-Card $f $PANES[1] -RingH 20
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B3b a vertical-only stretch (top/bottom ring 20px) is B3 on the top and bottom sides' `
        ((Show $res) -match 'top ring 20px' -and (Show $res) -match 'bottom ring 20px' -and -not ((Show $res) -match 'left ring')) (Show $res)

    # B4: the divider's expected rect is derived from the SAME frame's rings -
    # it must fill the gap between the left ring's right edge and the right
    # ring's left edge.
    function Add-Divider($Scene, $Res) {
        $e = New-Object FsElement
        $e.Name = 'divider'; $e.Cls = 'B4'; $e.Color = $DIV
        $e.Search = New-ScoreBox 150 10 250 190
        $e.Expect = New-ScoreBox $Res.Rings['left'].X1 10 $Res.Rings['right'].X0 190
        $Scene.Elements.Add($e)
    }
    $f = New-CleanFrame
    $s4 = New-Scene; Add-Divider $s4 (Measure-FrameBleed -Frame $f -Scene $s4)
    $res = Measure-FrameBleed -Frame $f -Scene $s4
    Assert 'B4a a divider flush between the rings is not a tear' ($res.Findings.Count -eq 0 -and $res.Located['divider'].ToString() -eq '195,10-205,190') (Show $res)
    $f = New-Object FsFrame 400, 200
    $f.Fill((New-ScoreBox 0 0 400 200), $DESK)
    foreach ($p in $PANES) { Add-Card $f $p }
    $f.Fill((New-ScoreBox 199 10 209 190), $DIV)                  # divider a frame ahead: 4px right, over the right card
    $res = Measure-FrameBleed -Frame $f -Scene $s4
    Assert 'B4b a divider drawn 4px ahead of its panes is B4' ((Get-Targets $res 'B4') -eq 'divider' -and (Show $res) -match 'edges off by 4,0,4,0') (Show $res)

    # B5: a scrollbar overlay that belongs on the left pane's right edge.
    function New-ScrollScene { $s = New-Scene; $e = New-Object FsElement
        $e.Name = 'scrollbar'; $e.Cls = 'B5'; $e.Color = $SCROLL
        $e.Search = New-ScoreBox 10 10 195 190; $e.Expect = New-ScoreBox 180 40 186 100
        $s.Regions[0].Extra = [int[]]@($SCROLL); $s.Elements.Add($e); return $s }
    $f = New-CleanFrame; $f.Fill((New-ScoreBox 180 40 186 100), $SCROLL)
    $res = Measure-FrameBleed -Frame $f -Scene (New-ScrollScene)
    Assert 'B5a an overlay on its rect is not lag' ($res.Findings.Count -eq 0) (Show $res)
    $f = New-CleanFrame; $f.Fill((New-ScoreBox 180 50 186 110), $SCROLL)
    $res = Measure-FrameBleed -Frame $f -Scene (New-ScrollScene)
    Assert 'B5b the overlay 10px behind its pane is B5' ((Get-Targets $res 'B5') -eq 'scrollbar' -and $res.Classes() -eq 'B5') (Show $res)
    $res = Measure-FrameBleed -Frame (New-CleanFrame) -Scene (New-ScrollScene)
    Assert 'B5c an overlay missing from its frame is B5 "not found"' ((Show $res) -match 'B5 scrollbar: not found') (Show $res)

    $f = New-CleanFrame; $f.Fill((New-ScoreBox 60 120 64 124), 0x000000)
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B6a a 4x4 black block is garbage, 16 px, left pane only' `
        ($res.Classes() -eq 'B6' -and (Get-Targets $res 'B6') -eq 'left' -and $res.Findings[0].Pixels -eq 16) (Show $res)
    $f = New-CleanFrame; $rng = New-Object System.Random 2381
    for ($i = 0; $i -lt 50; $i++) { $f.Set($rng.Next(230, 360), $rng.Next(40, 160), $rng.Next(0, 0x1000000)) }
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B6b 50 random noise pixels in the right pane are caught as garbage (most of them)' `
        ((Get-Targets $res 'B6') -eq 'right' -and ($res.Findings | Where-Object Cls -eq 'B6')[0].Pixels -ge 40) (Show $res)
    $f = New-CleanFrame; $f.Fill((New-ScoreBox 60 120 64 124), $PANES[0].Bg + 0x010101)
    $res = Measure-FrameBleed -Frame $f -Scene $scene
    Assert 'B6c one colour step off the background is inside Tol and not garbage' ($res.Findings.Count -eq 0) (Show $res)

    # --- C. motion metrics ---------------------------------------------------
    ''
    '-- C. motion: advance rate, stalls, lag, reversals, curve, jitter, targets'

    $P = 1000.0 / 120
    # A pointer moving 5px per refresh for 60 refreshes; the edge shows the
    # pointer's position exactly 2 refreshes late, one frame per refresh.
    function New-Drag([int]$Slots = 60, [double]$Speed = 5, [int]$LagSlots = 2) {
        $pt = @(); $pp = @()
        for ($k = 0; $k -le $Slots; $k++) { $pt += $k * $P; $pp += 100 + $Speed * $k }
        $t = @(); $x = @()
        for ($k = 0; $k -le $Slots + $LagSlots; $k++) {
            $t += $k * $P; $x += 100 + $Speed * [math]::Max(0, [math]::Min($Slots, $k - $LagSlots))
        }
        return @{ PT = [double[]]$pt; PP = [double[]]$pp; T = [double[]]$t; X = [double[]]$x; End = ($Slots + $LagSlots) * $P }
    }

    $d = New-Drag
    $m = Measure-FrameMotion -Time $d.T -Position $d.X -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    "  perfect: $m"
    Assert 'C1 a perfect 120 Hz drag: every due refresh advanced, no stalls, no reversals, step 5 +- 0' `
        ($m.AdvanceRate -eq 1 -and $m.LongestStall -eq 0 -and $m.Stalls -eq 0 -and $m.Reversals -eq 0 -and $m.StepStd -eq 0 -and $m.StepMean -eq 5) "$m"
    Assert 'C2 ...and its input-to-photon lag reads exactly the planted 2 refreshes (p50 and p95)' `
        ([math]::Abs($m.LagP50 - 2) -lt 0.01 -and [math]::Abs($m.LagP95 - 2) -lt 0.01) "$m"
    $miss = Test-FrameMotionTargets -Motion $m
    Assert 'C3 the perfect drag meets every T2373 target' ($miss.Count -eq 0) ($miss -join '; ')

    # ~39 fps: a frame lands only on every third refresh (the T2365 baseline).
    $keep = @(); for ($i = 0; $i -lt $d.T.Count; $i++) { if ($i % 3 -eq 0) { $keep += $i } }
    $m39 = Measure-FrameMotion -Time ($keep | ForEach-Object { $d.T[$_] }) -Position ($keep | ForEach-Object { $d.X[$_] }) `
        -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    "  40 fps: $m39"
    Assert 'C4 a 40 fps drag on 120 Hz reads an advance rate of about a third' ($m39.AdvanceRate -gt 0.30 -and $m39.AdvanceRate -lt 0.37) "$m39"
    Assert 'C5 ...with a stall of 2 refreshes between every frame' ($m39.LongestStall -eq 2 -and $m39.Stalls -ge 15) "$m39"
    $miss = Test-FrameMotionTargets -Motion $m39
    Assert 'C6 ...and the targets verdict names both misses' `
        ($miss.Count -ge 2 -and ($miss -join ';') -match 'advance rate' -and ($miss -join ';') -match 'longest stall 2') ($miss -join '; ')

    # A planted 3-refresh stall: frames 20, 21, 22 never arrive.
    $keep = @(0..($d.T.Count - 1) | Where-Object { $_ -lt 20 -or $_ -gt 22 })
    $ms = Measure-FrameMotion -Time ($keep | ForEach-Object { $d.T[$_] }) -Position ($keep | ForEach-Object { $d.X[$_] }) `
        -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    "  stall: $ms"
    Assert 'C7 a planted 3-refresh stall reads longest=3, stalls=1, and the catch-up step as jitter (max 20px)' `
        ($ms.LongestStall -eq 3 -and $ms.Stalls -eq 1 -and $ms.StepMax -eq 20 -and $ms.StepStd -gt 0) "$ms"

    # A planted back-jank: one frame shows the edge 4px BEHIND the previous one.
    $xj = [double[]]$d.X.Clone(); $xj[30] = $xj[29] - 4
    $mj = Measure-FrameMotion -Time $d.T -Position $xj -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    Assert 'C8 one frame drawn 4px back while the pointer moves forward is a reversal' ($mj.Reversals -eq 1) "$mj"
    Assert 'C9 ...with no pointer at all, the overall direction still catches it' `
        ((Measure-FrameMotion -Time $d.T -Position $xj -PeriodMs $P -Start 0 -End $d.End).Reversals -eq 1) ''

    # Negative control for reversals: back-and-forth pointer, edge 3 refreshes
    # late. After the pointer turns the edge keeps going the old way briefly -
    # toward where the pointer WAS, which is still toward the pointer - and that
    # must not read as a jank.
    $pt = @(); $pp = @()
    for ($k = 0; $k -le 80; $k++) { $pt += $k * $P; $pp += 100 + 5 * $(if ($k -le 40) { $k } else { 80 - $k }) }
    $t = @(); $x = @()
    for ($k = 0; $k -le 83; $k++) { $t += $k * $P; $j = [math]::Max(0, [math]::Min(80, $k - 3)); $x += 100 + 5 * $(if ($j -le 40) { $j } else { 80 - $j }) }
    $mb = Measure-FrameMotion -Time ([double[]]$t) -Position ([double[]]$x) -PeriodMs $P -Start 0 -End (83 * $P) -PointerTime ([double[]]$pt) -PointerPosition ([double[]]$pp)
    "  back-and-forth: $mb"
    Assert 'C10 (negative control) a lagging edge following a back-and-forth pointer has 0 reversals' ($mb.Reversals -eq 0) "$mb"
    Assert 'C11 ...and its lag still reads the planted 3 refreshes' ([math]::Abs($mb.LagP95 - 3) -lt 0.01) "$mb"

    # Glide curve: an ease-out over 30 refreshes, compared at display time.
    $t = @(); $x = @(); $e = @()
    for ($k = 0; $k -le 30; $k++) { $u = $k / 30; $v = 200 * (1 - [math]::Pow(1 - $u, 3)); $t += $k * $P; $x += $v; $e += $v }
    $mc = Measure-FrameMotion -Time ([double[]]$t) -Position ([double[]]$x) -PeriodMs $P -Start 0 -End (30 * $P) -Expected ([double[]]$e)
    $x2 = [double[]]$x; $x2[10] += 3
    $mc2 = Measure-FrameMotion -Time ([double[]]$t) -Position $x2 -PeriodMs $P -Start 0 -End (30 * $P) -Expected ([double[]]$e)
    Assert 'C12 a glide on its ease curve deviates 0px; one frame 3px off reads 3px' ($mc.MaxCurveDev -eq 0 -and [math]::Abs($mc2.MaxCurveDev - 3) -lt 1e-9) "$mc | $mc2"

    # Jitter: alternating 3px / 7px steps average 5 with a spread of 2.
    $t = @(); $x = @(); $acc = 100
    for ($k = 0; $k -le 40; $k++) { $t += $k * $P; $x += $acc; $acc += $(if ($k % 2) { 3 } else { 7 }) }
    $mt = Measure-FrameMotion -Time ([double[]]$t) -Position ([double[]]$x) -PeriodMs $P -Start 0 -End (40 * $P)
    Assert 'C13 alternating 3/7px steps read mean 5, std 2, range 3..7' `
        ($mt.StepMean -eq 5 -and [math]::Abs($mt.StepStd - 2) -lt 1e-9 -and $mt.StepMin -eq 3 -and $mt.StepMax -eq 7) "$mt"

    # Capture timestamps carry jitter (QPC vs vblank); +-1.5ms must still map
    # each frame to its own refresh.
    $rng = New-Object System.Random 2373
    $tn = [double[]]($d.T | ForEach-Object { $_ + ($rng.NextDouble() * 3 - 1.5) })
    $mn = Measure-FrameMotion -Time $tn -Position $d.X -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    Assert 'C14 +-1.5ms timestamp noise still reads a perfect drag as rate 1, no stalls' ($mn.AdvanceRate -eq 1 -and $mn.LongestStall -eq 0) "$mn"

    # Unlocated frames (edge not found) are counted, never silently dropped.
    $xu = [double[]]$d.X.Clone(); $xu[5] = [double]::NaN; $xu[6] = [double]::NaN
    $mu = Measure-FrameMotion -Time $d.T -Position $xu -PeriodMs $P -Start 0 -End $d.End -PointerTime $d.PT -PointerPosition $d.PP
    Assert 'C15 two frames whose edge was not located are counted (unlocated=2) and read as a 2-refresh stall' `
        ($mu.Unlocated -eq 2 -and $mu.LongestStall -eq 2) "$mu"

    # A pointer that pauses mid-drag makes no refreshes due while the edge has
    # caught up, so the pause is not a stall.
    $pt = @(); $pp = @()
    for ($k = 0; $k -le 60; $k++) { $pt += $k * $P; $pp += 100 + 5 * $(if ($k -lt 20) { $k } elseif ($k -lt 40) { 20 } else { $k - 20 }) }
    $t = @(); $x = @(); $last = 100
    for ($k = 0; $k -le 61; $k++) { $j = [math]::Max(0, [math]::Min(60, $k - 1)); $v = 100 + 5 * $(if ($j -lt 20) { $j } elseif ($j -lt 40) { 20 } else { $j - 20 })
        if ($v -ne $last -or $k -eq 0) { $t += $k * $P; $x += $v; $last = $v } }
    $mp = Measure-FrameMotion -Time ([double[]]$t) -Position ([double[]]$x) -PeriodMs $P -Start 0 -End (61 * $P) -PointerTime ([double[]]$pt) -PointerPosition ([double[]]$pp)
    Assert 'C16 a pointer pause (no new frames because nothing moved) is not a stall and keeps rate 1' ($mp.AdvanceRate -eq 1 -and $mp.LongestStall -eq 0) "$mp"

    Complete-TestBody
}
finally {
    foreach ($b in $bitmaps) { if ($b) { $b.Dispose() } }
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the library as it now stands?". Red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-score -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2381 FRAME-SCORE' -Pass $script:passes -Fail $script:failures
