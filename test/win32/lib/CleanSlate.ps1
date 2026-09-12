# CleanSlate.ps1 - put the box back to a KNOWN-EMPTY state before a fixture
# is built (T248). Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
#     Reset-GhozttyTestState -Exe $Exe
#
# WHY THIS EXISTS
#
# `+new-window --target=<name>` is idempotent BY DESIGN: an existing target is
# FOCUSED, not recreated. Session persistence is on by default and the agent
# outlives the app, so a pane an acceptance script created in a PREVIOUS run
# can still be alive - and killing ghoztty.exe does not remove it, because
# two independent mechanisms bring it back:
#
#   1. the agent still owns the PTY,
#   2. %LOCALAPPDATA%\ghoztty\session-layout-debug.json still describes the
#      window, so the next launch RESTORES it - name and all, and
#   3. since T194, so does the agent's own layout-blob store
#      (local-agent-debug\layouts.json), which launch-time restore now consults
#      even when the manifest says nothing. Deleting the manifest alone stopped
#      being a clean slate that day.
#
# From the second run onward, `+new-window --target=X -e <fixture>` then does
# not run the fixture at all. It focuses last run's pane, complete with last
# run's painted screen, and a `+read` or screen-pixel oracle measures the
# PREVIOUS build and passes. Observed for real while building
# test\win32\color-contrast.ps1 (T150); caught only because two bands returned
# an identical, suspicious value.
#
# So a reset has to cut BOTH paths, which is what Reset-GhozttyTestState does.
# A script that must keep persistence ON (the session-* family) still wants
# this: it builds its own state, and last run's is never part of it.
#
# THE THIRD PART OF THE FIX IS PER-SCRIPT: make any fixture handshake file
# run-unique (embed $PID in the name), so a leftover file from a previous run
# can never be mistaken for this run's fixture reporting in.
#
# SAFETY
#
# Every kill here is filtered on the EXACT ExecutablePath of the exe under
# test and its sibling agent - never a '*zig-out*' CommandLine match, which
# also catches a detached instance running from zig-out-release (T53b), and
# never a match on process NAME alone, which would take the user's installed
# release and its live sessions with it. The manifest delete only ever touches
# the *-debug* file: a ReleaseFast build shares session-layout.json with the
# user's installed Ghoztty, and that file is the user's, not ours.

Set-StrictMode -Off

# T118: a script aims by ENDPOINT, and it inherits the environment of the pane
# it was started from - which, once the installed release bakes its own IPC
# endpoint into every pane, means $GHOZTTY_IPC_SOCKET names the USER'S app.
# The CLI prefers that over the derivation, so leaving it set would point this
# whole suite at the user's terminal. An explicit GHOZTTY_PIPE_SUFFIX already
# outranks it in the CLI, but 32 of the 96 scripts here set no suffix, so drop
# it at the source: a test never wants to inherit an endpoint.
Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue

# T350: the build-mode gate. `Assert-GhozttyUnderTest` below only catches a
# FOREIGN app that is already answering; on a cold box nothing answers and the
# script goes on to auto-launch a release build onto the user's own endpoints.
# `Assert-GhozttyIsolatedBuild` reads the exe itself, so it speaks first.
. (Join-Path $PSScriptRoot 'BuildMode.ps1')

# T1168: the clean slate now includes the REGISTRY. A run that is killed
# mid-way - taskkill, a bluescreen, Ctrl-Break - never reaches its own exit
# handler, and a leaked `HKCU\...\Run\GhozttyAgent-<instance>` value survives
# every reboot afterwards, launching an agent for a sandbox that is long gone.
# A crash is exactly when this leaks, so the next run's reset is the backstop.
. (Join-Path $PSScriptRoot 'HarnessLeak.ps1')

# T691: and the lineage helpers, which are what let the kills below be scoped
# to the agents THIS run owns instead of every agent running out of the repo.
# A script opts in by minting a lineage (Set-GhozttyTestAgentLineage) and
# passing -ScopeToLineage; an unconverted script is untouched by loading this.
. (Join-Path $PSScriptRoot 'AgentLineage.ps1')

