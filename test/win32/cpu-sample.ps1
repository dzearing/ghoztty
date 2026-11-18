<#
.SYNOPSIS
  Acceptance test for scripts\cpu-sample.ps1, the no-elevation sampling CPU
  profiler (T3159).

.DESCRIPTION
  The profiler exists because `wpr -start CPU` needs an elevated shell and the
  loop never has one. What has to be true for its numbers to be believed:

  A. -ImagePath picks up a process born AFTER the run started (a session
     holder is born exactly that way), and its on-CPU samples land on the
     thread that is actually spinning.
  B. Negative control: a process that is alive but blocked gets (almost) no
     on-CPU samples. Without this the profile of a relay that mostly waits
     would be indistinguishable from one that mostly works.
  C. cycles mode (the biased first design, kept for comparison) still runs.
  D. The JSON report and the folded-stack file are well formed.
  E. The sampler never samples its own process (suspending the sampling
     thread would hang the run): asked for its own pid, it returns nothing,
     promptly.

  The spinner is a private copy of cmd.exe running a `for /L` loop, so
  -ImagePath matches it and nothing else on the box. Hidden window, no focus,
  no Ghoztty, no agent. ASCII-only by design.

  powershell -NoProfile -File test\win32\cpu-sample.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cs = Join-Path $repo 'scripts\cpu-sample.ps1'
$work = Join-Path $env:TEMP "cpu-sample-test-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$spinExe = Join-Path $work 'spin.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $spinExe
$kids = New-Object System.Collections.ArrayList

function Start-Spin([string]$Body) {
    $p = Start-Process $spinExe -ArgumentList '/d', '/c', $Body -WindowStyle Hidden -PassThru
    $null = $p.Handle
    [void]$kids.Add($p)
    return $p
}
function Invoke-Cs([string[]]$CsArgs) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $cs @CsArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = @($out) }
}

