# T2958 (step 1 of the T2957 performance audit): a repeatable baseline of what
# the Windows port costs - CPU idle and busy, memory and handle growth over a
# pane/tab open-close cycle, GPU memory and engine time, and the agent on its
# own - written as JSON with the METHOD beside every number, so a re-audit is
# a rerun and a diff rather than hand work.
#
# WHERE IT RUNS. Only on the hidden test desktop (test\win32\lib\TestDesktop.ps1),
# never the user's, and only against builds in this repo: zig-out (Debug) and
# zig-out-release (ReleaseFast, built by the command printed when it is
# missing). Every run takes all the isolating knobs (Set-GhozttyTestIsolation
# -ReleaseSandbox: private app pipe, private agent lineage, private
# LOCALAPPDATA) - for the Debug build too, so the agent measured is this run's
# and no other harness's. The installed Ghoztty is never touched.
#
# WHAT IT MEASURES (each phase is one fresh app):
#   idle    1 window, 1 pane at a cmd prompt, 10 s settle, then -IdleSeconds:
#           app CPU (% of one core), context switches/s (the wakeup rate,
#           summed over the app's threads from SystemProcessInformation), and
#           GPU engine utilisation.
#   busy    a pane that `type`s a generated -BusyMB file: wall time, app CPU
#           seconds and % of one core, GPU engine %; then -ResizeSeconds of
#           window resizes, same counters.
#   cycle   private bytes, working set, kernel/GDI/USER handles, threads, GPU
#           dedicated+shared memory and descendant processes: at start, after
#           10 panes over 3 tabs, after closing them all - twice, so the
#           first-cycle one-time costs (atlases, arenas) are separated from
#           what each cycle leaves behind.
#   agent   session persistence on: ghoztty-agent.exe idle CPU and wakeups,
#           private bytes per hosted session, and its handles/threads across
#           -AttachCycles app kill (detach) / relaunch (re-attach) cycles.
#
# A metric the box cannot read is null with a reason, never a guess.
#
# USAGE
#   powershell -NoProfile -File scripts\perf-baseline.ps1                       # both builds -> temp\perf-baseline-<stamp>.json
#   powershell -NoProfile -File scripts\perf-baseline.ps1 -Build Debug -Out x.json
#   powershell -NoProfile -File scripts\perf-baseline.ps1 -Compare a.json,b.json  # repeatability / regression diff
#
# -Compare exits 0 when every metric of b is within the stated tolerance of a,
# 1 otherwise, and prints one row per metric. The tolerances are in
# $script:Tolerance below and are written into every JSON it emits.
param(
    [ValidateSet('Both', 'Debug', 'Release')][string]$Build = 'Both',
    [string]$Out,
    [int]$IdleSeconds = 60,
    [int]$BusyMB = 64,
    [int]$ResizeSeconds = 8,
    [int]$AgentSessions = 4,
    [int]$AttachCycles = 3,
    # all | idle | busy | cycle | agent, comma-separated or as an array
    [string[]]$Phase = @('all'),
    [string[]]$Compare
)

