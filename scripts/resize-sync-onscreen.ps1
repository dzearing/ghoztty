# On-screen oracle for window-edge resize sync (tracker T2516).
#
# The user's report: dragging the window's edge with a terminal beside a
# viewer, the viewer's page landed beside its own address bar, over the
# terminal, the terminal ran under the viewer, and strips of bare desk showed.
# Every surface was moving on its own clock. None of that is visible on the
# background test desktop (DWM composes nothing there), so this films it the
# way comp-present-onscreen.ps1 does: the app runs as a GHOST window on the
# input desktop (GHOZTTY_DEBUG_GHOST=bottom, debug builds only: opaque, a
# tool window that never activates, at the bottom of the z-order, so the
# person at the desk never sees it or loses focus to it), and
# ghoztty-comp-spike.exe --film-hwnd records EVERY frame DWM composes of it
# with Windows.Graphics.Capture while this script resizes it.
#
# The scene: a terminal on a solid green background, split right with a viewer
# showing a solid magenta page. One row through both panes is read per frame.
# What is scored does not depend on where the layout puts the divider at any
# moment, only on the panes agreeing with each other and with the frame:
#
#   gap    the distance from the terminal's right edge to the page's left edge
#          (the divider gutter) is the same as at rest, within 2 px. A page
#          painted at its old place over the terminal shrinks it; a terminal
#          still at its old width under the viewer shrinks it; a pane that has
#          moved before its neighbour shows bare desk and grows it.
#   right  the page's right edge sits the same distance from the frame's right
#          edge as at rest - a page still at its old width is clipped by the
#          frame (shrink) or leaves desk (grow).
#   left   the terminal starts where it did at rest (frame-relative).
#   top    the page starts the same distance below the frame's top - the
#          address bar band has not been painted over or opened up.
#
# Drags (each a stream of SetWindowPos steps, ~one per frame, inside a
# WM_ENTERSIZEMOVE/WM_EXITSIZEMOVE pair like a real edge drag):
#   right-shrink, right-grow, left-shrink, left-grow
# Each step is posted to the window's own thread (SWP_ASYNCWINDOWPOS), where a
# real drag's modal size loop runs; -CrossThread keeps the old shape.
#
# Timing (T2516): set GHOZTTY_RESIZE_TRACE=1 and the app logs a QPC stamp per
# top-level message and per phase of the layout pass (`resize trace ...`) and
# what a fresh desk costs (`desk trace ...`); each film's frames.txt holds the
# compose's QPC time (100 ns units), so the two line up frame by frame. For
# release-speed numbers pass -Exe a ReleaseSafe build (`zig build
# -Dapp-runtime=win32 -Doptimize=ReleaseSafe --prefix zig-out-rsafe`): it keeps
# the -debug endpoints and honours the ghost knob, and is never published.
#
#   powershell -NoProfile -File scripts\resize-sync-onscreen.ps1
#   powershell -NoProfile -File scripts\resize-sync-onscreen.ps1 -NegativeControl   # must go red
#
# -NegativeControl shifts the page 40 px left in every filmed frame before it
# is scored, which is screenshot 1's defect: the gap check must fail.

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Spike = 'D:\git\ghoztty\zig-out\bin\ghoztty-comp-spike.exe',
    [string[]]$Drags = @('right-shrink', 'right-grow', 'left-shrink', 'left-grow'),
    [int]$Width = 1400,
    [int]$Height = 800,
    # Pixels per step and steps per drag.
    [int]$Step = 12,
    [int]$Steps = 30,
    [int]$StepMs = 16,
    [string]$OutDir,
    [switch]$KeepFrames,
    # Re-score films already in -OutDir without running anything.
    [switch]$ScoreOnly,
    [switch]$NegativeControl,
    # Resize from THIS thread (a plain cross-process SetWindowPos) instead of
    # posting each step to the window's own thread. Cross-process, Windows
    # shows the new frame before the app is even sent WM_WINDOWPOSCHANGED
    # (~20 ms on the 2026-10-30 trace), which no app-side change can close
    # and which a real edge drag - the modal size loop runs on the window's
    # thread - never does.
    [switch]$CrossThread
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-resize-sync-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RsWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
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
    // One edge drag: `steps` SetWindowPos calls `stepMs` apart, inside the
    // size-loop bracket a real drag raises. dx/dw are per-step deltas.
    public static void Drag(IntPtr h, int steps, int dx, int dw, int stepMs, bool crossThread) {
        const uint NOZ = 0x0004, NOACT = 0x0010;
        // SWP_ASYNCWINDOWPOS: the move runs on the window's own thread, which
        // is where a real edge drag's modal size loop calls SetWindowPos.
        uint ASYNC = crossThread ? 0u : 0x4000u;
        RECT r; GetWindowRect(h, out r);
        int x = r.L, y = r.T, w = r.R - r.L, hh = r.B - r.T;
        SendMessage(h, 0x0231, IntPtr.Zero, IntPtr.Zero); // WM_ENTERSIZEMOVE
        var sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 1; i <= steps; i++) {
            SetWindowPos(h, IntPtr.Zero, x + dx * i, y, w + dw * i, hh, NOZ | NOACT | ASYNC);
            long due = (long)i * stepMs;
            while (sw.ElapsedMilliseconds < due) System.Threading.Thread.Sleep(1);
        }
        // An async move is posted: let the last one land inside the bracket.
        var settle = System.Diagnostics.Stopwatch.StartNew();
        while (!crossThread && settle.ElapsedMilliseconds < 3000) {
            RECT n; GetWindowRect(h, out n);
            if (n.L == x + dx * steps && n.R - n.L == w + dw * steps) break;
            System.Threading.Thread.Sleep(2);
        }
        SendMessage(h, 0x0232, IntPtr.Zero, IntPtr.Zero); // WM_EXITSIZEMOVE
    }
}
public static class RsScore {
    static bool Near(byte[] b, int o, int r, int g, int bl, int tol) {
        return Math.Abs(b[o + 2] - r) <= tol && Math.Abs(b[o + 1] - g) <= tol && Math.Abs(b[o] - bl) <= tol;
    }
    // Longest run of colour (r,g,bl) on row y: [start, end] inclusive, or
    // {-1,-1}. `shift` moves every magenta pixel left (negative control).
    public static int[] Run(byte[] b, int stride, int w, int y, int r, int g, int bl, int tol) {
        int bestS = -1, bestE = -1, s = -1;
        for (int x = 0; x <= w; x++) {
            bool on = x < w && Near(b, y * stride + x * 4, r, g, bl, tol);
            if (on && s < 0) s = x;
            if (!on && s >= 0) { if (x - 1 - s > bestE - bestS) { bestS = s; bestE = x - 1; } s = -1; }
        }
        return new int[] { bestS, bestE };
    }
    // First row, scanning down column x, of colour (r,g,bl); -1 if none.
    public static int Top(byte[] b, int stride, int h, int x, int r, int g, int bl, int tol) {
        for (int y = 0; y < h; y++) if (Near(b, y * stride + x * 4, r, g, bl, tol)) return y;
        return -1;
    }
    // The chrome tint the green background gives the terminal card and the
    // viewer's bar: clearly green, never the blue-grey desk.
    static bool Greenish(byte[] b, int o) { return b[o + 1] - Math.Max(b[o + 2], b[o]) > 40; }
    // The nearest greenish column left of x0 on row y (the terminal card's
    // right edge, seen from the page), or -1.
    // Pixels on row y that are the window's flat background (bg) - what an
    // erase or a background fill leaves where the desk should be. The page,
    // the cards and the desk are never this colour; the bar is, so callers
    // read a row below it.
    public static int Flat(byte[] b, int stride, int w, int y, int r, int g, int bl) {
        int n = 0;
        for (int x = 0; x < w; x++) if (Near(b, y * stride + x * 4, r, g, bl, 6)) n++;
        return n;
    }
    public static int GreenLeftOf(byte[] b, int stride, int y, int x0) {
        for (int x = x0 - 1; x >= 0; x--) if (Greenish(b, y * stride + x * 4)) return x;
        return -1;
    }
    // The outermost greenish columns of the run of non-desk pixels holding x0
    // on row y: the bar's left and right edges.
    public static int[] GreenSpan(byte[] b, int stride, int w, int y, int x0, int maxDesk) {
        int l = -1, r = -1, desk = 0;
        for (int x = x0; x >= 0; x--) { if (Greenish(b, y * stride + x * 4)) { l = x; desk = 0; } else if (++desk > maxDesk) break; }
        desk = 0;
        for (int x = x0; x < w; x++) { if (Greenish(b, y * stride + x * 4)) { r = x; desk = 0; } else if (++desk > maxDesk) break; }
        return new int[] { l, r };
    }
}
'@

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}

