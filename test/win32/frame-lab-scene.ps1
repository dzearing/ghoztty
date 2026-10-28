<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameLabScene.ps1 (T2394) - the frame
  lab's live scene scorer, proved on synthetic resize frames before it is ever
  trusted with a real one.

.DESCRIPTION
  The live scorer infers each frame's scene from where the window's edges and
  divider are in THAT frame, never from the cards' own content. Proving it
  needs frames whose truth is known, so this script renders them: a window on
  a solid backdrop, two panes split by a divider, each running FrameLabCard's
  test card, at a sequence of window sizes - a resize drag, frame by frame.

  Sections:

    A. the contract: calibration on a still frame measures the cell size,
       padding and every side's offset the renderer used; the C# layout rules
       (glyph scale, region) equal FrameLabCard's;
    B. the resize sequence: clean frames score clean with every tracked edge
       where it was drawn, and each planted defect - B1 magenta erase, B2
       content at the PREVIOUS size, B3 a stretched ring, B6 a garbage block -
       is found on exactly its frame; a frame whose window edge cannot be
       found fails as LOC; and the scorer runs as FrameCapture's GfcScorer on
       the worker thread;
    C. speed: one 1500x1000 frame scores inside one 120 Hz refresh.

  No app, no window, no input: runs anywhere.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-scene.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
$script:skipped = 0
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
. (Join-Path $PSScriptRoot 'lib\FrameLabScene.ps1')
Import-FrameLabScene

# ---- the synthetic window ----------------------------------------------------
$FW = 1500; $FH = 1000                 # capture rect
$Backdrop = 0x10F010
$Chrome = 0x484848
$Divider = 0x808080
$Pad = 0x282C34                        # theme background in the padding
$Magenta = 0xFF00FF
$WinL = 50; $WinT = 40; $TabH = 30
$CellW = 9; $CellH = 19; $PadPx = 4

function Get-Layout([int]$W, [int]$H) {
    $y0 = $WinT + $TabH; $y1 = $WinT + $H
    $div = $WinL + [math]::Floor($W / 2) - 1
    [pscustomobject]@{
        Right = $WinL + $W; Bottom = $y1; Div = $div
        A = (New-ScoreBox $WinL $y0 $div $y1)
        B = (New-ScoreBox ($div + 2) $y0 ($WinL + $W) $y1)
    }
}

# One card, drawn the way FrameLabCard's rule draws it (cell backgrounds only).
# -Grid is the rect the GRID is sized for (the previous size, for a stale
# frame); -RingMul thickens the left ring (a stretch).
function Draw-Card($f, $pane, [int]$Index, $Grid, [int]$RingMul = 1) {
    if (-not $Grid) { $Grid = $pane }
    $c = Get-FrameLabCardColors -Index $Index
    $f.Fill($pane, $Pad)
    $cols = [math]::Floor(($Grid.W - 2 * $PadPx) / $CellW)
    $rows = [math]::Floor(($Grid.H - 2 * $PadPx) / $CellH)
    $gx = $pane.X0 + $PadPx; $gy = $pane.Y0 + $PadPx
    $gw = $cols * $CellW; $gh = $rows * $CellH
    $f.Fill((New-ScoreBox $gx $gy ($gx + $gw) ($gy + $gh)), $c.Bg)
    $f.Fill((New-ScoreBox $gx $gy ($gx + $CellW * $RingMul) ($gy + $gh)), $c.Ring)
    $f.Fill((New-ScoreBox ($gx + $gw - $CellW) $gy ($gx + $gw) ($gy + $gh)), $c.Ring)
    $f.Fill((New-ScoreBox $gx $gy ($gx + $gw) ($gy + $CellH)), $c.Ring)
    $f.Fill((New-ScoreBox $gx ($gy + $gh - $CellH) ($gx + $gw) ($gy + $gh)), $c.Ring)
    $s = Get-FrameLabGlyphScale -Cols $cols -Rows $rows -Scale 2
    if ($s -gt 0) {
        $mask = $script:FrameLabDigits[[string]$Index]
        for ($mr = 0; $mr -lt 5; $mr++) {
            for ($mc = 0; $mc -lt 3; $mc++) {
                if ($mask[$mr][$mc] -ne '#') { continue }
                $x = $gx + ($script:FrameLabGlyphCol + $mc * 2 * $s) * $CellW
                $y = $gy + ($script:FrameLabGlyphRow + $mr * $s) * $CellH
                $f.Fill((New-ScoreBox $x $y ($x + 2 * $s * $CellW) ($y + $s * $CellH)), $c.Glyph)
            }
        }
    }
}

