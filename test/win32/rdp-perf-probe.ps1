# T1950 acceptance: scripts\rdp-perf-probe.ps1 measures what it says it does.
#
# The probe is the instrument the user runs inside a Remote Desktop / Cloud PC
# session to say where Ghoztty's cost goes there. It is only worth anything if
# its numbers are real, and its first draft already broke once on a CLI flag
# (`+send-keys --name=` is not a flag, so every echo sample timed out and the
# report printed `0/12` without complaint). So this runs it end to end against
# the debug build, with the software path FORCED the way the Cloud PC reaches
# it (GHOZTTY_GL_FORCE_VERSION=1.1 + GALLIUM_DRIVER=d3d12 +
# LIBGL_ALWAYS_SOFTWARE=1, i.e. Mesa d3d12 on WARP), and asserts:
#
#   SNAPSHOT. Part 1 finds the instance this script launched, measures its CPU,
#   names opengl32.dll among its loaded modules, counts its 1 window / 1 pane
#   over the instance's pipe, and reads the console session as NOT remote
#   (SM_REMOTESESSION is 0 here; a real remote session is T1256's, which this
#   box cannot originate).
#
#   MEASURED. Part 2 produces a row for both modes with every echo sample
#   answered, the renderer's own low-power line under each, and the cap
#   VISIBLE through the probe: the unfocused spinner presents at <= 6 fps
#   under `auto` and at >= 8 under `off`. A probe that measured the wrong pane,
#   or measured nothing, cannot pass that.
#
#   CLEAN. The probe's instances are gone afterwards, and none of them ever
#   became foreground on the interactive desktop (-TestDesktop puts them on a
#   background desktop).
#
# -NegativeControl asserts the spinner is NOT capped under `auto`, and MUST fail.
#
#   powershell -NoProfile -File test\win32\rdp-perf-probe.ps1
param([string]$ExePath, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$probe = Join-Path $repo 'scripts\rdp-perf-probe.ps1'

$env:GHOZTTY_PIPE_SUFFIX = "-rdpprobe-t$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Set-SoftwarePath([bool]$on) {
    if ($on) {
        $env:GHOZTTY_GL_FORCE_VERSION = '1.1'
        $env:GALLIUM_DRIVER = 'd3d12'
        $env:LIBGL_ALWAYS_SOFTWARE = '1'
    } else {
        Remove-Item Env:\GHOZTTY_GL_FORCE_VERSION, Env:\GALLIUM_DRIVER, Env:\LIBGL_ALWAYS_SOFTWARE -ErrorAction SilentlyContinue
    }
}

