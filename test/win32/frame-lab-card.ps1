<#
.SYNOPSIS
  Acceptance test for the T2373 frame lab's deterministic scene and its planted
  positive controls (T2383): test\win32\lib\FrameLabCard.ps1 (the card),
  test\win32\lib\lab-card.ps1 (the card running in a pane) and
  src\apprt\win32\lab_plant.zig (GHOZTTY_LAB_PLANT).

.DESCRIPTION
  The lab can only call a captured pixel wrong if every pixel the user should
  see is known in advance. That is the card's whole job, so this proves it from
  the bottom up, and then proves the three planted defects the lab's controls
  depend on really are planted:

    A. the palette: nine (Bg, Ring, Glyph) triples, every colour far from every
       other one, from the erase control's magenta and from what an undrawn
       pane shows; and no antialiasing blend inside a card passes near magenta,
       so an antialiased edge can never read as a background flash.
    B. the drawing: the VT the card writes, played back through a small
       interpreter, puts exactly Get-FrameLabCardCell's colour in every cell of
       every grid tried (with and without the glyph, in busy mode too), writes
       every cell, never scrolls, and is fast enough to redraw inside a drag.
    C. the contract with the scorer (FrameScore.ps1, T2381): the card
       rasterised at a cell size scores CLEAN against New-FrameLabCardRegion,
       and the three defects the controls plant are caught as the class they
       stand for - a magenta frame as B1, a card for the previous size as B2,
       a stretched old frame as B3.
    D. ON THE BOX (background test desktop): the real card in two real panes
       is photographed through the debug capture-pane action and scores
       clean, with the ring box exactly cols x rows cells (the check that
       catches a card drawn for the wrong grid); then, with
       GHOZTTY_LAB_PLANT armed, a scripted window resize fires every planted
       defect exactly once per pane/wash and says so on stderr, the held dim
       wash catches up to its pane afterwards, and the panes still render a
       clean card - every plant is one-shot.

  What D cannot show off the input desktop is a planted frame ON SCREEN: the
  magenta clear goes to the window, which the background desktop never
  composes. Catching it in a composed frame is the capture engine's job
  (T2382) and the lab's 100%-of-20-runs control (T2373); this proves the
  defect fires, when, and that it cleans up.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-card.ps1 [-PureOnly]
#>
[CmdletBinding()]
param([string]$ExePath, [switch]$Interactive, [switch]$PureOnly)

# T351: the shared reset/kill helpers, before any isolation setup.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

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
. (Join-Path $PSScriptRoot 'lib\FrameScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameLabCard.ps1')

$MAGENTA = 0xFF00FF
$THEME = 0x101014

function Get-ChanDist([int]$a, [int]$b) {
    $d = 0
    foreach ($sh in 16, 8, 0) {
        $x = [math]::Abs((($a -shr $sh) -band 255) - (($b -shr $sh) -band 255))
        if ($x -gt $d) { $d = $x }
    }
    return $d
}

# Closest approach (max-channel) of the segment a..b to colour p.
function Get-SegmentDist([int]$a, [int]$b, [int]$p) {
    $best = 999
    for ($i = 0; $i -le 64; $i++) {
        $t = $i / 64.0; $d = 0
        foreach ($sh in 16, 8, 0) {
            $ca = ($a -shr $sh) -band 255; $cb = ($b -shr $sh) -band 255; $cp = ($p -shr $sh) -band 255
            $x = [math]::Abs($ca + ($cb - $ca) * $t - $cp)
            if ($x -gt $d) { $d = $x }
        }
        if ($d -lt $best) { $best = $d }
    }
    return $best
}

