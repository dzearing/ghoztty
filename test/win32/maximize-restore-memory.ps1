# T3002 acceptance: a window that was maximized gives its pixel buffers back
# when it is restored.
#
# WHY. The pane desk (src/apprt/win32/PaneDesk.zig) keeps the gradient, the
# compose scratch, the quarter-size desk, the glow pictures and the composed
# bitmaps between paints, so a window-edge drag never page-faults a buffer in
# mid-step (T2520, T2529, T2946). They were grown and never shrunk: a window
# maximized once kept every one of them at the maximized size until it closed
# (audit-1 PA-M02: 25-40 MB a window at 1400x900, 165-265 MB at 4K). The chrome
# overlay's two desk-sized buffers (chrome_comp.zig `Overlay`) did the same.
# Now, outside a drag, each fits the window again: the CPU buffers drop their
# slack past twice the need, and the bitmap sections are re-mapped once they
# are twice the bitmap. Under a drag nothing changes - the canvas holds still
# (T2577) and every buffer keeps its room.
#
# HOW. One window, two panes, at a fixed restored size. Sample private bytes
# settled, then maximize and restore it -Cycles times, sampling after each.
#
#   A0  maximizing takes memory (the meter can see the desk's buffers at all)
#   A1  every restore gives back at least one desk-sized buffer of the
#       difference: (maximized area - restored area) x 4 bytes
#   A2  no growth across the cycles after the first (the last restored
#       sample vs the second; the first warms caches outside the desk)
#   B1  no segfault or panic in the app log
#   B2  the GUI never showed on the interactive desktop
#
# -NegativeControl runs the app with GHOZTTY_DESK_KEEP_BUFFERS=1, the old
# keep-the-largest behaviour: A1 MUST go red, which proves this meter sees
# the release rather than a coincidence of the heap.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\maximize-restore-memory.ps1
param([string]$ExePath, [int]$Cycles = 3, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-maxrestmem$PID"
if ($NegativeControl) { $env:GHOZTTY_DESK_KEEP_BUFFERS = '1' } else { Remove-Item Env:GHOZTTY_DESK_KEEP_BUFFERS -ErrorAction SilentlyContinue }
$errlog = Join-Path $env:TEMP "ghoztty-maximize-restore-memory-$PID.log"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

# Settled, then a few seconds more for the paint after a size change and the
# page allocator's decommit to land; the smaller of two reads.
function Get-QuietSample([int]$ProcessId, [string]$Label) {
    $a = Wait-Settled $ProcessId $Label
    Start-Sleep -Seconds 2
    $b = Get-Sample $ProcessId $Label
    if ([double]$b.PrivMB -lt [double]$a.PrivMB) { return $b }
    return $a
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { throw 'no window appeared' }
    Start-Sleep -Seconds 2
    $r = Invoke-Verb @('+split', '--name=mrm2', '--direction=right')
    if ($r.Code -ne 0) { throw "+split failed: $($r.Text)" }

    $wa = Get-TestWorkArea
    $rw = [math]::Min(1000, [int]($wa.Width / 2))
    $rh = [math]::Min(700, [int]($wa.Height / 2))
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 20) -Y ($wa.Top + 20) -Width $rw -Height $rh)
    Start-Sleep -Seconds 2
    # One desk-sized buffer of the difference, in MB: the bar every restore
    # must give back. The window's frame makes both areas a little smaller
    # than these, by about the same amount.
    $barMB = [math]::Round((([double]$wa.Width * $wa.Height) - ([double]$rw * $rh)) * 4 / 1MB, 1)
    Write-Host ("work area {0}x{1}, restored {2}x{3}: one buffer of the difference is {4} MB" -f $wa.Width, $wa.Height, $rw, $rh, $barMB)

    $rows = @()
    $rows += Get-QuietSample $appPid 'restored 0'
    for ($i = 1; $i -le $Cycles; $i++) {
        [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command maximize)
        Start-Sleep -Seconds 2
        $rows += Get-QuietSample $appPid "maximized $i"
        [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command restore)
        Start-Sleep -Seconds 2
        $rows += Get-QuietSample $appPid "restored $i"
    }
    $rows | Format-Table Label, PrivMB, Handles, Gdi, Threads -AutoSize | Out-String | Write-Host

    $took = [double]$rows[1].PrivMB - [double]$rows[0].PrivMB
    Assert ($took -ge $barMB) "A0 maximizing takes at least one buffer of the difference (took $([math]::Round($took,1)) MB, bar $barMB)"
    $drops = @()
    for ($k = 1; $k -lt $rows.Count; $k += 2) { $drops += [double]$rows[$k].PrivMB - [double]$rows[$k + 1].PrivMB }
    $minDrop = ($drops | Measure-Object -Minimum).Minimum
    Assert ($minDrop -ge $barMB) "A1 every restore gives back at least one buffer of the difference (smallest drop $([math]::Round($minDrop,1)) MB, bar $barMB)"
    # From the SECOND restore: the first maximize-restore warms caches outside
    # the desk by a one-time ~7 MB, which the negative control shows as well
    # (2026-11-15, 4K test desktop: 337.5 -> 344.9 -> 344.9 kept, 306.6 ->
    # 314.1 -> 314.2 fitted). What A2 asks is that the cycles after it are flat.
    $first = [double]$rows[4].PrivMB
    $last = [double]$rows[-1].PrivMB
    Assert (($last - $first) -le [math]::Max(2.0, $barMB / 4)) "A2 no growth after the first cycle (second restored $first MB, last $last MB)"

    $crashed = (Test-Path $errlog) -and (Select-String -Path $errlog -Pattern 'Segmentation fault|panic' -Quiet)
    Assert (-not $crashed) 'B1 no segfault or panic in the app log'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
} catch {
    $script:fail++
    Write-Host "FAIL  aborted: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item Env:GHOZTTY_DESK_KEEP_BUFFERS -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

if ($NegativeControl) {
    if ($script:fail -gt 0) { Write-Host "NEGATIVE CONTROL OK: $($script:fail) assert(s) went red with the buffers kept"; exit 0 }
    Write-Host 'NEGATIVE CONTROL FAILED: nothing went red with the buffers kept' -ForegroundColor Red
    exit 1
}
if ($script:fail -eq 0 -and $Cycles -ge 3) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard maximize-restore-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) passed)"; exit 0 }
Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"
exit 1
