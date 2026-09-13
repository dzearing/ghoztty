<#
.SYNOPSIS
    T271 acceptance - a run that asserted NOTHING must not exit 0.

.DESCRIPTION
    Three sections:

      A. The shared scorer ON THE WIRE (`lib\TestScore.ps1`). Fixture scripts
         are launched as real processes and their last line and exit code read
         back, because the whole defect class is "the last line and the exit
         code disagreed with what the run actually measured" - which is a
         property of the process, not of a function return value.

      B. The analyzer (`lib\AssertedNothingAudit.ps1`) against fixtures, both
         directions: a clean verdict yields nothing, and each violating shape
         is named.

      C. The sweep over `test\win32\*.ps1`: no acceptance script may still have
         a `zero-count` or `early-green` path. Three kinds are reported under a
         RATCHET rather than asserted at zero, because converting the suite is
         a burn-down and not a single change: `uncounted-final` (T775),
         `self-verdict` and `unarmed-stamp` (T1510). The ceiling is what stops
         the class GROWING while it falls.

    `-TeethCheck` proves the section-C assertions can fail: it injects a
    synthesized violator - a real fixture put through the analyzer, not a
    hand-made finding - and requires each of the three to go red. Run it after
    any change to the analyzer.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AssertedNothingAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t271-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
Write-Host ''
Write-Host '== A: the shared scorer, on the wire'
# ===========================================================================

# Run a fixture and report its LAST line plus its real exit code. `& powershell`
# with the output captured leaves $LASTEXITCODE set by the child, so there is no
# Start-Process handle to cache (the trap `lib\ExitCodeAudit.ps1` sweeps for).
function Invoke-Fixture([string]$Body, [string]$Tag) {
    $f = Join-Path $tmp "$Tag.ps1"
    $lib = (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
    # `Complete-TestBody` (T1039) because these fixtures are about the WORDING
    # of the verdicts below, not about a body that unwound: without it every
    # green fixture here would score RUN DID NOT FINISH, which is that rule's
    # own acceptance script's business (`body-complete-audit.ps1`).
    Set-Content -LiteralPath $f -Encoding utf8 -Value (@(
        ". '$lib'"
        "Complete-TestBody"
        $Body
    ) -join "`r`n")
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $last = if ($out.Count -gt 0) { $out[-1] } else { '' }
    return [pscustomobject]@{ Last = $last; Code = $code; All = $out }
}

$r = Invoke-Fixture 'Write-TestVerdict -Pass 7 -Fail 0' 'a-pass'
Assert 'A1 a run with passing assertions still says ALL PASS' ($r.Last -match 'ALL PASS \(7 assertions\)')
AssertEq 'A2 and still exits 0' 0 $r.Code

$r = Invoke-Fixture 'Write-TestVerdict -Pass 0 -Fail 0 -Skipped 1' 'a-nothing'
Assert 'A3 a run that asserted nothing says ASSERTED NOTHING' ($r.Last -match 'ASSERTED NOTHING')
Assert 'A4 and names it as not a pass' ($r.Last -match 'proved nothing')
Assert 'A5 and does NOT say ALL PASS' ($r.Last -notmatch 'ALL PASS')
AssertEq 'A6 and exits 2, not 0' 2 $r.Code
Assert 'A7 and still reports what it skipped' ($r.Last -match '1 SKIPPED')

$r = Invoke-Fixture 'Write-TestVerdict -Pass 4 -Fail 2' 'a-fail'
Assert 'A8 a run with failures says FAILURE(S)' ($r.Last -match '2 FAILURE\(S\)')
AssertEq 'A9 and exits 1 - a different answer from asserting nothing' 1 $r.Code

$r = Invoke-Fixture 'Write-TestVerdict -Pass 3 -Fail 0 -MinPass 20' 'a-too-little'
Assert 'A10 a run far below its own floor says ASSERTED TOO LITTLE' ($r.Last -match 'ASSERTED TOO LITTLE \(3 of at least 20')
AssertEq 'A11 and exits 2 as well' 2 $r.Code

$r = Invoke-Fixture "Write-TestAssertedNothing -Reason 'the port was held' -Label 'X ACCEPTANCE'" 'a-precondition'
Assert 'A12 the precondition helper names the reason' (($r.All -join "`n") -match 'SKIP whole run: the port was held')
Assert 'A13 and scores it as asserted nothing' ($r.Last -match '^X ACCEPTANCE: ASSERTED NOTHING')
AssertEq 'A14 and exits 2' 2 $r.Code

# The label is what a suite driver greps for, so it must survive.
$r = Invoke-Fixture "Write-TestVerdict -Label 'P1 ACCEPTANCE' -Pass 2 -Fail 0 -Unit 'checks'" 'a-label'
AssertEq 'A15 the label and unit reach the verdict line' 'P1 ACCEPTANCE: ALL PASS (2 checks)' $r.Last

# -NoExit is the seam P1-P3 use to tee their failure line into a transcript.
$r = Invoke-Fixture '$v = Write-TestVerdict -Pass 0 -Fail 0 -NoExit; "kind=$($v.Kind) code=$($v.Code)"' 'a-noexit'
AssertEq 'A16 -NoExit returns the verdict instead of exiting' 'kind=nothing code=2' $r.Last
AssertEq 'A17 and leaves the exit code to the caller' 0 $r.Code

# ===========================================================================
Write-Host ''
Write-Host '== B: the analyzer, both directions'
# ===========================================================================

function Get-Kinds([string[]]$Text) {
    return @(Get-AssertedNothingFindings -Path 'fixture.ps1' -Text $Text |
        ForEach-Object { $_.Kind })
}

# The fixtures below that assert "clean" are asking about the ENFORCED kinds -
# they are hand-written verdict lines on purpose, so `self-verdict` is true of
# them and says nothing about the shape each one is there to pin down. The
# T1510 kinds have their own fixtures (B9-B13) and their own ratchets (C4/C5).
function Get-EnforcedKinds([string[]]$Text) {
    $adoption = @('self-verdict', 'unarmed-stamp')
    return @(Get-Kinds $Text | Where-Object { $adoption -notcontains $_ })
}

$clean = @(
    '$script:pass = 0'
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }'
    'Write-Host "$script:fail FAILURE(S)"'
    'exit 1'
)
AssertEq 'B1 a counted final verdict is clean' 0 (Get-EnforcedKinds $clean).Count