# Play a VT string back into a grid of cells: bg colour, char, fg colour. Only
# the subset the card writes is understood; anything else is recorded, so an
# unexpected sequence fails the test instead of being silently skipped.
function Invoke-VtPlayback {
    param([string]$Vt, [int]$Cols, [int]$Rows)
    $bg = New-Object 'int[,]' $Rows, $Cols
    $ch = New-Object 'char[,]' $Rows, $Cols
    $fg = New-Object 'int[,]' $Rows, $Cols
    for ($r = 0; $r -lt $Rows; $r++) { for ($c = 0; $c -lt $Cols; $c++) { $bg[$r, $c] = -1; $ch[$r, $c] = [char]0 } }
    $row = 0; $col = 0; $curBg = -2; $curFg = -2
    $unknown = New-Object System.Collections.Generic.List[string]
    $overflow = 0
    $re = [regex]('\x1b\[(\??)([0-9;]*)([A-Za-z])|([^\x1b]+)')
    foreach ($m in $re.Matches($Vt)) {
        if ($m.Groups[4].Success) {
            foreach ($k in $m.Groups[4].Value.ToCharArray()) {
                if ($row -ge $Rows -or $col -ge $Cols) { $overflow++; continue }
                $bg[$row, $col] = $curBg; $ch[$row, $col] = $k; $fg[$row, $col] = $curFg
                $col++
            }
            continue
        }
        $priv = $m.Groups[1].Value; $p = $m.Groups[2].Value; $f = $m.Groups[3].Value
        if ($priv -eq '?') {
            if (@('2026', '25', '7') -notcontains $p) { $unknown.Add("?$p$f") }
            continue
        }
        switch ($f) {
            'H' {
                $a = $p -split ';'
                $row = [int]$a[0] - 1; $col = $(if ($a.Count -gt 1) { [int]$a[1] - 1 } else { 0 })
            }
            'm' {
                $a = @($p -split ';' | ForEach-Object { [int]$_ })
                if ($p -eq '' -or ($a.Count -eq 1 -and $a[0] -eq 0)) { $curBg = -2; $curFg = -2 }
                elseif ($a.Count -eq 5 -and $a[0] -eq 48 -and $a[1] -eq 2) { $curBg = ($a[2] -shl 16) -bor ($a[3] -shl 8) -bor $a[4] }
                elseif ($a.Count -eq 5 -and $a[0] -eq 38 -and $a[1] -eq 2) { $curFg = ($a[2] -shl 16) -bor ($a[3] -shl 8) -bor $a[4] }
                elseif ($a.Count -eq 1 -and $a[0] -eq 39) { $curFg = -2 }
                else { $unknown.Add("$p$f") }
            }
            default { $unknown.Add("$p$f") }
        }
    }
    return [pscustomobject]@{ Bg = $bg; Ch = $ch; Fg = $fg; Unknown = $unknown; Overflow = $overflow }
}

# The played-back grid as a frame: padding in the theme colour, every cell its
# background, and a non-space character as a two-pixel stroke in its fg with a
# 50% blend beside it (what antialiasing produces).
function ConvertTo-CardFrame {
    param($Grid, [int]$Cols, [int]$Rows, [int]$CellW, [int]$CellH, [int]$PadL, [int]$PadT, [int]$W, [int]$H)
    $f = New-Object FsFrame $W, $H
    $f.Fill((New-ScoreBox 0 0 $W $H), $THEME)
    for ($r = 0; $r -lt $Rows; $r++) {
        for ($c = 0; $c -lt $Cols; $c++) {
            $x0 = $PadL + $c * $CellW; $y0 = $PadT + $r * $CellH
            $b = $Grid.Bg[$r, $c]
            if ($b -lt 0) { $b = $THEME }
            $f.Fill((New-ScoreBox $x0 $y0 ($x0 + $CellW) ($y0 + $CellH)), $b)
            $k = $Grid.Ch[$r, $c]
            if ($k -ne [char]0 -and $k -ne ' ' -and $Grid.Fg[$r, $c] -ge 0) {
                $fc = $Grid.Fg[$r, $c]
                $mix = 0
                foreach ($sh in 16, 8, 0) { $mix = $mix -bor ([int]((((($b -shr $sh) -band 255) + (($fc -shr $sh) -band 255)) / 2)) -shl $sh) }
                $sx = $x0 + [int]($CellW / 2) - 1
                $f.Fill((New-ScoreBox $sx ($y0 + 3) ($sx + 2) ($y0 + $CellH - 3)), $fc)
                $f.Fill((New-ScoreBox ($sx + 2) ($y0 + 3) ($sx + 3) ($y0 + $CellH - 3)), $mix)
            }
        }
    }
    return $f
}

