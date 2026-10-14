<#
.SYNOPSIS
  The pre-flight gate for an upstream pull stage (S1..S6): refuse to start a
  stage the repo is not ready for.

.DESCRIPTION
  T1026. docs\design\windows-parity-upstream-pull-plan.md stages the upstream
  pull as six merges, each landing on a scratch branch and gated AFTER the merge
  ("Stage sequence and the gate after each"). Nothing gated the moment BEFORE
  one. `scripts\upstream-remote.ps1 check` - the assertion that every sha the
  plan pins still resolves and is anchored - had no caller but its own
  acceptance script: the claim runs `ensure`, which is never fatal on purpose so
  an offline box cannot wedge the loop, and `parity-tasks.ps1 validate` rightly
  does not know about it, since a turn that touches no merge machinery should
  not fail because GitHub is unreachable. The moment it DOES matter is the start
  of a stage, and that moment had no command. This is that command.

  It is a gate, never a starter. Whether an upstream pull happens at all is the
  user's call (D80); this script cuts no branch, merges nothing and fetches
  nothing. It answers one question - may stage <S> begin from this HEAD? - and
  exits 0 only when every check below passes:

    P1 stage     the plan's "Merge shape" table names the stage, and the table
                 is contiguous (each stage starts where the previous one ended),
                 so the range being merged is the one the plan measured
    P2 tree      the working tree is clean - a stage's diff must be the merge
                 and nothing a dead turn left behind
    P3 pushed    HEAD is on its upstream branch, so the stage's base exists
                 somewhere other than this box
    P4 upstream  `upstream-remote.ps1 check` exits 0: the remote is wired, and
                 every plan sha resolves and is anchored by a tag
    P5 sequence  the stage's FROM sha is already in HEAD (the previous stage
                 landed - for S1 that is the fork point) and its TO sha is not
                 (this stage has not been taken already)
    P6 identity  `fork-identity.ps1 check` is clean BEFORE the merge, so every
                 finding after it is the merge's and nobody else's
    P7 guards    `guard-due.ps1 check` exits 0: no acceptance harness is owed a
                 run against the base, so the post-merge guard report names only
                 what the merge itself made due
    P8 floor     `floor-lane.ps1 -Lane all` is green on the base. The expensive
                 one, so it runs last and only when P1..P7 passed: a floor run
                 over a base that is already refused buys nothing

  Each check prints one line - `ok`, `FAIL` with the reason, or `skip` naming
  the hatch that skipped it - and the verdict is PREFLIGHT OK or PREFLIGHT
  REFUSED. A skipped check is never an ok: the verdict names every hatch used.

  preflight  Run the checks for -Stage. Exit 0 OK, 1 REFUSED, 2 usage.
  list       Print the stage table as the plan defines it, plus each stage's
             state against HEAD (taken / next / later). Always exit 0 unless the
             plan cannot be parsed.

  Acceptance: test\win32\upstream-stage.ps1.

.EXAMPLE
  powershell -NoProfile -File scripts\upstream-stage.ps1 list
  powershell -NoProfile -File scripts\upstream-stage.ps1 preflight -Stage S1
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('preflight', 'list')]
    [string]$Action = 'list',

    [string]$Stage,

    [string]$Repo,

    # Where the sibling gate scripts live. Defaults to this script's directory;
    # the acceptance harness points it at stubs so the ORDER and the refusal
    # logic can be asserted without a twenty-minute floor per case.
    [string]$ScriptsDir,

    # Hatches. Each one is named in the verdict, never silent.
    [switch]$NoFloor,
    [switch]$NoGuardDue,
    [switch]$NoForkIdentity,
    [switch]$NoPushCheck
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $ScriptsDir) { $ScriptsDir = $PSScriptRoot }

$PlanRelative = 'docs\design\windows-parity-upstream-pull-plan.md'

# Same capture shape as upstream-remote.ps1 (T883): per-record, exit code is the
# answer, stderr is a normal channel for "no such ref" and must not throw.
function Invoke-Git {
    param([string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $Repo @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n").Trim() }
}

# Runs a sibling gate script as a child and keeps its last few lines, so a
# refusal names what the child said rather than only that it said no.
function Invoke-Gate {
    param([string]$Script, [string[]]$GateArgs)
    $path = Join-Path $ScriptsDir $Script
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Code = 127; All = @("missing: $path"); Tail = @("missing: $path") }
    }
    $ErrorActionPreference = 'Continue'
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $path @GateArgs 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; All = $out; Tail = @($out | Where-Object { $_.Trim() } | Select-Object -Last 4) }
}

