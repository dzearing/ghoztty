# DigestState.ps1 - is today's daily digest owed? (T1223, T1262)
#
# go.md step 0.5 asks for one digest a day. Two readers ask the question:
# go-loop-health.ps1 (`digest=`, for a human or the supervisor) and
# go-loop-exec.ps1 claim (for the turn that owes it). They answer it here, in
# one place, so the two can never disagree about what "owed" means.
#
# Three states:
#   present  - today's file is on disk
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
    if ($AsOf -eq [datetime]::MinValue) { $AsOf = Get-Date }
    $date = $AsOf.ToString('yyyy-MM-dd')
    $rel = "docs\design\windows-parity-digests\$date.md"
    $state = 'not-due'
    if (Test-Path -LiteralPath (Join-Path $Repo $rel)) {
        $state = 'present'
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
    return [pscustomobject]@{ State = $state; Date = $date; Path = $rel }
}
