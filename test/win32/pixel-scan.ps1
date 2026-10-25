<#
.SYNOPSIS
  Acceptance test for test\win32\lib\PixelScan.ps1 (T1373).

.DESCRIPTION
  The exact-colour probes used to walk a box in PowerShell, one GetPixel per
  pixel: cheap to say "yes", ~2.5s to say "no" over a full-width band, so a
  wait loop polling on the negative answer measured its own cost (T561: 2626ms
  reported for a ~140ms dismissal). PixelScan answers the same questions in
  compiled code over every pixel.

  What this proves, on synthetic bitmaps:
    A. the compiled scan gives the SAME answers as the PowerShell reference
       walk it replaces - present/absent, first hit, count, centroid, and how
       many pixels were on the capture - including a box that hangs off the
       capture and a shot whose origin is not 0,0;
    B. it is full fidelity: a single 1px feature in the last pixel of a large
       box is found, which a sampled grid would have to be sized to promise;
    C. "exactly" means exactly: a colour one step off in any channel is a miss,
       and pixel formats other than 32bpp read the same;
    D. it is fast where it matters: the negative answer over a 1200x60 band
       comes back in well under 100ms, and - the negative control - the
       PowerShell walk over the same band really is slow, so the hazard the
       library exists for is demonstrated on this interpreter, not assumed.

  Pure logic: no exe, no window, no agent. Runs anywhere.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\pixel-scan.ps1
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
. (Join-Path $PSScriptRoot 'lib\PixelScan.ps1')

# A synthetic shot: a Bitmap filled with $Bg, positioned on "screen" at
# $Left,$Top - the shape Get-TestWindowPixels returns.
function New-Shot([int]$W, [int]$H, [int]$Left, [int]$Top, [int[]]$Bg,
                  [System.Drawing.Imaging.PixelFormat]$Format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H, $Format
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, $Bg[0], $Bg[1], $Bg[2]))
    $g.Dispose()
    return [pscustomobject]@{ Bitmap = $bmp; Width = $W; Height = $H; Left = $Left; Top = $Top }
}

function Set-ShotPixel($Shot, [int]$X, [int]$Y, [int[]]$Rgb) {
    $Shot.Bitmap.SetPixel($X - $Shot.Left, $Y - $Shot.Top,
        [System.Drawing.Color]::FromArgb(255, $Rgb[0], $Rgb[1], $Rgb[2]))
}

# lib\TestDesktop.ps1's Get-TestPixel, copied so this file stays app-free: the
# old probes paid one PowerShell FUNCTION CALL per pixel, and that call - not
# GetPixel itself - is most of the 2.5s. A reference that inlined the read
# would make the negative control in D2 look an order of magnitude kinder than
# the code it stands for.
function Get-RefPixel {
    param([Parameter(Mandatory = $true)]$Shot, [Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y)
    $lx = $X - $Shot.Left
    $ly = $Y - $Shot.Top
    if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { return $null }
    return $Shot.Bitmap.GetPixel($lx, $ly)
}

# The reference: the PowerShell walk the library replaces, verbatim in shape
# (activity-monitor.ps1's Find-ExactPixel / Get-ExactPixelCentroid before
# T1373), so equivalence is measured against what the callers used to get.
function Measure-Reference($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int[]]$Rgb) {
    $n = 0; $sx = 0; $sy = 0; $first = $null; $examined = 0
    for ($y = $Y0; $y -lt $Y1; $y += 1) {
        for ($x = $X0; $x -lt $X1; $x += 1) {
            $c = Get-RefPixel -Shot $Shot -X $x -Y $y
            if ($null -eq $c) { continue }
            $examined++
            if ($c.R -eq $Rgb[0] -and $c.G -eq $Rgb[1] -and $c.B -eq $Rgb[2]) {
                if ($n -eq 0) { $first = [pscustomobject]@{ X = $x; Y = $y } }
                $n++; $sx += $x; $sy += $y
            }
        }
    }
    $cx = $null; $cy = $null
    if ($n -gt 0) { $cx = [int]($sx / $n); $cy = [int]($sy / $n) }
    return [pscustomobject]@{ Count = $n; First = $first; X = $cx; Y = $cy; Examined = $examined }
}

function Format-Answer($m) {
    $f = if ($m.First) { "$($m.First.X),$($m.First.Y)" } else { 'none' }
    return "count=$($m.Count) first=$f centroid=$($m.X),$($m.Y) examined=$($m.Examined)"
}

