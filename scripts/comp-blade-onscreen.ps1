# On-screen oracle for the tucked strips' blade shadows as compositor visuals
# (tracker T2796).
#
# In pane-tree mode (GHOZTTY_COMP_PRESENT + GHOZTTY_COMP_CHROME +
# GHOZTTY_COMP_PANE_TREE) each resting strip's blade shadow can leave the desk
# compose and go up as a picture of its own (blade_rides.zig), over the card
# layers under the desk's shadow root, kept off the bands in front of it. The
# desk then lays that strip's band WITHOUT its shadow, so the only way the
# shadow can be on screen in the blade arms is through the visual - which is
# what makes a pixel match against the baked desk a proof.
#
# Same filming technique as comp-shadow-onscreen.ps1 (T2741): a GHOST window
# on the input desktop (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates,
# bottom of the z-order), one whole frame taken with Windows.Graphics.Capture
# by ghoztty-comp-spike.exe --grab-hwnd. Each arm builds the same window: a
# named window split right three times, every pane cleared, cursor blink off,
# then narrowed (SetWindowPos, no activation) until two panes fold into
# strips beside the run.
#
# Arms (l = light window, d = dark window, both the solid card style):
#   - lbase/dbase:   GHOZTTY_COMP_SHADOWS=0. Every shadow - cards and blades -
#                    stays baked into the desk visual. The reference picture.
#   - lblade/dblade: everything rides. The log says the blades went up and
#                    none failed; the frame matches the base arm's.
#   - lnomask:       GHOZTTY_COMP_BLADES_NOMASK=1: the blade layers are laid
#                    without keeping off the bands in front. A positive
#                    control that the mask is measurable on screen: it must
#                    differ from lbase in MORE pixels than lblade does.
#   - ddouble:       GHOZTTY_COMP_BLADES_DOUBLE=1 (the desk keeps baking a
#                    blade that also went up). Only under -NegativeControl,
#                    which scores it as dblade: the match must then FAIL, or
#                    the comparison cannot tell one blade shadow from two.
#
#   powershell -NoProfile -File scripts\comp-blade-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-blade-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ (cursor, text rasterisation).
    [double]$MaxDiffShare = 0.002,
    # The fine match counts finer differences than the coarse one.
    [int]$MaskTolerance = 4,
    # The mask's positive control counts finer still: a blade's blur that
    # crosses onto a band in front is a level or two (T2743's unit test:
    # unmasked 7 vs masked 3 on a PALE band; on this window's strips the
    # first run measured nomask max 3 vs masked max 2).
    [int]$BladeMaskTolerance = 2,
    # How wide the window is narrowed to, in DIPs (blade-shadow.ps1's 680).
    [int]$NarrowDip = 680,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
$Exe = [IO.Path]::GetFullPath($Exe)
$Spike = [IO.Path]::GetFullPath($Spike)

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
. (Join-Path $testLib 'OccludedDisplay.ps1')   # T2650: a film of an occluded display is skipped, never scored
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Doptimize=Debug"; exit 2 }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-blade-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_COMP_SHADOWS',
    'GHOZTTY_COMP_BLADES', 'GHOZTTY_COMP_BLADES_NOMASK', 'GHOZTTY_COMP_BLADES_DOUBLE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BladeGhost {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
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
    // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE: a size, nothing else.
    public static bool Size(IntPtr h, int cx, int cy) { return SetWindowPos(h, IntPtr.Zero, 0, 0, cx, cy, 0x0002 | 0x0004 | 0x0010); }
    public static int Diff(byte[] a, byte[] b, int w, int h, int stride, int tol) {
        int n = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4) {
            int d = Math.Max(Math.Abs(a[o] - b[o]), Math.Max(Math.Abs(a[o + 1] - b[o + 1]), Math.Abs(a[o + 2] - b[o + 2])));
            if (d > tol) n++;
        }
        return n;
    }
    public static int MaxDiff(byte[] a, byte[] b, int w, int h, int stride) {
        int m = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4) {
            int d = Math.Max(Math.Abs(a[o] - b[o]), Math.Max(Math.Abs(a[o + 1] - b[o + 1]), Math.Abs(a[o + 2] - b[o + 2])));
            if (d > m) m = d;
        }
        return m;
    }
}
'@

function Get-Pixels($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $o = [pscustomobject]@{ W = $bmp.Width; H = $bmp.Height; Stride = $data.Stride; B = $bytes }
    $bmp.UnlockBits($data); $bmp.Dispose()
    return $o
}

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

