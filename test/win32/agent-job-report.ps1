# T1975 acceptance: the agent SAYS whether it is inside a kill-on-close job, and
# that answer reaches the app's log.
#
# The defect: T1970's mechanism - an agent spawned into a nested kill-on-close
# job dies with that job and takes every session with it - was invisible in any
# log a user could send. Only the APP probed its job at startup, and the agent
# is DETACHED with no stdio, so nothing it wrote to stderr reached anybody.
# Since T1975 the agent measures its own job once at startup, writes it into
# its info file (`port.json`, an additive `"job":{"inJob":B,"flags":N}`), and
# the app copies it into its log on every connect - at WARN when the job kills
# on close.
#
#   A: an agent the app spawned itself (escaped, the ordinary shape): its
#      port.json carries the job field, the app logged the same pid and the
#      same facts, and there is no warning unless the facts say kill-on-close.
#   B: an agent started INSIDE a kill-on-close job (the T1973 shape, built
#      here by hand): port.json says inJob=true with the kill-on-close bit, and
#      the agent's own stderr names it.
#   C: the app adopts that jailed agent and logs the WARNING naming it.
#   D: negative control - the job's teardown really does kill that agent, so
#      the warning in C described a real hazard and not a cosmetic flag.
#
# Hermetic: its own agent lineage, a private IPC pipe suffix, a per-run
# LOCALAPPDATA, every GUI launch on the background test desktop; it only ever
# kills processes started from the exes under test.
#
#   powershell -NoProfile -File test\win32\agent-job-report.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$KeepRoot
)

# T351: the shared reset/kill helpers. Dot-sourced first: it drops an inherited
# $GHOZTTY_IPC_SOCKET, and a test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T691: this run's own agent lineage, minted before anything starts an agent.
[void](Set-GhozttyTestAgentLineage -Tag 'jobrep')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

foreach ($f in @($Exe, $AgentExe)) {
    if (-not (Test-Path $f)) { Write-Host "FAIL: not found: $f" -ForegroundColor Red; exit 1 }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

function Stop-TestProcs {
    # Our kill, not a crash: mark the live launches so the test desktop's
    # postmortem does not report a deliberate TerminateProcess as CRASHED. One
    # that is ALREADY gone died on its own and stays unmarked, so it still reports.
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) {
        if (Get-Process -Id $r.Pid -ErrorAction SilentlyContinue) { $r.Killed = $true }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 800)
}

$jobSig = @'
using System;
using System.Runtime.InteropServices;
public static class T1975Job {
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit;
    public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job, int cls, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len, IntPtr retLen);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
}
'@
Add-Type -TypeDefinition $jobSig -ErrorAction SilentlyContinue

# A limit block carrying $Flags. Assigned through a copy of the STRUCT, because
# `$info.BasicLimitInformation.LimitFlags = X` writes into a temporary and the
# job is created with no limits at all (T1974).
function New-JobLimits([uint32]$Flags) {
    $info = New-Object T1975Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    $basic = $info.BasicLimitInformation
    $basic.LimitFlags = $Flags
    $info.BasicLimitInformation = $basic
    return $info
}
function Get-JobLimitFlags($job) {
    $q = New-Object T1975Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    $ok = [T1975Job]::QueryInformationJobObject($job, 9, [ref]$q,
        [System.Runtime.InteropServices.Marshal]::SizeOf($q), [IntPtr]::Zero)
    if (-not $ok) { return $null }
    return [uint32]$q.BasicLimitInformation.LimitFlags
}
function Test-InJob($procId, $job) {
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $inJob = $false
        if (-not [T1975Job]::IsProcessInJob($p.Handle, $job, [ref]$inJob)) { return $null }
        return $inJob
    } catch { return $null }
}

# port.json as an object, once it names a live pid; $null on timeout.
function Wait-InfoFile($path, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $path) {
            $obj = $null
            try { $obj = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { }
            if ($null -ne $obj -and $obj.pid -and (Get-Process -Id ([int]$obj.pid) -ErrorAction SilentlyContinue)) {
                return $obj
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# The first log line matching $pattern in $path; '' on timeout.
function Wait-LogLine($path, $pattern, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # Shared read: the writer (the app, or the agent's cmd launcher) still
        # holds the file open, and File.ReadAllText refuses a file opened that way.
        $text = ''
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        } catch { }
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match $pattern) { return $line }
        }
        Start-Sleep -Milliseconds 400
    }
    return ''
}

