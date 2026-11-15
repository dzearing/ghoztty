# Chrome paint clip acceptance (T2987, audit finding PA-W03).
#
# THE CONTRACT. The window chrome has two band painters: the caption and the
# tab strip. Each runs only when the paint it is part of actually reaches the
# band it puts on screen, and each keeps its double buffer across paints,
# rebuilding it only when the band changes size. Before T2987 every WM_PAINT -
# a divider, a pane-area exposure, a hover anywhere - re-measured every tab
# title, re-composited every tab and created and destroyed two full-width
# DC + DIB pairs, for pixels the paint's clip then threw away.
#
# WHAT IS MEASURED (no pixels - the claim is about work, not about colour):
#
#   A. the paint probe is live: both painters printed at least once at launch,
#      with a buffer build count, and the window is quiet once settled.
#   B. a paint whose clip is the PANE AREA (an InvalidateRect well below the
#      chrome) is a real WM_PAINT - the window counter advances, the positive
#      control - and neither painter runs.
#   C. a paint whose clip is the chrome row runs both painters (two tabs, so
#      the merged caption + strip row is on screen).
#   D. five more chrome paints at one size build no new buffer: `builds` holds
#      still while the painters' run counts climb by five each.
#
# THE ORACLE is `paint_probe.zig`'s stderr lines, under GHOZTTY_PAINT_PROBE:
#   paint-probe surface=window n=<k>          (one per WM_PAINT)
#   chrome-painter name=caption n=<k> builds=<b>
# No capture is taken while counting: a WM_PRINTCLIENT capture runs the
# painters too, and would advance the counters this script scores.
#
#   powershell -NoProfile -File test\win32\chrome-paint-clip.ps1
#
# -NegativeControl invalidates the CHROME row in section B instead of the pane
# area, so B's two "painter did not run" assertions must both fail on a correct
# build. Anything other than two failures means B is not measuring the clip.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-cpclip$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

Register-RepoBuildTeardown -Exe $exe | Out-Null

if (-not ('T2987Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T2987Native {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr hWnd, ref RECT r, bool erase);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    public static bool Invalidate(IntPtr h, int l, int t, int r, int b) {
        RECT rc; rc.Left = l; rc.Top = t; rc.Right = r; rc.Bottom = b;
        return InvalidateRect(h, ref rc, false);
    }
    public static int[] Client(IntPtr h) {
        RECT rc;
        if (!GetClientRect(h, out rc)) return null;
        return new int[] { rc.Right - rc.Left, rc.Bottom - rc.Top };
    }
}
'@
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
# Section B's two assertions, and the only ones -NegativeControl inverts the
# STATE for (it invalidates the chrome instead of the pane area).
function Assert-Pair([bool]$cond, [string]$label) {
    if ($NegativeControl) { Assert $cond "$label (NEGATIVE CONTROL: expected to fail)" }
    else { Assert $cond $label }
}