$zero = @(
    'if ($noBuild) {'
    '    Write-Host "ALL PASS (0 checks, $script:skipped SKIPPED)"'
    '    exit 0'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
Assert 'B2 a hardcoded zero count is named' ((Get-Kinds $zero) -contains 'zero-count')

$early = @(
    'if ($portHeld) {'
    '    Write-Host "  SKIP whole run: the port was held"'
    '    Write-Host "ALL PASS (1 SKIPPED)"'
    '    exit 0'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
Assert 'B3 a green verdict on an abort path is named' ((Get-Kinds $early) -contains 'early-green')

$earlyRed = @(
    'if ($portHeld) {'
    '    Write-Host "  SKIP whole run: the port was held"'
    '    Write-Host "ASSERTED NOTHING (0 assertions)"'
    '    exit 2'
    '}'
    'Write-Host "ALL PASS ($script:pass assertions)"'
)
AssertEq 'B4 the same branch exiting nonzero is clean' 0 (Get-EnforcedKinds $earlyRed).Count

$uncounted = @(
    'if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }'
)
Assert 'B5 a final verdict with no count is reported' ((Get-Kinds $uncounted) -contains 'uncounted-final')

$scored = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'Write-TestVerdict -Pass $script:passes -Fail $script:failures'
)
AssertEq 'B6 a script on the shared scorer has nothing to report' 0 (Get-Kinds $scored).Count

# Somebody else's verdict being SCORED is not this script emitting one - three
# scripts in the suite compare against a `ALL PASS` line they captured.
$operand = @(
    '$laneText = & other.ps1'
    'Check "the lane passed" ($laneText -match "ALL PASS")'
    'if ($fail -eq 0) { "ALL PASS ($pass assertions)"; exit 0 }'
    'exit 1'
)
AssertEq 'B7 a compared ALL PASS is not read as a verdict' 0 (Get-EnforcedKinds $operand).Count

$exempt = @(
    '# asserted-nothing-audit: a helper process with nothing to score'
    'if ($x) { "ALL PASS (0 checks)"; exit 0 }'
)
AssertEq 'B8 the stated-intent marker exempts a file' 0 (Get-Kinds $exempt).Count

# --- T1510: the two kinds that say whether T1039's rule reaches a file -------
# A COUNTED hand-rolled verdict is still a hand-rolled verdict: the count is of
# the assertions that ran, and an unwound run has a truthful number in front of
# a green word. That is the whole reason this kind is not `uncounted-final`.
$countedSelf = @(
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }'
    'else { Write-Host "$script:fail FAILURE(S)"; exit 1 }'
)
Assert 'B9 a counted hand-rolled verdict is still reported as self-verdict' (
    (Get-Kinds $countedSelf) -contains 'self-verdict')
