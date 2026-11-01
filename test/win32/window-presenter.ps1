# Window presenter child acceptance (tracker T2614, T2610 step 3b).
#
# THE CHANGE: with GHOZTTY_WINDOW_PRESENTER=1 every top-level window gets one
# GL child, class GhozttyPresenter, that its terminal panes will present
# through (src/apprt/win32/WindowPresenter.zig; design in
# docs/design/win32-window-presenter.md). Step 3b builds the child, its thread
# and context, and keeps it placed; the renderers hand their frames over in
# step 3c (T2615), so with the knob on a pane shows only its background for
# now. Off by default.
#
# THE CONTRACT this asserts:
#
#   A. Knob on: the window has exactly one GhozttyPresenter child, its thread
#      made a context and composed, and it sits DIRECTLY above the topmost
#      terminal pane with every terminal pane below it (z-order walk).
#   B. Its window region is the union of the visible terminal pane rects: with
#      a split, the region's box is the union's box, each pane's center is in
#      it, and the divider gap between the panes is NOT (the parent keeps
#      painting the gaps).
#   C. The app's own check (debug build, UI thread, because HTTRANSPARENT is
#      honored for same-thread windows only): a hit at each pane's center
#      reaches the PANE, and each pane is fully covered (empty visible region).
#   D. It follows the layout: a resize re-sizes the presenter to the client and
#      re-cuts the region, and closing a pane shrinks the region to the pane
#      that is left.
#   E. Negative controls: knob off, no presenter child and no presenter line;
#      knob on with GHOZTTY_COMP_PRESENT=1, no presenter and an "ignored" line.
#
# NOT asserted here: the pixels on screen. This harness runs on a background
# desktop that DWM never composes, so what the presenter draws can only be
# seen on the live desktop (T2610's T2592 criterion, recorded NOT RUN).
#
#   powershell -NoProfile -File test\win32\window-presenter.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

if (-not ('T2614Win' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class T2614Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int a, int b, int c, int d);
    [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out RECT r);
    [DllImport("gdi32.dll")] public static extern bool PtInRegion(IntPtr rgn, int x, int y);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    // Per-monitor aware, so window rects are in physical pixels like the
    // app's region: a DPI-unaware caller gets virtualized rects.
    public static void Aware() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
    // child's window rect in screen coordinates: L, T, R, B. (Point mapping
    // into a window on the background desktop is not reliable from here, so
    // everything is compared in screen space, relative to the presenter.)
    public static int[] ScreenRect(IntPtr child) {
        Aware();
        RECT r; GetWindowRect(child, out r);
        return new int[] { r.L, r.T, r.R, r.B };
    }
    public static string Cls(IntPtr h) { var sb = new StringBuilder(64); GetClassNameW(h, sb, 64); return sb.ToString(); }
}
'@
}

