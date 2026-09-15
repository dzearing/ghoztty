# T1593 acceptance: the session manager ANSWERS as soon as it is running, even
# when the box is full of holder pipes it does not own.
#
# In the user's terms: when Ghoztty has to start the background process that
# keeps your terminal sessions alive - the first launch after a restart, say -
# it waits two seconds for that process and then gives up. A process that takes
# fifteen or thirty seconds to say its first word is, from where the user sits,
# a process that is not there: the windows come back as plain new shells and the
# work that was running in them is not reattached.
#
# WHAT WENT WRONG (measured 2026-09-15, cdb stack on a live ReleaseFast agent)
#
#   runListenPipe -> holder_adopt.run -> reapOrphans -> shutdownOrphan
#     -> pipe_stream.dialHandle -> KERNELBASE!WaitNamedPipeW
#
# on the MAIN thread, after binding the pipe and before the accept loop existed.
# The orphan sweep probes every holder pipe in the user's namespace that no
# session record claims, and `dialHandle` retried PIPE_BUSY ten times at a
# second each. A BUSY holder pipe is one that already has an owner attached -
# i.e. the one thing that is definitely NOT an orphan - so every second of that
# wait was spent proving something the first attempt had already established,
# serially, before the agent could serve anybody. Three such pipes on the box
# measured 27.4s to first answer; the same build with the dial bounded measured
# 0.03s.
#
# WHAT THIS SCRIPT MEASURES
#
# The condition is manufactured rather than waited for, so this is a real
# measurement in any build mode and on any box: section A stands up busy pipes
# in the agent's own holder namespace, section B starts an isolated agent and
# times how long it takes to answer `+sessions`, section C checks the sweep left
# those pipes alone (busy means owned, and reaping an owned holder would kill a
# session somebody is using).
#
# The threshold is the app's own `spawn_deadline_ms` (src\apprt\win32\
# LocalAgent.zig), because that number is what decides whether the user's
# sessions come back at all - not a round number chosen to be comfortable.
#
# `-NegativeControl` inverts section B's timing assertion, so a run that scores
# this build as SLOW is available on demand.
#
# Hermetic: a per-run $env:LOCALAPPDATA and GHOZTTY_AGENT_INSTANCE, so the agent
# started here binds its own pipe, writes its own port.json and is never the one
# holding the user's live sessions. The fabricated pipes carry a run-unique
# session-id segment and are closed in the `finally`.
#
#   powershell -NoProfile -File test\win32\agent-first-answer.ps1
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$CliExe = 'D:\git\ghoztty\zig-out\bin\ghoztty.com',
    [switch]$NegativeControl
)

# isolation: none - the only verb this script runs is `+sessions`, which dials
# the AGENT pipe named by %LOCALAPPDATA%\ghoztty\local-agent[-debug]-<lineage># port.json and never the app IPC endpoint. LOCALAPPDATA and
# GHOZTTY_AGENT_INSTANCE are both redirected below, so the agent this run talks
# to is the one it started and the user's is unreachable by construction. An app
# pipe suffix would isolate an endpoint this script never dials (T680).

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

$script:passes = 0
$script:failures = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'AGENT-FIRST-ANSWER' `
        -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}
if (-not (Test-Path $CliExe)) {
    Write-TestAssertedNothing -Label 'AGENT-FIRST-ANSWER' `
        -Reason "cli not found: $CliExe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}

# The number the product itself gives an agent to become dialable. Read from the
# source rather than copied, so a change to the app's patience changes what this
# script demands instead of silently drifting away from it.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$deadlineMs = 2000
$laSrc = Join-Path $repo 'src\apprt\win32\LocalAgent.zig'
if (Test-Path $laSrc) {
    $m = [regex]::Match((Get-Content $laSrc -Raw), 'spawn_deadline_ms[^=]*=\s*([0-9_]+)')
    if ($m.Success) { $deadlineMs = [int]($m.Groups[1].Value -replace '_', '') }
}
Say "== the app gives a spawning agent ${deadlineMs}ms to become dialable"

$savedLocalAppData = $env:LOCALAPPDATA
$savedInstance = $env:GHOZTTY_AGENT_INSTANCE
$inst = 't1593' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $env:TEMP "ghoztty-t1593-$inst"
$servers = New-Object System.Collections.ArrayList
$clients = New-Object System.Collections.ArrayList
$agentPid = 0

