# T1861 acceptance: a STASHED pane stays stashed through IN-PLACE local-agent
# recovery, on both of the rebuild's paths.
#
# THE CLAIM. T1838 made the stash survive an app restart (stash-restore.ps1).
# The other way a pane's surface is replaced under a live window is in-place
# recovery (T145): the app re-dials a wedged or dead agent and rebuilds every
# terminal surface on the new connection. Before T1838 that rebuild built each
# fresh pane with `stash_seq = 0`, so an agent restart silently put every
# stashed pane back ON SCREEN. T1838 fixed both halves of the rebuild:
#
#   * the LEAF SWAP (`rebuildTabLeavesInPlace` -> `Window.replaceTabLeaf`),
#     taken when the live tree still has the captured shape: the fresh pane
#     inherits the slot's `stash_seq`;
#   * the ROOT FALLBACK (`rebuildTabRootInPlace`), taken when the tree changed
#     shape while the re-dial blocked: it rebuilds the captured tree and
#     re-applies the captured `stash_index` (`Window.applyRecordedStash`).
#
# Nothing drove either. This script does, on a P | (s1 / Q) tab with s1
# stashed:
#
#   A) setup: three agent-backed panes, s1 stashed, only P and Q on screen
#   B) LEAF SWAP: suspend the agent past the settle window so the app commits
#      to recovery, resume it, and let the rebuild run. Proof the leaf path ran:
#      the rebuild closed all three surfaces and never logged the root
#      fallback. Then s1 is still stashed (+list --json), P and Q are not,
#      exactly two pane HWNDs are visible, and s1 kept its session (pid).
#   C) ROOT FALLBACK: the same wedge, but Q is CLOSED over IPC while the
#      re-dial is blocked on the frozen agent (the agent-recovery-tabs.ps1
#      race, T1048), so the live tree no longer matches the capture. Proof the
#      root path ran: the app logs "replacing the whole root" and then
#      "restored stash in tab=0 stashed=1". Then s1 is still stashed, P is
#      not, and the visible HWND count equals the on-screen leaf count.
#   D) s1 is LIVE after both rebuilds, and +restore brings it back on screen.
#
# -NegativeControl inverts the B claim to "s1 is on screen after the leaf
# swap" - the answer a rebuild that dropped `stash_seq` gives - and MUST fail.
#
# Hermetic: per-run $env:LOCALAPPDATA, per-run agent binary override, a
# private IPC pipe suffix, and it only ever kills ghoztty processes launched
# from this repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stash-recovery.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers. Dot-sourced first: it drops an inherited
# $GHOZTTY_IPC_SOCKET, and a test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else { $script:fail++; Write-Host "  FAIL $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

# Suspend/resume a process - the same native block agent-recovery-tabs.ps1
# uses, under its own type name so the two scripts can share a PowerShell host.
if (-not ('GhozttyStashRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GhozttyStashRecoveryNative {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    const int PROCESS_SUSPEND_RESUME = 0x0800;

    public static int SetSuspended(int pid, bool suspended) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return -1;
        int rc = suspended ? NtSuspendProcess(h) : NtResumeProcess(h);
        CloseHandle(h);
        return rc;
    }
}
'@
}
function Set-AgentSuspended($procId, [bool]$suspended) {
    return [GhozttyStashRecoveryNative]::SetSuspended([int]$procId, $suspended)
}

# ---------------------------------------------------------------- CLI helpers
# One process launch, arguments straight to the exe: the close in section C is
# latency-bound (the re-dial gives up on a frozen agent in seconds).
#
# persistence: n/a - this is a `ghoztty +...` CLI invocation that opens no
# window, so there is no layout for it to restore.
function Run-CliOne($argv, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    $raw = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $raw) { return , @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return , @() }
    return , $out.ToArray()
}
function Get-LeafById($leaves, [string]$id) {
    foreach ($l in $leaves) { if ([string]$l.id -eq $id) { return $l } }
    return $null
}
function Test-LeafStashed($leaf) {
    return ($null -ne $leaf) -and ($leaf.PSObject.Properties.Name -contains 'stashed') -and ($leaf.stashed -eq $true)
}
function Wait-Leaves([scriptblock]$pred, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $ls = Get-Leaves
        if (& $pred $ls) { return $ls }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return (Get-Leaves)
}

function Get-Panes([IntPtr]$top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }

function Get-RunAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
}

# ---------------------------------------------------------------- app log
function Get-AppLogLength { if (Test-Path $appLog) { (Get-Item $appLog).Length } else { 0 } }
function Read-AppLog($fromLen) {
    if (-not (Test-Path $appLog)) { return '' }
    try {
        $fs = [System.IO.File]::Open($appLog, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $fromLen) { return '' }
            [void]$fs.Seek([int64]$fromLen, 'Begin')
            $buf = New-Object byte[] ([int]($fs.Length - $fromLen))
            [void]$fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
function Wait-AppLog($fromLen, $pattern, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-AppLog $fromLen) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}
# The surfaces a rebuild closed: `surface closed` lines between the re-dial and
# the `rebuilt` line (T2865's oracle - the pane-window pool reuses HWNDs, so
# window identity cannot say whether a surface is fresh).
function Get-ClosedInRebuild($tail) {
    $iDial = $tail.IndexOf('in-place recovery: re-dialed')
    $iDone = $tail.IndexOf('in-place recovery: rebuilt')
    if ($iDial -lt 0 -or $iDone -le $iDial) { return -1 }
    return ([regex]::Matches($tail.Substring($iDial, $iDone - $iDial), 'surface closed')).Count
}
function Show-RecoveryLines($tail, $tag) {
    foreach ($ln in ($tail -split "`r?`n")) {
        if ($ln -match 'recovery|surface closed|stash|re-dial|retry') { "    [$tag] log: $ln" }
    }
}

# Suspends the agent until the app commits to in-place recovery. Returns the
# log mark the wait started from, or -1 if recovery never started.
function Enter-Recovery($tag) {
    $mark = Get-AppLogLength
    $agents = Get-RunAgents
    if ($agents.Count -ne 1) {
        Assert $false "$tag exactly one agent belongs to this run (got $($agents.Count))"
        return -1
    }
    $script:agentPid = [int]$agents[0].ProcessId
    Assert ((Set-AgentSuspended $script:agentPid $true) -eq 0) "$tag the agent was suspended"
    # The app's own verdict, never a clock: `reconnecting` costs 3 missed
    # heartbeats 3s apart, and the settle window is 5s on top.
    $rec = Wait-AppLog $mark 'recovering local windows in place' 60
    Assert $rec "$tag the wedge outlasted the settle window and recovery started"
    if (-not $rec) { return -1 }
    return $mark
}

# ================================================================== setup
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$root = Join-Path $env:TEMP "ghoztty-stash-recovery-$PID"
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$appLog = Join-Path $tmp 'app.err'
$script:agentPid = 0

[void](Set-GhozttyTestIsolation -Tag 'stashrecov')

Stop-RepoInstances
Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if (-not (Test-Path $exe)) { Write-TestAssertedNothing -Reason "ghoztty exe not found: $exe" -Label 'stash-recovery' }
    if (-not (Test-Path $agent)) { Write-TestAssertedNothing -Reason "agent exe not found: $agent" -Label 'stash-recovery' }
    Assert-GhozttyPrivateEndpoint -Exe $exe
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim B is inverted to "s1 is on screen after the leaf swap" - this run MUST fail'
    }

    # ============================================================ A: setup
    Say '== A: P | (s1 / Q), every pane on an agent session, s1 stashed'
    # persistence: on (default) - the run has a per-run $env:LOCALAPPDATA, so
    # the launch has no manifest to restore; recovery re-attaches to the
    # sessions this run's agent holds, which is the thing under test.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $appLog -Arguments @('--config-default-files=false')
    $appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' -Label 'stash-recovery'
    }
    $l0 = @(Wait-Leaves { param($ls) $ls.Count -eq 1 } 40)
    if ($l0.Count -ne 1) { Write-TestAssertedNothing -Reason 'the first pane never answered +list' -Label 'stash-recovery' }
    Assert-GhozttyIsolated -Exe $exe

    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 900
    & $exe +split --pane=s1 --direction=down --name=q | Out-Null
    $l0 = @(Wait-Leaves { param($ls) $ls.Count -eq 3 -and @($ls | Where-Object { $_.name -eq 'q' }).Count -eq 1 } 30)
    if ($l0.Count -ne 3) { Write-TestAssertedNothing -Reason "the three panes never came up (got $($l0.Count))" -Label 'stash-recovery' }
    $idS1 = [string](@($l0 | Where-Object { $_.name -eq 's1' })[0].id)
    $idQ = [string](@($l0 | Where-Object { $_.name -eq 'q' })[0].id)
    $idP = [string](@($l0 | Where-Object { [string]$_.id -ne $idS1 -and [string]$_.id -ne $idQ })[0].id)
    Assert ($idP -and $idS1 -and $idQ) "A1 three pane ids (P=$idP s1=$idS1 Q=$idQ)"

    # Agent-backed shells: a non-zero pid on every pane is what lets the pid
    # oracle in B say anything at all.
    $l0 = @(Wait-Leaves { param($ls) @($ls | Where-Object { [int]$_.pid -gt 0 }).Count -eq 3 } 30)
    $pid0 = @{}
    foreach ($l in $l0) { $pid0[[string]$l.id] = [int]$l.pid }
    Assert (@($pid0.Values | Where-Object { $_ -gt 0 } | Sort-Object -Unique).Count -eq 3) `
        "A2 each pane has its own live shell pid ($(@($pid0.Values) -join ','))"

    & $exe +stash --target=s1 | Out-Null
    $ls = @(Wait-Leaves { param($ls) Test-LeafStashed (Get-LeafById $ls $idS1) } 10)
    Assert (Test-LeafStashed (Get-LeafById $ls $idS1)) 'A3 s1 is stashed'
    Start-Sleep -Milliseconds 600
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert ($vis.Count -eq 2) "A4 two pane HWNDs on screen with s1 stashed (got $($vis.Count))"

    # ======================================================== B: leaf swap
    Say '== B: a wedge held past the settle window; the tree keeps its shape, so the LEAF SWAP runs'
    $markB = Enter-Recovery 'B1'
    if ($markB -ge 0) {
        Assert ((Set-AgentSuspended $script:agentPid $false) -eq 0) 'B2 the agent was resumed'
    }
    $rebuiltB = ($markB -ge 0) -and (Wait-AppLog $markB 'in-place recovery: rebuilt' 120)
    Assert $rebuiltB 'B3 the re-dial completed and the rebuild ran'
    $tailB = if ($markB -ge 0) { Read-AppLog $markB } else { '' }
    Assert (-not ($tailB -match 'replacing the whole root')) `
        'B4 the rebuild took the LEAF SWAP path (no root fallback logged)'
    $closedB = Get-ClosedInRebuild $tailB
    Assert ($closedB -eq 3) "B5 the rebuild replaced all three surfaces, the stashed one included (closed inside it: $closedB, want 3)"
    if ($closedB -ne 3 -or -not $rebuiltB) { Show-RecoveryLines $tailB 'B' }

    Start-Sleep -Milliseconds 1200   # one layout pass after the swap
    $lB = @(Wait-Leaves { param($ls) $ls.Count -eq 3 } 30)
    $s1B = Get-LeafById $lB $idS1
    if ($NegativeControl) {
        Assert (-not (Test-LeafStashed $s1B)) 'B6(neg) s1 is on screen after the leaf swap (inverted)'
    } else {
        Assert (Test-LeafStashed $s1B) 'B6 +list --json still marks s1 stashed after the leaf swap'
    }
    Assert ((-not (Test-LeafStashed (Get-LeafById $lB $idP))) -and (-not (Test-LeafStashed (Get-LeafById $lB $idQ)))) `
        'B7 P and Q are still on screen'
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert ($vis.Count -eq 2) "B8 exactly two pane HWNDs are visible - the fresh s1 surface is hidden (got $($vis.Count))"
    Assert ($null -ne $s1B -and [int]$s1B.pid -eq $pid0[$idS1]) `
        "B9 s1 kept its session through the swap (pid $($pid0[$idS1]) -> $(if ($s1B) { $s1B.pid } else { 'gone' }))"

    # ===================================================== C: root fallback
    Say '== C: the same wedge, with Q closed while the re-dial is blocked, so the ROOT FALLBACK runs'
    $markC = Enter-Recovery 'C1'
    $closeRc = $null
    if ($markC -ge 0) {
        # Served by the GUI pump inside the blocked re-dial (T188); the close
        # needs nothing back from the frozen agent, so its RETURNING is proof it
        # landed while the dial was in flight. See agent-recovery-tabs.ps1 C.
        $closeRc = Run-CliOne @('+close', "--target=$idQ") "$tmp\close-q.txt" 20
    }
    Assert ($closeRc -eq 0) "C2 Q's close was served while the agent was still frozen (rc=$closeRc)"
    $rebuiltEarly = ($markC -ge 0) -and ((Read-AppLog $markC) -match 'in-place recovery: rebuilt')
    Assert (-not $rebuiltEarly) 'C3 no rebuild had run yet - the close landed inside the race window'
    if ($markC -ge 0) {
        Assert ((Set-AgentSuspended $script:agentPid $false) -eq 0) 'C4 the agent was resumed'
    }
    $rebuiltC = ($markC -ge 0) -and (Wait-AppLog $markC 'in-place recovery: rebuilt' 120)
    Assert $rebuiltC 'C5 the re-dial completed and the rebuild ran'
    $tailC = if ($markC -ge 0) { Read-AppLog $markC } else { '' }
    # The anti-vacuity gate: an aborted dial re-enters with a FRESH capture that
    # agrees with the live tree, and the leaf swap would run instead.
    $reentered = ($tailC -match 'in-place recovery ABORTED') -or ($tailC -match 'in-place recovery: retry')
    Assert (-not $reentered) 'C6 the rebuild came from the ORIGINAL capture - the re-dial never aborted and re-entered'
    $iRoot = $tailC.IndexOf('replacing the whole root')
    Assert ($iRoot -ge 0) 'C7 the rebuild took the ROOT FALLBACK path (the tree no longer matched its capture)'
    $stashLine = if ($iRoot -ge 0) { [regex]::Match($tailC.Substring($iRoot), 'restored stash in tab=0 stashed=(\d+)') } else { $null }
    Assert ($null -ne $stashLine -and $stashLine.Success -and [int]$stashLine.Groups[1].Value -ge 1) `
        "C8 the root fallback re-applied the captured stash ($(if ($stashLine -and $stashLine.Success) { $stashLine.Value } else { 'no restored-stash line' }))"
    if (-not ($iRoot -ge 0) -or -not $rebuiltC) { Show-RecoveryLines $tailC 'C' }

    Start-Sleep -Milliseconds 1200
    $lC = @(Wait-Leaves { param($ls) $null -ne (Get-LeafById $ls $idS1) -and $null -ne (Get-LeafById $ls $idP) } 30)
    $s1C = Get-LeafById $lC $idS1
    Assert (Test-LeafStashed $s1C) 'C9 +list --json still marks s1 stashed after the root fallback'
    Assert (-not (Test-LeafStashed (Get-LeafById $lC $idP))) 'C10 P is still on screen'
    # The captured tree may bring Q back (its close raced the capture); either
    # way every on-screen leaf has a visible HWND and s1's is not one of them.
    $onScreen = @($lC | Where-Object { -not (Test-LeafStashed $_) }).Count
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert ($onScreen -ge 1 -and $vis.Count -eq $onScreen) `
        "C11 visible pane HWNDs match the on-screen leaves - the stashed s1 stays hidden (visible=$($vis.Count) on-screen=$onScreen of $($lC.Count))"

    # ======================================================= D: still live
    Say '== D: the stashed pane is live after both rebuilds, and +restore brings it back'
    Assert (Test-PaneLive -Exe $exe -Target $idS1 -Tmp $root -Tag 'STASHREC') `
        'D1 the stashed pane s1 is LIVE after both rebuilds'
    & $exe +restore --target=s1 | Out-Null
    $lD = @(Wait-Leaves { param($ls) -not (Test-LeafStashed (Get-LeafById $ls $idS1)) } 10)
    Assert (($null -ne (Get-LeafById $lD $idS1)) -and -not (Test-LeafStashed (Get-LeafById $lD $idS1))) 'D2 +restore brings s1 back on screen'
    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) `
        'D3 the app pid never changed - this was recovery, not a relaunch'

    Complete-TestBody
} catch {
    $script:fail++
    Say "  FAIL script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    # A suspended agent left behind would outlive the script.
    if ($script:agentPid -gt 0) { [void](Set-AgentSuspended $script:agentPid $false) }
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Stop-RepoInstances
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

# ------------------------------------------------- foreground discipline
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783). Red leaves the stamp alone; a
# -NegativeControl run proves the harness discriminates, not the flow, so it
# must not stamp either.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard stash-recovery -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'stash-recovery'