try {
    # --- A. born during the run, on-CPU attribution -----------------------
    ''
    '-- A. -ImagePath picks up a process born mid-run; samples land on the spinning thread'
    $ja = Join-Path $work 'a.json'
    $fa = Join-Path $work 'a.folded'
    $sampler = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$cs`"", '-ImagePath', "`"$spinExe`"",
        '-Seconds', '6', '-Out', "`"$ja`"", '-Folded', "`"$fa`"")
    $null = $sampler.Handle
    Start-Sleep -Milliseconds 2500
    $spin = Start-Spin 'for /L %i in (1,1,2000000000) do @rem'
    $done = $sampler.WaitForExit(60000)
    Assert 'A0 the sampler finished' $done ''
    $ra = if (Test-Path $ja) { Get-Content -Raw $ja | ConvertFrom-Json } else { $null }
    $pa = @(if ($ra) { $ra.processes | ForEach-Object { $_ } | Where-Object { $_.pid -eq $spin.Id } })
    Assert 'A1 the spinner (born 2.5 s into the run) was sampled' ($pa.Count -eq 1) "processes=$(if ($ra) { (@($ra.processes | ForEach-Object { "pid $($_.pid)" }) -join ',') } else { 'no report' }) spinner=$($spin.Id)"
    if ($pa.Count -eq 1) {
        $p = $pa[0]
        "     pid $($p.pid): cpu $($p.cpu_s) s, $($p.samples) oncpu samples over $($p.seen_s) s"
        Assert 'A2 at least 200 on-CPU samples in ~3 s of spinning' ($p.samples -ge 200) "samples=$($p.samples)"
        $topT = @($p.threads | ForEach-Object { $_ })[0]
        Assert 'A3 the spinning thread carries >= 90% of the samples' ($topT -and ($topT.samples / [math]::Max(1, $p.samples)) -ge 0.9) "top thread samples=$($topT.samples) of $($p.samples)"
        Assert 'A4 the report charges it most of the process CPU' ($p.cpu_s -ge 1.5) "cpu_s=$($p.cpu_s)"
        Assert 'A5 self rows are named in the spinner module' (@($p.self | ForEach-Object { $_ } | Where-Object { $_.name -match '^spin[!+]' }).Count -ge 1) (@($p.self | ForEach-Object { $_.name }) -join ', ')
    }
    Stop-Process -Id $spin.Id -Force -ErrorAction SilentlyContinue

    # --- B. negative control: alive but blocked --------------------------
    ''
    '-- B. negative control: a blocked process gets (almost) no on-CPU samples'
    $idle = Start-Spin 'ping -n 12 127.0.0.1 >nul'
    Start-Sleep -Milliseconds 1500
    $rb = Invoke-Cs @('-ProcessId', "$($idle.Id)", '-Seconds', '3', '-Out', (Join-Path $work 'b.json'))
    $jb = Get-Content -Raw (Join-Path $work 'b.json') | ConvertFrom-Json
    $pb = @($jb.processes | ForEach-Object { $_ })
    $nb = if ($pb.Count) { [int]$pb[0].samples } else { 0 }
    "     blocked cmd: $nb samples in 3 s"
    Assert 'B1 a blocked process: fewer than 10 on-CPU samples' ($pb.Count -eq 1 -and $nb -lt 10) "processes=$($pb.Count) samples=$nb"
    Assert 'B2 ... and the run says NO SAMPLES with exit 1 when there were none' (($nb -gt 0) -or ($rb.Exit -eq 1 -and ($rb.Lines -join "`n") -match 'NO SAMPLES')) "exit=$($rb.Exit)"
    Stop-Process -Id $idle.Id -Force -ErrorAction SilentlyContinue

    # --- C. cycles mode ---------------------------------------------------
    ''
    '-- C. cycles mode runs and samples a spinner'
    $spin2 = Start-Spin 'for /L %i in (1,1,2000000000) do @rem'
    Start-Sleep -Milliseconds 800
    $rc = Invoke-Cs @('-ProcessId', "$($spin2.Id)", '-Seconds', '2', '-Mode', 'cycles', '-Out', (Join-Path $work 'c.json'))
    $jc = Get-Content -Raw (Join-Path $work 'c.json') | ConvertFrom-Json
    Assert 'C1 exit 0 with samples' ($rc.Exit -eq 0 -and @($jc.processes)[0].samples -gt 100) "exit=$($rc.Exit)"
    Assert 'C2 the report names its mode' ($jc.mode -eq 'cycles' -and $ra.mode -eq 'oncpu') "c=$($jc.mode) a=$($ra.mode)"
    Stop-Process -Id $spin2.Id -Force -ErrorAction SilentlyContinue

    # --- D. output formats ------------------------------------------------
    ''
    '-- D. the folded-stack file is flamegraph input'
    $fl = if (Test-Path $fa) { @(Get-Content $fa | Where-Object { $_ }) } else { @() }
    Assert 'D1 folded lines exist' ($fl.Count -ge 1) ''
    Assert 'D2 every line is "pid<n>;frame;...;frame <weight>"' ($fl.Count -ge 1 -and @($fl | Where-Object { $_ -notmatch '^pid\d+;\S.* \d+$' }).Count -eq 0) (@($fl | Where-Object { $_ -notmatch '^pid\d+;\S.* \d+$' } | Select-Object -First 1) -join '')

    # --- E. never itself ----------------------------------------------------
    ''
    '-- E. the sampler never samples its own process'
    if (-not ('CpuSampler' -as [type])) { Add-Type -Path (Join-Path $repo 'scripts\lib\CpuSampler.cs') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $self = [CpuSampler]::Run('', [int[]]@($PID), 1000, 2, $null, '', 16, $true)
    $sw.Stop()
    Assert 'E1 asked for its own pid, it samples nothing' (@($self).Count -eq 0) "processes=$(@($self).Count)"
    Assert 'E2 ... and returns when the duration ends' ($sw.Elapsed.TotalSeconds -lt 5) "took $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s"

    Complete-TestBody
}
finally {
    foreach ($k in $kids) { if (-not $k.HasExited) { Stop-Process -Id $k.Id -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard cpu-sample -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T3159 CPU SAMPLER' -Pass $script:passes -Fail $script:failures
