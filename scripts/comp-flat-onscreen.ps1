# On-screen oracle for the flat pane style on the chrome compositor (tracker
# T2545).
#
# With GHOZTTY_COMP_CHROME=1 the elevated style's desk is a composition visual
# (T2509). The flat style has no desk to compose, so before T2545 a flat window
# kept every pixel it owns between the panes on GDI. Now those painters - the
# gutters' background, the divider lines, the hovered or dragged gutter's bar,
# the strips of tucked panes and their names - draw into a mirror, and what
# they change goes up to the desk visual by dirty rectangle. The window's own
# pixels under that visual are never painted, so a divider line or a strip can
# only be on screen in that arm through the visual: a pixel match against the
# GDI picture is a proof, not a coincidence.
#
# Same filming technique as comp-overlay-onscreen.ps1 (T2544): a GHOST window
# (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates, bottom of the z-order),
# one whole frame taken with Windows.Graphics.Capture by
# ghoztty-comp-spike.exe --grab-hwnd. The divider is pressed and dragged with
# POSTED mouse messages in client pixels, so nothing ever takes the user's
# pointer or focus.
#
# Frames, each knob-on against knob-off:
#   - split:    two panes side by side - the gutter and its line.
#   - held:     the divider pressed and dragged 80 px left, still held - the
#               hot line and the gutter bar at the new place, and the old
#               gutter gone (a dirty-rect upload, not a whole one).
#   - released: the press let go - the moved line at rest, no bar.
#   - stack:    two more panes than the row holds - the strips of the tucked
#               panes, with their names.
#   - headers:  rearrange mode - the flat style's headers are GDI, so the flat
#               desk must leave the compositor for them (the log says it did).
#
# Every frame is matched whole. Before T2569 the drag frames were matched
# below the caption band only: on GDI the gutter bar's glow reached past the
# grid and painted the terminal background over the bottom of the tab bar, and
# that smear stayed after the release. The bar's blit is clipped below the
# chrome now, as the desk visual is, so both arms' bands must equal the band
# of the GDI split frame, taken before any drag.
#
# Arms:
#   - gdi:    knob off. The reference pictures.
#   - visual: knob on. The log says the flat desk went up on the desk visual
#             and never came off; every frame matches gdi's within rounding.
#   - fill:   knob on with the debug test fill (the window stays GDI under a
#             magenta visual). Only with -NegativeControl, scored as the
#             visual arm's split frame: the match must FAIL.
#   - freeze: knob on with GHOZTTY_COMP_CHROME_FLAT_FREEZE (the flat desk sends
#             only whole pictures). Only with -NegativeControl, scored as the
#             visual arm's held frame: the match must FAIL, or a line that
#             stayed where the divider was would pass.
#
#   powershell -NoProfile -File scripts\comp-flat-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-flat-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ (~200 px at the default size).
    # A divider line left behind is 1-2 px wide down the pane's height - a few
    # hundred px - so this is as tight as comp-overlay-onscreen's.
    [double]$MaxDiffShare = 0.0003,
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
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Doptimize=Debug"; exit 2 }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-flat-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_CHROME_TEST_FILL', 'GHOZTTY_COMP_CHROME_FLAT_FREEZE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class FlatGhost {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, int n);
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
    // Every visible child of `cls`, as "left top right bottom" in the
    // top-level's client pixels.
    public static string[] ChildRects(IntPtr top, string cls) {
        var list = new List<string>();
        EnumChildWindows(top, (h, l) => {
            if (IsWindowVisible(h) && Cls(h) == cls) {
                RECT r; GetWindowRect(h, out r);
                MapWindowPoints(IntPtr.Zero, top, ref r, 2);
                list.Add(r.Left + " " + r.Top + " " + r.Right + " " + r.Bottom);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr FirstChild(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            if (IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // A bare key, posted: no focus, no keyboard state.
    public static void Tap(IntPtr h, int vk, int scan) {
        uint down = 1u | ((uint)scan << 16);
        PostMessage(h, 0x100, (IntPtr)vk, (IntPtr)(long)down);
        PostMessage(h, 0x101, (IntPtr)vk, (IntPtr)unchecked((int)(down | 0xC0000000u)));
    }
    static IntPtr Pt(int x, int y) { return (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)); }
    // Client-pixel mouse messages, posted: no pointer, no focus.
    public static void Down(IntPtr h, int x, int y) { PostMessage(h, 0x201, (IntPtr)1, Pt(x, y)); }
    public static void Move(IntPtr h, int x, int y) { PostMessage(h, 0x200, (IntPtr)1, Pt(x, y)); }
    public static void Up(IntPtr h, int x, int y) { PostMessage(h, 0x202, IntPtr.Zero, Pt(x, y)); }
    // Pixels of rows [y0, y1) whose largest channel differs by more than tol.
    public static int Diff(byte[] a, byte[] b, int w, int y0, int y1, int stride, int tol) {
        int n = 0;
        for (int y = y0; y < y1; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4) {
            int d = Math.Max(Math.Abs(a[o] - b[o]), Math.Max(Math.Abs(a[o + 1] - b[o + 1]), Math.Abs(a[o + 2] - b[o + 2])));
            if (d > tol) n++;
        }
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

function Wait-Log($err, $pattern, $before, $ms) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if (([regex]::Matches((Read-Text $err), $pattern)).Count -gt $before) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Grab($arm, $dir, $hw, $name) {
    $bmpPath = Join-Path $dir "$name.bmp"
    $grabErr = Join-Path $dir "$name.txt"
    $gp = Start-Process -FilePath $Spike -ArgumentList @("--grab-hwnd=$([int64]$hw)", "--out=`"$bmpPath`"") `
        -NoNewWindow -PassThru -RedirectStandardError $grabErr
    [void]$gp.WaitForExit(15000)
    $out = (Read-Text $grabErr).Trim()
    "  $name`: $out"
    Assert "$arm.$name WGC grabbed the frame" ($out -match '^GRAB ok' -and (Test-Path $bmpPath))
    if (Test-Path $bmpPath) { $script:frames["$arm/$name"] = Get-Pixels $bmpPath }
}

$arms = @('gdi', 'visual')
if ($NegativeControl) { $arms += 'fill', 'freeze' }

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'flatonscreen')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

$script:frames = @{}
try {
    foreach ($arm in $arms) {
        "== arm '$arm'"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        Remove-Item env:GHOZTTY_COMP_CHROME, env:GHOZTTY_COMP_CHROME_TEST_FILL, env:GHOZTTY_COMP_CHROME_FLAT_FREEZE -ErrorAction SilentlyContinue
        if ($arm -ne 'gdi') { $env:GHOZTTY_COMP_CHROME = '1' }
        if ($arm -eq 'fill') { $env:GHOZTTY_COMP_CHROME_TEST_FILL = '1' }
        if ($arm -eq 'freeze') { $env:GHOZTTY_COMP_CHROME_FLAT_FREEZE = '1' }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=30', '--background=#101418',
            '--macos-pane-style=flat', '--split-divider-color=#5a6878',
            '--cursor-style-blink=false', '--title=t2545-flat',
            '--keybind=f9=toggle_rearrange_mode') -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([FlatGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=flat' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([FlatGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split '--target=flat' '--direction=right' '--name=flat-right' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'flat', 'flat-right') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 2000
        Grab $arm $dir $hw 'split'

        # The divider: between the two panes' facing edges.
        $rects = @([FlatGhost]::ChildRects($hw, 'GhozttyTerminal') | ForEach-Object { , ([int[]]($_ -split ' ')) } | Sort-Object { $_[0] })
        Assert "$arm.2 two panes side by side ($($rects.Count))" ($rects.Count -eq 2)
        if ($rects.Count -eq 2) {
            $gx = [int](($rects[0][2] + $rects[1][0]) / 2)
            $gy = [int](($rects[0][1] + $rects[0][3]) / 2)
            $script:contentTop = [int]$rects[0][1]
            "  gutter at x=$gx y=$gy (left pane ends $($rects[0][2]), right starts $($rects[1][0]))"
            $before = ([regex]::Matches((Read-Text $err), 'divider drag released')).Count
            [FlatGhost]::Down($hw, $gx, $gy)
            Start-Sleep -Milliseconds 300
            for ($s = 1; $s -le 8; $s++) { [FlatGhost]::Move($hw, $gx - 10 * $s, $gy); Start-Sleep -Milliseconds 60 }
            Start-Sleep -Milliseconds 1500
            $held = @([FlatGhost]::ChildRects($hw, 'GhozttyTerminal') | ForEach-Object { , ([int[]]($_ -split ' ')) } | Sort-Object { $_[0] })
            Assert "$arm.3 the held drag moved the divider (left pane ends $($held[0][2]), was $($rects[0][2]))" ($held.Count -eq 2 -and $held[0][2] -lt $rects[0][2] - 40)
            Grab $arm $dir $hw 'held'
            [FlatGhost]::Up($hw, $gx - 80, $gy)
            Assert "$arm.4 the drag released" (Wait-Log $err 'divider drag released' $before 3000)
            Start-Sleep -Milliseconds 1500
            Grab $arm $dir $hw 'released'
        }

        # Two more panes than the row holds: a stack, and its strips.
        & $Exe +split '--target=flat-right' '--direction=right' '--name=flat-r2' 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        & $Exe +split '--target=flat-r2' '--direction=right' '--name=flat-r3' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'flat-r2', 'flat-r3') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 2000
        $shown = @([FlatGhost]::ChildRects($hw, 'GhozttyTerminal')).Count
        "  panes on show: $shown of 4"
        Assert "$arm.5 the row tucked a pane into a stack ($shown of 4 on show)" ($shown -lt 4)
        Grab $arm $dir $hw 'stack'

        # Rearrange mode: the flat style's headers are GDI, so the flat desk
        # must come off the compositor for them, or they would be painted under
        # its visual and never seen.
        $log = Read-Text $err
        $pane = [FlatGhost]::FirstChild($hw, 'GhozttyTerminal')
        $tb = ([regex]::Matches($log, 'toggle_rearrange_mode')).Count
        $ok = $false
        for ($try = 0; $try -lt 3 -and -not $ok; $try++) {
            [FlatGhost]::Tap($pane, 0x78, 0x43)
            $ok = Wait-Log $err 'toggle_rearrange_mode' $tb 3000
        }
        Assert "$arm.9 rearrange mode came on" $ok
        Start-Sleep -Milliseconds 1500
        Grab $arm $dir $hw 'headers'
        $after = (Read-Text $err).Substring($log.Length)

        if ($arm -eq 'visual' -or $arm -eq 'freeze') {
            Assert "$arm.6 the flat desk went up on the desk visual" ($log -match 'chrome flat desk on the desk visual' -and $log -match 'chrome desk visual attached')
            Assert "$arm.7 the desk visual never fell back to GDI" ($log -notmatch 'chrome desk visual (failed|detached)')
            Assert "$arm.8 the caption band rode the compositor with it" ($log -match 'chrome caption visual attached')
            Assert "$arm.10 the headers took the flat desk back to GDI" ($after -match 'chrome desk visual detached')
        } elseif ($arm -eq 'fill') {
            Assert "$arm.6 the test fill is up (the window stays GDI under it)" ($log -match 'chrome composition test fill attached')
            Assert "$arm.7 no flat desk under the test fill" ($log -notmatch 'chrome flat desk on the desk visual')
        } else {
            Assert "$arm.6 knob off: no chrome host" ($log -notmatch 'chrome composition')
        }
        $fgPid = [uint32]0
        [void][FlatGhost]::GetWindowThreadProcessId([FlatGhost]::GetForegroundWindow(), [ref]$fgPid)
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

function Compare-Frame($label, $a, $b, $y0 = 0, $y1 = -1) {
    if (-not $a -or -not $b) { Assert "$label both frames to compare" $false; return $null }
    if ($a.W -ne $b.W -or $a.H -ne $b.H) { Assert "$label the frames are the same size ($($a.W)x$($a.H) vs $($b.W)x$($b.H))" $false; return $null }
    if ($y1 -lt 0) { $y1 = $a.H }
    $d = [FlatGhost]::Diff($a.B, $b.B, $a.W, $y0, $y1, $a.Stride, $Tolerance)
    # Host, not output: a function's output IS its return value.
    Write-Host "  $label differing=$d ($('{0:P2}' -f ($d / [double]($a.W * $a.H))))"
    return [int]$d
}

# Positive controls: each step changes the GDI picture at all.
$d = Compare-Frame 'ctl.1 gdi split vs held:' $script:frames['gdi/split'] $script:frames['gdi/held']
Assert 'ctl.1 the drag changes the GDI picture (positive control)' ($null -ne $d -and $d -gt 200)
$d = Compare-Frame 'ctl.2 gdi held vs released:' $script:frames['gdi/held'] $script:frames['gdi/released']
Assert 'ctl.2 the release changes the GDI picture - the bar goes (positive control)' ($null -ne $d -and $d -gt 0)
$d = Compare-Frame 'ctl.3 gdi released vs stack:' $script:frames['gdi/released'] $script:frames['gdi/stack']
Assert 'ctl.3 the stack changes the GDI picture (positive control)' ($null -ne $d -and $d -gt 200)
$d = Compare-Frame 'ctl.4 gdi stack vs headers:' $script:frames['gdi/stack'] $script:frames['gdi/headers']
Assert 'ctl.4 rearrange mode changes the GDI picture (positive control)' ($null -ne $d -and $d -gt 200)

foreach ($name in 'split', 'held', 'released', 'stack', 'headers') {
    $src = 'visual'
    if ($NegativeControl -and $name -eq 'split') { $src = 'fill' }
    if ($NegativeControl -and $name -eq 'held') { $src = 'freeze' }
    $ref = $script:frames["gdi/$name"]
    $g = $script:frames["$src/$name"]
    $d = Compare-Frame "match.$name $src vs gdi:" $ref $g
    if ($null -eq $d) { continue }
    $allowed = [int]($ref.W * $ref.H * $MaxDiffShare)
    Assert "match.$name the $src $name frame matches GDI's ($d <= $allowed differ by > $Tolerance)" ($d -le $allowed)
}
# Each arm's caption band through the drag: the band before any drag. The gdi
# rows are T2569's own check - the bar's glow over the tab bar was a GDI smear.
if ($script:contentTop -gt 0) {
    foreach ($arm in 'gdi', 'visual') {
        foreach ($name in 'held', 'released', 'stack') {
            $d = Compare-Frame "band.$arm.$name $arm vs gdi split (rows 0-$($script:contentTop)):" $script:frames['gdi/split'] $script:frames["$arm/$name"] 0 $script:contentTop
            if ($null -ne $d) { Assert "band.$arm.$name the caption band is untouched by the drag ($d px)" ($d -le 0) }
        }
    }
} else { Assert 'band the content top was measured' $false }
"  grabs kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
