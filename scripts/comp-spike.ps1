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
# T2465, the WARP path. -Surface auto|hardware|warp paints the comp blade into
# a CompositionDrawingSurface on a D3D11 device of that kind (WARP is the CPU
# rasterizer a Remote Desktop session or a GPU-less machine gets) instead of a
# colour brush. -RebindAfterGlide N swaps a fresh device (-RebindTo) in under
# that surface right after glide N is declared - the device-loss recovery a
# Remote Desktop connect triggers. Every run also prints CPU lines: the spike's
# own process time per glide, and dwm.exe's when Windows lets us read it.
# -CheckSurface (with -Live -Modes comp and -Surface) asserts the device kind
# took, the glides still score >= 0.9, and a rebind kept the blade drawn and
# moving through the glide it landed in.
#
#   powershell -NoProfile -File scripts\comp-spike.ps1 -Live -Modes comp -Surface warp -RebindAfterGlide 3 -CheckSurface
#
# Build first: zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug
# Reports land in temp\comp-spike\<live|bg>-<mode>-<thread>-stall<ms>.txt.
param(
    [string]$Modes = 'idle,gdi,comp',
    [int]$StallMs = 0,
    [ValidateSet('ui', 'worker')][string]$Thread = 'ui',
    [int]$Glides = 8,
    [switch]$Live,
    [switch]$CheckOracle,
    [ValidateSet('none', 'auto', 'hardware', 'warp')][string]$Surface = 'none',
    [int]$RebindAfterGlide = -1,
    [ValidateSet('auto', 'hardware', 'warp')][string]$RebindTo = 'warp',
    [switch]$CheckSurface,
    # Where the -Live ghost sits. It is bottom-most, and DWM stops running
    # compositor animations for a window that is COMPLETELY covered (measured
    # 2026-11-05, T2465: under a maximized window comp captured 1 frame per
    # run while gdi's repaints still came through), so pick a spot some part of
    # the desktop shows through - a second monitor, or beside a window.
    [int]$X = 200,
    [int]$Y = 200
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
if ($CheckSurface -and (-not $Live -or $Surface -eq 'none')) {
    Write-Host 'comp-spike: -CheckSurface needs -Live and -Surface'
    exit 2
}
$outDir = Join-Path $repo 'temp\comp-spike'
New-Item -ItemType Directory -Force $outDir | Out-Null

# dwm.exe CPU in ms (every session's dwm summed), or a throw when Windows will
# not say. Composition work happens there, not in the spike's own process.
function Get-DwmCpuMs {
    $t = 0.0
    foreach ($p in @(Get-Process -Name dwm -ErrorAction Stop)) {
        if ($null -eq $p.TotalProcessorTime) { throw 'no access' }
        $t += $p.TotalProcessorTime.TotalMilliseconds
    }
    return $t
}

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
        $useSurface = ($m -eq 'comp' -and $Surface -ne 'none')
        $sfx = ''
        if ($useSurface) {
            $sfx = "-surf$Surface"
            if ($RebindAfterGlide -ge 0) { $sfx += "-rebind$RebindAfterGlide$RebindTo" }
        }
        $out = Join-Path $outDir ('{0}-{1}-{2}-stall{3}{4}.txt' -f $where, $m, $Thread, $StallMs, $sfx)
        if (Test-Path $out) { Remove-Item -LiteralPath $out }
        $spikeArgs = @("--mode=$m", "--thread=$Thread", "--stall-ms=$StallMs", "--glides=$Glides", "--out=$out")
        if ($useSurface) {
            $spikeArgs += "--surface=$Surface"
            if ($RebindAfterGlide -ge 0) { $spikeArgs += @("--rebind-after-glide=$RebindAfterGlide", "--rebind-to=$RebindTo") }
        }
        $dwm0 = $null
        try { $dwm0 = Get-DwmCpuMs } catch { $dwm0 = $null }
        if ($Live) {
            $spikeArgs += @('--ghost', "--x=$X", "--y=$Y")
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
        $dwmMs = $null
        if ($null -ne $dwm0) { try { $dwmMs = (Get-DwmCpuMs) - $dwm0 } catch { $dwmMs = $null } }
        $lines = @(Get-Content -LiteralPath $out)
        $lines | Where-Object { $_ -match '^(SPIKE|CLOCK|SUMMARY|WCLOCK|WHOLDS|WSUMMARY|GLIDE_ERROR|DEVICE|SESSION|CPU)' } | ForEach-Object { Write-Host $_ }
        if ($null -ne $dwmMs) {
            Write-Host ('DWMCPU mode={0} run_ms={1:N1} per_glide_ms={2:N2} (whole run incl. warm-up; every window DWM composed)' -f $m, $dwmMs, ($dwmMs / [Math]::Max(1, $Glides)))
        } else {
            Write-Host "DWMCPU mode=$m unavailable (dwm.exe process times not readable)"
        }
        if ($m -eq 'comp') { $script:compLines = $lines }
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
if ($CheckSurface) {
    $bad = @()
    $L = @($script:compLines)
    $init = $L | Where-Object { $_ -match '^DEVICE init ' } | Select-Object -First 1
    $ws = $L | Where-Object { $_ -match '^WSUMMARY ' } | Select-Object -First 1
    $fin = $L | Where-Object { $_ -match '^DEVICE final ' } | Select-Object -First 1
    if (-not $init) { $bad += 'no DEVICE init line (the surface was never created)' }
    elseif ($Surface -eq 'warp' -and (Get-Field $init 'warp') -ne 'true') { $bad += "asked for warp, got: $init" }
    elseif ($Surface -eq 'hardware' -and (Get-Field $init 'warp') -ne 'false') { $bad += "asked for hardware, got: $init" }
    if (-not $ws -or $ws -match 'oracle=UNAVAILABLE') { $bad += 'no per-window score' }
    elseif ([double](Get-Field $ws 'advance_mean') -lt 0.9) { $bad += "surface comp advance_mean $(Get-Field $ws 'advance_mean') (want >= 0.9)" }
    if ($RebindAfterGlide -ge 0) {
        $rb = $L | Where-Object { $_ -match '^DEVICE rebind ' } | Select-Object -First 1
        if (-not $rb -or (Get-Field $rb 'ok') -ne 'true') { $bad += "the rebind did not succeed: $rb" }
        $g = $L | Where-Object { $_ -match "^WGLIDE i=$RebindAfterGlide " } | Select-Object -First 1
        if (-not $g) { $bad += "no WGLIDE for glide $RebindAfterGlide" }
        elseif ([double](Get-Field $g 'advance') -lt 0.9) { $bad += "glide $RebindAfterGlide (the rebind) advance $(Get-Field $g 'advance') (want >= 0.9)" }
        foreach ($a in @($L | Where-Object { $_ -match '^WGLIDE i=(\d+) ' -and [int]$Matches[1] -gt $RebindAfterGlide })) {
            if ([int](Get-Field $a 'new_frames') -eq 0) { $bad += "the blade stopped moving after the rebind: $a" }
        }
        if (-not $fin -or [int](Get-Field $fin 'draws') -lt 2 -or [int](Get-Field $fin 'rebinds') -lt 1) { $bad += "the surface was not redrawn on the new device: $fin" }
    }
    if ($bad.Count -gt 0) {
        Write-Host ('comp-spike: SURFACE FAIL - ' + ($bad -join '; '))
        exit 1
    }
    $rbNote = ''
    if ($RebindAfterGlide -ge 0) { $rbNote = " rebind@glide$RebindAfterGlide->$RebindTo kept drawing" }
    Write-Host "comp-spike: SURFACE PASS $Surface advance=$(Get-Field $ws 'advance_mean')$rbNote"
}
Write-Host 'comp-spike: all runs finished'
exit 0
