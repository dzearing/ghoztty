# AgentLineage.ps1 - T691. Give an acceptance run its OWN agent lineage, so it
# stops having to kill the box's.
#
# WHY THIS EXISTS
#
# The local agent takes a per-user, per-lineage single-instance guard, so until
# T167 a second agent could not exist at all: a persistence suite had to kill
# whatever agent was already running before it could have one of its own. Two
# consequences, both of them still live before this file:
#
#   1. A test run is RUDE. The agent it kills is holding real panes - the dev
#      install's, and on this box the go-loop's own.
#   2. Two acceptance scripts can never run at the same time. The suite is 241
#      scripts measured in hours, and it is serial by construction rather than
#      by choice.
#
# T167 built the knob (`GHOZTTY_AGENT_INSTANCE=<suffix>`: guard, lock,
# heartbeat, state dir, pipe, autostart value and `+sessions` all move together)
# and deliberately did not spend it. This file spends it, in three pieces:
#
#   Set-GhozttyTestAgentLineage   mint one, run-unique, with its teardown armed
#   Get-GhozttyAgentStateDir      the state dir that lineage implies, so a
#                                 script stops hardcoding `local-agent-debug`
#   Test-GhozttyAgentLineageOwned does this command line belong to that lineage
#
# The third is what lets `Stop-RepoGhoztty` (lib\CleanSlate.ps1) narrow from
# "every agent running out of the repo" to "the agents of MY lineage".
#
# WHAT MAKES A PROCESS ATTRIBUTABLE
#
# Win32_Process does not expose a process's environment, so the lineage cannot
# be read back off the agent that was spawned with it. What it does expose is
# the COMMAND LINE, and both processes a lineage owns spell their lineage there:
#
#   agent    `--port-file=<...>\local-agent-debug-<inst>\port.json`  (LocalAgent.zig)
#   holder   `--pty-host --spec <%TEMP%>\ghoztty-ptyhost-<inst>-<sid>.json`  (T691)
#
# The holder half is why T691 touched product code at all: a holder is spawned
# OUT of the agent's kill-on-close job and, on the second tier of that escape,
# with a spoofed parent, so neither the job nor the process tree says whose it
# is. Before the lineage went into its spec path, a lineage-scoped teardown
# would have left the other run's holders - and therefore its PTYs - alive.
#
# THE APP HALF IS PIDS, NOT COMMAND LINES
#
# `ghoztty.exe` spells nothing about its endpoint on its command line (the pipe
# suffix and LOCALAPPDATA both travel in the environment), so there is no
# equivalent fingerprint for it. There does not need to be one: every GUI and
# CLI invocation in this harness goes through `Start-OnTestDesktop` /
# `Invoke-OnTestDesktop`, which already record each pid they launch. A scoped
# kill asks THAT, which is exactly "the pids this script started" - and a script
# that launches the app some other way is not one that may be scoped, which
# `test\win32\agent-lineage-suites.ps1` section D is the check for.

Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'BuildMode.ps1')

# Minting a lineage is what frees the agent to write its own
# `HKCU\...\Run\GhozttyAgent-<inst>` value instead of clobbering the user's -
# and nothing removes it when the run ends unless the teardown is armed at the
# moment of minting (T1168). Same reason, same place, as lib\Isolation.ps1.
. (Join-Path $PSScriptRoot 'HarnessLeak.ps1')

# `GHOZTTY_AGENT_INSTANCE` caps at 24 chars (src\remote\agent_lineage.zig
# `max_len`) and an over-long value is REJECTED rather than truncated, because
# truncation would silently merge two sandboxes into one lineage - the very bug
# the knob exists to prevent. So compose inside the cap here.
$script:GhozttyLineageMaxLen = 24

function New-GhozttyAgentLineageName {
    <#
    .SYNOPSIS
    A run-unique lineage name for -Tag, inside the 24-char cap.

    .DESCRIPTION
    `<tag>-<pid>`, with the TAG trimmed and the pid never trimmed: the pid is
    what makes two runs of one script distinct, and a run-unique name is the
    whole point (a fixed one hands the next run whatever the last one left
    registered on that lineage). Pure - sets nothing.
    #>
    param([Parameter(Mandatory = $true)][string]$Tag)

    if (-not $Tag) { throw 'New-GhozttyAgentLineageName needs a tag.' }
    # The sanitize on the Zig side is a whitelist; keep to it here so a tag can
    # never be REJECTED at the far end, which would look like "no lineage".
    $clean = ($Tag -replace '[^A-Za-z0-9_-]', '')
    if (-not $clean) { throw "New-GhozttyAgentLineageName: tag '$Tag' has no usable characters." }

    $pidPart = [string]$PID
    $tagRoom = $script:GhozttyLineageMaxLen - ($pidPart.Length + 1)
    if ($tagRoom -lt 1) { throw "New-GhozttyAgentLineageName: pid $PID leaves no room for a tag." }
    $tagPart = if ($clean.Length -gt $tagRoom) { $clean.Substring(0, $tagRoom) } else { $clean }
    return "$tagPart-$pidPart"
}

function Get-GhozttyAgentLineage {
    <#
    .SYNOPSIS
    The lineage this process is running under, or $null.
    #>
    if ($env:GHOZTTY_AGENT_INSTANCE) { return $env:GHOZTTY_AGENT_INSTANCE }
    return $null
}