# Score one frame: the four distances, or $null when a pane is missing.
function Measure-Frame($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        $w = $bmp.Width; $h = $bmp.Height
    } finally { $bmp.Dispose() }
    $y = [int]($h * 0.72)
    $m = [RsScore]::Run($bytes, $stride, $w, $y, 0xff, 0x00, 0xff, 24)
    if ($m[0] -lt 0) { return [pscustomobject]@{ W = $w; H = $h; Ok = $false; Why = 'no page' } }
    $mid = [int](($m[0] + $m[1]) / 2)
    $top = [RsScore]::Top($bytes, $stride, $h, $mid, 0xff, 0x00, 0xff, 24)
    $termR = [RsScore]::GreenLeftOf($bytes, $stride, $y, $m[0])
    # The bar's bottom row, just above the page: solid, no glyphs.
    $nav = [RsScore]::GreenSpan($bytes, $stride, $w, [Math]::Max(0, $top - 3), $mid, 3)
    if ($termR -lt 0 -or $nav[0] -lt 0) { return [pscustomobject]@{ W = $w; H = $h; Ok = $false; Why = "no terminal/bar (termR=$termR nav=$($nav[0]))" } }
    $shift = if ($NegativeControl) { 40 } else { 0 }
    return [pscustomobject]@{
        W = $w; H = $h; Ok = $true; Why = ''
        PageL = $m[0] - $shift; PageR = $m[1] - $shift
        Flat = [RsScore]::Flat($bytes, $stride, $w, $y, 0x20, 0xa0, 0x20)
        NavL = $nav[0]; NavR = $nav[1]
        Gap = ($m[0] - $shift) - $termR
        Right = $w - 1 - $nav[1]
        Top = $top
    }
}

