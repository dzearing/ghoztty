# suite-timeout-sec: 3600
# (T1960: the full sweep runs 16-25 minutes; a runner that kills it at its own
# default cap scores a working floor STALL.)
<#
.SYNOPSIS
  Run the standing harness audits - one command, one verdict line.

.DESCRIPTION
  T725. `test\win32\` holds a family of audits whose subject is the HARNESS
  rather than the product: does every acceptance script score itself, exit the
  code its verdict implies, say out loud when it skipped something, isolate its
  endpoints, keep what the app said on its way out. The P1-P3 scripts are the
  PRODUCT's floor and nothing was the harness's, so each audit ran only when the
  turn that wrote it remembered to run it - and an audit that went red simply
  stayed red. Two of them were, the day this was written: `skip-visibility.ps1`
  against 13 unlisted violators (T1123), `asserted-nothing.ps1` with its
  unarmed-stamp ratchet two over its ceiling (T1568). Neither had been run in
  weeks.

  WHAT IT RUNS. The set in `scripts\lib\HarnessFloor.ps1`, which is where a new
  audit is added and where the reason each one is here is written down. Every
  member is a static sweep over the suite's own source or a pure-logic check of
  a shared gate - no GUI, no app launch, no `zig build` - which is what makes
  the whole set about fifteen minutes rather than an afternoon.

  HOW IT RUNS THEM. Through `scripts\suite-run.ps1`, not a scorer of its own:
  that runner already owns per-script timeouts, the verdict contract
  (`test\win32\lib\TestScore.ps1`), the leak sweep between scripts and the
  re-run-red-alone pass. A second implementation of any of those is a second
  thing free to disagree about what green means.

  THE PENDING RATCHET. An audit red for a reason somebody has already filed is
  listed in `$HARNESS_FLOOR_PENDING` against the task that converts it: it is
  run and reported, and it does not fail the floor. Anything else that goes red
  DOES. The list may only shrink - an entry whose audit has gone green fails as
  STALE - so the baseline cannot outlive the work it was a baseline for.

.PARAMETER Include
  Comma-separated wildcards, applied to the floor set, for running part of it.
  The verdict then covers only what was selected.

.PARAMETER List
  Print the set and the pending exceptions, run nothing.

.OUTPUTS
  One row per audit as it goes (suite-run's), then the floor's own summary and a
  final `HARNESS FLOOR: ...` line. Exit 0 green, 1 red.

.EXAMPLE
  powershell -NoProfile -File scripts\harness-floor.ps1
  powershell -NoProfile -File scripts\harness-floor.ps1 -List
  powershell -NoProfile -File scripts\harness-floor.ps1 -Include 'skip-*,foreground-*'
  powershell -NoProfile -File scripts\harness-floor.ps1 -Scoped -PlanOnly
#>
[CmdletBinding()]
param(
    [string]$Repo,

    # Single string, split here: every script under this tree is invoked with
    # `powershell -File`, where an argument list is parsed as LITERAL text, so
    # `-Include a,b` binds as the one string "a,b" (suite-run's -Include note).
    [string]$Include,

    [switch]$List,

    # Where suite-run puts its per-audit logs and summary.json.
    [string]$OutDir,

    # Per-audit cap for an audit that declares none. These are source sweeps;
    # the slowest measured here is test-reach-audit at about seven minutes.
    [int]$TimeoutSec = 900,

    # Score an existing suite-run summary instead of running anything. This is
    # how the acceptance harness exercises the scoring against planted rows
    # without waiting fifteen minutes for a real sweep.
    [string]$ScoreSummary,

    # T1955: where a full run records what it found, so a green narrowed re-run
    # of exactly its red rows can complete it. Default temp\harness-floor\
    # last-full.json; the acceptance harness points it at a scratch file.
    [string]$RecordPath,

    # How old a red full run may be and still be completed by a re-run.
    [double]$MaxAgeHours = 4,

    # Say what a completion WOULD stamp and stamp nothing. For the acceptance
    # harness, whose run must never write the committed floor stamp.
    [switch]$DryRunStamp,

    # T1958: the per-turn sweep. Run only what changed since the floor was last
    # verified green - every turn-tier member plus any member whose own script
    # changed - or the full set when a shared file changed or the last green
    # full sweep is older than -MaxFullAgeHours. Nothing changed: no run. A
    # bare invocation (no -Scoped, no -Include) is the FULL sweep, which is
    # what the digest step runs daily.
    [switch]$Scoped,

    # Where the floor records what it last verified green. Default
    # temp\harness-floor\verified.json; the acceptance harness points it at a
    # scratch file.
    [string]$VerifiedPath,

    # How old the last green full sweep may be and still let a scoped sweep
    # stand in for one. A day plus slack: the digest step runs the full sweep
    # every morning.
    [double]$MaxFullAgeHours = 26,

    # With -Scoped: print what would run, and why, and run nothing.
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'lib\HarnessFloor.ps1')

$audits = @(Get-HarnessFloorAudits)
$pending = Get-HarnessFloorPending

if ($Include) {
    $patterns = @($Include -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $audits = @($audits | Where-Object {
            $n = $_.Name
            @($patterns | Where-Object { $n -like $_ }).Count -gt 0
        })
    if ($audits.Count -eq 0) {
        Write-Host "HARNESS FLOOR: nothing in the floor set matches -Include '$Include'"
        exit 1
    }
    # The exceptions narrow with the set. Without this, every pending entry for
    # an audit -Include left out reads as an ORPHAN - an exception excusing
    # nothing - and a one-audit run scores red for the state of the other 22.
    $selected = @($audits | ForEach-Object { [string]$_.Name })
    $narrowed = @{}
    foreach ($k in @($pending.Keys)) { if ($selected -contains $k) { $narrowed[$k] = $pending[$k] } }
    $pending = $narrowed
}

if ($List) {
    Write-Host "harness floor: $($audits.Count) audit(s)"
    foreach ($a in $audits) {
        $mark = if ($pending.ContainsKey($a.Name)) { "  [PENDING $($pending[$a.Name])]" } else { '' }
        $tier = if ((Get-HarnessFloorTier $a) -eq 'daily') { '  [daily]' } else { '' }
        Write-Host ("  {0,-30} {1}{2}{3}" -f $a.Name, $a.Why, $tier, $mark)
    }
    exit 0
}

if (-not $VerifiedPath) { $VerifiedPath = Get-HarnessFloorVerifiedPath $Repo }

function Stamp-Floor {
    if ($DryRunStamp) { Write-Host '  DRY RUN: would stamp harness-floor; nothing written'; return }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'guard-due.ps1') `
        update -Guard harness-floor -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