# Repo root, derived from this file's location (test\win32\lib -> repo).
$script:CleanSlateRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

function Get-GhozttyAgentPath {
    <#
    .SYNOPSIS
    The agent that belongs to $Exe: its required sibling (docs/claude/build.md).
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)
    Join-Path (Split-Path -Parent $Exe) 'ghoztty-agent.exe'
}

function Test-UnderRepo {
    param([string]$Path)
    if (-not $Path) { return $false }
    return $Path.StartsWith($script:CleanSlateRepo, [StringComparison]::OrdinalIgnoreCase)
}

# The one process query the kill below runs, behind a seam (T688). A scriptblock
# rather than a plain function because the acceptance has to drive the poll
# through states a real box cannot be held in - a survivor that outlasts the old
# blind sleep, and one that never leaves - and shadowing `Stop-RepoGhoztty`
# itself to get there is the exact shape `cleanslate-audit.ps1` exists to refuse.
# Override it, call, restore; `Get-RepoGhozttyProcess` is the only caller.
$script:CleanSlateProcQuery = {
    param([string[]]$Paths)
    $found = @()
    foreach ($path in $Paths) {
        $leaf = Split-Path -Leaf $path
        $found += @(Get-CimInstance Win32_Process -Filter "Name='$leaf'" |
            Where-Object { $_.ExecutablePath -eq $path })
    }
    return $found
}

function Get-RepoGhozttyProcess {
    <#
    .SYNOPSIS
    The live processes whose ExecutablePath is exactly one of -Paths.

    .DESCRIPTION
    Path-exact enumeration, never a match on process NAME alone - that would
    also see the user's installed release and its live sessions. Returns an
    array (possibly empty) of Win32_Process instances.
    #>
    # The `, @(...)` is load-bearing (PS 5.1): a one-element result unrolls on
    # return and its `.Count` is then $null, which reads as "nothing is running".
    # The wrapper is stripped by the return pipeline, so callers use the result
    # directly - wrapping the CALL in `@()` would re-nest it one level.
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    return , @(& $script:CleanSlateProcQuery $Paths)
}

