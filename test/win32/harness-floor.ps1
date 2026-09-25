# harness-floor acceptance (T725): the standing set of harness audits is
# well-formed, its pending ratchet has teeth, and the runner scores a run the
# way the ratchet says.
#
#   powershell -NoProfile -File test\win32\harness-floor.ps1
#   powershell -NoProfile -File test\win32\harness-floor.ps1 -NegativeControl
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# a script list and a scorer, so this reads source text, plants summary rows and
# runs ONE cheap audit end to end.
#
# isolation: none - a static audit plus one scored run; nothing here launches
# ghoztty or runs a CLI verb (T680 meta-check reads this marker).
#
# Why it exists. `scripts\harness-floor.ps1` is a gate, and a gate whose teeth
# have never been observed is indistinguishable from a gate that has none
# (T1133). The condition it exists to catch - a harness audit going red with
# nobody noticing - is exactly the condition that cannot be produced by waiting,
# so it is produced here: planted rows, a red one that is not excused, a red one
# that is, and an exception that has gone green.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,

    # Invert one assertion, to prove a green run here is evidence and not a
    # script that asserts nothing (T221's shape).
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

function New-Row($name, $verdict) { return [pscustomobject]@{ Name = $name; Verdict = $verdict } }

$audits = @(Get-HarnessFloorAudits)
$pending = Get-HarnessFloorPending
$testRoot = Join-Path $Repo 'test\win32'
$work = Join-Path $env:TEMP ("harness-floor-acc-" + (Get-Date -Format 'yyyyMMddHHmmssfff'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    # ========================================================================
    "== A: the floor set is well-formed"
    # ========================================================================

    Assert 'A1 the set is not empty' ($audits.Count -gt 0) "count=$($audits.Count)"

    $names = @($audits | ForEach-Object { [string]$_.Name })
    $dupes = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert 'A2 no audit is listed twice' ($dupes.Count -eq 0) ($dupes -join ', ')

    $absent = @($names | Where-Object { -not (Test-Path (Join-Path $testRoot $_)) })
    Assert 'A3 every audit in the set exists on disk' ($absent.Count -eq 0) ($absent -join ', ')

    $whyless = @($audits | Where-Object { -not $_.Why } | ForEach-Object { $_.Name })
    Assert 'A4 every audit says why it is in the floor' ($whyless.Count -eq 0) ($whyless -join ', ')

    # The deliberate exclusion, asserted so it cannot drift back in by accident.
    # `test-filter-guard.ps1` guards a real harness trap (T631) and belongs to
    # the same family, but its subject is `zig build` itself: it runs the real
    # test step, which on a cold cache is minutes of compiling and is the zig
    # lanes' job. A source-sweep set that quietly grows a compiler is no longer
    # a fifteen-minute lane, which is the property that lets this be run at all.
    Assert 'A5 the set excludes the audit that drives a real zig build' (
        $names -notcontains 'test-filter-guard.ps1') ''

    $strayPending = @(@($pending.Keys) | Where-Object { $names -notcontains $_ })
    Assert 'A6 every pending exception names an audit in the set' ($strayPending.Count -eq 0) ($strayPending -join ', ')

    $unlinked = @(@($pending.Keys) | Where-Object { $pending[$_] -notmatch '^T\d+$' })
    Assert 'A7 every pending exception names the task that converts it' ($unlinked.Count -eq 0) ($unlinked -join ', ')

    $taskDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
    $deadTask = @(@($pending.Values) | Sort-Object -Unique | Where-Object {
            -not (Test-Path (Join-Path $taskDir "$_.md")) })
    Assert 'A8 those tasks are filed' ($deadTask.Count -eq 0) ($deadTask -join ', ')

    # ========================================================================
    ""
    "== B: the scorer, in both directions"
    # ========================================================================

    $twoAudits = @(
        [pscustomobject]@{ Name = 'alpha.ps1'; Why = 'a' }
        [pscustomobject]@{ Name = 'beta.ps1'; Why = 'b' }
    )
    $noPending = @{}
    $betaPending = @{ 'beta.ps1' = 'T725' }

    $green = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'pass'))
    Assert 'B1 an all-green run is green' ($green.Ok) ''
    Assert 'B2 and counts both audits' ($green.Passed.Count -eq 2) "passed=$($green.Passed.Count)"

    $red = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'fail'))
    Assert 'B3 an unexcused red fails the floor' (-not $red.Ok) ''
    Assert 'B4 and the red row is named' (@($red.Red | ForEach-Object { $_.Name }) -contains 'beta.ps1') ''

    $excused = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $betaPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'fail'))
    Assert 'B5 a red that is a named exception does NOT fail the floor' ($excused.Ok) ''
    Assert 'B6 and it is reported as pending against its task' (
        @($excused.Excused | Where-Object { $_.Name -eq 'beta.ps1' -and $_.Task -eq 'T725' }).Count -eq 1) ''

    $stale = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $betaPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'pass'))
    Assert 'B7 an exception that has gone green fails the floor as STALE' (-not $stale.Ok) ''
    Assert 'B8 and names the entry to drop' ($stale.Stale -contains 'beta.ps1') ''

    $missing = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'))
    Assert 'B9 an audit the run never produced a row for fails the floor' (-not $missing.Ok) ''
    Assert 'B10 and is reported as NOT RUN rather than counted green' ($missing.Missing -contains 'beta.ps1') ''

    $orphan = Get-HarnessFloorVerdict -Audits $twoAudits -Pending @{ 'gamma.ps1' = 'T725' } `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'pass'))
    Assert 'B11 an exception for an audit not in the set fails the floor' (-not $orphan.Ok) ''
    Assert 'B12 and is named as excusing nothing' ($orphan.Orphan -contains 'gamma.ps1') ''

    # A skip is the box saying it cannot answer, not the suite saying no (T1100).
    $skipped = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending `
        -Rows @((New-Row 'alpha.ps1' 'pass'), (New-Row 'beta.ps1' 'skip'))
    Assert 'B13 a skipped audit is not red' ($skipped.Ok) ''
    Assert 'B14 but it is reported, never silently counted as proof' ($skipped.Skipped -contains 'beta.ps1') ''

    $lines = @(Format-HarnessFloorVerdict -Verdict $green)
    Assert 'B15 a green verdict ends in ALL PASS' ($lines[-1] -match '^HARNESS FLOOR: ALL PASS \(2 audits\)$') $lines[-1]
    $redLines = @(Format-HarnessFloorVerdict -Verdict $red)
    Assert 'B16 a red verdict ends in a failure count' ($redLines[-1] -match '^HARNESS FLOOR: 1 FAILURE\(S\) of 2 audits$') $redLines[-1]
    $exLines = @(Format-HarnessFloorVerdict -Verdict $excused)
    Assert 'B17 a pending row is visible in the verdict, not hidden by the pass' (
        ($exLines -join "`n") -match 'PENDING\s+beta\.ps1 \(fail\) - tracked by T725') ''

    # T1734: a red row says WHY - its FAIL lines, how it did alone, and where
    # the transcript is - instead of the audit name alone.
    $whyDir = Join-Path $work 'why'
    New-Item -ItemType Directory -Force -Path $whyDir | Out-Null
    Set-Content -LiteralPath (Join-Path $whyDir 'beta.log') -Encoding UTF8 -Value @(
        '== B: something'
        '  PASS B0 fine'
        '  FAIL B1 the lane builds -- zig build test exited 1; failed test: ''x'''
        '1 FAILURE(S) (1 assertions passed)'
    )
    $whyRow = [pscustomobject]@{ Name = 'beta.ps1'; Verdict = 'fail'; Log = 'beta.log'; Alone = 'pass' }
    $why = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending -LogDir $whyDir `
        -Rows @((New-Row 'alpha.ps1' 'pass'), $whyRow)
    $whyRed = @($why.Red)[0]
    Assert 'B18 a red row carries its FAIL line' (
        @($whyRed.Fails).Count -eq 1 -and $whyRed.Fails[0] -match '^FAIL B1 the lane builds') ($whyRed.Fails -join ' | ')
    $whyText = (@(Format-HarnessFloorVerdict -Verdict $why) -join "`n")
    Assert 'B19 and the verdict prints it, the alone result and the log path' (
        $whyText -match 'FAIL B1 the lane builds' -and $whyText -match 'alone: pass' -and
        $whyText -match [regex]::Escape((Join-Path $whyDir 'beta.log'))) $whyText
    $noLog = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending -LogDir $whyDir `
        -Rows @((New-Row 'alpha.ps1' 'pass'), [pscustomobject]@{ Name = 'beta.ps1'; Verdict = 'fail'; Log = 'gone.log' })
    Assert 'B20 a red row whose log is gone is still red, with no detail rather than a throw' (
        -not $noLog.Ok -and @(@($noLog.Red)[0].Fails).Count -eq 0 -and -not @($noLog.Red)[0].LogPath) ''
    $refused = Get-HarnessFloorVerdict -Audits $twoAudits -Pending $noPending -LogDir $whyDir `
        -Rows @((New-Row 'alpha.ps1' 'pass'), [pscustomobject]@{
                Name = 'beta.ps1'; Verdict = 'fail'; Log = 'gone.log'; Line = 'refused: the build is stale' })
    Assert 'B21 a red row with no FAIL line falls back to its last line' (
        @(@($refused.Red)[0].Fails) -contains 'refused: the build is stale') ''

    # ========================================================================
    ""
    "== C: the runner on the wire"
    # ========================================================================

    $runner = Join-Path $Repo 'scripts\harness-floor.ps1'
    Assert 'C1 the runner exists' (Test-Path $runner) $runner

    $listOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $Repo -List 2>&1
    $listCode = $LASTEXITCODE
    $listText = ($listOut | Out-String)
    Assert 'C2 -List exits 0' ($listCode -eq 0) "exit=$listCode"
    Assert 'C3 -List names every audit in the set' (
        @($names | Where-Object { $listText -notmatch [regex]::Escape($_) }).Count -eq 0) ''
    Assert 'C4 -List marks the pending exceptions' (
        ($pending.Count -eq 0) -or ($listText -match '\[PENDING T\d+\]')) ''

    # The scoring path end to end, over a planted summary: a red row that is not
    # excused must come back as a nonzero exit from the RUNNER, not merely from
    # the scorer function above.
    $plantDir = Join-Path $work 'plant'
    New-Item -ItemType Directory -Force -Path $plantDir | Out-Null
    $plant = Join-Path $plantDir 'summary.json'
    $redRows = @($names | ForEach-Object { New-Row $_ 'pass' })
    $redRows[0].Verdict = 'fail'
    $firstName = $names[0]
    if ($pending.ContainsKey($firstName)) {
        # The first audit is an excused one, so plant the red on one that is not:
        # this section is about the UNEXCUSED path.
        $idx = 0
        for ($k = 0; $k -lt $names.Count; $k++) {
            if (-not $pending.ContainsKey($names[$k])) { $idx = $k; break }
        }
        $redRows[0].Verdict = 'pass'
        $redRows[$idx].Verdict = 'fail'
        $firstName = $names[$idx]
    }
    # A pending audit must be red in the plant too, or the scorer would call it
    # STALE and the section would be red for the wrong reason.
    foreach ($r in $redRows) { if ($pending.ContainsKey($r.Name)) { $r.Verdict = 'fail' } }
    # The red row's transcript, beside the summary as suite-run leaves it, so C6b
    # can prove the runner reads it from there (T1734).
    $plantedRed = @($redRows | Where-Object { $_.Name -eq $firstName })[0]
    $plantedRed | Add-Member -NotePropertyName Log -NotePropertyValue 'planted-red.log'
    Set-Content -LiteralPath (Join-Path $plantDir 'planted-red.log') -Encoding UTF8 `
        -Value @('  FAIL Z9 the planted assertion -- planted by harness-floor.ps1', '1 FAILURE(S)')
    ([pscustomobject]@{ schema = 'ghoztty-suite-run/1'; results = $redRows } | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath $plant -Encoding UTF8

    $scoreOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $Repo -ScoreSummary $plant 2>&1
    $scoreCode = $LASTEXITCODE
    $scoreText = ($scoreOut | Out-String)
    Assert 'C5 the runner exits 1 on an unexcused red row' ($scoreCode -eq 1) "exit=$scoreCode"
    Assert 'C6 and names it' ($scoreText -match ("RED\s+" + [regex]::Escape($firstName))) ''
    Assert 'C6b and prints the failing assertion out of the transcript beside the summary' (
        $scoreText -match 'FAIL Z9 the planted assertion') ''

    $greenRows = @($names | ForEach-Object { New-Row $_ 'pass' })
    foreach ($r in $greenRows) { if ($pending.ContainsKey($r.Name)) { $r.Verdict = 'fail' } }
    $plant2 = Join-Path $plantDir 'summary-green.json'
    ([pscustomobject]@{ schema = 'ghoztty-suite-run/1'; results = $greenRows } | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath $plant2 -Encoding UTF8
    $ok2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $Repo -ScoreSummary $plant2 2>&1
    $ok2Code = $LASTEXITCODE
    Assert 'C7 and exits 0 when every unexcused audit passed' ($ok2Code -eq 0) "exit=$ok2Code`n$($ok2 | Out-String)"

    $gone = Join-Path $plantDir 'nope.json'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $Repo -ScoreSummary $gone 2>&1
    Assert 'C8 a run that left no summary is a failure, not a green floor' ($LASTEXITCODE -eq 1) "exit=$LASTEXITCODE"

    # ========================================================================
    ""
    "== D: one real audit, all the way through suite-run"
    # ========================================================================

    # The cheapest member measured (about two seconds), so the wiring from the
    # runner through suite-run and back into the scorer is proved on real rows
    # rather than planted ones - without paying the whole fifteen minutes.
    # A narrowed run measured part of the suite, so it must not tell guard-due
    # the whole of it is proven. Recorded before and compared after, because the
    # stamp is a committed file and a false stamp here would be invisible.
    $floorStamp = Join-Path $testRoot 'harness-floor.stamp.json'
    $stampBefore = if (Test-Path $floorStamp) { (Get-FileHash $floorStamp -Algorithm SHA256).Hash } else { '<absent>' }

    $realDir = Join-Path $work 'real'
    $realOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Repo $Repo -Include 'printclient-audit.ps1' -OutDir $realDir 2>&1
    $realCode = $LASTEXITCODE
    $realText = ($realOut | Out-String)
    Assert 'D1 a one-audit floor run exits 0' ($realCode -eq 0) "exit=$realCode`n$realText"
    Assert 'D2 and its verdict line counts exactly that audit' (
        $realText -match 'HARNESS FLOOR: ALL PASS \(1 audits') ''
    Assert 'D3 suite-run really ran it (a summary is on disk)' (
        Test-Path (Join-Path $realDir 'summary.json')) $realDir

    $stampAfter = if (Test-Path $floorStamp) { (Get-FileHash $floorStamp -Algorithm SHA256).Hash } else { '<absent>' }
    Assert 'D4 a narrowed run does NOT stamp the floor guard' ($stampAfter -eq $stampBefore) `
        "before=$stampBefore after=$stampAfter"

    $bad = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner `
        -Repo $Repo -Include 'no-such-audit-*.ps1' 2>&1
    Assert 'D5 an -Include that matches nothing is a failure, not an empty pass' (
        $LASTEXITCODE -eq 1) "exit=$LASTEXITCODE`n$($bad | Out-String)"

    # ========================================================================
    ""
    "== E: the lane"
    # ========================================================================

    $lanePath = Join-Path $Repo 'scripts\floor-lane.ps1'
    $laneText = Get-Content -LiteralPath $lanePath -Raw

    # Ask the PARAMETER what it accepts, not the source text what it looks
    # like. This assertion used to pin the whole ValidateSet literal on one
    # line, so T846 adding the releasesafe lanes - and wrapping the list onto a
    # second line - scored it red over a lane that works perfectly well. A
    # summary that matches on spelling reports the wrong thing the moment the
    # spelling moves; the lesson is T1662's, and this is the same shape.
    $laneSet = @()
    try {
        $laneParam = (Get-Command -Name $lanePath -CommandType ExternalScript).Parameters['Lane']
        foreach ($attr in @($laneParam.Attributes)) {
            if ($attr -is [System.Management.Automation.ValidateSetAttribute]) {
                $laneSet = @($attr.ValidValues)
            }
        }
    }
    catch { $laneSet = @() }
    Assert 'E1 floor-lane accepts -Lane harness' ($laneSet -contains 'harness') `
        "-Lane accepts: $($laneSet -join ', ')"
    Assert 'E2 and runs the floor runner for it' ($laneText -match 'harness-floor\.ps1') ''
    # Deliberate, and asserted so it cannot drift by accident: the set is ~15
    # minutes of source scanning and guard-due is what makes it standing.
    Assert 'E3 -Lane all stays the four zig lanes' (
        $laneText -match "\`$lanes = if \(\`$Lane -eq 'all'\) \{ @\('lib', 'none', 'win32', 'agent'\) \}") ''

    # ========================================================================
    ""
    "== F: the entry point a script author reads (T732)"
    # ========================================================================

    # A floor is only half of what T732 asked for. The other half is that the
    # rules are WRITTEN DOWN somewhere a new script author finds them, instead
    # of being four paragraphs of CLAUDE.md prose plus twenty script headers -
    # the state in which they were learned one red run at a time. A README can
    # rot the day a row is added, so the set and the document are checked
    # against each other here rather than trusted to agree.
    $readme = Join-Path $testRoot 'README.md'
    Assert 'F1 test\win32 has a README' (Test-Path $readme) $readme

    $readmeText = if (Test-Path $readme) { Get-Content -LiteralPath $readme -Raw } else { '' }
    $undocumented = @($names | Where-Object { $readmeText -notmatch [regex]::Escape($_) })
    Assert 'F2 every audit in the floor set is documented there' ($undocumented.Count -eq 0) `
        ($undocumented -join ', ')

    Assert 'F3 and it names the one command that runs them' (
        $readmeText -match 'floor-lane\.ps1\s+-Lane\s+harness') ''
    Assert 'F4 and the guard row that makes the floor standing' (
        $readmeText -match 'harness-floor' -and $readmeText -match 'guard-due') ''
    # The membership criterion is the property that keeps the lane runnable at
    # all (section A5's exclusion is the same rule enforced on one case), so the
    # document has to state it or the next row will be a GUI script.
    Assert 'F5 and the criterion a new row has to meet' (
        $readmeText -match 'static sweep') ''

    if ($NegativeControl) {
        "  NEGATIVE CONTROL: one assertion is inverted below; this run MUST be red"
        Assert 'N1 (inverted) the floor set is empty' ($audits.Count -eq 0) "count=$($audits.Count)"
    }

    Complete-TestBody
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the floor as it now stands?". Red leaves the stamp
# alone: red stays due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard harness-floor-teeth -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T725 HARNESS FLOOR' -Pass $script:passes -Fail $script:failures