Assert 'B9b and is NOT reported as uncounted-final' (
    (Get-Kinds $countedSelf) -notcontains 'uncounted-final')

AssertEq 'B10 a script on the shared scorer has no self-verdict' 0 (
    @((Get-Kinds $scored) | Where-Object { $_ -eq 'self-verdict' })).Count

$unarmedStamp = @(
    'if ($script:fail -eq 0) {'
    '    & powershell -NoProfile -File (Join-Path $repo "scripts\guard-due.ps1") `'
    '        update -Guard some-harness -Repo $repo'
    '}'
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }'
)
Assert 'B11 a guard stamp written by an unarmed script is reported' (
    (Get-Kinds $unarmedStamp) -contains 'unarmed-stamp')

$armedStamp = @(
    '. (Join-Path $PSScriptRoot "lib\TestScore.ps1")'
    'Complete-TestBody'
    'if ($script:fail -eq 0) {'
    '    & powershell -NoProfile -File (Join-Path $repo "scripts\guard-due.ps1") `'
    '        update -Guard some-harness -Repo $repo'
    '}'
    'Write-TestVerdict -Pass $script:pass -Fail $script:fail'
)
AssertEq 'B12 an armed script that stamps has nothing to report' 0 (Get-Kinds $armedStamp).Count

# The comment that most often names the scorer is the one explaining why a
# script does NOT use it, so a mention in a comment must not count as arming.
$commentOnlyArm = @(
    '# this script scores itself rather than through lib\TestScore.ps1'
    'if ($script:fail -eq 0) {'
    '    & powershell -NoProfile -File (Join-Path $repo "scripts\guard-due.ps1") `'
    '        update -Guard some-harness -Repo $repo'
    '}'
    'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }'
)
Assert 'B13 a commented mention of the scorer does not count as armed' (
    (Get-Kinds $commentOnlyArm) -contains 'unarmed-stamp')

# ===========================================================================
Write-Host ''
Write-Host '== C: the sweep over the acceptance suite'
# ===========================================================================

$sweep = @(Get-AssertedNothingSweep (Join-Path $Repo 'test\win32'))
$hardKinds = Get-AssertedNothingHardKinds
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })

if ($TeethCheck) {
    # Synthesized rather than taken off the real state, so this mode keeps its
    # teeth once the suite is clean - which is the whole point and would
    # otherwise be the moment it stopped proving anything.
    $hard = @($hard) + [pscustomobject]@{
        Path = 'synthetic-violator.ps1'; Line = 1; Kind = 'early-green'
        Detail = 'teeth check' }
    Write-Host '  TEETH CHECK: a synthesized early-green violator is in the sweep'
    Assert 'C1 goes red when a script can score green having asserted nothing' ($hard.Count -gt 0)
} else {
    Assert 'C1 no acceptance script can score green having asserted nothing' ($hard.Count -eq 0)
    foreach ($h in $hard) {
        Write-Host "       $(Split-Path $h.Path -Leaf):$($h.Line) $($h.Kind) - $($h.Detail)"
    }
}

