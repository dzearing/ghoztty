# On-screen oracle for a glass viewer pane (tracker T1915, checking T1885).
#
# T1885 made our own viewer pages (markdown, code, diff) see-through on the
# glass pane style: the web view paints nothing under the page, the page drops
# its background (`html.pane-glass`), and the viewer host paints the glass
# sheet - the terminal background at GLASS_TINT over the window's desk -
# underneath, including under the browser's in-process child window. Every
# piece of that was proven in the win32 lane except the composite itself: an
# off-desktop surface reads back black, so nothing could say whether the sheet
# actually shows through the page on screen.
#
# Same filming technique as comp-desk-onscreen.ps1 (T2509): a GHOST window on
# the input desktop (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates,
# bottom of the z-order, so the user never sees or loses focus to it), one
# whole frame taken with Windows.Graphics.Capture by ghoztty-comp-spike.exe
# --grab-hwnd. WGC films the window's own DWM composite, browser visuals
# included, whatever is stacked above it.
#
# The window: a terminal with a markdown viewer split to its right (one
# heading, so the lower half of the page is empty sheet), and an `.html` page
# (no background of its own, so the browser's white) split off as a third
# pane. The oracle finds the panes by their rects rather than assuming where
# the split tree put the third one.
#
# Arms:
#   - glass: --macos-pane-glass=true. Scored.
#   - solid: --macos-pane-glass=false, the same window. The positive control:
#            the viewer page is an opaque card there, and the glass arm's page
#            must not look like it.
#
# Assertions (glass arm):
#   seam   at every row of the empty lower half, the viewer's sheet just right
#          of the seam matches the terminal's sheet just left of it - the page
#          IS the same sheet of glass. A page left opaque, or a stale/black
#          area under the web view, fails here.
#   black  the empty page area has no never-painted (black) pixels.
#   solid  the glass page differs from the solid arm's page (positive control:
#          the comparison can tell glass from a card).
#   html   the .html page keeps its own (white) background on glass.
#
#   powershell -NoProfile -File scripts\glass-viewer-onscreen.ps1
#   powershell -NoProfile -File scripts\glass-viewer-onscreen.ps1 -NegativeControl   # must go red
#
# -NegativeControl scores the SOLID arm's viewer page against the glass arm's
# terminal sheet: an opaque page must fail the seam match.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string]$OutDir,
    # Largest per-channel difference allowed between the two sides of the seam
    # (row means), and between a glass page and a card before they count as
    # the same.
    [int]$Tolerance = 8,
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-glass-viewer-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GlassGhost {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    static string Cls(IntPtr h) { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString(); }
    public static IntPtr[] TopLevel(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == cls) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr[] Children(IntPtr top, string cls) {
        var list = new List<IntPtr>();
        EnumChildWindows(top, (h, l) => { if (IsWindowVisible(h) && Cls(h) == cls) list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    // What WGC films: the extended frame bounds (no invisible resize border).
    public static RECT Frame(IntPtr h) {
        RECT r;
        if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
        return r;
    }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    // Mean B,G,R of each row of [x0, x0+w) x [y0, y0+h): a double[h*3].
    public static double[] RowMeans(byte[] b, int stride, int x0, int y0, int w, int h) {
        var m = new double[h * 3];
        for (int y = 0; y < h; y++) {
            double sb = 0, sg = 0, sr = 0;
            for (int x = 0, o = (y0 + y) * stride + x0 * 4; x < w; x++, o += 4) { sb += b[o]; sg += b[o + 1]; sr += b[o + 2]; }
            m[y * 3] = sb / w; m[y * 3 + 1] = sg / w; m[y * 3 + 2] = sr / w;
        }
        return m;
    }
    // Near-black pixels in a rect.
    public static int Black(byte[] b, int stride, int x0, int y0, int w, int h) {
        int n = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = (y0 + y) * stride + x0 * 4; x < w; x++, o += 4)
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

# Largest per-channel gap between two row-mean profiles, over every row.
function Get-ProfileGap($a, $b) {
    $gap = 0.0
    for ($i = 0; $i -lt [Math]::Min($a.Length, $b.Length); $i++) { $gap = [Math]::Max($gap, [Math]::Abs($a[$i] - $b[$i])) }
    return [Math]::Round($gap, 1)
}
# Mean colour of a profile as "r,g,b".
function Format-Mean($p) {
    $s = @(0.0, 0.0, 0.0)
    for ($i = 0; $i -lt $p.Length; $i++) { $s[$i % 3] += $p[$i] }
    $n = $p.Length / 3
    return ('{0:N0},{1:N0},{2:N0}' -f ($s[2] / $n), ($s[1] / $n), ($s[0] / $n))
}

# Content: one heading, so the lower half of the page is empty sheet; an .html
# page with no background of its own.
$md = Join-Path $OutDir 'glass.md'
$html = Join-Path $OutDir 'plain.html'
[IO.File]::WriteAllText($md, "# Glass`n")
[IO.File]::WriteAllText($html, "<!doctype html><html><body><p>plain</p></body></html>`n")

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'glassviewer')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$shots = @{}
try {
    foreach ($arm in 'glass', 'solid') {
        "== arm '$arm'"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        $err = Join-Path $dir 'stderr.txt'
        $appArgs = @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=140', '--window-height=36', '--background=#101418',
            '--cursor-style-blink=false', '--macos-pane-style=elevated',
            "--macos-pane-glass=$(if ($arm -eq 'glass') { 'true' } else { 'false' })",
            '--title=t1915-glass')
        $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([GlassGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=glass' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([GlassGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +send-keys '--target=glass' 'cls' Enter 2>$null | Out-Null
        $o1 = & $Exe +split '--target=glass' '--direction=right' '--name=glass-md' "--view=$md" 2>&1 | Out-String
        Start-Sleep -Milliseconds 1500
        $o2 = & $Exe +split '--target=glass-md' '--direction=down' '--name=glass-html' "--view=$html" 2>&1 | Out-String
        $viewers = @()
        for ($t = 0; $t -lt 60 -and $viewers.Count -lt 2; $t++) {
            Start-Sleep -Milliseconds 250
            $viewers = @([GlassGhost]::Children($hw, 'GhozttyViewer'))
        }
        Assert "$arm.2 both viewer panes came up ($($viewers.Count); $($o1.Trim()) $($o2.Trim()))" ($viewers.Count -ge 2)
        $terms = @([GlassGhost]::Children($hw, 'GhozttyTerminal'))
        Assert "$arm.3 the terminal pane is there" ($terms.Count -ge 1)
        if ($viewers.Count -lt 2 -or $terms.Count -lt 1) { continue }
        Start-Sleep -Milliseconds 3000   # pages load, the shell clears

        $fgPid = [uint32]0
        [void][GlassGhost]::GetWindowThreadProcessId([GlassGhost]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)

        $bmpPath = Join-Path $dir 'grab.bmp'
        $grabErr = Join-Path $dir 'grab.txt'
        $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
            -NoNewWindow -PassThru -RedirectStandardError $grabErr
        [void]$gp.WaitForExit(15000)
        $grabOut = (Read-Text $grabErr).Trim()
        "  $grabOut"
        Assert "$arm.4 WGC grabbed a frame of the ghost" ($grabOut -match '^GRAB ok' -and (Test-Path $bmpPath))
        if (-not (Test-Path $bmpPath)) { continue }
        $px = Get-Pixels $bmpPath

        # Pane rects in grab coordinates. Where the split tree puts each pane
        # is not this oracle's subject, so the markdown viewer is found as the
        # viewer whose left edge sits right of the terminal (they share a
        # seam), and the .html viewer is the other one.
        $frame = [GlassGhost]::Frame($hw)
        $tr = [GlassGhost]::Rect($terms[0])
        $vr = @($viewers | ForEach-Object { [GlassGhost]::Rect($_) })
        $mdR = @($vr | Where-Object { $_.Left -ge $tr.Right -and $_.Top -le $tr.Top + 4 }) | Select-Object -First 1
        $htR = @($vr | Where-Object { -not ($_.Left -eq $mdR.Left -and $_.Top -eq $mdR.Top) }) | Select-Object -First 1
        "  frame $($frame.Left),$($frame.Top) $($frame.Right - $frame.Left)x$($frame.Bottom - $frame.Top); grab $($px.W)x$($px.H)"
        "  terminal $($tr.Left),$($tr.Top)-$($tr.Right),$($tr.Bottom)"
        foreach ($r in $vr) { "  viewer $($r.Left),$($r.Top)-$($r.Right),$($r.Bottom)" }
        Assert "$arm.5 a markdown viewer shares a seam with the terminal, right of it" ($null -ne $mdR -and $null -ne $htR)
        if (-not $mdR -or -not $htR) { continue }
        $ox = $frame.Left; $oy = $frame.Top
        # The terminal's empty rows below its prompt (lower half of the pane),
        # which the markdown page beside it covers too: its one heading is at
        # the top, so the page is empty sheet there.
        $termH = $tr.Bottom - $tr.Top
        $y0 = $tr.Top + [int]($termH * 0.5) - $oy
        $h = [int]($termH * 0.4)
        $strip = 16
        $termX = $tr.Right - $ox - 8 - $strip   # just left of the seam, inside the terminal
        $mdX = $mdR.Left - $ox + 8              # just right of the seam, inside the page
        $mdW = [int](($mdR.Right - $mdR.Left) * 0.6)
        $hx = $htR.Left - $ox + 8
        $hw2 = [int](($htR.Right - $htR.Left) * 0.6)
        $hy0 = $htR.Top - $oy + [int](($htR.Bottom - $htR.Top) * 0.5)
        $hh = [int](($htR.Bottom - $htR.Top) * 0.3)
        $inside = ($termX -ge 0 -and $mdX + $mdW -le $px.W -and $y0 -ge 0 -and $y0 + $h -le $px.H -and $h -gt 10 -and
            $hx -ge 0 -and $hx + $hw2 -le $px.W -and $hy0 + $hh -le $px.H -and $hh -gt 10)
        Assert "$arm.6 the sample rects lie inside the frame" $inside
        if (-not $inside) { continue }
        $shots[$arm] = [pscustomobject]@{
            Term  = [GlassGhost]::RowMeans($px.B, $px.Stride, $termX, $y0, $strip, $h)
            Seam  = [GlassGhost]::RowMeans($px.B, $px.Stride, $mdX, $y0, $strip, $h)
            Page  = [GlassGhost]::RowMeans($px.B, $px.Stride, $mdX, $y0, $mdW, $h)
            Black = [GlassGhost]::Black($px.B, $px.Stride, $mdX, $y0, $mdW, $h)
            Area  = $mdW * $h
            Html  = [GlassGhost]::RowMeans($px.B, $px.Stride, $hx, $hy0, $hw2, $hh)
            Log   = $err
        }
        $s = $shots[$arm]
        "  $arm terminal sheet $(Format-Mean $s.Term); page at seam $(Format-Mean $s.Seam); page $(Format-Mean $s.Page); html $(Format-Mean $s.Html); black $($s.Black) of $($s.Area)"
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

$g = $shots['glass']
$c = $shots['solid']
if (-not $g -or -not $c) {
    Assert "score.0 both arms measured" $false
} else {
    $pageSrc = if ($NegativeControl) { $c } else { $g }
    if ($NegativeControl) { "  NEGATIVE CONTROL: scoring the solid arm's page as the glass page - the seam MUST fail" }
    $seamGap = Get-ProfileGap $g.Term $pageSrc.Seam
    Assert "seam the page's sheet matches the terminal's at every row across the seam (gap $seamGap <= $Tolerance)" ($seamGap -le $Tolerance)
    Assert "black no never-painted pixels under the page ($($g.Black) of $($g.Area))" ($g.Black -le $g.Area * 0.001)
    $cardGap = Get-ProfileGap $g.Page $c.Page
    Assert "solid the glass page differs from the solid card ($cardGap > $Tolerance)" ($cardGap -gt $Tolerance)
    $hm = (Format-Mean $g.Html) -split ','
    Assert "html the .html page keeps its own white background on glass ($($hm -join ','))" (([int]$hm[0]) -ge 235 -and ([int]$hm[1]) -ge 235 -and ([int]$hm[2]) -ge 235)
}
"  grabs kept in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