function Save-Verified([datetime]$FullAt) {
    if ($DryRunStamp) { return }
    $head = (& git -C $Repo rev-parse --short HEAD 2>$null | Select-Object -Last 1)
    $v = New-HarnessFloorVerified -FullAt $FullAt -Fingerprint (Get-HarnessFloorFingerprint $Repo) -Head ([string]$head)
    try { Write-HarnessFloorRecord -Path $VerifiedPath -Record $v } catch {
        Write-Host "  (could not record what the floor verified: $($_.Exception.Message))"
    }
}

# T1958: the scoped per-turn sweep. Decides the set, then falls through to the
# ordinary run with -Include semantics (a scoped set) or none (a full sweep).
$scopeMode = $null
$scopeFullAt = $null
if ($Scoped -and -not $Include -and -not $ScoreSummary) {
    $verified = Read-HarnessFloorRecord $VerifiedPath
    if ($null -eq $verified) {
        # A box that has swept since T1955 but never since T1958 already holds
        # the answer: a green (or completed) full-run record is a verified
        # state as of when it ran. Its fingerprint predates any fix edits, so
        # those read as changed - the conservative direction.
        if (-not $RecordPath) { $RecordPath = Get-HarnessFloorRecordPath $Repo }
        $last = Read-HarnessFloorRecord $RecordPath
        if ($last -and (-not $last.kind -or $last.kind -eq 'full') -and ($last.ok -or $last.consumed)) {
            $verified = [pscustomobject]@{
                fullAt = $last.finishedAt; verifiedAt = $last.finishedAt; fingerprint = $last.fingerprint
            }
        }
    }
    $scope =Get-HarnessFloorScope -Verified $verified -Fingerprint (Get-HarnessFloorFingerprint $Repo) `
        -Audits $audits -MaxFullAgeHours $MaxFullAgeHours
    $scopeMode = $scope.Mode
    Write-Host ("harness floor scope: {0} - {1}" -f $scope.Mode.ToUpper(), $scope.Reason)
    foreach ($ch in @($scope.Changed)) { Write-Host "    changed since verified: $ch" }
    if ($PlanOnly) {
        foreach ($n in @($scope.Selected)) { Write-Host "    would run: $n" }
        exit 0
    }
    if ($scope.Mode -eq 'current') {
        Write-Host "HARNESS FLOOR CURRENT: verified green at $($verified.verifiedAt) (full sweep $($verified.fullAt)); nothing to run"
        Stamp-Floor
        exit 0
    }
    if ($scope.Mode -eq 'scoped') {
        $scopeFullAt = $verified.fullAt
        $Include = (@($scope.Selected) -join ',')
        $selected = @($scope.Selected)
        $audits = @($audits | Where-Object { $selected -contains [string]$_.Name })
        $narrowed = @{}
        foreach ($k in @($pending.Keys)) { if ($selected -contains $k) { $narrowed[$k] = $pending[$k] } }
        $pending = $narrowed
    }
}

# ---------------------------------------------------------------- the rows

if ($ScoreSummary) {
    $summaryPath = $ScoreSummary
}
else {
    # Each audit named exactly, so an audit that has been RENAMED or deleted
    # produces no row and the floor says NOT RUN rather than quietly measuring
    # one fewer thing.
    $names = @($audits | ForEach-Object { $_.Name })
    if (-not $OutDir) {
        $OutDir = Join-Path $Repo ("temp\harness-floor\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $suite = Join-Path $PSScriptRoot 'suite-run.ps1'
    # T1982: one harness sweep on the box at a time. floor-lane.ps1 takes this
    # outside its watchdog and says so through GHOZTTY_FLOOR_LOCK_HELD; a
    # direct run takes it here. Released when this process exits.
    if ($env:GHOZTTY_FLOOR_LOCK_HELD -ne '1') {
        . (Join-Path $PSScriptRoot 'lib\MachineLock.ps1')
        $floorLock = Enter-MachineLock -Kind floor -Label "harness-floor.ps1 ($Repo)"
        if (-not $floorLock.Acquired) {
            Write-Host "FLOOR LOCK: running the sweep anyway - two sweeps at once are slower, not wrong"
        }
    }
    Write-Host "harness floor: $($audits.Count) audit(s) via suite-run -> $OutDir"
    Write-Host ''
    & powershell -NoProfile -ExecutionPolicy Bypass -File $suite run `
        -Repo $Repo -Include ($names -join ',') -OutDir $OutDir -TimeoutSec $TimeoutSec
    # suite-run's exit code is deliberately NOT the floor's: a red row that is a
    # named pending exception is not a floor failure, and that judgement is the
    # whole point of this wrapper. The rows are what is read.
    $summaryPath = Join-Path $OutDir 'summary.json'
}

