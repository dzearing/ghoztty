# T3251 acceptance: the session manager replaces itself after an IN-APP update,
# not only after a scripted delivery.
#
# In the user's terms: Ghoztty updated itself four times in two days and the
# background process that keeps their sessions alive stayed on the build from
# before all of them. The app logged "the agent is replacing itself" every time,
# and it never did.
#
# WHAT WENT WRONG
#
# The in-app updater renames the RUNNING `ghoztty-agent.exe` aside to
# `ghoztty-agent.exe.old-<stamp>` (src\apprt\win32\update_apply.zig
# sidelineName) and msiexec writes the new build at the original name. The
# agent's handoff supervisor (src\remote\agent\handoff.zig) asked "is my image a
# renamed backup?" of `std.fs.selfExePath`, which on Windows reads the PEB's
# ImagePathName - frozen at launch, so a rename made WHILE RUNNING is invisible.
# It also only knew the upgrade script's `.bak` suffix. agent-handoff.ps1 never
# caught either, because it LAUNCHES its agent from `ghoztty-agent.exe.bak`
# rather than renaming a running one, which is not what any real delivery does.
#
# WHAT THIS SCRIPT MEASURES (agent only - no app, no window)
#
#   A. Control: the running agent is renamed to a name that is NOT one of ours
#      (`.old-keep`) and a build is laid down at the canonical name. It must NOT
#      hand off: a rename is evidence only in the shapes deliveries produce.
#   B. The real shape: renamed to `.old-<digits>` while running, new build at the
#      canonical name. Within a bound the original process exits and a successor
#      running the canonical binary is serving the same pipe.
#
# Both copies are the binary under test, so the handoff is FORCED
# (GHOZTTY_AGENT_HANDOFF_FORCE, debug builds only) exactly as agent-handoff.ps1
# does - one tree cannot produce two build stamps. FORCE skips only the stamp
# comparison; the question measured here is whether the agent can SEE the build
# beside it at all, which is what was broken.
#
# `-NegativeControl` inverts B, so a run that scores this build as NOT handing
# off is available on demand.
#
# Hermetic: a per-run $env:LOCALAPPDATA, GHOZTTY_AGENT_INSTANCE and pipe name, a
# per-run COPY of the agent, and only processes whose ExecutablePath is under the
# per-run directory are ever stopped.
#
#   powershell -NoProfile -File test\win32\agent-handoff-rename.ps1
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$CliExe = 'D:\git\ghoztty\zig-out\bin\ghoztty.com',
    [switch]$NegativeControl
)

# isolation: none - the only verb this script runs is `+sessions`, which dials
# the AGENT pipe named by the per-run port.json and never the app IPC endpoint.
# LOCALAPPDATA and GHOZTTY_AGENT_INSTANCE are both redirected below, so the agent
# this run talks to is the one it started and the user's is unreachable by
# construction.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

$script:passes = 0
$script:failures = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'AGENT-HANDOFF-RENAME' `
        -Reason "agent not found: $AgentExe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $CliExe)) {
    Write-TestAssertedNothing -Label 'AGENT-HANDOFF-RENAME' `
        -Reason "cli not found: $CliExe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$savedLocalAppData = $env:LOCALAPPDATA
$savedInstance = Get-GhozttyAgentLineage
$savedForce = $env:GHOZTTY_AGENT_HANDOFF_FORCE
$savedInterval = $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS
$inst = 't3251' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $env:TEMP "ghoztty-t3251-$inst"
$agentDir = Join-Path $root 'agentdir'
$canonical = Join-Path $agentDir 'ghoztty-agent.exe'

