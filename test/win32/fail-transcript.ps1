<#
.SYNOPSIS
  Acceptance test for test\win32\lib\Transcript.ps1 (T900).

.DESCRIPTION
  The defect: on 2026-08-16 `ipc-p2.ps1` scored 16 FAILURE(S) and two immediate
  re-runs were ALL PASS. The run HAD teed a full transcript, but to the fixed
  path `%TEMP%\ghoztty-ipc-p2-last.log` - so the first green re-run truncated
  it, and the only flake anybody had seen became unreproducible AND
  undiagnosable in the same minute. Five of the seven teed harnesses also never
  NAMED the file, and the floor is habitually summarised with
  `| Select-Object -Last 1`, which keeps one line.

  So the two claims under test are the two halves of that:

    A. a RED run leaves its transcript somewhere a LATER RUN CANNOT WRITE, and
       that file holds every assertion line plus the verdict;
    B. the path is IN the verdict line - the one line a `-Last 1` reader keeps.

  Both are asserted against a real harness process, not only against the
  library: section D runs a throwaway script end to end, reds it on purpose,
  then runs it again GREEN and proves the preserved file survived the re-run
  byte for byte. That is the exact sequence the 2026-08-16 evidence died in.

  Section E is the negative control: the old fixed-path-only shape, so the file
  cannot pass on a box where the hazard does not exist.

  Pure PowerShell plus one child powershell.exe. No exe under test, no window,
  no agent - every path is under a private directory in %TEMP%.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\fail-transcript.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')

# Everything this script writes lives here, so a run cannot see - or prune -
# the real harnesses' preserved transcripts sitting in %TEMP%.
$root = Join-Path $env:TEMP "ghoztty-fail-transcript-$PID"
New-Item -ItemType Directory -Force $root | Out-Null

