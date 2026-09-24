<#
.SYNOPSIS
  Acceptance test for scripts\lib\LaneVerdict.ps1 and floor-lane.ps1's
  failure-detail block (T776).

.DESCRIPTION
  On 2026-08-11 a `-Lane all` run reported `agent#1=FAIL` and passed twice
  after, on unchanged code - and the reason was unrecoverable, because the
  caller had kept only the tail and everything that explained the red (the log
  path, the errors) had been printed hundreds of lines earlier. A floor whose
  failures cannot be read teaches the next reader to shrug at red.

  The rule this harness holds: WHATEVER a caller keeps of the tail, a red run
  names the lane, its VERDICT, its log path, and its first errors - and a
  WEDGED lane also carries the watchdog diagnostic that says wedged rather than
  slow (T815). Arms 1-6 drive the pure library against planted logs; arms 7-11
  are the wiring, including a REAL red run driven through `-Command`, whose last
  few lines are then checked the way a context-rule caller would keep them;
  arms 12-19 do both halves again for a STALL, ending on a REAL wedge staged
  with `waitfor` on a signal that never arrives. Arms 28-37 hold the CRASH
  verdict (T955): a lane whose test binary died says CRASH, not FAIL, in the
  LANE line and the summary alike, and still exits 1.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\LaneVerdict.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$Sandbox = Join-Path $env:TEMP ("lane-verdict-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

try {
    # ---- arms 1-4: the pure collector ---------------------------------------

    # Verbatim shapes from the T776 report.
    $log1 = Join-Path $Sandbox 'agent.log'
    @(
        "install zig build",
        "error: 'apprt.win32.ViewerPane.test.host floor: a real controller on a real window, on this box' failed: error.WaitForTimeout",
        "error: while executing test 'benchmark.OscParser.decltest.OscParser', the following test command failed:",
        "error: the following build command failed with exit code 1:",
        "error: four",
        "error: five",
        "error: six",
        "error: seven"
    ) | Set-Content -LiteralPath $log1 -Encoding ascii

    $d1 = Get-LaneFailureDetail -LaneName 'agent' -LogPath $log1 -MaxErrors 3
    Check 'the detail names the lane it was collected for' ($d1.Lane -eq 'agent') $d1.Lane
    Check 'the detail carries the log path' ($d1.LogPath -eq $log1) $d1.LogPath
    Check 'it keeps only the first MaxErrors error lines' ($d1.Errors.Count -eq 3) ($d1.Errors -join ' | ')
    Check 'but counts every one of them, so the block can say how many it dropped' `
        ($d1.Total -eq 7) $d1.Total

    # A lane that died before writing a log is not an error here: the verdict
    # still has to be printable, and "no log" is itself the answer.
    $dMissing = Get-LaneFailureDetail -LaneName 'win32' -LogPath (Join-Path $Sandbox 'nope.log')
    Check 'a missing log yields a printable detail rather than throwing' `
        ($dMissing.Errors.Count -eq 0 -and $dMissing.Lane -eq 'win32')

    # ---- arm 5-6: the summary token ----------------------------------------

    $green = Format-LaneSummaryToken -LaneName 'none' -Iteration 1 -Result 'PASS' -LogPath $log1
    Check 'a green lane token is unchanged - no path noise on a clean run' `
        ($green -eq 'none#1=PASS') $green

    $red = Format-LaneSummaryToken -LaneName 'agent' -Iteration 1 -Result 'FAIL' `
        -Note ' [alone: PASS alone]' -LogPath $log1
    Check 'a red lane token carries the log path, so the POINTER survives -Last 2' `
        ($red -match '^agent#1=FAIL \[alone: PASS alone\] \[log: ') $red

    # ---- arm 7-9: the block ------------------------------------------------

    $block = @(Format-FloorFailureDetail -Details @($d1))
    Check 'a green run prints no failure block at all' `
        (@(Format-FloorFailureDetail -Details @()).Count -eq 0)
    Check 'the block names the log path' (($block -join "`n") -match [regex]::Escape($log1)) ($block -join "`n")
    Check 'the block says how many error lines it dropped' `
        (($block -join "`n") -match "4 more 'error:' line") ($block -join "`n")

    # THE RULE for criterion 2: every line of the block is attributed to the
    # lane that produced it. An unattributed console line is what the T776
    # report spent its evidence arguing about.
    $body = @($block | Where-Object { $_ -match 'error:|no log' })
    $unattributed = @($body | Where-Object { $_ -notmatch 'lane agent:' })
    Check 'every error line in the block says which lane wrote it' `
        ($unattributed.Count -eq 0) ($unattributed -join ' | ')

    # ---- arm 10-11: the wiring, on a REAL red run ---------------------------

    $floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
    $src = Get-Content -LiteralPath $floor -Raw
    Check 'floor-lane dot-sources the library' ($src -match 'lib.LaneVerdict\.ps1')

    # A command that fails and writes an `error:` line: the cheapest real red
    # lane there is, and the one shape a harness can stage deterministically.
    $cmd = '(echo error: staged red for T776 verdict detail&& exit 1)'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Command $cmd -MinFreeGB 0 -NoCatch 2>&1 |
        ForEach-Object { $_.ToString() }

    # Exactly the pipeline the T776 turn used, and the whole point of the task:
    # what does a caller keeping only the tail actually keep?
    $tail = ($out | Select-Object -Last 12) -join "`n"
    Check 'the tail a context-rule caller keeps still names the failing log' `
        ($tail -match '\[log: .+\.log\]') $tail
    Check 'the tail still carries the error text itself' `
        ($tail -match 'staged red for T776') $tail
    Check 'and the run is still red' (($out -join "`n") -match 'FLOOR SUMMARY: command=FAIL') ($out -join "`n")

    # ---- arms 12-16: the STALL half, on the pure library (T815) -------------

    # A wedged lane writes no `error:` line, so before T815 its whole detail
    # block was one sentence offering three answers at once: "crash, stall, or
    # a kill". The verdict already knew which.
    $stallLog = Join-Path $Sandbox 'agent-stall.log'
    'install zig build' | Set-Content -LiteralPath $stallLog -Encoding ascii
    $diag = @(
        '==============================================================',
        'FLOOR LANE DIAGNOSTIC (lane agent): WEDGED (no CPU and no output for 421s) after 763s',
        '==============================================================',
        '-- process tree --',
        '  pid=1234    ghoztty-agent-test.exe           cpu=    12.5s',
        '-- threads of the test binaries (state / wait reason) --',
        '    tid=99     state=5   waitReason=13  userMs=0'
    )
    $dStall = Get-LaneFailureDetail -LaneName 'agent' -LogPath $stallLog -Result 'STALL' -Diagnostic $diag
    Check 'the detail carries the verdict that made the lane red' ($dStall.Result -eq 'STALL') $dStall.Result
    Check 'the detail carries the watchdog diagnostic' ($dStall.Diagnostic.Count -eq $diag.Count) $dStall.Diagnostic.Count

    $sb = @(Format-FloorFailureDetail -Details @($dStall)) -join "`n"
    Check 'the STALL block says WEDGED, so a hang is not read as a slow test' `
        ($sb -match 'WEDGED: no CPU and no output') $sb
    Check 'the STALL block no longer offers crash-stall-or-kill as one answer' `
        ($sb -notmatch 'crash, stall, or a kill') $sb
    Check 'the STALL block replays the thread wait reason the watchdog sampled' `
        ($sb -match 'waitReason=13') $sb
    $stallBody = @(Format-FloorFailureDetail -Details @($dStall) | Where-Object { $_ -match '^\s{4}' })
    $stallUnattributed = @($stallBody | Where-Object { $_ -notmatch 'lane agent:' })
    Check 'every replayed diagnostic line says which lane it describes' `
        ($stallUnattributed.Count -eq 0) ($stallUnattributed -join ' | ')

    # A wedge with NO diagnostic is itself a finding - the watchdog is supposed
    # to take one before it kills anything - and must not be printed as if the
    # lane had simply been quiet.
    $dNoDiag = Get-LaneFailureDetail -LaneName 'win32' -LogPath $stallLog -Result 'STALL'
    Check 'a wedge with no diagnostic is reported as a floor-lane defect' `
        ((@(Format-FloorFailureDetail -Details @($dNoDiag)) -join "`n") -match 'no watchdog diagnostic was captured')

    # A TIMEOUT is the one verdict that may genuinely BE a slow test, and it
    # says so rather than borrowing the wedge's wording.
    $dCap = Get-LaneFailureDetail -LaneName 'none' -LogPath $stallLog -Result 'TIMEOUT' -Diagnostic $diag
    Check 'a wall-clock cap is described as a cap, not as a wedge' `
        ((@(Format-FloorFailureDetail -Details @($dCap)) -join "`n") -match 'WALL-CLOCK CAP') 

    # And the FAIL wording is untouched: T776's block is what a red lane still
    # gets, with the verdict added in front of it.
    $failBlock = @(Format-FloorFailureDetail -Details @($d1)) -join "`n"
    Check 'a FAIL block still leads with its log path and errors' `
        ($failBlock -match 'lane agent: FAIL - ' -and $failBlock -match 'WaitForTimeout') $failBlock

    # ---- arms 17-19: the wiring, on a REAL wedge ----------------------------

    # `waitfor` blocks on a named signal that never arrives: a genuinely blocked
    # wait burning no CPU, which is the shape the watchdog exists to name. Short
    # -StallSeconds so the harness stages it in seconds rather than in the seven
    # minutes a real lane is given.
    $wedge = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Command 'waitfor /t 200 GhozttyVerdictDetailNeverSignalled' `
        -StallSeconds 12 -SampleSeconds 4 -MinFreeGB 0 -MinCommitFreeGB 0 -NoCatch 2>&1 |
        ForEach-Object { $_.ToString() }
    $wedgeTail = ($wedge | Select-Object -Last 14) -join "`n"
    Check 'a real wedge is still scored STALL' `
        (($wedge -join "`n") -match 'FLOOR SUMMARY: command=STALL') $wedgeTail
    Check 'the tail a context-rule caller keeps says WEDGED rather than just STALL' `
        ($wedgeTail -match 'WEDGED: no CPU and no output') $wedgeTail
    Check 'and it carries the process tree the watchdog sampled before the kill' `
        ($wedgeTail -match 'lane command: -- process tree --') $wedgeTail

    # ---- arms 20-27: the error return trace (T1662) -------------------------

    # The shape verbatim from floor-lane-win32-20260918-221751-383.log, the log
    # T1645 spent four turns reading wrong. The runner's `failed:` line names
    # the right test and, after `failed:`, a line emitted by a DIFFERENT test
    # that passed - every test in one binary shares one stderr. The cause is the
    # error return trace at the bottom, and not one line of it says `error:`.
    $misLog = Join-Path $Sandbox 'win32-misattributed.log'
    @(
        'install zig build',
        "error: 'apprt.win32.ViewerPane.test.host floor: a real controller on a real window, on this box' failed: [tripwire] (warn): untripped point=read",
        '[terminal_apc] (warn): kitty graphics protocol error: error.InvalidFormat',
        '[viewer_pane] (warn): waitFor: nothing satisfied the wait; pane still for 30015ms (bound 30s)',
        'D:\git\ghoztty\src\apprt\win32\ViewerPane.zig:9386:5: 0x7ff62c6feea4 in waitFor (ghostty-test_zcu.obj)',
        '    return error.WaitForTimeout;',
        '    ^',
        'D:\git\ghoztty\src\apprt\win32\ViewerPane.zig:8237:13: 0x7ff62c72b205 in test.host floor: a real controller on a real window, on this box (ghostty-test_zcu.obj)',
        '            try waitFor(&msg, 30, Wanted.ready, &pane);',
        '            ^',
        "error: while executing test 'cli.send_keys.test.flags: the known flags are recorded and consumed', the following test command failed:",
        'error: the following build command failed with exit code 1:'
    ) | Set-Content -LiteralPath $misLog -Encoding ascii

    $dMis = Get-LaneFailureDetail -LaneName 'win32' -LogPath $misLog
    Check 'the failing test is read out of the runner line, not guessed' `
        ($dMis.FailedTest -eq 'apprt.win32.ViewerPane.test.host floor: a real controller on a real window, on this box') `
        $dMis.FailedTest

    $misBlock = (@(Format-FloorFailureDetail -Details @($dMis))) -join "`n"
    # THE RULE of T1662: the kept output carries the REAL cause, which is the
    # error return trace, and not only the stderr line the runner happened to
    # attribute to it.
    Check 'the block surfaces the error the test actually returned' `
        ($misBlock -match 'return error\.WaitForTimeout;') $misBlock
    Check 'and the frame that names the failing test, with its file and line' `
        ($misBlock -match 'ViewerPane\.zig:8237:13.+in test\.host floor') $misBlock
    Check 'the innermost frame comes too, so the origin of the error is readable' `
        ($misBlock -match 'ViewerPane\.zig:9386:5.+in waitFor') $misBlock
    Check 'the trace section says the failed: text above it is shared stderr' `
        ($misBlock -match "the 'failed:' text above is shared stderr") $misBlock
    Check 'every trace line is attributed to its lane like the rest of the block' `
        (@(@(Format-FloorFailureDetail -Details @($dMis)) |
            Where-Object { $_ -match 'ViewerPane\.zig|WaitForTimeout' } |
            Where-Object { $_ -notmatch 'lane win32:' }).Count -eq 0) $misBlock
    # Caret lines are dropped: re-indented under a `lane <name>:` prefix they
    # align with nothing, so they are only lines a caller is keeping a budget of.
    Check 'the bare caret lines are dropped rather than re-indented into nonsense' `
        (@(@(Format-FloorFailureDetail -Details @($dMis)) |
            Where-Object { $_ -match '^\s*lane win32:\s*\^\s*$' }).Count -eq 0) $misBlock

    # A trace belonging to a DIFFERENT test must not be volunteered as this
    # one's cause - that is the same mistake the runner made, made twice.
    $otherLog = Join-Path $Sandbox 'win32-other-trace.log'
    @(
        "error: 'apprt.win32.ViewerPane.test.host floor: a real controller on a real window, on this box' failed: [tripwire] (warn): untripped point=read",
        'D:\git\ghoztty\src\apprt\win32\claude_plugin_migration.zig:135:22: 0x7ff62b1223a2 in scriptIsPluginOwned (ghostty-test_zcu.obj)',
        '    const target = try dir.readLink(name, &buf);',
        '    ^',
        'D:\git\ghoztty\src\apprt\win32\claude_plugin_migration.zig:255:12: 0x7ff62b121896 in test.run uninstalls every registration through the runner, then cleans up (ghostty-test_zcu.obj)',
        '    try run(alloc, &runner);',
        '    ^'
    ) | Set-Content -LiteralPath $otherLog -Encoding ascii
    $dOther = Get-LaneFailureDetail -LaneName 'win32' -LogPath $otherLog
    $otherBlock = (@(Format-FloorFailureDetail -Details @($dOther))) -join "`n"
    Check 'a trace for a different test is NOT offered as this failure cause' `
        ($otherBlock -notmatch 'claude_plugin_migration') $otherBlock
    Check 'and the absence is stated rather than left as silence' `
        ($otherBlock -match 'no error return trace naming') $otherBlock

    # Criterion 2: an ordinary red log - one with no `failed:` line at all -
    # is formatted exactly as it was before T1662. The whole block is compared,
    # not a substring, so a stray extra line cannot slip past.
    $plainLog = Join-Path $Sandbox 'win32-plain.log'
    @(
        'error: the following build command failed with exit code 1:',
        'error: unable to spawn zig'
    ) | Set-Content -LiteralPath $plainLog -Encoding ascii
    $plain = @(Format-FloorFailureDetail -Details @(Get-LaneFailureDetail -LaneName 'win32' -LogPath $plainLog))
    $expected = @(
        '',
        '-- FLOOR FAILURE DETAIL (read this, not the scrollback) --',
        "  lane win32: FAIL - $plainLog",
        '    lane win32: the lane exited non-zero; the errors below come from its own log.',
        '    lane win32: error: the following build command failed with exit code 1:',
        '    lane win32: error: unable to spawn zig'
    )
    Check 'a log with no misattribution is formatted exactly as it was before' `
        ((($plain -join "`n")) -eq ($expected -join "`n")) ($plain -join "`n")

    # ---- arms 28-37: a crashed test binary is CRASH, not FAIL (T955) --------

    # The pure classifier, against planted crash records, so each rule is held
    # without waiting on Windows Error Reporting.
    . (Join-Path $RepoRoot 'scripts\lib\CrashDiag.ps1')
    $since = (Get-Date).AddMinutes(-1)
    $ours = [pscustomobject]@{ App = 'ghostty-test.exe' }
    $zig = [pscustomobject]@{ App = 'zig.exe' }
    $foreign = [pscustomobject]@{ App = 'HxTsr.exe' }
    Check 'a crash record naming one of our test binaries is a CRASH' `
        (Test-LaneTestBinaryCrash -Since $since -Crashes @($ours))
    Check 'somebody else crashing in the same window is not' `
        (-not (Test-LaneTestBinaryCrash -Since $since -Crashes @($foreign)))
    Check 'a crashed compiler alone is not a test-binary crash' `
        (-not (Test-LaneTestBinaryCrash -Since $since -Crashes @($zig)))
    Check 'no record and no log is not a crash' `
        (-not (Test-LaneTestBinaryCrash -Since $since -Crashes @()))
    Check 'a T451 compiler-crash verdict keeps the lane FAIL, so its retry still keys' `
        (-not (Test-LaneTestBinaryCrash -Since $since -Crashes @($ours) `
                -CompilerCrash ([pscustomobject]@{ IsCompilerCrash = $true })))
    Check 'a caller-extended test-binary list is honoured' `
        (Test-LaneTestBinaryCrash -Since $since -Crashes @([pscustomobject]@{ App = 'fixture-t955.exe' }) `
            -ExeNames @('fixture-t955.exe'))

    # The 2026-08-15 shape, from the log alone: zig's truncated `code 3` is the
    # low byte of a breakpoint abort, i.e. the test binary died.
    $crashLog = Join-Path $Sandbox 'none-crash.log'
    @(
        'install zig build',
        "error: while executing test 'terminal.Screen.test.resize', the following test command failed:",
        'error: the following command exited with error code 3:'
    ) | Set-Content -LiteralPath $crashLog -Encoding ascii
    Check 'the 2026-08-15 log shape is a CRASH with no crash record at all' `
        (Test-LaneTestBinaryCrash -Since $since -Crashes @() -LogPath $crashLog)
    Check 'a plain red log (exit code 1) is not' `
        (-not (Test-LaneTestBinaryCrash -Since $since -Crashes @() -LogPath $plainLog))

    # The verdict block gives the new word its own meaning.
    $crashBlock = @(Format-FloorFailureDetail -Details @(
            Get-LaneFailureDetail -LaneName 'none' -LogPath $crashLog -Result 'CRASH')) -join "`n"
    Check 'a CRASH block says a test binary died, not that the lane was red' `
        ($crashBlock -match 'lane none: CRASH - ' -and $crashBlock -match 'A TEST BINARY DIED') $crashBlock

    # The wiring, on a REAL staged run: the transcript shape of 2026-08-15,
    # driven through -Command. The parentheses are load-bearing: floor-lane
    # appends `> log` to the command, and without the group that redirect binds
    # to `exit 1` alone, so the echo never reaches the log it is staging. It is the same staged-lane mechanism arm 10
    # uses, so the positive and the negative control differ only in the log.
    $crashCmd = '(echo error: the following command exited with error code 3:&& exit 1)'
    $crashOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Command $crashCmd -MinFreeGB 0 -MinCommitFreeGB 0 -NoCatch 2>&1 |
        ForEach-Object { $_.ToString() }
    $crashCode = $LASTEXITCODE
    $crashText = $crashOut -join "`n"
    Check 'a staged test-binary death reports LANE command CRASH' `
        ($crashText -match 'LANE command CRASH in ') $crashText
    Check 'and its summary says CRASH, so a pasted line is unambiguous' `
        ($crashText -match 'FLOOR SUMMARY: command=CRASH') $crashText
    Check 'and there is ONE verdict line, not a FAIL line corrected later' `
        ($crashText -notmatch 'LANE command FAIL') $crashText
    Check 'a CRASH exits 1, the same code FAIL always has' ($crashCode -eq 1) "exit=$crashCode"
    # The negative control: arm 10's plain red run, read for the same words.
    $failText = $out -join "`n"
    Check 'a genuinely red lane still reads LANE command FAIL' `
        ($failText -match 'LANE command FAIL in ' -and $failText -notmatch 'LANE command CRASH|=CRASH') $failText

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-verdict-detail -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
