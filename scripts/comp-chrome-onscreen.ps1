# On-screen oracle for the window-chrome composition host (tracker T2508).
#
# test\win32\comp-chrome.ps1 proves the host builds, rebuilds after a device
# loss and that its Direct2D context can draw into a composition surface - on
# the background test desktop, which DWM never composes. What it cannot see is
# WHERE that surface lands in the picture DWM shows, and that is the fact every
# later chrome step (T2509-T2511) stands on: a visual on the top-level target
# (topmost=FALSE) must compose ABOVE the window's own GDI pixels and BELOW its
# pane child windows.
#
# So this films it, the T2488 way: the app runs as a GHOST window on the input
# desktop (GHOZTTY_DEBUG_GHOST=bottom, debug builds only: opaque, a tool window
# that never activates, bottom of the z-order) with the debug test fill on
# (GHOZTTY_COMP_CHROME_TEST_FILL=1: one magenta visual the size of the client
# area), and ghoztty-comp-spike.exe --grab-hwnd takes one whole frame of it
# with Windows.Graphics.Capture.
#
# Per arm (fill = knob + fill seam on; off = neither):
#
#   - fill arm: magenta covers part of the window (it is above the GDI chrome:
#     were it below, the opaque chrome would hide every pixel of it), and the
#     pane, located by its own content, shows NO magenta (it is below the
#     pane child window).
#   - off arm: no magenta anywhere - so the magenta in the fill arm is the
#     visual, not something the window paints.
#
# It lives in scripts\ for the reason comp-present-onscreen.ps1 does: it needs
# the input desktop, and the person at the desk never loses focus to it.
#
#   powershell -NoProfile -File scripts\comp-chrome-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-chrome-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Spike = 'D:\git\ghoztty\zig-out\bin\ghoztty-comp-spike.exe',
    [string[]]$Arms = @('fill', 'off'),
    [string]$OutDir,
    # Score the fill arm's grab as if it were the off arm's and vice versa:
    # both arms must then FAIL, or the checks cannot tell the two apart.
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-chrome-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_CHROME_TEST_FILL', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ChromeGhost {
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
    // Magenta (the test fill): high red and blue, low green.
    static bool M(byte[] b, int o) { return b[o + 2] >= 230 && b[o] >= 230 && b[o + 1] <= 40; }
    public static int Count(byte[] b, int stride, int x0, int y0, int x1, int y1) {
        int n = 0;
        for (int y = y0; y < y1; y++) for (int x = x0, o = y * stride + x0 * 4; x < x1; x++, o += 4) if (M(b, o)) n++;
        return n;
    }
    // Ink (bright text on the dark pane) per row and per column of a region,
    // to find the pane by its own content.
    public static int Ink(byte[] b, int stride, int x0, int y0, int x1, int y1) {
        int n = 0;
        for (int y = y0; y < y1; y++) for (int x = x0, o = y * stride + x0 * 4; x < x1; x++, o += 4)
            if (b[o] + b[o + 1] + b[o + 2] >= 450 && !M(b, o)) n++;
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

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'chromeonscreen')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$grabs = @{}
try {
    foreach ($arm in $Arms) {
        "== arm '$arm'"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        if ($arm -eq 'fill') { $env:GHOZTTY_COMP_CHROME = '1'; $env:GHOZTTY_COMP_CHROME_TEST_FILL = '1' }
        else { Remove-Item env:GHOZTTY_COMP_CHROME, env:GHOZTTY_COMP_CHROME_TEST_FILL -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#101418',
            "--title=t2508-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([ChromeGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        if ($arm -eq 'fill') {
            Assert "$arm.1 the test fill was attached" (Wait-Log $err 'chrome composition test fill attached' 15000)
        } else {
            Start-Sleep -Milliseconds 1500
            Assert "$arm.1 no chrome host was built" ((Read-Text $err) -notmatch 'chrome composition')
        }
        # A named window to type into and grab; the startup one has no name.
        & $Exe +new-window "--target=chrome$arm" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([ChromeGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.N the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        $top = $hw
        # Bright text to find the pane by.
        & $Exe +send-keys "--target=chrome$arm" 'cls' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 600
        & $Exe +send-keys "--target=chrome$arm" 'for /L %i in (1,1,12) do @echo ################ T2508-MARK-%i ################################' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500

        $fgPid = [uint32]0
        [void][ChromeGhost]::GetWindowThreadProcessId([ChromeGhost]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

        $bmpPath = Join-Path $dir 'grab.bmp'
        $grabErr = Join-Path $dir 'grab.txt'
        $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$top)", "--out=`"$bmpPath`"") `
            -NoNewWindow -PassThru -RedirectStandardError $grabErr
        [void]$gp.WaitForExit(15000)
        $grabOut = (Read-Text $grabErr).Trim()
        "  $grabOut"
        Assert "$arm.2 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
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

# Score. Under -NegativeControl each arm is scored against the OTHER's grab.
foreach ($arm in $Arms) {
    $src = $arm
    if ($NegativeControl) { $src = @($Arms | Where-Object { $_ -ne $arm })[0] }
    $g = $grabs[$src]
    if (-not $g) { Assert "$arm.3 a grab to score" $false; continue }
    $total = $g.W * $g.H
    $mag = [ChromeGhost]::Count($g.B, $g.Stride, 0, 0, $g.W, $g.H)
    # The pane: the bounding box of the bright marker text, shrunk to the
    # rows and columns the markers occupy. Text never sits on the chrome.
    $rows = @(0..($g.H - 1) | Where-Object { [ChromeGhost]::Ink($g.B, $g.Stride, 0, $_, $g.W, $_ + 1) -ge 8 })
    $line = "  $arm (scored from $src): grab $($g.W)x$($g.H) magenta=$mag ($('{0:P1}' -f ($mag / [double]$total))) ink_rows=$($rows.Count)"
    if ($arm -eq 'fill') {
        Assert "$arm.3 the fill is ABOVE the GDI chrome: magenta covers >= 1% of the window" ($mag -ge ($total * 0.01))
        $paneMag = -1
        if ($rows.Count -ge 8) {
            $y0 = $rows[0]; $y1 = $rows[-1] + 1
            # A column of the marker text is bright in 12+ lines of glyphs;
            # a sidebar icon (a child window too, but not the pane) is not.
            $cols = @(0..($g.W - 1) | Where-Object { [ChromeGhost]::Ink($g.B, $g.Stride, $_, $y0, $_ + 1, $y1) -ge 40 })
            if ($cols.Count -gt 0) {
                $x0 = $cols[0]; $x1 = $cols[-1] + 1
                $paneMag = [ChromeGhost]::Count($g.B, $g.Stride, $x0, $y0, $x1, $y1)
                $line += " pane_text_box=${x0},${y0}-${x1},${y1} pane_magenta=$paneMag"
            }
        }
        $line
        Assert "$arm.4 the fill is BELOW the pane: its text box shows no magenta" ($paneMag -eq 0)
    } else {
        $line
        Assert "$arm.3 knob off: no magenta anywhere" ($mag -eq 0)
        Assert "$arm.4 knob off: the pane text is on screen" ($rows.Count -ge 8)
    }
}

"  grabs kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
