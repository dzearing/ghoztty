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
       divider; every catalogued interaction has a scene (T2727);
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
       painting exactly its colour. Nothing reaches the user's desktop;
    G. window-moving cells (T2398): caption-dblclick and maximize-button
       calibrated on a restored AND a maximized still (no border, a shorter
       caption), a maximize/restore scored frame by frame with a stale
       maximized frame planted; aero-snap dragged onto the work area's edge,
       snapped and dragged off with every divider carried; the refusals (no
       maximized still, a "maximized" still that is not, a window that starts
       against the edge) and the never-maximized run read as a miss.
    H. trigger cells (T2727): banner tracks the target pane's top up its
       padding column - on, off, a stale grid and a banner painted over an
       unmoved pane both caught; hero, tab-switch and split-close scored
       against one calibrated state per pane set, a frame matching no state
       failing, and the refusals (no state, a state that is the start's, a
       padding-coloured chrome above the banner pane, no target) plus the
       run whose pane set never changed read as a miss.

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
$BannerCol = 0x6A5A30
$CellW = 9; $CellH = 19; $PadPx = 4; $DivW = 2; $TabH = 30
$WinX = 250; $WinY = 140
$Monitor = @{ X = 0; Y = 0; W = 3000; H = 2000 }

# Pane rects for a world: a Cols x Rows ratio split of the content area (the
# window less its tab strip, its sidebar and a 1 px border right and bottom);
# -DivAt pins the first column's right edge (a divider drag). -WX/-WY put the
# window elsewhere (it moves as a whole), -Border 0 is a maximized window's
# missing border and -Tab its caption height (T2398).
# -Banner N pushes the first pane's top down N px under a banner, and
# -IndexBase shifts the card indices (another tab's cards, T2727).
function Get-World([int]$W, [int]$H, [int]$Cols = 1, [int]$Rows = 1, [int]$SbW = 0, [int]$DivAt = -1, [int]$WX = $WinX, [int]$WY = $WinY, [int]$Border = 1, [int]$Tab = $TabH, [int]$Banner = 0, [int]$IndexBase = 0) {
    $x0 = $WX + $SbW; $y0 = $WY + $Tab; $x1 = $WX + $W - $Border; $y1 = $WY + $H - $Border
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
        $panes += [pscustomobject]@{ Name = "P$n"; Index = $n + $IndexBase; X = $cs[$i]; Y = $rs[$j]; W = $ce[$i] - $cs[$i]; H = $re[$j] - $rs[$j] }
    } }
    $bn = $null
    if ($Banner -gt 0) {
        $p1 = $panes[0]
        $bn = [pscustomobject]@{ X = $p1.X; Y = $p1.Y; W = $p1.W; H = $Banner }
        $p1.Y += $Banner; $p1.H -= $Banner
    }
    [pscustomobject]@{ W = $W; H = $H; WX = $WX; WY = $WY; SbW = $SbW; X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1; Panes = $panes; DivX = $ce[0]; Banner = $bn }
}

