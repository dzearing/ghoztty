# LaneVerdict.ps1 - the pure half of floor-lane.ps1's failure detail (T776).
#
# A floor run already prints everything a reader needs about a red lane: the
# log path on the line that launched it, and an `-- errors --` block under the
# lane's own verdict. The problem T776 recorded is WHERE: both sit hundreds of
# lines above `FLOOR SUMMARY`, so a caller that keeps only the tail - which is
# every caller under the context rule - keeps the word FAIL and loses the
# reason AND the pointer to it. The one-off agent FAIL of 2026-08-11 could
# therefore never be told from a flake.
#
# What lives here is everything that can be answered from a log file on disk,
# so test\win32\floor-lane-verdict-detail.ps1 can cover it without staging a
# real red lane. The printing is floor-lane.ps1's.

<#
.SYNOPSIS
Collects the failure detail of ONE red lane: its log path and its first errors.

.DESCRIPTION
Reads the `error:` lines out of THAT lane's log - not the console, which is the
whole point: a console tail cannot be attributed to a lane, and the T776 report
spent its evidence arguing about whether the visible errors belonged to the
lane the summary had scored red. A detail block built from the lane's own log
file cannot disagree with that lane's verdict.

`Total` counts every `error:` line in the log; `Errors` holds the first
`MaxErrors` of them, so the block stays short and the report can still say how
many were dropped. A missing or unreadable log is not an error here - the lane
may have died before writing one - and comes back with no errors and whatever
path was passed, because a path that does not exist is still the answer to
"where would it have been".
#>
function Get-LaneFailureDetail {
    param(
        [Parameter(Mandatory)][string]$LaneName,
        [string]$LogPath,
        [int]$MaxErrors = 6
    )
    $errors = @()
    $total = 0
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        foreach ($line in (Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
            if ($line -match 'error:') {
                $total++
                if ($errors.Count -lt $MaxErrors) { $errors += $line.TrimEnd() }
            }
        }
    }
    return [pscustomobject]@{
        Lane    = $LaneName
        LogPath = $LogPath
        Errors  = $errors
        Total   = $total
    }
}

<#
.SYNOPSIS
The token a lane contributes to the FLOOR SUMMARY line.

.DESCRIPTION
`agent#1=FAIL` told a reader keeping one line that something was wrong and
nothing about where to look. A red lane's token now carries its log path, so
the POINTER survives even a `Select-Object -Last 2` - the exact pipeline the
T776 turn had used. A green lane's token is unchanged: a summary line that
carried four paths on a clean run would be unreadable, and nobody needs the log
of a lane that passed.
#>
function Format-LaneSummaryToken {
    param(
        [Parameter(Mandatory)][string]$LaneName,
        [Parameter(Mandatory)][int]$Iteration,
        [Parameter(Mandatory)][string]$Result,
        [string]$Note = '',
        [string]$LogPath
    )
    $token = "$LaneName#${Iteration}=$Result$Note"
    if ($Result -ne 'PASS' -and $LogPath) { $token += " [log: $LogPath]" }
    return $token
}

<#
.SYNOPSIS
The failure-detail block printed immediately above FLOOR SUMMARY.

.DESCRIPTION
One group per red lane, each naming the lane, its log path and its first error
lines. Every line is attributed to the lane that produced it (criterion 2 of
T776): a reader can no longer wonder whether a visible error belongs to the
lane the summary scored red, because the block says so on every line.

Returns an empty array when nothing failed, so a green run prints nothing extra.
#>
function Format-FloorFailureDetail {
    param([object[]]$Details)

    $out = @()
    $groups = @($Details | Where-Object { $_ })
    if ($groups.Count -eq 0) { return $out }

    $out += ''
    $out += '-- FLOOR FAILURE DETAIL (read this, not the scrollback) --'
    foreach ($d in $groups) {
        $where = if ($d.LogPath) { $d.LogPath } else { '(no log was written)' }
        $out += "  lane $($d.Lane): $where"
        if ($d.Errors.Count -eq 0) {
            $out += "    lane $($d.Lane): no 'error:' line in that log - the lane died without one (crash, stall, or a kill)"
        }
        else {
            foreach ($e in $d.Errors) { $out += "    lane $($d.Lane): $e" }
            $dropped = $d.Total - $d.Errors.Count
            if ($dropped -gt 0) {
                $out += "    lane $($d.Lane): ... $dropped more 'error:' line(s) in that log"
            }
        }
    }
    return $out
}
