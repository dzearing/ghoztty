# On-screen oracle for card shadows as compositor visuals (tracker T2741).
#
# In pane-tree mode (GHOZTTY_COMP_PRESENT + GHOZTTY_COMP_CHROME +
# GHOZTTY_COMP_PANE_TREE) every pane's card shadow can leave the desk compose
# and go up as a visual of its own - a premultiplied picture under the desk's
# glow and overlay that panePlace/paneGlide move in the pane's own commit.
# The desk is then composed WITHOUT that card's shadow, so the only way the
# shadow can be on screen in the shadow arms is through the visual - which is
# what makes a pixel match against the baked desk a proof.
#
# Same filming technique as comp-desk-onscreen.ps1 (T2509): a GHOST window on
# the input desktop (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates,
# bottom of the z-order), one whole frame taken with Windows.Graphics.Capture
# by ghoztty-comp-spike.exe --grab-hwnd. Each arm builds the same window: a
# named window split top/bottom, both panes cleared, cursor blink off. The
# split is DOWN on purpose: the shadow falls downwards, so the upper card's
# reaches across the gap onto the lower card's top rim - the neighbour case
# the layer's mask exists for.
#
# Arms (l = light window, d = dark window, both the solid card style - its
# shadow is the strong one; g = dark window, glass panes, whose single soft
# shadow is faint):
#   - lbase/dbase/gbase: GHOZTTY_COMP_SHADOWS=0. The shadows stay baked into
#                        the desk visual. The reference picture.
#   - lshadow/dshadow/gshadow: the shadows are visuals. The log says both went up
#                        and none failed; the frame matches the base arm's.
#   - lnomask:           GHOZTTY_COMP_SHADOWS_NOMASK=1: the layers are laid
#                        without keeping off the neighbouring card. A positive
#                        control that the mask is measurable on screen: it
#                        must differ from lbase by MORE than lshadow does.
#   - ddouble:           GHOZTTY_COMP_SHADOWS_DOUBLE=1 (desk keeps baking a
#                        shadow that also went up). Only under -NegativeControl,
#                        which scores it as dshadow: the match must then FAIL,
#                        or the comparison cannot tell one shadow from two.
#
#   powershell -NoProfile -File scripts\comp-shadow-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-shadow-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ (cursor, text rasterisation).
    [double]$MaxDiffShare = 0.002,
    # The mask's positive control counts finer differences than the match.
    [int]$MaskTolerance = 4,
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-shadow-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_COMP_SHADOWS',
    'GHOZTTY_COMP_SHADOWS_NOMASK', 'GHOZTTY_COMP_SHADOWS_DOUBLE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ShadowGhost {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
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
    // Pixels whose largest channel differs by more than tol.
    public static int Diff(byte[] a, byte[] b, int w, int h, int stride, int tol) {
        int n = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4) {
            int d = Math.Max(Math.Abs(a[o] - b[o]), Math.Max(Math.Abs(a[o + 1] - b[o + 1]), Math.Abs(a[o + 2] - b[o + 2])));
            if (d > tol) n++;
        }
        return n;
    }
    // The largest channel difference anywhere.
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