$ErrorActionPreference = 'Stop'
$Phase = @($Phase | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$bad = @($Phase | Where-Object { @('all', 'idle', 'busy', 'cycle', 'agent') -notcontains $_ })
if ($bad.Count) { Write-Host "unknown -Phase: $($bad -join ',')"; exit 2 }
$repo = Split-Path $PSScriptRoot -Parent
$lib = Join-Path $repo 'test\win32\lib'

# Relative tolerance and absolute floor per metric family: b is within when
# |b - a| <= max(abs, rel * |a|). Wide on CPU and GPU engine time (scheduler
# and DWM noise), tight on handle and object counts.
$script:Tolerance = [ordered]@{
    cpu_pct       = @{ rel = 0.50; abs = 0.5;  note = 'percent of one core' }
    wakeups       = @{ rel = 0.35; abs = 20;   note = 'context switches per second' }
    seconds       = @{ rel = 0.30; abs = 0.5;  note = 'wall or CPU seconds' }
    mb            = @{ rel = 0.15; abs = 5;    note = 'megabytes' }
    delta_mb      = @{ rel = 0.50; abs = 15;   note = 'megabytes left behind by an open/close cycle: a difference of two readings, so it carries the noise of both (run1 27.3 vs run2 36.1 MB on 2026-11-14)' }
    gpu_mb        = @{ rel = 0.20; abs = 5;    note = 'GPU megabytes' }
    gpu_pct       = @{ rel = 0.75; abs = 3;    note = 'GPU engine percent' }
    handles       = @{ rel = 0.10; abs = 30;   note = 'kernel handles' }
    objects       = @{ rel = 0.10; abs = 10;   note = 'GDI or USER objects' }
    threads       = @{ rel = 0.15; abs = 3;    note = 'threads' }
    count         = @{ rel = 0.00; abs = 1;    note = 'process or session counts' }
}

# ---------------------------------------------------------------- compare
function Get-MetricFamily([string]$Path) {
    $leaf = ($Path -split '\.')[-1]
    if ($Path -match '\.leak\.' -and $leaf -match '_mb$' -and $leaf -notmatch 'gpu') { return 'delta_mb' }
    switch -regex ($leaf) {
        'gpu.*_mb$' { return 'gpu_mb' }
        'gpu.*pct'  { return 'gpu_pct' }
        'cpu_pct'   { return 'cpu_pct' }
        'wakeups'   { return 'wakeups' }
        '_s$|seconds' { return 'seconds' }
        '_mb$'      { return 'mb' }
        'handles'   { return 'handles' }
        'gdi|user'  { return 'objects' }
        'threads'   { return 'threads' }
        'procs|sessions|attached' { return 'count' }
        default     { return $null }
    }
}

# Flatten every numeric leaf under "builds" into path -> value.
function Get-Leaves([object]$Node, [string]$Prefix, [hashtable]$Acc) {
    if ($null -eq $Node) { return }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -eq 'method' -or $p.Name -eq 'reason') { continue }
            Get-Leaves $p.Value ($(if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name })) $Acc
        }
        return
    }
    if ($Node -is [double] -or $Node -is [int] -or $Node -is [long] -or $Node -is [decimal]) { $Acc[$Prefix] = [double]$Node }
}

if ($Compare) {
    # Under -File a comma list arrives as ONE string.
    $Compare = @($Compare | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Compare.Count -ne 2) { Write-Host 'usage: -Compare <a.json>,<b.json>'; exit 2 }
    $a = Get-Content -Raw $Compare[0] | ConvertFrom-Json
    $b = Get-Content -Raw $Compare[1] | ConvertFrom-Json
    $la = @{}; $lb = @{}
    Get-Leaves $a.builds '' $la
    Get-Leaves $b.builds '' $lb
    $bad = 0; $rows = 0
    foreach ($k in ($la.Keys | Sort-Object)) {
        $fam = Get-MetricFamily $k
        if (-not $fam) { continue }
        if (-not $lb.ContainsKey($k)) { Write-Host ("MISSING  {0}" -f $k); $bad++; continue }
        $t = $script:Tolerance[$fam]
        $va = $la[$k]; $vb = $lb[$k]
        $lim = [math]::Max($t.abs, $t.rel * [math]::Abs($va))
        $ok = [math]::Abs($vb - $va) -le $lim
        $rows++
        if (-not $ok) { $bad++ }
        Write-Host ("{0,-6} {1,-58} {2,12:N2} {3,12:N2}  (+-{4:N2} {5})" -f $(if ($ok) { 'ok' } else { 'OUT' }), $k, $va, $vb, $lim, $fam)
    }
    Write-Host ''
    if ($bad -eq 0) { Write-Host "COMPARE WITHIN TOLERANCE ($rows metrics)"; exit 0 }
    Write-Host "COMPARE OUT OF TOLERANCE: $bad of $rows metrics"
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Out) { $Out = Join-Path $repo "temp\perf-baseline-$stamp.json" }
$Out = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null
$commit = (& git -C $repo rev-parse --short HEAD 2>$null)