try {
    # --- A. a red run preserves; a green run does not ------------------------
    ''
    '-- A. the library: red preserves, green does not'

    $live = New-TestTranscript -Name 'unit-a' -Dir $root
    Set-Content -LiteralPath $live -Value @('  PASS one', '  FAIL two')
    Reset-TestBody; Complete-TestBody
    $red = Complete-TestTranscript -Name 'unit-a' -Path $live -Dir $root `
        -Label 'UNIT A' -Pass 1 -Fail 1

    Assert 'A1 a red run exits nonzero' ($red.Code -ne 0) "code $($red.Code)"
    Assert 'A2 and names a preserved transcript' `
        (-not [string]::IsNullOrWhiteSpace($red.Evidence)) "evidence '$($red.Evidence)'"
    Assert 'A3 the preserved file exists' `
        ($red.Evidence -and (Test-Path -LiteralPath $red.Evidence)) ''
    Assert 'A4 it is NOT the live -last.log path' `
        ($red.Evidence -ne $live) "evidence '$($red.Evidence)'"

    $kept = Get-Content -LiteralPath $red.Evidence
    Assert 'A5 it holds every assertion line' `
        (($kept -join "`n") -match 'PASS one' -and ($kept -join "`n") -match 'FAIL two') ''
    Assert 'A6 and the verdict they add up to' `
        (($kept -join "`n") -match 'UNIT A: 1 FAILURE\(S\)') ''

    $liveG = New-TestTranscript -Name 'unit-g' -Dir $root
    Set-Content -LiteralPath $liveG -Value '  PASS one'
    Reset-TestBody; Complete-TestBody
    $green = Complete-TestTranscript -Name 'unit-g' -Path $liveG -Dir $root `
        -Label 'UNIT G' -Pass 1 -Fail 0
    Assert 'A7 a green run exits 0' ($green.Code -eq 0) "code $($green.Code)"
    Assert 'A8 and preserves nothing (the evidence store is for failures)' `
        ($null -eq $green.Evidence) "evidence '$($green.Evidence)'"
    Assert 'A9 green verdict wording is untouched by this library' `
        ($green.Line -eq 'UNIT G: ALL PASS (1 assertions)') "said '$($green.Line)'"

    # --- B. the path is in the line a `-Last 1` reader keeps -----------------
    ''
    '-- B. the verdict line names the evidence'

    Assert 'B1 the red verdict line names the preserved path' `
        ($red.Line -match [regex]::Escape($red.Evidence)) "said '$($red.Line)'"
    Assert 'B2 the original verdict wording survives inside it' `
        ($red.Line -match 'UNIT A: 1 FAILURE\(S\) \(1 assertions passed\)') "said '$($red.Line)'"
    Assert 'B3 and it is announced as evidence, not as prose' `
        ($red.Line -match ' - evidence: ') "said '$($red.Line)'"

    # --- C. failure verdicts other than FAILURE(S) preserve too --------------
    ''
    '-- C. every non-green verdict preserves, not just FAILURE(S)'

    $liveN = New-TestTranscript -Name 'unit-n' -Dir $root
    Set-Content -LiteralPath $liveN -Value '  SKIP whole run: the fixture never came up'
    Reset-TestBody; Complete-TestBody
    $nothing = Complete-TestTranscript -Name 'unit-n' -Path $liveN -Dir $root `
        -Label 'UNIT N' -Pass 0 -Fail 0
    Assert 'C1 ASSERTED NOTHING exits 2' ($nothing.Code -eq 2) "code $($nothing.Code)"
    Assert 'C2 and preserves its transcript too' `
        ($nothing.Evidence -and (Test-Path -LiteralPath $nothing.Evidence)) ''

    $liveI = New-TestTranscript -Name 'unit-i' -Dir $root
    Set-Content -LiteralPath $liveI -Value '  PASS one'
    Reset-TestBody   # armed and deliberately NOT completed: the T1039 unwind
    $incomplete = Complete-TestTranscript -Name 'unit-i' -Path $liveI -Dir $root `
        -Label 'UNIT I' -Pass 1 -Fail 0
    Complete-TestBody   # re-arm this script's own body marker
    Assert 'C3 RUN DID NOT FINISH exits 2' ($incomplete.Code -eq 2) "code $($incomplete.Code)"
    Assert 'C4 and preserves its transcript too' `
        ($incomplete.Evidence -and (Test-Path -LiteralPath $incomplete.Evidence)) ''

    # --- D. end to end: the re-run cannot destroy the evidence ---------------
    ''
    '-- D. end to end: a red run, then the green re-run that used to erase it'

    $harness = Join-Path $root 'throwaway-harness.ps1'
    # A miniature of the real shape: tee a body, then end on
    # Complete-TestTranscript. `-Red` is what makes it fail.
    @"
param([switch]`$Red)
`$ErrorActionPreference = 'Continue'
`$lib = '$($PSScriptRoot -replace "'","''")'
. (Join-Path `$lib 'lib\Transcript.ps1')
`$script:passes = 0
`$script:failures = 0
`$transcript = New-TestTranscript -Name 'throwaway' -Dir '$($root -replace "'","''")'
& {
    '  PASS the fixture came up'
    `$script:passes++
    if (`$Red) { '  FAIL the pane never answered'; `$script:failures++ }
    else { '  PASS the pane answered'; `$script:passes++ }
} 2>&1 | Tee-Object -FilePath `$transcript
Complete-TestBody
exit (Complete-TestTranscript -Name 'throwaway' -Path `$transcript ``
        -Dir '$($root -replace "'","''")' -Label 'THROWAWAY' ``
        -Pass `$script:passes -Fail `$script:failures).Code
"@ | Set-Content -LiteralPath $harness -Encoding ASCII

    $redOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $harness -Red 2>&1
    $redCode = $LASTEXITCODE
    $redLast = @($redOut | ForEach-Object { "$_" } | Where-Object { $_.Trim() })[-1]
    Assert 'D1 the deliberately-red run exits nonzero' ($redCode -ne 0) "code $redCode"
    Assert 'D2 its LAST line is the verdict naming a preserved transcript' `
        ($redLast -match 'THROWAWAY: 1 FAILURE\(S\).* - evidence: (.+\.log)$') "last line '$redLast'"

    $named = if ($redLast -match ' - evidence: (.+\.log)$') { $Matches[1].Trim() } else { $null }
    Assert 'D3 the named file exists' ($named -and (Test-Path -LiteralPath $named)) "named '$named'"
    $namedBefore = if ($named -and (Test-Path -LiteralPath $named)) {
        (Get-FileHash -LiteralPath $named -Algorithm SHA256).Hash
    } else { $null }
    Assert 'D4 and holds the failing assertion line' `
        ($named -and ((Get-Content -LiteralPath $named -Raw) -match 'the pane never answered')) ''

    # THE 2026-08-16 SEQUENCE: re-run, green, twice. This is what used to erase
    # the evidence.
    $g1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $harness 2>&1
    $g1Code = $LASTEXITCODE
    $g2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $harness 2>&1
    $g2Code = $LASTEXITCODE
    $g2Last = @($g2 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })[-1]
    Assert 'D5 the green re-runs really are green' `
        ($g1Code -eq 0 -and $g2Code -eq 0) "codes $g1Code / $g2Code"
    Assert 'D6 and say nothing about evidence' ($g2Last -notmatch 'evidence:') "last line '$g2Last'"
    Assert 'D7 THE FIX: the red run''s transcript survived both re-runs' `
        ($named -and (Test-Path -LiteralPath $named)) "named '$named'"
    $namedAfter = if ($named -and (Test-Path -LiteralPath $named)) {
        (Get-FileHash -LiteralPath $named -Algorithm SHA256).Hash
    } else { $null }
    Assert 'D8 byte for byte - it was not appended to or truncated either' `
        ($namedBefore -and $namedAfter -and ($namedBefore -eq $namedAfter)) ''

    # Two reds back to back accumulate rather than overwrite - a flake hunt's
    # actual shape, and the reason the preserved name carries the pid too.
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $harness -Red 2>&1)
    [void](& powershell -NoProfile -ExecutionPolicy Bypass -File $harness -Red 2>&1)
    $all = @(Get-PreservedTranscripts -Name 'throwaway' -Dir $root)
    Assert 'D9 back-to-back reds accumulate instead of overwriting' `
        ($all.Count -ge 3) "found $($all.Count)"

    # --- D2. the store is bounded --------------------------------------------
    ''
    '-- D2. the evidence store is bounded'

    $liveK = New-TestTranscript -Name 'unit-k' -Dir $root
    Set-Content -LiteralPath $liveK -Value '  FAIL x'
    for ($i = 0; $i -lt 6; $i++) {
        [void](Save-FailedTranscript -Name 'unit-k' -Path $liveK -Dir $root -Keep 3)
    }
    $keptK = @(Get-PreservedTranscripts -Name 'unit-k' -Dir $root)
    Assert 'D10 pruning keeps exactly -Keep files' ($keptK.Count -eq 3) "found $($keptK.Count)"

    # --- E. negative control: the hazard is real ------------------------------
    ''
    '-- E. negative control: the fixed path really is destroyed by a re-run'

    $fixed = Join-Path $root 'ghoztty-control-last.log'
    Set-Content -LiteralPath $fixed -Value '  FAIL the evidence nobody kept'
    # What every one of these harnesses did before this change: the next run's
    # Tee-Object opens the same name for writing.
    '  PASS a later, healthier run' | Tee-Object -FilePath $fixed | Out-Null
    $survived = (Get-Content -LiteralPath $fixed -Raw) -match 'the evidence nobody kept'
    Assert 'E1 the old fixed-path shape loses the red run''s lines on re-run' `
        (-not $survived) 'the control did not reproduce the hazard - re-read this file'

    # --- F. every teed harness is wired to it --------------------------------
    ''
    '-- F. the harnesses that tee a transcript all end on the keeper'

    $wired = @(
        'ipc-p1.ps1', 'ipc-p2.ps1', 'ipc-p3.ps1', 'cli-argv-fidelity.ps1',
        'ipc-floor-setup.ps1', 'ipc-list-session-id.ps1', 'ipc-target-exists-note.ps1'
    )
    foreach ($w in $wired) {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot $w) -Raw
        Assert "F:$w starts its transcript through New-TestTranscript" `
            ($text -match 'New-TestTranscript') ''
        Assert "F:$w ends it through Complete-TestTranscript" `
            ($text -match 'Complete-TestTranscript') ''
    }

    # And nothing NEW may quietly go back to the fixed-path shape: any script
    # here that tees to a `-last.log` it built by hand is the defect returning.
    $strays = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
        Where-Object {
            $t = Get-Content -LiteralPath $_.FullName -Raw
            ($t -match "Join-Path \`$env:TEMP '[^']*-last\.log'") -and ($t -match 'Tee-Object')
        } | Select-Object -ExpandProperty Name)
    Assert 'F0 no harness still builds a fixed -last.log path by hand' `
        ($strays.Count -eq 0) "strays: $($strays -join ', ')"

    Complete-TestBody
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the library as it now stands?". Red leaves the stamp
# alone: red stays due.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard fail-transcript -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T900 FAIL TRANSCRIPT' -Pass $script:passes -Fail $script:failures
