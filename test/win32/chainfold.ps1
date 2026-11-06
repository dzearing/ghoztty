<#
.SYNOPSIS
  Acceptance test for test\win32\lib\ChainFoldOracle.ps1 (T2485) - the
  frame-by-frame oracle for the user's chain-fold drag: six panes side by side,
  one divider dragged right until three of them fold into blades in turn.

.DESCRIPTION
  T2485 closes only when four checks hold over EVERY composed frame of a
  release capture (the task file has the user's words for each):

    a. no flash: no band of the window blinks for a frame (and no column is
       a pure-black hole nothing painted);
    b. no novel colour: nothing mid-drag wears a colour neither end state
       has (the light rim on the folding pane);
    c. no final jump: each run of motion ends on a step no bigger than 1.5x
       its median step;
    d. no stall: while the pointer moves, never more than 16.7 ms without a
       new picture.

  Without -Live this proves the ORACLE, on frames whose truth is known, so a
  live verdict means what it says:

    A. a clean synthetic tween (a pane gliding with ease-out past a still
       blade) scores nothing on any check;
    B. each defect planted on its own copy is found on exactly the frames it
       was planted on and by its own check: a blade flash, a black column, a
       light rim, a last-frame jump - and a colour on screen for the whole
       drag (the grabbed divider's accent) is NOT a novel colour;
    C. the stall check, on a frame list: a still stretch while the pointer
       moves is a gap of its length, a stretch with a frame missing is Blind
       rather than passed, and steady motion is clean;
    D. the run-directory scorer end to end (geometry.json, timeline.json,
       PNG frames written to temp): press and release found, the planted hole
       found on its frame, the stall found where it was planted.

  -Live (opt-in, never a sweep: it moves the real pointer) records the user's
  scenario on a RELEASE build in the release sandbox with
  docs\design\t2485-chainfold\tools\record-chainfold.ps1 and scores it: one
  assertion per check. A red there is a finding about the APP for T2485, and a
  -Live run never stamps. It needs nobody at the box (SKIP ALL otherwise).

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\chainfold.ps1
  powershell -NoProfile -File test\win32\chainfold.ps1 -Live -Exe temp\t2485-rel\bin\ghoztty.exe [-WinW 3000 -WinH 1700]
#>
[CmdletBinding()]
param(
    [switch]$Live,
    [string]$Exe = '',
    [int]$WinW = 1600,
    [int]$WinH = 800
)

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
. (Join-Path $PSScriptRoot 'lib\ChainFoldOracle.ps1')
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ---- the synthetic world -------------------------------------------------
# 200x120, four bands of 50 px. A 40x80 pane with text-like stripes glides
# from x=20 to x=110 with ease-out over 20 frames, then holds for 6; a 16 px
# blade stands still at x=170 (band 3) the whole time.
$W = 200; $H = 120
$Bg = 0x30303A; $PaneBg = 0x282C34; $Ink = 0xC8C8C8; $Blade = 0x506070; $BladeInk = 0xE0E0E0
$Glide = 20; $Hold = 6
function Get-PaneX([int]$k) {
    if ($k -ge $Glide) { return 110 }
    $t = $k / ($Glide - 1.0)
    return [int][math]::Round(20 + 90 * (1 - (1 - $t) * (1 - $t)))
}
function New-SynthFrame([int]$k, [hashtable]$Plant = @{}) {
    $f = [CfFrame]::Solid($W, $H, $Bg)
    $x = Get-PaneX $k
    if ($Plant.ContainsKey('jump') -and $k -ge $Plant['jump']) { $x += 12 }
    $f.Fill($x, 20, 40, 80, $PaneBg)
    for ($r = 0; $r -lt 8; $r++) { $f.Fill($x + 3, 24 + $r * 10, 30 - ($r % 3) * 6, 3, $Ink) }
    if ($Plant.ContainsKey('rim') -and $Plant['rim'] -contains $k) {
        $f.Fill($x - 2, 18, 44, 2, 0xE8E8F0); $f.Fill($x - 2, 100, 44, 2, 0xE8E8F0)
        $f.Fill($x - 2, 18, 2, 84, 0xE8E8F0); $f.Fill($x + 40, 18, 2, 84, 0xE8E8F0)
    }
    if (-not ($Plant.ContainsKey('flash') -and $k -eq $Plant['flash'])) {
        $f.Fill(170, 20, 16, 80, $Blade); $f.Fill(173, 30, 10, 3, $BladeInk); $f.Fill(173, 40, 10, 3, $BladeInk)
    }
    if ($Plant.ContainsKey('black') -and $k -eq $Plant['black']) { $f.Fill(100, 0, 3, $H, 0x000000) }
    if ($Plant.ContainsKey('accent') -and $k -gt 0 -and $k -lt ($Glide + $Hold - 1)) { $f.Fill([int]($x + 41), 0, 3, $H, 0xA94DC1) }
    # T2535: the accent already lit on the press frame (hover), with its
    # anti-aliased edge a 1 px column whose blend changes colour as it moves
    if ($Plant.ContainsKey('hover') -and $k -lt ($Glide + $Hold - 1)) { $f.Fill([int]($x + 41), 0, 3, $H, 0xA94DC1) }
    if (($Plant.ContainsKey('hover') -or $Plant.ContainsKey('edge')) -and $k -lt ($Glide + $Hold - 1)) { $f.Fill([int]($x + 44), 0, 1, $H, (0x403060 + ($k % 6) * 0x100000)) }
    if ($Plant.ContainsKey('accentOff') -and $k -eq $Plant['accentOff']) { $f.Fill([int]($x + 41), 0, 4, $H, $Plant['offColour']) }
    # T2535: a GPU overlay's toast (brand bar, dark panel, logo, grey text) over the blade
    if ($Plant.ContainsKey('toast') -and $Plant['toast'] -contains $k) {
        $f.Fill(150, 25, 50, 70, 0x040607); $f.Fill(150, 25, 4, 70, 0x76B900); $f.Fill(158, 40, 12, 14, 0x3E5A0F)
        $f.Fill(175, 45, 18, 2, 0xA0A0A0); $f.Fill(175, 60, 14, 2, 0xA0A0A0)
    }
    # T2535: a still strip crossfading from the backdrop to its rest colour
    # (or, 'fadeOver', overshooting to a light line mid-fade)
    if ($Plant.ContainsKey('fade')) {
        $t = $k / ($Glide + $Hold - 1.0)
        $c = Get-Mix $Bg 0x8090A0 $t
        if ($Plant['fade'] -eq 'over' -and $k -ge 8 -and $k -le 14) { $c = 0xE8E8F0 }
        $f.Fill(60, 0, 8, $H, $c)
    }
    return $f
}
function Get-Mix([int]$a, [int]$b, [double]$t) {
    $o = 0
    foreach ($sh in 16, 8, 0) { $ca = ($a -shr $sh) -band 255; $cb = ($b -shr $sh) -band 255; $o = $o -bor ([int][math]::Round($ca + ($cb - $ca) * $t) -shl $sh) }
    return $o
}
function Invoke-SynthScan([hashtable]$Plant = @{}, [switch]$NoOverlay) {
    $s = New-ChainFoldScan -X0 0 -Y0 0 -X1 $W -Y1 $H -Bands 4
    if ($NoOverlay) { $s.DetectOverlay = $false }
    for ($k = 0; $k -lt ($Glide + $Hold); $k++) { $s.Add($k, (New-SynthFrame $k $Plant)) }
    $s.PrepareRims()
    $rims = @(); for ($k = 0; $k -lt ($Glide + $Hold); $k++) { $rims += @($s.Rim($k, (New-SynthFrame $k $Plant))) }
    return [pscustomobject]@{ Flashes = @($s.Flashes()); Black = @($s.Black); Novel = @($s.Novel()); Rims = $rims; Final = @($s.FinalSteps()); Motion = @($s.MotionFrames()); Overlays = @($s.Overlays) }
}
function Format-Found($r) { return "flash=[$(@($r.Flashes) -join '; ')] black=[$(@($r.Black) -join '; ')] novel=[$(@($r.Novel | ForEach-Object { "f$($_.Frame)" }) -join ',')] rims=[$(@($r.Rims | ForEach-Object { "f$($_.Frame)" } | Select-Object -Unique) -join ',')] final=[$(@($r.Final) -join '; ')]" }

try {
    if (-not $Live) {
        # ---- A. a clean tween scores nothing -----------------------------
        'A. a clean synthetic tween (a pane gliding with ease-out past a still blade)'
        $clean = Invoke-SynthScan
        $want = @(1..($Glide - 1) | Where-Object { (Get-PaneX $_) -ne (Get-PaneX ($_ - 1)) })
        Assert 'A1 the glide is seen moving: motion on every frame the pane moved, none on the hold' (
            ($clean.Motion -join ',') -eq ($want -join ',')) "motion=$($clean.Motion -join ',') want=$($want -join ',')"
        Assert 'A2 the clean tween has no flash, no black column, no novel colour and no final jump' (
            $clean.Flashes.Count -eq 0 -and $clean.Black.Count -eq 0 -and $clean.Novel.Count -eq 0 -and $clean.Rims.Count -eq 0 -and $clean.Final.Count -eq 0) (Format-Found $clean)

        # ---- B. each plant on exactly its frames -------------------------
        ''
        'B. planted defects: each found on exactly its frames, by its own check'
        $r = Invoke-SynthScan @{ flash = 12 }
        Assert 'B1 the still blade blanked for one frame (f12) is a flash in its band (3) and nothing else' (
            $r.Flashes.Count -eq 1 -and $r.Flashes[0].Frame -eq 12 -and $r.Flashes[0].Band -eq 3 -and $r.Black.Count -eq 0 -and $r.Final.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ black = 8 }
        Assert 'B2 a 3 px pure-black column on f8 is a black finding at exactly x100-102' (
            $r.Black.Count -eq 1 -and $r.Black[0].Frame -eq 8 -and $r.Black[0].Detail -eq 'x100-102') (Format-Found $r)
        Assert 'B2b ...and is not ALSO a rim (T2535: run49 reported each of its 32 black strips twice)' ($r.Rims.Count -eq 0) (Format-Found $r)
        $rim = @(5..12)
        $r = Invoke-SynthScan @{ rim = $rim }
        $nf = @($r.Rims | ForEach-Object { $_.Frame } | Select-Object -Unique)
        Assert 'B3 a light rim on the gliding pane for f5-f12 - one step from the blade''s white ink, so the area check forgives it - is a rim on exactly f5-f12' (
            ($nf -join ',') -eq ($rim -join ',') -and $r.Flashes.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ jump = ($Glide - 1) }
        Assert "B4 the glide's last frame (f$($Glide - 1)) snapping 12 px further, where it then stays, is a final jump on that frame and nowhere else" (
            $r.Final.Count -ge 1 -and @($r.Final | Where-Object { $_.Frame -ne ($Glide - 1) }).Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ accent = $true }
        Assert "B5 a colour riding the drag from start to end (the grabbed divider's accent) is NOT novel" (
            $r.Novel.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ accent = $true; rim = $rim }
        Assert 'B5b ...nor a rim' ((Invoke-SynthScan @{ accent = $true }).Rims.Count -eq 0) ''
        $nf = @($r.Rims | ForEach-Object { $_.Frame } | Select-Object -Unique)
        Assert 'B6 ...and does not hide a rim that appears beside it (f5-f12 still found)' (($nf -join ',') -eq ($rim -join ',')) (Format-Found $r)

        # ---- T2535: what the near-full-monitor captures misread ----------
        $r = Invoke-SynthScan @{ edge = $true }
        Assert 'B10a negative control: the accent''s 1 px anti-aliased edge alone (its blend changes colour as it moves) IS a rim' ($r.Rims.Count -gt 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ hover = $true }
        Assert 'B10 ...but beside an accent already lit on the press frame (the divider was hovered) it is the accent''s edge, not a rim (run49: 93 such)' ($r.Rims.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ hover = $true; rim = $rim }
        $nf = @($r.Rims | ForEach-Object { $_.Frame } | Select-Object -Unique)
        Assert 'B10b ...and that does not hide a rim on the pane (f5-f12 still found)' (($nf -join ',') -eq ($rim -join ',')) (Format-Found $r)
        $toast = @(4..15)
        $r = Invoke-SynthScan @{ toast = $toast } -NoOverlay
        Assert 'B11a negative control: a GPU overlay''s toast over the blade (f4-f15), unrecognised, IS novel colour and a rim' (
            $r.Novel.Count -gt 0 -and $r.Rims.Count -gt 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ toast = $toast }
        $of = @($r.Overlays | ForEach-Object { $_.Frame } | Select-Object -Unique)
        Assert 'B11 ...recognised by its brand bar on exactly f4-f15, it is neither (run48/run49: NVIDIA "Press Alt+Z", #447700)' (
            $r.Novel.Count -eq 0 -and $r.Rims.Count -eq 0 -and ($of -join ',') -eq ($toast -join ',')) "overlay=[$($of -join ',')] $(Format-Found $r)"
        $r = Invoke-SynthScan @{ toast = $toast; rim = $rim }
        $nf = @($r.Rims | ForEach-Object { $_.Frame } | Select-Object -Unique)
        Assert 'B11b ...and the overlay does not hide a rim on the pane outside it (f5-f12 still found)' (($nf -join ',') -eq ($rim -join ',')) (Format-Found $r)
        $r = Invoke-SynthScan @{ fade = 'in' }
        Assert 'B12 a still strip crossfading from the backdrop to its rest colour is not a rim: every mid colour is between that pixel''s own end colours (run49 f322-f325 class)' ($r.Rims.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ fade = 'over' }
        Assert 'B12b ...but the same strip turning light mid-fade, outside its own end colours, is a rim' ($r.Rims.Count -gt 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ accent = $true; accentOff = 9; offColour = 0xAA44BB }
        Assert 'B13 the accent drawn one step off (#AA44BB for #A94DC1) for one frame is an accent blend, not novel (run48 f90)' ($r.Novel.Count -eq 0) (Format-Found $r)
        $r = Invoke-SynthScan @{ accent = $true; accentOff = 9; offColour = 0xA933A1 }
        Assert 'B13b ...but two steps off it is novel, on that frame' (
            $r.Novel.Count -eq 1 -and $r.Novel[0].Frame -eq 9) (Format-Found $r)

        # Fine text (1 px strokes) saturates the band mean, so uneven steps of
        # a correct glide read as blinks unless the shift explains them (live
        # 20261031-230739 f82/f94); a real blink must survive that.
        # The text spans every band (a pane wider than the band, as live), so
        # only the strokes move; a grey blank covers the middle of the frame.
        # Monospace-like: 10 px cells, each with 1-3 strokes at seeded random
        # places. A regular grid realigns every period and makes p and n
        # truly agree; uniform noise never lets the raw rule fire at all.
        $TextX = @(0, 3, 12, 15, 24, 27, 36, 39, 48, 51, 60, 63, 72, 75, 84, 87, 96, 96, 96, 96)
        $rng = New-Object System.Random 2485
        $Strokes = @(); for ($c = -15; $c -lt 40; $c++) { for ($r = 0; $r -lt 12; $r++) { for ($j = $rng.Next(1, 4); $j -gt 0; $j--) { $Strokes += , @(($c * 10 + $rng.Next(0, 9)), $r) } } }
        function New-TextFrame([int]$x, [bool]$Gray = $false) {
            $f = [CfFrame]::Solid($W, $H, $PaneBg)
            foreach ($s in $Strokes) { $f.Fill($x + $s[0], 14 + $s[1] * 8, 1, 6, $Ink) }
            if ($Gray) { $f.Fill(60, 10, 80, 100, 0x808080) }
            return $f
        }
        function Invoke-TextScan([int[]]$Xs, [int]$GrayAt = -1) {
            $s = New-ChainFoldScan -X0 0 -Y0 0 -X1 $W -Y1 $H -Bands 4
            for ($k = 0; $k -lt $Xs.Count; $k++) { $s.Add($k, (New-TextFrame $Xs[$k] ($k -eq $GrayAt))) }
            return [pscustomobject]@{ Flashes = @($s.Flashes()); Moved = @($s.Explained()) }
        }
        $r = Invoke-TextScan $TextX
        Assert 'B7 fine text gliding in uneven steps (+3, +9, ...) is not a flash, and the raw rule did see candidates there (negative control)' (
            $r.Flashes.Count -eq 0 -and $r.Moved.Count -gt 0) "flash=[$(@($r.Flashes) -join '; ')] moved=$($r.Moved.Count)"
        $r = Invoke-TextScan $TextX -GrayAt 9
        Assert 'B8 ...but the same glide with the pane blanked grey on f9 is still a flash on f9' (
            @($r.Flashes | Where-Object { $_.Frame -eq 9 }).Count -ge 1 -and @($r.Flashes | Where-Object { $_.Frame -ne 9 }).Count -eq 0) "flash=[$(@($r.Flashes) -join '; ')]"
        $r = Invoke-TextScan @(60, 60, 60, 60, 61, 60, 60, 60, 60)
        Assert 'B9 ...and a still pane shaking by one pixel for one frame (D19, a->b->a) is a flash on that frame, not explained away as motion' (
            @($r.Flashes | Where-Object { $_.Frame -eq 4 }).Count -ge 1 -and @($r.Flashes | Where-Object { $_.Frame -ne 4 }).Count -eq 0) "flash=[$(@($r.Flashes) -join '; ')] moved=$($r.Moved.Count)"

        # ---- C. the stall check -------------------------------------------
        ''
        'C. criterion d on a frame list (120 Hz, 10 MHz clock)'
        $F = 10000000; $per = [long]($F / 120)
        function New-FrameList([int]$n, [int[]]$Still = @(), [int[]]$Missing = @(), [int[]]$Unscanned = @()) {
            $o = @()
            for ($i = 0; $i -lt $n; $i++) {
                if ($Missing -contains $i) { continue }
                $o += [pscustomobject]@{ Qpc = [long](1000000 + $i * $per); Scanned = -not ($Unscanned -contains $i); Moved = -not ($Still -contains $i) }
            }
            return , $o
        }
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C1 a new picture every refresh: no gap, nothing blind' ($g.Gaps.Count -eq 0 -and $g.Blind -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',') blind=$($g.Blind)"
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(20, 21, 22)) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C2 three still refreshes while moving is ONE gap of 33.3 ms' ($g.Gaps.Count -eq 1 -and $g.Gaps[0].Ms -eq 33.3 -and $g.Blind -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',') blind=$($g.Blind)"
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(20)) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C3 one still refresh (16.7 ms between pictures) is within the limit' ($g.Gaps.Count -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',')"
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(20) -Missing @(21)) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C4 25 ms between pictures with a frame missing from it, and no still frame proving the stall, is Blind, not passed and not a gap' ($g.Gaps.Count -eq 0 -and $g.Blind -eq 1) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',') blind=$($g.Blind)"
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(30, 31) -Unscanned @(31)) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C5 ...and so is one with a frame that has no picture' ($g.Gaps.Count -eq 0 -and $g.Blind -eq 1) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',') blind=$($g.Blind)"
        # T2535: at ~3700 px WGC hands over a frame every 2-3 refreshes, so
        # nearly every span had a hole and d went blind on 35 of them.
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(20, 21, 22) -Missing @(23)) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C7 a hole AFTER three still frames is a proven gap of at least those 25 ms (the screen says so), not Blind' (
            $g.Gaps.Count -eq 1 -and $g.Gaps[0].Ms -eq 25.0 -and $g.Gaps[0].Source -eq 'screen' -and $g.Blind -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { "$($_.Source):$($_.Ms)" }) -join ',') blind=$($g.Blind)"
        $sparse = @(0..59 | Where-Object { $_ % 3 -ne 0 })
        $steady = [long[]]@(0..59 | ForEach-Object { [long](1000000 + $_ * $per - 1000) })
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Missing $sparse) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue)
        Assert 'C8a negative control: a capture handing over every third refresh, alone, is Blind on every 25 ms span (19)' ($g.Blind -eq 19 -and $g.Gaps.Count -eq 0) "gaps=$($g.Gaps.Count) blind=$($g.Blind)"
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Missing $sparse) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue) -AppQpc $steady
        Assert 'C8 ...with the app''s layout batches every refresh, every span is Resolved: nothing blind, no gap' (
            $g.Blind -eq 0 -and $g.Gaps.Count -eq 0 -and $g.Resolved -eq 19) "gaps=$($g.Gaps.Count) blind=$($g.Blind) resolved=$($g.Resolved)"
        $stalled = [long[]]@($steady | Where-Object { $_ -ne $steady[31] -and $_ -ne $steady[32] })
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Missing $sparse) -Frequency $F -FromQpc 0 -ToQpc ([long]::MaxValue) -AppQpc $stalled
        Assert 'C9 ...and with two batches missing (25 ms between batches 30 and 33) it is ONE app gap of 25 ms' (
            $g.Gaps.Count -eq 1 -and $g.Gaps[0].Source -eq 'app' -and $g.Gaps[0].Ms -eq 25.0 -and $g.Blind -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { "$($_.Source):$($_.AtMs)+$($_.Ms)" }) -join ',') blind=$($g.Blind)"
        $log = Join-Path $env:TEMP "chainfold-trace-$PID.log"
        [IO.File]::WriteAllLines($log, @('info(win32): stack trace place hwnd=1 grid=0,0+1x1', 'info(win32): stack trace batch qpc=100 end=150 plan=90 grid=95', 'noise', 'info(win32): stack trace batch qpc=200 end=260 plan=190 grid=195'))
        try { $st = Get-ChainFoldAppStamps -Path $log } finally { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
        Assert 'C10 the app''s batches are read from a ring-trace log as their end stamps (150, 260)' (($st -join ',') -eq '150,260') "stamps=$($st -join ',')"
        $none = Get-ChainFoldAppStamps -Path (Join-Path $env:TEMP 'no-such-chainfold.log')
        Assert 'C10b ...and a missing log is no stamps, not an error' ($null -ne $none -and $none.Count -eq 0) ''
        $g = Get-ChainFoldGaps -Frames (New-FrameList 60 -Still @(20, 21, 22)) -Frequency $F -FromQpc ([long](1000000 + 30 * $per)) -ToQpc ([long]::MaxValue)
        Assert 'C6 a stall outside the measured span does not count' ($g.Gaps.Count -eq 0) "gaps=$(@($g.Gaps | ForEach-Object { $_.Ms }) -join ',')"

        # ---- D. the run-directory scorer, end to end ----------------------
        ''
        'D. Invoke-ChainFoldOracle over a written run directory'
        $dir = Join-Path $repo "temp\chainfold-synth-$PID"
        $fdir = Join-Path $dir 'frames'
        $null = New-Item -ItemType Directory -Force -Path $fdir
        try {
            # Frames 0-1 before the press, the glide 2-21 with the pointer
            # moving (and a 3-refresh stall at 9-11 that repeats frame 8), the
            # hold 22-31 after the release. A black column on f15.
            $q0 = [long]5000000; $tlist = @(); $k = 0
            for ($i = 0; $i -lt 32; $i++) {
                $k = [math]::Max(0, [math]::Min($i - 2, $Glide + $Hold - 1))
                if ($i -ge 9 -and $i -le 11) { $k = 6 }
                $plant = $(if ($i -eq 15) { @{ black = $k } } else { @{} })
                $png = Join-Path $fdir ('f{0:D6}-sample.png' -f $i)
                (New-SynthFrame $k $plant).Save($png)
                $tlist += [ordered]@{ i = $i; qpc = $q0 + $i * $per; png = $png; sup = $false }
            }
            $stamps = @()
            $stamps += [ordered]@{ qpc = $q0 + 1 * $per + 10; x = 50; y = 60; flags = 1 }
            for ($i = 2; $i -le 21; $i++) { $stamps += [ordered]@{ qpc = $q0 + $i * $per; x = 50 + $i * 4; y = 60; flags = 0 } }
            $stamps += [ordered]@{ qpc = $q0 + 22 * $per + 10; x = 134; y = 60; flags = 2 }
            $meta = [ordered]@{ freq = $F; stats = [ordered]@{ QueueDropped = 0; RefreshHz = 120 }; timeline = $tlist; stamps = $stamps }
            [IO.File]::WriteAllText((Join-Path $dir 'timeline.json'), ($meta | ConvertTo-Json -Depth 6))
            $geo = [ordered]@{ window = @(0, 0, $W, $H); panes = @([ordered]@{ X = 0; Y = 0; W = 40; H = $H + 40 }) }
            [IO.File]::WriteAllText((Join-Path $dir 'geometry.json'), ($geo | ConvertTo-Json -Depth 6))
            $o = Invoke-ChainFoldOracle -RunDir $dir -SettleMs 80 -Bands 4
            Assert 'D1 the frames scored run from the press (f2) to the end of the settle' ($o.FirstFrame -eq 2 -and $o.LastFrame -ge 22) "first=$($o.FirstFrame) last=$($o.LastFrame) n=$($o.Frames)"
            Assert 'D2 the black column planted on f15 is found there, and only there' (
                @($o.Black).Count -eq 1 -and $o.Black[0].Frame -eq 15) "black=$(@($o.Black) -join '; ')"
            Assert 'D3 the stall planted at f9-f11 (pointer moving, picture still) is one gap of over 16.7 ms' (
                @($o.Gaps).Count -eq 1 -and $o.Gaps[0].Ms -gt 16.7 -and $o.GapBlind -eq 0) "gaps=$(@($o.Gaps | ForEach-Object { "$($_.AtMs)+$($_.Ms)" }) -join ',') blind=$($o.GapBlind)"
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        # ---- L. the user's scenario on a release build --------------------
        # Moves the real pointer over the user's screen: opt-in, never a sweep.
        . (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
        Assert-UserAbsent
        if (-not $Exe -or -not (Test-Path $Exe)) { throw "-Live needs -Exe <a ReleaseFast ghoztty.exe outside the install>, got '$Exe'" }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $out = Join-Path $repo "temp\chainfold-live\$stamp"
        'L. live: the chain-fold drag on a release build, every frame'
        # Keep the app's ring trace with every live run: a red frame is only
        # worth the idle slot it cost if ringmap.py can say what committed in it
        # (2026-11-01: a near-full run went red with no app.log to map).
        $priorTrace = $env:GHOZTTY_STACK_TRACE
        $env:GHOZTTY_STACK_TRACE = 'ring'
        try {
            $rec = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'docs\design\t2485-chainfold\tools\record-chainfold.ps1') -Exe $Exe -Out $out -WinW $WinW -WinH $WinH -QueueGB $(if ($WinW -gt 2000) { 16 } else { 3 }) -StdErr (Join-Path $out 'app.log') 2>&1 | ForEach-Object { "$_" }
        } finally { $env:GHOZTTY_STACK_TRACE = $priorTrace }
        $rec | ForEach-Object { "  $_" }
        if (@($rec | Where-Object { $_ -match '^SKIP' }).Count -gt 0) {
            "  SKIP L: the recorder did not record (above)"
            $script:skipped++
        } else {
            $o = Invoke-ChainFoldOracle -RunDir $out
            "  scored f$($o.FirstFrame)-f$($o.LastFrame) ($($o.Frames) frames, $($o.Dropped) dropped by the PNG queue) in $out"
            @($o.Explained) | ForEach-Object { "  explained as motion (not a blink): $_" }
            Assert 'La no frame where a band blinks' (@($o.Flashes).Count -eq 0) (@($o.Flashes | Select-Object -First 6) -join '; ')
            Assert 'La no pure-black hole in any frame' (@($o.Black).Count -eq 0) (@($o.Black | Select-Object -First 6) -join '; ')
            Assert 'Lb no colour mid-drag that neither end state has' (@($o.Novel).Count -eq 0) (@($o.Novel | Select-Object -First 4) -join '; ')
            Assert 'Lb no rim: no such colour forms a line' (@($o.Rims).Count -eq 0) (@($o.Rims | Select-Object -First 6) -join '; ')
            Assert 'Lc no run of motion ends on a jump' (@($o.Final).Count -eq 0) (@($o.Final | Select-Object -First 6) -join '; ')
            Assert 'Ld no stall over 16.7 ms while the pointer moves, and none unmeasured' (@($o.Gaps).Count -eq 0 -and $o.GapBlind -eq 0) "gaps=$(@($o.Gaps | Select-Object -First 8 | ForEach-Object { "$($_.AtMs)ms+$($_.Ms)" }) -join ',') blind=$($o.GapBlind)"
        }
    }

    Complete-TestBody
}
finally { }

# A green synthetic run stamps the covered files (T783); a live run never does,
# and red or skipped stays due.
if (-not $Live -and $script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chainfold -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2485 CHAINFOLD' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