# ---------------------------------------------------------------- both
# Each build runs in its own child process: isolation is process-wide env
# (pipe suffix, agent lineage, LOCALAPPDATA), so one process per build is the
# only way the two cannot share anything.
if ($Build -eq 'Both') {
    $parts = [ordered]@{}
    $exit = 0
    foreach ($b in @('Debug', 'Release')) {
        $part = Join-Path $env:TEMP "perf-baseline-$b-$PID.json"
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Build', $b, '-Out', $part,
            '-IdleSeconds', $IdleSeconds, '-BusyMB', $BusyMB, '-ResizeSeconds', $ResizeSeconds,
            '-AgentSessions', $AgentSessions, '-AttachCycles', $AttachCycles, '-Phase', ($Phase -join ','))
        Write-Host "== $b build"
        & powershell @childArgs
        if ($LASTEXITCODE -ne 0) { $exit = 1 }
        if (Test-Path $part) {
            $parts[$b.ToLower()] = (Get-Content -Raw $part | ConvertFrom-Json).builds.($b.ToLower())
            Remove-Item $part -ErrorAction SilentlyContinue
        } else {
            $parts[$b.ToLower()] = [pscustomobject]@{ error = "the $b run wrote no result (exit $LASTEXITCODE)" }
        }
    }
    $doc = [ordered]@{
        schema    = 'ghoztty-perf-baseline/1'
        task      = 'T2958'
        generated = (Get-Date).ToString('o')
        commit    = $commit
        machine   = [ordered]@{
            cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
            cores = [Environment]::ProcessorCount
            ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            gpu   = ((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join '; ')
            os    = (Get-CimInstance Win32_OperatingSystem).Version
        }
        parameters = [ordered]@{ idle_seconds = $IdleSeconds; busy_mb = $BusyMB; resize_seconds = $ResizeSeconds; agent_sessions = $AgentSessions; attach_cycles = $AttachCycles }
        tolerance = $script:Tolerance
        builds    = $parts
    }
    $doc | ConvertTo-Json -Depth 12 | Set-Content -Path $Out -Encoding ascii
    Write-Host ''
    Write-Host "PERF BASELINE written: $Out"
    exit $exit
}

# ---------------------------------------------------------------- one build
. (Join-Path $lib 'CleanSlate.ps1')
. (Join-Path $lib 'Isolation.ps1')
. (Join-Path $lib 'TestDesktop.ps1')
. (Join-Path $lib 'ProcessMemory.ps1')