$BG = @(30, 30, 30)
$INK = @(64, 160, 255)
$shots = @()

try {
    # --- A. same answers as the walk it replaces ---------------------------
    ''
    '-- A. the compiled scan agrees with the PowerShell reference walk'

    $a = New-Shot 120 80 1000 500 $BG
    $shots += $a
    $rng = New-Object System.Random 1373
    foreach ($i in 1..40) {
        Set-ShotPixel $a ($a.Left + $rng.Next(0, 120)) ($a.Top + $rng.Next(0, 80)) $INK
    }
    $boxes = @(
        @{ Name = 'the whole capture'; B = @(1000, 500, 1120, 580) },
        @{ Name = 'an interior box'; B = @(1020, 510, 1090, 560) },
        @{ Name = 'a box hanging off the top-left'; B = @(950, 450, 1040, 530) },
        @{ Name = 'a box hanging off the bottom-right'; B = @(1080, 540, 1300, 700) },
        @{ Name = 'a box entirely off the capture'; B = @(0, 0, 200, 200) },
        @{ Name = 'an empty box'; B = @(1050, 520, 1050, 560) }
    )
    $k = 0
    foreach ($bx in $boxes) {
        $k++
        $b = $bx.B
        $want = Measure-Reference $a $b[0] $b[1] $b[2] $b[3] $INK
        $got = Measure-TestExactPixels -Shot $a -X0 $b[0] -Y0 $b[1] -X1 $b[2] -Y1 $b[3] -Rgb $INK
        Assert "A$k $($bx.Name): same count, first hit, centroid and examined" `
            ((Format-Answer $got) -eq (Format-Answer $want)) "scan: $(Format-Answer $got) / walk: $(Format-Answer $want)"
        $t = Test-TestExactPixel -Shot $a -X0 $b[0] -Y0 $b[1] -X1 $b[2] -Y1 $b[3] -Rgb $INK
        $f = Find-TestExactPixel -Shot $a -X0 $b[0] -Y0 $b[1] -X1 $b[2] -Y1 $b[3] -Rgb $INK
        $fWant = if ($want.First) { "$($want.First.X),$($want.First.Y)" } else { 'none' }
        $fGot = if ($f) { "$($f.X),$($f.Y)" } else { 'none' }
        Assert "A$k (Test/Find) $($bx.Name): agree with the walk" `
            (($t -eq ($want.Count -gt 0)) -and ($fGot -eq $fWant)) "test=$t find=$fGot want=$fWant"
    }
    $some = Measure-TestExactPixels -Shot $a -X0 1000 -Y0 500 -X1 1120 -Y1 580 -Rgb $INK
    Assert 'A7 the fixture really has ink in it (or A1-A6 compared nothing)' ($some.Count -gt 10) "count=$($some.Count)"
    $fst = Measure-TestExactPixels -Shot $a -X0 1000 -Y0 500 -X1 1120 -Y1 580 -Rgb $INK -First
    Assert 'A8 -First stops at the first hit (count 1, same pixel as the full scan)' `
        ($fst.Count -eq 1 -and $fst.First.X -eq $some.First.X -and $fst.First.Y -eq $some.First.Y) (Format-Answer $fst)

    # PowerShell's [int] rounds half to EVEN, so a centroid ending in .5 rounds
    # by the parity of the absolute coordinate. Two pixels one apart, on a shot
    # at an ODD origin, put the mean exactly on a half in both axes.
    $odd = New-Shot 20 20 1001 333 $BG
    $shots += $odd
    Set-ShotPixel $odd 1006 340 $INK
    Set-ShotPixel $odd 1007 341 $INK
    $want = Measure-Reference $odd 1001 333 1021 353 $INK
    $got = Measure-TestExactPixels -Shot $odd -X0 1001 -Y0 333 -X1 1021 -Y1 353 -Rgb $INK
    Assert 'A9 a half-pixel centroid at an odd origin rounds the way the walk did' `
        ($got.X -eq $want.X -and $got.Y -eq $want.Y) "scan $($got.X),$($got.Y) / walk $($want.X),$($want.Y)"

    # --- B. full fidelity ---------------------------------------------------
    ''
    '-- B. a 1px feature in the last pixel is still found'

    $bshot = New-Shot 1200 60 0 900 $BG
    $shots += $bshot
    Assert 'B1 an all-background band answers no' `
        (-not (Test-TestExactPixel -Shot $bshot -X0 0 -Y0 900 -X1 1200 -Y1 960 -Rgb $INK)) ''
    Set-ShotPixel $bshot 1199 959 $INK
    $f = Find-TestExactPixel -Shot $bshot -X0 0 -Y0 900 -X1 1200 -Y1 960 -Rgb $INK
    Assert 'B2 one pixel at the far corner answers yes, at that pixel' `
        ($f -and $f.X -eq 1199 -and $f.Y -eq 959) "found $(if ($f) { "$($f.X),$($f.Y)" } else { 'none' })"
    Assert 'B3 the half-open bound excludes it again' `
        (-not (Test-TestExactPixel -Shot $bshot -X0 0 -Y0 900 -X1 1199 -Y1 960 -Rgb $INK)) ''

    # --- C. exactly means exactly ------------------------------------------
    ''
    '-- C. near misses are misses; other pixel formats read the same'

    $c = New-Shot 10 10 0 0 $BG
    $shots += $c
    Set-ShotPixel $c 1 1 @(65, 160, 255)
    Set-ShotPixel $c 2 2 @(64, 159, 255)
    Set-ShotPixel $c 3 3 @(64, 160, 254)
    Assert 'C1 one step off in R, G or B matches nothing' `
        (-not (Test-TestExactPixel -Shot $c -X0 0 -Y0 0 -X1 10 -Y1 10 -Rgb $INK)) ''
    Set-ShotPixel $c 7 8 $INK
    $m = Measure-TestExactPixels -Shot $c -X0 0 -Y0 0 -X1 10 -Y1 10 -Rgb $INK
    Assert 'C2 and the exact one beside them is the only match' `
        ($m.Count -eq 1 -and $m.First.X -eq 7 -and $m.First.Y -eq 8) (Format-Answer $m)

    foreach ($fmt in @('Format24bppRgb', 'Format32bppRgb')) {
        $s = New-Shot 40 20 0 0 $BG ([System.Drawing.Imaging.PixelFormat]$fmt)
        $shots += $s
        Set-ShotPixel $s 33 17 $INK
        $m = Measure-TestExactPixels -Shot $s -X0 0 -Y0 0 -X1 40 -Y1 20 -Rgb $INK
        Assert "C3 a $fmt capture reads the same (one hit at 33,17; 800 examined)" `
            ($m.Count -eq 1 -and $m.First.X -eq 33 -and $m.First.Y -eq 17 -and $m.Examined -eq 800) (Format-Answer $m)
    }

    # --- D. the negative answer is fast; the walk really was not ----------
    ''
    '-- D. the poll costs milliseconds; the PowerShell walk it replaces did not'

    $d = New-Shot 1200 60 0 0 $BG
    $shots += $d
    $null = Test-TestExactPixel -Shot $d -X0 0 -Y0 0 -X1 1200 -Y1 60 -Rgb $INK   # warm the type
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($i in 1..10) {
        $null = Test-TestExactPixel -Shot $d -X0 0 -Y0 0 -X1 1200 -Y1 60 -Rgb $INK
    }
    $sw.Stop()
    $scanMs = $sw.Elapsed.TotalMilliseconds / 10
    "  scan: $([math]::Round($scanMs, 1))ms per 'no' over 72000 pixels"
    Assert 'D1 a full-fidelity "no" over a 1200x60 band takes under 100ms' ($scanMs -lt 100) "$([math]::Round($scanMs, 1))ms"

    # Negative control: the hazard is real here. A sixth of the band keeps this
    # to about half a second; scaled up it is the ~2.5s T561 measured.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Measure-Reference $d 0 0 1200 10 $INK
    $sw.Stop()
    $walkMs = $sw.Elapsed.TotalMilliseconds * 6
    "  walk: ~$([math]::Round($walkMs))ms per 'no' over the same band (measured on a sixth, scaled)"
    Assert 'D2 (negative control) the PowerShell walk over the same band is at least 10x slower' `
        ($walkMs -ge 10 * $scanMs) "walk ~$([math]::Round($walkMs))ms vs scan $([math]::Round($scanMs, 1))ms"

    Complete-TestBody
}
finally {
    foreach ($s in $shots) { if ($s.Bitmap) { $s.Bitmap.Dispose() } }
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the library as it now stands?". Red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pixel-scan -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T1373 PIXEL-SCAN' -Pass $script:passes -Fail $script:failures