# The analyzer must actually have read the suite - a sweep that found no files
# would report zero violations and look identical to a clean one.
$scanned = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Filter *.ps1 -File).Count
Assert 'C2 the sweep read the whole suite' ($scanned -gt 100)

$uncountedFinal = @($sweep | Where-Object { $_.Kind -eq 'uncounted-final' })
Write-Host "  ($($uncountedFinal.Count) script(s) still print an UNCOUNTED final verdict - T775 converts them)"

# T775's ratchet: the number may fall, never rise. A name list of 40-odd files
# would be noise nobody reads; a ceiling is the same guarantee in one number.
#
# LOWER THIS when you convert a script onto the shared scorer; never raise it to
# make a red run go green. It sat 2 OVER for eight days (T962) because the four
# harnesses filed since it was set each hand-rolled their own verdict, and this
# assertion is the only thing that says so - the ceiling is a ratchet exactly to
# the extent that a run that finds it exceeded is treated as work to do.
# 2026-09-01 (T1257): 37 -> 36. It had drifted to 41 - five harnesses filed
# since T962 (daily-publish, install-launch, install-ownership, one-installer,
# viewer-find) each hand-rolled a bare "ALL PASS", against one (morning-refresh)
# that was retired. All five are on the shared scorer now, so the ceiling comes
# down past where T962 left it rather than up to where the drift landed.
$ceiling = 29
Assert "C3 the uncounted-final count did not grow past $ceiling" ($uncountedFinal.Count -le $ceiling)

# T1510's ratchets, same contract as C3 and for a sharper reason: until a
# script's verdict goes through the scorer, T1039's "a run that unwound is not
# a pass" rule does not reach it AT ALL, and if it also stamps its guard the
# damage outlives the run. LOWER THESE as scripts convert; never raise one.
# 2026-09-12 (T1510): set at the measured state, minus the one script converted
# in the same commit (viewer-feedback-capture, where the defect was observed).
# 2026-09-12 (T1511, batch 1): 198 -> 181 and 79 -> 62. Seventeen of the
# stamping scripts moved onto the shared scorer - the static audits and the
# doc/tracker harnesses, which are the ones a single turn can run green end to
# end - and each was run on the box and re-stamped by that run. Two more were
# converted and REVERTED rather than shipped unproven, because their harness
# cannot reach a green stamping run at HEAD for reasons of their own:
# website-windows-download (T1513, the gh-pages mirror has drifted) and
# ghoztty-cleanup (T1514, a box-state skip means it can never re-stamp here).
# 2026-09-12 (T1511, batch 2): 181 -> 173 and 62 -> 54.
# 2026-09-12 (T1511, batch 3): 173 -> 164 and 54 -> 45. The first nine GUI
# acceptance runs - session-layout-preserve, sessions-running-cmd,
# remote-disconnect, ipc-relay, remote-pill, activity-monitor-remote,
# chooser-restore-all-remote, remote-reconnect-relay and chrome-theme - picked,
# as every batch is, by whether this box can re-stamp the guard after the edit.
# 2026-09-12 (T1511, batch 4): 164 -> 158 and 45 -> 39. Six more GUI runs -
# palette-jump, chooser-session-sort, chooser-resume, chooser-orphan-badge,
# restore-late-agent and harness-process-leak. Three of them continue past their
# top-level try (a foreground-leak check, or three more sections), so those
# tries grew a SCORING catch instead of ending in the marker - the other honest
# shape the body-completion rule names. Three more were converted and REVERTED
# rather than shipped unproven, because this box cannot reach a green stamping
# run of them at HEAD: tab-tooltip (T1515, sections A and E red - the tip now
# carries an un-abbreviated title line above the cwd), layout-capture-cost
# (T1516, a wall-clock frame budget that fails a DIFFERENT assertion each run
# under box load) and relay-account (T1517, which wedges in its own teardown
# after the last assertion and never prints a verdict at all).
# 2026-09-12 (T1511, batch 5): 158 -> 152, 39 -> 33 and C3 31 -> 29. Six more
# stamping harnesses onto the shared scorer - ipc-when-idle, ipc-version,
# url-scheme, clipboard-retry, gui-launch-command and go-loop-guard. ipc-version
# had hand-rolled the completion marker as $script:reachedEnd and moved onto the
# shared one, which its own "the script ran to the end" assertion now reads.
# 2026-09-12 (T1511, batch 6): 152 -> 146 and 33 -> 27. The six viewer
# acceptance harnesses - viewer-composer, viewer-feedback, viewer-panes,
# viewer-image, viewer-narrow-pane and viewer-nav-pin. All six run leak checks
# AFTER their top-level try, so every one of those tries grew a SCORING catch
# and the marker sits immediately before the stamp.
# 2026-09-13 (T1511, batch 7): 146 -> 140 and 27 -> 21. Six more stamping GUI
# harnesses - readonly-badge, key-state-pill, menu-f10-binding, split-divider,
# viewer-worktree-port and stderr-launch-capture. Four of the six run their
# foreground-leak checks after the top-level try, so those tries grew a SCORING
# catch; the other two already scored their throw.
$selfCeiling  = 140
$stampCeiling = 21