if (-not (Test-Path $summaryPath)) {
    Write-Host ''
    Write-Host "HARNESS FLOOR: 1 FAILURE(S) - the run left no summary at $summaryPath"
    exit 1
}

$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$rows = @($summary.results)

$verdict = Get-HarnessFloorVerdict -Rows $rows -Audits $audits -Pending $pending `
    -LogDir (Split-Path -Parent $summaryPath)

Write-Host ''
Write-Host '---- harness floor ----------------------------------------------------------'
foreach ($line in @(Format-HarnessFloorVerdict -Verdict $verdict)) { Write-Host $line }

if (-not $RecordPath) { $RecordPath = Get-HarnessFloorRecordPath $Repo }

# T1955. A real sweep - full, or scoped (T1958) - records what it found, red or
# green, so that a fix to one red member is proved by re-running that member,
# not the whole sweep again. Written on every such run, so the record always
# describes the latest sweep and an old red one cannot be completed after a
# newer one.
$isSweep = (-not $ScoreSummary) -and ((-not $Include) -or $scopeMode -eq 'scoped')
$kind = if ($scopeMode -eq 'scoped') { 'scoped' } else { 'full' }
if ($isSweep) {
    $head = (& git -C $Repo rev-parse --short HEAD 2>$null | Select-Object -Last 1)
    $record = New-HarnessFloorRecord -Verdict $verdict -Head ([string]$head) -Kind $kind `
        -Fingerprint (Get-HarnessFloorFingerprint $Repo)
    try { Write-HarnessFloorRecord -Path $RecordPath -Record $record } catch {
        Write-Host "  (could not record this run for a targeted re-run: $($_.Exception.Message))"
    }
    if (-not $verdict.Ok -and -not $record.structural -and @($record.red).Count -gt 0) {
        Write-Host ''
        Write-Host '  Fix the red row(s), then re-run ONLY them - a green re-run completes this sweep and stamps the floor:'
        Write-Host ("    powershell -NoProfile -File scripts\harness-floor.ps1 -Include '{0}'" -f (@($record.red) -join ','))
    }
}

