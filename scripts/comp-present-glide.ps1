# On-screen glide oracle for the composition present path (tracker T2512).
#
# comp-present-onscreen.ps1 (T2488) proved ONE still frame of the composition
# present right way up on screen. This films the motion: nine panes in a grid,
# a divider dragged under them, and EVERY frame DWM composes of the window
# scored pane by pane for a blank or a torn pane.
#
# The app runs as a GHOST on the input desktop, the way the T2488 and T2516
# oracles do (GHOZTTY_DEBUG_GHOST=bottom, debug builds only: opaque, a tool
# window that never activates, at the bottom of the z-order), with
# GHOZTTY_TEST_NO_OCCLUSION=1 so the renderer is not parked as occluded, and
# ghoztty-comp-spike.exe --film-hwnd records every composed frame with
# Windows.Graphics.Capture.
#
# The drag is POSTED to the window (WM_LBUTTONDOWN / WM_MOUSEMOVE /
# WM_LBUTTONUP with client coordinates), never sent through the real pointer:
# Send-TestMouse calls SetCursorPos, which on the input desktop would move the
# user's cursor. The app hit-tests and drags the divider from the message's
# own coordinates.
#
# The scene: each pane runs a tiny cmd script that fills its whole grid with
# one solid colour of its own (VT background + erase), hides the cursor and
# waits. Per frame, per pane colour:
#
#   blank  the colour covers less than half the area it covers in the settled
#          frame - the pane presented nothing, or a stale empty buffer.
#   torn   the colour region's LEFT edge is not one column top to bottom (more
#          than 4 px of spread), or rows inside it are missing: the top of the
#          pane presented at one place and the bottom at another. The left
#          edge is what is scored because a terminal resized under the drag
#          keeps column 0 where it is whether or not the shell has repainted
#          the new cells yet; the right and bottom edges legitimately lag.
#          The rows nearest the top and bottom are skipped (rounded cards).
#
# Arms: knob ON (GHOZTTY_COMP_PRESENT=1) is asserted; knob OFF (WGL
# SwapBuffers) is filmed and scored the same way and RECORDED beside it, not
# asserted - the WGL path's offset frames are T2485's to fix.
#
#   powershell -NoProfile -File scripts\comp-present-glide.ps1
#   powershell -NoProfile -File scripts\comp-present-glide.ps1 -Arms on
#   powershell -NoProfile -File scripts\comp-present-glide.ps1 -NegativeControl   # must go red
#
# -NegativeControl paints pane 5 over with the backdrop on every third frame
# and shifts the lower half of pane 7 sideways on the next one, before
# scoring: both the blank and the torn check must fail.
#
# It lives in scripts\ for the reason comp-present-onscreen.ps1 does: it needs
# the input desktop, and the person at the desk never sees or loses focus to
# anything it opens.

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Spike = 'D:\git\ghoztty\zig-out\bin\ghoztty-comp-spike.exe',
    [string[]]$Arms = @('on', 'off'),
    [string[]]$Drags = @('columns', 'rows'),
    # Wide enough that three columns of panes stay on show: narrower, the
    # last column folds into strips (T2124).
    [int]$Width = 1500,
    [int]$Height = 900,
    # Pixels per posted move and moves per drag.
    [int]$Step = 2,
    [int]$Moves = 30,
    [int]$StepMs = 16,
    [string]$OutDir,
    [switch]$KeepFrames,
    # Re-score films already in -OutDir (<arm>\<drag>\f*.bmp) without running
    # anything.
    [switch]$ScoreOnly,
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-glide-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GlWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
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
    // Visible descendants of class cls, as client rects of top: L,T,R,B each.
    public static int[] ChildRects(IntPtr top, string cls) {
        var list = new List<int>();
        EnumChildWindows(top, (h, l) => {
            var sb = new System.Text.StringBuilder(64);
            GetClassName(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                var a = new POINT { X = r.L, Y = r.T }; var b = new POINT { X = r.R, Y = r.B };
                ScreenToClient(top, ref a); ScreenToClient(top, ref b);
                list.Add(a.X); list.Add(a.Y); list.Add(b.X); list.Add(b.Y);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    static IntPtr Lp(int x, int y) { return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)); }
    // One divider drag, POSTED: hover, press, `moves` moves of (dx,dy) each
    // `stepMs` apart, release. Nothing touches the real cursor.
    public static void Drag(IntPtr h, int x, int y, int dx, int dy, int moves, int stepMs) {
        const uint MOVE = 0x0200, DOWN = 0x0201, UP = 0x0202;
        PostMessage(h, MOVE, IntPtr.Zero, Lp(x, y));
        System.Threading.Thread.Sleep(40);
        PostMessage(h, DOWN, (IntPtr)1, Lp(x, y));
        System.Threading.Thread.Sleep(60);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 1; i <= moves; i++) {
            PostMessage(h, MOVE, (IntPtr)1, Lp(x + dx * i, y + dy * i));
            long due = (long)i * stepMs;
            while (sw.ElapsedMilliseconds < due) System.Threading.Thread.Sleep(1);
        }
        PostMessage(h, UP, IntPtr.Zero, Lp(x + dx * moves, y + dy * moves));
    }
}
public static class GlScore {
    static bool Near(byte[] b, int o, int r, int g, int bl, int tol) {
        return Math.Abs(b[o + 2] - r) <= tol && Math.Abs(b[o + 1] - g) <= tol && Math.Abs(b[o] - bl) <= tol;
    }
    // Pixels within tol of (r,g,bl) and their mean colour: {count, r, g, b}.
    public static int[] Mean(byte[] b, int stride, int w, int h, int r, int g, int bl, int tol) {
        long n = 0, sr = 0, sg = 0, sb = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4)
            if (Near(b, o, r, g, bl, tol)) { n++; sr += b[o + 2]; sg += b[o + 1]; sb += b[o]; }
        if (n == 0) return new int[] { 0, 0, 0, 0 };
        return new int[] { (int)n, (int)(sr / n), (int)(sg / n), (int)(sb / n) };
    }
    // The region of colour (r,g,bl), counting only runs of >= minRun pixels
    // so a stray matching pixel in the chrome never widens it:
    // {count, minX, maxX, minY, maxY, leftSpread, gapRows}. leftSpread and
    // gapRows are read over the rows more than `skip` inside the top and
    // bottom of the region.
    public static int[] Region(byte[] b, int stride, int w, int h, int r, int g, int bl, int tol, int minRun, int skip) {
        var left = new int[h];
        int count = 0, minX = w, maxX = -1, minY = h, maxY = -1;
        for (int y = 0; y < h; y++) {
            left[y] = -1;
            int s = -1;
            for (int x = 0; x <= w; x++) {
                bool on = x < w && Near(b, y * stride + x * 4, r, g, bl, tol);
                if (on && s < 0) s = x;
                if (!on && s >= 0) {
                    int len = x - s;
                    if (len >= minRun) {
                        count += len;
                        if (left[y] < 0) left[y] = s;
                        if (s < minX) minX = s;
                        if (x - 1 > maxX) maxX = x - 1;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                    s = -1;
                }
            }
        }
        if (count == 0) return new int[] { 0, -1, -1, -1, -1, 0, 0 };
        int lo = int.MaxValue, hi = int.MinValue, gaps = 0;
        for (int y = minY + skip; y <= maxY - skip; y++) {
            if (left[y] < 0) { gaps++; continue; }
            if (left[y] < lo) lo = left[y];
            if (left[y] > hi) hi = left[y];
        }
        int spread = (lo == int.MaxValue) ? 0 : hi - lo;
        return new int[] { count, minX, maxX, minY, maxY, spread, gaps };
    }
    // Negative-control damage: fill a rectangle with one colour.
    public static void Fill(byte[] b, int stride, int x0, int y0, int x1, int y1, int r, int g, int bl) {
        for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
            int o = y * stride + x * 4; b[o] = (byte)bl; b[o + 1] = (byte)g; b[o + 2] = (byte)r;
        }
    }
    // Negative-control damage: shift rows [y0,y1] of [x0,x1] right by dx.
    public static void Shift(byte[] b, int stride, int w, int x0, int y0, int x1, int y1, int dx) {
        for (int y = y0; y <= y1; y++) for (int x = Math.Min(w - 1, x1 + dx); x >= x0; x--) {
            int src = x - dx, o = y * stride + x * 4;
            if (src < x0) { b[o] = 0x18; b[o + 1] = 0x14; b[o + 2] = 0x10; continue; }
            int so = y * stride + src * 4;
            b[o] = b[so]; b[o + 1] = b[so + 1]; b[o + 2] = b[so + 2];
        }
    }
}
'@

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}