function Stop-RepoGhoztty {
    <#
    .SYNOPSIS
    Kill the app under test and (unless -AppOnly) its sibling agent, and WAIT
    until they are actually gone.

    .DESCRIPTION
    Path-exact, and refuses outright to touch an exe that does not live under
    the repo - so a mistyped -Exe can never reach the user's install.
    Returns the number of distinct processes stopped.

    -AgentOnly is the mirror of -AppOnly and exists for the scripts whose
    subject is the agent alone (T351: `agent-pipe.ps1` restarts the agent under
    a live app). Passing both is a contradiction, so it throws rather than
    quietly killing nothing.

    T688: this used to kill once, sleep -SettleMs and return, which made the
    slate a hope rather than a fact. When one process outlived the sleep the
    script's own launch found the pipe already owned, forwarded its
    `new-window` and exited - and three seconds later the caller printed
    `SETUP FAIL: GUI died at launch`, which reads as a crash and is not one.
    Every misread cost a triage. So the kill now POLLS until nothing matching
    remains, re-issuing the stop each round (a process that ignored the first
    one, or that was spawned between rounds, is killed again), and THROWS
    naming the surviving pids when -TimeoutMs expires. A box that is not clean
    says so in the setup instead of libelling the app.

    -SettleMs keeps its old meaning - "at least this long since the kill" - and
    is measured from the start of the wait rather than added to it, so the
    ordinary clean-box case costs exactly what it did before.

    T691: -ScopeToLineage narrows the whole thing from "every ghoztty and agent
    running out of this repo" to "the ones THIS run owns" - the agents and
    ConPTY holders whose command line names our GHOZTTY_AGENT_INSTANCE, and the
    app pids the test-desktop helpers recorded launching. That is what lets two
    acceptance scripts run at the same time, and what stops a run killing the
    agent holding somebody's live panes. It REFUSES rather than quietly widening
    when it cannot scope both halves (no lineage minted, or an app killed
    without -AgentOnly by a script that does not launch through the harness):
    a scope that silently falls back to the blunt kill is worse than no scope,
    because the suite would be built on a guarantee it does not have.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$AppOnly,
        [switch]$AgentOnly,
        [switch]$ScopeToLineage,
        [int]$SettleMs = 800,
        [int]$TimeoutMs = 5000,
        [int]$PollMs = 100
    )

    if (-not (Test-UnderRepo $Exe)) {
        throw "Stop-RepoGhoztty refuses '$Exe': not under the repo ($script:CleanSlateRepo). Acceptance scripts never touch an installed Ghoztty."
    }
    if ($AppOnly -and $AgentOnly) {
        throw "Stop-RepoGhoztty: -AppOnly and -AgentOnly are mutually exclusive."
    }

    $targets = @()
    if (-not $AgentOnly) { $targets += $Exe }
    if (-not $AppOnly) { $targets += (Get-GhozttyAgentPath -Exe $Exe) }

    # T691. Resolve the scope BEFORE the first kill round, and refuse here
    # rather than in the loop: a caller that asked for a scoped kill and cannot
    # have one must find out before anything has died.
    $lineage = $null
    $ownPids = $null
    if ($ScopeToLineage) {
        $lineage = Get-GhozttyAgentLineage
        if (-not $lineage) {
            throw ("Stop-RepoGhoztty -ScopeToLineage: no GHOZTTY_AGENT_INSTANCE is set. " +
                "Mint one with Set-GhozttyTestAgentLineage (lib\AgentLineage.ps1) before the first reset.")
        }
        if (-not $AgentOnly) {
            $ownPids = Get-GhozttyHarnessLaunchedPid
            if ($null -eq $ownPids) {
                throw ("Stop-RepoGhoztty -ScopeToLineage: the app half cannot be scoped - this script " +
                    "does not launch through lib\TestDesktop.ps1, so there is no record of which " +
                    "ghoztty.exe is ours. Launch through Start-OnTestDesktop, or pass -AgentOnly.")
            }
        }
    }

    $agentPath = Get-GhozttyAgentPath -Exe $Exe
    $mine = {
        param($proc)
        if (-not $ScopeToLineage) { return $true }
        if ($proc.ExecutablePath -eq $agentPath) {
            # The agent and its holders say which lineage they are in, on their
            # own command line. Nothing else on the box does.
            return (Test-GhozttyAgentLineageOwned -CommandLine $proc.CommandLine -Instance $lineage)
        }
        return ($ownPids -contains [int]$proc.ProcessId)
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $stopped = @{}
    $survivors = @()
    while ($true) {
        # ASSIGN, then filter. `Get-RepoGhozttyProcess` returns `, @(...)` so a
        # one-element result does not unroll into a `.Count` of $null - and that
        # wrapper is stripped by the RETURN pipeline, not by a pipeline the
        # caller starts. Piping the call straight into Where-Object therefore
        # hands the filter ONE object, the whole array, whose `.ProcessId` is
        # null: the scoped kill matched nothing and reported a clean box.
        # (Found by this feature's own -TeethCheck arm, which is the only reason
        # it was not shipped as a scope that silently killed nothing.)
        $all = Get-RepoGhozttyProcess -Paths $targets
        $live = @($all | Where-Object { & $mine $_ })
        if ($live.Count -eq 0) { $survivors = @(); break }

        foreach ($p in $live) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped[[string]$p.ProcessId] = $true
        }

        if ($clock.ElapsedMilliseconds -ge $TimeoutMs) {
            $stillThere = Get-RepoGhozttyProcess -Paths $targets
            $survivors = @($stillThere | Where-Object { & $mine $_ })
            break
        }
        Start-Sleep -Milliseconds $PollMs
    }

    if ($survivors.Count -gt 0) {
        $who = ($survivors | ForEach-Object { "pid $($_.ProcessId) $($_.ExecutablePath)" }) -join '; '
        throw ("Stop-RepoGhoztty: $($survivors.Count) process(es) survived $TimeoutMs ms of stops - $who. " +
            "The box is not clean, so anything measured from here would be measuring them.")
    }

    $remaining = $SettleMs - $clock.ElapsedMilliseconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
    return $stopped.Count
}