# Every agent process (manager or holder) running out of the per-run directory.
# Matched on ExecutablePath, never on a name, so the user's installed agent is
# out of reach of every Stop-Process below.
function Get-RunAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($agentDir, 'OrdinalIgnoreCase') -and
            $_.CommandLine -notmatch '--pty-host' })
}
function Test-Alive([int]$procId) {
    return ($procId -gt 0) -and ($null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue))
}
function Stop-RunAgents {
    # cleanslate-exempt: LIKE, because the images under test are renamed
    # (.old-keep, .old-<stamp>); scoped to ExecutablePath under this run's dir.
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($agentDir, 'OrdinalIgnoreCase') })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
# Does the agent on our pipe answer `+sessions`? Judged on output (T351).
function Test-Answers {
    $outFile = Join-Path $root ("probe-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    # persistence: n/a - `+sessions` asks the AGENT for its roster; it opens no
    # window and restores nothing.
    $q = Start-Process -FilePath $CliExe -WindowStyle Hidden -PassThru `
        -ArgumentList '+sessions' -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
    $null = $q.Handle
    [void]$q.WaitForExit(20000)
    $text = ''
    foreach ($f in @($outFile, "$outFile.err")) { if (Test-Path $f) { $text += (Get-Content $f -Raw) } }
    return ($text -match '\S') -and ($text -notmatch 'could not connect to the local agent') -and
        ($text -notmatch 'no local agent found') -and ($text -notmatch 'the agent did not answer')
}

$agentPid = 0
try {
    New-Item -ItemType Directory -Force $agentDir | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOZTTY_AGENT_INSTANCE = $inst
    $stateDir = Get-GhozttyAgentStateDir -Root $root -Exe $CliExe -Instance $inst
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $portFile = Join-Path $stateDir 'port.json'
    $sessFile = Join-Path $stateDir 'sessions.json'
    $agentPipe = '\\.\pipe\ghoztty-agent-' + $inst

    Copy-Item -LiteralPath $AgentExe -Destination $canonical -Force
    Assert-GhozttyIsolatedAgent -Exe $canonical | Out-Null
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = '1'
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = '500'

    # Launched under the CANONICAL name - the shape of every installed agent.
    $p = Start-Process -FilePath $canonical -PassThru -WindowStyle Hidden `
        -ArgumentList "--listen-pipe=$agentPipe", "--port-file=$portFile", "--sessions-file=$sessFile", '--headless' `
        -RedirectStandardOutput "$root\agent.out.txt" -RedirectStandardError "$root\agent.err.txt"
    $null = $p.Handle
    $agentPid = [int]$p.Id
    # The flag is read once at startup; clear it so nothing else here inherits it.
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = $null

    $up = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { break }
        if (Test-Answers) { $up = $true; break }
        Start-Sleep -Milliseconds 300
    }
    Assert "P1 premise: the agent (pid $agentPid) is up and answering under its canonical name" $up
    if (-not $up) {
        Write-TestVerdict -Label 'AGENT-HANDOFF-RENAME' -Pass $script:passes -Fail $script:failures
    }
    # A few supervisor ticks with nothing beside it: not renamed, nothing to adopt.
    Start-Sleep -Seconds 3
    Assert 'P2 premise: unrenamed, it does not hand off to its own path' (Test-Alive $agentPid)

    # ========================================================================
    Say '== A: control - renamed to a name that is not a delivery''s'
    # ========================================================================
    $keep = Join-Path $agentDir 'ghoztty-agent.exe.old-keep'
    Rename-Item -LiteralPath $canonical -NewName (Split-Path -Leaf $keep)
    Copy-Item -LiteralPath $AgentExe -Destination $canonical -Force
    Start-Sleep -Seconds 6
    $others = @((Get-RunAgents) | Where-Object { [int]$_.ProcessId -ne $agentPid })
    Assert 'A1 the original agent is still serving' ((Test-Alive $agentPid) -and (Test-Answers))
    Assert "A2 no successor was started ($($others.Count) other manager(s))" ($others.Count -eq 0)

    # Put the file back into the shape the in-app updater leaves.
    Remove-Item -LiteralPath $canonical -Force
    $sidelined = Join-Path $agentDir ('ghoztty-agent.exe.old-' + [int][double]::Parse((Get-Date -UFormat %s)))
    Rename-Item -LiteralPath $keep -NewName (Split-Path -Leaf $sidelined)

    # ========================================================================
    Say '== B: the in-app updater''s shape - .old-<stamp> while running'
    # ========================================================================
    Copy-Item -LiteralPath $AgentExe -Destination $canonical -Force
    $successor = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if (-not (Test-Alive $agentPid)) {
            $successor = @((Get-RunAgents) | Where-Object { [int]$_.ProcessId -ne $agentPid }) | Select-Object -First 1
            if ($successor) { break }
        }
        Start-Sleep -Milliseconds 300
    }
    $handedOff = ($null -ne $successor)
    $answers = $handedOff -and (Test-Answers)
    Say ("  successor: " + $(if ($successor) { "pid $($successor.ProcessId) after $([int]$sw.Elapsed.TotalSeconds)s" } else { 'none' }))
    if ($NegativeControl) {
        Assert 'B1 (negative control) the agent did NOT replace itself' (-not $handedOff)
    } else {
        Assert 'B1 the renamed agent exited and a successor took over within 30s' $handedOff
        Assert 'B2 the successor runs the binary at the canonical name' (
            $handedOff -and ([string]$successor.CommandLine -like "*$canonical*"))
        Assert 'B3 the successor answers on the same pipe' $answers
    }

    $agentErr = ''
    if (Test-Path "$root\agent.err.txt") { $agentErr = Get-Content "$root\agent.err.txt" -Raw }
    if ($script:failures -gt 0 -and $agentErr.Trim()) {
        Say '  agent stderr (tail):'
        ($agentErr -split "`n" | Select-Object -Last 15) | ForEach-Object { Say "    $_" }
    }

    Complete-TestBody
} finally {
    Stop-RunAgents
    $env:LOCALAPPDATA = $savedLocalAppData
    Restore-GhozttyAgentLineage -Saved $savedInstance
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = $savedForce
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $savedInterval
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-handoff-rename -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'AGENT-HANDOFF-RENAME' -Pass $script:passes -Fail $script:failures