$root = Join-Path $env:TEMP "ghoztty-window-presenter-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_WINDOW_PRESENTER', 'GHOZTTY_COMP_PRESENT'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($presenter, $comp) {
    $vals = @{ GHOZTTY_WINDOW_PRESENTER = $presenter; GHOZTTY_COMP_PRESENT = $comp }
    foreach ($k in $knobs) {
        if ($vals[$k]) { Set-Item "env:$k" $vals[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'winpres')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

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

function Count-Log($path, $pattern) {
    return ([regex]::Matches((Read-Text $path), $pattern)).Count
}

# The top-level's children, top of the z-order first, with each rect in
# screen coordinates.
function Get-Kids([IntPtr]$top) {
    $out = New-Object System.Collections.ArrayList
    $c = [T2614Win]::GetWindow($top, 5)  # GW_CHILD
    $guard = 0
    while ($c -ne [IntPtr]::Zero -and $guard -lt 500) {
        $guard++
        $q = [T2614Win]::ScreenRect($c)
        [void]$out.Add([pscustomobject]@{
            Hwnd = $c; Class = [T2614Win]::Cls($c); Visible = [T2614Win]::IsWindowVisible($c)
            Left = $q[0]; Top = $q[1]; Right = $q[2]; Bottom = $q[3]
        })
        $c = [T2614Win]::GetWindow($c, 2)  # GW_HWNDNEXT
    }
    return , $out.ToArray()
}

function Get-Region([IntPtr]$h) {
    [T2614Win]::Aware()
    $rgn = [T2614Win]::CreateRectRgn(0, 0, 0, 0)
    $kind = [T2614Win]::GetWindowRgn($h, $rgn)
    $box = New-Object T2614Win+RECT
    [void][T2614Win]::GetRgnBox($rgn, [ref]$box)
    return [pscustomobject]@{ Rgn = $rgn; Kind = $kind; Box = $box }
}

# Everything A-D ask of one window, in one object.
function Measure-Presenter([IntPtr]$top) {
    $kids = Get-Kids $top
    $pres = @($kids | Where-Object { $_.Class -eq 'GhozttyPresenter' })
    $terms = @($kids | Where-Object { $_.Class -eq 'GhozttyTerminal' -and $_.Visible })
    $m = [pscustomobject]@{
        Kids = $kids; Presenters = $pres; Terms = $terms
        ZOk = $false; Region = $null; BoxOk = $false; CentersIn = 0; FullClient = $false
    }
    if ($pres.Count -ne 1) { return $m }
    $p = $pres[0]
    # z-order: the presenter is directly above the topmost terminal pane, and
    # no terminal pane (hidden or not) is above it.
    $idxP = [array]::IndexOf(@($kids | ForEach-Object { $_.Hwnd }), $p.Hwnd)
    $firstTerm = -1
    for ($i = 0; $i -lt $kids.Count; $i++) { if ($kids[$i].Class -eq 'GhozttyTerminal') { $firstTerm = $i; break } }
    $m.ZOk = ($firstTerm -gt 0 -and $idxP -eq ($firstTerm - 1))
    [T2614Win]::Aware()
    $client = New-Object T2614Win+RECT
    [void][T2614Win]::GetClientRect($top, [ref]$client)
    # The presenter is placed at the client origin; what can be checked from
    # here is that it is exactly the client's size and starts where the
    # top-level's client does (its window rect less the client, which has no
    # non-client border on this frameless window, so the two corners meet).
    $topRect = [T2614Win]::ScreenRect($top)
    $m.FullClient = (($p.Right - $p.Left) -eq $client.R -and ($p.Bottom - $p.Top) -eq $client.B -and
        $p.Right -le $topRect[2] -and $p.Bottom -le $topRect[3] -and $p.Left -ge $topRect[0] -and $p.Top -ge $topRect[1])
    $m.Region = Get-Region $p.Hwnd
    if ($terms.Count -gt 0) {
        $u = [pscustomobject]@{
            L = ($terms | Measure-Object Left -Minimum).Minimum; T = ($terms | Measure-Object Top -Minimum).Minimum
            R = ($terms | Measure-Object Right -Maximum).Maximum; B = ($terms | Measure-Object Bottom -Maximum).Maximum
        }
        # The region is in the presenter's window coordinates.
        $b = $m.Region.Box
        $m.BoxOk = ($b.L -eq ($u.L - $p.Left) -and $b.T -eq ($u.T - $p.Top) -and $b.R -eq ($u.R - $p.Left) -and $b.B -eq ($u.B - $p.Top))
        foreach ($t in $terms) {
            if ([T2614Win]::PtInRegion($m.Region.Rgn, [int](($t.Left + $t.Right) / 2) - $p.Left, [int](($t.Top + $t.Bottom) / 2) - $p.Top)) { $m.CentersIn++ }
        }
    }
    return $m
}

function Close-Measure($m) { if ($m -and $m.Region) { [void][T2614Win]::DeleteObject($m.Region.Rgn) } }

function Wait-Measure([IntPtr]$top, [int]$terms, [int]$timeoutMs = 10000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $m = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        Close-Measure $m
        $m = Measure-Presenter $top
        if ($m.Terms.Count -eq $terms -and $m.BoxOk -and $m.ZOk -and $m.FullClient) { return $m }
        Start-Sleep -Milliseconds 200
    }
    return $m
}

function Show-Kids($m) {
    foreach ($k in $m.Kids) { "    $($k.Class) 0x$(([int64]$k.Hwnd).ToString('x')) vis=$($k.Visible) [$($k.Left),$($k.Top),$($k.Right),$($k.Bottom)]" }
    if ($m.Region) { $b = $m.Region.Box; "    region kind=$($m.Region.Kind) box=[$($b.L),$($b.T),$($b.R),$($b.B)]" }
}

function Start-Arm($name) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t2614-$name") -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    # The startup window itself, so no second top-level overlaps the panes
    # and takes the app's hit test (C). Its target is whatever +list says.
    $win = $null
    for ($t = 0; $t -lt 50 -and -not $win; $t++) {
        $json = (& $Exe +list --json 2>$null | Out-String).Trim()
        if ($json) { try { $win = @(($json | ConvertFrom-Json).data.windows)[0] } catch { $win = $null } }
        if (-not $win) { Start-Sleep -Milliseconds 200 }
    }
    $tgt = if ($win) { [string]$win.target } else { '' }
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = $tgt }
}

