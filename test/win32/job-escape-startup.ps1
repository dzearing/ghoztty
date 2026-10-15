# T675 acceptance: the APP escapes a hostile kill-on-close job at startup.
#
# The defect: an app launched from inside a Ghoztty pane is a member of the
# AGENT's process-global PTY job (kill-on-close, no breakaway - the shape
# measured in T268). The destructive agent refresh terminates the agent, the
# agent's death closes that job's last handle, and the teardown kills the app
# mid-refresh - the T229/T421/T426 family of unexplained deaths. The fix: at
# startup the app probes its own job and, finding itself inside a kill-on-close
# job, respawns its command line OUTSIDE it (job_spawn's escape tiers) and
# exits; the escaped twin carries on as the app.
#
# This script reproduces the FIELD SHAPE - the app launched from a process that
# is already inside the hostile job, so the app inherits membership at creation
# (every earlier repro attempt jailed the app after launch, which the startup
# probe cannot see and does not claim to fix):
#
#   A: premise - a kill-on-close job with the field's exact flags (0x2000,
#      breakaway forbidden), a launcher jailed in it, and proof that the
#      launcher's plain children inherit membership (the control).
#   B: the app launched by that jailed launcher detects the job, respawns, and
#      the surviving twin is NOT a member - probed with IsProcessInJob against
#      the exact job handle, plus the jailed process's own log trail.
#   C: the job's teardown (TerminateJobObject - what the agent's death does)
#      kills the jailed control and NOT the escaped twin, which is the outcome
#      the membership probe is a proxy for.
#   D: T901 - on the COMMONEST launch path (`ghoztty` typed in a pane, which
#      reaches the console twin ghoztty.com), the twin now spawns the GUI
#      through those same escape tiers, so the child is born outside the job
#      and A-C's backstop has nothing to do. Measured as both halves at once:
#      the GUI is out of the job AND no re-exec happened.
#   E: T902 - the blind spot A-D cannot reach. A kill-on-close job NESTED
#      behind a limitless one, launched with no pane lineage: both of the old
#      clues miss (measured from the app's own probe line, not assumed), and
#      the app escapes anyway because it opened the agent's job BY NAME and
#      asked IsProcessInJob.
#   F: E's negative control and the lineage-isolation proof - the identical
#      shape with the job named for a DIFFERENT GHOZTTY_AGENT_INSTANCE. The
#      app must not claim membership, and must not escape.
#   G: the agent's half of E - the REAL agent, launched under its own lineage,
#      creates its PTY job under exactly the name the app probes for.
#
# Runs anywhere as of T674: breakaway is forbidden (field shape) and
# GetShellWindow() answers nothing on a background test desktop, but the
# jobless-donor tier escapes without either, so this no longer skips itself
# off the interactive desktop.
#
# Hermetic: a per-run $env:LOCALAPPDATA and a private IPC pipe suffix, and it
# only ever touches ghoztty processes launched from the -Exe under test.
#
#   powershell -NoProfile -File test\win32\job-escape-startup.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-Host "FAIL: exe not found: $Exe" -ForegroundColor Red
    exit 1
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# T1970: the in-session launcher (E-H) starts on a BACKGROUND desktop, so the
# apps it launches - and their escaped twins, which job_spawn places on the
# caller's own desktop - never open a window on the user's.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$agentExe = Join-Path (Split-Path -Parent $Exe) 'ghoztty-agent.exe'

$jobSig = @'
using System;
using System.Runtime.InteropServices;
public static class T675Job {
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
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job, uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
  // T902 section G: open the agent's PTY job BY NAME, the way the app does.
  // Unicode explicitly - this one is compared against a name the app composed.
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name);
}
'@
Add-Type -TypeDefinition $jobSig -ErrorAction SilentlyContinue

# A limit block carrying `$Flags`. NOT `$info.BasicLimitInformation.LimitFlags = X`:
# BasicLimitInformation is a STRUCT, so PowerShell assigns into a temporary copy
# and the job is created with no limits at all. Every "kill-on-close" job this
# script built before T1970 was flagless that way, and passed anyway, because the
# escape fired on pane lineage or the named probe and every teardown here is
# TerminateJobObject, which kills members whatever the flags say.
function New-JobLimits([uint32]$Flags) {
    $info = New-Object T675Job+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    $basic = $info.BasicLimitInformation
    $basic.LimitFlags = $Flags
    $info.BasicLimitInformation = $basic
    return $info
}

# This run USED to skip itself here when GetShellWindow() answered nothing:
# breakaway is forbidden in the field shape this jail reproduces, the escape
# rode the shell-parent hop, and no shell window meant no hop - so a
# background-desktop run measured no part of the escape and was scored as
# ASSERTED NOTHING rather than as a pass.
#
# T674 removed the excuse. The jobless-donor tier finds a parent by enumerating
# the session instead of by asking for a window, so the escape no longer needs
# a desktop and this script no longer needs an environment. The skip is gone on
# purpose: a shell-less desktop is now the environment that exercises the tier
# the shell-less case depends on, which makes it the MOST valuable place to run
# this, not a place to opt out of.

# $true / $false / $null when the process is gone or unopenable.
function Test-InJob($procId, $job) {
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $inJob = $false
        if (-not [T675Job]::IsProcessInJob($p.Handle, $job, [ref]$inJob)) { return $null }
        return $inJob
    } catch { return $null }
}

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $agentExe })
}
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy. It matches the same two exact images the Get-Test* enumerations above
    # do - $Exe and its required sibling agent.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 800)
}