$arms = @('lbase', 'lblade', 'lnomask', 'dbase', 'dblade')
if ($NegativeControl) { $arms += 'ddouble' }

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'bladeonscreen')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$grabs = @{}
try {
    foreach ($arm in $arms) {
        "== arm '$arm'"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        foreach ($k in 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PANE_TREE') { Set-Item "env:$k" '1' }
        Remove-Item env:GHOZTTY_COMP_SHADOWS, env:GHOZTTY_COMP_BLADES, env:GHOZTTY_COMP_BLADES_NOMASK, env:GHOZTTY_COMP_BLADES_DOUBLE -ErrorAction SilentlyContinue
        $base = $arm.EndsWith('base')
        if ($base) { $env:GHOZTTY_COMP_SHADOWS = '0' }
        if ($arm -eq 'lnomask') { $env:GHOZTTY_COMP_BLADES_NOMASK = '1' }
        if ($arm -eq 'ddouble') { $env:GHOZTTY_COMP_BLADES_DOUBLE = '1' }
        $bg = if ($arm.StartsWith('l')) { '#f4f4f2' } else { '#101418' }
        $err = Join-Path $dir 'stderr.txt'
        $appArgs = @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=160', '--window-height=34', "--background=$bg",
            '--cursor-style-blink=false', '--title=t2796-blade', '--macos-pane-glass=false')
        $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([BladeGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=blade' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([BladeGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split '--target=blade' '--direction=right' '--name=blade-s1' 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        & $Exe +split '--target=blade-s1' '--direction=right' '--name=blade-s2' 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        & $Exe +split '--target=blade-s2' '--direction=right' '--name=blade-s3' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'blade', 'blade-s1', 'blade-s2', 'blade-s3') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        $dpi = [int][BladeGhost]::GetDpiForWindow($hw)
        if ($dpi -le 0) { $dpi = 96 }
        [void][BladeGhost]::Size($hw, [int]($NarrowDip * $dpi / 96.0), [int](560 * $dpi / 96.0))
        # Past the fold glide, so every strip is at rest.
        Start-Sleep -Milliseconds 3000

        $text = Read-Text $err
        Assert "$arm.2 the desk visual attached" (Wait-Log $err 'chrome desk visual attached' 10000)
        $text = Read-Text $err
        Assert "$arm.4 the desk never fell back to GDI" ($text -notmatch 'chrome desk visual (failed|detached)')
        if ($base) {
            Assert "$arm.5 knob off: no blade went up" ($text -notmatch 'blade layer visuals up=[1-9]')
        } else {
            Assert "$arm.5 the strips' blades went up as visuals" (Wait-Log $err 'blade layer visuals up=[1-9]' 10000)
            $text = Read-Text $err
            Assert "$arm.6 no blade or shadow step failed" ($text -notmatch 'blade layer visual (show )?failed|pane shadow visual (show )?failed|chrome shadow layer failed')
            $m = [regex]::Matches($text, 'blade layer visuals up=(\d+)')
            if ($m.Count -gt 0) { "  blades up (last line): $($m[$m.Count - 1].Groups[1].Value)" }
        }

        $fgPid = [uint32]0
        [void][BladeGhost]::GetWindowThreadProcessId([BladeGhost]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

        $bmpPath = Join-Path $dir 'grab.bmp'
        $grabErr = Join-Path $dir 'grab.txt'
        $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
            -NoNewWindow -PassThru -RedirectStandardError $grabErr
        [void]$gp.WaitForExit(15000)
        $grabOut = (Read-Text $grabErr).Trim()
        "  $grabOut"
        Assert "$arm.7 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
        if (Test-Path $bmpPath) { $grabs[$arm] = Get-Pixels $bmpPath }
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

function Score($refArm, $arm, $label) {
    $ref = $grabs[$refArm]
    $g = $grabs[$arm]
    if (-not $ref -or -not $g) { Assert "$label.0 both frames to compare ($refArm, $arm)" $false; return $null }
    if ($ref.W -ne $g.W -or $ref.H -ne $g.H) {
        Assert "$label.0 the frames are the same size ($($ref.W)x$($ref.H) vs $($g.W)x$($g.H))" $false
        return $null
    }
    $total = $g.W * $g.H
    $diff = [BladeGhost]::Diff($ref.B, $g.B, $g.W, $g.H, $g.Stride, $Tolerance)
    $fine = [BladeGhost]::Diff($ref.B, $g.B, $g.W, $g.H, $g.Stride, $MaskTolerance)
    $max = [BladeGhost]::MaxDiff($ref.B, $g.B, $g.W, $g.H, $g.Stride)
    # Host output: a pipeline line here would ride out in the return value.
    Write-Host "  $arm vs ${refArm}: $($g.W)x$($g.H) differing=$diff ($('{0:P2}' -f ($diff / [double]$total))) fine(>$MaskTolerance)=$fine max=$max"
    return [pscustomobject]@{ Diff = $diff; Fine = $fine; Total = $total; Max = $max }
}

# The match: each blade arm (ddouble in dblade's place under -NegativeControl)
# against its own window's baked desk.
$pairs = @(@('lbase', 'lblade', 'lmatch'), @('dbase', $(if ($NegativeControl) { 'ddouble' } else { 'dblade' }), 'dmatch'))
$scores = @{}
foreach ($p in $pairs) {
    $r = Score $p[0] $p[1] $p[2]
    if ($r) {
        $scores[$p[1]] = $r
        Assert "$($p[2]).1 the $($p[1]) frame's shadows match the baked desk's (<= $('{0:P1}' -f $MaxDiffShare) differ by > $Tolerance)" ($r.Diff -le $r.Total * $MaxDiffShare)
        Assert "$($p[2]).2 ... and finely (<= $('{0:P1}' -f $MaxDiffShare) differ by > $MaskTolerance)" ($r.Fine -le $r.Total * $MaxDiffShare)
    }
}
# The mask is measurable: without it the bands in front come out darker
# where a blade's blur crosses onto them.
if ($grabs['lbase'] -and $grabs['lnomask'] -and $grabs['lblade']) {
    $b = $grabs['lbase']
    if ($b.W -eq $grabs['lnomask'].W -and $b.H -eq $grabs['lnomask'].H -and $b.W -eq $grabs['lblade'].W -and $b.H -eq $grabs['lblade'].H) {
        $nmFine = [BladeGhost]::Diff($b.B, $grabs['lnomask'].B, $b.W, $b.H, $b.Stride, $BladeMaskTolerance)
        $okFine = [BladeGhost]::Diff($b.B, $grabs['lblade'].B, $b.W, $b.H, $b.Stride, $BladeMaskTolerance)
        $more = $nmFine - $okFine
        Assert "mask.1 without the mask the frame differs from the baked desk in more pixels ($nmFine vs $okFine, at > $BladeMaskTolerance)" ($more -gt 0)
    } else { Assert 'mask.0 the frames are the same size' $false }
} else { Assert 'mask.0 lbase, lnomask and lblade frames to compare' $false }
"  grabs kept in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
