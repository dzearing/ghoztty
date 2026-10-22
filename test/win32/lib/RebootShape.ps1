# RebootShape.ps1 - the one way an acceptance script fakes a machine restart
# (T1140). Dot-source it AFTER lib\CleanSlate.ps1, whose Stop-RepoGhoztty it
# drives:
#
#     . (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
#     . (Join-Path $PSScriptRoot 'lib\RebootShape.ps1')
#     $r = Stop-RebootShape -Exe $Exe
#     Assert "no agent process survived the reboot shape ($($r.Survivors))" ($r.Survivors -eq 0)
#
# WHY THIS EXISTS
#
# Since T909 a persistent session's ConPTY, shell and kill-on-close job live in
# a separate `ghoztty-agent --pty-host --spec ...` holder process
# (src\remote\agent\pty_holder_child.zig) that deliberately outlives the
# session manager: an agent that crashes or is upgraded comes back and ADOPTS
# its holders, and the panes re-attach to sessions that never died. That is
# right - and it means "kill the agent" stopped being a reboot. It is an
# upgrade. A test that kills the manager alone and expects dead-but-relaunchable
# tombstones measures re-adoption instead, and scores a correct app broken.
#
# That has been paid twice, three months apart, by scripts that each worked the
# shape out for themselves:
#
#   - session-relaunch-notify.ps1 (2026-08-18): every notice arm FAILED against
#     a correct build - the restored panes had re-attached to LIVE sessions and
#     there was nothing to notify about.
#   - agent-autostart.ps1 (T1108): `B6 ...as a DEAD tombstone` was red, filed as
#     a P1 user-facing defect, and the app was fine - the surviving holder was
#     re-adopted exactly as designed.
#
# and a third copy (session-reboot-tui.ps1) was written the same way. So the
# reasoning lives here, under the name the next script will reach for.
#
# WHAT IT DOES
#
# A reboot takes everything, in the order the OS would leave it: the app first
# (app death never ends a session - no CLOSE is sent), then the session manager
# AND every holder. Holders are the same image at the same path as the manager,
# so the path-exact agent kill takes them together, and the `ExecutablePath`
# filter is what keeps the user's installed agent - which owns their real
# sessions - out of it. It never matches on a `*zig-out*` command line: that
# also sees another loop lane's checkout (D:\git\ghoztty vs D:\git\ghoztty-b)
# and a detached zig-out-release instance (T53b).
#
# It RETURNS what it saw rather than asserting, so the caller's assertions keep
# their own names:
#
#   HoldersBefore  holders alive when the kill started. This is the
#                  non-vacuousness number: a run that had live sessions and
#                  reports 0 here had holders switched off (an inherited
#                  GHOZTTY_AGENT_PTY_HOLDER=0) rather than exercised, and its
#                  green says nothing about the reboot path.
#   ManagersBefore session managers alive when the kill started.
#   Survivors      repo-path agent processes (manager or holder) still alive
#                  after it. Anything but 0 is a box that is not rebooted.

Set-StrictMode -Off

function Get-RebootShapeAgentProcess {
    <#
    .SYNOPSIS
    Every live ghoztty-agent.exe whose ExecutablePath is exactly $Exe's sibling
    agent - the manager and its `--pty-host` holders alike - optionally narrowed
    to this run's lineage (lib\AgentLineage.ps1).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$ScopeToLineage
    )
    $agentPath = Get-GhozttyAgentPath -Exe $Exe
    # Assign, then filter: Get-RepoGhozttyProcess returns `, @(...)`, and piping
    # the CALL straight into Where-Object hands the filter the whole array as
    # one object (see Stop-RepoGhoztty).
    $all = Get-RepoGhozttyProcess -Paths @($agentPath)
    if (-not $ScopeToLineage) { return , @($all) }
    $lineage = Get-GhozttyAgentLineage
    return , @($all | Where-Object {
            Test-GhozttyAgentLineageOwned -CommandLine $_.CommandLine -Instance $lineage })
}

function Stop-RebootShape {
    <#
    .SYNOPSIS
    Fake a machine restart: kill the app under test, then its session manager
    and every PTY holder, and report what was there and what is left.

    .DESCRIPTION
    Returns [pscustomobject]@{ HoldersBefore; ManagersBefore; Survivors }. The
    kills are Stop-RepoGhoztty's (path-exact, polled until gone, refusing an exe
    outside the repo), so a box that will not come clean throws there with the
    surviving pids named; Survivors is the independent read-back afterwards.

    -SettleMs is the settle after the APP kill (the session-layout manifest and
    the panes' last writes land in it) and again after the agent kill.
    -ScopeToLineage is passed through to both kills and the counts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [int]$SettleMs = 900,
        [switch]$ScopeToLineage
    )

    $scope = @{}
    if ($ScopeToLineage) { $scope.ScopeToLineage = $true }

    # The app first, exactly as a restart leaves it: app death sends no CLOSE,
    # so every session it was showing is still the agent's.
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs $SettleMs @scope)

    $before = Get-RebootShapeAgentProcess -Exe $Exe @scope
    $holders = @($before | Where-Object { $_.CommandLine -like '*--pty-host*' }).Count
    $managers = $before.Count - $holders

    [void](Stop-RepoGhoztty -Exe $Exe -AgentOnly -SettleMs $SettleMs @scope)

    $after = Get-RebootShapeAgentProcess -Exe $Exe @scope
    return [pscustomobject]@{
        HoldersBefore  = $holders
        ManagersBefore = $managers
        Survivors      = $after.Count
    }
}