function Wait-File($path, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The app under test still holds its stderr file open.
function Read-AppLog($path) {
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object System.IO.StreamReader($fs)).ReadToEnd() }
        finally { $fs.Close() }
    } catch { '' }
}
function Wait-LogMatch($path, $pattern, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-AppLog $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

$root = Join-Path $env:TEMP "ghoztty-t675-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSocket = $env:GHOZTTY_IPC_SOCKET
$env:GHOZTTY_PIPE_SUFFIX = "-t675-$PID"
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = $root

$goFile = Join-Path $root 'go.marker'
$victimPidFile = Join-Path $root 'victim.pid'
$appPidFile = Join-Path $root 'app.pid'
$errFile = Join-Path $root 'app.err.txt'
$launcherPs1 = Join-Path $root 'launcher.ps1'

$job = [IntPtr]::Zero
$job2 = [IntPtr]::Zero
$jobOuter = [IntPtr]::Zero
$jobNamed = [IntPtr]::Zero
$jobOuter2 = [IntPtr]::Zero
$jobOther = [IntPtr]::Zero
$jobH = [IntPtr]::Zero
$jobHInner = [IntPtr]::Zero
try {
    Stop-TestProcs
    $null = New-TestDesktop

    # ========================================================================
    Say "== A: a jailed launcher whose children inherit the kill-on-close job"
    # ========================================================================
    $job = [T675Job]::CreateJobObject([IntPtr]::Zero, $null)
    # KILL_ON_JOB_CLOSE (0x2000) and NOTHING else: the agent PTY job's exact
    # measured shape (T268) - members die on teardown, breakaway is forbidden,
    # so tier 1 is refused and the escape must ride the shell-parent hop.
    $jobInfo = New-JobLimits 0x2000
    $jobLen = [System.Runtime.InteropServices.Marshal]::SizeOf($jobInfo)
    $jobSet = [T675Job]::SetInformationJobObject($job, 9, [ref]$jobInfo, $jobLen)
    Assert "A0 premise: a kill-on-close job exists (flags 0x2000, no breakaway)" `
        ($job -ne [IntPtr]::Zero -and $jobSet)

    # The launcher waits for the go marker so it can be jailed BEFORE it
    # spawns anything - its children then inherit membership at creation,
    # which is exactly how a pane shell adopts the app in the field.
    #
    # It is created via WMI (Win32_Process.Create - the child belongs to
    # WmiPrvSE, outside every job THIS script sits in) so that after the
    # assignment below it is in EXACTLY ONE job, the jail. Launched plainly it
    # would nest the jail inside whatever job the test runner lives in, and
    # the app's NULL-handle flags query answers for the FIRST job a process
    # joined - the runner's, not the jail - which is a harness artifact the
    # field does not have (a pane shell's only job is the agent's PTY job).
    # WMI also means no environment inheritance, so the launcher sets the
    # hermetic environment itself. It also carries GHOZTTY_PANE_ID, as every
    # real pane shell does - the lineage signal the startup probe trusts when
    # a nested compat job answers the flags query in front of the killer
    # (this box compat-jails GUI launches, so the artifact is reproduced here
    # whether or not the field has it).
    @"
`$env:LOCALAPPDATA = '$root'
`$env:GHOZTTY_PIPE_SUFFIX = '-t675-$PID'
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
`$env:GHOZTTY_PANE_ID = 'T675-ACCEPTANCE-PANE'
Remove-Item env:GHOZTTY_NO_STARTUP_ESCAPE -ErrorAction SilentlyContinue
while (-not (Test-Path '$goFile')) { Start-Sleep -Milliseconds 200 }
`$victim = Start-Process -FilePath cmd.exe -ArgumentList '/c','ping -n 120 127.0.0.1 > nul' -WindowStyle Hidden -PassThru
Set-Content -Path '$victimPidFile' -Value `$victim.Id
`$app = Start-Process -FilePath '$Exe' -ArgumentList '--title=t675' -RedirectStandardError '$errFile' -PassThru
Set-Content -Path '$appPidFile' -Value `$app.Id
"@ | Set-Content -Path $launcherPs1 -Encoding ascii

    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPs1`""
    }
    $launcherPid = if ($created.ReturnValue -eq 0) { [int]$created.ProcessId } else { 0 }
    $launcherJailed = $false
    if ($launcherPid -ne 0) {
        try {
            $launcherProc = Get-Process -Id $launcherPid -ErrorAction Stop
            [T675Job]::AssignProcessToJobObject($job, $launcherProc.Handle) | Out-Null
            [T675Job]::IsProcessInJob($launcherProc.Handle, $job, [ref]$launcherJailed) | Out-Null
        } catch {}
    }
    Assert "A1 premise: the launcher is jailed in the job (and only in it)" $launcherJailed

    New-Item -ItemType File -Path $goFile -Force | Out-Null

    $victimSeen = Wait-File $victimPidFile 20
    $victimPid = if ($victimSeen) { [int](Get-Content $victimPidFile | Select-Object -First 1) } else { 0 }
    Start-Sleep -Milliseconds 300
    Assert "A2 control: a plain child of the jailed launcher inherits membership" `
        ($victimPid -ne 0 -and (Test-InJob $victimPid $job) -eq $true)

    # ========================================================================
    Say "== B: the app launched from inside the job escapes it at startup"
    # ========================================================================
    $appSeen = Wait-File $appPidFile 20
    $origPid = if ($appSeen) { [int](Get-Content $appPidFile | Select-Object -First 1) } else { 0 }
    Assert "B1 premise: the jailed launcher started the app" ($origPid -ne 0)

    Assert "B2 the jailed app DETECTED the kill-on-close job" `
        (Wait-LogMatch $errFile 'startup escape: this process is inside a kill-on-close job' 30)
    Assert "B3 ... and respawned itself outside it, naming the tier" `
        (Wait-LogMatch $errFile 'startup escape: respawned as pid \d+ \((breakaway|shell-parent|jobless-parent)\)' 30)

    $twinPid = 0
    if ((Read-AppLog $errFile) -match 'startup escape: respawned as pid (\d+)') {
        $twinPid = [int]$Matches[1]
    }
    $twinProc = $null
    if ($twinPid -ne 0) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $twinProc = Get-Process -Id $twinPid -ErrorAction SilentlyContinue
            if ($twinProc) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    Assert "B4 the escaped twin is alive and is the exe under test" `
        ($null -ne $twinProc -and $twinProc.Path -eq $Exe)
    Assert "B5 the twin is NOT a member of the hostile job" `
        ((Test-InJob $twinPid $job) -eq $false)

    $origGone = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $origPid -ErrorAction SilentlyContinue)) { $origGone = $true; break }
        Start-Sleep -Milliseconds 300
    }
    Assert "B6 the jailed original exited after handing off" $origGone

    # ========================================================================
    Say "== C: the job's teardown kills its members and not the twin"
    # ========================================================================
    [T675Job]::TerminateJobObject($job, 1) | Out-Null
    [T675Job]::CloseHandle($job) | Out-Null
    $job = [IntPtr]::Zero
    Start-Sleep -Seconds 3

    Assert "C1 the teardown DID kill the jailed control" `
        ($null -eq (Get-Process -Id $victimPid -ErrorAction SilentlyContinue))
    Assert "C2 the escaped app SURVIVED the teardown that used to kill it" `
        ($twinPid -ne 0 -and $null -ne (Get-Process -Id $twinPid -ErrorAction SilentlyContinue))

    # ========================================================================
    Say "== D: ghoztty.com spawns the GUI already escaped, with no second hop (T901)"
    # ========================================================================
    # Sections A-C prove the BACKSTOP: a GUI born inside the job re-execs
    # itself out. That backstop covers every launch path, and on the commonest
    # one - `ghoztty` typed in a pane, which reaches the console twin
    # ghoztty.com - it cost a whole extra process start every time. T901 makes
    # the twin spawn the GUI through the same escape tiers, so the child is
    # born outside the job and the backstop finds nothing to do.
    #
    # What is measured, and why each half is needed: the child must be OUT of
    # the job (the correctness the backstop was there for) AND must not have
    # re-execed (the cost T901 removes). Either one alone is satisfied by the
    # pre-T901 behavior.
    #
    # Its own jail, built after C tore the first one down, and its own launch:
    # the B twin is stopped first so the com-spawned GUI is the sole instance
    # and stays alive to be probed, rather than forwarding to an existing app
    # over the single-instance pipe and exiting mid-measurement.
    Stop-TestProcs

    $comExe = Join-Path (Split-Path -Parent $Exe) 'ghoztty.com'
    Assert "D0 premise: the console twin is built beside the exe under test" `
        (Test-Path $comExe)

    $job2 = [T675Job]::CreateJobObject([IntPtr]::Zero, $null)
    $jobInfo2 = New-JobLimits 0x2000
    $jobSet2 = [T675Job]::SetInformationJobObject($job2, 9, [ref]$jobInfo2, $jobLen)
    Assert "D1 premise: a second kill-on-close job exists (flags 0x2000)" `
        ($job2 -ne [IntPtr]::Zero -and $jobSet2)

    # Same WMI-created, go-marker-gated launcher as section A, for the same
    # reasons (exactly one job; no environment inheritance) - except that what
    # it launches is the COM TWIN, which is what a pane shell running
    # `ghoztty` actually starts.
    $go2File = Join-Path $root 'go2.marker'
    $victim2PidFile = Join-Path $root 'victim2.pid'
    $comErrFile = Join-Path $root 'com.err.txt'
    $launcher2Ps1 = Join-Path $root 'launcher2.ps1'
    @"