function Clear-DebugSessionLayout {
    <#
    .SYNOPSIS
    Delete the DEBUG session-layout manifest so the next launch restores nothing.

    .DESCRIPTION
    Only ever the -debug file. A release build writes session-layout.json,
    which is the same file the user's installed Ghoztty restores from; that one
    is never ours to delete. Returns $true if a file was removed.
    #>
    # The OTHER debug state file - window_placement-debug (T85), which decides
    # a new window's size - is cleared by the launch helper itself
    # (Clear-TestWindowPlacement in lib\TestDesktop.ps1, T267) rather than
    # here, because every GUI script goes through Start-OnTestDesktop while
    # only some dot-source this file. One copy, in the file that launches.
    $local = $env:LOCALAPPDATA
    if (-not $local) { return $false }
    # T691: and only ever THIS lineage's file. The manifest follows
    # GHOZTTY_AGENT_INSTANCE the way the agent's state dir does
    # (src\apprt\win32\session_layout.zig `layoutPath`), so under a lineage the
    # unsuffixed one describes somebody else's windows.
    $inst = Get-GhozttyAgentLineage
    $stem = if ($inst) { "session-layout-debug-$inst" } else { 'session-layout-debug' }
    $path = Join-Path $local (Join-Path 'ghoztty' "$stem.json")
    if (-not (Test-Path $path)) { return $false }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path $path))
}

function Clear-DebugAgentLayouts {
    <#
    .SYNOPSIS
    Delete the DEBUG agent's layout-blob store so the next launch recovers
    nothing from it.

    .DESCRIPTION
    The SECOND restore source, and since T194 it is a live one: launch-time
    restore no longer trusts the manifest alone - it pulls the agent's
    `GET_LAYOUTS` and rebuilds any window the manifest has lost. That is exactly
    what makes a crash-orphaned window come back, and exactly what would make a
    PREVIOUS acceptance run's windows come back into a fixture that asked for a
    known-empty box. Dropping the manifest alone stopped being a clean slate the
    day that landed.

    Only ever the `-debug` agent's store, for the same reason
    `Clear-DebugSessionLayout` only touches the `-debug` manifest: the release
    path belongs to the user's installed Ghoztty. Callers that keep the agent
    ALIVE must not use this - it owns the file and would simply rewrite it.
    Returns $true if a file was removed.
    #>
    $local = $env:LOCALAPPDATA
    if (-not $local) { return $false }
    # T691: under a lineage the store lives in that lineage's state dir, and the
    # unsuffixed one belongs to somebody else - clearing it would be both
    # ineffective for this run and destructive to theirs.
    $path = Join-Path (Get-GhozttyAgentStateDir -Root $local) 'layouts.json'
    if (-not (Test-Path $path)) { return $false }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path $path))
}

