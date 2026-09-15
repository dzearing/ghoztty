# T740 meta-check: the shared VT-strip helper actually strips VT, and the scan
# that keeps `` `e `` out of this suite has teeth.
#
# THE DEFECT THIS CLOSES. `Snapshot-Text` in session-snapshot-reattach.ps1 and
# session-reattach-zombie.ps1 stripped escape sequences with three regexes built
# on `` `e ``. PowerShell 7 reads that as U+001B; Windows PowerShell 5.1 - the
# host this suite runs under - has no such escape, so the backtick is dropped and
# the pattern says "the letter e". The helpers therefore deleted every `e` from
# the captured text and left every escape sequence exactly where it stood.
# Dumping a WP-D3 snapshot through one produced `C:\Us<e gone>rs\David>`.
#
# What makes it worth a standing check rather than a one-line fix is that it is
# INVISIBLE TO THE ASSERTIONS ON TOP. They kept passing, because the markers
# they matched happened to contain no `e` and were never confronted with the
# sequences they meant to remove. A marker with an `e` in it would have failed
# for a reason nobody could have found by reading the script.
#
# Sections:
#
#   A  the shared helper strips real CSI/OSC/2-byte sequences and keeps every
#      letter - against a fixture that contains both, and against the broken
#      helper, so the fixture is proven to discriminate
#   B  the scanner bites, and only on a real one (quoting, comments, here-strings)
#   C  the live tree is clean, and the scan really covered it
#   D  the two callers use the shared helper and no longer carry the regexes
#   E  the check is wired into the harness floor, which is what runs it
#
# Static: no app, no CLI, no zig build - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\vt-escape-scan.ps1
#   powershell -NoProfile -File test\win32\vt-escape-scan.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it reads files and
# runs the scanner over fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\VtText.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$Scanner = Join-Path $Repo 'scripts\vt-escape-scan.ps1'

# A separate process on purpose: what is under test is the exit code and the
# report a caller sees, not a function this script could hold differently.
function Invoke-Scan([string[]]$ScanPaths) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo -Paths $ScanPaths 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

function Write-Fixture([string]$Path, [string[]]$Lines) {
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"))
}

