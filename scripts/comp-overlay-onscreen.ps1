# On-screen oracle for the desk's overlay on the chrome compositor (tracker
# T2544).
#
# With GHOZTTY_COMP_CHROME=1 the desk is a composition visual, and the GDI
# painters that draw OVER the desk - the rearrange headers, a hero tab's
# carousel - paint an overlay instead, which goes up as the desk's child
# visual. Before T2544 such a window kept its whole desk on GDI. The window's
# own pixels under the desk visual are never painted, so a header or a
# carousel can only be on screen in that arm through the overlay: a pixel
# match against the GDI picture is a proof, not a coincidence.
#
# Same filming technique as comp-desk-onscreen.ps1 (T2509/T2543): a GHOST
# window (GHOZTTY_DEBUG_GHOST=bottom: opaque, never activates, bottom of the
# z-order), one whole frame taken with Windows.Graphics.Capture by
# ghoztty-comp-spike.exe --grab-hwnd. The modes are bound to bare F9/F8 and the
# keys are POSTED to a pane, so nothing ever takes the user's focus.
#
# Frames, each knob-on against knob-off:
#   - headers: rearrange mode on a two-pane split - the header bands.
#   - moved:   a `+rearrange` swaps the panes and moves the divider, so every
#              header moves: a stale band left where one was shows here. This
#              is the header drag's shape (a re-lay under the headers) without
#              a real pointer.
#   - hero:    rearrange off, a third pane, hero mode - the carousel column.
#
# Arms:
#   - gdi:    knob off. The reference pictures.
#   - visual: knob on. The log says the overlay attached and the desk never
#             fell back to GDI; every frame matches gdi's within rounding.
#   - fill:   knob on with the debug test fill (desk stays GDI under a magenta
#             visual). Only with -NegativeControl, scored as the visual arm's
#             headers frame: the match must FAIL.
#   - freeze: knob on with GHOZTTY_COMP_CHROME_OVERLAY_FREEZE (the overlay drops
#             every dirty-rect upload). Only with -NegativeControl, scored as
#             the visual arm's moved frame: the match must FAIL, or a header
#             that stopped following its pane would pass.
#
#   powershell -NoProfile -File scripts\comp-overlay-onscreen.ps1
#   powershell -NoProfile -File scripts\comp-overlay-onscreen.ps1 -NegativeControl   # must go red

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ (~200 px at the default size).
    # Tighter than comp-desk-onscreen's 0.2%: on glass a header's band is the
    # desk's, so a header left behind is only its title and glyphs - ~900 px,
    # under 0.2% of the frame. The overlay arm scores 0-2 px.
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-comp-overlay-onscreen-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_CHROME_TEST_FILL', 'GHOZTTY_COMP_CHROME_OVERLAY_FREEZE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class OvlGhost {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
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
    // Pixels whose largest channel differs by more than tol.
    public static int Diff(byte[] a, byte[] b, int w, int h, int stride, int tol) {
        int n = 0;
        for (int y = 0; y < h; y++) for (int x = 0, o = y * stride; x < w; x++, o += 4) {
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

# Post a bound key at the pane until the log shows its action dispatched: a
# key posted before the pane is ready to read input is dropped, not queued.
function Send-Toggle($pane, $vk, $scan, $err, $action) {
    $before = ([regex]::Matches((Read-Text $err), $action)).Count
    for ($try = 0; $try -lt 3; $try++) {
        [OvlGhost]::Tap($pane, $vk, $scan)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 3000) {
            if (([regex]::Matches((Read-Text $err), $action)).Count -gt $before) { return $true }
            Start-Sleep -Milliseconds 200
        }
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
[void](Set-GhozttyTestIsolation -Tag 'ovlonscreen')
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
        Remove-Item env:GHOZTTY_COMP_CHROME, env:GHOZTTY_COMP_CHROME_TEST_FILL, env:GHOZTTY_COMP_CHROME_OVERLAY_FREEZE -ErrorAction SilentlyContinue
        if ($arm -ne 'gdi') { $env:GHOZTTY_COMP_CHROME = '1' }
        if ($arm -eq 'fill') { $env:GHOZTTY_COMP_CHROME_TEST_FILL = '1' }
        if ($arm -eq 'freeze') { $env:GHOZTTY_COMP_CHROME_OVERLAY_FREEZE = '1' }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=30', '--background=#101418',
            '--cursor-style-blink=false', '--title=t2544-overlay',
            '--keybind=f9=toggle_rearrange_mode', '--keybind=f8=toggle_hero_mode') -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([OvlGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window '--target=ovl' 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([OvlGhost]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split '--target=ovl' '--direction=right' '--name=ovl-right' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'ovl', 'ovl-right') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 2000
        $pane = [OvlGhost]::FirstChild($hw, 'GhozttyTerminal')
        Assert "$arm.2 a pane to post the keys to" ($pane -ne [IntPtr]::Zero)

        # Rearrange mode: the headers.
        Assert "$arm.3 rearrange mode came on" (Send-Toggle $pane 0x78 0x43 $err 'toggle_rearrange_mode')
        Start-Sleep -Milliseconds 1500
        Grab $arm $dir $hw 'headers'

        # Close the right pane: its header goes, the left one widens across
        # where it was.
        & $Exe +close '--target=ovl-right' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        Grab $arm $dir $hw 'moved'

        # Out of rearrange mode, three panes, hero mode: the carousel.
        $pane = [OvlGhost]::FirstChild($hw, 'GhozttyTerminal')
        Assert "$arm.3b rearrange mode went off" (Send-Toggle $pane 0x78 0x43 $err 'toggle_rearrange_mode')
        & $Exe +split '--target=ovl' '--direction=right' '--name=ovl-r2' 2>$null | Out-Null
        & $Exe +split '--target=ovl-r2' '--direction=down' '--name=ovl-down' 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($p in 'ovl-r2', 'ovl-down') { & $Exe +send-keys "--target=$p" 'cls' Enter 2>$null | Out-Null }
        Start-Sleep -Milliseconds 1000
        $pane = [OvlGhost]::FirstChild($hw, 'GhozttyTerminal')
        Assert "$arm.4 hero mode came on" (Send-Toggle $pane 0x77 0x42 $err 'toggle_hero_mode')
        Start-Sleep -Milliseconds 2000
        Grab $arm $dir $hw 'hero'

        $log = Read-Text $err
        if ($arm -eq 'visual' -or $arm -eq 'freeze') {
            Assert "$arm.5 the overlay visual attached" ($log -match 'chrome overlay visual attached')
            Assert "$arm.6 the desk visual attached and never fell back to GDI" ($log -match 'chrome desk visual attached' -and $log -notmatch 'chrome desk visual (failed|detached)')
            Assert "$arm.7 the overlay never failed" ($log -notmatch 'chrome overlay visual failed')
        } elseif ($arm -eq 'fill') {
            Assert "$arm.5 the test fill is up (the desk stays GDI under it)" ($log -match 'chrome composition test fill attached')
        } else {
            Assert "$arm.5 knob off: no chrome host" ($log -notmatch 'chrome composition')
        }
        $fgPid = [uint32]0
        [void][OvlGhost]::GetWindowThreadProcessId([OvlGhost]::GetForegroundWindow(), [ref]$fgPid)
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

function Compare-Frame($label, $a, $b) {
    if (-not $a -or -not $b) { Assert "$label both frames to compare" $false; return $null }
    if ($a.W -ne $b.W -or $a.H -ne $b.H) { Assert "$label the frames are the same size ($($a.W)x$($a.H) vs $($b.W)x$($b.H))" $false; return $null }
    $d = [OvlGhost]::Diff($a.B, $b.B, $a.W, $a.H, $a.Stride, $Tolerance)
    # Host, not output: a function's output IS its return value.
    Write-Host "  $label differing=$d ($('{0:P2}' -f ($d / [double]($a.W * $a.H))))"
    return [int]$d
}

# Positive controls: each step changes the GDI picture at all.
$d = Compare-Frame 'ctl.1 gdi headers vs moved:' $script:frames['gdi/headers'] $script:frames['gdi/moved']
Assert 'ctl.1 the move changes the GDI picture (positive control)' ($null -ne $d -and $d -gt 200)
$d = Compare-Frame 'ctl.2 gdi moved vs hero:' $script:frames['gdi/moved'] $script:frames['gdi/hero']
Assert 'ctl.2 hero mode changes the GDI picture (positive control)' ($null -ne $d -and $d -gt 200)

foreach ($name in 'headers', 'moved', 'hero') {
    $src = 'visual'
    if ($NegativeControl -and $name -eq 'headers') { $src = 'fill' }
    if ($NegativeControl -and $name -eq 'moved') { $src = 'freeze' }
    $ref = $script:frames["gdi/$name"]
    $g = $script:frames["$src/$name"]
    $d = Compare-Frame "match.$name $src vs gdi:" $ref $g
    if ($null -eq $d) { continue }
    $allowed = [int]($ref.W * $ref.H * $MaxDiffShare)
    Assert "match.$name the $src $name frame matches GDI's ($d <= $allowed differ by > $Tolerance)" ($d -le $allowed)
}
"  grabs kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
