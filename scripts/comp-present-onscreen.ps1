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
# Per arm (knob ON = GHOZTTY_COMP_PRESENT=1, knob OFF = WGL SwapBuffers,
# TREE = ON plus GHOZTTY_COMP_CHROME=1 and GHOZTTY_COMP_PANE_TREE=1: the swap
# chain presents into a visual of the WINDOW's composition tree and the
# pane's child window paints nothing, so the visual is the only way the pane
# can be on screen - T2553):
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
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms tree,off
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms tree,flat
#
# FLAT is TREE in the flat pane style (T2570). TREE runs the default elevated
# style, where the pane is a rounded card, and since a window region does not
# clip a visual on the topmost pane target, the visual must carry the card's
# corners itself. Both read the pane's bottom-left corner pixel off the grab:
# rounded (the desk round the card) on TREE, square (the pane's background)
# on FLAT.
#
# The tree arm also splits the window and scores BOTH the original pane (now
# moved and resized) and the new one, so a visual that does not follow its
# child window, or a second pane that is never adopted, is a failure.
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -NegativeControl   # must go red
#
# FOLD is FLAT plus a stack fold (T2570): P | s1 | s2, the root divider
# dragged past the fold point and held with the slide stretched
# (GHOZTTY_STACK_SLIDE_MS), the stack-fold-slide.ps1 shape. s2 is filled with
# ink and s1 is cleared; mid-fold the window is grabbed, and s1's spot on the
# grab must carry none of s2's ink - a folding pane whose visual is not cut to
# its card draws at full size over the pane next to it. The drag is posted
# mouse input the app captures, so run this arm only on an idle box.
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms fold
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms fold -NegativeControl   # must go red
#
# Mid-fold the folding card is not the pane's visual at all: the pane is
# hidden and its card is a STRIP FACE, an owned popup carrying the pane's last
# frame (T2457). Window capture leaves owned popups out unless asked, so the
# mid-fold grab asks (the spike's --popups) and fold.27 says it took. Asked,
# it also takes the process's other windows where they overlap, so the arm
# first minimizes the window it started with (without activating it).
# fold.28 then requires s2's ink inside the face's own rect - the card IS on
# the grab - and fold.26 scores s1's spot outside that rect only, since the
# card is meant to lie over s1 there. -NoPopups grabs the mid-fold frame the
# old way, without the face, and fold.27/28 must go red.
#   powershell -NoProfile -File scripts\comp-present-onscreen.ps1 -Arms fold -NoPopups   # fold.27/28 must go red

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('on', 'off'),
    # 1 = layered alpha 1/255 (invisible); bottom = opaque, bottom of z-order.
    [string]$Ghost = 'bottom',
    [string]$OutDir,
    # Flip each grab upside down before scoring: the right-way-up and match
    # checks must then FAIL, or they cannot tell a flipped present apart.
    [switch]$NegativeControl,
    # Grab the mid-fold frame without the window's owned popups (fold arm).
    [switch]$NoPopups
)