$isRelease = $Build -eq 'Release'
$exe = Join-Path $repo $(if ($isRelease) { 'zig-out-release\bin\ghoztty.exe' } else { 'zig-out\bin\ghoztty.exe' })
if (-not (Test-Path $exe)) {
    Write-Host "PERF BASELINE: $exe is missing. Build it with:"
    if ($isRelease) { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release' }
    else { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=Debug' }
    exit 2
}
[void](Set-GhozttyTestIsolation -Tag 'perfb' -ReleaseSandbox -Quiet)
$work = Join-Path $env:TEMP "ghoztty-perfb-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

if (-not ('PerfSnap' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PerfSnap {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    // SystemProcessInformation (class 5), x64 layout: the process record is
    // 0x100 bytes (UniqueProcessId at 0x50, NumberOfThreads at 0x04, the
    // kernel/user times at 0x28/0x20), followed by NumberOfThreads
    // SYSTEM_THREAD_INFORMATION records of 0x50 bytes, ContextSwitches at 0x40.
    public static long[] Read(int pid) {
        int len = 4 << 20;
        for (int tries = 0; tries < 6; tries++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(5, buf, len, out ret);
                if ((uint)st == 0xC0000004u) { len *= 2; continue; }
                if (st != 0) return null;
                long p = buf.ToInt64();
                while (true) {
                    int next = Marshal.ReadInt32(new IntPtr(p));
                    long id = Marshal.ReadIntPtr(new IntPtr(p + 0x50)).ToInt64();
                    if (id == pid) {
                        int n = Marshal.ReadInt32(new IntPtr(p + 4));
                        long user = Marshal.ReadInt64(new IntPtr(p + 0x20));
                        long kern = Marshal.ReadInt64(new IntPtr(p + 0x28));
                        long cs = 0;
                        for (int i = 0; i < n; i++) cs += (uint)Marshal.ReadInt32(new IntPtr(p + 0x100 + i * 0x50 + 0x40));
                        return new long[] { user + kern, cs, n };
                    }
                    if (next == 0) return null;
                    p += next;
                }
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return null;
    }
}
'@
}

$cores = [Environment]::ProcessorCount
function Get-Snap([int]$ProcessId) {
    $r = [PerfSnap]::Read($ProcessId)
    if ($null -eq $r) { return $null }
    return [pscustomobject]@{ Cpu100ns = $r[0]; Ctx = $r[1]; Threads = $r[2]; At = [Diagnostics.Stopwatch]::GetTimestamp() }
}
# CPU % of ONE core, CPU seconds and context switches/s between two snaps.
function Get-Rate($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $null }
    $sec = ($B.At - $A.At) / [double][Diagnostics.Stopwatch]::Frequency
    $cpu = ($B.Cpu100ns - $A.Cpu100ns) / 1e7
    return [pscustomobject]@{
        wall_s  = [math]::Round($sec, 2)
        cpu_s   = [math]::Round($cpu, 3)
        cpu_pct = [math]::Round(100.0 * $cpu / $sec, 2)
        wakeups_per_s = [math]::Round(($B.Ctx - $A.Ctx) / $sec, 1)
    }
}

# GPU engine utilisation charged to a pid, sampled once a second in a
# background job so the foreground can drive a workload meanwhile.
function Start-GpuSampler([int]$ProcessId, [int]$Seconds) {
    # One Get-Counter call per sample, so every sample is already emitted when
    # Stop-Job ends a sampler early (a single -MaxSamples call emits nothing
    # until it has them all).
    Start-Job -ArgumentList $ProcessId, $Seconds -ScriptBlock {
        param($procId, $n)
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $set = Get-Counter -Counter "\GPU Engine(pid_${procId}_*)\Utilization Percentage" -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $tot = 0.0
                foreach ($c in $set.CounterSamples) { $tot += $c.CookedValue }
                [pscustomobject]@{ Sum = $tot }
            } catch { [pscustomobject]@{ Error = "$_" } }
        }
    }
}
function Stop-GpuSampler($Job) {
    [void](Wait-Job $Job -Timeout 120)
    $rows = @(Receive-Job $Job -ErrorAction SilentlyContinue)
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    $err = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'Error' })
    $ok = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'Sum' })
    if ($ok.Count -eq 0) {
        $why = if ($err.Count) { $err[0].Error } else { 'no samples' }
        return [pscustomobject]@{ gpu_engine_pct = $null; gpu_engine_peak_pct = $null; reason = "GPU Engine counters unreadable: $why" }
    }
    $avg = ($ok | Measure-Object -Property Sum -Average).Average
    $peak = ($ok | Measure-Object -Property Sum -Maximum).Maximum
    return [pscustomobject]@{ gpu_engine_pct = [math]::Round($avg, 2); gpu_engine_peak_pct = [math]::Round($peak, 2); samples = $ok.Count }
}

