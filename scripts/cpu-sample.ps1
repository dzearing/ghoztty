<#
.SYNOPSIS
    Sample where another process's CPU goes, without elevation (T3159).

.DESCRIPTION
    A user-mode sampling profiler: every -IntervalMs it reads each thread's
    cycle counter, and every thread that ran since the last tick is
    suspended, its stack walked with dbghelp, and the cycles it spent charged
    to that stack. See scripts\lib\CpuSampler.cs for the method and its one
    bias (a burst that ends in a wait is charged to the wait).

    Use it where `wpr -start CPU` would be the tool but the shell is not
    elevated - which, for the loop, is always.

    Targets: -ImagePath samples EVERY process running that exact exe,
    re-scanned four times a second, so a process born during the run (a
    session holder) is sampled from its first quarter second. -ProcessId
    samples exactly those pids.

    Symbols: the exe's own directory (its .pdb sits beside it) plus
    _NT_SYMBOL_PATH. A Windows DLL without a PDB resolves to its nearest
    export, which still names the syscall stubs (NtWriteFile, NtReadFile, ...).

.PARAMETER Seconds
    Longest run. -StopFile ends it sooner.

.PARAMETER StopFile
    End the run as soon as this file exists (the workload's "done" marker).

.PARAMETER Out
    JSON report: per process, the cycles observed and the top self /
    inclusive functions, source lines and stacks, each with its share and an
    estimated CPU seconds (share x the process's measured CPU time).

.PARAMETER Folded
    Folded-stack file (one "frame;frame;frame weight" line per stack), the
    input format of flamegraph.pl / speedscope.

.OUTPUTS
    A text report on stdout. Exit 0 = sampled something; 1 = no process
    matched or no sample landed; 2 = bad arguments.

.EXAMPLE
    powershell -NoProfile -File scripts\cpu-sample.ps1 -ImagePath zig-out-release\bin\ghoztty-agent.exe -Seconds 40 -Out temp\agent-prof.json
#>
[CmdletBinding()]
param(
    [string]$ImagePath,
    [int[]]$ProcessId,
    [int]$Seconds = 30,
    [int]$IntervalMs = 2,
    [string]$StopFile,
    [string]$Out,
    [string]$Folded,
    [int]$Top = 15,
    [int]$MaxFrames = 64,
    [string]$SymbolPath,
    # oncpu (default): walk only threads on a CPU at the tick, one tick each.
    # cycles: walk every thread that ran since the last tick, charged its
    # cycles wherever it stands (biased toward waits; see CpuSampler.cs).
    [ValidateSet('oncpu', 'cycles')][string]$Mode = 'oncpu'
)
$ErrorActionPreference = 'Stop'

if (-not $ImagePath -and -not $ProcessId) { Write-Host 'cpu-sample: give -ImagePath or -ProcessId'; exit 2 }
if ($ImagePath) {
    if (-not (Test-Path -LiteralPath $ImagePath)) { Write-Host "cpu-sample: no such image: $ImagePath"; exit 2 }
    $ImagePath = (Resolve-Path -LiteralPath $ImagePath).Path
}

if (-not ('CpuSampler' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'lib\CpuSampler.cs')
}

$sym = @()
if ($SymbolPath) { $sym += $SymbolPath }
if ($ImagePath) { $sym += (Split-Path $ImagePath) }
if ($env:_NT_SYMBOL_PATH) { $sym += $env:_NT_SYMBOL_PATH }
$symPath = ($sym -join ';')

$stop = if ($StopFile) { [IO.Path]::GetFullPath($StopFile) } else { $null }
$img = if ($ImagePath) { $ImagePath } else { '' }
$pids = if ($ProcessId) { [int[]]$ProcessId } else { [int[]]@() }

$t0 = Get-Date
$reps = [CpuSampler]::Run($img, $pids, $Seconds * 1000, $IntervalMs, $stop, $symPath, $MaxFrames, ($Mode -eq 'oncpu'))
$wall = ((Get-Date) - $t0).TotalSeconds

function Get-TopRows($dict, [double]$total, [double]$cpuS, [int]$n) {
    $rows = @()
    if ($total -le 0) { return , $rows }
    foreach ($kv in ($dict.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $n)) {
        $share = $kv.Value / $total
        $rows += [ordered]@{ name = $kv.Key; pct = [math]::Round(100 * $share, 1); est_cpu_s = [math]::Round($share * $cpuS, 2) }
    }
    return , $rows
}

$report = [ordered]@{
    method = $(if ($Mode -eq 'oncpu') {
        'user-mode sampling (scripts\cpu-sample.ps1, oncpu): every interval, each thread whose cycle counter advances across a 30 us probe is on a CPU; it is suspended, its stack walked with dbghelp, and counted one tick. est_cpu_s = share of the process''s on-CPU ticks x its measured CPU time.'
    } else {
        'user-mode sampling (scripts\cpu-sample.ps1, cycles): every interval, each thread whose cycle counter moved is suspended and walked; the cycles it spent since the last tick are charged to that stack (biased toward waits). est_cpu_s = share of walked cycles x the process''s measured CPU time.'
    })
    image = $img
    mode = $Mode
    interval_ms = $IntervalMs
    wall_s = [math]::Round($wall, 2)
    processes = @()
}
$total = 0
foreach ($r in @($reps | Sort-Object CpuSeconds -Descending)) {
    $total += $r.Samples
    $w = [double]$r.WalkedCycles
    $threads = @()
    foreach ($t in @($r.Threads.Values | Where-Object { $_.Cycles -gt 0 } | Sort-Object Cycles -Descending)) {
        $share = if ($r.Cycles -gt 0) { $t.Cycles / $r.Cycles } else { 0 }
        $threads += [ordered]@{ tid = $t.Tid; name = $t.Name; pct = [math]::Round(100 * $share, 1); est_cpu_s = [math]::Round($share * $r.CpuSeconds, 2); samples = $t.Samples }
    }
    $report.processes += [ordered]@{
        pid = $r.Pid
        image = $r.Image
        exited = $r.Exited
        seen_s = [math]::Round(($r.LastSeenMs - $r.FirstSeenMs) / 1000, 2)
        cpu_s = [math]::Round($r.CpuSeconds, 2)
        samples = $r.Samples
        walk_failures = $r.WalkFailures
        walked_pct = if ($Mode -eq 'cycles' -and $r.Cycles -gt 0) { [math]::Round(100 * $w / $r.Cycles, 1) } else { $null }
        threads = $threads
        self = Get-TopRows $r.Self $w $r.CpuSeconds $Top
        lines = Get-TopRows $r.Lines $w $r.CpuSeconds $Top
        inclusive = Get-TopRows $r.Inclusive $w $r.CpuSeconds ($Top * 2)
        stacks = Get-TopRows $r.Folded $w $r.CpuSeconds $Top
    }
}

if ($Out) {
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Out), ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
if ($Folded) {
    $sb = New-Object Text.StringBuilder
    foreach ($r in $reps) {
        foreach ($kv in $r.Folded.GetEnumerator()) {
            [void]$sb.Append("pid$($r.Pid);$($kv.Key) $([long]$kv.Value)`n")
        }
    }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Folded), $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}

Write-Host ("cpu-sample: {0} process(es), {1} samples, {2:N1} s wall, interval {3} ms" -f $report.processes.Count, $total, $wall, $IntervalMs)
foreach ($p in $report.processes) {
    Write-Host ''
    Write-Host ("== pid {0} cpu {1} s over {2} s seen, {3} {4} samples{5}" -f $p.pid, $p.cpu_s, $p.seen_s, $p.samples, $Mode, $(if ($p.exited) { ' (exited)' } else { '' }))
    Write-Host '  threads:'
    foreach ($t in @($p.threads | Select-Object -First 6)) { Write-Host ("    {0,5}%  {1,6} s  tid {2} {3}" -f $t.pct, $t.est_cpu_s, $t.tid, $t.name) }
    Write-Host '  self:'
    foreach ($row in $p.self) { Write-Host ("    {0,5}%  {1,6} s  {2}" -f $row.pct, $row.est_cpu_s, $row.name) }
    Write-Host '  inclusive:'
    foreach ($row in @($p.inclusive | Select-Object -First $Top)) { Write-Host ("    {0,5}%  {1,6} s  {2}" -f $row.pct, $row.est_cpu_s, $row.name) }
}
if ($total -eq 0) { Write-Host 'cpu-sample: NO SAMPLES (no matching process ran)'; exit 1 }
exit 0