function Get-WorldGeometry($World, $Mon = $Monitor, [string]$Target = '') {
    $g = @{
        Window = @{ X = $World.WX; Y = $World.WY; W = $World.W; H = $World.H }
        Monitor = $Mon
        Caption = $World.WY + 10
        Panes = @($World.Panes | ForEach-Object { @{ Name = $_.Name; Index = $_.Index; X = $_.X; Y = $_.Y; W = $_.W; H = $_.H } })
    }
    if ($World.Panes.Count -gt 1) { $g.Divider = @{ X = $World.DivX; Y0 = $World.Y0; Y1 = $World.Y1 } }
    if ($World.SbW -gt 0) { $g.Sidebar = @{ EdgeX = $World.X0; Y0 = $World.Y0; Y1 = $World.Y1 } }
    if ($Target) { $g.Target = $Target }
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
# NoBackdrop / DivIsCard (the dividers drawn in card 1's Bg) / BannerOver
# (this world's banner painted over -Prev's panes, which never moved) /
# PadChrome (the chrome painted in the padding colour).
function New-WorldFrame($World, $Cap, [string]$Plant = '', $Prev) {
    $f = New-Object FsFrame ([int]$Cap.W), ([int]$Cap.H)
    $f.Fill((New-ScoreBox 0 0 $Cap.W $Cap.H), $(if ($Plant -eq 'NoBackdrop') { $Chrome } else { $Backdrop }))
    $ox = -$Cap.X; $oy = -$Cap.Y
    $f.Fill((New-ScoreBox ($World.WX + $ox) ($World.WY + $oy) ($World.WX + $World.W + $ox) ($World.WY + $World.H + $oy)), $(if ($Plant -eq 'PadChrome') { $Pad } else { $Chrome }))
    $dc = $(if ($Plant -eq 'DivIsCard') { (Get-FrameLabCardColors -Index 1).Bg } else { $DivCol })
    $f.Fill((New-ScoreBox ($World.X0 + $ox) ($World.Y0 + $oy) ($World.X1 + $ox) ($World.Y1 + $oy)), $dc)
    if ($World.SbW -gt 0) {
        $f.Fill((New-ScoreBox ($World.WX + $ox) ($World.Y0 + $oy) ($World.X0 - 2 + $ox) ($World.Y1 + $oy)), $SbBg)
        $f.Fill((New-ScoreBox ($World.X0 - 2 + $ox) ($World.Y0 + $oy) ($World.X0 + $ox) ($World.Y1 + $oy)), $SbEdge)
    }
    $drawn = $(if ($Plant -eq 'BannerOver' -and $Prev) { $Prev } else { $World })
    for ($i = 0; $i -lt $drawn.Panes.Count; $i++) {
        $p = $drawn.Panes[$i]
        $grid = $(if ($Plant -eq 'B2' -and $Prev) { $Prev.Panes[$i] } else { $null })
        Draw-Card $f $Cap $p $p.Index $grid
    }
    if ($World.Banner) {
        $b = $World.Banner
        $f.Fill((New-ScoreBox ($b.X + $ox) ($b.Y + $oy) ($b.X + $b.W + $ox) ($b.Y + $b.H + $oy)), $BannerCol)
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

    # T2727: every catalogued interaction has a scene - none is refused as
    # "not modelled" - and a name that is not catalogued still is.
    $cat = @(Get-FrameLabInteractions | ForEach-Object { $_.Name })
    $none = @($cat | Where-Object { $_ -notin $script:FrameLabSceneSupported })
    $geo = Get-WorldGeometry $w1 $Monitor 'P1'
    $msgs = @(foreach ($n in $cat) {
        $sp = New-FrameLabCellSceneSpec -Interaction $n -Geometry $geo -CaptureRect $t.Cap
        $u = @($sp.Unsupported | Where-Object { $_ -match 'not modelled' })
        if ($u.Count) { "${n}: $($u -join '; ')" }
    })
    $bogus = New-FrameLabCellSceneSpec -Interaction 'no-such-gesture' -Geometry $geo -CaptureRect $t.Cap
    Assert "B6 the Unsupported list is empty for the catalogue: all $($cat.Count) interactions have a scene, and an uncatalogued name is still refused" (
        $cat.Count -ge 13 -and $none.Count -eq 0 -and $msgs.Count -eq 0 -and ($bogus.Unsupported -join ' ') -match 'not modelled') "unscened=$($none -join ',') $($msgs -join ' | ') bogus=$($bogus.Unsupported -join ';')"

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

    # ---- G. window-moving cells (T2398) ---------------------------------------
    ''
    'G. caption-dblclick / aero-snap / maximize-button: the window moves as a whole'
    $MonG = @{ X = 0; Y = 0; W = 1400; H = 900 }
    function New-MovingCell([string]$Interaction, $W0, $WMax, [switch]$MaxIsRestored) {
        $geo = Get-WorldGeometry $W0 $MonG
        if ($Interaction -eq 'maximize-button') {
            # A trigger: the plan, not a pointer path, says what is captured.
            $geo.MaximizeButton = @{ X = $W0.WX + $W0.W - 69; Y = $W0.WY + 10 }
            $g = Get-FrameLabTrigger -Name $Interaction -Geometry $geo
        } else { $g = Get-FrameLabGesture -Name $Interaction -Geometry $geo }
        $spec = New-FrameLabCellSceneSpec -Interaction $Interaction -Geometry $geo -CaptureRect $g.CaptureRect
        $a = @{ Spec = $spec; Still = (New-WorldFrame $W0 $g.CaptureRect); Flash = @($Chrome) }
        if ($WMax) { $a.MaximizedStill = New-WorldFrame $WMax $g.CaptureRect }
        if ($MaxIsRestored) { $a.MaximizedStill = New-WorldFrame $W0 $g.CaptureRect }
        [pscustomobject]@{ Geometry = $geo; Gesture = $g; Spec = $spec; Scene = (New-FrameLabCellScene @a); Cap = $g.CaptureRect }
    }
    $wantWin = { param($w) $h = @{ 'window-left' = $w.WX; 'window-top' = $w.WY; 'window-right' = $w.WX + $w.W; 'window-bottom' = $w.WY + $w.H }
        if ($w.Panes.Count -gt 1) { $h['v:P1'] = $w.Panes[0].X + $w.Panes[0].W }
        $h }
    $r2 = Get-World 800 500 2 1
    # Maximized: the whole work area, no border, and a caption 4 px shorter.
    $m2 = Get-World 1400 900 2 1 -WX 0 -WY 0 -Border 0 -Tab ($TabH - 4)
    $tc = New-MovingCell 'caption-dblclick' $r2 $m2
    $names = ($tc.Spec.Edges.Name | Sort-Object) -join ','
    $opens = (@($tc.Spec.Edges | Where-Object { $_.Open }).Name | Sort-Object) -join ','
    $dv = @($tc.Spec.Edges | Where-Object { $_.Name -eq 'v:P1' })[0]
    Assert 'G1 the spec: all four window edges, every one Open; the divider carried over the window''s left..right / top..bottom; every card side that touches no divider rides its window edge; the cell maximizes' (
        $names -eq 'v:P1,window-bottom,window-left,window-right,window-top' -and $opens -eq 'window-bottom,window-left,window-right,window-top' -and
        "$($dv.CarryX)/$($dv.CarryX2)/$($dv.CarryY)/$($dv.CarryY2)" -eq 'window-left/window-right/window-top/window-bottom' -and
        (Get-Anchors $tc.Spec 'P1') -eq 'window-left window-top v:P1 window-bottom' -and (Get-Anchors $tc.Spec 'P2') -eq 'v:P1 window-top window-right window-bottom' -and
        $tc.Spec.Maximizes -and $tc.Spec.Unsupported.Count -eq 0 -and "$($tc.Cap.X),$($tc.Cap.Y),$($tc.Cap.W),$($tc.Cap.H)" -eq '0,0,1400,900') (
        "edges=$names open=$opens carry=$($dv.CarryX)/$($dv.CarryX2)/$($dv.CarryY)/$($dv.CarryY2) P1=$(Get-Anchors $tc.Spec 'P1') P2=$(Get-Anchors $tc.Spec 'P2') unsup=$($tc.Spec.Unsupported -join ';')")
    $c1 = $(if ($tc.Scene.Ok) { $tc.Scene.Scorer.Cards[0] })
    Assert 'G2 calibrated on both stills: the maximized offsets lose the border (bottom -1 -> 0) and the 4 px of caption (top 30 -> 26)' (
        $tc.Scene.Ok -and $tc.Scene.Scorer.MaxCalibrated -and $c1.Offset[3] -eq -1 -and $c1.OffsetMax[3] -eq 0 -and $c1.Offset[1] -eq $TabH -and $c1.OffsetMax[1] -eq ($TabH - 4)) (
        "ok=$($tc.Scene.Ok) reasons=$($tc.Scene.Reasons -join '; ') $(if ($c1) { "off=$($c1.Offset -join ',') max=$($c1.OffsetMax -join ',')" })")
    if ($tc.Scene.Ok) {
        $worlds = @($r2, $r2, $m2, $m2, $m2, $m2, $r2, $r2)
        $d = Invoke-TestDrag $tc $worlds @{ 2 = 'B2' } $wantWin
        $on = @(for ($i = 0; $i -lt $d.Records.Count; $i++) { if ($d.Records[$i].Failing) { $i } })
        $mx = @(for ($i = 0; $i -lt $d.Records.Count; $i++) { if ($d.Records[$i].Maximized) { $i } })
        Assert 'G3 maximize and restore: every frame clean but the planted stale one (#2, the maximized window still drawing the restored grid, B2), every edge where drawn, frames 2-5 read maximized and no other' (
            $d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0 -and ($on -join ',') -eq '2' -and $d.Records[2].Classes() -match 'B2' -and ($mx -join ',') -eq '2,3,4,5') (
            "dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3) failing=$($on -join ',') #2=$($d.Records[2].Classes()) maximized=$($mx -join ',')")
        $timeline = @(0..7 | ForEach-Object { [pscustomobject]@{ Index = $_; Superseded = $false } })
        $capture = [pscustomobject]@{ Stats = [pscustomobject]@{ QpcFrequency = 10000000; RefreshHz = 120 }; Timeline = $timeline }
        $s = Get-FrameLabSceneScore -Scorer $tc.Scene.Scorer -Capture $capture -Gesture $tc.Gesture -ExpectMaximized
        Assert 'G4 the score bridge counts the maximized frames (4) and a run that did maximize is no miss' ($s.MaximizedFrames -eq 4 -and $s.MotionMisses.Count -eq 0 -and $s.BleedFrames -eq 1) "maxed=$($s.MaximizedFrames) misses=$($s.MotionMisses -join ';') bleed=$($s.BleedFrames)"
    }
    $tq = New-MovingCell 'caption-dblclick' $r2 $m2
    if ($tq.Scene.Ok) {
        foreach ($i in 0..3) { [void]$tq.Scene.Scorer.ScoreFrame((New-WorldFrame $r2 $tq.Cap), $i, [long]$i * 83333) }
        $timeline = @(0..3 | ForEach-Object { [pscustomobject]@{ Index = $_; Superseded = $false } })
        $capture = [pscustomobject]@{ Stats = [pscustomobject]@{ QpcFrequency = 10000000; RefreshHz = 120 }; Timeline = $timeline }
        $s = Get-FrameLabSceneScore -Scorer $tq.Scene.Scorer -Capture $capture -Gesture $tq.Gesture -ExpectMaximized
        Assert 'G5 negative control: a maximizing run whose window never maximized is a miss (it fails), not a clean pass over a window that sat still' (
            $s.MaximizedFrames -eq 0 -and $s.BleedFrames -eq 0 -and ($s.MotionMisses -join ' ') -match 'never showed maximized') "maxed=$($s.MaximizedFrames) misses=$($s.MotionMisses -join ';')"
    } else { Assert 'G5 the second caption-dblclick cell calibrates' $false ($tq.Scene.Reasons -join '; ') }

    $r4 = Get-World 800 500 2 2
    $ta = New-MovingCell 'aero-snap' $r4 $null
    Assert 'G6 aero-snap calibrates on the restored still alone (it never maximizes)' ($ta.Scene.Ok -and -not $ta.Spec.Maximizes) ($ta.Scene.Reasons -join '; ')
    if ($ta.Scene.Ok) {
        $worlds = @(250, 200, 150, 100, 50, 0 | ForEach-Object { Get-World 800 500 2 2 -WX $_ })
        $worlds += Get-World 700 900 2 2 -WX 0 -WY 0
        $worlds += Get-World 800 500 2 2 -WX 300
        $d = Invoke-TestDrag $ta $worlds @{} $wantWin
        $mx = @($d.Records | Where-Object { $_.Maximized }).Count
        Assert 'G7 aero-snap: dragged left onto the work area''s edge, snapped (left half, full height, border kept) and dragged off - every frame clean, every edge where drawn, none maximized' (
            $d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0 -and $mx -eq 0) "dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3) maximized=$mx"
        $fr = $ta.Scene.Scorer.ScoreFrame((New-WorldFrame $m2 $ta.Cap), 99, 0)
        Assert 'G8 a maximized frame in a scene with no maximized calibration fails as LOC naming why, never scored against the restored offsets as if clean' (
            $fr.Failing -and $fr.Maximized -and (@($fr.Findings | Where-Object { $_.Cls -eq 'LOC' -and $_.Detail -match 'no maximized still' }).Count -eq 1)) "failing=$($fr.Failing) max=$($fr.Maximized) $($fr.Classes())"
    }

    $tn = New-MovingCell 'maximize-button' $r2 $null
    $tr = New-MovingCell 'caption-dblclick' $r2 $null -MaxIsRestored
    Assert 'G9 refusals: a maximizing cell with no maximized still, and one whose "maximized" still shows the restored window, are both refused, saying why' (
        -not $tn.Scene.Ok -and ($tn.Scene.Reasons -join ' ') -match 'no maximized still frame was given' -and
        -not $tr.Scene.Ok -and ($tr.Scene.Reasons -join ' ') -match 'does not show a maximized window') "none: $($tn.Scene.Reasons -join '; ') | restored: $($tr.Scene.Reasons -join '; ')"
    $edge = Get-World 800 500 1 1 -WX 0
    $geo = Get-WorldGeometry $edge $MonG
    $g = Get-FrameLabGesture -Name 'caption-dblclick' -Geometry $geo
    $sp = New-FrameLabCellSceneSpec -Interaction 'caption-dblclick' -Geometry $geo -CaptureRect $g.CaptureRect
    Assert 'G10 a window-moving cell whose window starts against the work area''s edge is Unsupported (no backdrop to tell it from a snapped one)' (
        ($sp.Unsupported -join ' ') -match 'backdrop on every side.*left') ($sp.Unsupported -join '; ')

    # ---- H. trigger cells (T2727) ---------------------------------------------
    ''
    'H. banner (pane-top) and the pane-set triggers (hero, tab-switch, split-close)'
    function New-TriggerCell([string]$Interaction, $W0, [object[]]$StateWorlds = @(), [string]$Target = 'P1', [string]$StillPlant = '', [switch]$NoTarget) {
        $geo = Get-WorldGeometry $W0 $Monitor $(if ($NoTarget) { '' } else { $Target })
        $pg = $geo.Clone(); $pg.Target = $Target
        $plan = Get-FrameLabTrigger -Name $Interaction -Geometry $pg
        $spec = New-FrameLabCellSceneSpec -Interaction $Interaction -Geometry $geo -CaptureRect $plan.CaptureRect
        $states = @(for ($i = 0; $i -lt $StateWorlds.Count; $i++) {
            @{ Name = "s$($i + 1)"; Geometry = (Get-WorldGeometry $StateWorlds[$i]); Still = (New-WorldFrame $StateWorlds[$i] $plan.CaptureRect) }
        })
        $scene = New-FrameLabCellScene -Spec $spec -Still (New-WorldFrame $W0 $plan.CaptureRect $StillPlant) -Flash @($Chrome) -States $states
        [pscustomobject]@{ Geometry = $geo; Gesture = $plan; Spec = $spec; Scene = $scene; Cap = $plan.CaptureRect }
    }
    function Get-Failing($d) { @(for ($i = 0; $i -lt $d.Records.Count; $i++) { if ($d.Records[$i].Failing) { $i } }) -join ',' }
    function Get-States($d) { @($d.Records | ForEach-Object { $_.State }) -join '' }
    function Get-Bridge($T, [int]$N, [switch]$States) {
        $timeline = @(0..($N - 1) | ForEach-Object { [pscustomobject]@{ Index = $_; Superseded = $false } })
        $capture = [pscustomobject]@{ Stats = [pscustomobject]@{ QpcFrequency = 10000000; RefreshHz = 120 }; Timeline = $timeline }
        Get-FrameLabSceneScore -Scorer $T.Scene.Scorer -Capture $capture -Gesture ([pscustomobject]@{ Axis = 'none'; Track = '' }) -ExpectStates:$States
    }

    # Banner: two panes side by side, the banner on the left one.
    $b0 = Get-World 1000 600 2 1
    $tb = New-TriggerCell 'banner' $b0
    $pt = @($tb.Spec.Edges | Where-Object { $_.Name -eq 'pane-top' })
    Assert 'H1 banner spec: a pane-top edge on the target pane, scanned UP (From below To), the target''s T riding it and the other pane''s T fixed; the plan tracks pane-top' (
        $pt.Count -eq 1 -and -not $pt[0].Vertical -and $pt[0].From -gt $pt[0].To -and (Get-Anchors $tb.Spec 'P1') -eq '- pane-top v:P1 -' -and (Get-Anchors $tb.Spec 'P2') -eq 'v:P1 - - -' -and $tb.Gesture.Track -eq 'pane-top' -and $tb.Spec.Unsupported.Count -eq 0) (
        "pane-top=$($pt.Count) P1=$(Get-Anchors $tb.Spec 'P1') P2=$(Get-Anchors $tb.Spec 'P2') track=$($tb.Gesture.Track) unsup=$($tb.Spec.Unsupported -join ';')")
    $ptl = $(if ($tb.Scene.Ok) { $tb.Scene.Scorer.Edges[$tb.Scene.Scorer.EdgeIndex('pane-top')].Lines })
    Assert 'H2 banner calibrates on its still frame: pane-top located where the geometry puts it, its scan lines spread across the pane''s padding column' (
        $tb.Scene.Ok -and $tb.Scene.Delta['pane-top'] -eq 0 -and @($ptl | Where-Object { $_ -lt $b0.Panes[0].X - $tb.Cap.X -or $_ -ge $b0.Panes[0].X - $tb.Cap.X + $PadPx }).Count -eq 0 -and @($ptl | Select-Object -Unique).Count -gt 1) (
        "ok=$($tb.Scene.Ok) reasons=$($tb.Scene.Reasons -join '; ') delta=$($tb.Scene.Delta['pane-top']) lines=$($ptl -join ',')")
    if ($tb.Scene.Ok) {
        $on = Get-World 1000 600 2 1 -Banner 36
        $worlds = @($b0, $b0, $on, $on, $on, $on, $b0, $b0)
        $d = Invoke-TestDrag $tb $worlds @{} { param($w) @{ 'pane-top' = $w.Panes[0].Y - $tb.Cap.Y } }
        Assert 'H3 banner on and off: every frame clean, pane-top where drawn on all 8 (pushed 36 px down while the banner shows)' (
            $d.Dirty.Count -eq 0 -and $d.EdgeBad.Count -eq 0 -and (Get-Failing $d) -eq '') "dirty=$($d.Dirty | Select-Object -First 2) edges=$($d.EdgeBad | Select-Object -First 3)"
        $worlds = @($b0, $b0, $on, $on, $b0, $on, $on, $b0)
        $d = Invoke-TestDrag $tb $worlds @{ 2 = 'B2'; 5 = 'BannerOver' } { param($w) @{} }
        Assert 'H4 stale frames caught on exactly their frames: #2 the banner pane still drawing the full-height grid, #5 a banner painted over a pane that never moved' (
            $d.Dirty.Count -eq 0 -and (Get-Failing $d) -eq '2,5') "failing=$(Get-Failing $d) #2=$($d.Records[2].Classes()) #5=$($d.Records[5].Classes()) dirty=$($d.Dirty | Select-Object -First 2)"
    }
    $tpc = New-TriggerCell 'banner' $b0 -StillPlant 'PadChrome'
    $tnt = New-TriggerCell 'banner' $b0 -NoTarget
    Assert 'H5 banner refusals: chrome above the pane in its padding colour (nothing would stop the scan), and a geometry with no target pane' (
        -not $tpc.Scene.Ok -and ($tpc.Scene.Reasons -join ' ') -match 'pane-top: the chrome above the pane .* is its padding colour' -and
        ($tnt.Spec.Unsupported -join ' ') -match 'needs Geometry.Target' -and -not $tnt.Scene.Ok) "padchrome: $($tpc.Scene.Reasons -join '; ') | notarget: $($tnt.Spec.Unsupported -join '; ')"

    # Hero: two panes, then the first alone filling the window, then back.
    $h0 = Get-World 1000 600 2 1
    $h1 = Get-World 1000 600 1 1
    $th = New-TriggerCell 'hero' $h0 @($h1)
    Assert 'H6 hero calibrates the start (2 panes) and one state (the hero pane alone), and the spec says it changes the pane set' (
        $th.Scene.Ok -and $th.Spec.PaneSet -and $th.Scene.PaneSet -and $th.Scene.Scorer.States.Count -eq 1 -and $th.Scene.Scorer.States[0].StateName -eq 's1') "ok=$($th.Scene.Ok) reasons=$($th.Scene.Reasons -join '; ')"
    if ($th.Scene.Ok) {
        $three = Get-World 1000 600 3 1
        $worlds = @($h0, $h0, $h1, $h1, $h1, $h1, $h0, $three, $h0)
        $d = Invoke-TestDrag $th $worlds @{ 2 = 'B2' } { param($w) @{} }
        Assert 'H7 hero in and out: every frame clean but #2 (the hero pane still drawing its half-width grid) and #7 (a pane set that is neither state); frames 3-5 matched the hero state, the rest the start' (
            $d.Dirty.Count -eq 1 -and (Get-Failing $d) -eq '2,7' -and (Get-States $d).Substring(3, 3) -eq '111' -and (Get-States $d).Substring(0, 2) -eq '00' -and (Get-States $d)[6] -eq '0' -and (Get-States $d)[8] -eq '0') (
            "failing=$(Get-Failing $d) states=$(Get-States $d) dirty=$($d.Dirty -join ' | ')")
        $s = Get-Bridge $th $worlds.Count -States
        Assert 'H8 the score bridge: two bleed frames, three frames passed as the hero state, and a run that changed pane set is no miss' ($s.BleedFrames -eq 2 -and $s.StateFrames -eq 3 -and $s.MotionMisses.Count -eq 0) "bleed=$($s.BleedFrames) states=$($s.StateFrames) misses=$($s.MotionMisses -join ';')"
    }

    # Tab-switch: the second tab shows another card; a third card is no state.
    $t0 = Get-World 900 600
    $t1 = Get-World 900 600 -IndexBase 4
    $tt = New-TriggerCell 'tab-switch' $t0 @($t1)
    if ($tt.Scene.Ok) {
        $worlds = @($t0, $t1, $t1, (Get-World 900 600 -IndexBase 2), $t0)
        $d = Invoke-TestDrag $tt $worlds @{} { param($w) @{} }
        Assert 'H9 tab-switch: the start and the second tab (card 5) both pass, each as its own state; a frame of a third card (3) matches no state and fails' (
            (Get-Failing $d) -eq '3' -and (Get-States $d).Substring(0, 3) -eq '011' -and (Get-States $d)[4] -eq '0') "failing=$(Get-Failing $d) states=$(Get-States $d)"
    } else { Assert 'H9 tab-switch calibrates' $false ($tt.Scene.Reasons -join '; ') }

    # Split-close: one pane, split right, closed again.
    $s0 = Get-World 1000 600
    $s1 = Get-World 1000 600 2 1
    $ts = New-TriggerCell 'split-close' $s0 @($s1)
    if ($ts.Scene.Ok) {
        $worlds = @($s0, $s1, $s1, $s1, $s0, $s0)
        $d = Invoke-TestDrag $ts $worlds @{ 1 = 'B2' } { param($w) @{} }
        Assert 'H10 split-close: split and closed, every frame clean but #1 (the split pane still drawing its full-width grid); frames 2-3 matched the split state' (
            (Get-Failing $d) -eq '1' -and (Get-States $d).Substring(2, 2) -eq '11' -and (Get-States $d).Substring(4) -eq '00') "failing=$(Get-Failing $d) states=$(Get-States $d) #1=$($d.Records[1].Classes())"
        $ts2 = New-TriggerCell 'split-close' $s0 @($s1)
        foreach ($i in 0..3) { [void]$ts2.Scene.Scorer.ScoreFrame((New-WorldFrame $s0 $ts2.Cap), $i, [long]$i * 83333) }
        $s = Get-Bridge $ts2 4 -States
        Assert 'H11 negative control: a pane-set run whose pane set never changed is a miss, not a clean pass over a window that sat still' (
            $s.StateFrames -eq 0 -and $s.BleedFrames -eq 0 -and ($s.MotionMisses -join ' ') -match 'no scored frame showed another pane set') "states=$($s.StateFrames) misses=$($s.MotionMisses -join ';')"
    } else { Assert 'H10 split-close calibrates' $false ($ts.Scene.Reasons -join '; ') }

    # T2784: the live driver scores a trigger's tracked edge on its FIRE
    # stamps (there is no pointer path), with positions back in screen px.
    $tb2 = New-TriggerCell 'banner' $b0
    if ($tb2.Scene.Ok) {
        $on = Get-World 1000 600 2 1 -Banner 36
        $ws = @($b0, $b0, $b0, $on, $on, $on, $on, $on, $on, $b0, $b0, $b0)
        for ($i = 0; $i -lt $ws.Count; $i++) { [void]$tb2.Scene.Scorer.ScoreFrame((New-WorldFrame $ws[$i] $tb2.Cap), $i, [long]$i * 83333) }
        $timeline = @(0..($ws.Count - 1) | ForEach-Object { [pscustomobject]@{ Index = $_; Superseded = $false } })
        $capture = [pscustomobject]@{ Stats = [pscustomobject]@{ QpcFrequency = 10000000; RefreshHz = 120 }; Timeline = $timeline }
        $st = { param([int]$i, [long]$q) [pscustomobject]@{ Index = $i; Action = 'ipc'; FireQpc = $q; StartQpc = $q; DoneQpc = $q } }
        $fired = [pscustomobject]@{ Frequency = 10000000; Stamps = @((& $st 0 (2 * 83333 + 1000)), (& $st 1 (8 * 83333 + 1000))) }
        $sb = Get-FrameLabSceneScore -Scorer $tb2.Scene.Scorer -Capture $capture -Gesture $tb2.Gesture -Played $fired -Delta $tb2.Scene.Delta
        # The same frames under a plan WITH a glide are held to the targets: a
        # 36 px jump that holds for six refreshes is no eased glide.
        $gl = $tb2.Gesture.PSObject.Copy()
        $py = [double]$b0.Panes[0].Y
        $gl.Glides = @([pscustomobject]@{ Step = 0; FromPx = $py; ToPx = $py + 36; Ms = 240.0; Curve = @(0.2, 0.8, 0.2, 1.0) }, [pscustomobject]@{ Step = 1; FromPx = $py + 36; ToPx = $py; Ms = 240.0; Curve = @(0.2, 0.8, 0.2, 1.0) })
        $sg = Get-FrameLabSceneScore -Scorer $tb2.Scene.Scorer -Capture $capture -Gesture $gl -Played $fired -Delta $tb2.Scene.Delta
        Assert 'H13b positive control: a trigger plan with a glide is held to the smoothness targets, so a jump that holds reads as a miss' (
            @($sg.MotionMisses).Count -gt 0 -and $sg.Motion.MaxCurveDev -gt 0) "misses=$($sg.MotionMisses -join ';') curveDev=$($sg.Motion.MaxCurveDev)"
        $half = [pscustomobject]@{ Frequency = 10000000; Stamps = @((& $st 0 (2 * 83333))) }
        $sh = Get-FrameLabSceneScore -Scorer $tb2.Scene.Scorer -Capture $capture -Gesture $tb2.Gesture -Played $half -Delta $tb2.Scene.Delta
        Assert 'H13 a trigger''s tracked edge is measured on its fire stamps: banner on/off gives a motion over every frame, none unlocated, its two jumps the only advances, and no miss (a jump is not held to the glide targets, T2824); negative control: one of two steps fired is a miss, never a motion' (
            $null -ne $sb.Motion -and $sb.Motion.Unlocated -eq 0 -and @($sb.MotionMisses).Count -eq 0 -and $sb.BleedFrames -eq 0 -and $sb.Motion.Advanced -eq 2 -and
            $null -eq $sh.Motion -and ($sh.MotionMisses -join ' ') -match '1 of 2 trigger step\(s\) fired') (
            "motion=$($null -ne $sb.Motion) unlocated=$($sb.Motion.Unlocated) misses=$($sb.MotionMisses -join ';') bleed=$($sb.BleedFrames) | half=$($sh.MotionMisses -join ';')")
    } else { Assert 'H13 banner calibrates for the fire-stamp bridge' $false ($tb2.Scene.Reasons -join '; ') }

    # T2784: the live launcher addresses pane 1 by its pane id, so the banner's
    # Geometry.Target is that id and the pane carries it as Target.
    $gid = Get-WorldGeometry $b0 $Monitor 'pane-42'
    $gid.Panes[0].Target = 'pane-42'
    $spid = New-FrameLabCellSceneSpec -Interaction banner -Geometry $gid -CaptureRect (Get-FrameLabTrigger -Name banner -Geometry $gid).CaptureRect
    $gno = Get-WorldGeometry $b0 $Monitor 'pane-43'
    $gno.Panes[0].Target = 'pane-42'
    $spno = New-FrameLabCellSceneSpec -Interaction banner -Geometry $gno -CaptureRect (Get-FrameLabTrigger -Name banner -Geometry $gno).CaptureRect
    Assert 'H14 a banner Target that is a pane id finds the pane carrying it; one no pane carries is refused' (
        @($spid.Unsupported).Count -eq 0 -and @($spid.Edges | Where-Object { $_.Name -eq 'pane-top' }).Count -eq 1 -and
        ($spno.Unsupported -join ' ') -match "target 'pane-43' is not one of the geometry's panes") "id: $($spid.Unsupported -join ';') | none: $($spno.Unsupported -join ';')"

    $tn = New-TriggerCell 'hero' $h0
    $tsame = New-TriggerCell 'hero' $h0 @($h0)
    Assert 'H12 pane-set refusals: no state still at all, and a "state" that is the pane set the run starts on, both refused saying why' (
        -not $tn.Scene.Ok -and ($tn.Scene.Reasons -join ' ') -match 'no still frame of the other pane set' -and
        -not $tsame.Scene.Ok -and ($tsame.Scene.Reasons -join ' ') -match 'state s1: .*not another pane set') "none: $($tn.Scene.Reasons -join '; ') | same: $($tsame.Scene.Reasons -join '; ')"

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