try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOZTTY_AGENT_INSTANCE = $inst
    # The leaf carries the build mode as well as the lineage, and the CLI is the
    # binary that decides it: the agent is TOLD its --port-file, while `+sessions`
    # derives the path from its own build (a debug CLI looks in
    # `local-agent-debug-<inst>`). Asking the AGENT exe for a mode returns
    # nothing, which silently reads as the release leaf - and that is how the
    # first run of this script measured a perfectly healthy agent as never
    # having answered.
    $stateDir = Get-GhozttyAgentStateDir -Root $root -Exe $CliExe -Instance $inst
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $portFile = Join-Path $stateDir 'port.json'
    $sessFile = Join-Path $stateDir 'sessions.json'
    $agentPipe = '\\.\pipe\ghoztty-agent-' + $inst

    # ========================================================================
    Say '== A: premise - busy holder pipes the agent does not own'
    # ========================================================================
    # The holder namespace is `ghoztty-pty-host[-debug]-<USER>-<session-id>`
    # (src\remote\agent\pty_host.zig defaultPipeName). It carries no lineage
    # suffix, so an agent enumerates every holder on the box regardless of whose
    # it is - which is exactly the state this script needs, and is itself worth
    # knowing (T1594). Both prefixes are fabricated so the script does not have
    # to work out which build mode the agent under test is.
    $user = $env:USERNAME
    if (-not $user) { $user = 'unknown' }
    $made = 0
    foreach ($seg in @('', '-debug')) {
        for ($i = 0; $i -lt 3; $i++) {
            $bare = "ghoztty-pty-host$seg-$user-t1593x$inst`x$i"
            try {
                # maxInstances = 1, then OCCUPY it: with its only instance taken,
                # every further dial sees PIPE_BUSY - a holder that is being
                # served, which is what a live session's holder looks like.
                $s = New-Object System.IO.Pipes.NamedPipeServerStream(
                    $bare, [System.IO.Pipes.PipeDirection]::InOut, 1,
                    [System.IO.Pipes.PipeTransmissionMode]::Byte,
                    [System.IO.Pipes.PipeOptions]::Asynchronous)
                $null = $s.BeginWaitForConnection($null, $null)
                $c = New-Object System.IO.Pipes.NamedPipeClientStream(
                    '.', $bare, [System.IO.Pipes.PipeDirection]::InOut)
                $c.Connect(3000)
                [void]$servers.Add($s)
                [void]$clients.Add($c)
                $made++
            } catch {
                Say "  (could not fabricate $bare : $($_.Exception.Message))"
            }
        }
    }
    Assert 'A1 six busy holder pipes stand in the agent''s namespace' ($made -eq 6)
    if ($made -eq 0) {
        Write-TestAssertedNothing -Label 'AGENT-FIRST-ANSWER' `
            -Reason 'no holder pipe could be fabricated, so nothing about the sweep was measured'
    }

    # ========================================================================
    Say '== B: the agent answers inside the app''s spawn deadline'
    # ========================================================================
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -ArgumentList "--listen-pipe=$agentPipe", "--port-file=$portFile", `
        "--sessions-file=$sessFile", '--headless' `
        -RedirectStandardOutput "$root\agent.out.txt" -RedirectStandardError "$root\agent.err.txt"
    # Cache the handle BEFORE the child can exit, or a refused agent reads back
    # as a running one (the T351 ExitCode trap).
    $null = $p.Handle
    $agentPid = [int]$p.Id
    Say "  agent pid=$agentPid pipe=$agentPipe"

    $answeredMs = -1
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        if ($p.HasExited) { break }
        $outFile = Join-Path $root 'probe.txt'
        # persistence: n/a - this is the CLI asking the AGENT for its roster, not
        # a terminal launch: `+sessions` opens no window and restores nothing.
        $q = Start-Process -FilePath $CliExe -WindowStyle Hidden -PassThru `
            -ArgumentList '+sessions' `
            -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
        $null = $q.Handle
        [void]$q.WaitForExit(30000)
        $text = ''
        foreach ($f in @($outFile, "$outFile.err")) {
            if (Test-Path $f) { $text += (Get-Content $f -Raw) }
        }
        # Judged on the OUTPUT, not the exit code (T351): the answer is the
        # roster, and "No sessions." is an answer.
        if ($text -notmatch 'could not connect to the local agent' -and
            $text -notmatch 'no local agent found' -and
            $text -notmatch 'the agent did not answer') {
            $answeredMs = [int]$sw.Elapsed.TotalMilliseconds
            break
        }
        Start-Sleep -Milliseconds 150
    }

    Assert 'B1 premise: the agent stayed up' (-not $p.HasExited)
    Assert 'B2 the agent answered +sessions at all' ($answeredMs -ge 0)
    Say "  time to first answer: ${answeredMs}ms (deadline ${deadlineMs}ms)"
    $inTime = ($answeredMs -ge 0 -and $answeredMs -le $deadlineMs)
    if ($NegativeControl) {
        Assert 'B3 (negative control) the agent did NOT answer in time' (-not $inTime)
    } else {
        Assert "B3 it answered within the app's own spawn deadline (${answeredMs}ms <= ${deadlineMs}ms)" $inTime
    }

    # ========================================================================
    Say '== C: a BUSY holder pipe is left alone, not reaped'
    # ========================================================================
    # The safety half of the same change. A busy pipe has an owner attached, so
    # it is a live session's holder; a sweep that shut one down would end a
    # session somebody is using. Skipping the wait must not become skipping the
    # interlock: the fabricated pipes' server ends must still be connected.
    $stillUp = 0
    foreach ($c in $clients) { if ($c.IsConnected) { $stillUp++ } }
    Assert "C1 all $made busy holder pipes survived the sweep (got $stillUp)" ($stillUp -eq $made)

    $agentErr = ''
    if (Test-Path "$root\agent.err.txt") { $agentErr = Get-Content "$root\agent.err.txt" -Raw }
    Assert 'C2 the accept loop was never poisoned (no AcceptFailed)' ($agentErr -notmatch 'AcceptFailed')
    if ($agentErr.Trim()) { Say "  agent stderr: $($agentErr.Trim())" }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($agentPid -gt 0) { Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue }
    foreach ($c in $clients) { try { $c.Dispose() } catch {} }
    foreach ($s in $servers) { try { $s.Dispose() } catch {} }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedInstance) { $env:GHOZTTY_AGENT_INSTANCE = $savedInstance }
    else { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-first-answer -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'AGENT-FIRST-ANSWER' -Pass $script:passes -Fail $script:failures
