# morning-owner.ps1 - which loop lane writes today's morning block (T2115).
#
# go.md steps 0.5-0.7 (the daily digest, the triage with its main intake, and
# the feature ideas) are one block of work a day, and every lane used to do
# it. On 2026-10-21 lanes A and B both wrote the whole block; lane A's commit
# conflicted on the digest and the intake watermark at push-rebase and was
# skipped, so 40 minutes of work were thrown away. The 2026-10-20 main intake
# was double-filed the same way (T2089-T2096).
#
# The block has ONE owner, lane a (the main worktree) - the same lane that
# alone publishes and delivers (LoopLane.ps1). Another lane takes it only when
# lane a's loop is NOT running (its lock is free or stale, or it is stopped by
# request), so a parked lane a never costs the user their morning read.
#
# The MAIN INTAKE left this block in T2260: it runs whenever it is due, from
# any lane, under its own box-wide lease (scripts\main-intake.ps1).
#
# This only answers "is it this lane's job?". Whether a digest is owed at all
# (past 05:00, no file yet) is still `digest=` on go-loop-health.ps1, which
# stays lane-agnostic: it asks whether the file exists, not who wrote it.
#
#   powershell -NoProfile -File scripts\morning-owner.ps1
#
# Exit 0 = this lane owns the block today: run steps 0.5-0.7 as written.
#      3 = another lane owns it: one 'LANE REFUSED' line names it; skip steps
#          0.5-0.7 and carry on with step 1. Not a failure.
#
# ASCII only and PS 5.1 compatible.

param(
    [string]$Repo,
    # Same default as go-loop-health.ps1: a lock with no sign of life for this
    # long is stale, and a stale lane a is not running the loop.
    [int]$StaleMinutes = 45
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

. (Join-Path $PSScriptRoot 'loop-session.ps1')
. (Join-Path $PSScriptRoot 'lib\LoopLane.ps1')

$lane = Get-LoopLaneId -Repo $Repo
if (Test-LoopLaneOwnsDelivery $lane) {
    Write-Host "MORNING OWNER lane $lane - write today's digest, triage and feature ideas (go.md steps 0.5-0.7)"
    exit 0
}

# Lane a's loop state, asked the way go-loop-health.ps1 asks it of another lane.
$laneA = @(Get-LoopLanes -Repo $Repo | Where-Object { $_.Id -eq 'a' }) | Select-Object -First 1
$state = 'absent'
if ($laneA) {
    $state = 'free'
    if (Test-Path -LiteralPath $laneA.LockPath) {
        $lr = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'go-loop-lock.ps1') status -Json `
            -Repo $laneA.Root -LockPath $laneA.LockPath -NoPaneProbe -StaleMinutes $StaleMinutes 2>$null
        try { $lj = ($lr | Out-String | ConvertFrom-Json); if ($lj -and $lj.state) { $state = [string]$lj.state } } catch { }
    }
    if (Get-LoopStop -Path $laneA.StopPath) { $state = 'stopped' }
}

if ($state -eq 'held') {
    Write-Host ("LANE REFUSED lane $lane does not write the morning block - lane a is running the loop and owns " +
        "today's digest, triage and feature ideas, so two lanes never write the same day twice (T2115). " +
        "Skip go.md steps 0.5-0.7 and carry on with step 1.")
    exit 3
}

Write-Host "MORNING OWNER lane $lane - lane a is $state, so this lane writes today's digest, triage and feature ideas (go.md steps 0.5-0.7)"
exit 0