# A whole frame at window size W x H. -Plant: B1 / B2 (content at -PrevW x
# -PrevH) / B3 / B6 / NoBackdrop.
function New-SceneFrame([int]$W, [int]$H, [string]$Plant = '', [int]$PrevW = 0, [int]$PrevH = 0) {
    $f = New-Object FsFrame $FW, $FH
    $f.Fill((New-ScoreBox 0 0 $FW $FH), $(if ($Plant -eq 'NoBackdrop') { $Chrome } else { $Backdrop }))
    $L = Get-Layout $W $H
    $f.Fill((New-ScoreBox $WinL $WinT $L.Right $L.Bottom), $Chrome)
    $f.Fill((New-ScoreBox $L.Div ($WinT + $TabH) ($L.Div + 2) $L.Bottom), $Divider)
    $gA = $null; $gB = $null
    if ($Plant -eq 'B2') { $P = Get-Layout $PrevW $PrevH; $gA = $P.A; $gB = $P.B }
    Draw-Card $f $L.A 1 $gA
    Draw-Card $f $L.B 2 $gB $(if ($Plant -eq 'B3') { 2 } else { 1 })
    if ($Plant -eq 'B1') { $f.Fill((New-ScoreBox ($L.B.X0 + 100) ($L.B.Y0 + 220) ($L.B.X0 + 140) ($L.B.Y0 + 260)), $Magenta) }
    if ($Plant -eq 'B6') { $f.Fill((New-ScoreBox ($L.A.X0 + 120) ($L.A.Y0 + 240) ($L.A.X0 + 150) ($L.A.Y0 + 270)), 0x000000) }
    return $f
}

function New-SceneEdges {
    @(
        (New-FrameLabSceneEdge -Name 'window-right' -Kind 'window-right' -Vertical -Lines @(150, 250, 350) -From ($FW - 1) -To 0 -Color $Backdrop -Backdrop),
        (New-FrameLabSceneEdge -Name 'window-bottom' -Kind 'window-bottom' -Lines @(150, 250, 350) -From ($FH - 1) -To 0 -Color $Backdrop -Backdrop),
        (New-FrameLabSceneEdge -Name 'divider' -Kind 'divider' -Vertical -Lines @(300, 400, 500) -From ($WinL + 10) -To ($FW - 1) -Color $Divider)
    )
}
function New-SceneCards {
    @(
        (New-FrameLabSceneCard -Index 1 -Anchor @('', '', 'divider', 'window-bottom') -Extra @($Pad) -Name 'A'),
        (New-FrameLabSceneCard -Index 2 -Anchor @('divider', '', 'window-right', 'window-bottom') -Extra @($Pad) -Name 'B')
    )
}

$Flash = @($Magenta, $Chrome, $Backdrop)
$sizes = @(0..20 | ForEach-Object { , @((900 + 25 * $_), (600 + 12 * $_)) })

# ---- A. the contract ---------------------------------------------------------
'A. calibration and the layout contract'
$still = New-SceneFrame $sizes[0][0] $sizes[0][1]
$sc = New-FrameLabSceneScorer -Edges (New-SceneEdges) -Cards (New-SceneCards) -Still $still -Flash $Flash
$L0 = Get-Layout $sizes[0][0] $sizes[0][1]
$cA = $sc.Cards[0]; $cB = $sc.Cards[1]
Assert 'A1 calibration measures the cell size (9x19) and padding (4/4) the cards were drawn with' (
    $cA.CellW -eq 9 -and $cA.CellH -eq 19 -and $cA.PadL -eq 4 -and $cA.PadT -eq 4 -and $cB.CellW -eq 9 -and $cB.PadL -eq 4) "A=$($cA.CellW)x$($cA.CellH) pad $($cA.PadL)/$($cA.PadT) B=$($cB.CellW)x$($cB.CellH) pad $($cB.PadL)/$($cB.PadT)"
Assert 'A2 the still panes are the rects drawn, and each side rides its edge at the drawn offset (A.R = divider, B.L = divider + 2)' (
    "$($cA.Still)" -eq "$($L0.A)" -and "$($cB.Still)" -eq "$($L0.B)" -and
    ($cA.Offset -join ',') -eq "$WinL,$($WinT + $TabH),0,0" -and ($cB.Offset -join ',') -eq "2,$($WinT + $TabH),0,0") (
    "A=$($cA.Still) want $($L0.A) off $($cA.Offset -join ',') | B=$($cB.Still) want $($L0.B) off $($cB.Offset -join ',')")

