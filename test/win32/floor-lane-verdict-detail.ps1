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
  names the lane, its log path, and its first errors. Arms 1-6 drive the pure
  library against planted logs; arms 7-11 are the wiring, including a REAL red
  run driven through `-Command`, whose last few lines are then checked the way
  a context-rule caller would keep them.

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
    $cmd = 'echo error: staged red for T776 verdict detail && exit 1'
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