# The newest counters out of the app's stderr. $null fields when the probe
# never printed, which the assertions refuse to read as 0.
function Get-ProbeState {
    $s = [pscustomobject]@{ Window = $null; Caption = $null; Strip = $null; CaptionBuilds = $null; StripBuilds = $null }
    if (-not $errlog -or -not (Test-Path $errlog)) { return $s }
    foreach ($l in @(Get-Content $errlog -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($l, 'paint-probe surface=window n=(\d+)')
        if ($m.Success) { $s.Window = [int]$m.Groups[1].Value; continue }
        $m = [regex]::Match($l, 'chrome-painter name=(caption|strip) n=(\d+) builds=(\d+)')
        if ($m.Success) {
            if ($m.Groups[1].Value -eq 'caption') {
                $s.Caption = [int]$m.Groups[2].Value; $s.CaptionBuilds = [int]$m.Groups[3].Value
            } else {
                $s.Strip = [int]$m.Groups[2].Value; $s.StripBuilds = [int]$m.Groups[3].Value
            }
        }
    }
    return $s
}

# Wait until the counters stop moving (the shell's prompt and title settle).
function Wait-ProbeQuiet([int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $prev = $null
    while ((Get-Date) -lt $deadline) {
        $cur = Get-ProbeState
        $key = "$($cur.Window)/$($cur.Caption)/$($cur.Strip)"
        if ($prev -eq $key) { return $true }
        $prev = $key
        Start-Sleep -Milliseconds 1500
    }
    return $false
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = $null
$app = $null

try {
    $td = New-TestDesktop -Interactive:$Interactive
    $errlog = Join-Path $env:TEMP "ghoztty-chrome-paint-clip-stderr-$PID.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:GHOZTTY_PAINT_PROBE = '1'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1 }
    Set-TestWindowSize -Window $top -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Seconds 1

    # A second tab, so the strip is on screen (one tab shows none, T234).
    $fw = Get-TestFocusedWindow -Window $top
    if ($fw -eq 0) {
        $vis = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
        if ($vis.Count -gt 0) { $fw = $vis[0].Hwnd }
    }
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$fw) -Modifiers ctrl -Key T)
    Start-Sleep -Seconds 2
    $terms = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    Assert ($terms.Count -ge 2) "setup: a second tab opened ($($terms.Count) terminal children)"

    $client = [T2987Native]::Client($top)
    Assert ($null -ne $client -and $client[0] -gt 200 -and $client[1] -gt 200) `
        "setup: the client area is readable ($($client -join 'x'))"
    if ($null -eq $client) { throw 'no client rect' }
    $cw = $client[0]; $ch = $client[1]

    # =======================================================================
    # A. THE PROBE IS LIVE
    # =======================================================================
    Write-Host ''
    Write-Host 'A. both painters reported, and the window settles quiet'
    $quiet = Wait-ProbeQuiet
    $s0 = Get-ProbeState
    Assert ($null -ne $s0.Window -and $null -ne $s0.Caption -and $null -ne $s0.Strip) `
        "A the probe printed window=$($s0.Window) caption=$($s0.Caption) strip=$($s0.Strip)"
    Assert ($null -ne $s0.CaptionBuilds -and $s0.CaptionBuilds -ge 1 -and $null -ne $s0.StripBuilds -and $s0.StripBuilds -ge 1) `
        "A each painter reports a buffer build count (caption=$($s0.CaptionBuilds) strip=$($s0.StripBuilds))"
    Assert $quiet 'A the counters stopped moving (a quiet window is what B and C are scored against)'

    # =======================================================================
    # B. A PANE-AREA PAINT RUNS NEITHER PAINTER
    # =======================================================================
    Write-Host ''
    Write-Host 'B. a paint clipped to the pane area runs neither band painter'
    $before = Get-ProbeState
    $paneTop = [int]($ch * 0.6)
    for ($i = 0; $i -lt 3; $i++) {
        if ($NegativeControl) {
            [void][T2987Native]::Invalidate($top, 0, 0, $cw, 6)
        } else {
            [void][T2987Native]::Invalidate($top, 0, $paneTop, $cw, $ch)
        }
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 600
    $after = Get-ProbeState
    Assert ($null -ne $after.Window -and $after.Window -gt $before.Window) `
        "B the invalidation was a real WM_PAINT (window $($before.Window) -> $($after.Window)) - the positive control"
    Assert-Pair ($after.Caption -eq $before.Caption) `
        "B the caption painter did not run (caption $($before.Caption) -> $($after.Caption))"
    Assert-Pair ($after.Strip -eq $before.Strip) `
        "B the strip painter did not run (strip $($before.Strip) -> $($after.Strip))"

    # =======================================================================
    # C. A CHROME-ROW PAINT RUNS BOTH
    # =======================================================================
    Write-Host ''
    Write-Host 'C. a paint clipped to the chrome row runs both painters'
    [void](Wait-ProbeQuiet)
    $before = Get-ProbeState
    [void][T2987Native]::Invalidate($top, 0, 0, $cw, 6)
    Start-Sleep -Milliseconds 800
    $after = Get-ProbeState
    Assert ($after.Caption -gt $before.Caption) "C the caption painter ran (caption $($before.Caption) -> $($after.Caption))"
    Assert ($after.Strip -gt $before.Strip) "C the strip painter ran (strip $($before.Strip) -> $($after.Strip))"

    # =======================================================================
    # D. NO BUFFER IS BUILT PER PAINT
    # =======================================================================
    Write-Host ''
    Write-Host 'D. five chrome paints at one size build no new buffer'
    [void](Wait-ProbeQuiet)
    $before = Get-ProbeState
    for ($i = 0; $i -lt 5; $i++) {
        [void][T2987Native]::Invalidate($top, 0, 0, $cw, 6)
        Start-Sleep -Milliseconds 350
    }
    Start-Sleep -Milliseconds 600
    $after = Get-ProbeState
    Assert (($after.Caption - $before.Caption) -ge 5 -and ($after.Strip - $before.Strip) -ge 5) `
        "D both painters ran for each paint (caption +$($after.Caption - $before.Caption), strip +$($after.Strip - $before.Strip))"
    Assert ($after.CaptionBuilds -eq $before.CaptionBuilds) `
        "D the caption buffer was not rebuilt (builds $($before.CaptionBuilds) -> $($after.CaptionBuilds))"
    Assert ($after.StripBuilds -eq $before.StripBuilds) `
        "D the strip buffer was not rebuilt (builds $($before.StripBuilds) -> $($after.StripBuilds))"

    # A resize IS a new size, and the one time a rebuild is owed: the control
    # that shows `builds` can move at all.
    Set-TestWindowSize -Window $top -Width 1000 -Height 650 | Out-Null
    Start-Sleep -Seconds 1
    [void][T2987Native]::Invalidate($top, 0, 0, 2000, 6)
    Start-Sleep -Milliseconds 800
    $resized = Get-ProbeState
    Assert ($resized.StripBuilds -gt $after.StripBuilds) `
        "D a resize rebuilds the strip buffer (builds $($after.StripBuilds) -> $($resized.StripBuilds)) - the control that the count can move"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived the whole run'
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    if ($td) { Remove-TestDesktop }
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chrome-paint-clip -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'chrome-paint-clip' -MinPass 14