# The "Merge shape" table: `| S1 | \`063ac3ecc..c4c9e945a\` (...) | ...`. The
# plan is the source on purpose, for the same reason upstream-remote.ps1 reads
# its sha list from it: a re-cut stage is covered the day it is written there.
function Get-Stages {
    $path = Join-Path $Repo $PlanRelative
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rows = @()
    foreach ($line in (Get-Content -LiteralPath $path)) {
        $m = [regex]::Match($line, '^\|\s*\**(S\d+)\**\s*\|\s*`([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})`')
        if ($m.Success) {
            $rows += [pscustomobject]@{ Name = $m.Groups[1].Value; From = $m.Groups[2].Value; To = $m.Groups[3].Value }
        }
    }
    return @($rows)
}

function Test-InHead {
    param([string]$Sha)
    return ((Invoke-Git @('merge-base', '--is-ancestor', $Sha, 'HEAD')).Code -eq 0)
}

function Test-Resolves {
    param([string]$Sha)
    return ((Invoke-Git @('cat-file', '-e', "$Sha^{commit}")).Code -eq 0)
}

$stages = @(Get-Stages)
if ($stages.Count -eq 0) {
    "UPSTREAM-STAGE: no stage table found in $PlanRelative (rows shaped '| S1 | ``from..to`` |')"
    exit 2
}

# Contiguity is a property of the plan, not of HEAD, so both verbs report it.
$gaps = @()
for ($i = 1; $i -lt $stages.Count; $i++) {
    if ($stages[$i].From -ne $stages[$i - 1].To) {
        $gaps += "$($stages[$i].Name) starts at $($stages[$i].From) but $($stages[$i - 1].Name) ends at $($stages[$i - 1].To)"
    }
}

