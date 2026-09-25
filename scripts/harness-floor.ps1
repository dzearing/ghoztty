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
    [string]$ScoreSummary
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
        Write-Host ("  {0,-30} {1}{2}" -f $a.Name, $a.Why, $mark)
    }
    exit 0
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

if (-not $verdict.Ok) { exit 1 }

# A green FULL run stamps the covered files (T783), so guard-due can answer "has
# anybody run the harness floor against the suite as it now stands?" - which is
# what makes the set standing rather than something a turn remembers. Only a
# full run, and only a real one: a narrowed -Include measured part of the suite,
# and -ScoreSummary measured nothing at all.
if (-not $Include -and -not $ScoreSummary) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'guard-due.ps1') `
        update -Guard harness-floor -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}
exit 0
