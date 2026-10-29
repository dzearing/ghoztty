# T2360 step 1: run the Windows.UI.Composition spike (zig-out\bin\ghoztty-comp-spike.exe)
# and print its summary lines per run.
#
# Each run is one mode of the same blade collapse/expand schedule:
#   idle  the same blade, never moved (the noise floor)
#   gdi   today's shape: child HWNDs hand-stepped by a 16 ms SetTimer
#   comp  SpriteVisuals under a desktop window target; each glide is declared
#         once as keyframe animations that DWM runs on its own clock
# -StallMs blocks the UI thread halfway through every glide. -Thread worker
# puts the Compositor on its own thread (comp mode only).
#
# Two places to run it:
#
#   default  the background test desktop. Measures init, the worker-thread
#            target and the gdi path's UI-thread step count. NO cadence: DWM
#            composes only the input desktop, and Windows.Graphics.Capture
#            refuses a window on any other (CreateCaptureSession returns
#            ERROR_INVALID_STATE; measured 2026-10-29, T2463).
#   -Live    the input desktop, as a GHOST window (--ghost): alpha 1/255,
#            click-through, bottom of the z-order, never activated, no taskbar
#            button. DWM composes it and WGC captures it, and the person at
#            the desk cannot see it or lose focus to it. This is where the
#            per-window oracle (WGLIDE/WHOLDS/WSUMMARY) has numbers.
#            Off-screen placement is NOT a substitute: off every monitor a GDI
#            window is never repainted (1 frame) and composition is throttled
#            to ~40 Hz (measured 2026-10-29).
#
# -CheckOracle (with -Live and -Modes idle,gdi,comp) asserts the oracle can
# tell the three apart: idle 0 new frames, gdi advance_mean < 0.6 (today's
# 16 ms timer lands on about one 120 Hz refresh in three), comp >= 0.9. Exit 1
# when it cannot - that is a broken oracle, not a slow path.
#
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Live -CheckOracle
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Live -Modes gdi,comp -StallMs 500
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Live -Modes comp -Thread worker
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Modes comp -Thread worker
#
# Build first: zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug
# Reports land in temp\comp-spike\<live|bg>-<mode>-<thread>-stall<ms>.txt.
param(
    [string]$Modes = 'idle,gdi,comp',
    [int]$StallMs = 0,
    [ValidateSet('ui', 'worker')][string]$Thread = 'ui',
    [int]$Glides = 8,
    [switch]$Live,
    [switch]$CheckOracle
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'test\win32\lib\TestDesktop.ps1')
$exe = Join-Path $repo 'zig-out\bin\ghoztty-comp-spike.exe'
if (-not (Test-Path $exe)) {
    Write-Host "comp-spike: $exe is missing - run: zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug"
    exit 2
}
if ($CheckOracle -and -not $Live) {
    Write-Host 'comp-spike: -CheckOracle needs -Live (WGC cannot capture on the background desktop)'
    exit 2
}
$outDir = Join-Path $repo 'temp\comp-spike'
New-Item -ItemType Directory -Force $outDir | Out-Null

function Get-Field([string]$line, [string]$name) {
    if ($line -match "(?:^| )$name=([^ ]+)") { return $Matches[1] }
    return $null
}

$failed = 0
$wsum = @{}
if (-not $Live) { New-TestDesktop | Out-Null }
try {
    foreach ($m in ($Modes -split ',')) {
        $m = $m.Trim()
        $where = if ($Live) { 'live' } else { 'bg' }
        $out = Join-Path $outDir ('{0}-{1}-{2}-stall{3}.txt' -f $where, $m, $Thread, $StallMs)
        if (Test-Path $out) { Remove-Item -LiteralPath $out }
        $spikeArgs = @("--mode=$m", "--thread=$Thread", "--stall-ms=$StallMs", "--glides=$Glides", "--out=$out")
        if ($Live) {
            $spikeArgs += @('--ghost', '--x=200', '--y=200')
            $proc = Start-Process -FilePath $exe -ArgumentList $spikeArgs -PassThru -WindowStyle Hidden
        } else {
            $proc = (Start-OnTestDesktop -Exe $exe -Arguments $spikeArgs).Process
        }
        $null = $proc.Handle
        if (-not $proc.WaitForExit(60000)) {
            $proc.Kill()
            Write-Host "comp-spike: $m TIMED OUT after 60 s"
            $failed++
            continue
        }
        if (-not (Test-Path $out)) {
            Write-Host "comp-spike: $m wrote no report (exit $($proc.ExitCode))"
            $failed++
            continue
        }
        $lines = @(Get-Content -LiteralPath $out)
        $lines | Where-Object { $_ -match '^(SPIKE|CLOCK|SUMMARY|WCLOCK|WHOLDS|WSUMMARY|GLIDE_ERROR)' } | ForEach-Object { Write-Host $_ }
        if (-not ($lines | Where-Object { $_ -match '^SUMMARY ' })) { $failed++ }
        $ws = $lines | Where-Object { $_ -match '^WSUMMARY ' } | Select-Object -First 1
        if ($ws) { $wsum[$m] = $ws }
    }
} finally {
    if (-not $Live) { Remove-TestDesktop | Out-Null }
}
if ($failed -gt 0) { Write-Host "comp-spike: $failed run(s) did not finish"; exit 1 }

if ($CheckOracle) {
    $bad = @()
    foreach ($m in 'idle', 'gdi', 'comp') {
        if (-not $wsum.ContainsKey($m) -or $wsum[$m] -match 'oracle=UNAVAILABLE') { $bad += "$m has no per-window score" }
    }
    if ($bad.Count -eq 0) {
        $idleNew = [int](Get-Field $wsum['idle'] 'new_frames')
        $gdiAdv = [double](Get-Field $wsum['gdi'] 'advance_mean')
        $compAdv = [double](Get-Field $wsum['comp'] 'advance_mean')
        if ($idleNew -ne 0) { $bad += "idle scored $idleNew new frames (want 0)" }
        if ($gdiAdv -ge 0.6) { $bad += "gdi advance_mean $gdiAdv (want < 0.6)" }
        if ($compAdv -lt 0.9) { $bad += "comp advance_mean $compAdv (want >= 0.9)" }
    }
    if ($bad.Count -gt 0) {
        Write-Host ('comp-spike: ORACLE FAIL - ' + ($bad -join '; '))
        exit 1
    }
    Write-Host "comp-spike: ORACLE PASS idle=0 new frames, gdi advance=$gdiAdv, comp advance=$compAdv"
}
Write-Host 'comp-spike: all runs finished'
exit 0
