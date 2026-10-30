# On-screen oracle for the composition present path (tracker T2488).
#
# test\win32\comp-present.ps1 proves the composition swap chain builds,
# presents, falls back and rebuilds - on the background test desktop, which DWM
# never composes. What it cannot see is the picture DWM actually shows. This
# script films it: the app runs as a GHOST window on the input desktop
# (GHOZTTY_DEBUG_GHOST=1, debug builds only: layered alpha 1/255,
# click-through, a tool window that never activates, bottom of the z-order -
# the shape T2463 measured for the spike), and ghoztty-comp-spike.exe
# --grab-hwnd captures one whole frame of it with Windows.Graphics.Capture.
#
# It lives in scripts\ rather than test\win32\ for the same reason
# comp-spike.ps1 -Live does: it needs the input desktop, and the person at the
# desk never sees or loses focus to anything it opens.
#
# Per arm (knob ON = GHOZTTY_COMP_PRESENT=1, knob OFF = WGL SwapBuffers):
#
#   1. clear the pane and print a block of marker lines at the top
#   2. grab the window with WGC; read the app's own picture of the pane
#      (capture-pane, the renderer's target)
#   3. score:
#      - not blank: the pane region of the grab has ink
#      - right way up: the ink sits in the TOP of the pane, the bottom
#        third is background (an upside-down present puts the lines at the
#        bottom)
#      - matches capture-pane: aligned by ink profile, the sampled pixels
#        agree within tolerance
#
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms on
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Spike = 'D:\git\ghoztty\zig-out\bin\ghoztty-comp-spike.exe',
    [string[]]$Arms = @('on', 'off'),
    # 1 = layered alpha 1/255 (invisible); bottom = opaque, bottom of z-order.
    [string]$Ghost = 'bottom',
    [string]$OutDir,
    # Flip each grab upside down before scoring: the right-way-up and match
    # checks must then FAIL, or they cannot tell a flipped present apart.
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
. (Join-Path $testLib 'PaneCapture.ps1')
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Doptimize=Debug"; exit 2 }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GhostWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    public static IntPtr[] TopLevel(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new System.Text.StringBuilder(64);
                GetClassName(h, sb, 64);
                if (sb.ToString() == cls) list.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@

# BGRA bytes of a bitmap, top row first, and its size.
function Get-Pixels($bmp) {
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $stride = $data.Stride
    $bmp.UnlockBits($data)
    return [pscustomobject]@{ W = $bmp.Width; H = $bmp.Height; Stride = $stride; B = $bytes }
}

Add-Type -TypeDefinition @'
public static class InkMath {
    // Text is bright and the pane backdrop is dark (a solid fill or the
    // window's gradient showing through), so "ink" is luminance, not distance
    // from one background colour.
    static bool Ink(byte[] b, int o, int lum) { return (b[o] + b[o + 1] + b[o + 2]) >= 3 * lum; }
    // Ink pixels per row of [x0,x1) x [y0,y1).
    public static int[] RowInk(byte[] b, int stride, int x0, int y0, int x1, int y1, int lum) {
        var rows = new int[y1 - y0];
        for (int y = y0; y < y1; y++) {
            int n = 0, o = y * stride + x0 * 4;
            for (int x = x0; x < x1; x++, o += 4) if (Ink(b, o, lum)) n++;
            rows[y - y0] = n;
        }
        return rows;
    }
    // Glyph agreement of A (aw x ah) placed at (dx,dy) in B, sampled every
    // step pixels: of the pixels that are ink in EITHER picture, the fraction
    // that are ink in BOTH. Background agreeing with background proves
    // nothing, so it is not counted.
    public static double Match(byte[] a, int aStride, int aw, int ah, byte[] b, int bStride, int bw, int bh, int dx, int dy, int step, int lum) {
        int either = 0, both = 0;
        for (int y = 0; y < ah; y += step) {
            int by = y + dy; if (by < 0 || by >= bh) continue;
            for (int x = 0; x < aw; x += step) {
                int bx = x + dx; if (bx < 0 || bx >= bw) continue;
                bool ia = Ink(a, y * aStride + x * 4, lum), ib = Ink(b, by * bStride + bx * 4, lum);
                if (ia || ib) either++;
                if (ia && ib) both++;
            }
        }
        return either == 0 ? 0.0 : (double)both / either;
    }
}
'@

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}

function Wait-Log($path, $pattern, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$onLine = 'pane presents through a composition swap chain'

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'componscreen')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