$arms = @('lbase', 'lshadow', 'lnomask', 'dbase', 'dshadow', 'gbase', 'gshadow')
if ($NegativeControl) { $arms += 'ddouble' }

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'shadowonscreen')
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
        Remove-Item env:GHOZTTY_COMP_SHADOWS, env:GHOZTTY_COMP_SHADOWS_NOMASK, env:GHOZTTY_COMP_SHADOWS_DOUBLE -ErrorAction SilentlyContinue
        $base = $arm.EndsWith('base')
        if ($base) { $env:GHOZTTY_COMP_SHADOWS = '0' }
        if ($arm -eq 'lnomask') { $env:GHOZTTY_COMP_SHADOWS_NOMASK = '1' }
        if ($arm -eq 'ddouble') { $env:GHOZTTY_COMP_SHADOWS_DOUBLE = '1' }
        $bg = if ($arm.StartsWith('l')) { '#f4f4f2' } else { '#101418' }
        $err = Join-Path $dir 'stderr.txt'
        $appArgs = @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=34', "--background=$bg",
            '--cursor-style-blink=false', '--title=t2741-shadow',
            "--macos-pane-glass=$(if ($arm.StartsWith('g')) { 'true' } else { 'false' })")
        $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([ShadowGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=shadow' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([ShadowGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split '--target=shadow' '--direction=down' '--name=shadow-low' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'shadow', 'shadow-low') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 2500

        $text = Read-Text $err
        Assert "$arm.2 the desk visual attached" (Wait-Log $err 'chrome desk visual attached' 10000)
        Assert "$arm.3 both panes went into the window tree (adopts=2)" (Wait-Log $err 'adopted into the window tree \(adopts=2\)' 10000)
        $text = Read-Text $err
        Assert "$arm.4 the desk never fell back to GDI" ($text -notmatch 'chrome desk visual (failed|detached)')
        if ($base) {
            Assert "$arm.5 knob off: no shadow went up" ($text -notmatch 'pane shadow visuals up=[1-9]')
        } else {
            Assert "$arm.5 both cards' shadows went up as visuals" (Wait-Log $err 'pane shadow visuals up=2' 10000)
            $text = Read-Text $err
            Assert "$arm.6 no shadow step failed" ($text -notmatch 'pane shadow visual (show )?failed|chrome shadow layer failed')
        }

        $fgPid = [uint32]0
        [void][ShadowGhost]::GetWindowThreadProcessId([ShadowGhost]::GetForegroundWindow(), [ref]$fgPid)
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
    $diff = [ShadowGhost]::Diff($ref.B, $g.B, $g.W, $g.H, $g.Stride, $Tolerance)
    $fine = [ShadowGhost]::Diff($ref.B, $g.B, $g.W, $g.H, $g.Stride, $MaskTolerance)
    $max = [ShadowGhost]::MaxDiff($ref.B, $g.B, $g.W, $g.H, $g.Stride)
    # Host output: a pipeline line here would ride out in the return value.
    Write-Host "  $arm vs ${refArm}: $($g.W)x$($g.H) differing=$diff ($('{0:P2}' -f ($diff / [double]$total))) fine(>$MaskTolerance)=$fine max=$max"
    return [pscustomobject]@{ Diff = $diff; Fine = $fine; Total = $total; Max = $max }
}

# The match: each shadow arm (ddouble in dshadow's place under
# -NegativeControl) against its own window's baked desk.
$pairs = @(@('lbase', 'lshadow', 'lmatch'), @('dbase', $(if ($NegativeControl) { 'ddouble' } else { 'dshadow' }), 'dmatch'), @('gbase', 'gshadow', 'gmatch'))
$scores = @{}
foreach ($p in $pairs) {
    $r = Score $p[0] $p[1] $p[2]
    if ($r) {
        $scores[$p[1]] = $r
        Assert "$($p[2]).1 the $($p[1]) frame's shadows match the baked desk's (<= $('{0:P1}' -f $MaxDiffShare) differ by > $Tolerance)" ($r.Diff -le $r.Total * $MaxDiffShare)
        # And finely: a shadow laid twice is a few levels off over a wide
        # band (measured 3.6% of the frame at > 4 on the dark solid window).
        Assert "$($p[2]).2 ... and finely (<= $('{0:P1}' -f $MaxDiffShare) differ by > $MaskTolerance)" ($r.Fine -le $r.Total * $MaxDiffShare)
    }
}
# The mask is measurable: without it the lower card's rim and edge come out
# darker under the upper card's shadow, so the frame strays further from the
# baked desk than the masked one does.
$nm = Score 'lbase' 'lnomask' 'mask'
if ($nm -and $scores['lshadow']) {
    $more = $nm.Fine - $scores['lshadow'].Fine
    Assert "mask.1 without the mask the frame differs from the baked desk in more pixels (by $more > 100, at > $MaskTolerance)" ($more -gt 100)
}
"  grabs kept in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