# Verbs go through the console twin when there is one: a release ghoztty.exe is
# a GUI-subsystem binary.
$cli = Join-Path (Split-Path $exe -Parent) 'ghoztty.com'
if (-not (Test-Path $cli)) { $cli = $exe }
function Invoke-Verb([string[]]$VerbArgs) {
    $o = @(& $cli @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $o.Trim() }
}
# Every leaf pane in `+list --json` (objects carrying id + pid). Unrolled.
function Get-PaneLeaves {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    $acc = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$acc.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($r.Text | ConvertFrom-Json) } catch { return @() }
    return $acc.ToArray()
}
function Wait-PaneCount([int]$Want, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do { if (@(Get-PaneLeaves).Count -eq $Want) { return $true }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
    return $false
}

function Format-Sample($S) {
    return [ordered]@{
        private_mb  = $S.PrivMB
        working_set_mb = $S.WsMB
        handles     = $S.Handles
        gdi         = $S.Gdi
        user        = $S.User
        threads     = $S.Threads
        gpu_dedicated_mb = $S.GpuDedMB
        gpu_shared_mb    = $S.GpuShMB
        child_procs = $S.Procs
        child_private_mb = $S.ProcMB
    }
}
function Get-FullSample([int]$ProcessId, [string]$Label, [switch]$Settle) {
    $s = if ($Settle) { Wait-Settled $ProcessId $Label } else { Get-Sample $ProcessId $Label }
    $ws = (Get-Process -Id $ProcessId).WorkingSet64
    $s | Add-Member -NotePropertyName WsMB -NotePropertyValue ([math]::Round($ws / 1MB, 1))
    return $s
}

$launchBase = @('--config-default-files=false', '--confirm-close-surface=false', '--undo-timeout=1s')
$script:app = $null
function Start-App([bool]$Persist) {
    $err = Join-Path $work ("app-{0}.err" -f ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $a = $launchBase + @("--session-persistence=$($Persist.ToString().ToLower())")
    $script:app = Start-OnTestDesktop -Exe $exe -StdErr $err -Arguments $a -AllowReleaseBuild:$isRelease
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    if ($top -eq [IntPtr]::Zero) { throw "the app window never appeared (stderr: $err)" }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 20 -Y 20 -Width 1400 -Height 900)
    $deadline = (Get-Date).AddSeconds(20)
    do { if (@(Get-PaneLeaves).Count -ge 1) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ Pid = $script:app.Pid; Top = [IntPtr]$top }
}
function Stop-App { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

$result = [ordered]@{
    exe = $exe
    build = $Build
    version = ((& $cli +version 2>$null | ForEach-Object { "$_" }) -join ' ').Trim()
}
$want = if ($Phase -contains 'all') { @('idle', 'busy', 'cycle', 'agent') } else { $Phase }
$failed = $false

[void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
Start-TestForegroundWatch
[void](New-TestDesktop)
try {
    # ------------------------------------------------------------ idle
    if ($want -contains 'idle') {
        Write-Host "[$Build] idle: 1 window, 1 pane, $IdleSeconds s"
        try {
            $a = Start-App $false
            Start-Sleep -Seconds 10
            $job = Start-GpuSampler $a.Pid ([math]::Min($IdleSeconds, 30))
            $s0 = Get-Snap $a.Pid
            Start-Sleep -Seconds $IdleSeconds
            $s1 = Get-Snap $a.Pid
            $gpu = Stop-GpuSampler $job
            $r = Get-Rate $s0 $s1
            $result.idle = [ordered]@{
                method = "1 window 1400x900, 1 cmd pane at its prompt, persistence off; 10 s settle, then CPU time and summed thread context switches (NtQuerySystemInformation class 5) over $IdleSeconds s; GPU Engine(pid_*) utilisation summed over engines, 1 s samples, first 30 s"
                cpu_pct = $r.cpu_pct
                wakeups_per_s = $r.wakeups_per_s
                threads = $s1.Threads
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.idle.gpu_reason = $gpu.reason }
            $result.idle.memory = Format-Sample (Get-FullSample $a.Pid 'idle')
        } catch { $failed = $true; $result.idle = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ busy
    if ($want -contains 'busy') {
        Write-Host "[$Build] busy: type a $BusyMB MB file, then $ResizeSeconds s of resizes"
        try {
            $big = Join-Path $work 'big.txt'
            if (-not (Test-Path $big)) {
                $line = ('0123456789abcdefghijklmnopqrstuvwxyz' * 3) + "`r`n"
                $chunk = [Text.Encoding]::ASCII.GetBytes(($line * 4096))
                $fs = [IO.File]::Create($big)
                try { while ($fs.Length -lt $BusyMB * 1MB) { $fs.Write($chunk, 0, $chunk.Length) } } finally { $fs.Close() }
            }
            $marker = Join-Path $work 'busy.done'
            Remove-Item $marker -ErrorAction SilentlyContinue
            $a = Start-App $false
            Start-Sleep -Seconds 6
            $anchor = @(Get-PaneLeaves)[0].id
            $job = Start-GpuSampler $a.Pid 120
            $s0 = Get-Snap $a.Pid
            $r = Invoke-Verb @('+split', "--target=$anchor", '--name=perfbusy', '--direction=right', "--command=type `"$big`" & echo done> `"$marker`"")
            if ($r.Code -ne 0) { throw "+split for the busy pane failed: $($r.Text)" }
            $deadline = (Get-Date).AddSeconds(600)
            while (-not (Test-Path $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $s1 = Get-Snap $a.Pid
            Stop-Job $job -ErrorAction SilentlyContinue
            $gpu = Stop-GpuSampler $job
            if (-not (Test-Path $marker)) { throw 'the busy pane never finished its output within 600 s' }
            $rb = Get-Rate $s0 $s1
            $result.busy = [ordered]@{
                method = "+split a cmd pane running ``type`` of a $BusyMB MB file (108-char ASCII lines) then writing a marker; wall time from the split to the marker, app CPU over the same span; GPU Engine(pid_*) summed, 1 s samples"
                output_mb = $BusyMB
                wall_s = $rb.wall_s
                cpu_s = $rb.cpu_s
                cpu_pct = $rb.cpu_pct
                wakeups_per_s = $rb.wakeups_per_s
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.busy.gpu_reason = $gpu.reason }
            Start-Sleep -Seconds 3

            $job = Start-GpuSampler $a.Pid $ResizeSeconds
            $s0 = Get-Snap $a.Pid
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $i = 0
            while ($sw.Elapsed.TotalSeconds -lt $ResizeSeconds) {
                $w = 900 + (($i * 37) % 600); $h = 600 + (($i * 23) % 350)
                [void](Set-TestWindowPos -Window $a.Top -X 20 -Y 20 -Width $w -Height $h)
                Start-Sleep -Milliseconds 50
                $i++
            }
            $s1 = Get-Snap $a.Pid
            $gpu = Stop-GpuSampler $job
            $rr = Get-Rate $s0 $s1
            $result.resize = [ordered]@{
                method = "SetWindowPos to a new size every 50 ms for $ResizeSeconds s (2 panes open, one holding the busy output); app CPU and GPU Engine over the span"
                resizes = $i
                cpu_pct = $rr.cpu_pct
                wakeups_per_s = $rr.wakeups_per_s
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.resize.gpu_reason = $gpu.reason }
        } catch { $failed = $true; $result.busy = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ cycle
    if ($want -contains 'cycle') {
        Write-Host "[$Build] cycle: 10 panes over 3 tabs, closed, twice"
        try {
            $a = Start-App $false
            Start-Sleep -Seconds 5
            $orig = @(Get-PaneLeaves)[0].id
            $start = Get-FullSample $a.Pid 'start' -Settle
            $cycles = @()
            foreach ($c in 1, 2) {
                $made = New-Object System.Collections.ArrayList
                # Two more tabs (ctrl+shift+t on the live pane), then splits so the
                # tabs hold 4 + 3 + 3 panes.
                $tabAnchors = @($orig)
                foreach ($t in 1, 2) {
                    $ids = @(Get-PaneLeaves | ForEach-Object { $_.id })
                    $panes = @(Get-TestChildWindows -Window $a.Top -Class 'GhozttyTerminal' | Where-Object { $_.Visible -and $_.Width -gt 0 })
                    if ($panes.Count -lt 1) { throw 'no visible terminal pane to open a tab from' }
                    $hw = [IntPtr][int64]$panes[0].Hwnd
                    $f = Focus-TestWindow -Window $a.Top -Child $hw
                    $k = Send-TestKeys -Window $a.Top -Target $hw -Modifiers ctrl, shift -Key T
                    if (-not ($f -and $k)) { throw "ctrl+shift+t was not delivered (focus=$f keys=$k)" }
                    $new = $null
                    $deadline = (Get-Date).AddSeconds(20)
                    do { Start-Sleep -Milliseconds 300; $new = @(Get-PaneLeaves | Where-Object { $ids -notcontains $_.id }) | Select-Object -First 1 } while ($null -eq $new -and (Get-Date) -lt $deadline)
                    if ($null -eq $new) { throw 'ctrl+shift+t opened no listed pane' }
                    [void]$made.Add($new.id)
                    $tabAnchors += $new.id
                }
                $plan = @(3, 2, 2)
                for ($ti = 0; $ti -lt 3; $ti++) {
                    $target = $tabAnchors[$ti]
                    for ($j = 0; $j -lt $plan[$ti]; $j++) {
                        $nm = "pb$c$ti$j"
                        $dir = if ($j % 2 -eq 0) { 'right' } else { 'down' }
                        $r = Invoke-Verb @('+split', "--target=$target", "--name=$nm", "--direction=$dir")
                        if ($r.Code -ne 0) { throw "+split $nm failed: $($r.Text)" }
                        [void]$made.Add($nm)
                        $target = $nm
                    }
                }
                if (-not (Wait-PaneCount 10 30)) { throw "expected 10 panes, +list shows $(@(Get-PaneLeaves).Count)" }
                Start-Sleep -Seconds 4
                $open = Get-FullSample $a.Pid "open $c" -Settle
                for ($m = $made.Count - 1; $m -ge 0; $m--) {
                    $r = Invoke-Verb @('+close', "--target=$($made[$m])")
                    if ($r.Code -ne 0) { throw "+close $($made[$m]) failed: $($r.Text)" }
                }
                if (-not (Wait-PaneCount 1 30)) { throw "panes did not close back to 1 ($(@(Get-PaneLeaves).Count) left)" }
                Start-Sleep -Seconds 3
                $closed = Get-FullSample $a.Pid "closed $c" -Settle
                $cycles += [ordered]@{ open = (Format-Sample $open); closed = (Format-Sample $closed) }
            }
            $first = Format-Sample $start
            $result.cycle = [ordered]@{
                method = 'one window, persistence off, cmd panes: settled sample (lib\ProcessMemory.ps1 Get-Sample + working set) at start, with 10 panes open over 3 tabs (ctrl+shift+t x2, then +split 3/2/2), and after +close of every added pane plus the 1 s undo window; the cycle runs twice. GPU memory is the GPU Process Memory counter set summed over adapters.'
                start = $first
                cycle1 = $cycles[0]
                cycle2 = $cycles[1]
                leak = [ordered]@{
                    first_cycle_private_mb = [math]::Round($cycles[0].closed.private_mb - $first.private_mb, 1)
                    second_cycle_private_mb = [math]::Round($cycles[1].closed.private_mb - $cycles[0].closed.private_mb, 1)
                    second_cycle_handles = $cycles[1].closed.handles - $cycles[0].closed.handles
                    second_cycle_gdi = $cycles[1].closed.gdi - $cycles[0].closed.gdi
                    second_cycle_user = $cycles[1].closed.user - $cycles[0].closed.user
                    second_cycle_threads = $cycles[1].closed.threads - $cycles[0].closed.threads
                    second_cycle_gpu_dedicated_mb = $(if ($null -ne $first.gpu_dedicated_mb) { [math]::Round($cycles[1].closed.gpu_dedicated_mb - $cycles[0].closed.gpu_dedicated_mb, 1) } else { $null })
                }
            }
            if ($null -eq $first.gpu_dedicated_mb) { $result.cycle.gpu_reason = 'GPU Process Memory counters unreadable on this box' }
        } catch { $failed = $true; $result.cycle = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ agent
    if ($want -contains 'agent') {
        Write-Host "[$Build] agent: $AgentSessions sessions, $AttachCycles detach/attach cycles"
        try {
            function Get-AgentInfo {
                $r = Invoke-Verb @('+sessions', '--agent', '--json')
                try { return ($r.Text | ConvertFrom-Json) } catch { return $null }
            }
            function Get-SessionRows {
                $r = Invoke-Verb @('+sessions', '--json')
                if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
                try { $j = $r.Text | ConvertFrom-Json } catch { return @() }
                return @($j | ForEach-Object { $_ })
            }
            # A cold sandbox has no agent and the first app gives up on it after
            # ~2 s, so bring one app up purely to start the agent, then measure
            # in apps that find it running.
            [void](Start-App $true)
            $agentPid = $null
            $deadline = (Get-Date).AddSeconds(40)
            do {
                Start-Sleep -Milliseconds 500
                $info = Get-AgentInfo
                if ($info -and $info.agent_pid) { $agentPid = [int]$info.agent_pid }
            } while (-not $agentPid -and (Get-Date) -lt $deadline)
            if (-not $agentPid) { throw 'no agent came up for the sandbox lineage' }
            Stop-App
            Start-Sleep -Seconds 2
            $a = Start-App $true
            Start-Sleep -Seconds 6
            $base = Get-FullSample $agentPid 'agent base' -Settle
            $sessBase = @(Get-SessionRows).Count

            $s0 = Get-Snap $agentPid
            Start-Sleep -Seconds 30
            $s1 = Get-Snap $agentPid
            $idle = Get-Rate $s0 $s1

            $anchor = @(Get-PaneLeaves)[0].id
            $target = $anchor
            for ($n = 1; $n -le $AgentSessions; $n++) {
                $nm = "pbag$n"
                $r = Invoke-Verb @('+split', "--target=$target", "--name=$nm", "--direction=$(if ($n % 2) { 'right' } else { 'down' })")
                if ($r.Code -ne 0) { throw "+split $nm failed: $($r.Text)" }
                $target = $nm
            }
            Start-Sleep -Seconds 6
            $more = Get-FullSample $agentPid 'agent +sessions' -Settle
            $sessMore = @(Get-SessionRows).Count
            $added = $sessMore - $sessBase
            $perSession = if ($added -gt 0) { [math]::Round(($more.PrivMB - $base.PrivMB) / $added, 2) } else { $null }
            $perSessionChild = if ($added -gt 0) { [math]::Round(($more.ProcMB - $base.ProcMB) / $added, 2) } else { $null }

            $att = @()
            for ($c = 1; $c -le $AttachCycles; $c++) {
                Stop-App
                Start-Sleep -Seconds 3
                $det = Get-FullSample $agentPid "detached $c" -Settle
                $detAttached = @(Get-SessionRows | Where-Object { $_.attached }).Count
                $a = Start-App $true
                Start-Sleep -Seconds 8
                $re = Get-FullSample $agentPid "attached $c" -Settle
                $reAttached = @(Get-SessionRows | Where-Object { $_.attached }).Count
                $att += [ordered]@{
                    detached = [ordered]@{ handles = $det.Handles; threads = $det.Threads; private_mb = $det.PrivMB; attached_sessions = $detAttached }
                    attached = [ordered]@{ handles = $re.Handles; threads = $re.Threads; private_mb = $re.PrivMB; attached_sessions = $reAttached }
                }
            }
            $result.agent = [ordered]@{
                method = "persistence on; agent started by a throwaway app, then measured: idle = 30 s CPU and context switches with 1 attached session; per-session = (private bytes, and its ConPTY/shell descendants' private bytes) delta after $AgentSessions +split panes divided by the +sessions --json delta; attach/detach = app killed (sessions stay pinned) then relaunched (restore re-attaches), $AttachCycles times, settled agent sample after each"
                idle_cpu_pct = $idle.cpu_pct
                idle_wakeups_per_s = $idle.wakeups_per_s
                base = Format-Sample $base
                sessions_base = $sessBase
                sessions_after = $sessMore
                per_session_private_mb = $perSession
                per_session_child_private_mb = $perSessionChild
                attach_cycles = $att
                attach_cycle_handle_growth = $(if ($att.Count -ge 2) { $att[-1].attached.handles - $att[0].attached.handles } else { $null })
                attach_cycle_thread_growth = $(if ($att.Count -ge 2) { $att[-1].attached.threads - $att[0].attached.threads } else { $null })
            }
            if ($null -eq $perSession) { $result.agent.per_session_reason = "+sessions --json showed no added sessions ($sessBase -> $sessMore): the panes did not go through the agent" }
        } catch { $failed = $true; $result.agent = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
if ($leaked.Count) { $failed = $true; $result.foreground_leak = "test-desktop pids reached the interactive foreground: $($leaked -join ',')" }

$doc = [ordered]@{
    schema = 'ghoztty-perf-baseline/1'
    task = 'T2958'
    generated = (Get-Date).ToString('o')
    commit = $commit
    tolerance = $script:Tolerance
    builds = [ordered]@{ ($Build.ToLower()) = $result }
}
$doc | ConvertTo-Json -Depth 12 | Set-Content -Path $Out -Encoding ascii
Write-Host "PERF BASELINE ($Build) written: $Out$(if ($failed) { ' - WITH ERRORS, read the error fields' })"
exit $(if ($failed) { 1 } else { 0 })
