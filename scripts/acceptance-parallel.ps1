<#
.SYNOPSIS
  Run acceptance scripts about four at a time - normally the guard-due set a
  turn owes - with every worker isolated from every other (T1960).

.DESCRIPTION
  A turn's due acceptance used to run one script at a time: 21 harnesses took
  16 minutes on T1874. This runs them side by side, each worker in its own
  mirror of the repo (junctions to the real tree, its own hard-linked zig-out,
  its own LOCALAPPDATA, agent lineage and app pipe), so no worker's clean-slate
  can reach another worker's app. How, and what may not run in a worker, is in
  scripts\lib\AcceptanceParallel.ps1.

    due       run every blocking `GUARD DUE` harness (scripts\guard-due.ps1),
              -Width at a time. This is the step-3 command.
    run       run -Scripts (comma-separated, relative to the repo or to
              test\win32), -Width at a time.
    classify  print each script's class (parallel / main / exclusive) and why,
              without running anything. -Scripts narrows it; default is every
              top-level test\win32 script.

  -Width 1 runs the same set strictly one at a time, from the real repo, with
  your environment - the serial baseline, for comparing verdicts.

  A script declares `# @timing-sensitive` when it measures a wall-clock budget:
  it then runs with nothing beside it. `# @parallel-unsafe` is the general
  opt-out. Every non-green row is re-run alone before the run ends; red beside
  others and green alone is reported PARALLEL-SENSITIVE with the marker to add,
  and the alone verdict is the one that counts.

  BEFORE ANY SCRIPT STARTS (T1961) the run settles whether zig-out is the code
  under test: a stale or missing ghoztty.exe is rebuilt once (Debug), and a
  failed rebuild - or any stale exe under -NoRebuild - refuses the whole run
  with nothing launched. Without this every worker met the same stale exe and
  the turn read a page of red rows about one cause.

  -FailFast stops starting scripts at the first red (running ones finish, the
  red is still confirmed alone) and names every script it never ran. `due`
  orders the most specific harness first, so the changed feature's own
  acceptance is the first to answer. The step-3 order is in go.md.

  Exit 0: every script passed or skipped. Exit 1: something is red, or
  -FailFast left scripts unrun. Exit 3: the schedule was violated (an exclusive
  script overlapped another) - a runner defect, never a script's. Exit 4: the
  build is stale and was not (or could not be) rebuilt - nothing ran.

.EXAMPLE
  powershell -NoProfile -File scripts\acceptance-parallel.ps1 due
  powershell -NoProfile -File scripts\acceptance-parallel.ps1 run -Scripts viewer-close.ps1 -FailFast
  powershell -NoProfile -File scripts\acceptance-parallel.ps1 run -Scripts kb-actions.ps1,viewer-close.ps1
  powershell -NoProfile -File scripts\acceptance-parallel.ps1 classify -Scripts drag-perf.ps1
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('due', 'run', 'classify')]
    [string]$Action = 'due',

    # Comma-separated, as ONE string: `-File` binds an array parameter's
    # elements unreliably, the reason suite-run.ps1 takes lists the same way.
    [string]$Scripts,

    [int]$Width = 4,
    [int]$TimeoutSec = 1800,
    [string]$LogDir,
    [switch]$NoConfirm,
    [switch]$FailFast,
    [switch]$NoRebuild,
    [switch]$Json,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }
$Repo = (Resolve-Path $Repo).Path
. (Join-Path $PSScriptRoot 'lib\AcceptanceParallel.ps1')
. (Join-Path $PSScriptRoot 'lib\AcceptanceFresh.ps1')

function Resolve-ApScript {
    param([string]$Name)
    $n = $Name.Trim()
    foreach ($cand in @($n, (Join-Path 'test\win32' $n))) {
        if (Test-Path -LiteralPath (Join-Path $Repo $cand)) { return $cand }
    }
    throw "no such script: $n (looked under the repo and test\win32)"
}

switch ($Action) {
    'classify' {
        $paths = if ($Scripts) {
            @($Scripts -split ',' | Where-Object { $_.Trim() } | ForEach-Object { Join-Path $Repo (Resolve-ApScript $_) })
        } else {
            @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Filter *.ps1 -File | Sort-Object Name | ForEach-Object { $_.FullName })
        }
        $rows = @(foreach ($p in $paths) { Get-AcceptanceScriptClass -Path $p -RepoLiteral $Repo })
        if ($Json) { ConvertTo-Json -Depth 4 -InputObject @($rows); exit 0 }
        foreach ($r in $rows) {
            "{0,-10} {1}{2}" -f $r.Class, $r.Name, $(if ($r.Reasons.Count) { '  - ' + ($r.Reasons -join '; ') } else { '' })
        }
        $g = $rows | Group-Object Class
        "CLASSIFY {0} scripts: {1}" -f $rows.Count, (($g | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        exit 0
    }
}

# ------------------------------------------------------------- the job list

$jobs = @()
if ($Action -eq 'run') {
    if (-not $Scripts) { throw "run needs -Scripts a.ps1,b.ps1" }
    $jobs = @($Scripts -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [pscustomobject]@{ Script = (Resolve-ApScript $_); Args = '' } })
} else {
    $guard = Join-Path $PSScriptRoot 'guard-due.ps1'
    $raw = & powershell -NoProfile -File $guard check -Json -Repo $Repo 2>$null
    try { $jobs = @(Get-AcceptanceDueJobs -GuardJson ($raw -join "`n")) }
    catch { throw "guard-due check -Json did not answer JSON: $($raw | Select-Object -First 3)" }
    if ($jobs.Count -eq 0) { "ACCEPTANCE DUE: nothing is due."; exit 0 }
}