function Get-RepoAppPids {
    @(Get-CimInstance Win32_Process -Filter "Name = 'ghoztty.exe'" | Where-Object { $_.ExecutablePath -eq $exe } | ForEach-Object { [int]$_.ProcessId })
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop
$out = Join-Path $env:TEMP "ghoztty-rdpprobe-t$PID.md"
$probePids = @()

try {
    Set-SoftwarePath $true
    # persistence: off - --session-persistence=false; the snapshot counts this
    # instance's windows and panes, so a restored layout would change the count.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--config-default-files=false', '--session-persistence=false', '--command=cmd.exe')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $console = & powershell -NoProfile -ExecutionPolicy Bypass -File $probe -Exe $exe -Seconds 6 -Measure -TestDesktop -Out $out 2>&1 | ForEach-Object { "$_" } | Out-String
    $probeExit = $LASTEXITCODE
    Assert ($probeExit -eq 0) "the probe exits 0 (exit $probeExit)"
    Assert (Test-Path $out) 'the probe wrote its report'
    $r = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }

    # --- SNAPSHOT -----------------------------------------------------------
    Assert ($r -match 'remote session: no \(console\)') 'snapshot: the console session reads as not remote'
    Assert ($r -match 'display adapter: \S') 'snapshot: the display adapters are named'
    $sec = ''
    $mSec = [regex]::Match($r, "(?s)### pid $($app.Pid)\r?\n(.*?)(?=\r?\n###|\r?\n## )")
    if ($mSec.Success) { $sec = $mSec.Groups[1].Value }
    Assert ($sec -ne '') "snapshot: the launched instance (pid $($app.Pid)) has a section"
    Assert ($sec -match 'CPU over \d+ s: \*\*[\d.]+ cores\*\*; threads \d+') 'snapshot: its CPU and thread count are measured'
    Assert ($sec -match '(?i)GL/D3D module: .*opengl32\.dll') 'snapshot: opengl32.dll is among its loaded modules'
    Assert ($sec -match '(?i)GL/D3D module: .*\\gl\\opengl32\.dll \(bundled Mesa\)') 'snapshot: the bundled Mesa (gl\opengl32.dll) is loaded, and labelled, on the forced software path'
    Assert ($r -match 'windows: 1, panes: 1 ') 'snapshot: 1 window / 1 pane counted over the instance pipe'

    # --- MEASURED -----------------------------------------------------------
    $rows = @{}
    foreach ($m in [regex]::Matches($r, '(?m)^\| (off|auto) \| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\| ([^|]+)\|')) {
        $rows[$m.Groups[1].Value] = [pscustomobject]@{
            Cores = $m.Groups[2].Value.Trim(); SpinFps = $m.Groups[4].Value.Trim(); EchoMed = $m.Groups[8].Value.Trim(); Samples = $m.Groups[10].Value.Trim()
        }
    }
    foreach ($mode in 'off', 'auto') {
        $row = $rows[$mode]
        Assert ($null -ne $row) "measured: a row for low-power=$mode"
        if ($row) {
            Write-Host "      $mode : cores $($row.Cores), spinner $($row.SpinFps) fps, echo median $($row.EchoMed) ms, $($row.Samples)"
            Assert ($row.Samples -eq '12/12') "measured ($mode): every echo sample answered ($($row.Samples))"
            Assert ($row.EchoMed -match '^[\d.]+$') "measured ($mode): an echo median is a number ($($row.EchoMed))"
        }
    }
    Assert ($r -match '\[off\] warning\(low_power\): low-power rendering pinned off') 'measured (off): the instance logs low-power pinned off'
    Assert ($r -match '\[auto\] info\(low_power\): low-power rendering on: renderer="[^"]*Basic Render Driver') 'measured (auto): the instance logs low-power on with the WARP renderer'
    if ($rows['off'] -and $rows['auto']) {
        $off = 0.0; $auto = 0.0
        [void][double]::TryParse($rows['off'].SpinFps, [ref]$off)
        [void][double]::TryParse($rows['auto'].SpinFps, [ref]$auto)
        Assert ($off -ge 8) "measured (off): the unfocused spinner presents at full rate ($off fps >= 8)"
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the spinner is NOT capped under auto - this run MUST fail'
            Assert ($auto -ge 8) "measured (auto): the spinner runs at full rate (negative control)"
        } else {
            Assert (($auto -gt 0) -and ($auto -le 6)) "measured (auto): the cap is visible through the probe ($auto fps <= 6)"
        }
    }

    # --- CLEAN --------------------------------------------------------------
    $probePids = @([regex]::Matches($r, 'instance pid (\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
    Assert ($probePids.Count -eq 2) "clean: the report names both measured instances ($($probePids.Count))"
    $alive = @(Get-RepoAppPids | Where-Object { $probePids -contains $_ })
    Assert ($alive.Count -eq 0) "clean: the probe's instances are gone afterwards (alive: $($alive -join ','))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'clean: the probe left this script''s own instance running (it stops only its own)'
    if ($script:fail -gt 0) { Write-Host ($console -split "`n" | Select-Object -Last 25 | Out-String) }
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Set-SoftwarePath $false
    Remove-Item $out -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$launched = @(@(Get-TestLaunchedPids) + $probePids | Select-Object -Unique)
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
$leaked = @($launched | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) 'no instance (this script''s or the probe''s) ever became foreground on the interactive desktop'

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard rdp-perf-probe -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'RDP PERF PROBE ACCEPTANCE'
