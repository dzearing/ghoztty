# @timing-sensitive
# T2974 acceptance: a pane's GPU storage comes back down after its window
# was bigger.
#
# WHY. On Win32 a pane's render target, the composition path's shared
# texture and its swap chain all grow in 256 px buckets and used to keep any
# larger allocation (T2577/T2598 - a window-edge drag rebuilt them on every
# step otherwise). So they only ever grew: a pane once maximized held its
# maximized-size storage for life, whatever size it was now. The fix trims
# them once the size has held still for a second (renderer/storage_trim.zig).
#
# HOW. One app on the test desktop, one window split into two panes at
# 1000x700. Sample GPU dedicated memory once settled (BASE). Maximize the
# window through the real WM_SYSCOMMAND path and settle (PEAK), restore it and
# wait past the settle (RESTORED).
#
#   A1  the meter can see it: PEAK - BASE is at least -MinGrowMB, i.e. the
#       maximize grew the panes' storage at all (else the box's screen is too
#       small to say anything, and the run SKIPs rather than passes).
#   A2  RESTORED is within 10% (or -SlackMB, whichever is larger) of BASE:
#       the restore gave the maximized storage back.
#   A3  the restored window still draws: both panes are listed and the app
#       survived.
#
# -NegativeControl launches with GHOZTTY_STORAGE_TRIM=0 (the high-water
# behavior from before T2974). A2 MUST go red: it is the proof that this
# meter can see storage that was never given back.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\storage-trim-memory.ps1
param(
    [string]$ExePath,
    [double]$MinGrowMB = 8,
    [double]$SlackMB = 4,
    [int]$Cycles = 2,
    [switch]$NegativeControl,
    [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-storagetrim$PID"
if ($NegativeControl) { $env:GHOZTTY_STORAGE_TRIM = '0' } else { Remove-Item Env:GHOZTTY_STORAGE_TRIM -ErrorAction SilentlyContinue }
$errlog = Join-Path $env:TEMP "ghoztty-storage-trim-$PID.log"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Get-LeafIds {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add([string]$o.id) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($r.Text | ConvertFrom-Json) } catch { return @() }
    return $out.ToArray()
}

# GPU dedicated MB once it has stopped moving: two reads 1s apart within
# 0.5 MB, after at least $MinWaitMs (the trim waits a full second of quiet).
function Wait-GpuSettled([int]$ProcessId, [int]$MinWaitMs = 2500, [int]$TimeoutSec = 20) {
    Start-Sleep -Milliseconds $MinWaitMs
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $prev = $null
    do {
        $g = Get-GpuBytes $ProcessId
        if ($null -eq $g) { return $null }
        $mb = [math]::Round($g.Dedicated / 1MB, 1)
        if ($null -ne $prev -and [math]::Abs($mb - $prev) -le 0.5) { return $mb }
        $prev = $mb
        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)
    return $prev
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'the window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    $top = [IntPtr]$top
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1000 -Height 700)
    $deadline = (Get-Date).AddSeconds(15)
    $ids = @()
    do { $ids = @(Get-LeafIds); if ($ids.Count -ge 1) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    if ($ids.Count -ne 1) { throw "expected one pane at launch, +list shows $($ids.Count)" }
    $r = Invoke-Verb @('+split', "--target=$($ids[0])", '--name=sttrim2', '--direction=right')
    if ($r.Code -ne 0) { throw "+split failed: $($r.Text)" }
    $deadline = (Get-Date).AddSeconds(15)
    do { Start-Sleep -Milliseconds 300 } while (@(Get-LeafIds).Count -lt 2 -and (Get-Date) -lt $deadline)
    Assert (@(Get-LeafIds).Count -eq 2) 'the window is split into two panes'

    if ($null -eq (Get-GpuBytes $appPid)) {
        $script:skipped++
        Write-Host 'SKIP  A1/A2: the GPU Process Memory counters are not readable on this box'
    } else {
        $base = Wait-GpuSettled $appPid 3000
        Write-Host "BASE      $base MB dedicated (1000x700, two panes)"
        $worstRestored = $null
        $peakGrow = 0.0
        for ($i = 1; $i -le $Cycles; $i++) {
            Assert (Send-TestSysCommand -Window $top -Command maximize) "cycle $i maximize was delivered"
            $peak = Wait-GpuSettled $appPid 2500
            Assert (Send-TestSysCommand -Window $top -Command restore) "cycle $i restore was delivered"
            $restored = Wait-GpuSettled $appPid 3000
            Write-Host "cycle $i  PEAK $peak MB, RESTORED $restored MB"
            $peakGrow = [math]::Max($peakGrow, $peak - $base)
            if ($null -eq $worstRestored -or $restored -gt $worstRestored) { $worstRestored = $restored }
        }
        if ($peakGrow -lt $MinGrowMB) {
            $script:skipped++
            Write-Host ("SKIP  A1 a maximize grew GPU memory by only {0:N1} MB (< {1} MB): this screen is too small for the meter to see a trim" -f $peakGrow, $MinGrowMB)
        } else {
            Assert $true ("A1 the meter sees the maximize: +{0:N1} MB at its peak" -f $peakGrow)
            $allow = [math]::Max($base * 0.10, $SlackMB)
            $over = $worstRestored - $base
            Assert ($over -le $allow) ("A2 restored GPU dedicated is back within {0:N1} MB of the never-maximized {1} MB (worst {2} MB, +{3:N1})" -f $allow, $base, $worstRestored, $over)
        }
    }

    Assert (@(Get-LeafIds).Count -eq 2) 'A3 both panes are still listed after the restores'
    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) 'A3 the app survived every cycle'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B1 GUI never became visible on the interactive desktop'
    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item Env:GHOZTTY_STORAGE_TRIM -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783); a run with skips does not.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard storage-trim-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 8