function Set-GhozttyTestAgentLineage {
    <#
    .SYNOPSIS
    Give this run its own agent lineage. Returns the instance name.

    .DESCRIPTION
    One call, next to the script's existing `Set-GhozttyTestIsolation`. After
    it: the agent this run's app spawns takes a guard nobody else holds, writes
    its state under `local-agent-debug-<inst>`, listens on its own pipe, and is
    invisible to `+sessions` run without the suffix. Nothing has to be killed
    for any of that to be true.

    Call it BEFORE the first reset and before anything is launched. A run that
    mints its lineage after it has already started an agent has two.

    Already set (lib\Isolation.ps1's -ReleaseSandbox mints one too) is not an
    error and is not overwritten: the two mechanisms name the same env var on
    purpose, and the first one to speak owns the run.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [switch]$Quiet
    )

    $existing = Get-GhozttyAgentLineage
    if ($existing) {
        if (-not $Quiet) { "  [lineage] GHOZTTY_AGENT_INSTANCE=$existing (already set; left alone)" }
        return $existing
    }

    $instance = New-GhozttyAgentLineageName -Tag $Tag
    $env:GHOZTTY_AGENT_INSTANCE = $instance
    [void](Register-AgentRunKeyTeardown -Instance $instance)
    if (-not $Quiet) { "  [lineage] GHOZTTY_AGENT_INSTANCE=$instance" }
    return $instance
}

function Get-GhozttyAgentStateDirLeaf {
    <#
    .SYNOPSIS
    The agent state directory's LEAF for a build mode and lineage.

    .DESCRIPTION
    Mirrors `LocalAgent.agentDir` (src\apprt\win32\LocalAgent.zig): the base is
    `local-agent-debug` on an isolated build and `local-agent` otherwise, and
    the lineage is appended with a `-`. Pure.
    #>
    param(
        [string]$Instance,
        [switch]$ReleaseLineage
    )
    $base = if ($ReleaseLineage) { 'local-agent' } else { 'local-agent-debug' }
    if ($Instance) { return "$base-$Instance" }
    return $base
}

function Get-GhozttyAgentStateDir {
    <#
    .SYNOPSIS
    The agent state directory under -Root, for THIS run's lineage.

    .DESCRIPTION
    The one-line replacement for the `Join-Path $tmp 'ghoztty\local-agent-debug'`
    that sixty scripts here spell by hand. -Root is the LOCALAPPDATA the run is
    using (its private `$tmp`, or `$env:LOCALAPPDATA`).

    The base comes from the build mode when -Exe is given, and is assumed
    `-debug` otherwise - which is what every caller that hardcoded the name was
    already assuming, and what `Assert-GhozttyIsolatedBuild` refuses to let be
    wrong. -Instance overrides the ambient lineage, for a script that reasons
    about somebody else's.

    Creates nothing: callers that need the directory to exist keep their own
    New-Item, because on the ordinary path the AGENT creates it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Exe,
        [string]$Instance,
        [switch]$NoLineage
    )

    $inst = if ($NoLineage) { $null } elseif ($PSBoundParameters.ContainsKey('Instance')) { $Instance } else { Get-GhozttyAgentLineage }

    $releaseLineage = $false
    if ($Exe) {
        $mode = Get-GhozttyBuildMode -Exe $Exe
        $releaseLineage = -not (Test-GhozttyIsolatedBuildMode -Mode $mode)
    }

    $leaf = Get-GhozttyAgentStateDirLeaf -Instance $inst -ReleaseLineage:$releaseLineage
    return (Join-Path $Root (Join-Path 'ghoztty' $leaf))
}

function Get-GhozttyAgentLineageMarker {
    <#
    .SYNOPSIS
    The command-line fragments that identify -Instance's agent and holders.

    .DESCRIPTION
    Two, because a lineage owns two kinds of process and they spell it
    differently (see this file's header). Returned as an array of literal
    substrings; the caller does the matching so it can log which one hit.
    #>
    param([Parameter(Mandatory = $true)][string]$Instance)
    return @(
        # the agent: its --port-file / --sessions-file live in the state dir
        "\$(Get-GhozttyAgentStateDirLeaf -Instance $Instance)\",
        "\$(Get-GhozttyAgentStateDirLeaf -Instance $Instance -ReleaseLineage)\",
        # a per-session ConPTY holder: --spec %TEMP%\ghoztty-ptyhost-<inst>-<sid>.json
        "\ghoztty-ptyhost-$Instance-"
    )
}

function Test-GhozttyAgentLineageOwned {
    <#
    .SYNOPSIS
    Does -CommandLine belong to -Instance's lineage?

    .DESCRIPTION
    The predicate a scoped teardown runs. A command line that names NO lineage
    at all (the box's own `local-agent-debug\`) is not ours and answers $false,
    which is the whole point - but note that the agent marker is anchored with
    a trailing separator so `local-agent-debug\` can never be read as a prefix
    of `local-agent-debug-sbx1\`, or the reverse.
    #>
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Instance
    )
    if (-not $CommandLine) { return $false }
    foreach ($marker in (Get-GhozttyAgentLineageMarker -Instance $Instance)) {
        if ($CommandLine.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-GhozttyHarnessLaunchedPid {
    <#
    .SYNOPSIS
    Every pid this run launched through the test-desktop helpers, or $null when
    those helpers were never loaded.

    .DESCRIPTION
    $null and "an empty list" mean different things here and the difference
    decides whether a kill may be scoped at all: no records because the script
    does not use the helpers is NOT the same as no records because it has not
    launched anything yet. Callers treat $null as "cannot scope the app half".
    #>
    if (-not (Get-Command Get-TestLaunchRecords -ErrorAction SilentlyContinue)) { return $null }
    return , @(Get-TestLaunchRecords | ForEach-Object { [int]$_.Pid })
}