# Score one drag's film. The reference is the LAST frame - the window settled
# at its final size - and it is held to the page-under-its-bar rule too, so a
# layout that is simply wrong at rest cannot become the yardstick.
function Score-Film($drag, $frames) {
    $ref = Measure-Frame $frames[-1].FullName
    Assert "$drag.2 terminal, bar and page are in the settled frame$(if (-not $ref.Ok) { ': ' + $ref.Why })" $ref.Ok
    if (-not $ref.Ok) { $script:lastBad = 1; return }
    "  settled $($ref.W)x$($ref.H): page=$($ref.PageL)..$($ref.PageR) bar=$($ref.NavL)..$($ref.NavR) gap=$($ref.Gap) right=$($ref.Right) top=$($ref.Top)"
    $badFrames = @()
    $flatFrames = 0
    $sizes = @{}
    foreach ($f in $frames) {
        $m = Measure-Frame $f.FullName
        $sizes["$($m.W)"] = 1
        $why = @()
        if (-not $m.Ok) { $why += $m.Why }
        else {
            if ([Math]::Abs($m.PageL - $m.NavL) -gt 2) { $why += "pageL=$($m.PageL)/barL=$($m.NavL)" }
            if ([Math]::Abs($m.PageR - $m.NavR) -gt 2) { $why += "pageR=$($m.PageR)/barR=$($m.NavR)" }
            if ([Math]::Abs($m.Gap - $ref.Gap) -gt 2) { $why += "gap=$($m.Gap)" }
            if ([Math]::Abs($m.Right - $ref.Right) -gt 2) { $why += "right=$($m.Right)" }
            if ([Math]::Abs($m.Top - $ref.Top) -gt 2) { $why += "top=$($m.Top)" }
            if ($m.Flat -gt 4) { $why += "flat=$($m.Flat)"; $flatFrames++ }
        }
        if ($why.Count -gt 0) { $badFrames += "$($f.BaseName) w=$($m.W) $($why -join ' ')" }
    }
    "  frames=$($frames.Count) widths=$($sizes.Count) bad=$($badFrames.Count) flat_background=$flatFrames"
    $badFrames | Select-Object -First 15 | ForEach-Object { "    $_" }
    Assert "$drag.3 the window really resized on film ($($sizes.Count) widths)" ($sizes.Count -ge 5)
    Assert "$drag.4 no frame shows the flat background where the desk belongs ($flatFrames)" ($flatFrames -eq 0)
    Assert "$drag.5 every frame shows terminal, bar and page at one geometry" ($badFrames.Count -eq 0)
    $script:lastBad = $badFrames.Count
}

