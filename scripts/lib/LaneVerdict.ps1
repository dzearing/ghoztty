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

`FailedTest` and `Trace` are T1662's half, and they exist because the `error:`
filter above can keep a line that names the wrong cause. Zig's build runner
prints `error: '<test>' failed: <text>` where `<text>` is whatever arrived on
stderr at that moment - and every test in one binary shares one stderr, so the
text is routinely a note from a test that PASSED. The REAL cause is the error
return trace, which carries no `error:` prefix and is therefore dropped by the
only filter this block had. On 2026-09-18 that cost T1645 four turns chasing
`[tripwire] (warn): untripped point=read` - emitted by `src/tripwire.zig`'s own
passing test - while `error.WaitForTimeout at ViewerPane.zig:8237` sat unread in
the same logs. So when a `failed:` line is present, `FailedTest` carries the test
it names and `Trace` carries the trace frames from the same log that name THAT
test. An empty `Trace` beside a non-null `FailedTest` is itself the finding:
nothing in the log blames the test the runner blamed.

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
        [string[]]$Diagnostic = @(),
        [int]$MaxTraceLines = 12
    )
    $errors = @()
    $total = 0
    $lines = @()
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if ($line -match 'error:') {
                $total++
                if ($errors.Count -lt $MaxErrors) { $errors += $line.TrimEnd() }
            }
        }
    }
    $failedTest = Get-LaneFailedTestName -Lines $lines
    $trace = @()
    $traceTruncated = 0
    if ($failedTest) {
        $found = @(Get-LaneErrorReturnTrace -Lines $lines -TestName $failedTest -MaxLines $MaxTraceLines)
        $trace = @($found | Where-Object { $_ -ne '__TRUNCATED__' })
        if ($found -contains '__TRUNCATED__') { $traceTruncated = 1 }
    }
    return [pscustomobject]@{
        Lane           = $LaneName
        LogPath        = $LogPath
        Errors         = $errors
        Total          = $total
        Result         = $Result
        Diagnostic     = @($Diagnostic)
        FailedTest     = $failedTest
        Trace          = $trace
        TraceTruncated = [bool]$traceTruncated
    }
}

<#
.SYNOPSIS
The test name out of zig's `error: '<test>' failed: <text>` line, or $null.

.DESCRIPTION
Only the NAME is taken. The text after `failed:` is deliberately ignored here:
it is whatever was on the shared stderr when the runner gave up, which is the
entire defect T1662 records. A log with no such line answers $null, and the
caller then prints exactly what it printed before this existed.
#>
function Get-LaneFailedTestName {
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ($line -match "^error: '(?<name>.+?)' failed:") { return $Matches['name'] }
    }
    return $null
}

<#
.SYNOPSIS
The error return trace frames in a lane log that name a given test.

.DESCRIPTION
A zig error return trace is groups of three lines - a frame
(`<file>:<line>:<col>: 0x<addr> in <symbol> (<obj>)`), the source line, and a
caret. The frame that names the failing test is the BOTTOM of its trace, so the
search is: find the last frame whose symbol is that test, then walk backwards
over the contiguous groups above it to the origin of the error. The caret lines
are dropped - re-indented under a `lane <name>:` prefix they no longer line up
with anything, so they are only cost.

The test's qualified name in the `failed:` line (`apprt.win32.ViewerPane.test.
host floor: ...`) and its symbol in a frame (`test.host floor: ...`) differ by
the module path, so the marker is rebuilt from the last `.test.` / `.decltest.`
segment.

The LAST matching frame wins because a handled error earlier in the same test
prints a trace too, and the one that ended the run is the one at the bottom of
the log. `MaxLines` bounds what comes back; a truncated trace carries a
`__TRUNCATED__` sentinel as its final element so the caller can say so.
#>
function Get-LaneErrorReturnTrace {
    param(
        [string[]]$Lines,
        [string]$TestName,
        [int]$MaxLines = 12
    )
    $out = @()
    $all = @($Lines)
    if ($all.Count -eq 0 -or -not $TestName) { return $out }

    $marker = $TestName
    if ($TestName -match '\.(decltest)\.(?<short>.+)$') { $marker = "decltest.$($Matches['short'])" }
    elseif ($TestName -match '\.test\.(?<short>.+)$') { $marker = "test.$($Matches['short'])" }

    $frameRe = '^.+:\d+:\d+: 0x[0-9a-fA-F]+ in (?<sym>.+) \([^)]+\)\s*$'
    $isFrame = {
        param($idx)
        if ($idx -lt 0 -or $idx -ge $all.Count) { return $false }
        return ($all[$idx] -match $frameRe)
    }

    $anchor = -1
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if ($all[$i] -match $frameRe -and $Matches['sym'] -eq $marker) { $anchor = $i; break }
    }
    if ($anchor -lt 0) { return $out }

    # Walk back to the top of the contiguous trace block. A line belongs to it
    # when it is a frame, the source line under a frame, or the caret under one.
    $start = $anchor
    for ($j = $anchor - 1; $j -ge 0; $j--) {
        if ((& $isFrame $j) -or (& $isFrame ($j - 1)) -or (& $isFrame ($j - 2))) { $start = $j }
        else { break }
    }

    # The anchor's own source line, when one follows it.
    $end = $anchor
    if (($anchor + 1) -lt $all.Count -and -not (& $isFrame ($anchor + 1))) { $end = $anchor + 1 }

    for ($k = $start; $k -le $end; $k++) {
        $line = $all[$k]
        if ($line -match '^\s*\^\s*$') { continue }
        if ($out.Count -ge $MaxLines) { $out += '__TRUNCATED__'; break }
        $out += $line.TrimEnd()
    }
    return $out
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
        # T1662: the `error: '<test>' failed: <text>` line above names the test
        # correctly and the CAUSE only by accident - the text is whatever was on
        # the binary's shared stderr at that moment. The error return trace is
        # the part that is actually about the failure, and nothing in it matches
        # `error:`, so until now none of it survived into this block.
        $failedTest = if ($d.PSObject.Properties['FailedTest']) { $d.FailedTest } else { $null }
        if ($failedTest) {
            $trace = if ($d.PSObject.Properties['Trace']) { @($d.Trace) } else { @() }
            if ($trace.Count -gt 0) {
                $out += "    lane $($d.Lane): -- error return trace for '$failedTest' (the 'failed:' text above is shared stderr, not necessarily the cause) --"
                foreach ($line in $trace) { $out += "    lane $($d.Lane): $line" }
                if ($d.PSObject.Properties['TraceTruncated'] -and $d.TraceTruncated) {
                    $out += "    lane $($d.Lane): ... trace truncated; the rest is in that log"
                }
            }
            else {
                $out += "    lane $($d.Lane): no error return trace naming '$failedTest' in that log - the 'failed:' text above is the only clue, and it may belong to a different test"
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