$results = @{}
try {
    foreach ($arm in $Arms) {
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=$(if ($arm -eq 'on') { '1' } else { 'unset' }))"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = $Ghost
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        if ($arm -eq 'on') { $env:GHOZTTY_COMP_PRESENT = '1' } else { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=34', '--background=#101418',
            "--title=t2488-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([GhostWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        $ex = [GhostWin]::GetWindowLong($top, -20)
        $wantLayered = ($Ghost -ne 'bottom')
        Assert "$arm.1 it is a ghost (noactivate, layered=$($wantLayered): ex=0x$('{0:x}' -f $ex))" `
            ((($ex -band 0x08000000) -ne 0) -and ((($ex -band 0x80000) -ne 0) -eq $wantLayered))

        & $Exe +new-window "--target=on$arm" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([GhostWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.2 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        if ($arm -eq 'on') {
            Assert "$arm.3 the panes present through the composition chain" (Wait-Log $err $onLine 15000)
        } else {
            Start-Sleep -Milliseconds 1500
            Assert "$arm.3 no pane touched the composition path" ((Read-Text $err) -notmatch [regex]::Escape($onLine))
        }

        & $Exe +send-keys "--target=on$arm" 'cls' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        & $Exe +send-keys "--target=on$arm" 'for /L %i in (1,1,6) do @echo ######## T2488-MARK-%i ########################################' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500

        $fgPid = [uint32]0
        [void][GhostWin]::GetWindowThreadProcessId([GhostWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

        $bmpPath = Join-Path $dir 'grab.bmp'
        $grabErr = Join-Path $dir 'grab.txt'
        $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
            -NoNewWindow -PassThru -RedirectStandardError $grabErr
        [void]$gp.WaitForExit(15000)
        $grabOut = (Read-Text $grabErr).Trim()
        "  $grabOut"
        Assert "$arm.4 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
        $shot = Get-TestPaneCapture -Target "on$arm"
        Assert "$arm.5 capture-pane answered$(if (-not $shot) { ': ' + (Get-LastPaneCaptureError) })" ($null -ne $shot)
        if (-not (Test-Path $bmpPath) -or -not $shot) { Close-TestPaneCapture $shot; continue }

        $grabBmp = New-Object System.Drawing.Bitmap $bmpPath
        if ($NegativeControl) { $grabBmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
        $g = Get-Pixels $grabBmp
        $grabBmp.Dispose()
        $p = Get-Pixels $shot.Bitmap
        Close-TestPaneCapture $shot

        $lum = 150
        $paneRows = [InkMath]::RowInk($p.B, $p.Stride, 0, 0, $p.W, $p.H, $lum)

        # Align the pane inside the grab: the offset whose sampled ink agrees
        # best. Coarse search on a 4 px grid, then refine.
        $best = @{ s = -1.0; dx = 0; dy = 0 }
        $maxDx = [Math]::Max(0, $g.W - $p.W); $maxDy = [Math]::Max(0, $g.H - $p.H)
        for ($dy = 0; $dy -le $maxDy; $dy += 4) {
            for ($dx = 0; $dx -le $maxDx; $dx += 4) {
                $s = [InkMath]::Match($p.B, $p.Stride, $p.W, $p.H, $g.B, $g.Stride, $g.W, $g.H, $dx, $dy, 3, $lum)
                if ($s -gt $best.s) { $best = @{ s = $s; dx = $dx; dy = $dy } }
            }
        }
        $cx = $best.dx; $cy = $best.dy
        for ($dy = [Math]::Max(0, $cy - 4); $dy -le [Math]::Min($maxDy, $cy + 4); $dy++) {
            for ($dx = [Math]::Max(0, $cx - 4); $dx -le [Math]::Min($maxDx, $cx + 4); $dx++) {
                $s = [InkMath]::Match($p.B, $p.Stride, $p.W, $p.H, $g.B, $g.Stride, $g.W, $g.H, $dx, $dy, 1, $lum)
                if ($s -gt $best.s) { $best = @{ s = $s; dx = $dx; dy = $dy } }
            }
        }

        # Score the grab's PANE region on its own terms (no reference).
        $x0 = $best.dx; $y0 = $best.dy
        $x1 = [Math]::Min($g.W, $x0 + $p.W); $y1 = [Math]::Min($g.H, $y0 + $p.H)
        $rows = [InkMath]::RowInk($g.B, $g.Stride, $x0, $y0, $x1, $y1, $lum)
        $h = $rows.Length
        $inkRows = @(0..($h - 1) | Where-Object { $rows[$_] -ge 3 })
        $topInk = @($inkRows | Where-Object { $_ -lt ($h / 2) }).Count
        $bottomInk = @($inkRows | Where-Object { $_ -ge ($h * 2 / 3) }).Count
        $refInk = @(0..($paneRows.Length - 1) | Where-Object { $paneRows[$_] -ge 3 }).Count
        $line = "  grab $($g.W)x$($g.H) pane $($p.W)x$($p.H) at +$($best.dx)+$($best.dy) match=$('{0:N3}' -f $best.s) ink_rows=$($inkRows.Count) (ref $refInk) top_half=$topInk bottom_third=$bottomInk"
        $line
        Assert "$arm.6 the pane on screen is not blank" ($inkRows.Count -ge 20)
        Assert "$arm.7 right way up: the marker lines are at the top, the bottom third is background" ($topInk -ge 20 -and $bottomInk -le 2)
        Assert "$arm.8 the glyphs match capture-pane's (>= 0.80 ink overlap)" ($best.s -ge 0.80)
        $results[$arm] = $line
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

"  grabs kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