if ($ScoreOnly) {
    foreach ($drag in $Drags) {
        "== drag $drag (scored from $OutDir)"
        $frames = @(Get-ChildItem (Join-Path $OutDir $drag) -Filter 'f*.bmp' | Sort-Object Name)
        if ($frames.Count -lt 5) { Assert "$drag.1 film present" $false; continue }
        Score-Film $drag $frames
    }
    if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
    "$script:failures FAILURE(S), $script:passes pass"
    exit 1
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'resizesync')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$html = Join-Path $OutDir 'page.html'
Set-Content -Path $html -Encoding ascii -Value '<!doctype html><html><head><title>t2516</title></head><body style="margin:0;background:#ff00ff;height:100vh"></body></html>'


try {
    $env:LOCALAPPDATA = $OutDir
    $env:GHOZTTY_DEBUG_GHOST = 'bottom'
    # A ghost sits under the user's windows, so the app would park its
    # renderer as occluded (T1951) after the first frame.
    $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
    $err = Join-Path $OutDir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        '--window-width=110', '--window-height=34', '--background=#20a020',
        '--title=t2516') -StdErr $err
    $top = $null
    for ($t = 0; $t -lt 100 -and -not $top; $t++) {
        $w = @([RsWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
        if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
    }
    Assert '0 the ghost window came up' ($null -ne $top)
    if (-not $top) { throw 'no window' }
    & $Exe +new-window '--target=rs' 2>$null | Out-Null
    $hw = $null
    for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
        $hw = @([RsWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
        if (-not $hw) { Start-Sleep -Milliseconds 200 }
    }
    Assert '1 the named window came up' ($null -ne $hw)
    if (-not $hw) { throw 'no named window' }
    & $Exe +send-keys '--target=rs' 'cls' Enter 2>$null | Out-Null
    & $Exe +split '--target=rs' '--name=rsview' '--direction=right' "--view=$html" 2>$null | Out-Null
    [void][RsWin]::SetWindowPos($hw, [IntPtr]::Zero, 40, 40, $Width, $Height, 0x0014)
    Start-Sleep -Milliseconds 4000

    foreach ($drag in $Drags) {
        "== drag $drag"
        # Every drag starts from the same frame.
        [void][RsWin]::SetWindowPos($hw, [IntPtr]::Zero, 40, 40, $Width, $Height, 0x0014)
        Start-Sleep -Milliseconds 1200
        $dx = 0; $dw = 0
        switch ($drag) {
            'right-shrink' { $dw = -$Step }
            'right-grow' { $dw = $Step }
            'left-shrink' { $dx = $Step; $dw = -$Step }
            'left-grow' { $dx = -$Step; $dw = $Step }
        }
        if ($dw -gt 0) {
            # Grow from a frame shrunk by the drag's length, so the window
            # ends where the others start.
            [void][RsWin]::SetWindowPos($hw, [IntPtr]::Zero, 40 - $dx * $Steps, 40, $Width - $dw * $Steps, $Height, 0x0014)
            Start-Sleep -Milliseconds 1200
        }
        $dir = Join-Path $OutDir $drag
        if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object { Remove-Item $_.FullName } }
        $filmMs = 900 + $Steps * $StepMs + 900
        $filmErr = Join-Path $OutDir "$drag-film.txt"
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$dir`"", "--film-ms=$filmMs",
            "--pool-w=$($Width + 64)", "--pool-h=$($Height + 64)") -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $dir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$drag.0 the film started" $ready
        Start-Sleep -Milliseconds 400
        [RsWin]::Drag($hw, $Steps, $dx, $dw, $StepMs, [bool]$CrossThread)
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$drag.1 the film finished" ($filmOut -match '^FILM ok')
        $frames = @(Get-ChildItem $dir -Filter 'f*.bmp' | Sort-Object Name)
        if ($frames.Count -lt 5) { Assert "$drag.2 enough frames ($($frames.Count))" $false; continue }

        Score-Film $drag $frames
        if (-not $KeepFrames -and $script:lastBad -eq 0) { Get-ChildItem $dir -Filter 'f*.bmp' | ForEach-Object { Remove-Item $_.FullName } }
    }

    $fgPid = [uint32]0
    [void][RsWin]::GetWindowThreadProcessId([RsWin]::GetForegroundWindow(), [ref]$fgPid)
    Assert "F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

"  films kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