function New-CardScene($Region) {
    $s = New-Object FsScene
    $s.Regions.Add($Region)
    $s.Flash = [int[]]@($MAGENTA, $THEME)
    return $s
}

$bitmaps = @()
$td = $null
try {
    # ---- A. the palette ----------------------------------------------------
    ''
    'A. palette'
    $all = @()
    for ($i = 1; $i -le 9; $i++) {
        $c = Get-FrameLabCardColors -Index $i
        $all += [pscustomobject]@{ Name = "$i.Bg"; C = $c.Bg }
        $all += [pscustomobject]@{ Name = "$i.Ring"; C = $c.Ring }
        $all += [pscustomobject]@{ Name = "$i.Glyph"; C = $c.Glyph }
    }
    $close = @()
    for ($a = 0; $a -lt $all.Count; $a++) {
        for ($b = $a + 1; $b -lt $all.Count; $b++) {
            $d = Get-ChanDist $all[$a].C $all[$b].C
            if ($d -lt 64) { $close += "$($all[$a].Name)~$($all[$b].Name)=$d" }
        }
    }
    Assert 'A1 all 27 card colours are pairwise at least 64 apart on some channel' ($close.Count -eq 0) ($close -join ', ')
    $near = @()
    foreach ($x in $all) {
        foreach ($p in $script:FrameLabCardForbidden) {
            $d = Get-ChanDist $x.C $p
            if ($d -lt 64) { $near += ('{0}~0x{1:X6}={2}' -f $x.Name, $p, $d) }
        }
    }
    Assert 'A2 no card colour is within 64 of magenta, black, white or a common theme background' ($near.Count -eq 0) ($near -join ', ')
    $blend = @()
    for ($i = 1; $i -le 9; $i++) {
        $c = Get-FrameLabCardColors -Index $i
        $set = @($c.Bg, $c.Ring, $c.Glyph, $THEME)
        for ($a = 0; $a -lt $set.Count; $a++) {
            for ($b = $a + 1; $b -lt $set.Count; $b++) {
                $d = Get-SegmentDist $set[$a] $set[$b] $MAGENTA
                if ($d -lt 48) { $blend += ('card {0}: 0x{1:X6}..0x{2:X6} passes {3} from magenta' -f $i, $set[$a], $set[$b], [int]$d) }
            }
        }
    }
    Assert 'A3 no antialiasing blend inside a card (its colours and the theme padding) passes within 48 of magenta' ($blend.Count -eq 0) ($blend -join '; ')
    $digits = @($script:FrameLabDigits.Keys | Where-Object {
            $m = $script:FrameLabDigits[$_]
            -not ($m.Count -eq 5 -and @($m | Where-Object { $_.Length -eq 3 }).Count -eq 5 -and
                @($m | Where-Object { $_[0] -eq '#' }).Count -gt 0 -and @($m | Where-Object { $_[2] -eq '#' }).Count -gt 0 -and
                $m[0].Contains('#') -and $m[4].Contains('#'))
        })
    Assert 'A4 every digit fills its whole 3x5 box, so the glyph is the same size whatever the pane id' ($digits.Count -eq 0) ($digits -join ',')

    # ---- B. the drawing ----------------------------------------------------
    ''
    'B. the VT the card writes'
    $sizes = @(@(80, 24, 2), @(41, 17, 2), @(30, 12, 2), @(18, 9, 2), @(12, 6, 2), @(3, 3, 2), @(100, 30, 3))
    $cellBad = @(); $unwritten = @(); $unknown = @(); $overflow = @()
    foreach ($sz in $sizes) {
        $cols = $sz[0]; $rows = $sz[1]; $sc = $sz[2]
        foreach ($idx in 1, 7) {
            $vt = Format-FrameLabCard -Cols $cols -Rows $rows -Index $idx -Scale $sc
            $g = Invoke-VtPlayback -Vt $vt -Cols $cols -Rows $rows
            if ($g.Unknown.Count) { $unknown += "${cols}x$rows : $($g.Unknown -join ' ')" }
            if ($g.Overflow) { $overflow += "${cols}x$rows : $($g.Overflow)" }
            $col = Get-FrameLabCardColors -Index $idx
            $es = Get-FrameLabGlyphScale -Cols $cols -Rows $rows -Scale $sc
            $mask = $script:FrameLabDigits[[string]$idx]
            for ($r = 0; $r -lt $rows; $r++) {
                for ($c = 0; $c -lt $cols; $c++) {
                    if ($g.Ch[$r, $c] -eq [char]0) { $unwritten += "${cols}x$rows@$r,$c"; continue }
                    $k = Get-FrameLabCardCell -Row $r -Col $c -Cols $cols -Rows $rows -Mask $mask -Scale $es
                    $want = switch ($k) { 'R' { $col.Ring } 'G' { $col.Glyph } default { $col.Bg } }
                    if ($g.Bg[$r, $c] -ne $want -and $cellBad.Count -lt 6) {
                        $cellBad += ('{0}x{1} card {2} cell {3},{4}: 0x{5:X6}, expected {6} 0x{7:X6}' -f $cols, $rows, $idx, $r, $c, $g.Bg[$r, $c], $k, $want)
                    }
                }
            }
        }
    }
    Assert 'B1 every cell of every grid tried is exactly the colour the layout rule says' ($cellBad.Count -eq 0) ($cellBad -join '; ')
    Assert 'B2 the card writes every cell (nothing left showing what was there before)' ($unwritten.Count -eq 0) (($unwritten | Select-Object -First 5) -join ', ')
    Assert 'B3 the card writes only the sequences it means to (no stray escapes)' ($unknown.Count -eq 0) ($unknown -join '; ')
    Assert 'B4 nothing is written past the grid (autowrap off, every row addressed)' ($overflow.Count -eq 0) ($overflow -join '; ')
    $v80 = Format-FrameLabCard -Cols 80 -Rows 24 -Index 3
    $e = [string][char]27
    Assert 'B5 the card is one synchronized update with the cursor hidden and autowrap off' (
        $v80.StartsWith("$e[?2026h$e[?25l$e[?7l") -and $v80.EndsWith("$e[?2026l"))
    Assert 'B6 a grid too small for any glyph draws none, and says so with scale 0' (
        (Get-FrameLabGlyphScale -Cols 12 -Rows 6 -Scale 2) -eq 0 -and (Get-FrameLabGlyphScale -Cols 30 -Rows 12 -Scale 2) -eq 1 -and
        (Get-FrameLabGlyphScale -Cols 80 -Rows 24 -Scale 2) -eq 2)

    # Busy mode: the card's cells are untouched outside the busy rows, the busy
    # rows carry text in the Bg colour (real glyph work, no off-palette pixel) a
    # cell clear of the ring, and the text moves.
    $cols = 60; $rows = 26
    $mask = $script:FrameLabDigits['4']; $col = Get-FrameLabCardColors -Index 4
    $es = Get-FrameLabGlyphScale -Cols $cols -Rows $rows -Scale 2
    $busyRows = @(Get-FrameLabBusyRows -Rows $rows -GlyphScale $es)
    $g0 = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols $cols -Rows $rows -Index 4 -Busy -Tick 0) -Cols $cols -Rows $rows
    $g1 = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols $cols -Rows $rows -Index 4 -Busy -Tick 1) -Cols $cols -Rows $rows
    $bad = @(); $textCells = 0; $moved = $false; $glyphHit = $false
    for ($r = 0; $r -lt $rows; $r++) {
        for ($c = 0; $c -lt $cols; $c++) {
            $k = Get-FrameLabCardCell -Row $r -Col $c -Cols $cols -Rows $rows -Mask $mask -Scale $es
            if ($k -eq 'G' -and $busyRows -contains $r) { $glyphHit = $true }
            $want = switch ($k) { 'R' { $col.Ring } 'G' { $col.Glyph } default { $col.Bg } }
            if ($g0.Bg[$r, $c] -ne $want -and $bad.Count -lt 4) { $bad += "$r,$c" }
            if ($g0.Ch[$r, $c] -ne ' ' -and $g0.Ch[$r, $c] -ne [char]0) {
                $textCells++
                if ($g0.Fg[$r, $c] -ne $col.Bg -or $c -lt 2 -or $c -gt $cols - 3 -or $busyRows -notcontains $r) { if ($bad.Count -lt 4) { $bad += "text@$r,$c" } }
            }
            if ($g0.Ch[$r, $c] -ne $g1.Ch[$r, $c]) { $moved = $true }
        }
    }
    Assert 'B7 busy mode keeps every card colour, puts Bg-coloured text only in the busy rows a cell clear of the ring, and the text moves' (
        $bad.Count -eq 0 -and $textCells -gt 100 -and $moved -and -not $glyphHit -and $busyRows.Count -gt 3) "bad=$($bad -join ',') text=$textCells moved=$moved rows=$($busyRows.Count)"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($k = 0; $k -lt 5; $k++) { [void](Format-FrameLabCard -Cols 240 -Rows 70 -Index 2 -Busy -Tick $k) }
    $sw.Stop()
    $per = $sw.ElapsedMilliseconds / 5
    Assert 'B8 a 240x70 busy card is built in under 40 ms, so the card keeps up with a drag' ($per -lt 40) "$per ms per card"

    # ---- C. the contract with the scorer -----------------------------------
    ''
    'C. the scorer reads the card'
    $cw = 9; $ch = 18; $pl = 4; $pt = 3
    $cols = 44; $rows = 20
    $W = $pl + $cols * $cw + 6; $H = $pt + $rows * $ch + 11
    $card = New-ScoreBox 0 0 $W $H
    foreach ($busy in $false, $true) {
        $g = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols $cols -Rows $rows -Index 5 -Busy:$busy) -Cols $cols -Rows $rows
        $frame = ConvertTo-CardFrame $g $cols $rows $cw $ch $pl $pt $W $H
        $reg = New-FrameLabCardRegion -Card $card -Index 5 -Cols $cols -Rows $rows -CellW $cw -CellH $ch -PadLeft $pl -PadTop $pt -Extra @($THEME)
        $res = Measure-FrameBleed -Frame $frame -Scene (New-CardScene $reg)
        $what = $(if ($busy) { 'busy' } else { 'still' })
        Assert "C1 the $what card, rasterised, scores clean against its own region" ($res.Findings.Count -eq 0) (($res.Findings | Select-Object -First 4) -join '; ')
    }
    $g = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols $cols -Rows $rows -Index 5) -Cols $cols -Rows $rows
    $reg = New-FrameLabCardRegion -Card $card -Index 5 -Cols $cols -Rows $rows -CellW $cw -CellH $ch -PadLeft $pl -PadTop $pt -Extra @($THEME)

    # The erase control: one frame of solid magenta.
    $fm = ConvertTo-CardFrame $g $cols $rows $cw $ch $pl $pt $W $H
    $fm.Fill($card, $MAGENTA)
    $res = Measure-FrameBleed -Frame $fm -Scene (New-CardScene $reg)
    Assert 'C2 the erase control (a magenta frame) is caught as B1' ($res.Count('B1') -gt 0) "$($res.Classes())"

    # The stale control: the card drawn for the size the pane HAD (6 columns and
    # 3 rows smaller), presented into the pane at its new size.
    $og = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols ($cols - 6) -Rows ($rows - 3) -Index 5) -Cols ($cols - 6) -Rows ($rows - 3)
    $fs = ConvertTo-CardFrame $og ($cols - 6) ($rows - 3) $cw $ch $pl $pt $W $H
    $res = Measure-FrameBleed -Frame $fs -Scene (New-CardScene $reg)
    Assert 'C3 the stale-size control (last size''s card in the new pane) is caught as B2' ($res.Count('B2') -gt 0) "$($res.Classes())"

    # A stretch: the old frame scaled up to the new size, cells 3px wider.
    $fx = ConvertTo-CardFrame $og ($cols - 6) ($rows - 3) ($cw + 3) ($ch + 4) $pl $pt $W $H
    $res = Measure-FrameBleed -Frame $fx -Scene (New-CardScene $reg)
    Assert 'C4 a stretched old frame (cells scaled) is caught as B3' ($res.Count('B3') -gt 0) "$($res.Classes())"

    # A different pane's card in this pane's place is not this card.
    $go = Invoke-VtPlayback -Vt (Format-FrameLabCard -Cols $cols -Rows $rows -Index 6) -Cols $cols -Rows $rows
    $fo = ConvertTo-CardFrame $go $cols $rows $cw $ch $pl $pt $W $H
    $res = Measure-FrameBleed -Frame $fo -Scene (New-CardScene $reg)
    Assert 'C5 another pane''s card in this pane''s rect is flagged (the colours are pane-unique)' ($res.Findings.Count -gt 0) "$($res.Classes())"

    if ($PureOnly) {
        $script:skipped++
        '  SKIP D (on-box) by -PureOnly'
    } else {

    # ---- D. on the box -----------------------------------------------------
    ''
    'D. the real card and the planted defects, in the app'
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    . (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
    [void](Set-GhozttyTestIsolation -Tag 'labcard')
    Assert-GhozttyPrivateEndpoint -Exe $exe

    $cardPs = Join-Path $PSScriptRoot 'lib\lab-card.ps1'
    $out1 = Join-Path $env:TEMP "ghoztty-labcard-$PID-1.txt"
    $out2 = Join-Path $env:TEMP "ghoztty-labcard-$PID-2.txt"
    Remove-Item $out1, $out2 -ErrorAction SilentlyContinue
    $errlog = New-TestStdErrPath -Exe $exe

    # Plants armed late enough that the launch's own settling does not use them
    # up, early enough that the scripted resizes below reach every one.
    $env:GHOZTTY_LAB_PLANT = 'erase@8,stale@12,overlay@4'
    Start-TestForegroundWatch
    $td = New-TestDesktop -Interactive:$Interactive
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false',
        '--macos-pane-glass=false', '--unfocused-split-opacity=0.5',
        '-e', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cardPs, '-Index', '1', '-Out', $out1)
    Remove-Item Env:\GHOZTTY_LAB_PLANT -ErrorAction SilentlyContinue
    $appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no window' -Label 'frame-lab-card' }
    Assert 'D0 the GUI is not on the interactive desktop' (-not (Test-TestDesktopLeak -ProcessId $appPid))
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1100 -Height 700)

    function Wait-Card([string]$path, [string]$not) {
        for ($t = 0; $t -lt 80; $t++) {
            if (Test-Path $path) {
                $v = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
                if ($v -and $v.Trim() -ne $not) { return $v.Trim() }
            }
            Start-Sleep -Milliseconds 250
        }
        return $null
    }
    $s1 = Wait-Card $out1 ''
    Assert 'D1 the card came up in the launch pane and reported its grid' ($null -ne $s1) "no $out1"
    if (-not $s1) { throw 'card 1 never reported' }

    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    $names = @([regex]::Matches($json, '"name"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $pane1 = $null
    foreach ($n in $names) { if (Get-TestPaneCapture -Target $n) { $pane1 = $n; break } }
    Assert 'D2 the launch pane is addressable for capture' ($null -ne $pane1) "names=$($names -join ',') err=$(Get-LastPaneCaptureError)"
    if (-not $pane1) { throw 'no capturable pane' }

    & $exe +split --target=$pane1 --direction=right --name=labcard2 -e powershell -NoProfile -ExecutionPolicy Bypass -File $cardPs -Index 2 -Busy -Out $out2 2>&1 | Out-Null
    $s2 = Wait-Card $out2 ''
    Assert 'D3 a second card (busy) came up in a split' ($null -ne $s2) "no $out2"
    Start-Sleep -Milliseconds 1200

    # Photograph a card and score it against the region its reported grid and
    # the measured cell size predict.
    function Test-RealCard([string]$target, [string]$out, [int]$index, [string]$label) {
        $st = (Get-Content $out -Raw).Trim() -split ' '
        $cols = [int]$st[0]; $rows = [int]$st[1]
        $shot = $null
        for ($t = 0; $t -lt 10 -and -not $shot; $t++) { $shot = Get-TestPaneCapture -Target $target; if (-not $shot) { Start-Sleep -Milliseconds 300 } }
        if (-not $shot) { Assert "$label capture" $false (Get-LastPaneCaptureError); return }
        try {
            $f = ConvertTo-ScoreFrame -Bitmap $shot.Bitmap
            $c = Get-FrameLabCardColors -Index $index
            # The ring's box and thickness, read off the pixels along the two
            # centre lines (the glyph and text are other colours, so the first
            # ring pixel in from each edge IS the ring).
            $isRing = { param($x, $y) (Get-ChanDist $f.At($x, $y) $c.Ring) -le 8 }
            $mx = [int]($f.W / 2); $my = [int]($f.H / 2)
            $x0 = 0; while ($x0 -lt $f.W -and -not (& $isRing $x0 $my)) { $x0++ }
            $x1 = $f.W - 1; while ($x1 -ge 0 -and -not (& $isRing $x1 $my)) { $x1-- }
            $y0 = 0; while ($y0 -lt $f.H -and -not (& $isRing $mx $y0)) { $y0++ }
            $y1 = $f.H - 1; while ($y1 -ge 0 -and -not (& $isRing $mx $y1)) { $y1-- }
            $cw = 0; while ($x0 + $cw -lt $f.W -and (& $isRing ($x0 + $cw) $my)) { $cw++ }
            $chh = 0; while ($y0 + $chh -lt $f.H -and (& $isRing $mx ($y0 + $chh))) { $chh++ }
            $bw = $x1 - $x0 + 1; $bh = $y1 - $y0 + 1
            Assert "$label the ring box is exactly the reported grid (${cols}x$rows cells of ${cw}x$chh px)" (
                $cw -gt 2 -and $chh -gt 4 -and $bw -eq $cols * $cw -and $bh -eq $rows * $chh) "ring box ${bw}x$bh at $x0,$y0 in $($f.W)x$($f.H)"
            $reg = New-FrameLabCardRegion -Card (New-ScoreBox 0 0 $f.W $f.H) -Index $index -Cols $cols -Rows $rows -CellW $cw -CellH $chh -PadLeft $x0 -PadTop $y0 -Extra @($THEME)
            $res = Measure-FrameBleed -Frame $f -Scene (New-CardScene $reg)
            Assert "$label the real card scores clean" ($res.Findings.Count -eq 0) (($res.Findings | Select-Object -First 4) -join '; ')
        } finally { Close-TestPaneCapture $shot }
    }
    Test-RealCard $pane1 $out1 1 'D4 card 1:'
    Test-RealCard 'labcard2' $out2 2 'D5 card 2 (busy):'

    # The plants: resize the window in steps, as a drag does.
    for ($i = 1; $i -le 24; $i++) {
        $w = 1100 - 12 * $i
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height (700 - 4 * $i))
        Start-Sleep -Milliseconds 70
    }
    Start-Sleep -Milliseconds 1500
    $fired = @()
    for ($t = 0; $t -lt 20; $t++) {
        $fired = @(Get-Content $errlog -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_ -match 'lab plant fired kind=(\w+) n=(\d+) qpc=(\d+)') { [pscustomobject]@{ Kind = $Matches[1]; N = [int]$Matches[2]; Qpc = [uint64]$Matches[3] } }
            })
        if (@($fired | Where-Object Kind -eq 'overlay').Count -gt 0 -and @($fired | Where-Object Kind -eq 'stale').Count -ge 2) { break }
        Start-Sleep -Milliseconds 250
    }
    $armed = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'lab plant armed erase=8 stale=12 overlay=4' })
    Assert 'D6 the app read GHOZTTY_LAB_PLANT and said what it armed' ($armed.Count -ge 1)
    $er = @($fired | Where-Object Kind -eq 'erase'); $sl = @($fired | Where-Object Kind -eq 'stale'); $ov = @($fired | Where-Object Kind -eq 'overlay')
    Assert 'D7 the magenta erase fired once per pane, on each pane''s 8th resize frame' ($er.Count -eq 2 -and @($er | Where-Object N -ne 8).Count -eq 0) "$($er.Count) fire(s): $(($er | ForEach-Object { $_.N }) -join ',')"
    Assert 'D8 the stale-size frame fired once per pane, on its 12th resize frame' ($sl.Count -eq 2 -and @($sl | Where-Object N -ne 12).Count -eq 0) "$($sl.Count) fire(s): $(($sl | ForEach-Object { $_.N }) -join ',')"
    Assert 'D9 the overlay hold fired once, on the dim wash''s 4th move' ($ov.Count -eq 1 -and $ov[0].N -eq 4) "$($ov.Count) fire(s)"
    Assert 'D10 every fire carries a capture-clock timestamp' (@($fired | Where-Object { $_.Qpc -eq 0 }).Count -eq 0 -and $fired.Count -gt 0)

    # One-shot and clean afterwards: the wash sits on its pane again, and both
    # panes render a correct card at their final size.
    Start-Sleep -Milliseconds 800
    $washes = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyDimOverlay')
    $terms = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' | Where-Object { $_.Visible })
    $glued = $false
    foreach ($wsh in @($washes | Where-Object Visible)) {
        foreach ($tm in $terms) {
            if ($wsh.Left -eq $tm.Left -and $wsh.Right -eq $tm.Right -and $wsh.Top -le $tm.Top -and $wsh.Bottom -eq $tm.Bottom) { $glued = $true }
        }
    }
    Assert 'D11 the held dim wash caught up and sits on its pane again' $glued "washes=$(($washes | ForEach-Object { "$($_.Left),$($_.Top)-$($_.Right),$($_.Bottom) v=$($_.Visible)" }) -join ' ') panes=$(($terms | ForEach-Object { "$($_.Left),$($_.Top)-$($_.Right),$($_.Bottom)" }) -join ' ')"
    [void](Wait-Card $out1 $s1)
    Test-RealCard $pane1 $out1 1 'D12 card 1 after the plants:'
    Test-RealCard 'labcard2' $out2 2 'D13 card 2 after the plants:'

    Assert 'D14 the GUI survived' (-not $app.Process.HasExited)
    $fgSeen = @(Stop-TestForegroundWatch)
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    Assert 'D15 the run never took the user''s foreground' ($leaked.Count -eq 0) ($leaked -join ', ')
    }

    Complete-TestBody
}
finally {
    foreach ($b in $bitmaps) { if ($b) { $b.Dispose() } }
    Remove-Item Env:\GHOZTTY_LAB_PLANT -ErrorAction SilentlyContinue
    if (-not $PureOnly) {
        [void](Stop-RepoGhoztty -Exe $exe -SettleMs 400)
        if ($td) { Remove-TestDesktop $td }
        Remove-Item $out1, $out2, "$out1.tmp", "$out2.tmp" -ErrorAction SilentlyContinue
    }
}

if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-card -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2383 FRAME-LAB-CARD' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