$bad = @()
foreach ($cols in 1..40) { foreach ($rows in 1..24) {
    $want = Get-FrameLabGlyphScale -Cols $cols -Rows $rows -Scale 2
    $got = $sc.GlyphScale($cols, $rows, 2)
    if ($want -ne $got) { $bad += "${cols}x${rows}: $got want $want" }
} }
Assert 'A3 the C# glyph-scale rule equals FrameLabCard''s for every grid up to 40x24' ($bad.Count -eq 0) (($bad | Select-Object -First 5) -join '; ')

$bad = @()
foreach ($box in @((New-ScoreBox 50 70 505 640), (New-ScoreBox 507 70 950 640), (New-ScoreBox 10 10 70 60), (New-ScoreBox 0 0 1213 777))) {
    $cols = [math]::Floor(($box.W - 8) / 9); $rows = [math]::Floor(($box.H - 8) / 19)
    $want = New-FrameLabCardRegion -Card $box -Index 1 -Cols $cols -Rows $rows -CellW 9 -CellH 19 -PadLeft 4 -PadTop 4 -Extra @($Pad) -Name 'A'
    $got = $sc.RegionFor($cA, $box)
    $w = "$($want.Slack -join ',') $($want.RingW)x$($want.RingH) g$($want.Glyph) $($want.GlyphW)x$($want.GlyphH)"
    $g = "$($got.Slack -join ',') $($got.RingW)x$($got.RingH) g$($got.Glyph) $($got.GlyphW)x$($got.GlyphH)"
    if ($w -ne $g) { $bad += "$box : $g want $w" }
}
Assert 'A4 the region built per frame equals New-FrameLabCardRegion for the same rect and grid (slack, ring, glyph)' ($bad.Count -eq 0) ($bad -join '; ')

$bent = New-SceneFrame $sizes[0][0] $sizes[0][1] 'B6'
$threw = $null
try { [void](New-FrameLabSceneScorer -Edges (New-SceneEdges) -Cards (New-SceneCards) -Still $bent -Flash $Flash) } catch { $threw = $_.Exception.Message }
Assert 'A5 negative control: a still frame that does not score clean refuses calibration, and says why' (
    $threw -and $threw -match 'does not score clean' -and $threw -match 'B6') "$threw"

# ---- B. the resize sequence --------------------------------------------------
''
'B. a resize drag, frame by frame'
$plants = @{ 5 = 'B1'; 8 = 'B2'; 11 = 'B3'; 14 = 'B6' }
$frames = @()
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $p = $(if ($plants.ContainsKey($i)) { $plants[$i] } else { '' })
    $frames += , (New-SceneFrame $sizes[$i][0] $sizes[$i][1] $p $sizes[[math]::Max(0, $i - 1)][0] $sizes[[math]::Max(0, $i - 1)][1])
}
$recs = @()
for ($i = 0; $i -lt $frames.Count; $i++) { $recs += $sc.ScoreFrame($frames[$i], $i, [long]$i * 83333) }

$dirty = @(); $edgeBad = @()
for ($i = 0; $i -lt $recs.Count; $i++) {
    $L = Get-Layout $sizes[$i][0] $sizes[$i][1]
    $e = $recs[$i].Edges
    if ($e[0] -ne $L.Right -or $e[1] -ne $L.Bottom -or $e[2] -ne $L.Div) { $edgeBad += "#${i}: $($e -join ',') want $($L.Right),$($L.Bottom),$($L.Div)" }
    if (-not $plants.ContainsKey($i) -and $recs[$i].Failing) { $dirty += "#${i}: $(($recs[$i].Findings | Select-Object -First 3) -join '; ')" }
}
Assert "B1 every clean frame of the drag ($($recs.Count - $plants.Count)) scores zero findings" ($dirty.Count -eq 0) (($dirty | Select-Object -First 3) -join ' | ')
Assert 'B2 every frame''s tracked window-right, window-bottom and divider equal the ones drawn (planted frames too)' ($edgeBad.Count -eq 0) (($edgeBad | Select-Object -First 3) -join ' | ')