function Assert-GhozttyUnderTest {
    <#
    .SYNOPSIS
    Fail loudly unless the running app answering our IPC IS $Exe.

    .DESCRIPTION
    A script aims by ENDPOINT, not by exe path. `-Exe zig-out\bin\ghoztty.exe`
    only picks which CLI binary runs; which app that CLI reaches is decided by
    the pipe name, which is derived from the build mode ('-debug' suffix on a
    Debug build). So a zig-out that holds a RELEASE build - one
    `zig build -Dapp-runtime=win32` without `-Doptimize=Debug` does it - puts
    the whole suite on the same endpoint as the user's INSTALLED Ghoztty. Every
    +new-window then opens a window in the user's terminal, the path-filtered
    kills match nothing, and the assertions measure a binary nobody built.
    Observed for real on 2026-08-02 (T248): `zig-out\bin\ghoztty.exe +list`
    answered `"exe":"...\Programs\Ghoztty\ghoztty.exe"`.

    Call this after the app under test is up. Returns the server's exe path;
    throws when it is a different install. -Quiet returns $null instead of
    throwing when no instance is running at all (nothing to be wrong about).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$Quiet
    )
    $out = Join-Path $env:TEMP "ghoztty-aim-$PID.json"
    # cmd redirection: PowerShell's own `>` on a native command can land 0
    # bytes here (T245).
    cmd /c "`"$Exe`" +list --json > `"$out`" 2>&1" | Out-Null
    $raw = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -Force -ErrorAction SilentlyContinue

    if ($raw -notmatch '"exe":"([^"]+)"') {
        if ($Quiet) { return $null }
        throw "Assert-GhozttyUnderTest: no running instance answered '$Exe +list --json'."
    }
    $serverExe = $matches[1] -replace '\\\\', '\'
    if ($serverExe -ne $Exe) {
        throw @"
Assert-GhozttyUnderTest: WRONG APP. This script is driving
    $serverExe
but was asked to test
    $Exe
Both resolve to the same IPC endpoint, which means zig-out holds a non-Debug
build. Rebuild it the way CLAUDE.md says and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug
"@
    }
    return $serverExe
}

function Reset-GhozttyTestState {
    <#
    .SYNOPSIS
    The whole reset: kill app + agent, drop the debug restore manifest, settle.

    .DESCRIPTION
    Call this before building a fixture, in place of a private
    Stop-DebugGhoztty / Kill-RepoInstances copy. -AppOnly keeps the agent
    alive for scripts whose subject IS the running agent (an upgrade or
    re-attach test); the manifest is cleared either way.

    The agent's layout-blob store is cleared only when the agent is being
    killed with it (T194): with the agent alive that file is its own, and a
    delete would be both ineffective and a lie about the state it is holding.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$AppOnly,
        [switch]$ScopeToLineage,
        [int]$SettleMs = 800,
        [switch]$AllowReleaseBuild
    )
    # Pre-flight ZERO (T350): is this exe even ours to drive? A non-debug build
    # derives the user's app pipe, the user's agent pipe and the user's state
    # files, and every check below is powerless against that - the kills match
    # nothing (different ExecutablePath) and the manifest we clear is not the one
    # in play. Refuse before a single window is opened.
    Assert-GhozttyIsolatedBuild -Exe $Exe -Allow:$AllowReleaseBuild | Out-Null

    # Pre-flight: if an app is already answering the endpoint this $Exe dials
    # and it is a DIFFERENT install, the script is pointed at the user's
    # Ghoztty and every kill below will match nothing while every +new-window
    # opens a window in their terminal. Catch it before the fixture is built,
    # not after the assertions have measured the wrong app.
    Assert-GhozttyUnderTest -Exe $Exe -Quiet | Out-Null

    $killed = Stop-RepoGhoztty -Exe $Exe -AppOnly:$AppOnly -ScopeToLineage:$ScopeToLineage -SettleMs $SettleMs
    $cleared = Clear-DebugSessionLayout
    $layoutsCleared = if ($AppOnly) { $false } else { Clear-DebugAgentLayouts }

    # T1168: sweep autostart entries a KILLED run left behind. Only
    # lineage-suffixed names are candidates, so the user's `GhozttyAgent` and
    # the dev install's `GhozttyAgent-debug` are out of reach by construction -
    # Remove-LeakedAgentRunValue throws rather than touching either.
    $runValuesSwept = 0
    try { $runValuesSwept = [int](Remove-LeakedAgentRunValue) } catch {}

    return [pscustomobject]@{
        Killed          = $killed
        ManifestCleared = $cleared
        LayoutsCleared  = $layoutsCleared
        RunValuesSwept  = $runValuesSwept
    }
}
