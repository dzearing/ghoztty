# DigestState.ps1 - is today's daily digest owed? (T1223, T1262)
#
# go.md step 0.5 asks for one digest a day. Two readers ask the question:
# go-loop-health.ps1 (`digest=`, for a human or the supervisor) and
# go-loop-exec.ps1 claim (for the turn that owes it). They answer it here, in
# one place, so the two can never disagree about what "owed" means.
#
# Four states:
#   present  - today's file is on disk with all three categories
#   partial  - today's file is on disk but lacks one or more of the H2
#              categories steps 0.5-0.7 each write (T1279); Field names them,
#              e.g. `partial:task-triage,feature-ideas`
#   missing  - past 05:00, the loop was turning today, and there is no file
#   not-due  - before 05:00, or the loop did not turn today at all (a box that
#              was off overnight, or a loop stopped on purpose, owes nothing;
#              and the standing rule is never to backfill a missed day)
#
# -Turning says "the loop is turning right now" without consulting the lock
# history. The claim passes it: a claim IS a turn, so past 05:00 the digest is
# owed whether or not this morning's history has a line yet.
#
# This never WRITES a digest, and must not: a generated placeholder turns the
# light green while destroying the thing the light measures.
#
# Functions only, no load-time side effects. ASCII only, PS 5.1 compatible.

function Get-DigestState {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [datetime]$AsOf = [datetime]::MinValue,
        [switch]$Turning
    )
    $sections = @(
        [pscustomobject]@{ Heading = 'Commentary'; Slug = 'commentary' }
        [pscustomobject]@{ Heading = 'Task triage'; Slug = 'task-triage' }
        [pscustomobject]@{ Heading = 'Feature ideas'; Slug = 'feature-ideas' }
    )
    if ($AsOf -eq [datetime]::MinValue) { $AsOf = Get-Date }
    $date = $AsOf.ToString('yyyy-MM-dd')
    $rel = "docs\design\windows-parity-digests\$date.md"
    $state = 'not-due'
    $missingSections = @()
    $abs = Join-Path $Repo $rel
    if (Test-Path -LiteralPath $abs) {
        # T1279: the file is three steps' work (0.5 Commentary, 0.6 Task
        # triage, 0.7 Feature ideas), each its own H2. Existence alone said
        # `present` over the 2026-09-01 digest that held only Commentary.
        $text = ''
        try { $text = [System.IO.File]::ReadAllText($abs) } catch { $text = '' }
        foreach ($s in $sections) {
            if ($text -notmatch ('(?im)^##[ \t]+' + [regex]::Escape($s.Heading) + '[ \t]*\r?$')) {
                $missingSections += $s
            }
        }
        $state = if ($missingSections.Count -gt 0) { 'partial' } else { 'present' }
    } else {
        $dueAt = $AsOf.Date.AddHours(5)
        if ($AsOf -ge $dueAt) {
            # "Did the loop turn today?" is answered from the lock history, not
            # the live lock: the lock says who holds it NOW, and a loop that ran
            # this morning and then died would read as owing nothing.
            $aliveToday = [bool]$Turning
            $histPath = Join-Path $Repo 'temp\go-loop-history.jsonl'
            if (-not $aliveToday -and (Test-Path -LiteralPath $histPath)) {
                foreach ($line in @(Get-Content -LiteralPath $histPath -Tail 500 -ErrorAction SilentlyContinue)) {
                    if (-not $line) { continue }
                    $at = $null
                    try { $at = [datetime]::Parse([string](($line | ConvertFrom-Json).at)) } catch { continue }
                    if ($at -ge $dueAt -and $at -le $AsOf) { $aliveToday = $true; break }
                }
            }
            if ($aliveToday) { $state = 'missing' }
        }
    }
    $field = $state
    if ($state -eq 'partial') { $field = 'partial:' + (@($missingSections | ForEach-Object { $_.Slug }) -join ',') }
    return [pscustomobject]@{
        State    = $state
        Field    = $field
        Date     = $date
        Path     = $rel
        Missing  = @($missingSections | ForEach-Object { $_.Heading })
    }
}