# This tree's build, whichever loop lane's tree it is (T2572: a default of
# lane A's tree made lane B's run refuse).
$Exe = [System.IO.Path]::GetFullPath($Exe)
$Spike = [System.IO.Path]::GetFullPath($Spike)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
# The fold arm's slide, stretched so the grab (a process start plus one WGC
# frame) lands well inside it.
$foldSlideMs = 4000

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
. (Join-Path $testLib 'PaneCapture.ps1')
. (Join-Path $testLib 'ChromeGeometry.ps1')
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
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_STACK_SLIDE_MS'
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
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
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
    // For LOCATING only (T2553): of A's sampled ink pixels, the fraction with
    // ink in B within r pixels. A coarse grid can land off a thin glyph by a
    // pixel or two, and the strict Match then scores the true spot below a
    // wrong one; this is tolerant of that, and the refine stays strict.
    public static double MatchNear(byte[] a, int aStride, int aw, int ah, byte[] b, int bStride, int bw, int bh, int dx, int dy, int step, int lum, int r) {
        int ink = 0, near = 0;
        for (int y = 0; y < ah; y += step) {
            for (int x = 0; x < aw; x += step) {
                if (!Ink(a, y * aStride + x * 4, lum)) continue;
                ink++;
                bool found = false;
                for (int oy = -r; oy <= r && !found; oy++) {
                    int by = y + dy + oy; if (by < 0 || by >= bh) continue;
                    for (int ox = -r; ox <= r && !found; ox++) {
                        int bx = x + dx + ox; if (bx < 0 || bx >= bw) continue;
                        if (Ink(b, by * bStride + bx * 4, lum)) found = true;
                    }
                }
                if (found) near++;
            }
        }
        return ink == 0 ? 0.0 : (double)near / ink;
    }
    // Mean luminance of [x0,x1) x [y0,y1), sampled every 2 px (T2562: is the
    // dim wash on this pane's spot of the grab).
    public static double MeanLum(byte[] b, int stride, int x0, int y0, int x1, int y1) {
        long sum = 0, n = 0;
        for (int y = y0; y < y1; y += 2) {
            for (int x = x0, o = y * stride + x0 * 4; x < x1; x += 2, o += 8) { sum += (b[o] + b[o + 1] + b[o + 2]) / 3; n++; }
        }
        return n == 0 ? 0.0 : (double)sum / n;
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
$treeLine = 'pane visual adopted into the window tree'

# Clear a pane and print the marker block at its top.
function Mark-Pane($target, $text = 'for /L %i in (1,1,6) do @echo ######## T2488-MARK-%i ########################################') {
    & $Exe +send-keys "--target=$target" 'cls' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800
    # argv-audit: every caller passes a fixed cmd line with no double quote and no trailing backslash, which survives a native argv
    & $Exe +send-keys "--target=$target" $text Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 1500

}

# Grab the window with WGC and score `target`'s region of it against the
# app's own picture of that pane. Returns the summary line, or null.
function Score-Grab($arm, $label, $hw, $target, $dir, [double]$minMatch = 0.80, [switch]$NoFlip) {
    $fgPid = [uint32]0
    [void][GhostWin]::GetWindowThreadProcessId([GhostWin]::GetForegroundWindow(), [ref]$fgPid)
    Assert "$label.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

    $bmpPath = Join-Path $dir "grab-$($label -replace '[^\w-]','_').bmp"
    $grabErr = Join-Path $dir "grab-$($label -replace '[^\w-]','_').txt"
    $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
        -NoNewWindow -PassThru -RedirectStandardError $grabErr
    [void]$gp.WaitForExit(15000)
    $grabOut = (Read-Text $grabErr).Trim()
    "  $grabOut"
    Assert "$label.4 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
    $shot = Get-TestPaneCapture -Target $target
    Assert "$label.5 capture-pane answered$(if (-not $shot) { ': ' + (Get-LastPaneCaptureError) })" ($null -ne $shot)
    if (-not (Test-Path $bmpPath) -or -not $shot) { Close-TestPaneCapture $shot; return $null }

    $grabBmp = New-Object System.Drawing.Bitmap $bmpPath
    if ($NegativeControl -and -not $NoFlip) { $grabBmp.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
    $g = Get-Pixels $grabBmp
    $grabBmp.Dispose()
    $shot.Bitmap.Save((Join-Path $dir "ref-$($label -replace '[^\w-]','_').png"), [System.Drawing.Imaging.ImageFormat]::Png)
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
            $s = [InkMath]::MatchNear($p.B, $p.Stride, $p.W, $p.H, $g.B, $g.Stride, $g.W, $g.H, $dx, $dy, 3, $lum, 2)
            if ($s -gt $best.s) { $best = @{ s = $s; dx = $dx; dy = $dy } }
        }
    }
    $cx = $best.dx; $cy = $best.dy
    $best = @{ s = -1.0; dx = $cx; dy = $cy }
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
    $script:lastAt = $best.dx
    $script:lastW = $p.W
    $script:lastGrab = $g
    $script:lastRegion = @($x0, $y0, $x1, $y1)
    $line = "  grab $($g.W)x$($g.H) pane $($p.W)x$($p.H) at +$($best.dx)+$($best.dy) match=$('{0:N3}' -f $best.s) ink_rows=$($inkRows.Count) (ref $refInk) top_half=$topInk bottom_third=$bottomInk"
    $line
    Assert "$label.6 the pane on screen is not blank" ($inkRows.Count -ge 20)
    Assert "$label.7 right way up: the marker lines are at the top, the bottom third is background" ($topInk -ge 20 -and $bottomInk -le 2)
    Assert "$label.8 the glyphs match capture-pane's (>= $('{0:N2}' -f $minMatch) ink overlap)" ($best.s -ge $minMatch)
    return
}

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
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=$(if ($arm -ne 'off') { '1' } else { 'unset' }) PANE_TREE=$(if ($arm -in 'tree', 'flat', 'fold') { '1' } else { 'unset' }))"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = $Ghost
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        if ($arm -ne 'off') { $env:GHOZTTY_COMP_PRESENT = '1' } else { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
        $inTree = $arm -in 'tree', 'flat', 'fold'
        foreach ($k in 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE') {
            if ($inTree) { Set-Item "env:$k" '1' } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        }
        if ($arm -eq 'fold') { $env:GHOZTTY_STACK_SLIDE_MS = "$foldSlideMs" } else { Remove-Item env:GHOZTTY_STACK_SLIDE_MS -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $appArgs = @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=34', '--background=#101418',
            "--title=t2488-$arm")
        # The tree arm's split leaves one pane unfocused; a white wash makes
        # its dim visible on the grab (T2562) while its text stays ink. Glass
        # panes never dim (T2281), so glass is off.
        if ($arm -eq 'tree') { $appArgs += '--unfocused-split-opacity=0.7', '--unfocused-split-fill=#ffffff', '--macos-pane-glass=false' }
        # The flat arm (T2570): the tree arm is the default elevated style,
        # whose rounded card the visual must take; flat, it stays square.
        if ($arm -in 'flat', 'fold') { $appArgs += '--macos-pane-style=flat', '--macos-pane-glass=false' }
        $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs -StdErr $err
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
            Assert "$arm.3b no pane went into the window tree" ((Read-Text $err) -notmatch [regex]::Escape($treeLine))
        } elseif ($inTree) {
            Assert "$arm.3 the pane's surface handle went into the window tree" (Wait-Log $err $treeLine 15000)
            Assert "$arm.3b the presenter made a handle swap chain (tree=true)" ((Read-Text $err) -match 'composition swap chain warp=\w+ tree=true')
        } else {
            Start-Sleep -Milliseconds 1500
            Assert "$arm.3 no pane touched the composition path" ((Read-Text $err) -notmatch [regex]::Escape($onLine))
        }

        Mark-Pane "on$arm"
        $script:lastRegion = $null
        Score-Grab $arm "$arm" $hw "on$arm" $dir
        # T2570: the pane's bottom-left corner pixel on the grab. Elevated
        # (the default, the tree arm), the visual takes the card's rounded
        # corner and the corner shows the desk round the card, as the pixel
        # just left of the pane does - before T2570 it was the pane's
        # background, square. Flat, it is a plain rectangle.
        if ($inTree -and $script:lastRegion) {
            $g = $script:lastGrab; $r = $script:lastRegion
            $px = { param($x, $y) $o = $y * $g.Stride + $x * 4; @([int]$g.B[$o + 2], [int]$g.B[$o + 1], [int]$g.B[$o]) }
            $dist = { param($a, $b) [Math]::Abs($a[0] - $b[0]) + [Math]::Abs($a[1] - $b[1]) + [Math]::Abs($a[2] - $b[2]) }
            $corner = & $px ($r[0] + 1) ($r[3] - 2)
            $bg = & $px ($r[0] + 24) ($r[3] - 24)
            $desk = & $px ([Math]::Max(0, $r[0] - 3)) ($r[3] - 24)
            "  corner rgb=$($corner -join ',') pane bg=$($bg -join ',') desk=$($desk -join ',')"
            if ($arm -eq 'tree') {
                Assert "$arm.15 the visual took a rounded card shape (log)" ((Read-Text $err) -match 'pane visual shape -?\d+,-?\d+--?\d+,-?\d+ radius=[1-9]')
                Assert "$arm.16 desk and pane background differ on the grab, so a corner can be told apart (distance $(& $dist $desk $bg))" ((& $dist $desk $bg) -ge 12)
                Assert "$arm.17 the card's corner is rounded on screen: the corner pixel is the desk, not the pane" `
                    ((& $dist $corner $desk) -lt (& $dist $corner $bg))
            } else {
                Assert "$arm.15 flat, the corner is square on screen: the corner pixel is the pane background" ((& $dist $corner $bg) -le 12)
            }
        }
        if ($arm -eq 'tree') {
            # Split + resize: the first pane is moved and shrunk by the layout,
            # the second is a new presenter adopted into the same tree.
            & $Exe +split "--target=on$arm" '--direction=right' "--name=on$arm-r" 2>$null | Out-Null
            $adopted2 = $false
            for ($t = 0; $t -lt 75 -and -not $adopted2; $t++) {
                $adopted2 = (Read-Text $err) -match 'adopted into the window tree \(adopts=2\)'
                if (-not $adopted2) { Start-Sleep -Milliseconds 200 }
            }
            Assert "$arm.9 the split's new pane was adopted into the same tree (adopts=2)" $adopted2
            # Different text in each half (short lines, so a half-width pane
            # does not wrap them), or the right pane's picture would align
            # onto the left pane and score as a match.
            Mark-Pane "on$arm-r" 'for /L %i in (1,1,3) do @echo == RIGHT-%i ==== rrrr ===='
            Mark-Pane "on$arm" 'for /L %i in (1,1,6) do @echo ## LEFT-%i ## llll ##'
            $script:lastAt = $null
            Score-Grab $arm "$arm.split-left" $hw "on$arm" $dir
            $leftAt = $script:lastAt; $leftW = $script:lastW; $leftRegion = $script:lastRegion
            Score-Grab $arm "$arm.split-right" $hw "on$arm-r" $dir
            Assert "$arm.10 the right pane's picture sits right of the left pane's (left +$leftAt w$leftW, right +$($script:lastAt))" `
                ($null -ne $leftAt -and $script:lastAt -ge ($leftAt + $leftW - 8))

            # T2562: the overlays hang under the pane's visual in the window's
            # tree, so they are on the grab at the pane's spot and no overlay
            # popup window exists at all.
            $text = Read-Text $err
            Assert "$arm.11 the dim wash went onto the pane's visual" ($text -match 'dim overlay path visual=true')
            Assert "$arm.11b the unfocused pane's wash is shown as a visual" ($text -match 'dim overlay shown as visual')
            Assert "$arm.12 the scrollbar went onto the pane's visual" ($text -match 'scrollbar path visual=true')
            $popups = @()
            foreach ($cls in 'GhozttyDimOverlay', 'GhozttyScrollbar', 'GhozttyBellBorder') {
                $popups += @([GhostWin]::TopLevel([uint32]$app.Pid, $cls) | ForEach-Object { $cls })
            }
            Assert "$arm.13 no overlay popup window is visible ($(if ($popups.Count) { $popups -join ',' } else { 'none' }))" ($popups.Count -eq 0)
            # Both panes are in the last grab. One is unfocused and carries a
            # white 30% wash: its background (the bottom third, no text) reads
            # well above the other's dark #101418.
            $g = $script:lastGrab
            $lumOf = {
                param($r)
                $y0 = $r[1] + [int](($r[3] - $r[1]) * 2 / 3)
                [InkMath]::MeanLum($g.B, $g.Stride, $r[0] + 4, $y0, $r[2] - 24, $r[3] - 4)
            }
            $lumL = & $lumOf $leftRegion
            $lumR = & $lumOf $script:lastRegion
            "  background lum: left=$('{0:N1}' -f $lumL) right=$('{0:N1}' -f $lumR)"
            $hi = [Math]::Max($lumL, $lumR); $lo = [Math]::Min($lumL, $lumR)
            Assert "$arm.14 exactly one pane is washed on the grab, at its own spot (washed >= 60, other <= 35)" ($hi -ge 60 -and $lo -le 35)
        }
        if ($arm -eq 'fold') {
            # The window the app started with sits over this one, and the
            # mid-fold grab takes the process's other windows with its
            # popups: minimize it, without activating it (SW_SHOWMINNOACTIVE).
            [void][GhostWin]::ShowWindowAsync($top, 7)
            for ($t = 0; $t -lt 20 -and -not [GhostWin]::IsIconic($top); $t++) { Start-Sleep -Milliseconds 100 }
            Assert "$arm.19 the first window is out of the way (minimized)" ([GhostWin]::IsIconic($top))
            # P | s1 | s2 across 1125 DIP: five pane minimums of 225, so the
            # drag below folds s2 (stack-fold-slide.ps1's layout, T2295).
            $minDip = 225
            $dpi = [int](Get-TestWindowDpi -Window $hw)
            if ($dpi -le 0) { $dpi = 96 }
            $scale = $dpi / 96.0
            [void](Set-TestWindowPos -Window $hw -X 0 -Y 0 -Width (Get-TestChromeDip -Dip (5 * $minDip) -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
            Start-Sleep -Seconds 2
            & $Exe +split "--target=on$arm" '--direction=right' "--name=on$arm-s1" 2>$null | Out-Null
            Start-Sleep -Milliseconds 800
            # --pane, not --target: a --target names a window and splits its
            # focused pane (P), which left P | s2 | s1 and fed the checks
            # below the wrong panes.
            & $Exe +split "--target=on$arm" "--pane=on$arm-s1" '--direction=right' "--name=on$arm-s2" 2>$null | Out-Null
            $c3 = @()
            for ($t = 0; $t -lt 60 -and $c3.Count -ne 3; $t++) {
                Start-Sleep -Milliseconds 300
                $c3 = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
            }
            Assert "$arm.20 three panes on show: $(($c3 | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | ')" ($c3.Count -eq 3)
            if ($c3.Count -ne 3) { continue }
            # s2 carries a block of ink in its top half; s1 and P are cleared,
            # so ink on s1's spot mid-fold can only be s2 drawn over it.
            & $Exe +send-keys "--target=on$arm-s1" 'cls' Enter 2>$null | Out-Null
            & $Exe +send-keys "--target=on$arm" 'cls' Enter 2>$null | Out-Null
            Mark-Pane "on$arm-s2" 'for /L %i in (1,1,12) do @echo ##########################'
            # At rest: s2's ink is on the grab where s2 is, which both proves
            # the grab can see it and maps screen to grab coordinates. A
            # locate, not a fidelity check (fold.8 and the tree arm are): an
            # 319 px s2 draws greyer glyphs than capture-pane's and scores
            # ~0.72 (2026-11-01), and anything above 0.6 is unambiguously s2.
            # Never flipped: -NegativeControl scores s2's inked spot on this
            # grab below, so it has to be where s2 really is.
            $script:lastRegion = $null
            Score-Grab $arm "$arm.rest-s2" $hw "on$arm-s2" $dir 0.60 -NoFlip
            $restRegion = $script:lastRegion
            $c3 = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
            if (-not $restRegion) { Assert "$arm.21 the at-rest grab located s2" $false; continue }
            $offX = $restRegion[0] - $c3[2].Left
            $offY = $restRegion[1] - $c3[2].Top
            # The fold: down on the P | s1 divider, up to just short of the
            # fold point, then over it in one move, and hold.
            $gutter = $c3[1].Left - $c3[0].Right
            $foldAt = $c3[2].Right - 2 * (Get-TestChromeDip -Dip $minDip -Scale $scale) - $gutter
            $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
            $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
            $xNear = [int]($foldAt - (Get-TestChromeDip -Dip 40 -Scale $scale))
            $xFold = [int]($foldAt + (Get-TestChromeDip -Dip 100 -Scale $scale))
            "  fold point ~$foldAt px; drag $x0 -> $xNear -> $xFold, slide $foldSlideMs ms"
            [void](Send-TestMouse -Window $hw -Target $hw -X $x0 -Y $y -Action down -HoldMs 0)
            Start-Sleep -Milliseconds 150
            for ($i = 1; $i -le 6; $i++) {
                [void](Send-TestMouse -Window $hw -Target $hw -X ([int]($x0 + ($xNear - $x0) * $i / 6)) -Y $y -Action move -HoldMs 0)
                Start-Sleep -Milliseconds 30
            }
            Start-Sleep -Milliseconds 400
            $near = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            [void](Send-TestMouse -Window $hw -Target $hw -X $xFold -Y $y -Action move -HoldMs 0)
            Start-Sleep -Milliseconds 600
            $before = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Sort-Object Left)
            $faces = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace')
            $bmpPath = Join-Path $dir 'grab-fold-mid.bmp'
            $grabArgs = @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"")
            if (-not $NoPopups) { $grabArgs += '--popups' }
            $gp = Start-Process -FilePath $Spike -ArgumentList $grabArgs `
                -NoNewWindow -PassThru -RedirectStandardError (Join-Path $dir 'grab-fold-mid.txt')
            [void]$gp.WaitForExit(15000)
            $grabMs = $sw.ElapsedMilliseconds
            $after = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Sort-Object Left)
            $faces += @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace')
            $grabOut = (Read-Text (Join-Path $dir 'grab-fold-mid.txt')).Trim()
            "  $grabOut"
            "  strip faces on show around the grab: $(($faces | ForEach-Object { "$($_.Hwnd):$($_.Left)-$($_.Right)" }) -join ' ')"
            Start-Sleep -Milliseconds ($foldSlideMs + 800)
            [void](Send-TestMouse -Window $hw -Target $hw -X $xFold -Y $y -Action up -HoldMs 0)
            $rest = @(Get-TestChildWindows -Window $hw -Class 'GhozttyTerminal' | Where-Object Visible)
            "  short of the fold: $(($near | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '); grab done at +$grabMs ms; at rest $($rest.Count) on show"
            Assert "$arm.21 the approach did not fold (3 on show short of the fold point)" ($near.Count -eq 3)
            Assert "$arm.22 the grab finished mid-slide (+$grabMs ms of $foldSlideMs)" ($grabMs -lt ($foldSlideMs - 300))
            Assert "$arm.23 the drag folded s2 (2 on show at rest)" ($rest.Count -eq 2)
            Assert "$arm.24 WGC grabbed the mid-fold frame" (Test-Path $bmpPath)
            if (-not (Test-Path $bmpPath)) { continue }
            # s1's spot at the grab: what its window covered both before and
            # after, inset from its edges, top half below the prompt row (s2's
            # ink is in its own top half, at the same height). s1's own prompt
            # sits ~44 DIP down (padding + one row): start below it, or the
            # check reads s1's prompt as s2's ink.
            $s1b = $before | Where-Object { $_.Hwnd -eq $c3[1].Hwnd }
            $s1a = $after | Where-Object { $_.Hwnd -eq $c3[1].Hwnd }
            $l = [Math]::Max($s1b.Left, $s1a.Left) + 8; $r = [Math]::Min($s1b.Right, $s1a.Right) - 8
            # The card lies over s1 by design: s1 is scored left of it.
            # Before and after the grab, so the whole span the card swept
            # while the grab ran is left out.
            $faceL = $null; $faceR = $null
            if ($faces.Count -gt 0) {
                $faceL = ($faces | Measure-Object -Property Left -Minimum).Minimum
                $faceR = ($faces | Measure-Object -Property Right -Maximum).Maximum
                $r = [Math]::Min($r, $faceL - 8)
            }
            $tp = [Math]::Max($s1b.Top, $s1a.Top) + (Get-TestChromeDip -Dip 64 -Scale $scale)
            $bt = [Math]::Max($s1b.Top, $s1a.Top) + [int](($s1b.Bottom - $s1b.Top) / 2)
            $grabBmp = New-Object System.Drawing.Bitmap $bmpPath
            $g = Get-Pixels $grabBmp
            $grabBmp.Dispose()
            # -NegativeControl scores s2's own spot at rest instead: it is
            # inked, so the check must go red.
            $region = if ($NegativeControl) { @(($restRegion[0] + 8), ($restRegion[1] + 40), ($restRegion[2] - 8), ($restRegion[1] + 240)) }
                      else { @(($l + $offX), ($tp + $offY), ($r + $offX), ($bt + $offY)) }
            $region = @([Math]::Max(0, $region[0]), [Math]::Max(0, $region[1]), [Math]::Min($g.W, $region[2]), [Math]::Min($g.H, $region[3]))
            $inked = 0
            if ($region[2] -gt $region[0] -and $region[3] -gt $region[1]) {
                $src = if ($NegativeControl) { $script:lastGrab } else { $g }
                $rows = [InkMath]::RowInk($src.B, $src.Stride, $region[0], $region[1], $region[2], $region[3], 150)
                $inked = @($rows | Where-Object { $_ -ge 3 }).Count
            }
            "  $(if ($NegativeControl) { 'NEGATIVE CONTROL: s2 at rest' } else { 's1' }) spot on the grab $($region -join ','): $inked ink rows"
            Assert "$arm.25 s1's spot is a real area of the grab ($($region[2] - $region[0])x$($region[3] - $region[1]))" (($region[2] - $region[0]) -ge 40 -and ($region[3] - $region[1]) -ge 80)
            Assert "$arm.26 mid-fold, none of s2's ink is drawn over s1 ($inked ink rows, want <= 2)" ($inked -le 2)
            Assert "$arm.27 the grab took the window's owned popups ($grabOut)" ($grabOut -match 'popups=true')
            # The card: s2's ink inside the face's rect, top half below the
            # prompt row - where s2's marker lines are, carried at what is
            # left of the content's strength.
            $cardInk = 0
            if ($faces.Count -gt 0) {
                $cr = @(($faceL + 8 + $offX), ($tp + $offY), ($faceR - 8 + $offX), ($bt + $offY))
                $cr = @([Math]::Max(0, $cr[0]), [Math]::Max(0, $cr[1]), [Math]::Min($g.W, $cr[2]), [Math]::Min($g.H, $cr[3]))
                if ($cr[2] -gt $cr[0] -and $cr[3] -gt $cr[1]) {
                    $rows = [InkMath]::RowInk($g.B, $g.Stride, $cr[0], $cr[1], $cr[2], $cr[3], 150)
                    $cardInk = @($rows | Where-Object { $_ -ge 3 }).Count
                }
                "  s2's card on the grab $($cr -join ','): $cardInk ink rows"
            }
            Assert "$arm.28 mid-fold, s2's card is on the grab with its ink ($($faces.Count) face sightings, $cardInk ink rows, want >= 6)" ($faces.Count -gt 0 -and $cardInk -ge 6)
        }
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