$fixtureDir = Join-Path $Repo ("temp\vt-escape-scan-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

try {
    # -----------------------------------------------------------------------
    "== A: the helper strips sequences and keeps letters"
    # -----------------------------------------------------------------------
    # The fixture is built from [char] codes so this file stays plain ASCII
    # (control-char-scan.ps1 would otherwise report it). It carries one of each
    # form the strippers claim to handle, and - the point - plenty of letter
    # `e`s, inside and outside the sequences.
    $ESC = [char]27
    $BEL = [char]7
    $raw = "he" + $ESC + "]0;the title" + $BEL + "llo " + $ESC + "[1;31mthere" + $ESC + "[0m end" + $ESC + "M!"

    $stripped = Remove-VtSequences $raw
    Assert 'A1 the OSC title sequence is gone' (-not $stripped.Contains('the title')) "(got '$stripped')"
    Assert 'A2 no ESC survives the strip' (-not $stripped.Contains([string]$ESC)) "(got '$stripped')"
    Assert 'A3 no BEL survives the strip' (-not $stripped.Contains([string]$BEL)) "(got '$stripped')"
    Assert 'A4 the CSI parameters are gone, not left as digits' ($stripped -notmatch '1;31|\[0m') "(got '$stripped')"
    Assert 'A5 the two-byte ESC M is gone' ($stripped -notmatch [regex]::Escape([string]$ESC + 'M')) "(got '$stripped')"

    # The half the broken helper got exactly backwards. `hello there end!` -
    # four of them, and the count is spelled out so a helper that ate one is a
    # failure rather than a slightly different string nobody reads.
    Assert 'A6 every letter e survives' (
        (@($stripped.ToCharArray() | Where-Object { $_ -eq 'e' }).Count -eq 4)) "(got '$stripped')"
    Assert 'A7 the readable text is the words, in order' (
        $stripped -eq 'hello there end!') "(got '$stripped')"
    Assert 'A8 Get-VtReadableText also drops the whitespace' (
        (Get-VtReadableText $raw) -eq 'hellothereend!') "(got '$(Get-VtReadableText $raw)')"
    Assert 'A9 a null input is the empty string, not a throw' ((Get-VtReadableText $null) -eq '')

    # The fixture DISCRIMINATES: run the pre-fix regexes over the same input and
    # watch them do the opposite of what they claimed. Without this, A1-A8 would
    # also pass against a helper that had never been broken, and the section
    # would be evidence of nothing. `$brokenE` is what the old `` `e `` actually
    # collapsed to under 5.1 - the letter - spelled out.
    $brokenE = 'e'
    function Invoke-BrokenStrip([string]$s) {
        $t = [regex]::Replace($s, "$brokenE\][^a$brokenE]*(a|$brokenE\\)", '')
        $t = [regex]::Replace($t, "$brokenE\[[0-9;:?]*[ -/]*[@-~]", '')
        return [regex]::Replace($t, "$brokenE[@-Z\\-_]", '')
    }
    $b = Invoke-BrokenStrip $raw
    Assert 'A10 PRE-FIX ORACLE: the old pattern leaves every escape in' (
        (@($b.ToCharArray() | Where-Object { $_ -eq $ESC }).Count -eq 4)) "(got '$b')"

    # ...and the other half of the damage: it deletes text that was never a
    # sequence. `cache[0]` is ordinary output - an index, a capture group, a
    # test name - and "the letter e, then [, digits, a final byte" matches it.
    $plain = 'the cache[0] entry'
    Assert 'A11 PRE-FIX ORACLE: ...and eats plain text that was never a sequence' (
        (Invoke-BrokenStrip $plain) -eq 'the cach entry') "(got '$(Invoke-BrokenStrip $plain)')"
    Assert 'A12 the fixed helper leaves that text exactly as it found it' (
        (Remove-VtSequences $plain) -eq $plain) "(got '$(Remove-VtSequences $plain)')"

    # -----------------------------------------------------------------------
    ""
    "== B: the scanner bites, and only on a real one"
    # -----------------------------------------------------------------------
    # Built character by character so this file itself never contains the thing
    # it is scanning for - otherwise the live-tree scan in C would report this
    # very script and there would be no way to tell a working scan from a broken
    # fixture.
    $TICK = [char]96
    $bad = "$TICK" + 'e'

    # NOTE the parentheses around every concatenation in these array literals:
    # `,` binds tighter than `+` in PowerShell, so @('a: ' + $x, 'b') is THREE
    # elements, not two. Without them the fixtures were written one token per
    # line and the scanner - correctly - found nothing (this bit on the first
    # run of this very script).
    $hit = Join-Path $fixtureDir 'hit.ps1'
    Write-Fixture $hit @(
        ('$t = [regex]::Replace($s, "' + $bad + '\[[0-9;]*m", '''')')
    )
    $r = Invoke-Scan @($hit)
    Assert 'B1 a backtick-e inside an expanding string is a finding' ($r.Code -eq 1) "(exit $($r.Code)) $($r.Text)"
    Assert 'B2 the report names the headline a caller greps for' ($r.Text -match 'BACKTICK-E ESCAPE')
    Assert 'B3 the finding carries file:line:col' ($r.Text -match 'hit\.ps1:1:\d+') "($($r.Text.Trim()))"
    Assert 'B4 the report says what to write instead' ($r.Text -match '\[char\]27')

    # The three shapes that look like the defect and are not. A scanner that
    # reported these would be turned off within a week, which is the real
    # failure mode for a sweep of this kind.
    $ok = Join-Path $fixtureDir 'ok.ps1'
    Write-Fixture $ok @(
        ('# a comment about ' + $bad + 'cho and ' + $bad + 'rror: markdown inline code'),
        ('$literal = ''the claim' + $bad + 's own line'''),
        ('$backtick = "a literal backtick: ' + $TICK + $TICK + 'e"'),
        '<#',
        ('   block comment mentioning ' + $bad + 'cho'),
        '#>',
        '$here = @''',
        ('a literal here-string with ' + $bad + 'scape in it'),
        '''@'
    )
    $r = Invoke-Scan @($ok)
    Assert 'B5 comments, literal strings, doubled backticks and literal here-strings are clean' `
        ($r.Code -eq 0) "(exit $($r.Code)) $($r.Text)"

    # ...but an EXPANDING here-string is code, and is in scope.
    $hereHit = Join-Path $fixtureDir 'here.ps1'
    Write-Fixture $hereHit @(
        '$x = @"',
        ('a pattern: ' + $bad + '\[0m'),
        '"@'
    )
    $r = Invoke-Scan @($hereHit)
    Assert 'B6 an expanding here-string is in scope' ($r.Code -eq 1) "(exit $($r.Code)) $($r.Text)"
    Assert 'B7 ...and the finding names the right line' ($r.Text -match 'here\.ps1:2:') "($($r.Text.Trim()))"

    # A trailing line comment after real code: the comment half is out of scope,
    # the code half is not.
    $mixed = Join-Path $fixtureDir 'mixed.ps1'
    Write-Fixture $mixed @(
        ('$a = "plain"   # trailing note about ' + $bad + 'cho'),
        ('$b = "' + $bad + '[0m"  # this one is real')
    )
    $r = Invoke-Scan @($mixed)
    Assert 'B8 a trailing comment is out of scope' ($r.Text -notmatch 'mixed\.ps1:1:')
    Assert 'B9 ...and the code on the next line still is' ($r.Text -match 'mixed\.ps1:2:') "($($r.Text.Trim()))"

    # -----------------------------------------------------------------------
    ""
    "== C: the live tree is clean"
    # -----------------------------------------------------------------------
    $live = & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    $liveCode = $LASTEXITCODE
    Assert 'C1 a full scan of test\win32 and scripts exits 0' ($liveCode -eq 0) `
        ("(exit $liveCode) " + (($live -split "`r?`n" | Select-Object -First 8) -join ' / '))
    Assert 'C2 the scan reported what it looked at' ($live -match 'CLEAN: (\d+) file') $live
    if ($live -match 'CLEAN: (\d+) file') {
        # A scan that enumerated a handful of files is a broken enumeration
        # reporting success - the failure a clean exit code hides. The suite
        # alone is 300-odd scripts.
        Assert 'C3 the scan covered both roots, not a corner' ([int]$Matches[1] -gt 300) "($($Matches[1]) files)"
    }

    # -----------------------------------------------------------------------
    ""
    "== D: the two callers use the shared helper"
    # -----------------------------------------------------------------------
    foreach ($caller in @('session-snapshot-reattach.ps1', 'session-reattach-zombie.ps1')) {
        $p = Join-Path $PSScriptRoot $caller
        $text = [System.IO.File]::ReadAllText($p)
        Assert "D1 $caller dot-sources lib\VtText.ps1" ($text -match 'lib\\VtText\.ps1')
        Assert "D2 $caller calls the shared reader" ($text -match 'Get-VtReadableText')
        # The regexes are gone from the caller, not merely shadowed by it.
        Assert "D3 $caller no longer carries a hand-rolled CSI regex" `
            ($text -notmatch '\[0-9;:\?\]\*\[ -/\]\*\[@-~\]') ''
    }
    $lib = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\VtText.ps1'))
    Assert 'D4 the shared helper is built on [char]27' ($lib -match '\[char\]27')

    # -----------------------------------------------------------------------
    ""
    "== E: the check is wired into the floor that runs it"
    # -----------------------------------------------------------------------
    # A scanner nothing runs is a scanner that is not a gate. Membership of the
    # harness floor is what makes it standing: a touched test script puts the
    # floor DUE and `parity-tasks.ps1 validate` refuses the commit until it has
    # been run green.
    . (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')
    $names = @(Get-HarnessFloorAudits | ForEach-Object { [string]$_.Name })
    Assert 'E1 vt-escape-scan.ps1 is a member of the harness floor' `
        ($names -contains 'vt-escape-scan.ps1') "(set: $($names.Count) rows)"
    Assert 'E2 it is not listed as a pending exception' `
        (-not (Get-HarnessFloorPending).ContainsKey('vt-escape-scan.ps1'))

    $guards = [System.IO.File]::ReadAllText((Join-Path $Repo 'scripts\guard-due.ps1'))
    Assert 'E3 the floor guard is due when the scanner itself changes' `
        ($guards -match 'scripts\\vt-escape-scan\.ps1')

    # -----------------------------------------------------------------------
    # Negative control: the scan must be able to go RED against a REAL tracked
    # file, not only against section B's fixtures. Plant one in a live script,
    # run the standard-roots scan, and assert - INVERTED - that it stays clean.
    # A working scanner fails that assertion, so a healthy repo scores exactly
    # 1 FAILURE here; a scanner whose enumeration had quietly stopped covering
    # the suite would pass it and be caught. The probe is restored either way.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting a planted ``e goes unreported - a working scan MUST fail this"
        $probe = Join-Path $PSScriptRoot 'lib\VtText.ps1'
        $original = [System.IO.File]::ReadAllBytes($probe)
        $code = 0
        try {
            $line = '$planted = "' + $bad + '[0m"'
            $planted = $original + [System.Text.Encoding]::UTF8.GetBytes("`r`n" + $line + "`r`n")
            [System.IO.File]::WriteAllBytes($probe, $planted)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Scanner -Repo $Repo -Quiet 2>&1 |
                ForEach-Object { $_.ToString() } | Out-Null
            $code = $LASTEXITCODE
        } finally {
            [System.IO.File]::WriteAllBytes($probe, $original)
        }
        Assert 'N1 a planted backtick-e goes unreported (inverted)' ($code -eq 0) `
            "(exit $code, and 1 is the healthy answer)"
        $restored = [System.IO.File]::ReadAllBytes($probe)
        Assert 'N2 the probe file is restored byte for byte' `
            (@(Compare-Object $original $restored -SyncWindow 0).Count -eq 0)
    }
}
catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $fixtureDir -ErrorAction SilentlyContinue
}

Complete-TestBody

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
