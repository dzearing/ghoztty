# T2360 step 1: run the Windows.UI.Composition spike (zig-out\bin\ghoztty-comp-spike.exe)
# and print one SUMMARY line per run.
#
# Each run is one mode of the same blade collapse/expand schedule:
#   idle  nothing animates (the noise floor for the compose clock)
#   gdi   today's shape: child HWNDs hand-stepped by a 16 ms SetTimer
#   comp  SpriteVisuals under a desktop window target; each glide is declared
#         once as keyframe animations that DWM runs on its own clock
# -StallMs blocks the UI thread halfway through every glide. -Thread worker
# puts the Compositor on its own thread (comp mode only).
#
# By default it runs on the background test desktop, so it never takes the
# user's focus. Know what that can measure (2026-10-29): init and the
# worker-thread target, the UI-thread step count of the gdi path, and nothing
# about frame cadence - DWM composes only the input desktop, and the
# compose clock it reads is system-wide (see src\apprt\win32\comp_spike_stats.zig).
#
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Modes idle,gdi,comp
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Modes gdi,comp -StallMs 500
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Modes comp -Thread worker
#
# Build first: zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug
# Reports land in temp\comp-spike\<mode>-<thread>-stall<ms>.txt.
param(
    [string]$Modes = 'idle,gdi,comp',
    [int]$StallMs = 0,
    [ValidateSet('ui', 'worker')][string]$Thread = 'ui',
    [int]$Glides = 8
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'test\win32\lib\TestDesktop.ps1')
$exe = Join-Path $repo 'zig-out\bin\ghoztty-comp-spike.exe'
if (-not (Test-Path $exe)) {
    Write-Host "comp-spike: $exe is missing - run: zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug"
    exit 2
}
$outDir = Join-Path $repo 'temp\comp-spike'
New-Item -ItemType Directory -Force $outDir | Out-Null

$failed = 0
New-TestDesktop | Out-Null
try {
    foreach ($m in ($Modes -split ',')) {
        $m = $m.Trim()
        $out = Join-Path $outDir ('{0}-{1}-stall{2}.txt' -f $m, $Thread, $StallMs)
        if (Test-Path $out) { Remove-Item -LiteralPath $out }
        $spikeArgs = @("--mode=$m", "--thread=$Thread", "--stall-ms=$StallMs", "--glides=$Glides", "--out=$out")
        $app = Start-OnTestDesktop -Exe $exe -Arguments $spikeArgs
        $null = $app.Process.Handle
        if (-not $app.Process.WaitForExit(60000)) {
            $app.Process.Kill()
            Write-Host "comp-spike: $m TIMED OUT after 60 s"
            $failed++
            continue
        }
        if (-not (Test-Path $out)) {
            Write-Host "comp-spike: $m wrote no report (exit $($app.Process.ExitCode))"
            $failed++
            continue
        }
        $lines = @(Get-Content -LiteralPath $out)
        $lines | Where-Object { $_ -match '^(SPIKE|CLOCK|SUMMARY|GLIDE_ERROR)' } | ForEach-Object { Write-Host $_ }
        if (-not ($lines | Where-Object { $_ -match '^SUMMARY ' })) { $failed++ }
    }
} finally {
    Remove-TestDesktop | Out-Null
}
if ($failed -gt 0) { Write-Host "comp-spike: $failed run(s) did not finish"; exit 1 }
Write-Host 'comp-spike: all runs finished'
exit 0
