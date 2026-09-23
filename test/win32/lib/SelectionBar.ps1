# SelectionBar.ps1 - find a list row's selection INDICATOR BAR in a capture (T930).
#
# Windows 11 marks a selected list row with a neutral fill and one small accent
# bar at its leading edge (`src/apprt/win32/list_selection.zig`). The accent
# reaching that bar has been through contrast floors, so its exact RGB depends on
# the surface under it; a harness that sets a test accent therefore cannot match
# the bar by colour. It CAN match it by shape, which is what this does.
#
# Dot-source it; it needs only a shot from lib\TestDesktop.ps1's
# `Get-TestWindowPixels` (anything with a System.Drawing `.Bitmap`).

# T930: find the selection INDICATOR BAR - the one solid, saturated mark on the
# card. The accent reaches the bar through two contrast floors
# (`chrome_theme.accentOn` against the card, then `list_selection` against the
# selection fill), so on a dark card its exact RGB is the test accent LIFTED, not
# the value set in the registry. What cannot move is its shape: a solid run of
# one colour, several pixels tall, that no antialiased glyph fringe produces.
# Returns the colour with the tallest such vertical run (>= $MinRun) and its
# widest horizontal run - the bar is narrow, the retired pill was the whole row.
function Find-SaturatedBar($Shot, [int]$MinChroma = 48, [int]$MinRun = 10) {
    $bmp = $Shot.Bitmap
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = [int]($data.Stride / 4)
        $px = New-Object int[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
    } finally { $bmp.UnlockBits($data) }

    $sat = @{}
    $vrun = @{}
    for ($x = 0; $x -lt $w; $x++) {
        $prev = $null; $run = 0
        for ($y = 0; $y -lt $h; $y++) {
            $v = $px[$y * $stride + $x] -band 0xFFFFFF
            if (-not $sat.ContainsKey($v)) {
                $r = ($v -shr 16) -band 0xFF; $g = ($v -shr 8) -band 0xFF; $b = $v -band 0xFF
                $sat[$v] = (([Math]::Max($r, [Math]::Max($g, $b)) - [Math]::Min($r, [Math]::Min($g, $b))) -ge $MinChroma)
            }
            if ($sat[$v] -and $v -eq $prev) { $run++ } elseif ($sat[$v]) { $run = 1 } else { $run = 0 }
            $prev = $v
            if ($run -gt 0 -and (-not $vrun.ContainsKey($v) -or $vrun[$v] -lt $run)) { $vrun[$v] = $run }
        }
    }
    $best = $null
    foreach ($k in $vrun.Keys) {
        if ($vrun[$k] -ge $MinRun -and ($null -eq $best -or $vrun[$k] -gt $vrun[$best])) { $best = $k }
    }
    if ($null -eq $best) { return $null }

    $hrun = 0
    for ($y = 0; $y -lt $h; $y++) {
        $run = 0
        for ($x = 0; $x -lt $w; $x++) {
            if (($px[$y * $stride + $x] -band 0xFFFFFF) -eq $best) { $run++; if ($run -gt $hrun) { $hrun = $run } }
            else { $run = 0 }
        }
    }
    $rgb = @((($best -shr 16) -band 0xFF), (($best -shr 8) -band 0xFF), ($best -band 0xFF))
    return [pscustomobject]@{ Rgb = $rgb; VRun = $vrun[$best]; HRun = $hrun }
}


# Is channel $Index (0 = R, 1 = G, 2 = B) the colour's clear maximum - the hue
# test a contrast floor cannot move, since the floor walks lightness only?
function Test-DominantChannel([int[]]$Rgb, [int]$Index, [int]$Margin = 48) {
    $others = @(0, 1, 2 | Where-Object { $_ -ne $Index } | ForEach-Object { $Rgb[$_] })
    return (($Rgb[$Index] - ($others | Measure-Object -Maximum).Maximum) -ge $Margin)
}