function Get-Pixels($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        return [pscustomobject]@{ W = $bmp.Width; H = $bmp.Height; Stride = $stride; B = $bytes }
    } finally { $bmp.Dispose() }
}

# The nine pane colours, far apart from each other and from the dark backdrop.
$paneRgb = @(
    @(230, 40, 40), @(40, 200, 60), @(40, 80, 230),
    @(230, 210, 40), @(220, 50, 220), @(40, 210, 210),
    @(240, 140, 30), @(150, 60, 240), @(250, 150, 180))

$esc = [char]27
for ($i = 0; $i -lt 9; $i++) {
    $c = $paneRgb[$i]
    # ASCII bytes on purpose: cmd reads a .cmd file in the OEM code page.
    $body = "@echo off`r`necho $esc[48;2;$($c[0]);$($c[1]);$($c[2])m$esc[2J$esc[3J$esc[H$esc[?25l`r`npause >nul`r`n"
    [System.IO.File]::WriteAllText((Join-Path $OutDir "p$($i + 1).cmd"), $body, [System.Text.Encoding]::ASCII)
}
function PaneCommand($n) { return "--command=cmd.exe /d /c $(Join-Path $OutDir "p$n.cmd")" }

# Score one film against its settled (last) frame. On the knob-on arm the
# blank/torn counts are assertions; elsewhere they are recorded.
function Score-Film($arm, $drag, $frames, $assert) {
    $ref = Get-Pixels $frames[-1].FullName
    $refCount = @{}
    $tol = @{}
    $col = @{}
    $missing = @()
    for ($i = 0; $i -lt 9; $i++) {
        $c = $paneRgb[$i]
        $m = [GlScore]::Mean($ref.B, $ref.Stride, $ref.W, $ref.H, $c[0], $c[1], $c[2], 40)
        if ($m[0] -lt 2000) { $missing += "p$($i + 1)(n=$($m[0]))"; continue }
        # Score against the colour the screen actually shows, held tight.
        $col[$i] = @($m[1], $m[2], $m[3])
        $tol[$i] = 18
        $r = [GlScore]::Region($ref.B, $ref.Stride, $ref.W, $ref.H, $m[1], $m[2], $m[3], 18, 8, 12)
        $refCount[$i] = $r[0]
    }
    Assert "$arm.$drag.2 all nine panes are in the settled frame$(if ($missing.Count) { ': missing ' + ($missing -join ' ') })" ($missing.Count -eq 0)
    $script:film = @{ Blank = -1; Torn = -1; Frames = $frames.Count; Bad = 1 }
    if ($missing.Count) { return }

    $blank = 0; $torn = 0; $badLines = @()
    $layouts = @{}
    $k = 0
    foreach ($f in $frames) {
        $px = Get-Pixels $f.FullName
        if ($NegativeControl) {
            $phase = $k % 3
            if ($phase -eq 0) {
                $r5 = [GlScore]::Region($px.B, $px.Stride, $px.W, $px.H, $col[4][0], $col[4][1], $col[4][2], 18, 8, 12)
                if ($r5[0] -gt 0) { [GlScore]::Fill($px.B, $px.Stride, $r5[1], $r5[3], $r5[2], $r5[4], 0x10, 0x14, 0x18) }
            } elseif ($phase -eq 1) {
                $r7 = [GlScore]::Region($px.B, $px.Stride, $px.W, $px.H, $col[6][0], $col[6][1], $col[6][2], 18, 8, 12)
                if ($r7[0] -gt 0) {
                    $midY = [int](($r7[3] + $r7[4]) / 2)
                    [GlScore]::Shift($px.B, $px.Stride, $px.W, $r7[1], $midY, $r7[2], $r7[4], 24)
                }
            }
        }
        $why = @()
        $geo = @()
        for ($i = 0; $i -lt 9; $i++) {
            $r = [GlScore]::Region($px.B, $px.Stride, $px.W, $px.H, $col[$i][0], $col[$i][1], $col[$i][2], $tol[$i], 8, 12)
            $geo += "$($r[1]),$($r[3])"
            if ($r[0] -lt ($refCount[$i] / 2)) { $blank++; $why += "p$($i + 1) blank($($r[0])/$($refCount[$i]))" }
            elseif ($r[5] -gt 4 -or $r[6] -gt 2) { $torn++; $why += "p$($i + 1) torn(left_spread=$($r[5]) gap_rows=$($r[6]))" }
        }
        if ($why.Count) { $badLines += "$($f.BaseName) $($why -join ' ')" }
        # Under a drag the terminals are HELD at their size and the cards
        # move, so motion is read from where every pane sits, not its size.
        $layouts[$geo -join ' '] = 1
        $k++
    }
    "  frames=$($frames.Count) pane_frames=$($frames.Count * 9) blank=$blank torn=$torn layouts=$($layouts.Count)"
    $badLines | Select-Object -First 12 | ForEach-Object { "    $_" }
    Assert "$arm.$drag.3 the panes really moved on film ($($layouts.Count) distinct pane layouts)" ($layouts.Count -ge 5)
    if ($assert) {
        Assert "$arm.$drag.4 no pane frame is blank ($blank of $($frames.Count * 9))" ($blank -eq 0)
        Assert "$arm.$drag.5 no pane frame is torn ($torn of $($frames.Count * 9))" ($torn -eq 0)
    } else {
        "  RECORDED $arm.$drag blank=$blank torn=$torn of $($frames.Count * 9) pane frames (not asserted)"
    }
    # Handed back through a script variable: everything this function prints
    # is the report, so a return value would swallow the PASS/FAIL lines.
    $script:film = @{ Blank = $blank; Torn = $torn; Frames = $frames.Count; Bad = $badLines.Count }
}