`$env:LOCALAPPDATA = '$root'
`$env:GHOZTTY_PIPE_SUFFIX = '-t675-$PID'
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
`$env:GHOZTTY_PANE_ID = 'T901-ACCEPTANCE-PANE'
Remove-Item env:GHOZTTY_NO_STARTUP_ESCAPE -ErrorAction SilentlyContinue
Remove-Item env:GHOZTTY_JOB_ESCAPED -ErrorAction SilentlyContinue
while (-not (Test-Path '$go2File')) { Start-Sleep -Milliseconds 200 }
`$victim = Start-Process -FilePath cmd.exe -ArgumentList '/c','ping -n 120 127.0.0.1 > nul' -WindowStyle Hidden -PassThru
Set-Content -Path '$victim2PidFile' -Value `$victim.Id
`$com = Start-Process -FilePath '$comExe' -ArgumentList '--title=t901' -RedirectStandardError '$comErrFile' -PassThru
`$com.WaitForExit()
"@ | Set-Content -Path $launcher2Ps1 -Encoding ascii

    $created2 = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher2Ps1`""
    }
    $launcher2Pid = if ($created2.ReturnValue -eq 0) { [int]$created2.ProcessId } else { 0 }
    $launcher2Jailed = $false
    if ($launcher2Pid -ne 0) {
        try {
            $launcher2Proc = Get-Process -Id $launcher2Pid -ErrorAction Stop
            [T675Job]::AssignProcessToJobObject($job2, $launcher2Proc.Handle) | Out-Null
            [T675Job]::IsProcessInJob($launcher2Proc.Handle, $job2, [ref]$launcher2Jailed) | Out-Null
        } catch {}
    }
    Assert "D2 premise: the com-twin launcher is jailed in that job" $launcher2Jailed

    New-Item -ItemType File -Path $go2File -Force | Out-Null

    $victim2Seen = Wait-File $victim2PidFile 20
    $victim2Pid = if ($victim2Seen) { [int](Get-Content $victim2PidFile | Select-Object -First 1) } else { 0 }
    Start-Sleep -Milliseconds 300
    Assert "D3 control: a plain child of THAT launcher inherits membership" `
        ($victim2Pid -ne 0 -and (Test-InJob $victim2Pid $job2) -eq $true)

    # The GUI the twin spawned, identified by the title it was launched with -
    # the exe path alone would also match a stray app this run did not start.
    $guiPid = 0
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $cand = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.ExecutablePath -eq $Exe -and $_.CommandLine -match 't901' })
        if ($cand.Count -gt 0) { $guiPid = [int]$cand[0].ProcessId; break }
        Start-Sleep -Milliseconds 400
    }
    Assert "D4 the console twin started a GUI" ($guiPid -ne 0)

    # Correctness, which A-C's backstop also delivers: whatever route it took,
    # the GUI that is RUNNING is out of the job. Measured against the negative
    # control (the twin's escape forced to fail, 2026-09-20) this one stays
    # green - it is D7 below that tells the two routes apart.
    Assert "D5 that GUI is not a member of the hostile job" `
        ($guiPid -ne 0 -and (Test-InJob $guiPid $job2) -eq $false)

    # The twin's own trail. Read from its stderr and not from the shared log
    # sink: the sink is compiled out of Debug builds (main_ghostty's logFn
    # gates the file branch on `mode != .Debug`), and a Debug build is the only
    # thing an acceptance script is allowed to launch - so an oracle reading
    # the sink here would be reading an empty string and passing on it.
    [void](Wait-LogMatch $comErrFile 'respawned the GUI sibling' 20)
    $comErr = Read-AppLog $comErrFile
    Assert "D6 the twin named the tier it escaped through, and the pid it made" `
        ($comErr -match 'respawned the GUI sibling as pid (\d+) \(escape=(breakaway|shell-parent|jobless-parent)\)')
    $spawnedPid = if ($comErr -match 'respawned the GUI sibling as pid (\d+)') { [int]$Matches[1] } else { 0 }

    # The heart of T901, and the half that can only pass after it: BEFORE this
    # change the twin's child was born jailed and re-execed itself, so the
    # surviving GUI was a DIFFERENT process from the one the twin started.
    # Same pid means one process start, not two.
    Assert "D7 ... and the GUI still running IS that process - no second hop" `
        ($spawnedPid -ne 0 -and $spawnedPid -eq $guiPid)

    # The outcome the membership probe is a proxy for, proved the same way C
    # proves it for the backstop path.
    [T675Job]::TerminateJobObject($job2, 1) | Out-Null
    [T675Job]::CloseHandle($job2) | Out-Null
    $job2 = [IntPtr]::Zero
    Start-Sleep -Seconds 3
    Assert "D8 the teardown killed that launcher's control child" `
        ($null -eq (Get-Process -Id $victim2Pid -ErrorAction SilentlyContinue))
    Assert "D9 ... and the com-spawned GUI SURVIVED it" `
        ($guiPid -ne 0 -and $null -ne (Get-Process -Id $guiPid -ErrorAction SilentlyContinue))

    # ========================================================================
    Say "== E: the exact named-job probe escapes where both heuristics miss (T902)"
    # ========================================================================
    # The blind spot A-D cannot reach. Two clues decided the escape before
    # T902: the NULL-handle flags query (which with NESTED jobs answers for the
    # FIRST job this process joined, so a limitless compat job in front of the
    # killer reads 0x0) and $GHOZTTY_PANE_ID lineage (which a launch from
    # ANOTHER terminal does not have). Construct exactly that: an outer job
    # with no limits, the kill-on-close job nested inside it, and a launcher
    # with no pane lineage. Both clues miss.
    #
    # What must still fire is the exact probe: the agent creates its PTY job
    # under a NAME (src\remote\pty_job_name.zig) and the app opens that name
    # and asks IsProcessInJob directly. Here the HARNESS plays the agent - it
    # creates the job under the name the app will compose for this lineage,
    # which is also what proves the two sides derive the same string.
    #
    # E2 below is this section's negative control: the identical shape with
    # one lineage of difference in the name scores the opposite way.
    Stop-TestProcs

    # The lineage half of the name is `build_config.is_debug`, which
    # Test-GhozttyIsolatedBuildMode mirrors - and it takes the MODE, not the
    # exe. Passing -Exe bound nothing, answered $false for a Debug build, and
    # composed `-local` where the app composes `-local-debug`: E then looked
    # perfectly correct and measured a job that did not exist (2026-09-20).
    $buildMode = Get-GhozttyBuildMode -Exe $Exe
    $isDebugBuild = Test-GhozttyIsolatedBuildMode -Mode $buildMode
    $lineage = if ($isDebugBuild) { 'local-debug' } else { 'local' }
    Assert "E-0 premise: the build mode under test is known ($buildMode -> lineage '$lineage')" `
        ($null -ne $buildMode -and $buildMode -ne '')
    $instance = "t902-$PID"
    $jobName = "Local\GhozttyAgentPtyJob-$lineage-$instance"
    # The name E2 uses: a DIFFERENT sandbox lineage, which the app running
    # under $instance must not be able to name, open, or be told it belongs to.
    $otherInstance = "t902x-$PID"
    $otherJobName = "Local\GhozttyAgentPtyJob-$lineage-$otherInstance"

    # Launch a jailed app the same shape A and D do - a go-marker-gated launcher
    # jailed before it spawns anything - with ONE deliberate difference: it is
    # started with Start-Process, not through WMI.
    #
    # A and D use Win32_Process.Create to guarantee the launcher is in exactly
    # one job. That is the wrong tool here, and measurably so: a process created
    # through WMI belongs to WmiPrvSE and lands in SESSION 0, and the agent's
    # PTY job name lives in the `Local\` namespace, which is PER LOGON SESSION.
    # The app then looked for a job in session 0's namespace while this script
    # had created it in session 1's, and the probe answered `null` - not a
    # defect in the probe, an artifact of launching across a session boundary
    # that the field never crosses (the agent is spawned BY the app, in the
    # user's own session). Measured 2026-09-20 while writing this section.
    #
    # Start-Process keeps the launcher in this session, at the cost of it also
    # inheriting whatever job the test runner sits in. That costs nothing here:
    # E wants a nested chain, one more limitless layer in front changes nothing,
    # and E4 MEASURES what the flags query actually answered rather than
    # assuming it - so a runner whose own job is a killer fails loudly instead
    # of quietly turning E into a test of the old heuristic.
    # T1970: -BreakawayProbe also has the jailed launcher start one plain child
    # WITH CREATE_BREAKAWAY_FROM_JOB and record its pid, which is section H's
    # premise control: it shows where an accepted breakaway really lands.
    function Start-JailedApp($tag, $instanceValue, $jobs, [switch]$BreakawayProbe) {
        $goF = Join-Path $root "go-$tag.marker"
        $pidF = Join-Path $root "app-$tag.pid"
        $errF = Join-Path $root "app-$tag.err.txt"
        $ps1 = Join-Path $root "launcher-$tag.ps1"
        $probeF = Join-Path $root "breakaway-$tag.pid"
        $probeBlock = ''
        if ($BreakawayProbe) {
            $probeBlock = @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T1970Spawn {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct SI { public int cb; public string r; public string d; public string t; public int x, y, w, h, cx, cy, fa, fl; public short sw, cr2; public IntPtr r2, i, o, e; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PI { public IntPtr hp, ht; public int pid, tid; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string cwd, ref SI si, out PI pi);
  public static int Breakaway(string cmd) {
    SI si = new SI(); si.cb = Marshal.SizeOf(typeof(SI)); PI pi;
    // CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW
    if (!CreateProcessW(null, new System.Text.StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0x09000000, IntPtr.Zero, null, ref si, out pi)) return -Marshal.GetLastWin32Error();
    return pi.pid;
  }
  [StructLayout(LayoutKind.Sequential)] public struct BL { public long a,b; public uint LimitFlags; public UIntPtr c,d; public uint e; public UIntPtr f; public uint g,h; }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr j, int c, ref BL i, int l, IntPtr r);
  // The immediate job's flags, the way the app's NULL-handle probe reads them.
  public static string Flags() { BL b = new BL(); if (!QueryInformationJobObject(IntPtr.Zero, 2, ref b, Marshal.SizeOf(typeof(BL)), IntPtr.Zero)) return "?"; return "0x" + b.LimitFlags.ToString("X"); }
}
'@
Set-Content -Path '$probeF.flags' -Value ([T1970Spawn]::Flags())
Set-Content -Path '$probeF' -Value ([T1970Spawn]::Breakaway('cmd.exe /c ping -n 120 127.0.0.1'))
"@
        }
        # NO GHOZTTY_PANE_ID: half the blind spot is the absence of lineage.
        @"
`$env:LOCALAPPDATA = '$root'
`$env:GHOZTTY_PIPE_SUFFIX = '-t675-$PID'
`$env:GHOZTTY_AGENT_INSTANCE = '$instanceValue'
Remove-Item env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue
Remove-Item env:GHOZTTY_PANE_ID -ErrorAction SilentlyContinue
Remove-Item env:GHOZTTY_NO_STARTUP_ESCAPE -ErrorAction SilentlyContinue
Remove-Item env:GHOZTTY_JOB_ESCAPED -ErrorAction SilentlyContinue
while (-not (Test-Path '$goF')) { Start-Sleep -Milliseconds 200 }
$probeBlock
`$app = Start-Process -FilePath '$Exe' -ArgumentList '--title=$tag' -RedirectStandardError '$errF' -PassThru
Set-Content -Path '$pidF' -Value `$app.Id
"@ | Set-Content -Path $ps1 -Encoding ascii

        # On the test desktop (T1970): the app this launcher starts inherits
        # its desktop, and so does every escaped twin (job_spawn.ownDesktop).
        $made = $null
        try {
            # A full path: the helper's CreateProcessW does no PATH search.
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $made = Start-OnTestDesktop -Exe $psExe `
                -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $ps1)
        } catch { Say "  launcher failed to start: $_" }
        $lp = if ($made) { [int]$made.Pid } else { 0 }
        # With no jobs to assign (section G), "jailed" means only "the launcher
        # started" - there is nothing to be inside of.
        $jailed = $false
        if ($lp -ne 0) {
            try {
                $lproc = Get-Process -Id $lp -ErrorAction Stop
                # Order is load-bearing: each job assigned to a process already
                # in one nests INSIDE it, and the flags query answers for the
                # innermost (the last one listed).
                foreach ($j in $jobs) {
                    [T675Job]::AssignProcessToJobObject($j, $lproc.Handle) | Out-Null
                }
                $jailed = $true
                foreach ($j in $jobs) {
                    $inIt = $false
                    [T675Job]::IsProcessInJob($lproc.Handle, $j, [ref]$inIt) | Out-Null
                    if (-not $inIt) { $jailed = $false }
                }
            } catch {}
        }
        New-Item -ItemType File -Path $goF -Force | Out-Null
        [void](Wait-File $pidF 25)
        $appPid = if (Test-Path $pidF) { [int](Get-Content $pidF | Select-Object -First 1) } else { 0 }
        $probePid = if (Test-Path $probeF) { [int](Get-Content $probeF | Select-Object -First 1) } else { 0 }
        return [pscustomobject]@{ Jailed = $jailed; AppPid = $appPid; Err = $errF; ProbePid = $probePid }
    }

    # The limitless job. This is the compat job nested INSIDE the killer that
    # makes the flags query answer 0x0: that query reads the IMMEDIATE job
    # (measured for T1970), so the limitless one has to be the inner one.
    $jobOuter = [T675Job]::CreateJobObject([IntPtr]::Zero, $null)
    # The killer, under the AGENT's name for this lineage.
    $jobNamed = [T675Job]::CreateJobObject([IntPtr]::Zero, $jobName)
    $jobInfoE = New-JobLimits 0x2000
    $setE = $false
    if ($jobNamed -ne [IntPtr]::Zero) {
        $setE = [T675Job]::SetInformationJobObject($jobNamed, 9, [ref]$jobInfoE, $jobLen)
    }
    Assert "E0 premise: a limitless outer job and a NAMED kill-on-close job exist" `
        ($jobOuter -ne [IntPtr]::Zero -and $jobNamed -ne [IntPtr]::Zero -and $setE)

    $e = Start-JailedApp 't902' $instance @($jobNamed, $jobOuter)
    Assert "E1 premise: the launcher is inside BOTH jobs (a limitless one nested inside the killer)" `
        $e.Jailed
    Assert "E2 premise: the jailed launcher started the app" ($e.AppPid -ne 0)

    # The app's own breadcrumb, which is where the premise is MEASURED rather
    # than assumed: it records what each signal answered.
    [void](Wait-LogMatch $e.Err 'startup job probe:' 30)
    $eLog = Read-AppLog $e.Err
    $eProbe = if ($eLog -match 'startup job probe: [^\r\n]*') { $Matches[0] } else { '' }
    Say "  probe line: $eProbe"
    Assert "E3 premise: the pane-lineage clue MISSED (no GHOZTTY_PANE_ID on this launch)" `
        ($eProbe -match 'pane_lineage=false')
    Assert "E4 premise: the first-job flags clue MISSED (the limitless job answered, not the killer)" `
        ($eProbe -match 'flags=0x0 ')
    Assert "E5 the exact probe found us in the agent's NAMED job" `
        ($eProbe -match 'agent_job_member=true')
    Assert "E6 ... and the app escaped on that alone, where both heuristics said stay" `
        (Wait-LogMatch $e.Err 'startup escape: respawned as pid \d+ \((breakaway|shell-parent|jobless-parent)\)' 30)

    $eTwinPid = if ((Read-AppLog $e.Err) -match 'startup escape: respawned as pid (\d+)') { [int]$Matches[1] } else { 0 }
    $eTwin = $null
    if ($eTwinPid -ne 0) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $eTwin = Get-Process -Id $eTwinPid -ErrorAction SilentlyContinue
            if ($eTwin) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    Assert "E7 the escaped twin is alive and is NOT a member of the named killer job" `
        ($null -ne $eTwin -and (Test-InJob $eTwinPid $jobNamed) -eq $false)

    [T675Job]::TerminateJobObject($jobNamed, 1) | Out-Null
    [T675Job]::CloseHandle($jobNamed) | Out-Null
    $jobNamed = [IntPtr]::Zero
    Start-Sleep -Seconds 2
    Assert "E8 the teardown that used to kill it left the twin running" `
        ($eTwinPid -ne 0 -and $null -ne (Get-Process -Id $eTwinPid -ErrorAction SilentlyContinue))

    # ========================================================================
    Say "== F: a job named for ANOTHER lineage is not ours, and E can go red (T902)"
    # ========================================================================
    # E's negative control, and the isolation claim in one. Identical shape -
    # limitless outer job, nested kill-on-close job, no pane lineage - with the
    # killer named for a DIFFERENT GHOZTTY_AGENT_INSTANCE than the app runs
    # under. The app must not be able to claim membership of a job belonging to
    # a lineage that is not its own, so the probe answers nothing, both
    # heuristics still miss, and the escape does NOT fire.
    #
    # That is the demonstration that E5/E6 measure something: one lineage of
    # difference in the name flips both of them. It is also the property that
    # keeps a harness agent out of the dev agent's kill domain.
    Stop-TestProcs

    $jobOuter2 = [T675Job]::CreateJobObject([IntPtr]::Zero, $null)
    $jobOther = [T675Job]::CreateJobObject([IntPtr]::Zero, $otherJobName)
    $setF = $false
    if ($jobOther -ne [IntPtr]::Zero) {
        $setF = [T675Job]::SetInformationJobObject($jobOther, 9, [ref]$jobInfoE, $jobLen)
    }
    Assert "F0 premise: a kill-on-close job exists under ANOTHER lineage's name" `
        ($jobOuter2 -ne [IntPtr]::Zero -and $jobOther -ne [IntPtr]::Zero -and $setF)

    $f = Start-JailedApp 't902x' $instance @($jobOther, $jobOuter2)
    Assert "F1 premise: the launcher is inside both of THOSE jobs" $f.Jailed

    [void](Wait-LogMatch $f.Err 'startup job probe:' 30)
    $fLog = Read-AppLog $f.Err
    $fProbe = if ($fLog -match 'startup job probe: [^\r\n]*') { $Matches[0] } else { '' }
    Say "  probe line: $fProbe"
    Assert "F2 the app did NOT claim membership of another lineage's job" `
        ($fProbe -ne '' -and $fProbe -notmatch 'agent_job_member=true')
    Assert "F3 ... so with both heuristics still missing, it did not escape" `
        ($fLog -notmatch 'startup escape: respawned as pid')

    [T675Job]::TerminateJobObject($jobOther, 1) | Out-Null
    [T675Job]::CloseHandle($jobOther) | Out-Null
    $jobOther = [IntPtr]::Zero
    [T675Job]::CloseHandle($jobOuter2) | Out-Null
    $jobOuter2 = [IntPtr]::Zero
    [T675Job]::CloseHandle($jobOuter) | Out-Null
    $jobOuter = [IntPtr]::Zero


    # ========================================================================
    Say "== G: the REAL agent creates its PTY job under that name (T902)"
    # ========================================================================
    # E and F prove the APP's half against a job this script created. The other
    # half is the agent's, and nothing above exercises it: a name only two
    # processes agree on is worth nothing if the process that is supposed to
    # create it never does, or creates it under a different string. So launch
    # the real app under a private lineage - it spawns the agent, the agent
    # spawns the first pane's ConPTY child, and THAT is what creates the job -
    # and then open the name from here.
    #
    # Launched through the same helper E and F use, with NO jobs to be put in:
    # this section has no jail to build, and routing the launch through the
    # helper keeps every app start in this file behind one launcher script
    # rather than adding a bare `Start-Process $Exe` site of its own (which the
    # desktop-launch audit reads, correctly, as a GUI launched straight onto
    # the caller's desktop).
    Stop-TestProcs

    $gInstance = "t902g-$PID"
    $gName = "Local\GhozttyAgentPtyJob-$lineage-$gInstance"
    $g = Start-JailedApp 't902g' $gInstance @()
    Assert "G0 premise: the app started under its own agent lineage '$gInstance'" `
        ($g.AppPid -ne 0)

    $gJob = [IntPtr]::Zero
    $gDeadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $gDeadline) {
        $gJob = [T675Job]::OpenJobObjectW(0x0004, $false, $gName)
        if ($gJob -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert "G1 the agent's PTY job exists under the name the app probes for" `
        ($gJob -ne [IntPtr]::Zero)
    if ($gJob -ne [IntPtr]::Zero) { [void][T675Job]::CloseHandle($gJob) }

    # And the name is LINEAGE-scoped, which is what keeps this run's agent out
    # of the dev agent's kill domain: a neighbouring name must resolve to
    # nothing at all.
    $gOther = [T675Job]::OpenJobObjectW(0x0004, $false, "Local\GhozttyAgentPtyJob-$lineage-$gInstance-x")
    Assert "G2 ... and only under THAT lineage's name, not a neighbouring one" `
        ($gOther -eq [IntPtr]::Zero)
    if ($gOther -ne [IntPtr]::Zero) { [void][T675Job]::CloseHandle($gOther) }

    Stop-TestProcs

    # ========================================================================
    Say "== H: a breakaway that only reaches an OUTER job is not an escape (T1970)"
    # ========================================================================
    # The field shape measured on 2026-10-15, in the user's own log: an app the
    # installer relaunched sat in a breakaway-OK job nested inside a
    # kill-on-close one. The startup escape's breakaway was ACCEPTED - it only
    # needs the innermost job's permission - and with nested jobs that moves the
    # child to the next job OUT. The twin logged `respawned ... (breakaway)` and
    # then `STILL inside a kill-on-close job`, and so would every agent such an
    # app spawned, along with every session that agent held.
    #
    # Built here as: the agent's NAMED kill-on-close job (so the exact probe
    # fires the escape, as in E) with a breakaway-OK job nested inside it.
    # H2 is the control that shows the trap is real on this box: a plain
    # breakaway child of the same launcher lands in the killer.
    Stop-TestProcs

    $hInstance = "t1970-$PID"
    $hName = "Local\GhozttyAgentPtyJob-$lineage-$hInstance"
    $jobH = [T675Job]::CreateJobObject([IntPtr]::Zero, $hName)
    $jobHInner = [T675Job]::CreateJobObject([IntPtr]::Zero, "$hName-inner")
    $infoH = New-JobLimits 0x2000
    $infoHInner = New-JobLimits 0x800
    $setH = ($jobH -ne [IntPtr]::Zero) -and
        [T675Job]::SetInformationJobObject($jobH, 9, [ref]$infoH, $jobLen) -and
        ($jobHInner -ne [IntPtr]::Zero) -and
        [T675Job]::SetInformationJobObject($jobHInner, 9, [ref]$infoHInner, $jobLen)
    Assert "H0 premise: a named kill-on-close job and a breakaway-OK job exist" $setH

    # Outer first, then inner: assigning a process that is already in a job
    # to a second one nests the second inside the first.
    $h = Start-JailedApp 't1970' $hInstance @($jobH, $jobHInner) -BreakawayProbe
    $hFlagsF = Join-Path $root 'breakaway-t1970.pid.flags'
    $hFlags = if (Test-Path $hFlagsF) { (Get-Content $hFlagsF | Select-Object -First 1) } else { '' }
    Assert "H1 premise: the launcher's immediate job is the breakaway-OK one (read: '$hFlags')" `
        ($hFlags -eq '0x800')
    Start-Sleep -Milliseconds 500
    Assert "H2 control: a plain breakaway child of that launcher is STILL in the killer job" `
        ($h.ProbePid -gt 0 -and (Test-InJob $h.ProbePid $jobH) -eq $true)

    Assert "H3 the app escaped, through a parent hop rather than the breakaway" `
        (Wait-LogMatch $h.Err 'startup escape: respawned as pid \d+ \((shell-parent|jobless-parent)\)' 30)
    Assert "H4 ... and its log names the nested-job trap it stepped around" `
        ((Read-AppLog $h.Err) -match 'breakaway only reached an OUTER job')

    $hTwinPid = if ((Read-AppLog $h.Err) -match 'startup escape: respawned as pid (\d+)') { [int]$Matches[1] } else { 0 }
    $hTwin = $null
    if ($hTwinPid -ne 0) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $hTwin = Get-Process -Id $hTwinPid -ErrorAction SilentlyContinue
            if ($hTwin) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    Assert "H5 the twin is alive and is NOT a member of the killer job" `
        ($null -ne $hTwin -and (Test-InJob $hTwinPid $jobH) -eq $false)

    [T675Job]::TerminateJobObject($jobH, 1) | Out-Null
    [T675Job]::CloseHandle($jobH) | Out-Null
    $jobH = [IntPtr]::Zero
    Start-Sleep -Seconds 2
    Assert "H6 the killer's teardown took the breakaway control and left the twin running" `
        ($null -eq (Get-Process -Id $h.ProbePid -ErrorAction SilentlyContinue) -and
         $hTwinPid -ne 0 -and $null -ne (Get-Process -Id $hTwinPid -ErrorAction SilentlyContinue))
    [T675Job]::CloseHandle($jobHInner) | Out-Null
    $jobHInner = [IntPtr]::Zero

    Stop-TestProcs

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($job -ne [IntPtr]::Zero) { [T675Job]::CloseHandle($job) | Out-Null }
    if ($job2 -ne [IntPtr]::Zero) { [T675Job]::CloseHandle($job2) | Out-Null }
    # T902's four handles. A named job outlives its creator as long as ANY
    # handle to it is open, so leaking one here would leave the name taken and
    # the next run's CreateJobObject would OPEN ours instead of making its own.
    foreach ($jh in @($jobOuter, $jobNamed, $jobOuter2, $jobOther, $jobH, $jobHInner)) {
        if ($null -ne $jh -and $jh -ne [IntPtr]::Zero) { [T675Job]::CloseHandle($jh) | Out-Null }
    }
    Stop-TestProcs
    Remove-TestDesktop
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($savedPipe) { $env:GHOZTTY_PIPE_SUFFIX = $savedPipe }
    else { Remove-Item env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    if ($savedSocket) { $env:GHOZTTY_IPC_SOCKET = $savedSocket }
    # A red run KEEPS its evidence (the same lesson as T900): every oracle here
    # reads an app's stderr, and deleting those files on the way out means the
    # next question - what did the app actually print? - can only be answered by
    # re-running and hoping. Green runs still clean up.
    if ($script:failures -eq 0) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "  evidence kept (run was red): $root"
    }
}

Say ""
if ($script:failures -eq 0) {
    # A green run stamps the covered files (T783) so guard-due can answer "has
    # this harness been run against the code as it now stands?". Red leaves
    # the stamp alone (red stays due), and the SKIP path above never gets
    # here (a run that proved nothing must not stamp).
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard job-escape-startup -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:passes -Fail $script:failures
