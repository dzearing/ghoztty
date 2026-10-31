# On-screen oracle for the desk on the chrome compositor (tracker T2509).
#
# With GHOZTTY_COMP_CHROME=1 the window stops blitting the desk (the gradient,
# every card's shadow, corners and rim) into its own pixels and uploads it into
# the chrome host's bottom composition visual instead. The window's pixels
# under that visual are then never painted, so the only way the desk can be on
# screen in that arm is through the visual - which is what makes a pixel match
# against the GDI desk a proof rather than a coincidence.
#
# Same filming technique as comp-chrome-onscreen.ps1 (T2508): a GHOST window
# on the input desktop (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates,
# bottom of the z-order), one whole frame taken with Windows.Graphics.Capture
# by ghoztty-comp-spike.exe --grab-hwnd. Each arm builds the same window: a
# named window split in two, both panes cleared, cursor blink off.
#
# Arms:
#   - gdi:    knob off. The reference picture.
#   - visual: knob on. The log says the desk visual attached and took uploads;
#             the frame matches gdi's to within rounding.
#   - fill:   knob on with the debug test fill (the desk stays GDI under a
#             magenta visual). Only used by -NegativeControl, which scores it
#             as the visual arm: the match must then FAIL, or the comparison
#             cannot tell a desk from no desk.
#
#   powershell -NoProfile -File scripts\comp-desk-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-desk-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Spike = 'D:\git\ghoztty\zig-out\bin\ghoztty-comp-spike.exe',
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ (cursor, text rasterisation).
    [double]$MaxDiffShare = 0.002,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Doptimize=Debug"; exit 2 }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-desk-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_CHROME_TEST_FILL', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DeskGhost {
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
    // Near-black pixels: what never-painted window pixels read as.
    public static int Black(byte[] b, int w, int h, int stride) {
        int n = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4)
            if (b[o] + b[o + 1] + b[o + 2] <= 6) n++;
        return n;
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

$arms = @('gdi', 'visual')
if ($NegativeControl) { $arms += 'fill' }

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'deskonscreen')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$grabs = @{}
$logs = @{}
try {
    foreach ($arm in $arms) {
        "== arm '$arm'"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        Remove-Item env:GHOZTTY_COMP_CHROME, env:GHOZTTY_COMP_CHROME_TEST_FILL -ErrorAction SilentlyContinue
        if ($arm -ne 'gdi') { $env:GHOZTTY_COMP_CHROME = '1' }
        if ($arm -eq 'fill') { $env:GHOZTTY_COMP_CHROME_TEST_FILL = '1' }
        $err = Join-Path $dir 'stderr.txt'
        $logs[$arm] = $err
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=30', '--background=#101418',
            '--cursor-style-blink=false', '--title=t2509-desk') -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([DeskGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=desk' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([DeskGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split '--target=desk' '--direction=right' '--name=desk-right' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'desk', 'desk-right') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 2000

        if ($arm -eq 'visual') {
            Assert "$arm.2 the desk visual attached" (Wait-Log $err 'chrome desk visual attached' 10000)
            Assert "$arm.3 the desk never fell back to GDI" ((Read-Text $err) -notmatch 'chrome desk visual (failed|detached)')
        } elseif ($arm -eq 'fill') {
            Assert "$arm.2 the test fill is up (the desk stays GDI under it)" (Wait-Log $err 'chrome composition test fill attached' 10000)
        } else {
            Assert "$arm.2 knob off: no chrome host" ((Read-Text $err) -notmatch 'chrome composition')
        }

        $fgPid = [uint32]0
        [void][DeskGhost]::GetWindowThreadProcessId([DeskGhost]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

        $bmpPath = Join-Path $dir 'grab.bmp'
        $grabErr = Join-Path $dir 'grab.txt'
        $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
            -NoNewWindow -PassThru -RedirectStandardError $grabErr
        [void]$gp.WaitForExit(15000)
        $grabOut = (Read-Text $grabErr).Trim()
        "  $grabOut"
        Assert "$arm.4 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
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

# Score: the visual arm's frame (the fill arm's under -NegativeControl)
# against the GDI reference.
$ref = $grabs['gdi']
$src = if ($NegativeControl) { 'fill' } else { 'visual' }
$g = $grabs[$src]
if (-not $ref -or -not $g) {
    Assert "match.0 both frames to compare" $false
} elseif ($ref.W -ne $g.W -or $ref.H -ne $g.H) {
    Assert "match.0 the frames are the same size ($($ref.W)x$($ref.H) vs $($g.W)x$($g.H))" $false
} else {
    $total = $g.W * $g.H
    $diff = [DeskGhost]::Diff($ref.B, $g.B, $g.W, $g.H, $g.Stride, $Tolerance)
    $blackRef = [DeskGhost]::Black($ref.B, $ref.W, $ref.H, $ref.Stride)
    $black = [DeskGhost]::Black($g.B, $g.W, $g.H, $g.Stride)
    "  $src vs gdi: $($g.W)x$($g.H) differing=$diff ($('{0:P2}' -f ($diff / [double]$total))) black=$black (gdi $blackRef)"
    Assert "match.1 the $src frame's desk matches the GDI desk (<= $('{0:P1}' -f $MaxDiffShare) differ by > $Tolerance)" ($diff -le $total * $MaxDiffShare)
    Assert "match.2 no never-painted (black) pixels beyond the GDI frame's" ($black -le $blackRef + $total * 0.001)
}
"  grabs kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
