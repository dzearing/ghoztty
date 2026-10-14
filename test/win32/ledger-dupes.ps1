# T1025 acceptance: a doubled entry in a union-merged ledger is noticed, and the
# check that notices it has teeth.
#
# Why: T957 put docs/design/windows-parity-log.md and
# docs/design/windows-parity-feature-ideas.md under git's `union` merge driver,
# so a collision between the two seats merges silently instead of conflicting.
# The trade is right - a conflict there was always resolved by keeping both
# sides - but union never stops anybody, and some merges it accepts leave the
# SAME entry in the file twice. Section D below constructs one with real git:
# two seats holding the same two entries in a different order merge with exit 0
# and one entry doubled. Before this check nothing anywhere would have noticed.
#
# Sections:
#
#   A  the scanner bites on each of its three findings, in both entry shapes
#      the log uses, and stays quiet on the two repeats that are legitimate
#   B  the ledger set is read from .gitattributes, not written down twice
#   C  the live ledgers are clean
#   D  a real union merge produces exactly what the scanner catches
#   E  parity-tasks.ps1 validate is DRIVEN red through its relay, and quiet
#      again once the duplicate is removed
#
# Static checks plus throwaway git repos under temp\ - no app, no CLI, safe on
# the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\ledger-dupes.ps1
#   powershell -NoProfile -File test\win32\ledger-dupes.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads files,
# runs git in fixture repos, and runs the scanner and validate over fixtures.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$Scanner = Join-Path $Repo 'scripts\ledger-dupes.ps1'
$Dash = [string][char]0x2014

# A separate process on purpose: what is under test is the exit code and the
# text a caller sees.
function Invoke-Scan {
    param([string[]]$ScanPaths, [string]$At = $Repo)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Scanner, '-Repo', $At)
    if ($ScanPaths) { $a += @('-Paths'); $a += $ScanPaths }
    $out = & powershell @a 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

function Write-Fixture([string]$Path, [string[]]$Lines) {
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}

