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

`Result` and `Diagnostic` are T815's half. A wedged lane writes no `error:`
line at all, so the block above could only say "the lane died without one
(crash, stall, or a kill)" - three different answers offered as one, under a
verdict that already knew which. `Result` carries that verdict down, and
`Diagnostic` carries the watchdog's own block (process tree, thread wait
reasons, log tail) - the thing floor-lane.ps1 exists to print and which, in a
`-Lane all` run, is printed thousands of lines above the summary and therefore
kept by nobody.
#>
function Get-LaneFailureDetail {
    param(
        [Parameter(Mandatory)][string]$LaneName,
        [string]$LogPath,
        [int]$MaxErrors = 6,
        [string]$Result = 'FAIL',
        [string[]]$Diagnostic = @()
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
        Lane       = $LaneName
        LogPath    = $LogPath
        Errors     = $errors
        Total      = $total
        Result     = $Result
        Diagnostic = @($Diagnostic)
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
One group per red lane, each naming the lane, the VERDICT that made it red, its
log path and its first error lines. Every line is attributed to the lane that
produced it (criterion 2 of T776): a reader can no longer wonder whether a
visible error belongs to the lane the summary scored red, because the block says
so on every line.

A wedged or capped lane gets its watchdog diagnostic replayed here (T815).
That block - the process tree, the thread wait reasons, the log tail - is
printed the moment the wedge is detected, which in a `-Lane all` run is
thousands of lines above the summary and is therefore exactly what a
context-rule caller drops. Replaying it under the verdict is what makes a STALL
readable as "wedged waiting on X" rather than as "slow": on 2026-08-12 the agent
lane STALLed as the third lane of a run and passed alone minutes later, and
nothing kept said which.

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
        # The verdict leads the group. `FAIL`, `STALL` and `TIMEOUT` are three
        # different problems with three different first moves, and until T815
        # this block spelled all three "the lane died without one (crash, stall,
        # or a kill)" - an answer that repeats the question.
        $verdict = if ($d.PSObject.Properties['Result'] -and $d.Result) { $d.Result } else { 'FAIL' }
        $out += "  lane $($d.Lane): $verdict - $where"
        $out += "    lane $($d.Lane): $(Get-LaneVerdictMeaning -Result $verdict)"
        if ($d.Errors.Count -eq 0) {
            if ($verdict -eq 'FAIL') {
                $out += "    lane $($d.Lane): no 'error:' line in that log - the lane died without one (a crash or a kill)"
            }
        }
        else {
            foreach ($e in $d.Errors) { $out += "    lane $($d.Lane): $e" }
            $dropped = $d.Total - $d.Errors.Count
            if ($dropped -gt 0) {
                $out += "    lane $($d.Lane): ... $dropped more 'error:' line(s) in that log"
            }
        }
        $diag = @()
        # The `====` rules are console furniture: they separate the block from
        # the scrollback around it, and re-indented under a lane prefix they
        # only cost lines a caller is keeping a budget of.
        if ($d.PSObject.Properties['Diagnostic']) {
            $diag = @($d.Diagnostic | Where-Object { $null -ne $_ -and $_ -notmatch '^=+$' })
        }
        if ($diag.Count -gt 0) {
            $out += "    lane $($d.Lane): -- watchdog diagnostic, replayed from where it was taken --"
            foreach ($line in $diag) { $out += "    lane $($d.Lane): $line" }
        }
        elseif ($verdict -eq 'STALL' -or $verdict -eq 'TIMEOUT') {
            # A wedge with no diagnostic is itself a finding: the watchdog is
            # supposed to take one before it kills anything.
            $out += "    lane $($d.Lane): (no watchdog diagnostic was captured - that is a floor-lane.ps1 defect, not a slow test)"
        }
    }
    return $out
}

<#
.SYNOPSIS
One line saying what a lane verdict MEANS, in the words a reader needs.

.DESCRIPTION
T815's title is the complaint: a STALL that cannot be told from a slow lane.
The verdict already knows the difference - a STALL is a measured zero-CPU,
zero-output window, not a timeout - so the block says it instead of leaving the
reader to remember which of the three exit codes means what.
#>
function Get-LaneVerdictMeaning {
    param([string]$Result)
    switch ($Result) {
        'STALL' { return 'WEDGED: no CPU and no output for the whole stall window - this is a hang, not a slow test. The tree below was sampled before anything was killed.' }
        'TIMEOUT' { return 'WALL-CLOCK CAP: the lane was still making progress but ran past -TimeoutSeconds - this one may really be slow rather than wedged.' }
        'FAIL' { return 'the lane exited non-zero; the errors below come from its own log.' }
        default { return "the lane ended $Result." }
    }
}