switch ($Action) {

    'list' {
        $nextMarked = $false
        foreach ($s in $stages) {
            $state = '?'
            if ((Test-Resolves $s.To) -and (Test-InHead $s.To)) { $state = 'taken' }
            elseif (-not $nextMarked) { $state = 'next'; $nextMarked = $true }
            else { $state = 'later' }
            "{0,-3} {1}..{2}  {3}" -f $s.Name, $s.From, $s.To, $state
        }
        foreach ($g in $gaps) { "GAP $g" }
        exit 0
    }

    'preflight' {
        if (-not $Stage) {
            "UPSTREAM-STAGE: preflight needs -Stage (one of $(($stages | ForEach-Object { $_.Name }) -join ', '))"
            exit 2
        }
        $want = $Stage.ToUpperInvariant()
        $row = $stages | Where-Object { $_.Name -eq $want } | Select-Object -First 1

        $fails = @()
        $hatches = @()
        function Report([string]$Id, [string]$Verdict, [string]$Text) {
            "  {0,-11} {1,-4} {2}" -f $Id, $Verdict, $Text
        }

        "UPSTREAM-STAGE PREFLIGHT $want"
        "  (a gate, not a starter: whether to pull upstream at all is the user's call - D80)"

        # P1 -----------------------------------------------------------------
        if (-not $row) {
            Report 'P1 stage' 'FAIL' "the plan has no stage '$want' (it defines $(($stages | ForEach-Object { $_.Name }) -join ', '))"
            $fails += 'P1'
        } elseif ($gaps.Count -gt 0) {
            Report 'P1 stage' 'FAIL' "the plan's stage table is not contiguous: $($gaps -join '; ')"
            $fails += 'P1'
        } else {
            Report 'P1 stage' 'ok' "$($row.Name) = $($row.From)..$($row.To)"
        }

        # P2 -----------------------------------------------------------------
        $dirty = @((Invoke-Git @('status', '--porcelain', '--untracked-files=normal')).Lines | Where-Object { $_ })
        if ($dirty.Count -gt 0) {
            $shown = ($dirty | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ', '
            Report 'P2 tree' 'FAIL' "$($dirty.Count) dirty path(s): $shown$(if ($dirty.Count -gt 3) { ', ...' })"
            $fails += 'P2'
        } else {
            Report 'P2 tree' 'ok' 'clean'
        }

        # P3 -----------------------------------------------------------------
        if ($NoPushCheck) {
            Report 'P3 pushed' 'skip' '-NoPushCheck'
            $hatches += '-NoPushCheck'
        } else {
            $up = Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if ($up.Code -ne 0 -or -not $up.Text) {
                Report 'P3 pushed' 'FAIL' 'the current branch has no upstream branch to compare against'
                $fails += 'P3'
            } else {
                $ahead = (Invoke-Git @('rev-list', '--count', '@{u}..HEAD')).Text
                if ($ahead -and [int]$ahead -gt 0) {
                    Report 'P3 pushed' 'FAIL' "HEAD is $ahead commit(s) ahead of $($up.Text) - push first"
                    $fails += 'P3'
                } else {
                    Report 'P3 pushed' 'ok' "HEAD is on $($up.Text)"
                }
            }
        }

        # P4 -----------------------------------------------------------------
        $u = Invoke-Gate 'upstream-remote.ps1' @('check', '-Repo', $Repo)
        if ($u.Code -eq 0) {
            Report 'P4 upstream' 'ok' (($u.Tail | Select-Object -First 1) -replace '^\s+', '')
        } else {
            Report 'P4 upstream' 'FAIL' "upstream-remote.ps1 check exited $($u.Code)"
            foreach ($t in $u.Tail) { "                   $($t.Trim())" }
            $fails += 'P4'
        }

        # P5 -----------------------------------------------------------------
        if ($row) {
            if (-not (Test-Resolves $row.From) -or -not (Test-Resolves $row.To)) {
                Report 'P5 sequence' 'FAIL' "$($row.From) or $($row.To) does not resolve here (P4 says why)"
                $fails += 'P5'
            } elseif (-not (Test-InHead $row.From)) {
                $prev = $stages | Where-Object { $_.To -eq $row.From } | Select-Object -First 1
                $what = if ($prev) { "$($prev.Name) has not landed" } else { 'the stage base is not in HEAD' }
                Report 'P5 sequence' 'FAIL' "$($row.From) is not in HEAD - $what"
                $fails += 'P5'
            } elseif (Test-InHead $row.To) {
                Report 'P5 sequence' 'FAIL' "$($row.To) is already in HEAD - $($row.Name) was taken"
                $fails += 'P5'
            } else {
                Report 'P5 sequence' 'ok' "$($row.From) in HEAD, $($row.To) not yet"
            }
        } else {
            Report 'P5 sequence' 'skip' 'no stage row (P1)'
        }

        # P6 -----------------------------------------------------------------
        if ($NoForkIdentity) {
            Report 'P6 identity' 'skip' '-NoForkIdentity'
            $hatches += '-NoForkIdentity'
        } else {
            $f = Invoke-Gate 'fork-identity.ps1' @('check', '-Path', $Repo)
            if ($f.Code -eq 0) {
                Report 'P6 identity' 'ok' 'no upstream identity in the base'
            } else {
                Report 'P6 identity' 'FAIL' "fork-identity.ps1 check exited $($f.Code) on the base"
                foreach ($t in $f.Tail) { "                   $($t.Trim())" }
                $fails += 'P6'
            }
        }

        # P7 -----------------------------------------------------------------
        if ($NoGuardDue) {
            Report 'P7 guards' 'skip' '-NoGuardDue'
            $hatches += '-NoGuardDue'
        } else {
            $g = Invoke-Gate 'guard-due.ps1' @('check', '-Repo', $Repo)
            if ($g.Code -eq 0) {
                Report 'P7 guards' 'ok' 'no harness owed a run'
            } else {
                Report 'P7 guards' 'FAIL' "guard-due.ps1 check exited $($g.Code) - run what it names first"
                # The DUE lines are the useful part; the tail is CURRENT rows.
                $due = @($g.All | Where-Object { $_ -match '^\s*GUARD DUE' })
                if ($due.Count -eq 0) { $due = $g.Tail }
                foreach ($t in $due) { "                   $($t.Trim())" }
                $fails += 'P7'
            }
        }

        # P8 -----------------------------------------------------------------
        if ($NoFloor) {
            Report 'P8 floor' 'skip' '-NoFloor'
            $hatches += '-NoFloor'
        } elseif ($fails.Count -gt 0) {
            Report 'P8 floor' 'skip' "not run: the base is already refused ($($fails -join ', '))"
        } else {
            $fl = Invoke-Gate 'floor-lane.ps1' @('-Lane', 'all', '-Repo', $Repo)
            if ($fl.Code -eq 0) {
                Report 'P8 floor' 'ok' 'floor-lane -Lane all green'
            } else {
                Report 'P8 floor' 'FAIL' "floor-lane.ps1 -Lane all exited $($fl.Code)"
                foreach ($t in $fl.Tail) { "                   $($t.Trim())" }
                $fails += 'P8'
            }
        }

        $hatchNote = ''
        if ($hatches.Count -gt 0) { $hatchNote = " (hatches used: $($hatches -join ' '))" }
        if ($fails.Count -eq 0) {
            "PREFLIGHT OK $want$hatchNote"
            "  next: cut the scratch branch and merge $($row.To), then run the gate after the stage (plan: 'Stage sequence and the gate after each')"
            exit 0
        }
        "PREFLIGHT REFUSED $want - $($fails -join ', ')$hatchNote"
        exit 1
    }
}