# What the app should have logged for these facts, as the agent wrote them.
function Get-ExpectedPhrase($job) {
    $in = if ($null -eq $job.inJob) { '?' } elseif ($job.inJob) { 'yes' } else { 'no' }
    $fl = if ($null -eq $job.flags) { '?' } else { '0x{0:X}' -f [uint32]$job.flags }
    return "in_job=$in flags=$fl"
}
function Test-KillsOnClose($job) {
    return ($job.inJob -eq $true -and $null -ne $job.flags -and (([uint32]$job.flags -band 0x2000) -ne 0))
}

$root = Join-Path $env:TEMP "ghoztty-agent-job-report-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'jobrep')
Assert-GhozttyPrivateEndpoint -Exe $Exe

$env:LOCALAPPDATA = $root
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$stateDir = Get-GhozttyAgentStateDir -Root $root -Exe $Exe
$infoPath = Join-Path $stateDir 'port.json'
$warnRx = 'closing that job ends every session'

$job = [IntPtr]::Zero
$td = $null
try {
    Stop-TestProcs
    $td = New-TestDesktop

    # ========================================================================
    Say "== A: an agent the app spawned reports its job, and the app logs it"
    # ========================================================================
    $appLogA = Join-Path $root 'app-a.err.txt'
    # persistence: on (default) - the agent connection is this script's subject.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1975a') -StdErr $appLogA)
    $infoA = Wait-InfoFile $infoPath 40
    Assert "A1 premise: the app spawned an agent that published port.json" ($null -ne $infoA)
    $jobA = if ($null -ne $infoA) { $infoA.job } else { $null }
    Assert "A2 port.json carries the job field (inJob + flags keys)" (
        $null -ne $jobA -and ($jobA.PSObject.Properties.Name -contains 'inJob') -and
        ($jobA.PSObject.Properties.Name -contains 'flags'))
    $lineA = if ($null -ne $infoA) { Wait-LogLine $appLogA "local agent pid $($infoA.pid) job: " 30 } else { '' }
    Assert "A3 the app logged the job line for THAT agent pid" ($lineA -ne '')
    if ($null -ne $jobA -and $lineA) {
        $expA = Get-ExpectedPhrase $jobA
        Assert "A4 the logged facts are the agent's own ($expA)" ($lineA.Contains($expA))
        Assert "A5 the warning appears exactly when the facts say kill-on-close" (
            ($lineA -match $warnRx) -eq (Test-KillsOnClose $jobA))
    } else {
        Assert "A4 the logged facts are the agent's own" $false
        Assert "A5 the warning appears exactly when the facts say kill-on-close" $false
    }
    Say "     agent A: $lineA"
    Stop-TestProcs
    Remove-Item -LiteralPath $infoPath -Force -ErrorAction SilentlyContinue

    # ========================================================================
    Say "== B: an agent started inside a kill-on-close job reports it"
    # ========================================================================
    $job = [T1975Job]::CreateJobObject([IntPtr]::Zero, $null)
    # KILL_ON_JOB_CLOSE alone: no BREAKAWAY_OK, so nothing started inside it can
    # step out - the agent is in it for life, which is the T1973 outcome.
    $jobInfo = New-JobLimits 0x2000
    $jobSet = [T1975Job]::SetInformationJobObject($job, 9, [ref]$jobInfo,
        [System.Runtime.InteropServices.Marshal]::SizeOf($jobInfo))
    $held = Get-JobLimitFlags $job
    Assert "B0 premise: the job really holds KILL_ON_JOB_CLOSE (held: $(if ($null -eq $held) { '?' } else { '0x{0:X}' -f $held }))" (
        $jobSet -and $null -ne $held -and ($held -band 0x2000) -ne 0)

    # The agent is started by a cmd.exe that is jailed BEFORE it launches the
    # agent (the ping is the window), so the agent is born inside the job and
    # its one startup measurement sees it. Same command line the app uses
    # (LocalAgent.agentCommandLine), with the app's pipe derivation.
    $pipeName = "\\.\pipe\ghoztty-agent-debug-$($env:GHOZTTY_AGENT_INSTANCE)-$($env:USERNAME -replace '[\\/]', '_')"
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $agentErr = Join-Path $root 'agent-b.err.txt'
    $inner = "ping -n 3 127.0.0.1 >nul & `"$AgentExe`" `"--listen-pipe=$pipeName`" `"--port-file=$stateDir\port.json`" `"--sessions-file=$stateDir\sessions.json`" 2>`"$agentErr`""
    $launcher = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$inner`"") -PassThru -WindowStyle Hidden
    $launcherJailed = $false
    try {
        [T1975Job]::AssignProcessToJobObject($job, $launcher.Handle) | Out-Null
        [T1975Job]::IsProcessInJob($launcher.Handle, $job, [ref]$launcherJailed) | Out-Null
    } catch { }
    Assert "B1 premise: the launcher was jailed before it started the agent" $launcherJailed

    $infoB = Wait-InfoFile $infoPath 40
    $agentPidB = if ($null -ne $infoB) { [int]$infoB.pid } else { 0 }
    Assert "B2 premise: the jailed agent published port.json" ($agentPidB -ne 0)
    Assert "B3 premise: that agent really is a member of the job" ((Test-InJob $agentPidB $job) -eq $true)
    $jobB = if ($null -ne $infoB) { $infoB.job } else { $null }
    Assert "B4 port.json says inJob=true with the kill-on-close bit" (
        $null -ne $jobB -and (Test-KillsOnClose $jobB))
    $errLine = Wait-LogLine $agentErr 'agent job: ' 10
    Assert "B5 the agent's own log names the hazard at warn level" (
        $errLine.Contains('in_job=yes flags=0x2000 kill_on_close') -and ($errLine -match $warnRx))
    Say "     agent B: $errLine"

    # ========================================================================
    Say "== C: the app adopts that agent and logs the warning"
    # ========================================================================
    $appLogC = Join-Path $root 'app-c.err.txt'
    # persistence: on (default) - the app must adopt the jailed agent to log it.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1975c') -StdErr $appLogC)
    $lineC = if ($agentPidB -ne 0) { Wait-LogLine $appLogC "local agent pid $agentPidB job: " 40 } else { '' }
    Assert "C1 the app logged the job line for the jailed agent's pid" ($lineC -ne '')
    Assert "C2 ... with the facts the agent measured" ($lineC.Contains('in_job=yes flags=0x2000 kill_on_close'))
    Assert "C3 ... at WARN, naming what is at stake" ($lineC -match $warnRx -and $lineC -match '\bwarn')
    Say "     app C:   $lineC"

    # ========================================================================
    Say "== D: control - the job's teardown really does kill that agent"
    # ========================================================================
    Assert "D1 premise: the jailed agent is alive before the teardown" (
        $agentPidB -ne 0 -and $null -ne (Get-Process -Id $agentPidB -ErrorAction SilentlyContinue))
    [T1975Job]::TerminateJobObject($job, 1) | Out-Null
    [T1975Job]::CloseHandle($job) | Out-Null
    $job = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $agentPidB -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 300
    }
    Assert "D2 the job teardown killed the agent the warning was about" (
        $null -eq (Get-Process -Id $agentPidB -ErrorAction SilentlyContinue))
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($job -ne [IntPtr]::Zero) {
        [T1975Job]::TerminateJobObject($job, 1) | Out-Null
        [T1975Job]::CloseHandle($job) | Out-Null
    }
    Stop-TestProcs
    if ($td) { try { Remove-TestDesktop | Out-Null } catch { } }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    # A red run keeps its evidence (every oracle here reads a log file).
    if ($KeepRoot -or $script:failures -ne 0) { Say "  evidence kept: $root" }
    else { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Say ""
if ($script:failures -eq 0) {
    # A green run stamps the covered files (T783); red stays due.
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-job-report -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:passes -Fail $script:failures