function Test-Alive($arm) { return ($arm.App.Process -and -not $arm.App.Process.HasExited) }

$createdLine = 'window presenter created'
$composedLine = 'window presenter composed'
$ignoredLine = 'GHOZTTY_WINDOW_PRESENTER ignored'

try {
    # ========================================================================
    "== A: knob on, one presenter per window, directly above the terminal panes"
    # ========================================================================
    Set-Knobs '1' $null
    $a = Start-Arm 'a'
    Assert "A0 the arm's window came up with a target ($($a.Target))" ($a.Top -ne [IntPtr]::Zero -and $a.Target)
    Assert "A1 a presenter was created with a context" (Wait-Log $a.Err $createdLine 15000)
    Assert "A2 and its thread composed" (Wait-Log $a.Err $composedLine 10000)
    $m1 = Wait-Measure $a.Top 1
    Assert "A3 the window has exactly one GhozttyPresenter child ($($m1.Presenters.Count))" ($m1.Presenters.Count -eq 1)
    Assert "A4 it sits directly above the topmost terminal pane, none above it" $m1.ZOk
    Assert "A5 it covers the client exactly" $m1.FullClient
    if (-not ($m1.ZOk -and $m1.FullClient)) { Show-Kids $m1 }
    Close-Measure $m1

    # ========================================================================
    "== B: the region is the union of the terminal panes, not the gaps"
    # ========================================================================
    & $Exe +split "--target=$($a.Target)" '--direction=right' '--name=presa2' 2>$null | Out-Null
    $m2 = Wait-Measure $a.Top 2
    Assert "B0 the split shows two terminal panes ($($m2.Terms.Count))" ($m2.Terms.Count -eq 2)
    Assert "B1 still one presenter, still directly above the panes" ($m2.Presenters.Count -eq 1 -and $m2.ZOk)
    Assert "B2 the region is a region (kind=$($m2.Region.Kind))" ($m2.Region -and $m2.Region.Kind -ge 2)
    Assert "B3 the region's box is the union of the pane rects" $m2.BoxOk
    Assert "B4 each pane's center is in the region ($($m2.CentersIn))" ($m2.CentersIn -eq 2)
    $gapOut = $false
    if ($m2.Terms.Count -eq 2 -and $m2.Region) {
        $l, $r = @($m2.Terms | Sort-Object Left)
        $gx = [int](($l.Right + $r.Left) / 2)
        $gy = [int](($l.Top + $l.Bottom) / 2)
        $p2 = $m2.Presenters[0]
        $gapOut = ($r.Left -gt $l.Right) -and -not [T2614Win]::PtInRegion($m2.Region.Rgn, $gx - $p2.Left, $gy - $p2.Top)
        if (-not $gapOut) { "    gap l.Right=$($l.Right) r.Left=$($r.Left) probe=($gx,$gy)" }
    }
    Assert "B5 the divider gap between the panes is outside the region" $gapOut
    if (-not ($m2.BoxOk -and $gapOut)) { Show-Kids $m2 }
    Close-Measure $m2

    # ========================================================================
    "== C: the app's own check - hits reach the panes, the panes are covered"
    # ========================================================================
    # The arm runs in the startup window, so nothing overlaps it: every hit
    # must reach its pane. (occluded counts a hit another top-level took; it
    # is reported so a future overlap reads as itself, not as the defect.)
    $checkOk = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $checkOk -and $sw.ElapsedMilliseconds -lt 8000) {
        foreach ($mm in [regex]::Matches((Read-Text $a.Err), 'window presenter check panes=2 hit_through=(\d+) hit_presenter=(\d+) occluded=(\d+) covered=(\d+)')) {
            $th = [int]$mm.Groups[1].Value; $hp = [int]$mm.Groups[2].Value; $oc = [int]$mm.Groups[3].Value; $cv = [int]$mm.Groups[4].Value
            if ($hp -eq 0 -and $th -eq 2 -and $oc -eq 0 -and $cv -eq 2) { $checkOk = $true }
        }
        if (-not $checkOk) { Start-Sleep -Milliseconds 200 }
    }
    Assert "C0 with a split, each pane takes the hit at its center (none lands on the presenter) and both are covered" $checkOk
    $oneOk = (Read-Text $a.Err) -match 'window presenter check panes=1 hit_through=1 hit_presenter=0 occluded=0 covered=1'
    Assert "C1 with one pane, the hit at its center reaches it and it is covered" $oneOk
    if (-not $checkOk) {
        ((Read-Text $a.Err) -split "`n" | Where-Object { $_ -match 'window presenter check' } | Select-Object -Last 4) |
            ForEach-Object { "    $_" }
    }

    # ========================================================================
    "== D: it follows the layout - resize, then close a pane"
    # ========================================================================
    [void](Set-TestWindowSize -Window $a.Top -Width 1100 -Height 700)
    $m3 = Wait-Measure $a.Top 2
    Assert "D0 after a resize it still covers the client exactly" $m3.FullClient
    Assert "D1 and the region is still the union of the panes" ($m3.BoxOk -and $m3.CentersIn -eq 2)
    Close-Measure $m3
    & $Exe +close '--target=presa2' 2>$null | Out-Null
    $m4 = Wait-Measure $a.Top 1
    Assert "D2 closing a pane leaves one terminal pane ($($m4.Terms.Count))" ($m4.Terms.Count -eq 1)
    Assert "D3 and the region shrinks to it" ($m4.BoxOk -and $m4.CentersIn -eq 1 -and $m4.ZOk)
    if (-not $m4.BoxOk) { Show-Kids $m4 }
    Close-Measure $m4
    Assert "D4 the app is still running" (Test-Alive $a)
    Assert "D5 no OpenGL errors were raised" ((Read-Text $a.Err) -notmatch 'error\(opengl\)')
    Assert "D6 no presenter failure was logged" ((Read-Text $a.Err) -notmatch 'window presenter: ')

    # ========================================================================
    "== E: negative controls"
    # ========================================================================
    Set-Knobs $null $null
    $e = Start-Arm 'e'
    Assert "E0 knob off: the window came up" ($e.Top -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    $me = Measure-Presenter $e.Top
    Assert "E1 knob off: no GhozttyPresenter child ($($me.Presenters.Count)) beside $($me.Terms.Count) pane(s)" ($me.Presenters.Count -eq 0 -and $me.Terms.Count -ge 1)
    Assert "E2 knob off: no presenter line" ((Count-Log $e.Err $createdLine) -eq 0)
    Close-Measure $me

    Set-Knobs '1' '1'
    $f = Start-Arm 'f'
    Assert "E3 both knobs: the window came up" ($f.Top -ne [IntPtr]::Zero)
    Assert "E4 both knobs: the presenter knob is reported ignored" (Wait-Log $f.Err $ignoredLine 10000)
    $mf = Measure-Presenter $f.Top
    Assert "E5 both knobs: no GhozttyPresenter child ($($mf.Presenters.Count))" ($mf.Presenters.Count -eq 0 -and $mf.Terms.Count -ge 1)
    Assert "E6 both knobs: no presenter line" ((Count-Log $f.Err $createdLine) -eq 0)
    Close-Measure $mf
    Complete-TestBody
} finally {
    foreach ($k in $knobs) {
        if ($saved[$k]) { Set-Item "env:$k" $saved[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard window-presenter -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'window-presenter' -MinPass 28