if (-not $verdict.Ok) { exit 1 }

# A green sweep stamps the covered files (T783), so guard-due can answer "has
# anybody run the harness floor against the suite as it now stands?" - which is
# what makes the set standing rather than something a turn remembers. A FULL
# sweep also restarts the daily clock; a SCOPED one (T1958) advances only the
# fingerprint, so the daily members still owe their run within the day.
if ($isSweep) {
    if ($kind -eq 'full') { Save-Verified (Get-Date) }
    else { Save-Verified ([datetime]$scopeFullAt) }
    if ($kind -eq 'scoped') {
        Write-Host ("HARNESS FLOOR SCOPED: {0} of {1} members green; the last full sweep ({2}) still stands" -f `
                @($audits).Count, @(Get-HarnessFloorAudits).Count, $scopeFullAt)
    }
    Stamp-Floor
    exit 0
}

# A green narrowed re-run that covers every red row of the last sweep completes
# it (T1955; the rules are Test-HarnessFloorCompletion's).
if ($Include -and -not $ScoreSummary) {
    $selected = @($audits | ForEach-Object { [string]$_.Name })
    $rec = Read-HarnessFloorRecord $RecordPath
    $c = Test-HarnessFloorCompletion -Record $rec -Selected $selected -Verdict $verdict `
        -Fingerprint (Get-HarnessFloorFingerprint $Repo) -MaxAgeHours $MaxAgeHours
    Write-Host ''
    if (-not $c.Ok) {
        Write-Host "  not a completion of the last full run: $($c.Reason)"
        exit 0
    }
    $recKind = if ($rec.kind) { [string]$rec.kind } else { 'full' }
    Write-Host ("HARNESS FLOOR COMPLETED: the {0} run of {1} (head {2}) was red only on {3}; all now green" -f `
            $recKind, $rec.finishedAt, $rec.head, (@($c.Red) -join ', '))
    foreach ($ch in @($c.Changed)) { Write-Host "    edited since the full run: $ch" }
    if ($DryRunStamp) {
        Write-Host '  DRY RUN: would stamp harness-floor; nothing written'
        exit 0
    }
    $rec.consumed = $true
    try { Write-HarnessFloorRecord -Path $RecordPath -Record $rec } catch {
        Write-Host "  (could not mark the record consumed: $($_.Exception.Message))"
    }
    # A completed full sweep is a green full sweep as of when it ran; a
    # completed scoped one leaves the daily clock where it was (T1958).
    if ($recKind -eq 'full') { Save-Verified ([datetime]$rec.finishedAt) }
    else {
        $prior = Read-HarnessFloorRecord $VerifiedPath
        if ($prior -and $prior.fullAt) { Save-Verified ([datetime]$prior.fullAt) }
    }
    Stamp-Floor
    exit 0
}
exit 0