# cmd does the redirecting so git's chatter on stderr cannot arrive as a
# terminating NativeCommandError under -ErrorAction Stop.
function Invoke-Git([string]$At, [string]$GitArgs) {
    & cmd /c "git -C `"$At`" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false $GitArgs > NUL 2>&1"
    return $LASTEXITCODE
}

$fixtureDir = Join-Path $Repo ("temp\ledger-dupes-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

# Three healthy entries in the `##` shape, plus the two repeats the live log
# legitimately carries: one task with two entries on one day, and a floor
# sentence recurring across different entries.
$healthy = @(
    '# Fixture log', '', 'Preamble line that is long enough to be considered by the repeat check.', '',
    '- 2026-09-20: T9 closed - a dated bullet entry in the newest-first shape',
    '  that wraps onto a second line.',
    '- 2026-09-19: T8 closed - another dated bullet entry, different from the first.',
    '',
    '## 2026-07-31 - T217 batch 1: four scripts off the desktop', '',
    '- **What changed.** batch one moved.',
    '- **Validation.** Floor: both zig build test lanes, test-agent, P1-P3 green.', '',
    '## 2026-07-31 - T217 batch 2: three more scripts off the desktop', '',
    '- **What changed.** batch two moved.',
    '- **Validation.** Floor: both zig build test lanes, test-agent, P1-P3 green.', ''
)

try {
    # -----------------------------------------------------------------------
    "== A: the scanner bites on each finding, and only on those"
    # -----------------------------------------------------------------------
    $clean = Join-Path $fixtureDir 'clean.md'
    Write-Fixture $clean $healthy
    $r = Invoke-Scan @($clean)
    Assert 'A1 a healthy ledger exits 0' ($r.Code -eq 0) "(exit $($r.Code)) $($r.Text)"
    Assert 'A2 same date + task on two headings is not a finding' ($r.Text -cnotmatch 'DUPLICATE (ENTRY|HEADING)')
    Assert 'A3 a sentence recurring across entries is not a finding' ($r.Text -notmatch 'REPEATED LINE')
    Assert 'A4 the clean line counts the entries it parsed (2 bullets + 2 headings)' `
        ($r.Text -match 'CLEAN: 4 entries') $r.Text

    # A whole `##` entry appended a second time - the replayed-commit shape.
    $dupEntry = Join-Path $fixtureDir 'dup-entry.md'
    Write-Fixture $dupEntry ($healthy + @(
            '## 2026-07-31 - T217 batch 1: four scripts off the desktop', '',
            '- **What changed.** batch one moved.',
            '- **Validation.** Floor: both zig build test lanes, test-agent, P1-P3 green.'))
    $r = Invoke-Scan @($dupEntry)
    Assert 'A5 a doubled ## entry exits 1' ($r.Code -eq 1) "(exit $($r.Code))"
    Assert 'A6 ...reported as DUPLICATE ENTRY naming both lines' `
        ($r.Text -match 'DUPLICATE ENTRY \S*dup-entry\.md:19 repeats the entry at line 9') $r.Text
    Assert 'A7 ...and NOT also as a heading collision (one finding per accident)' `
        ($r.Text -notmatch 'DUPLICATE HEADING') $r.Text
    Assert 'A8 the report leads with LEDGER DUPLICATES' ($r.Text -match 'LEDGER DUPLICATES: 1 finding') $r.Text

    # The dated-bullet shape at the top of the log, doubled.
    $dupBullet = Join-Path $fixtureDir 'dup-bullet.md'
    $b = @($healthy[0..6]) + @('- 2026-09-19: T8 closed - another dated bullet entry, different from the first.') + @($healthy[7..($healthy.Count - 1)])
    Write-Fixture $dupBullet $b
    $r = Invoke-Scan @($dupBullet)
    Assert 'A9 a doubled dated-bullet entry is a DUPLICATE ENTRY' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE ENTRY \S*dup-bullet\.md:8 repeats the entry at line 7') $r.Text

    # Same heading, body edited differently - one entry edited on each seat.
    $dupHead = Join-Path $fixtureDir 'dup-heading.md'
    Write-Fixture $dupHead ($healthy + @(
            '## 2026-07-31 - T217 batch 2: three more scripts off the desktop', '',
            '- **What changed.** batch two moved, and one more sentence from the other seat.'))
    $r = Invoke-Scan @($dupHead)
    Assert 'A10 a heading reused over a different body is a DUPLICATE HEADING' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE HEADING \S*dup-heading\.md:19 opens like the entry at line 14') $r.Text

    # The log carries both dash styles; a hand edit can swap one for the other.
    $dashHead = Join-Path $fixtureDir 'dash-heading.md'
    Write-Fixture $dashHead ($healthy + @(
            ("## 2026-07-31 {0} T217 batch 2:  three more scripts off the desktop" -f $Dash), '',
            '- **What changed.** the em-dash copy.'))
    $r = Invoke-Scan @($dashHead)
    Assert 'A11 an em dash and doubled space do not hide a heading collision' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE HEADING') $r.Text

    # Union keeping both sides of one hunk inside a single entry.
    $repLine = Join-Path $fixtureDir 'repeated-line.md'
    $rl = @($healthy[0..10]) + @('- **What changed.** batch one moved.') + @($healthy[11..($healthy.Count - 1)])
    Write-Fixture $repLine $rl
    $r = Invoke-Scan @($repLine)
    Assert 'A12 a line doubled inside one entry is a REPEATED LINE' `
        ($r.Code -eq 1 -and $r.Text -match 'REPEATED LINE \S*repeated-line\.md:12 repeats line 11 inside the entry at line 9') $r.Text

    # The feature-ideas shape: dated sections of short one-line bullets.
    $ideas = Join-Path $fixtureDir 'ideas.md'
    Write-Fixture $ideas @('# Feature-ideas ledger', '', '## 2026-08-09', '', '- Jump to any pane', '- Dim inactive panes', '- Jump to any pane', '', '## 2026-08-10', '', '- Other idea')
    $r = Invoke-Scan @($ideas)
    Assert 'A13 a short idea bullet doubled in its day is caught (no length floor for bullets)' `
        ($r.Code -eq 1 -and $r.Text -match 'REPEATED LINE \S*ideas\.md:7 repeats line 5') $r.Text
    $ideas2 = Join-Path $fixtureDir 'ideas2.md'
    Write-Fixture $ideas2 @('# Feature-ideas ledger', '', '## 2026-08-09', '', '- Idea one', '', '## 2026-08-09', '', '- Idea two')
    $r = Invoke-Scan @($ideas2)
    Assert 'A14 one day''s section appearing twice is a DUPLICATE HEADING' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE HEADING \S*ideas2\.md:7') $r.Text

    # The entry at the end of a file has no trailing separator; the same entry
    # mid-file does. They must still compare equal.
    $tail = Join-Path $fixtureDir 'tail.md'
    [System.IO.File]::WriteAllText($tail, "# L`n`n## 2026-01-01 - T1: x`n`nbody x   `n`n`n## 2026-01-02 - T2: y`n`nbody y`n`n## 2026-01-01 - T1: x`n`nbody x",
        (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Scan @($tail)
    Assert 'A15 trailing whitespace and blank lines do not hide a duplicate at end of file' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE ENTRY \S*tail\.md:12 repeats the entry at line 3') $r.Text

    $r = Invoke-Scan @((Join-Path $fixtureDir 'no-such-ledger.md'))
    Assert 'A16 a missing ledger is exit 2, not CLEAN' ($r.Code -eq 2 -and $r.Text -notmatch 'CLEAN') $r.Text

    # One entry is the shape a PowerShell function return unrolls to a bare
    # object; the scan must still count it as one.
    $single = Join-Path $fixtureDir 'single.md'
    Write-Fixture $single @('# L', '', '## 2026-01-01 - T1: only', '', 'body')
    $r = Invoke-Scan @($single)
    Assert 'A17 a one-entry ledger is CLEAN with 1 entry' ($r.Code -eq 0 -and $r.Text -match 'CLEAN: 1 entries') $r.Text

    # -----------------------------------------------------------------------
    ""
    "== B: the ledger set comes from .gitattributes"
    # -----------------------------------------------------------------------
    $attrRepo = Join-Path $fixtureDir 'attr-repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $attrRepo 'docs') | Out-Null
    Write-Fixture (Join-Path $attrRepo '.gitattributes') @(
        '# comment naming docs/b.md merge=union must not count', '.gitignore merge=union',
        'docs/a.md merge=union', 'docs/b.md text eol=lf')
    Write-Fixture (Join-Path $attrRepo 'docs\a.md') ($healthy + @('## 2026-07-31 - T217 batch 1: four scripts off the desktop', '', '- **What changed.** batch one moved.', '- **Validation.** Floor: both zig build test lanes, test-agent, P1-P3 green.'))
    Copy-Item (Join-Path $attrRepo 'docs\a.md') (Join-Path $attrRepo 'docs\b.md')
    Write-Fixture (Join-Path $attrRepo '.gitignore') @('x', 'x')
    $r = Invoke-Scan -At $attrRepo
    Assert 'B1 a union-merged ledger is checked without being named' `
        ($r.Code -eq 1 -and $r.Text -match 'docs\\a\.md') $r.Text
    Assert 'B2 a ledger NOT under merge=union is left alone' ($r.Text -notmatch 'b\.md') $r.Text
    Assert 'B3 a union-merged non-markdown file (.gitignore) is left alone' ($r.Text -notmatch 'gitignore') $r.Text

    Write-Fixture (Join-Path $attrRepo '.gitattributes') @('*.zig text eol=lf')
    $r = Invoke-Scan -At $attrRepo
    Assert 'B4 an empty union set is exit 2, never a silent CLEAN' ($r.Code -eq 2 -and $r.Text -notmatch 'CLEAN') $r.Text

    $live = [System.IO.File]::ReadAllText((Join-Path $Repo '.gitattributes'))
    Assert 'B5 premise: the live log is still union-merged' `
        ($live -match '(?m)^docs/design/windows-parity-log\.md\s+merge=union')
    Assert 'B6 premise: the live feature-ideas ledger is still union-merged' `
        ($live -match '(?m)^docs/design/windows-parity-feature-ideas\.md\s+merge=union')

    # -----------------------------------------------------------------------
    ""
    "== C: the live ledgers are clean"
    # -----------------------------------------------------------------------
    $r = Invoke-Scan
    Assert 'C1 the live union set exits 0' ($r.Code -eq 0) ("(exit $($r.Code)) " + (($r.Text -split "`r?`n" | Select-Object -First 6) -join ' / '))
    $n = 0
    if ($r.Text -match 'CLEAN: (\d+) entries in (\d+) union') { $n = [int]$Matches[1]; $files = [int]$Matches[2] } else { $files = 0 }
    # An enumeration that parsed a handful of entries is a broken parser
    # reporting success.
    Assert 'C2 the scan parsed the whole log, not a corner' ($n -gt 1000) "($n entries)"
    Assert 'C3 both live ledgers were read' ($files -eq 2) "($files ledgers)"

    # -----------------------------------------------------------------------
    ""
    "== D: a real union merge produces what the scanner catches"
    # -----------------------------------------------------------------------
    # The premise of the whole task, constructed rather than asserted: two seats
    # that each hold entries E and F, in opposite order, merge under union with
    # exit 0 and a doubled entry.
    $mergeRepo = Join-Path $fixtureDir 'merge-repo'
    New-Item -ItemType Directory -Force -Path $mergeRepo | Out-Null
    $null = Invoke-Git $mergeRepo 'init -q -b main'
    $null = Invoke-Git $mergeRepo 'config core.autocrlf false'
    Write-Fixture (Join-Path $mergeRepo '.gitattributes') @('log.md merge=union')
    $x = @('## 2026-01-01 - T1: x', '', 'body x')
    $e = @('## 2026-01-03 - T3: e', '', 'body e', '')
    $f = @('## 2026-01-02 - T2: f', '', 'body f', '')
    Write-Fixture (Join-Path $mergeRepo 'log.md') (@('# L', '') + $x)
    $null = Invoke-Git $mergeRepo 'add -A'
    $null = Invoke-Git $mergeRepo 'commit -qm base'
    $null = Invoke-Git $mergeRepo 'checkout -qb seat-a'
    Write-Fixture (Join-Path $mergeRepo 'log.md') (@('# L', '') + $e + $f + $x)
    $null = Invoke-Git $mergeRepo 'commit -qam a'
    $null = Invoke-Git $mergeRepo 'checkout -q main'
    Write-Fixture (Join-Path $mergeRepo 'log.md') (@('# L', '') + $f + $e + $x)
    $null = Invoke-Git $mergeRepo 'commit -qam b'
    $mergeCode = Invoke-Git $mergeRepo 'merge -q seat-a -m merged'
    Assert 'D1 git merges the two seats under union without a conflict' ($mergeCode -eq 0) "(exit $mergeCode)"
    $merged = [System.IO.File]::ReadAllText((Join-Path $mergeRepo 'log.md'))
    $copies = ([regex]::Matches($merged, 'T2: f')).Count
    Assert 'D2 ...and the merged ledger holds an entry twice (the premise)' ($copies -eq 2) "($copies copies)"
    $r = Invoke-Scan -At $mergeRepo
    Assert 'D3 the scanner, reading the union set of that repo, reports it' `
        ($r.Code -eq 1 -and $r.Text -match 'DUPLICATE ENTRY \S*log\.md') $r.Text

    # -----------------------------------------------------------------------
    ""
    "== E: validate is DRIVEN red through its relay"
    # -----------------------------------------------------------------------
    $tasksSrc = [System.IO.File]::ReadAllText((Join-Path $Repo 'scripts\parity-tasks.ps1'))
    Assert 'E1 parity-tasks.ps1 validate runs the scanner' ($tasksSrc -match 'ledger-dupes\.ps1')

    $fixtureTasks = Join-Path $mergeRepo 'docs\design\windows-parity-tasks'
    New-Item -ItemType Directory -Force -Path $fixtureTasks | Out-Null
    $t = @(
        '---', 'id: T1', 'title: "fixture"', 'order: null', 'deps: []',
        'status: "todo"', 'commits: []', 'seat: "win"', 'priority: "P2"',
        'triage-reason: "fixture"', 'tags: ["infra"]', '---', '',
        '# T1 - fixture', '', '## Summary', '', 'fixture.'
    )
    [System.IO.File]::WriteAllText((Join-Path $fixtureTasks 'T1.md'), ($t -join "`r`n"))

    function Invoke-FixtureValidate {
        $env:GHOZTTY_LEDGER_DUPES_REPO = $mergeRepo
        try {
            $o = & powershell -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $Repo 'scripts\parity-tasks.ps1') validate -TaskDir $fixtureTasks 2>&1 |
                ForEach-Object { $_.ToString() } | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $o }
        } finally {
            Remove-Item Env:\GHOZTTY_LEDGER_DUPES_REPO -ErrorAction SilentlyContinue
        }
    }
    $v = Invoke-FixtureValidate
    Assert 'E2 validate reports DUPLICATED LEDGER ENTRY over the merged repo' ($v.Text -match 'DUPLICATED LEDGER ENTRY') $v.Text
    Assert 'E3 ...and scores it as a problem' ($v.Code -ne 0) "(exit $($v.Code))"
    Assert 'E4 ...relaying the scanner''s finding with the ledger and line' ($v.Text -match 'DUPLICATE ENTRY \S*log\.md:\d+') $v.Text

    # Remove the second copy: the relay must fall quiet, so E2 measured the
    # duplicate and not the fixture's existence.
    $fixed = $merged -replace '(?s)(## 2026-01-02 - T2: f\r?\n\r?\nbody f\r?\n\r?\n)(## 2026-01-03 - T3: e\r?\n\r?\nbody e\r?\n\r?\n)\1', '$1$2'
    [System.IO.File]::WriteAllText((Join-Path $mergeRepo 'log.md'), $fixed, (New-Object System.Text.UTF8Encoding($false)))
    Assert 'E5 premise: the repaired ledger holds each entry once' (([regex]::Matches($fixed, 'T2: f')).Count -eq 1) $fixed
    $v = Invoke-FixtureValidate
    Assert 'E6 a repaired ledger is not reported' ($v.Text -notmatch 'DUPLICATED LEDGER ENTRY') $v.Text

    # -----------------------------------------------------------------------
    # Negative control: the scanner must go RED on the REAL log's shape, not
    # only on section A's fixtures. Copy the live log, append its own last
    # entry again, and assert - INVERTED - that the copy is clean. A working
    # scanner fails that, so a healthy run scores exactly 1 FAILURE. The live
    # file is never written.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting a doubled live entry is NOT found - a working scan MUST fail this"
        $liveLog = Join-Path $Repo 'docs\design\windows-parity-log.md'
        $copy = Join-Path $fixtureDir 'live-copy.md'
        $text = [System.IO.File]::ReadAllText($liveLog, [System.Text.Encoding]::UTF8)
        $lastHead = $text.LastIndexOf("`n## ")
        $doubled = $text.TrimEnd() + "`n`n" + $text.Substring($lastHead + 1).TrimEnd() + "`n"
        [System.IO.File]::WriteAllText($copy, $doubled, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-Scan @($copy)
        Assert 'N1 a doubled real entry goes unreported (inverted)' ($r.Code -eq 0) `
            "(exit $($r.Code), and 1 is the healthy answer)"
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

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this check been run against the tree as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard ledger-dupes -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
