# PixelScan.ps1 (T1373) - exact-colour questions about a capture, answered in
# compiled code at full fidelity.
#
# THE DEFECT: the probes that asked "is there a pixel of exactly this colour in
# this box?" walked the box in PowerShell, one Bitmap.GetPixel per pixel. They
# exit on the first hit, so "yes" was cheap - but "no" visits every pixel, and a
# full-width bottom band is ~60k of them: about 2.5s per answer on this box.
# T561 measured the consequence: a wait-for-dismissal loop built on that probe
# reported 2626ms for a dismissal that actually takes ~140ms. Any poll keyed on
# the NEGATIVE answer measured its own cost and burned the wall clock of every
# run that used it.
#
# The fix is not a coarser grid. A grid is sized against the smallest feature it
# must not miss, and that sizing is a claim nobody re-checks when the feature
# shrinks (a glyph, a 1px stroke). Here the scan runs over a LockBits copy in C#,
# so every pixel is still examined and the full "no" costs milliseconds. One
# scan answers all four questions the callers ask - is it there, where is the
# first one, how many, and where is their centre - so the four can never
# disagree about what "exactly" means.
#
# Coordinates are SCREEN coordinates, exactly like Get-TestPixel's in
# lib\TestDesktop.ps1, so a probe migrated from a GetPixel walk keeps its math.
# Pixels of the box that fall off the capture are skipped, as Get-TestPixel's
# $null skipped them. The shot is anything with { Bitmap, Left, Top } - what
# Get-TestWindowPixels returns, or a synthetic one built in a test.
#
# Acceptance: test\win32\pixel-scan.ps1 (no app, no window - runs anywhere).
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

if (-not ('GhozttyPixelScan' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class GhozttyPixelScan {
    // Row-major, top to bottom, left to right - the order the PowerShell walks
    // used, so "the first match" is the same pixel it always was.
    //
    // Box is bitmap-local, half-open [x0,x1) x [y0,y1), already clamped by the
    // caller. Returns { count, firstX, firstY, sumX, sumY, examined }, first =
    // -1 when nothing matched. stopAtFirst ends the scan on the first hit.
    public static long[] Scan(Bitmap bmp, int x0, int y0, int x1, int y1,
                              int r, int g, int b, bool stopAtFirst) {
        long[] res = new long[] { 0, -1, -1, 0, 0, 0 };
        if (x1 <= x0 || y1 <= y0) return res;
        Rectangle rect = new Rectangle(x0, y0, x1 - x0, y1 - y0);
        BitmapData d = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int w = x1 - x0;
            byte[] row = new byte[w * 4];
            // pixel-region: rect is the CALLER's box (x0..x1, y0..y1), locked alone - the walk spans the region the caller named, never the capture around it
            for (int y = 0; y < rect.Height; y++) {
                // Stride is negative for a bottom-up bitmap; 64-bit arithmetic
                // keeps the address right either way.
                IntPtr p = new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride);
                Marshal.Copy(p, row, 0, row.Length);
                res[5] += w;
                for (int x = 0; x < w; x++) {
                    int o = x * 4;  // BGRA in memory
                    if (row[o + 2] == r && row[o + 1] == g && row[o] == b) {
                        if (res[0] == 0) { res[1] = x0 + x; res[2] = y0 + y; }
                        res[0]++;
                        res[3] += x0 + x;
                        res[4] += y0 + y;
                        if (stopAtFirst) return res;
                    }
                }
            }
        } finally {
            bmp.UnlockBits(d);
        }
        return res;
    }
}
'@
}

<#
One exact-colour scan of a screen-coordinate box. Returns
{ Count, First, X, Y, Examined }: Count is the number of exactly-$Rgb pixels,
First is the first one in row-major order as { X, Y } (or $null), X/Y is their
centroid (or $null), and Examined is how many pixels of the box were on the
capture at all - so "how many are NOT $Rgb" is Examined - Count. -First stops
at the first hit, so Count is then 0 or 1.
#>
function Measure-TestExactPixels {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$X0, [int]$Y0, [int]$X1, [int]$Y1,
        [Parameter(Mandatory = $true)][int[]]$Rgb,
        [switch]$First
    )
    $bmp = $Shot.Bitmap
    # Screen -> bitmap-local, clamped to the capture (off-capture pixels are
    # skipped, as Get-TestPixel's $null skipped them).
    $lx0 = [math]::Max(0, $X0 - $Shot.Left)
    $ly0 = [math]::Max(0, $Y0 - $Shot.Top)
    $lx1 = [math]::Min($bmp.Width, $X1 - $Shot.Left)
    $ly1 = [math]::Min($bmp.Height, $Y1 - $Shot.Top)
    $r = [GhozttyPixelScan]::Scan($bmp, $lx0, $ly0, $lx1, $ly1,
        $Rgb[0], $Rgb[1], $Rgb[2], [bool]$First)
    $n = [int]$r[0]
    $hit = $null; $cx = $null; $cy = $null
    if ($n -gt 0) {
        $hit = [pscustomobject]@{ X = [int]$r[1] + $Shot.Left; Y = [int]$r[2] + $Shot.Top }
        # Averaged over SCREEN sums, as the walks did: [int] rounds half to
        # even, so rounding a bitmap-local mean and adding an odd origin lands
        # one pixel off whenever the mean ends in .5.
        $cx = [int](([double]$r[3] + [double]$n * $Shot.Left) / $n)
        $cy = [int](([double]$r[4] + [double]$n * $Shot.Top) / $n)
    }
    return [pscustomobject]@{
        Count    = $n
        First    = $hit
        X        = $cx
        Y        = $cy
        Examined = [long]$r[5]
    }
}

# Is there a pixel of EXACTLY $Rgb in the box? Fast in both directions, so it
# is usable as a poll on the negative answer.
function Test-TestExactPixel {
    param([Parameter(Mandatory = $true)]$Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1,
          [Parameter(Mandatory = $true)][int[]]$Rgb)
    return ((Measure-TestExactPixels -Shot $Shot -X0 $X0 -Y0 $Y0 -X1 $X1 -Y1 $Y1 -Rgb $Rgb -First).Count -gt 0)
}

# The FIRST screen coordinate in the box (row-major) whose pixel is exactly
# $Rgb, as { X, Y }, or $null.
function Find-TestExactPixel {
    param([Parameter(Mandatory = $true)]$Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1,
          [Parameter(Mandatory = $true)][int[]]$Rgb)
    return (Measure-TestExactPixels -Shot $Shot -X0 $X0 -Y0 $Y0 -X1 $X1 -Y1 $Y1 -Rgb $Rgb -First).First
}
