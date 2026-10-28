<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameLabLiveScene.ps1 (T2397) - the frame
  lab's per-cell live scene: the backdrop behind the app, the scorer's edges
  and cards derived from a cell's geometry, the still-frame calibration, and
  the bridge from the scorer's records to the cell's numbers.

.DESCRIPTION
  The live run photographs the real app; this proves everything between the
  geometry the launcher measures and the cell's verdict against frames whose
  truth is known. They are rendered from the same geometry the spec is built
  from - a window on the backdrop, panes in a ratio split (so an inner divider
  moves when the window does), an optional sidebar - and each drag is
  rendered frame by frame through the catalogue's own gesture.

  Sections:

    A. the backdrop colour: the default is clear of every card colour and
       every colour a card must never use; a colour that is not (T2394's
       synthetic 0x10F010, a card's own Bg) is refused, and says why;
    B. the spec from geometry: which edges exist, which side of each card
       rides which edge, for 1/2/4/9 panes, a sidebar, and the grabbed
       divider; window-moving interactions are Unsupported, not guessed;
    C. calibrate and score a drag: frame-right (1 pane), frame-corner (4
       panes, inner dividers moving), divider (2 panes), sidebar-edge (a
       sidebar) - every clean frame clean, every tracked edge where it was
       drawn, a planted stale frame found on exactly its frame;
    D. refusals: no backdrop, a divider drawn in a card's colour, and a scene
       refusal through Invoke-FrameLabCell reads incomplete with nothing
       played;
    E. the score bridge: superseded frames not counted, a bleed frame named,
       the motion measured on the pointer's clock with the still-frame delta
       folded into the grab offset;
    F. the backdrop window itself, on the background test desktop: shown
       directly below the window it backs, never activated, never topmost,
       painting exactly its colour. Nothing reaches the user's desktop.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-live-scene.ps1
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
. (Join-Path $PSScriptRoot 'lib\FrameLabCatalogue.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameLabLiveScene.ps1')
Import-FrameLabScene

# ---- the synthetic world (screen coordinates, physical px) -----------------
$Backdrop = $script:FrameLabBackdropColor
$Chrome = 0x484848
$DivCol = 0x808080
$SbBg = 0x303848
$SbEdge = 0x9090B0
$Pad = 0x282C34
$CellW = 9; $CellH = 19; $PadPx = 4; $DivW = 2; $TabH = 30
$WinX = 250; $WinY = 140
$Monitor = @{ X = 0; Y = 0; W = 3000; H = 2000 }

# Pane rects for a world: a Cols x Rows ratio split of the content area (the
# window less its tab strip, its sidebar and a 1 px border right and bottom);
# -DivAt pins the first column's right edge (a divider drag).
function Get-World([int]$W, [int]$H, [int]$Cols = 1, [int]$Rows = 1, [int]$SbW = 0, [int]$DivAt = -1) {
    $x0 = $WinX + $SbW; $y0 = $WinY + $TabH; $x1 = $WinX + $W - 1; $y1 = $WinY + $H - 1
    $cs = @(); $ce = @()
    for ($i = 0; $i -lt $Cols; $i++) {
        $cs += $x0 + [math]::Floor($i * ($x1 - $x0 + $DivW) / $Cols)
        $ce += $x0 + [math]::Floor(($i + 1) * ($x1 - $x0 + $DivW) / $Cols) - $DivW
    }
    if ($DivAt -ge 0) { $ce[0] = $DivAt; if ($Cols -gt 1) { $cs[1] = $DivAt + $DivW } }
    $rs = @(); $re = @()
    for ($j = 0; $j -lt $Rows; $j++) {
        $rs += $y0 + [math]::Floor($j * ($y1 - $y0 + $DivW) / $Rows)
        $re += $y0 + [math]::Floor(($j + 1) * ($y1 - $y0 + $DivW) / $Rows) - $DivW
    }
    $panes = @()
    $n = 0
    for ($j = 0; $j -lt $Rows; $j++) { for ($i = 0; $i -lt $Cols; $i++) {
        $n++
        $panes += [pscustomobject]@{ Name = "P$n"; Index = $n; X = $cs[$i]; Y = $rs[$j]; W = $ce[$i] - $cs[$i]; H = $re[$j] - $rs[$j] }
    } }
    [pscustomobject]@{ W = $W; H = $H; SbW = $SbW; X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1; Panes = $panes; DivX = $ce[0] }
}

function Get-WorldGeometry($World) {
    $g = @{
        Window = @{ X = $WinX; Y = $WinY; W = $World.W; H = $World.H }
        Monitor = $Monitor
        Caption = $WinY + 10
        Panes = @($World.Panes | ForEach-Object { @{ Name = $_.Name; Index = $_.Index; X = $_.X; Y = $_.Y; W = $_.W; H = $_.H } })
    }
    if ($World.Panes.Count -gt 1) { $g.Divider = @{ X = $World.DivX; Y0 = $World.Y0; Y1 = $World.Y1 } }
    if ($World.SbW -gt 0) { $g.Sidebar = @{ EdgeX = $World.X0; Y0 = $World.Y0; Y1 = $World.Y1 } }
    return $g
}

# One card into frame $f at the pane's rect (screen) offset by the capture;
# -Grid sizes the GRID for another rect (a stale frame).
function Draw-Card($f, $cap, $pane, [int]$Index, $Grid) {
    if (-not $Grid) { $Grid = $pane }
    $c = Get-FrameLabCardColors -Index $Index
    $px = $pane.X - $cap.X; $py = $pane.Y - $cap.Y
    $f.Fill((New-ScoreBox $px $py ($px + $pane.W) ($py + $pane.H)), $Pad)
    $cols = [math]::Floor(($Grid.W - 2 * $PadPx) / $CellW)
    $rows = [math]::Floor(($Grid.H - 2 * $PadPx) / $CellH)
    $gx = $px + $PadPx; $gy = $py + $PadPx
    $gw = $cols * $CellW; $gh = $rows * $CellH
    $f.Fill((New-ScoreBox $gx $gy ($gx + $gw) ($gy + $gh)), $c.Ring)
    $f.Fill((New-ScoreBox ($gx + $CellW) ($gy + $CellH) ($gx + $gw - $CellW) ($gy + $gh - $CellH)), $c.Bg)
    $s = Get-FrameLabGlyphScale -Cols $cols -Rows $rows -Scale 2
    if ($s -gt 0) {
        $mask = $script:FrameLabDigits[[string]$Index]
        for ($mr = 0; $mr -lt 5; $mr++) { for ($mc = 0; $mc -lt 3; $mc++) {
            if ($mask[$mr][$mc] -ne '#') { continue }
            $x = $gx + ($script:FrameLabGlyphCol + $mc * 2 * $s) * $CellW
            $y = $gy + ($script:FrameLabGlyphRow + $mr * $s) * $CellH
            $f.Fill((New-ScoreBox $x $y ($x + 2 * $s * $CellW) ($y + $s * $CellH)), $c.Glyph)
        } }
    }
}

# A whole frame of the capture rect. -Plant: B2 (grids sized for -Prev) /
# NoBackdrop / DivIsCard (the dividers drawn in card 1's Bg).
function New-WorldFrame($World, $Cap, [string]$Plant = '', $Prev) {
    $f = New-Object FsFrame ([int]$Cap.W), ([int]$Cap.H)
    $f.Fill((New-ScoreBox 0 0 $Cap.W $Cap.H), $(if ($Plant -eq 'NoBackdrop') { $Chrome } else { $Backdrop }))
    $ox = -$Cap.X; $oy = -$Cap.Y
    $f.Fill((New-ScoreBox ($WinX + $ox) ($WinY + $oy) ($WinX + $World.W + $ox) ($WinY + $World.H + $oy)), $Chrome)
    $dc = $(if ($Plant -eq 'DivIsCard') { (Get-FrameLabCardColors -Index 1).Bg } else { $DivCol })
    $f.Fill((New-ScoreBox ($World.X0 + $ox) ($World.Y0 + $oy) ($World.X1 + $ox) ($World.Y1 + $oy)), $dc)
    if ($World.SbW -gt 0) {
        $f.Fill((New-ScoreBox ($WinX + $ox) ($World.Y0 + $oy) ($World.X0 - 2 + $ox) ($World.Y1 + $oy)), $SbBg)
        $f.Fill((New-ScoreBox ($World.X0 - 2 + $ox) ($World.Y0 + $oy) ($World.X0 + $ox) ($World.Y1 + $oy)), $SbEdge)
    }
    for ($i = 0; $i -lt $World.Panes.Count; $i++) {
        $p = $World.Panes[$i]
        $grid = $(if ($Plant -eq 'B2' -and $Prev) { $Prev.Panes[$i] } else { $null })
        Draw-Card $f $Cap $p $p.Index $grid
    }
    return $f
}

# Build the spec + scene for an interaction at world $w0 (the still frame).
function New-TestCell([string]$Interaction, $W0, [hashtable]$GArgs = @{}) {
    $geo = Get-WorldGeometry $W0
    $g = Get-FrameLabGesture -Name $Interaction -Geometry $geo @GArgs
    $spec = New-FrameLabCellSceneSpec -Interaction $Interaction -Geometry $geo -CaptureRect $g.CaptureRect
    $still = New-WorldFrame $W0 $g.CaptureRect
    $scene = New-FrameLabCellScene -Spec $spec -Still $still -Flash @($Chrome)
    [pscustomobject]@{ Geometry = $geo; Gesture = $g; Spec = $spec; Scene = $scene; Cap = $g.CaptureRect }
}

function Get-Anchors($Spec, [string]$Card) { (@($Spec.Cards | Where-Object { $_.Name -eq $Card })[0].Anchor | ForEach-Object { if ($_) { $_ } else { '-' } }) -join ' ' }

# Score a drag: $worlds frame by frame; returns the records and every
# frame whose tracked edges are not where each was drawn.
function Invoke-TestDrag($T, $Worlds, [hashtable]$Plants = @{}, [scriptblock]$Want) {
    $sc = $T.Scene.Scorer
    $recs = @(); $bad = @()
    for ($i = 0; $i -lt $Worlds.Count; $i++) {
        $p = $(if ($Plants.ContainsKey($i)) { $Plants[$i] } else { '' })
        $f = New-WorldFrame $Worlds[$i] $T.Cap $p $Worlds[[math]::Max(0, $i - 1)]
        $r = $sc.ScoreFrame($f, $i, [long]$i * 83333)
        $recs += $r
        foreach ($kv in (& $Want $Worlds[$i]).GetEnumerator()) {
            $k = $sc.EdgeIndex($kv.Key)
            if ($r.Edges[$k] -ne $kv.Value) { $bad += "#${i} $($kv.Key)=$($r.Edges[$k]) want $($kv.Value)" }
        }
    }
    $dirty = @(for ($i = 0; $i -lt $recs.Count; $i++) { if (-not $Plants.ContainsKey($i) -and $recs[$i].Failing) { "#${i}: $(($recs[$i].Findings | Select-Object -First 2) -join '; ')" } })
    [pscustomobject]@{ Records = $recs; EdgeBad = $bad; Dirty = $dirty }
}

try {
    # ---- A. the backdrop colour --------------------------------------------
    'A. the backdrop colour'
    $why = Test-FrameLabBackdropColor -Other @($Chrome, $DivCol)
    Assert ('A1 the default backdrop 0x{0:X6} is at least 32 from every card colour, every forbidden colour and the scene''s chrome' -f $Backdrop) ($why.Count -eq 0) ($why -join '; ')
    $why = Test-FrameLabBackdropColor -Color 0x10F010
    Assert 'A2 negative control: T2394''s synthetic 0x10F010 is refused - 16 from card 4''s ring' ($why.Count -gt 0 -and ($why -join ' ') -match 'card 4 Ring') ($why -join '; ')
    $why = Test-FrameLabBackdropColor -Color (Get-FrameLabCardColors -Index 3).Bg
    Assert 'A3 negative control: a card''s own Bg is refused, naming the card' ($why.Count -gt 0 -and ($why -join ' ') -match 'card 3 Bg') ($why -join '; ')

    # ---- B. the spec from geometry -----------------------------------------
    ''
    'B. which edges exist, and which side rides which'
    $w1 = Get-World 900 600
    $t = New-TestCell 'frame-right' $w1
    $names = ($t.Spec.Edges.Name | Sort-Object) -join ','
    Assert 'B1 frame-right, 1 pane: only window-right exists (no backdrop below a capture that ends at the window''s bottom), and the card''s R rides it' (
        $names -eq 'window-right' -and (Get-Anchors $t.Spec 'P1') -eq '- - window-right -' -and $t.Spec.Unsupported.Count -eq 0) "edges=$names anchors=$(Get-Anchors $t.Spec 'P1')"

    $w4 = Get-World 1000 700 2 2
    $t4 = New-TestCell 'frame-corner' $w4
    $names = ($t4.Spec.Edges.Name | Sort-Object) -join ','
    $a = @('P1', 'P2', 'P3', 'P4' | ForEach-Object { "$_=$(Get-Anchors $t4.Spec $_)" }) -join ' | '
    Assert 'B2 frame-corner, 2x2: both window edges plus a divider edge per pane with a right or lower neighbour, every inner side riding one' (
        $names -eq 'h:P1,h:P2,v:P1,v:P3,window-bottom,window-right' -and
        $a -eq 'P1=- - v:P1 h:P1 | P2=v:P1 - window-right h:P2 | P3=- h:P1 v:P3 window-bottom | P4=v:P3 h:P2 window-right window-bottom') "edges=$names | $a"

    $w2 = Get-World 1000 600 2 1
    $t2 = New-TestCell 'divider' $w2
    $names = ($t2.Spec.Edges.Name | Sort-Object) -join ','
    Assert 'B3 divider, 2 panes: the grabbed divider is named ''divider'' (the gesture''s Track), and no window edge exists in a capture that is the window' (
        $names -eq 'divider' -and (Get-Anchors $t2.Spec 'P1') -eq '- - divider -' -and (Get-Anchors $t2.Spec 'P2') -eq 'divider - - -' -and $t2.Gesture.Track -eq 'divider') "edges=$names P1=$(Get-Anchors $t2.Spec 'P1') P2=$(Get-Anchors $t2.Spec 'P2')"

    $ws = Get-World 900 600 1 1 160
    $tsb = New-TestCell 'sidebar-edge' $ws
    $names = ($tsb.Spec.Edges.Name | Sort-Object) -join ','
    Assert 'B4 sidebar-edge: the sidebar edge exists and the first column''s L rides it' (
        $names -eq 'sidebar-edge' -and (Get-Anchors $tsb.Spec 'P1') -eq 'sidebar-edge - - -') "edges=$names P1=$(Get-Anchors $tsb.Spec 'P1')"

    $w9 = Get-World 1200 900 3 3
    $t9 = New-TestCell 'frame-bottom' $w9
    $nv = @($t9.Spec.Edges | Where-Object { $_.Name -like 'v:*' }).Count; $nh = @($t9.Spec.Edges | Where-Object { $_.Name -like 'h:*' }).Count
    Assert 'B5 frame-bottom, 3x3: six vertical and six horizontal divider edges, window-bottom and no window-right' (
        $nv -eq 6 -and $nh -eq 6 -and @($t9.Spec.Edges.Name) -contains 'window-bottom' -and @($t9.Spec.Edges.Name) -notcontains 'window-right') "v=$nv h=$nh edges=$($t9.Spec.Edges.Name -join ',')"

    $ok = $true; $msgs = @()
    foreach ($n in 'caption-dblclick', 'aero-snap') {
        $geo = Get-WorldGeometry $w1
        $g = Get-FrameLabGesture -Name $n -Geometry $geo
        $sp = New-FrameLabCellSceneSpec -Interaction $n -Geometry $geo -CaptureRect $g.CaptureRect
        if (-not $sp.Unsupported.Count -or ($sp.Unsupported -join ' ') -notmatch 'T2398') { $ok = $false }
        $msgs += "${n}: $($sp.Unsupported -join '; ')"
    }
    Assert 'B6 the window-moving interactions are Unsupported, naming the task that models them, never a guessed scene' $ok ($msgs -join ' | ')

    # ---- C. calibrate and score a drag --------------------------------------
    ''
    'C. calibration on the still frame, then the drag frame by frame'
    Assert 'C1 every cell above calibrates on its still frame (1, 2x2, divider, sidebar, 3x3)' (
        $t.Scene.Ok -and $t4.Scene.Ok -and $t2.Scene.Ok -and $tsb.Scene.Ok -and $t9.Scene.Ok) (
        "1:$($t.Scene.Reasons -join ';') 4:$($t4.Scene.Reasons -join ';') 2:$($t2.Scene.Reasons -join ';') sb:$($tsb.Scene.Reasons -join ';') 9:$($t9.Scene.Reasons -join ';')")
    $c1 = $t.Scene.Scorer.Cards[0]
    Assert 'C2 calibration measured the cell size and padding the cards were drawn with, and the border between pane and window edge (-1)' (
        $c1.CellW -eq $CellW -and $c1.CellH -eq $CellH -and $c1.PadL -eq $PadPx -and $c1.Offset[2] -eq -1) "cell $($c1.CellW)x$($c1.CellH) pad $($c1.PadL) offsets $($c1.Offset -join ',')"

    if ($t.Scene.Ok) {
        $worlds = @(0..20 | ForEach-Object { Get-World (900 + 12 * $_) 600 })
        $d = Invoke-TestDrag $t $worlds @{ 9 = 'B2' } { param($w) @{ 'window-right' = $w.W } }
        $on = @(for ($i = 0; $i -lt $d.Records.Count; $i++) { if ($d.Records[$i].Failing) { $i } })
        Assert 'C3 frame-right drag, 1 pane: 20 clean frames clean, window-right where drawn on all 21, the stale frame (#9) the only failing one, as B2' (
            $d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0 -and ($on -join ',') -eq '9' -and $d.Records[9].Classes() -match 'B2') "dirty=$($d.Dirty -join ' | ') edges=$($d.EdgeBad | Select-Object -First 3) failing=$($on -join ',') #9=$($d.Records[9].Classes())"
    }
    if ($t4.Scene.Ok) {
        $worlds = @(0..16 | ForEach-Object { Get-World (1000 + 15 * $_) (700 + 15 * $_) 2 2 })
        $d = Invoke-TestDrag $t4 $worlds @{} { param($w) @{ 'window-right' = $w.W; 'window-bottom' = $w.H; 'v:P1' = $w.Panes[0].X + $w.Panes[0].W - $t4.Cap.X } }
        Assert 'C4 frame-corner drag, 2x2: the inner dividers move with the window, and every frame still scores clean with every edge where drawn' (
            $d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0 -and ($worlds[16].DivX - $worlds[0].DivX) -gt 50) "moved=$($worlds[16].DivX - $worlds[0].DivX) dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3)"
    }
    if ($t2.Scene.Ok) {
        $x0 = $w2.DivX
        $worlds = @(0..12 | ForEach-Object { Get-World 1000 600 2 1 0 ($x0 + 20 * $_) })
        $d = Invoke-TestDrag $t2 $worlds @{} { param($w) @{ 'divider' = $w.DivX - $t2.Cap.X } }
        Assert 'C5 divider drag, 2 panes: both cards follow the divider and every frame scores clean' ($d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0) "dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3)"
    }
    if ($tsb.Scene.Ok) {
        $worlds = @(0..12 | ForEach-Object { Get-World 900 600 1 1 (160 + 20 * $_) })
        $d = Invoke-TestDrag $tsb $worlds @{} { param($w) @{ 'sidebar-edge' = $w.X0 - $tsb.Cap.X } }
        Assert 'C6 sidebar-edge drag: the pane follows the sidebar edge and every frame scores clean' ($d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0) "dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3)"
    }

    # ---- D. refusals --------------------------------------------------------
    ''
    'D. a scene that cannot be read is refused, and the cell reads incomplete'
    $geo = Get-WorldGeometry $w1
    $g = Get-FrameLabGesture -Name 'frame-right' -Geometry $geo
    $sp = New-FrameLabCellSceneSpec -Interaction 'frame-right' -Geometry $geo -CaptureRect $g.CaptureRect
    $r = New-FrameLabCellScene -Spec $sp -Still (New-WorldFrame $w1 $g.CaptureRect 'NoBackdrop')
    Assert 'D1 the backdrop missing: calibration refuses, naming window-right as not located' (
        -not $r.Ok -and -not $r.Scorer -and ($r.Reasons -join ' ') -match 'window-right not located') ($r.Reasons -join '; ')

    $geo2 = Get-WorldGeometry $w2
    $g2 = Get-FrameLabGesture -Name 'divider' -Geometry $geo2
    $sp2 = New-FrameLabCellSceneSpec -Interaction 'divider' -Geometry $geo2 -CaptureRect $g2.CaptureRect
    $r = New-FrameLabCellScene -Spec $sp2 -Still (New-WorldFrame $w2 $g2.CaptureRect 'DivIsCard')
    Assert 'D2 a divider drawn in a card''s colour is refused before any scan is trusted' (-not $r.Ok -and ($r.Reasons -join ' ') -match 'divider: its colour .* is a card colour') ($r.Reasons -join '; ')

    $played = New-Object System.Collections.ArrayList
    $drv = @{
        Presence = { [pscustomobject]@{ Present = $false; Reason = '' } }
        Launch = { param($Cell) @{ Geometry = (Get-WorldGeometry $w1); Close = { } } }
        Scene = { param($Cell, $L, $G)
            $s = New-FrameLabCellSceneSpec -Interaction $Cell.Interaction -Geometry $L.Geometry -CaptureRect $G.CaptureRect
            New-FrameLabCellScene -Spec $s -Still (New-WorldFrame $w1 $G.CaptureRect 'NoBackdrop') }
        StartCapture = { param($Rect, $Dup, $Scorer) [void]$played.Add('capture'); 1 }
        StopCapture = { param($S) @{ Stats = @{ SlotGaps = 0 }; Account = $null; Timeline = @() } }
        Play = { param($P) [void]$played.Add('play'); [pscustomobject]@{ Skipped = $false; Aborted = $false } }
        Score = { param($C, $F, $G, $P, $S) @{ BleedFrames = 0; MotionMisses = @() } }
    }
    $cell = @(Get-FrameLabMatrix -Interaction frame-right -Panes 1 -Theme flat -Dpi 100 -Sidebar hidden -StallMs 0)[0]
    $res = Invoke-FrameLabCell -Cell $cell -Driver $drv
    Assert 'D3 through Invoke-FrameLabCell: the refusal is the verdict - incomplete, its reasons prefixed scene: - and nothing was captured or played' (
        $res.Verdict.Verdict -eq 'incomplete' -and ($res.Verdict.Reasons -join ' ') -match '^scene: .*window-right' -and $played.Count -eq 0) "verdict=$($res.Verdict.Verdict) reasons=$($res.Verdict.Reasons -join '; ') played=$($played -join ',')"

    $seen = New-Object System.Collections.ArrayList
    $drv.Scene = { param($Cell, $L, $G) [pscustomobject]@{ Ok = $true; Scorer = 'the-scorer'; Reasons = @(); Delta = @{} } }
    $drv.StartCapture = { param($Rect, $Dup, $Scorer) [void]$seen.Add("dup=$Dup scorer=$Scorer"); 1 }
    $drv.StopCapture = { param($S) @{ Stats = @{ SlotGaps = 0 }; Account = [pscustomobject]@{ Skipped = 0 }; Timeline = @() } }
    $drv.Score = { param($C, $F, $G, $P, $S) [void]$seen.Add("score scene=$($S.Scorer)"); @{ BleedFrames = 0; MotionMisses = @() } }
    $res = Invoke-FrameLabCell -Cell $cell -Driver $drv
    Assert 'D4 an Ok scene: its scorer rides the measurement capture only, and Score is handed the scene' (
        $res.Verdict.Verdict -eq 'pass' -and ($seen -join ' | ') -eq 'dup=False scorer=the-scorer | score scene=the-scorer | dup=True scorer=') "verdict=$($res.Verdict.Verdict) seen=$($seen -join ' | ')"

    # ---- E. the score bridge -----------------------------------------------
    ''
    'E. from the scorer''s records to the cell''s numbers'
    $F = 10000000; $hz = 120; $per = [long]($F / $hz)
    $t = New-TestCell 'frame-right' $w1
    $sc = $t.Scene.Scorer
    $g = $t.Gesture
    # Pointer stamps on the capture clock: the path as planned, sent on time.
    $base = 50 * $F
    $stamps = @($g.Path | ForEach-Object { [pscustomobject]@{ SentQpc = $base + $_.OffsetTicks; X = $_.X; Y = $_.Y } })
    $played = [pscustomobject]@{ Stamps = $stamps; Skipped = $false; Aborted = $false }
    # One frame per refresh across the whole path, the window's right edge at
    # the pointer minus the grab (a perfect follower), one stale frame, and a
    # superseded frame that bleeds and must not count.
    $end = $stamps[-1].SentQpc
    $timeline = @(); $k = 0; $si = 0
    $grabX = $stamps[0].X - ($WinX + 900)
    for ($q = $base; $q -le $end; $q += $per) {
        while ($si + 1 -lt $stamps.Count -and $stamps[$si + 1].SentQpc -le $q) { $si++ }
        $wpx = $stamps[$si].X - $grabX - $WinX
        $plant = $(if ($k -eq 40) { 'B2' } elseif ($k -eq 41) { 'NoBackdrop' } else { '' })
        $prevW = Get-World ([math]::Max(900, $wpx - 30)) 600
        $fr = New-WorldFrame (Get-World $wpx 600) $t.Cap $plant $prevW
        [void]$sc.ScoreFrame($fr, $k, $q)
        $timeline += [pscustomobject]@{ Index = $k; Superseded = ($k -eq 41) }
        $k++
    }
    $capture = [pscustomobject]@{ Stats = [pscustomobject]@{ QpcFrequency = $F; RefreshHz = $hz }; Timeline = $timeline }
    $s = Get-FrameLabSceneScore -Scorer $sc -Capture $capture -Gesture $g -Played $played -Delta $t.Scene.Delta
    Assert "E1 bleed: of $k frames the stale one (#40) is the only bleed frame counted - the superseded one (#41, no backdrop) is never on screen" (
        $s.BleedFrames -eq 1 -and $s.Frames[0].Index -eq 40 -and $s.Frames[0].Classes -match 'B2' -and $s.Scored -eq ($k - 1)) "bleed=$($s.BleedFrames) frames=$(@($s.Frames | ForEach-Object { "$($_.Index):$($_.Classes)" }) -join ',') scored=$($s.Scored)"
    $m = $s.Motion
    Assert 'E2 motion: measured on the pointer''s clock, a perfect follower advances on every due refresh and meets every target' (
        $null -ne $m -and $m.Due -gt 50 -and $s.MotionMisses.Count -eq 0) "$(if ($m) { "due=$($m.Due) adv=$($m.AdvanceRate) stall=$($m.LongestStall) lagp95=$($m.LagP95) rev=$($m.Reversals)" }) misses=$($s.MotionMisses -join '; ')"
    Assert 'E3 the still-frame delta for window-right (the pane''s border) is what the geometry and the backdrop scan disagree by: 0' (
        $t.Scene.Delta['window-right'] -eq 0) "delta=$($t.Scene.Delta['window-right'])"
    $gb = $g.PSObject.Copy(); $gb.Axis = 'none'
    $s2 = Get-FrameLabSceneScore -Scorer $sc -Capture $capture -Gesture $gb -Played $played
    Assert 'E4 a bleed-only gesture gets bleed and no motion' ($null -eq $s2.Motion -and $s2.BleedFrames -eq 1 -and $s2.MotionMisses.Count -eq 0) "motion=$($s2.Motion) bleed=$($s2.BleedFrames)"

    # ---- F. the backdrop window, on the test desktop -------------------------
    ''
    'F. the backdrop window (background test desktop: nothing reaches the user)'
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop
    $app = $null; $bd = $null
    try {
        $app = Show-FrameLabBackdrop -Rect @{ X = 300; Y = 200; W = 400; H = 300 } -Color 0x2060A0 -Desktop $td.Name
        $bd = Show-FrameLabBackdrop -Rect @{ X = 250; Y = 150; W = 700; H = 450 } -Below $app.Hwnd -Desktop $td.Name
        $ex = [GflBackdrop]::ExStyle($bd.Hwnd)
        $rect = [GflBackdrop]::Rect($bd.Hwnd) -join ','
        Assert 'F1 it is a visible borderless popup at exactly the rect asked for' (
            [GflBackdrop]::Visible($bd.Hwnd) -and (([GflBackdrop]::Style($bd.Hwnd) -band 0x80000000) -ne 0) -and $rect -eq '250,150,700,450') "visible=$([GflBackdrop]::Visible($bd.Hwnd)) rect=$rect"
        Assert 'F2 never activated, never topmost, not in the taskbar (WS_EX_NOACTIVATE + TOOLWINDOW, no TOPMOST)' (
            ($ex -band 0x08000000) -and ($ex -band 0x80) -and -not ($ex -band 0x8)) ('exstyle=0x{0:X8}' -f $ex)
        Assert 'F3 it sits directly below the window it backs' ([GflBackdrop]::Below($app.Hwnd) -eq $bd.Hwnd) "below(app)=$([GflBackdrop]::Below($app.Hwnd)) backdrop=$($bd.Hwnd)"
        $pxs = @($bd.PrintPixel(0, 0), $bd.PrintPixel(350, 225), $bd.PrintPixel(699, 449)) | ForEach-Object { '0x{0:X6}' -f $_ }
        Assert ('F4 it paints exactly its colour (0x{0:X6}) corner to corner' -f $Backdrop) (@($pxs | Where-Object { $_ -ne ('0x{0:X6}' -f $Backdrop) }).Count -eq 0) ($pxs -join ',')
        $h = $bd.Hwnd
        $bd.Dispose(); $bd = $null
        Assert 'F5 Dispose closes it' (-not [GflBackdrop]::Visible($h)) ''
    } finally {
        if ($bd) { $bd.Dispose() }
        if ($app) { $app.Dispose() }
        Remove-TestDesktop
    }

    Complete-TestBody
}
finally { }

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-live-scene -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2397 FRAME-LAB-LIVE-SCENE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