# T1961: one freshness answer for the whole run, before anything launches.
$fresh = Invoke-AcceptanceFreshPreflight -Repo $Repo -NoRebuild:$NoRebuild
$fresh.Line
if (-not $fresh.Ok) { exit 4 }

if (-not $LogDir) { $LogDir = Join-Path $env:TEMP ("ghoztty-acceptance-parallel\" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
"ACCEPTANCE {0}: {1} script(s), width {2}, logs {3}" -f $Action, $jobs.Count, $Width, $LogDir

$clock = [Diagnostics.Stopwatch]::StartNew()
$results = Invoke-AcceptanceRun -Repo $Repo -Jobs $jobs -Width $Width -LogDir $LogDir -TimeoutSec $TimeoutSec -NoConfirm:$NoConfirm -FailFast:$FailFast -OnResult {
    param($r)
    $where = switch ($r.Class) { 'parallel' { "w$($r.Slot)" } default { $r.Class } }
    $phase = if ($r.Phase -eq 'confirm') { ' alone' } else { '' }
    "  [{0}{1}] {2,-8} {3}  ({4:N0}s)  {5}" -f $where, $phase, $r.Kind.ToUpper(), $r.Name, ($r.Ended - $r.Started).TotalSeconds, $r.Line
}
$clock.Stop()

$final = @(Get-AcceptanceFinal -Results $results)
$ranSeq = @($final | ForEach-Object { $_.Seq })
$notRun = @(for ($i = 0; $i -lt $jobs.Count; $i++) { if ($ranSeq -notcontains $i) { Split-Path -Leaf $jobs[$i].Script } })
$overlap = @(Test-AcceptanceOverlap -Results $results)
$busy = ($results | ForEach-Object { ($_.Ended - $_.Started).TotalSeconds } | Measure-Object -Sum).Sum

$summary = [pscustomobject]@{
    action = $Action; width = $Width; repo = $Repo
    # PS 5.1 under Stop turns git's stderr into a terminating error, so a -Repo
    # that is not a checkout (the harness's fixture) used to end the run here.
    commit = $(try { & { $ErrorActionPreference = 'Continue'; git -C $Repo rev-parse --short HEAD 2>$null } } catch { $null })
    wallSeconds = [int]$clock.Elapsed.TotalSeconds; scriptSeconds = [int]$busy
    build = $fresh.State; notRun = $notRun
    final = $final; runs = @($results | Select-Object Seq, Name, Class, Slot, Phase, Kind, Line, ExitCode,
            @{ n = 'Started'; e = { $_.Started.ToString('o') } }, @{ n = 'Ended'; e = { $_.Ended.ToString('o') } }, Log)
    scheduleViolations = $overlap
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $LogDir 'summary.json') -Encoding UTF8

foreach ($f in @($final | Where-Object { $_.ParallelSensitive })) {
    "PARALLEL-SENSITIVE {0}: {1} beside other scripts, {2} alone - add '# @parallel-unsafe' (or '# @timing-sensitive' if it measures time) to its header, or fix what it shares" -f $f.Name, $f.PoolKind, $f.AloneKind
}
foreach ($v in $overlap) { "SCHEDULE VIOLATION: $v" }

$red = @($final | Where-Object { $_.Kind -notin @('pass', 'skip') })
$counts = ($final | Group-Object Kind | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
if ($notRun.Count -gt 0) { $counts += " not-run=$($notRun.Count)" }
"ACCEPTANCE {0}: {1} in {2:N0}s wall ({3:N0}s of script time, width {4}) - {5}" -f $(if ($red.Count -eq 0 -and $overlap.Count -eq 0 -and $notRun.Count -eq 0) { 'GREEN' } else { 'RED' }),
    $final.Count, $clock.Elapsed.TotalSeconds, $busy, $Width, $counts
foreach ($r in $red) { "  RED {0} ({1}): {2}" -f $r.Name, $r.Kind, $r.Line }
if ($notRun.Count -gt 0) { "  NOT RUN (-FailFast stopped at the first red): {0}" -f ($notRun -join ', ') }
if ($overlap.Count -gt 0) { exit 3 }
exit ([int]($red.Count -gt 0 -or $notRun.Count -gt 0))