if ($ScoreOnly) {
    foreach ($arm in $Arms) {
        foreach ($drag in $Drags) {
            "== $arm drag $drag (scored from $OutDir)"
            $frames = @(Get-ChildItem (Join-Path (Join-Path $OutDir $arm) $drag) -Filter 'f*.bmp' -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($frames.Count -lt 10) { Assert "$arm.$drag.1 film present ($($frames.Count) frames)" $false; continue }
            Score-Film $arm $drag $frames ($arm -eq 'on')
        }
    }
    if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
    "$script:failures FAILURE(S), $script:passes pass"
    exit 1
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'compglide')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

$summary = @()
try {
    foreach ($arm in $Arms) {
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=$(if ($arm -eq 'on') { '1' } else { 'unset' }))"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $armDir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $armDir | Out-Null
        $env:LOCALAPPDATA = $armDir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        if ($arm -eq 'on') { $env:GHOZTTY_COMP_PRESENT = '1' } else { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
        $err = Join-Path $armDir 'stderr.txt'
        # Unfocused panes are not dimmed, so every pane shows its own colour.
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=34', '--background=#101418',
            '--unfocused-split-opacity=1', '--undo-timeout=0', "--title=t2512-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([GlWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }

        $win = "gl$arm"
        & $Exe +new-window "--target=$win" (PaneCommand 1) 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([GlWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        [void][GlWin]::SetWindowPos($hw, [IntPtr]::Zero, 40, 40, $Width, $Height, 0x0014)
        Start-Sleep -Milliseconds 800

        # Nine named panes split off the window's first (unnamed) pane, which
        # keeps focus throughout; then one rearrange puts them in an even 3x3
        # grid - three splits in a row halve, so the last column would be a
        # quarter of the window and fold into strips. The rearrange leaves the
        # unnamed pane out, which closes it (at once: --undo-timeout=0).
        for ($n = 1; $n -le 9; $n++) {
            $d = if ($n % 2) { 'right' } else { 'down' }
            & $Exe +split "--target=$win" "--name=p$n" "--direction=$d" (PaneCommand $n) 2>$null | Out-Null
        }
        $col = { param($a, $b, $c) "{`"direction`":`"vertical`",`"ratio`":33.3,`"left`":{`"pane`":`"$a`"},`"right`":{`"direction`":`"vertical`",`"ratio`":50,`"left`":{`"pane`":`"$b`"},`"right`":{`"pane`":`"$c`"}}}" }
        $layout = "{`"direction`":`"horizontal`",`"ratio`":33.3,`"left`":$(& $col p1 p4 p7),`"right`":{`"direction`":`"horizontal`",`"ratio`":50,`"left`":$(& $col p2 p5 p8),`"right`":$(& $col p3 p6 p9)}}"
        # PowerShell 5.1 hands embedded quotes to a native exe unescaped; the
        # JSON has no spaces, so \" reaches the CLI as a plain quote.
        $ra = & $Exe +rearrange "--target=$win" "--layout=$($layout -replace '"', '\"')" 2>&1
        "  rearrange: $(($ra | Out-String).Trim())"
        $rects = @()
        for ($t = 0; $t -lt 60; $t++) {
            $rects = @([GlWin]::ChildRects($hw, 'GhozttyTerminal'))
            if ($rects.Count -ge 36) { break }
            Start-Sleep -Milliseconds 250
        }
        Assert "$arm.2 nine panes are up ($($rects.Count / 4))" ($rects.Count -ge 36)
        if ($rects.Count -lt 36) { continue }
        if ($arm -eq 'on') {
            $n = ([regex]::Matches((Read-Text $err), 'pane presents through a composition swap chain')).Count
            Assert "$arm.3 the panes present through the composition chain ($n)" ($n -ge 9)
        } else {
            Assert "$arm.3 no pane touched the composition path" ((Read-Text $err) -notmatch 'pane presents through a composition swap chain')
        }
        # Let the nine shells start and paint.
        Start-Sleep -Milliseconds 3000

        foreach ($drag in $Drags) {
            "== $arm drag $drag"
            $panes = @()
            $rects = @([GlWin]::ChildRects($hw, 'GhozttyTerminal'))
            for ($i = 0; $i -lt $rects.Count; $i += 4) {
                $panes += [pscustomobject]@{ L = $rects[$i]; T = $rects[$i + 1]; R = $rects[$i + 2]; B = $rects[$i + 3] }
            }
            $leftCol = @($panes | Sort-Object L | Select-Object -First 3 | Sort-Object T)
            $nextCol = @($panes | Where-Object { $_.L -gt $leftCol[0].L + 20 } | Sort-Object L, T)[0]
            if ($drag -eq 'columns') {
                # The root divider: between the first column and the rest.
                $x = [int](($leftCol[0].R + $nextCol.L) / 2); $y = [int](($leftCol[0].T + $leftCol[0].B) / 2)
                $dx = $Step; $dy = 0
            } else {
                # Inside the first column: between its first and second row.
                $x = [int](($leftCol[0].L + $leftCol[0].R) / 2); $y = [int](($leftCol[0].B + $leftCol[1].T) / 2)
                $dx = 0; $dy = $Step
            }
            "  divider at client ($x,$y), $Moves moves of ($dx,$dy)"
            $dir = Join-Path $armDir $drag
            if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object { Remove-Item $_.FullName } }
            $filmMs = 600 + $Moves * $StepMs + 1000
            $filmErr = Join-Path $armDir "$drag-film.txt"
            $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$dir`"", "--film-ms=$filmMs",
                "--pool-w=$($Width + 64)", "--pool-h=$($Height + 64)") -NoNewWindow -PassThru -RedirectStandardError $filmErr
            $ready = $false
            for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $dir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
            Assert "$arm.$drag.0 the film started" $ready
            Start-Sleep -Milliseconds 300
            [GlWin]::Drag($hw, $x, $y, $dx, $dy, $Moves, $StepMs)
            [void]$fp.WaitForExit(60000)
            $filmOut = (Read-Text $filmErr).Trim()
            "  $filmOut"
            Assert "$arm.$drag.1 the film finished" ($filmOut -match '^FILM ok')
            $frames = @(Get-ChildItem $dir -Filter 'f*.bmp' | Sort-Object Name)
            if ($frames.Count -lt 10) { Assert "$arm.$drag.2 enough frames ($($frames.Count))" $false; continue }
            Score-Film $arm $drag $frames ($arm -eq 'on')
            $s = $script:film
            $summary += "  $arm $drag frames=$($s.Frames) blank=$($s.Blank) torn=$($s.Torn)"
            if (-not $KeepFrames -and $s.Bad -eq 0) { Get-ChildItem $dir -Filter 'f*.bmp' | ForEach-Object { Remove-Item $_.FullName } }
        }

        $fgPid = [uint32]0
        [void][GlWin]::GetWindowThreadProcessId([GlWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

"== summary"
$summary
"  films kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