foreach ($k in ($plants.Keys | Sort-Object)) {
    $cls = $plants[$k]
    $on = @(for ($i = 0; $i -lt $recs.Count; $i++) { if ($recs[$i].Failing -and @($recs[$i].Findings | Where-Object { $_.Cls -eq $cls }).Count -gt 0) { $i } })
    $what = @{ B1 = 'a magenta erase'; B2 = 'content still at the PREVIOUS size'; B3 = 'a ring stretched to twice its width'; B6 = 'a black garbage block' }[$cls]
    Assert "B3.$cls $what is found on exactly its frame (#$k), as $cls" ($on.Count -eq 1 -and $on[0] -eq $k) (
        "frames with ${cls}: $($on -join ',') | #$k reads $($recs[$k].Classes()): $(($recs[$k].Findings | Select-Object -First 3) -join '; ')")
}

$stale = $recs[8]
Assert 'B4 the stale frame reads B2 on both cards (its content disagrees with where the panes are), never clean' (
    $stale.Failing -and @($stale.Findings | Where-Object { $_.Cls -eq 'B2' -and $_.Target -eq 'A' }).Count -gt 0 -and
    @($stale.Findings | Where-Object { $_.Cls -eq 'B2' -and $_.Target -eq 'B' }).Count -gt 0) "$(($stale.Findings | Select-Object -First 4) -join '; ')"

$lost = $sc.ScoreFrame((New-SceneFrame $sizes[3][0] $sizes[3][1] 'NoBackdrop'), 99, 0)
Assert 'B5 a frame on which the window''s edge cannot be found fails as LOC, naming the card and the edge' (
    $lost.Failing -and [double]::IsNaN($lost.Edges[0]) -and @($lost.Findings | Where-Object { $_.Cls -eq 'LOC' -and $_.Target -match 'window-right' }).Count -gt 0) "$(($lost.Findings | Select-Object -First 3) -join '; ')"

$m = Get-FrameLabSceneMotion -Scorer $sc -Edge 'window-right' -QpcFrequency 10000000
Assert 'B6 the motion input carries one position and one time per scored frame, in order' (
    $m.Position.Length -eq ($recs.Count + 1) -and $m.Position[1] -eq ($WinL + 925) -and [math]::Abs($m.Time[2] - 16.6666) -lt 1e-6) "n=$($m.Position.Length) p1=$($m.Position[1]) t2=$($m.Time[2])"

# The same scorer on FrameCapture's worker thread, fed the drag.
$sw = New-Object GfsSceneScorer
foreach ($e in (New-SceneEdges)) { $sw.Edges.Add($e) }
foreach ($c in (New-SceneCards)) { $sw.Cards.Add($c) }
$sw.Flash = [int[]]$Flash
$why = $sw.Calibrate($still)
$ws = Start-FrameCaptureWorker -W $FW -H $FH -SampleEvery 0 -Scorer $sw.AsScorer()
for ($i = 0; $i -lt $frames.Count; $i++) { [void]$ws.Feed($frames[$i].Px, [long]$i * 83333) }
$st = $ws.Stop()
$failIdx = @($ws.Timeline | Where-Object { $_.Failing } | ForEach-Object { $_.Index }) -join ','
Assert 'B7 as a GfcScorer on the capture worker: every frame scored, exactly the four planted frames failing' (
    $why.Count -eq 0 -and $st.Scored -eq $frames.Count -and $st.ScorerErrors -eq 0 -and $failIdx -eq '5,8,11,14') "scored=$($st.Scored) errors=$($st.ScorerErrors) failing=$failIdx why=$($why -join ';')"

# ---- C. speed ----------------------------------------------------------------
''
'C. scoring keeps up with the display'
$big = New-SceneFrame 1400 900
$ms = @()
for ($i = 0; $i -lt 20; $i++) { $ms += $sc.ScoreFrame($big, 1000 + $i, 0).Ms }
$ms = @($ms | Sort-Object)
$p50 = $ms[[int]($ms.Count / 2)]; $max = $ms[-1]
'    1500x1000 frame (window 1400x900, two cards): p50 {0:F2} ms, max {1:F2} ms over {2} runs' -f $p50, $max, $ms.Count
Assert 'C1 a 1500x1000 frame scores inside one 120 Hz refresh (p50 < 8.33 ms)' ($p50 -lt (1000.0 / 120)) ('p50 {0:F2} ms' -f $p50)

Complete-TestBody

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-scene -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2394 FRAME-LAB-SCENE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