$ratchetSweep = @($sweep)
if ($TeethCheck) {
    # A REAL violator, analyzed - not a hand-made finding object. The fixture
    # is run through `Get-AssertedNothingFindings` and its findings joined to
    # the sweep, and the ceilings are pinned to what the real suite scored, so
    # a correctly wired assertion must go red. Injecting a finding without
    # moving the ceiling would prove nothing (one more is still under 198), and
    # moving the ceiling without injecting would prove only that `-le` works.
    $teethFixture = @(
        'if ($script:fail -eq 0) {'
        '    & powershell -NoProfile -File (Join-Path $repo "scripts\guard-due.ps1") `'
        '        update -Guard synthetic-violator -Repo $repo'
        '}'
        'if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }'
    )
    $ratchetSweep = @($sweep) + @(Get-AssertedNothingFindings -Path 'synthetic-violator.ps1' -Text $teethFixture)
    $selfCeiling  = @($sweep | Where-Object { $_.Kind -eq 'self-verdict' }).Count
    $stampCeiling = @($sweep | Where-Object { $_.Kind -eq 'unarmed-stamp' }).Count
    Write-Host '  TEETH CHECK: one synthesized violator is in the sweep, with both ceilings at the real count'
}

$selfVerdict       = @($ratchetSweep | Where-Object { $_.Kind -eq 'self-verdict' })
$unarmedStampSweep = @($ratchetSweep | Where-Object { $_.Kind -eq 'unarmed-stamp' })
Write-Host "  ($($selfVerdict.Count) script(s) still PRINT their own verdict - T1039's unwind rule does not reach them)"
Write-Host "  ($($unarmedStampSweep.Count) script(s) stamp a guard while unarmed - an unwound run still records the files as proven)"

if ($TeethCheck) {
    Assert 'C4 goes red when one more script prints its own verdict' ($selfVerdict.Count -gt $selfCeiling)
    Assert 'C5 goes red when one more unarmed script stamps its guard' ($unarmedStampSweep.Count -gt $stampCeiling)
} else {
    Assert "C4 the self-verdict count did not grow past $selfCeiling" ($selfVerdict.Count -le $selfCeiling)
    Assert "C5 the unarmed-stamp count did not grow past $stampCeiling" ($unarmedStampSweep.Count -le $stampCeiling)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ''
Complete-TestBody  # T1039: the run reached the end of its body
Write-TestVerdict -Label 'T271 ACCEPTANCE' -Pass $script:pass -Fail $script:fail -MinPass 20
